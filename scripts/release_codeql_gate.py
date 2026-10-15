#!/usr/bin/env python3
"""Verify real exact-main CodeQL release evidence BEFORE GitHub Release mutation.

This guard runs in the already-public 'released' workflow. It protects
GitHub Release publication, NOT initial GitHub Release visibility.
"""
import argparse
import datetime as dt
import time
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
        and SHA.fullmatch(run.get("head_sha") or "")
        and run.get("status") == "completed"
        and run.get("conclusion") == "success"
        and isinstance(run.get("id"), int)
        and isinstance(run.get("run_attempt"), int)
        and run["run_attempt"] == 1
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
    if (not isinstance(jobs, dict) or not isinstance(jobs.get("jobs"), list)
        or jobs.get("total_count") != len(expected_jobs) + 1
        or len(jobs["jobs"]) != len(expected_jobs) + 1
        or {j.get("name") for j in jobs["jobs"] if isinstance(j, dict)}
           != expected_jobs | {"CodeQL schedule guard"}
        or any(j.get("status") != "completed" or j.get("conclusion") != "success"
               for j in jobs["jobs"] if isinstance(j, dict))):
        reject("missing, extra, incomplete or unsuccessful CodeQL language jobs")
    expected_names = ({f"release-codeql-{sha}-{lang}" for lang in LANGUAGES}
                      | {f"release-codeql-source-{sha}-{lang}" for lang in LANGUAGES})
    if (not isinstance(artifacts, dict)
        or artifacts.get("total_count") != 2 * len(LANGUAGES)
        or not isinstance(artifacts.get("artifacts"), list)
        or len(artifacts["artifacts"]) != 2 * len(LANGUAGES)):
        reject("expected precisely four retained SARIF artifacts")
    items = artifacts["artifacts"]
    if ({a.get("name") for a in items if isinstance(a, dict)} != expected_names
        or any(not isinstance(a, dict)
               or a.get("expired") is not False
               or not isinstance(a.get("id"), int)
               or not isinstance(a.get("size_in_bytes"), int)
               or a["size_in_bytes"] <= 0
               or a.get("workflow_run", {}).get("head_sha") not in (None, run["head_sha"])
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


def intentional_schedule_skip(run, jobs):
    """A successful guard-only schedule is a no-op, never release evidence."""
    if run.get("event") != "schedule" or run.get("status") != "completed" or run.get("conclusion") != "success":
        return False
    items = jobs.get("jobs", [])
    return (len(items) == len(LANGUAGES) + 1
            and len([j for j in items if j.get("name") == "CodeQL schedule guard"
                     and j.get("conclusion") == "success"]) == 1
            and {j.get("name") for j in items if j.get("conclusion") == "skipped"}
                == {f"Analyze ({lang})" for lang in LANGUAGES})


def verify_manifest(directory, repo, run, sha, lang):
    docs = list(directory.rglob("source-identity.json"))
    if len(docs) != 1:
        reject("missing or ambiguous source identity manifest")
    doc = json.loads(docs[0].read_text(encoding="utf-8"))
    if (not isinstance(doc, dict) or doc.get("schema") != 1
        or doc.get("candidate_sha") != sha or doc.get("checkout_sha") != sha
        or doc.get("event_sha") != run.get("head_sha")
        or doc.get("run_id") != run.get("id")
        or doc.get("run_attempt") != 1 or doc.get("language") != lang):
        reject("CodeQL source provenance mismatch")


def inspect_run(repo, sha, workflow, run_id, script):
    run = api(repo, f"actions/runs/{run_id}")
    jobs = api(repo, f"actions/runs/{run_id}/jobs?per_page=100")
    if intentional_schedule_skip(run, jobs):
        return False
    artifacts = api(repo, f"actions/runs/{run_id}/artifacts?per_page=100")
    metadata_ok(run, workflow, jobs, artifacts, repo, sha, dt.datetime.now(dt.timezone.utc))
    with tempfile.TemporaryDirectory(prefix="crossinput-release-codeql-") as tmp:
        for lang in LANGUAGES:
            for prefix in ("release-codeql-", "release-codeql-source-"):
                name = f"{prefix}{sha}-{lang}"
                directory = Path(tmp) / lang / ("manifest" if prefix.endswith("source-") else "sarif")
                directory.mkdir(parents=True)
                subprocess.run(["gh", "run", "download", str(run_id),
                                "-R", repo, "-n", name, "-D", str(directory)], check=True)
                if prefix.endswith("source-"):
                    verify_manifest(directory, repo, run, sha, lang)
                else:
                    subprocess.run([sys.executable, str(script),
                                    "--sarif-dir", str(directory),
                                    "--language", lang, "--candidate-sha", sha], check=True)
    check_repo_sha(repo, sha)
    print(f"Exact-source CodeQL PASS {repo}@{sha} run={run_id} all four languages")
    return True


def run_candidates(repo, sha, workflow, script):
    found = []
    for event in ("workflow_dispatch", "schedule"):
        result = api(repo, f"actions/workflows/codeql.yml/runs?event={event}&branch=main&per_page=100")
        if not isinstance(result.get("workflow_runs"), list):
            reject("CodeQL discovery returned invalid run array")
        for run in result["workflow_runs"]:
            if (isinstance(run, dict) and run.get("workflow_id") == workflow["id"]
                and run.get("path") == ".github/workflows/codeql.yml"
                and run.get("head_branch") == "main" and run.get("run_attempt") == 1
                and run.get("head_repository", {}).get("full_name") == repo):
                found.append(run)
    found.sort(key=lambda r: r.get("created_at", ""), reverse=True)
    return found


def verify_live(repo, sha, script):
    if not os.environ.get("GH_TOKEN"):
        reject("missing GitHub API credential")
    check_repo_sha(repo, sha)
    workflow = api(repo, "actions/workflows/codeql.yml")
    if not isinstance(workflow.get("id"), int):
        reject("untrusted CodeQL workflow")
    candidates = run_candidates(repo, sha, workflow, script)
    active = []
    for run in candidates:
        run_id = run["id"]
        if run.get("status") != "completed":
            # Exact candidate dispatch is signaled in GitHub's run-name.
            if (run.get("event") == "workflow_dispatch"
                and run.get("display_title") == f"CodeQL source {sha}"):
                active.append(run_id)
            continue
        if run.get("conclusion") != "success":
            continue
        try:
            if inspect_run(repo, sha, workflow, run_id, script):
                return
        except (ValueError, subprocess.CalledProcessError, OSError, KeyError, TypeError) as exc:
            # A completed run with manifest/provenance or SARIF problems must
            # not be turned into a fresh scan that masks a security failure.
            if run.get("event") == "workflow_dispatch" and run.get("display_title") == f"CodeQL source {sha}":
                reject(f"invalid completed exact candidate scan {run_id}: {exc}")
            # A run for a different candidate or a guard-only schedule is ineligible.
            continue
    if len(active) > 1:
        reject("ambiguous active exact-source CodeQL scans")
    if active:
        selected = active[0]
        print(f"Joining active exact-source CodeQL {selected}", flush=True)
    else:
        # Never dispatch from tag or feature refs; the workflow file is selected
        # from the trusted current default branch, candidate is an immutable SHA.
        gh("api", "-X", "POST", f"repos/{repo}/actions/workflows/codeql.yml/dispatches",
           "-f", "ref=main", "-f", f"inputs[candidate_sha]={sha}")
        selected = None
        print(f"Dispatched trusted full CodeQL for candidate {sha}", flush=True)

    deadline = time.monotonic() + 35 * 60
    while time.monotonic() < deadline:
        check_repo_sha(repo, sha)
        recent = run_candidates(repo, sha, workflow, script)
        matches = [r for r in recent if r.get("event") == "workflow_dispatch"
                   and r.get("display_title") == f"CodeQL source {sha}"
                   and r.get("run_attempt") == 1]
        if selected is None:
            if len(matches) > 1:
                reject("ambiguous auto-dispatched CodeQL runs")
            if matches:
                selected = matches[0]["id"]
        if selected is not None:
            matched = [r for r in matches if r["id"] == selected]
            if matched:
                state = matched[0]
                if state.get("status") == "completed":
                    if state.get("conclusion") != "success":
                        reject(f"CodeQL run {selected} ended {state.get('conclusion')}")
                    if inspect_run(repo, sha, workflow, selected, script):
                        return
                    reject("CodeQL finished without complete language evidence")
        time.sleep(15)
    reject(f"timed out waiting for exact-source CodeQL run {selected}" if selected else
           "timed out discovering auto-dispatched CodeQL run")

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
    jobs = {"total_count": len(LANGUAGES) + 1, "jobs": [{"name": name,
             "status": "completed", "conclusion": "success"} for name in sorted({f"Analyze ({lang})" for lang in LANGUAGES} | {"CodeQL schedule guard"})]}
    artifacts = {"total_count": 2 * len(LANGUAGES), "artifacts": [
        {"name": f"release-codeql-{sha}-{lang}", "id": i + 1,
         "size_in_bytes": 2000, "expired": False,
         "workflow_run": {"head_sha": sha}} for i, lang in enumerate(LANGUAGES)] + [
        {"name": f"release-codeql-source-{sha}-{lang}", "id": i + 10,
         "size_in_bytes": 500, "expired": False,
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
    probe(None, lambda r, w, j, a: (r.update(head_sha="b" * 40), [v["workflow_run"].update(head_sha="b" * 40) for v in a["artifacts"]]))
    probe("mismatched", lambda r, w, j, a: r.update(conclusion="cancelled"))
    probe("mismatched", lambda r, w, j, a: r.update(run_attempt=2))
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
