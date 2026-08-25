#!/usr/bin/env python3
"""CI fixture for the issue-62 evidence aggregator.

Extracts the embedded python aggregation block from
scripts/verify-device-issue62.sh and runs it against synthetic raw evidence.
Catches NameErrors / schema regressions in the summary pipeline at CI time —
the same class of defect that previously only surfaced on a real device after
all workload profiles had already run.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "verify-device-issue62.sh")

FIXTURE = {
    "latencySamples": [0.01 + i * 0.0001 for i in range(100)],
    "requests": 100,
    "successes": 100,
    "timeouts": 0,
    "lateResponses": 0,
    "acceptedAsNewBatch": 8,
    "coalescedIntoExistingBatch": 92,
    "shedLocally": 0,
    "safetyRejected": 0,
}


def main() -> int:
    with open(SCRIPT) as f:
        script = f.read()
    match = re.search(r"<<'PYEOF'\n(.*?)\nPYEOF", script, re.S)
    if not match:
        print("FAIL: aggregator heredoc not found in verify-device-issue62.sh",
              file=sys.stderr)
        return 1
    body = match.group(1)

    with tempfile.TemporaryDirectory() as raw_dir:
        with open(os.path.join(raw_dir, "latency-scroll-burst.json"), "w") as f:
            json.dump(FIXTURE, f)
        # Tiny dataset (5 samples): percentiles MUST be null — a fabricated
        # percentile from a tiny dataset is exactly what the guard prevents.
        tiny = dict(FIXTURE, latencySamples=[0.01, 0.02, 0.03, 0.04, 0.05])
        with open(os.path.join(raw_dir, "latency-baseline.json"), "w") as f:
            json.dump(tiny, f)
        result = subprocess.run(["python3", "-", raw_dir], input=body,
                                capture_output=True, text=True)
        if result.returncode != 0:
            print("FAIL: aggregator exited non-zero", file=sys.stderr)
            print(result.stderr, file=sys.stderr)
            return 1
        with open(os.path.join(raw_dir, "latency-summary.json")) as f:
            summary = json.load(f)

    profile = summary.get("profiles", {}).get("scroll-burst")
    tiny_profile = summary.get("profiles", {}).get("baseline")
    if profile is None:
        print("FAIL: scroll-burst missing from summary", file=sys.stderr)
        return 1

    checks = [
        ("p50", lambda v: v is not None and abs(v - 0.0149) < 0.001),
        ("p99", lambda v: v is not None and abs(v - 0.0199) < 0.001),
        ("admission_coalesced", lambda v: v == 92),
        ("requests", lambda v: v == 100),
        ("timeouts", lambda v: v == 0),
    ]
    failed = False
    for key, ok in checks:
        if not ok(profile.get(key)):
            print(f"FAIL: {key} = {profile.get(key)!r}", file=sys.stderr)
            failed = True
    # Minimum-sample guard on the REAL tiny dataset (5 samples): all
    # percentiles and threshold counts must be null.
    if tiny_profile is None or tiny_profile["p50"] is not None \
            or tiny_profile["p99"] is not None or tiny_profile["over_250ms"] is not None:
        print(f"FAIL: tiny dataset produced non-null statistics: {tiny_profile}",
              file=sys.stderr)
        failed = True
    if failed:
        return 1
    print("aggregator fixture OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
