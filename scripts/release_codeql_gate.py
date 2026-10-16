#!/usr/bin/env python3
"""Verify exact-source CodeQL release evidence before managed publication.

The caller may analyze the current protected main or an earlier immutable
protected-main ancestor. This gate protects repository-managed first
publication; an owner-created public GitHub Release remains out of band.
"""
import argparse
import datetime as dt
import time
from unittest import mock
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


def metadata_ok(run, workflow, jobs, artifacts, repo, sha, now, allow_missing=False):
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
        or not isinstance(artifacts.get("artifacts"), list)
        or artifacts.get("total_count") != len(artifacts["artifacts"])
        or len(artifacts["artifacts"]) > 2 * len(LANGUAGES)):
        reject("expected four SARIF plus four source-provenance artifacts")
    items = artifacts["artifacts"]
    names = [a.get("name") for a in items if isinstance(a, dict)]
    if (len(names) != len(items) or len(names) != len(set(names))
        or not set(names) <= expected_names):
        reject("missing, ambiguous, expired or wrong-SHA SARIF artifacts")
    expired = False
    for a in items:
        if (not isinstance(a.get("id"), int)
            or not isinstance(a.get("size_in_bytes"), int)
            or a["size_in_bytes"] <= 0
            or (a.get("workflow_run") or {}).get("head_sha") not in (None, run["head_sha"])):
            reject("missing, ambiguous, expired or wrong-SHA SARIF artifacts")
        if a.get("expired") is True:
            expired = True
        elif a.get("expired") is not False:
            reject("unknown original CodeQL artifact expiration state")
    if expired or len(items) < 2 * len(LANGUAGES):
        if allow_missing:
            return None
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


def inspect_run(repo, sha, workflow, run_id, script, allow_missing=False):
    run = api(repo, f"actions/runs/{run_id}")
    jobs = api(repo, f"actions/runs/{run_id}/jobs?per_page=100")
    if intentional_schedule_skip(run, jobs):
        return False
    artifacts = api(repo, f"actions/runs/{run_id}/artifacts?per_page=100")
    usable = metadata_ok(run, workflow, jobs, artifacts, repo, sha,
                         dt.datetime.now(dt.timezone.utc),
                         allow_missing=allow_missing)
    if usable is None:
        return None
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
        # Search sufficiently deeply to rule out conflicting attempts.
        # A saturated upper bound is a security NO-GO, never silent evidence reuse.
        for page in range(1, 11):
            result = api(repo, f"actions/workflows/codeql.yml/runs?event={event}&branch=main&per_page=100&page={page}")
            rows = result.get("workflow_runs")
            if not isinstance(rows, list) or len(rows) > 100 or any(not isinstance(row, dict) for row in rows):
                reject("CodeQL discovery returned invalid run array")
            found.extend(run for run in rows
                         if run.get("workflow_id") == workflow["id"]
                         and run.get("path") == ".github/workflows/codeql.yml"
                         and run.get("head_branch") == "main"
                         and (run.get("head_repository") or {}).get("full_name") == repo)
            if len(rows) < 100:
                break
        else:
            reject("CodeQL discovery exhausted safe 1000-run bound")
    found.sort(key=lambda r: (r.get("created_at", ""), r.get("id", 0)), reverse=True)
    return found


def verify_live(repo, sha, script):
    if not os.environ.get("GH_TOKEN"):
        reject("missing GitHub API credential")
    check_repo_sha(repo, sha)
    workflow = api(repo, "actions/workflows/codeql.yml")
    if not isinstance(workflow.get("id"), int):
        reject("untrusted CodeQL workflow")

    candidates = run_candidates(repo, sha, workflow, script)
    before = {row.get("id") for row in candidates if isinstance(row.get("id"), int)}
    active = []
    good = 0
    for run in candidates:
        exact = ((run.get("event") == "workflow_dispatch"
                  and run.get("display_title") == f"CodeQL source {sha}")
                 or (run.get("event") == "schedule" and run.get("head_sha") == sha))
        if not exact:
            continue
        run_id = run["id"]
        if run.get("run_attempt") != 1:
            reject(f"ambiguous rerun attempt for exact candidate {run_id}")
        if run.get("status") != "completed":
            active.append(run_id)
            continue
        if run.get("conclusion") != "success":
            reject(f"existing exact candidate CodeQL run {run_id} ended {run.get('conclusion')}")
        try:
            valid = inspect_run(repo, sha, workflow, run_id, script,
                                allow_missing=True)
        except (ValueError, subprocess.CalledProcessError, OSError, KeyError, TypeError) as exc:
            reject(f"invalid completed exact candidate scan {run_id}: {exc}")
        if valid is True:
            good += 1
        # False means an authenticated scheduled guard-only no-op.
        # None means authentic success whose original archives expired/vanished.

    if len(active) > 1:
        reject("ambiguous active exact-source CodeQL scans")
    if active and good:
        reject("ambiguous active and completed exact candidate scans")
    if good:
        print(f"Reused {good} independently verified same-source CodeQL run(s)", flush=True)
        return
    if active:
        selected = active[0]
        print(f"Joining active exact-source CodeQL {selected}", flush=True)
    else:
        gh("api", "-X", "POST", f"repos/{repo}/actions/workflows/codeql.yml/dispatches",
           "-f", "ref=main", "-f", f"inputs[candidate_sha]={sha}")
        selected = None
        print(f"Dispatched trusted full CodeQL for candidate {sha}", flush=True)

    deadline = time.monotonic() + 35 * 60
    while time.monotonic() < deadline:
        check_repo_sha(repo, sha)
        recent = run_candidates(repo, sha, workflow, script)
        exact_runs = [r for r in recent
                      if (r.get("event") == "workflow_dispatch"
                          and r.get("display_title") == f"CodeQL source {sha}")
                      or (r.get("event") == "schedule" and r.get("head_sha") == sha)]
        if any(r.get("run_attempt") != 1 for r in exact_runs):
            reject("ambiguous rerun attempt for exact candidate")
        if any(r.get("status") == "completed" and r.get("conclusion") != "success"
               for r in exact_runs):
            reject("failed exact candidate scan encountered while waiting")
        if selected is None:
            matches = [r for r in exact_runs if r.get("event") == "workflow_dispatch"
                       and r.get("id") not in before]
            if len(matches) > 1:
                reject("ambiguous auto-dispatched CodeQL runs")
            if matches:
                selected = matches[0]["id"]
        if selected is not None:
            matches = [r for r in exact_runs if r.get("id") == selected]
            if len(matches) != 1:
                reject(f"selected CodeQL run {selected} disappeared or became ambiguous")
            state = matches[0]
            if state.get("status") == "completed":
                if state.get("conclusion") != "success":
                    reject(f"CodeQL run {selected} ended {state.get('conclusion')}")
                if inspect_run(repo, sha, workflow, selected, script) is True:
                    return
                reject("CodeQL finished without complete original language evidence")
        time.sleep(15)
    reject(f"timed out waiting for exact-source CodeQL run {selected}" if selected
           else "timed out discovering auto-dispatched CodeQL run")


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
    probe("four SARIF plus four source-provenance", lambda r, w, j, a: a["artifacts"].pop())
    probe("wrong-SHA", lambda r, w, j, a: a["artifacts"][0]["workflow_run"].update(head_sha="b" * 40))
    probe("ambiguous", lambda r, w, j, a: a["artifacts"][1].update(expired=True))
    # Candidate ancestry: current main and a historical protected-main ancestor
    # are accepted; divergence is rejected fail-closed.
    for status in ("identical", "ahead"):
        with mock.patch.object(sys.modules[__name__], "api", return_value={
            "status": status,
            "base_commit": {"sha": sha},
            "merge_base_commit": {"sha": sha},
        }):
            check_repo_sha(repo, sha)
    with mock.patch.object(sys.modules[__name__], "api", return_value={
        "status": "diverged",
        "base_commit": {"sha": sha},
        "merge_base_commit": {"sha": "b" * 40},
    }):
        try:
            check_repo_sha(repo, sha)
        except ValueError as exc:
            assert "not proven reachable" in str(exc)
        else:
            raise AssertionError("diverged release candidate was accepted")
    # The successful guard-only scheduled workflow is an intentional no-op,
    # never evidence for publication even though GitHub reports SUCCESS.
    schedule = dict(run, event="schedule")
    skipped_jobs = {"jobs": [{"name": "CodeQL schedule guard", "conclusion": "success"}] + [
        {"name": f"Analyze ({lang})", "conclusion": "skipped"} for lang in LANGUAGES]}
    assert intentional_schedule_skip(schedule, skipped_jobs)
    assert not intentional_schedule_skip(run, skipped_jobs)
    assert not intentional_schedule_skip(schedule, jobs)
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp, "source-identity.json")
        manifest = {"schema": 1, "candidate_sha": sha, "checkout_sha": sha,
                    "event_sha": sha, "run_id": run["id"],
                    "run_attempt": 1, "language": "swift"}
        path.write_text(json.dumps(manifest), encoding="utf-8")
        verify_manifest(Path(tmp), repo, run, sha, "swift")
        for key, bad in (("candidate_sha", "b" * 40), ("checkout_sha", "b" * 40),
                         ("event_sha", "b" * 40), ("run_id", 10),
                         ("run_attempt", 2), ("language", "actions")):
            changed = dict(manifest, **{key: bad})
            path.write_text(json.dumps(changed), encoding="utf-8")
            try:
                verify_manifest(Path(tmp), repo, run, sha, "swift")
            except ValueError as exc:
                assert "provenance mismatch" in str(exc)
            else:
                raise AssertionError(f"accepted malformed source manifest {key}")
    # Offline preflight lifecycle: valid reuse, active join, automatic dispatch,
    # scanner failure and bounded timeout. No GitHub writes are performed.
    def candidate(state, conclusion=None):
        return {"id": 71, "workflow_id": 42,
                "path": ".github/workflows/codeql.yml",
                "event": "workflow_dispatch", "head_branch": "main",
                "head_repository": {"full_name": repo},
                "run_attempt": 1, "display_title": f"CodeQL source {sha}",
                "status": state, "conclusion": conclusion,
                "created_at": "2026-10-14T00:00:00Z"}

    def exercise(initial, later, should_dispatch, error=None):
        sources = [initial, later] if later is not None else [initial]
        source_sets = [[x] if x is not None else [] for x in sources]
        with (mock.patch.dict(os.environ, {"GH_TOKEN": "offline-fixture"}),
              mock.patch.object(sys.modules[__name__], "check_repo_sha"),
              mock.patch.object(sys.modules[__name__], "api", return_value={"id": 42}),
              mock.patch.object(sys.modules[__name__], "run_candidates",
                                side_effect=source_sets),
              mock.patch.object(sys.modules[__name__], "inspect_run", return_value=True) as inspect,
              mock.patch.object(sys.modules[__name__], "gh", return_value="") as dispatch,
              mock.patch.object(time, "sleep", return_value=None)):
            if error:
                try:
                    verify_live(repo, sha, Path("fake-verdict.py"))
                except ValueError as exc:
                    assert error in str(exc), str(exc)
                else:
                    raise AssertionError(f"expected lifecycle rejection: {error}")
            else:
                verify_live(repo, sha, Path("fake-verdict.py"))
                assert inspect.call_count == 1
            assert dispatch.called == should_dispatch

    exercise(candidate("completed", "success"), None, False)
    exercise(candidate("in_progress"), candidate("completed", "success"), False)
    exercise(None, candidate("completed", "success"), True)
    exercise(candidate("in_progress"), candidate("completed", "failure"), False, "ended failure")
    exercise(candidate("completed", "failure"), None, False, "ended failure")
    exercise(dict(candidate("completed", "success"), run_attempt=2), None,
             False, "ambiguous rerun")
    with (mock.patch.dict(os.environ, {"GH_TOKEN": "offline-fixture"}),
          mock.patch.object(sys.modules[__name__], "check_repo_sha"),
          mock.patch.object(sys.modules[__name__], "api", return_value={"id": 42}),
          mock.patch.object(sys.modules[__name__], "run_candidates", return_value=[]),
          mock.patch.object(sys.modules[__name__], "gh", return_value=""),
          mock.patch.object(time, "monotonic", side_effect=[0, 3600])):
        try:
            verify_live(repo, sha, Path("fake-verdict.py"))
        except ValueError as exc:
            assert "timed out" in str(exc)
        else:
            raise AssertionError("bounded scan timeout did not fail closed")
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
