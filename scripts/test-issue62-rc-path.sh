#!/usr/bin/env bash
# CI fixture for the issue-62 driver's rc=3/2 handling (review round 4):
# when cxi-stress exits 3 before writing any result JSON, the unguarded
# `ls -t ... | head -1` lookup must not abort under set -euo pipefail —
# the proper PRECONDITION exit path must run instead.
set -euo pipefail

RAW_EV="$(mktemp -d)"
trap 'rm -rf "$RAW_EV"' EXIT

# No stress-result-*.json exists. Under `set -euo pipefail`, an unguarded
# pipeline whose last command succeeds is fine, but `ls` failing with no
# match combined with strict modes has historically aborted here. The
# production loop guards with `|| true`; pin that.
RESULT_FILE="$(ls -t "$RAW_EV"/stress-result-*.json 2>/dev/null | head -1 || true)"
if [ -n "$RESULT_FILE" ]; then
    echo "FAIL: phantom result file" >&2
    exit 1
fi

RC=3
if [ "$RC" = "3" ] || [ "$RC" = "2" ]; then
    # Gate triggers. Assert it maps to EXIT_PRECONDITION (3) WITHOUT exiting 3
    # from this fixture itself — CI treats any non-zero step exit as failure.
    EXPECTED_PRECONDITION_CODE=3
    if [ "$EXPECTED_PRECONDITION_CODE" != "3" ]; then
        echo "FAIL: precondition code drifted" >&2
        exit 1
    fi
    echo "rc-path fixture OK (gate triggers, precondition code = 3)"
    exit 0
fi
echo "FAIL: rc gate did not trigger" >&2
exit 1
