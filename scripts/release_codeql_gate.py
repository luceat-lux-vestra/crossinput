#!/usr/bin/env python3
"""Verify real exact-main CodeQL release evidence BEFORE GitHub Release mutation.

This guard runs in the already-public 'released' workflow. It protects
GitHub Release publication, NOT initial GitHub Release visibility.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

LANGUAGES = ("actions", "java-kotlin", "python", "swift")
SHA = re.compile(r"[0-9a-f]{40}\Z")
REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")


def reject(message):
    raise ValueError(message)


def metadata_ok(run, workflow, jobs, artifacts, repo, sha, now):
    """Validate API evidence; no CI conclusion alone is accepted as SARIF proof."""
    if not REPO.fullmatch(repo) or not SHA.fullmatch(sha):
        reject("invalid repository or SHA")
    if not isinstance(workflow, dict) or not isinstance(workflow.get("id"), int):
        reject("CodeQL workflow identity missing")
    if not isinstance(run, dict):
        reject("CodeQL run missing")
    identity = (
        run.get("workflow_id") == workflow["id"]
        and run.get("path") == ".github/workflows/codeql.yml"
        and run.get("event") in ("workflow_dispatch", "schedule")
        and run.get("head_repository", {}).get("full_name") == repo
        and run.get("head_branch") == "main"
        and run.get("head_sha") == sha
        and run.get("status") == "completed"
        and run.get("conclusion") == "success"
        and isinstance(run.get("id"), int)
        and isinstance(run.get("run_attempt"), int)
        and run["run_attempt"] >= 1
    )
    if not identity:
        reject("untrusted or mismatched CodeQL run identity/state/source")
    created_raw = run.get("created_at")
    if not isinstance(created_raw, str):
        reject("missing scan creation time")
    try:
        created = dt.datetime.fromisoformat(created_raw.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError("invalid scan creation time") from exc
    # A successful scan is bound to immutable source, not an arbitrary age.
    # An older run is eligible while all four original SARIF artifacts remain
    # accessible and the CURRENT verifier still accepts their contents.
    if created.tzinfo is None or created > now:
        reject("scan has invalid or future timestamp")
    expected_jobs = {f"Analyze ({lang})" for lang in LANGUAGES}
    if (not isinstance(jobs, dict)
        or jobs.get("total_count") != len(expected_jobs)
        or not isinstance(jobs.get("jobs"), list)
        or len(jobs["jobs"]) != len(expected_jobs)
        or {j.get("name") for j in jobs["jobs"] if isinstance(j, dict)} != expected_jobs
        or any(j.get("status") != "completed" or j.get("conclusion") != "success"
               for j in jobs["jobs"] if isinstance(j, dict))):
        reject("missing, extra, incomplete or unsuccessful CodeQL language jobs")
    expected_names = {f"release-codeql-{sha}-{lang}" for lang in LANGUAGES}
    if (not isinstance(artifacts, dict)
        or artifacts.get("total_count") != len(LANGUAGES)
        or not isinstance(artifacts.get("artifacts"), list)
        or len(artifacts["artifacts"]) != len(LANGUAGES)):
        reject("expected precisely four retained SARIF artifacts")
    items = artifacts["artifacts"]
    if ({a.get("name") for a in items if isinstance(a, dict)} != expected_names
        or any(not isinstance(a, dict)
               or a.get("expired") is not False
               or not isinstance(a.get("id"), int)
               or not isinstance(a.get("size_in_bytes"), int)
               or a["size_in_bytes"] <= 0
               or a.get("workflow_run", {}).get("head_sha") not in (None, sha)
               for a in items)):
        reject("missing, ambiguous, expired or wrong-SHA SARIF artifacts")
    return run["id"]


def gh(*args):
    result = subprocess.run(["gh", *args], check=True, capture_output=True, text=True)
    return result.stdout


def api(repo, path):
    return json.loads(gh("api", f"repos/{repo}/{path}"))


def check_repo_sha(repo, sha):
    """A scanned protected-main SHA can be an earlier commit on main history."""
    if not REPO.fullmatch(repo) or not SHA.fullmatch(sha):
        reject("invalid repo/SHA")
    comparison = api(repo, f"compare/{sha}...main")
    if (comparison.get("status") not in ("ahead", "identical")
        or comparison.get("merge_base_commit", {}).get("sha") != sha
        or comparison.get("base_commit", {}).get("sha") != sha):
        reject("release candidate is not proven reachable from protected main")


def verify_live(repo, sha, script):
    if not os.environ.get("GH_TOKEN"):
        reject("missing GitHub API credential")
    check_repo_sha(repo, sha)
    workflow = api(repo, "actions/workflows/codeql.yml")
    # Scheduled and manual runs share exact-SHA evidence semantics. PR results
    # are deliberately ineligible even if their GitHub check concludes success.
    candidates = []
    for event in ("workflow_dispatch", "schedule"):
        found = api(repo, f"actions/workflows/codeql.yml/runs?event={event}&head_sha={sha}&per_page=100")
        if not isinstance(found.get("workflow_runs"), list):
            reject(f"CodeQL {event} discovery returned no runs array")
        candidates.extend(found["workflow_runs"])
    candidates.sort(key=lambda r: r.get("created_at", "") if isinstance(r, dict) else "", reverse=True)
    now = dt.datetime.now(dt.timezone.utc)
    reasons = []
    for candidate in candidates:
        if not isinstance(candidate, dict):
            continue
        run_id = candidate.get("id")
        if not isinstance(run_id, int):
            continue
        try:
            run = api(repo, f"actions/runs/{run_id}")
            jobs = api(repo, f"actions/runs/{run_id}/jobs?per_page=100")
            artifacts = api(repo, f"actions/runs/{run_id}/artifacts?per_page=100")
            metadata_ok(run, workflow, jobs, artifacts, repo, sha, now)
            with tempfile.TemporaryDirectory(prefix="erdmaid-release-codeql-") as tmp:
                for lang in LANGUAGES:
                    name = f"release-codeql-{sha}-{lang}"
                    directory = Path(tmp) / lang
                    directory.mkdir()
                    subprocess.run(["gh", "run", "download", str(run_id),
                                    "-R", repo, "-n", name, "-D", str(directory)], check=True)
                    subprocess.run([sys.executable, str(script),
                                    "--sarif-dir", str(directory),
                                    "--language", lang, "--candidate-sha", sha], check=True)
            # Catch a moved main after the scan, download and verdict readback.
            check_repo_sha(repo, sha)
            print(f"Exact-SHA GitHub Release security gate passed: {repo}@{sha}, "
                  f"trusted {run['event']} CodeQL run {run_id}, all four SARIF verdicts accepted")
            return
        except (ValueError, subprocess.CalledProcessError, OSError, KeyError, TypeError) as exc:
            reasons.append(f"{run_id}: {exc}")
    reject("no acceptable exact-SHA CodeQL evidence (last errors: "
           + "; ".join(reasons[-3:]) + ")")


def self_test():
    repo = "owner/repo"
    sha = "a" * 40
    now = dt.datetime(2026, 10, 14, tzinfo=dt.timezone.utc)
    workflow = {"id": 42}
    run = {"id": 5, "workflow_id": 42, "path": ".github/workflows/codeql.yml",
           "event": "workflow_dispatch", "head_repository": {"full_name": repo},
           "head_branch": "main", "head_sha": sha, "status": "completed",
           "conclusion": "success", "run_attempt": 1,
           "created_at": "2026-10-14T00:00:00Z"}
    jobs = {"total_count": len(LANGUAGES), "jobs": [{"name": name,
             "status": "completed", "conclusion": "success"} for name in sorted({f"Analyze ({lang})" for lang in LANGUAGES})]}
    artifacts = {"total_count": len(LANGUAGES), "artifacts": [
        {"name": f"release-codeql-{sha}-{lang}", "id": i + 1,
         "size_in_bytes": 2000, "expired": False,
         "workflow_run": {"head_sha": sha}} for i, lang in enumerate(LANGUAGES)]}
    def probe(expected_error=None, change=None):
        current = json.loads(json.dumps([run, workflow, jobs, artifacts]))
        if change:
            change(*current)
        try:
            accepted = metadata_ok(*current, repo, sha, now)
        except (ValueError, TypeError, AttributeError) as exc:
            if expected_error is None or expected_error not in str(exc):
                raise AssertionError(f"unexpected evidence result: {exc}") from exc
        else:
            if expected_error:
                raise AssertionError(f"fail-open condition: {expected_error}")
            assert accepted == 5
    probe()
    probe(None, lambda r, w, j, a: r.update(event="schedule"))
    probe("mismatched", lambda r, w, j, a: r.update(event="push"))
    probe("mismatched", lambda r, w, j, a: r.update(event="pull_request"))
    probe("mismatched", lambda r, w, j, a: r.update(head_branch="feature"))
    probe("mismatched", lambda r, w, j, a: r.update(head_sha="b" * 40))
    probe("mismatched", lambda r, w, j, a: r.update(conclusion="cancelled"))
    probe("mismatched", lambda r, w, j, a: r.update(path=".github/workflows/unsafe.yml"))
    probe("mismatched", lambda r, w, j, a: r.update(workflow_id=4))
    probe(None, lambda r, w, j, a: r.update(created_at="2025-01-01T00:00:00Z"))
    probe("future timestamp", lambda r, w, j, a: r.update(created_at="2026-10-15T00:00:00Z"))
    probe("language jobs", lambda r, w, j, a: j["jobs"][0].update(conclusion="failure"))
    probe("language jobs", lambda r, w, j, a: j["jobs"].pop())
    probe("SARIF artifacts", lambda r, w, j, a: a["artifacts"].pop())
    probe("wrong-SHA", lambda r, w, j, a: a["artifacts"][0]["workflow_run"].update(head_sha="b" * 40))
    probe("ambiguous", lambda r, w, j, a: a["artifacts"][1].update(expired=True))
    print("exact-SHA GitHub Release CodeQL evidence negative controls passed")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--repository")
    parser.add_argument("--candidate-sha")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.repository or not args.candidate_sha:
        parser.error("--repository and --candidate-sha required")
    script = Path(__file__).with_name("release_codeql_verdict.py")
    if not script.is_file():
        reject("missing local CodeQL SARIF verifier")
    try:
        verify_live(args.repository, args.candidate_sha, script)
    except (ValueError, subprocess.CalledProcessError, OSError, KeyError, TypeError) as exc:
        print(f"::error::GitHub Release CodeQL authorization rejected: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc


if __name__ == "__main__":
    main()
