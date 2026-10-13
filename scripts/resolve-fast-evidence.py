#!/usr/bin/env python3
"""Resolve reusable exact-SHA Fast CI evidence for ready-for-review validation.

The resolver is intentionally executed from the protected base revision rather
than from PR-controlled contents. Reuse is an optimization only: unavailable,
cancelled, or workflow-mismatched evidence falls back to local Final checks.
A completed non-success producer remains a hard failure so a deterministic Fast
failure cannot be hidden by the ready-for-review transition.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Any

WORKFLOW_PATH = ".github/workflows/ci.yml"
DEFAULT_ATTEMPTS = 60
DEFAULT_SLEEP_SECONDS = 5.0


class EvidenceFailure(RuntimeError):
    """A completed producer proved that reusable evidence is unsafe."""


class EvidenceUnavailable(RuntimeError):
    """The GitHub API could not establish reusable evidence."""


@dataclass(frozen=True)
class RunDecision:
    action: str
    reason: str


def _api_json(endpoint: str) -> dict[str, Any]:
    completed = subprocess.run(
        [
            "gh",
            "api",
            "-H",
            "Accept: application/vnd.github+json",
            endpoint,
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or f"gh api exited {completed.returncode}"
        raise EvidenceUnavailable(detail)
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise EvidenceUnavailable(f"GitHub API returned invalid JSON: {error}") from error
    if not isinstance(payload, dict):
        raise EvidenceUnavailable("GitHub API returned an unexpected payload type")
    return payload


def workflow_blob_sha(repository: str, ref: str) -> str:
    payload = _api_json(f"repos/{repository}/contents/{WORKFLOW_PATH}?ref={ref}")
    value = payload.get("sha")
    if not isinstance(value, str) or not value:
        raise EvidenceUnavailable(f"Could not read {WORKFLOW_PATH} blob SHA at {ref}")
    return value


def select_latest_run(
    payload: dict[str, Any], expected_sha: str, current_run_id: str
) -> dict[str, Any] | None:
    runs = payload.get("workflow_runs")
    if not isinstance(runs, list):
        raise EvidenceUnavailable("Workflow-runs response has no workflow_runs array")

    candidates: list[dict[str, Any]] = []
    for run in runs:
        if not isinstance(run, dict):
            continue
        if run.get("head_sha") != expected_sha or run.get("event") != "pull_request":
            continue
        if str(run.get("id")) == current_run_id:
            continue
        candidates.append(run)

    if not candidates:
        return None

    try:
        return max(candidates, key=lambda run: int(run["id"]))
    except (KeyError, TypeError, ValueError) as error:
        raise EvidenceUnavailable("Workflow-runs response contains an invalid run id") from error


def classify_run(run: dict[str, Any]) -> RunDecision:
    status = str(run.get("status") or "")
    conclusion = str(run.get("conclusion") or "")

    if status != "completed":
        return RunDecision("wait", f"producer status is {status or 'unknown'}")
    if conclusion == "success":
        return RunDecision("inspect-jobs", "producer completed successfully")
    if conclusion == "cancelled":
        return RunDecision(
            "fallback",
            "producer was cancelled; Final must execute local Fast checks",
        )
    return RunDecision(
        "fail",
        f"producer completed with non-success conclusion {conclusion or 'unknown'}",
    )


def validate_expected_job(payload: dict[str, Any], expected_job: str) -> None:
    jobs = payload.get("jobs")
    if not isinstance(jobs, list):
        raise EvidenceUnavailable("Workflow-jobs response has no jobs array")

    matches = [
        job
        for job in jobs
        if isinstance(job, dict) and job.get("name") == expected_job
    ]
    if len(matches) != 1:
        raise EvidenceFailure(
            f"Canonical run must contain exactly one '{expected_job}' job; "
            f"found {len(matches)}."
        )

    job = matches[0]
    status = str(job.get("status") or "")
    conclusion = str(job.get("conclusion") or "")
    if status != "completed" or conclusion != "success":
        raise EvidenceFailure(
            f"Canonical '{expected_job}' evidence is "
            f"status={status or 'unknown'} conclusion={conclusion or 'unknown'}."
        )


def _emit_reuse(reuse: bool) -> None:
    value = "true" if reuse else "false"
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as stream:
            stream.write(f"reuse={value}\n")
    else:
        print(f"reuse={value}")


def _fallback(message: str) -> int:
    _emit_reuse(False)
    print(message)
    return 0


def resolve() -> int:
    repository = os.environ["GITHUB_REPOSITORY"]
    base_sha = os.environ["BASE_SHA"]
    expected_sha = os.environ["EXPECTED_SHA"]
    expected_job = os.environ["EXPECTED_JOB"]
    current_run_id = os.environ["GITHUB_RUN_ID"]

    if os.environ.get("SAME_REPOSITORY") != "true":
        return _fallback(
            "Fork PR cannot reuse base-repository workflow evidence; "
            "Final will execute the local Fast checks."
        )

    try:
        base_workflow_sha = workflow_blob_sha(repository, base_sha)
        head_workflow_sha = workflow_blob_sha(repository, expected_sha)
    except EvidenceUnavailable as error:
        return _fallback(
            f"Could not establish trusted workflow identity ({error}); "
            "Final will execute the local Fast checks."
        )

    if base_workflow_sha != head_workflow_sha:
        return _fallback(
            "Fast producer workflow changed on this PR; Final will execute "
            "the local Fast checks instead of trusting self-modified evidence."
        )

    attempts = int(os.environ.get("FAST_EVIDENCE_MAX_ATTEMPTS", DEFAULT_ATTEMPTS))
    sleep_seconds = float(
        os.environ.get("FAST_EVIDENCE_SLEEP_SECONDS", DEFAULT_SLEEP_SECONDS)
    )
    runs_endpoint = (
        f"repos/{repository}/actions/workflows/ci.yml/runs"
        f"?event=pull_request&head_sha={expected_sha}&per_page=100"
    )

    for attempt in range(attempts):
        try:
            runs_payload = _api_json(runs_endpoint)
            latest = select_latest_run(runs_payload, expected_sha, current_run_id)
        except EvidenceUnavailable as error:
            return _fallback(
                f"Could not establish reusable exact-SHA evidence ({error}); "
                "Final will execute the local Fast checks."
            )

        if latest is None:
            if attempt + 1 < attempts:
                time.sleep(sleep_seconds)
                continue
            return _fallback(
                f"No completed reusable ci.yml producer appeared for exact HEAD "
                f"{expected_sha}; Final will execute the local Fast checks."
            )

        decision = classify_run(latest)
        if decision.action == "wait":
            if attempt + 1 < attempts:
                time.sleep(sleep_seconds)
                continue
            return _fallback(
                f"Canonical ci.yml producer for exact HEAD {expected_sha} did not "
                "complete in the reuse window; Final will execute the local Fast checks."
            )

        run_id = latest.get("id")
        conclusion = str(latest.get("conclusion") or "")

        if decision.action == "fallback":
            return _fallback(
                f"Canonical ci.yml producer {run_id} for exact HEAD {expected_sha} "
                "was cancelled; treating it as unavailable evidence and executing "
                "the local Fast checks."
            )

        if decision.action == "fail":
            raise EvidenceFailure(
                f"Canonical ci.yml workflow for exact HEAD {expected_sha} "
                f"concluded '{conclusion or 'unknown'}'; refusing failed evidence."
            )

        try:
            jobs_payload = _api_json(
                f"repos/{repository}/actions/runs/{run_id}/jobs?filter=latest&per_page=100"
            )
            validate_expected_job(jobs_payload, expected_job)
        except EvidenceUnavailable as error:
            return _fallback(
                f"Could not establish reusable '{expected_job}' evidence ({error}); "
                "Final will execute the local Fast checks."
            )

        _emit_reuse(True)
        print(
            f"Reusing canonical successful '{expected_job}' evidence "
            f"for exact HEAD {expected_sha} from run {run_id}."
        )
        return 0

    raise AssertionError("unreachable")


def main() -> int:
    try:
        return resolve()
    except EvidenceFailure as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    except (KeyError, ValueError) as error:
        print(f"::error::Fast evidence resolver configuration error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
