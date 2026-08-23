#!/usr/bin/env bash
# Static privacy guard: no input payloads in helper sources or logs.
#
# Enforces AGENTS.md rule 4 — never log keystrokes, clipboard contents, or
# HID/input report payloads. CI runs this instead of an inline `rg` call: a
# missing scanner binary inside an `if` silently passed the check (false-green,
# issue #60). This script fails closed:
#
#   1. The scanning tool must exist, or the guard FAILS.
#   2. A self-test plants one file per forbidden-pattern alternative and
#      requires every planted violation to be detected; any miss means the
#      guard itself is broken and the run FAILS.
#   3. Benign control lines must NOT match (guards against an over-broad
#      pattern that would make the scan meaningless).
#   4. Only then is the real tree scanned; any hit FAILS the run.
#
# Usage:
#   scripts/check-log-guard.sh [path ...]     # default: android/helper/app/src/main
set -euo pipefail

if ! command -v grep >/dev/null 2>&1; then
    echo "log guard broken: scanning tool 'grep' is not available" >&2
    exit 1
fi

PATTERN='keyCode=.*event\.keyCode|keyCode=\$\{|HID report.*payload'

scan() {
    grep -RInE -- "$PATTERN" "$@" 2>/dev/null
}

self_test_dir="$(mktemp -d)"
trap 'rm -rf "$self_test_dir"' EXIT

# One planted violation per pattern alternative (issue #60 regression).
printf 'Log.d(TAG, "keyCode=" + event.keyCode)\n' >"$self_test_dir/a.kt"
printf 'log("keyCode=${event.keyCode}")\n' >"$self_test_dir/b.kt"
printf '// HID report payload bytes must never be logged\n' >"$self_test_dir/c.kt"
# Benign metadata-only log lines that must stay allowed.
printf '[HidDeviceManager] report sent id=1 len=5\n' >"$self_test_dir/ok.kt"

for planted in a b c; do
    if ! scan "$self_test_dir/$planted.kt" | grep -q .; then
        echo "log guard broken: planted violation was NOT detected ($planted.kt)" >&2
        exit 1
    fi
done

if [ -n "$(scan "$self_test_dir/ok.kt" || true)" ]; then
    echo "log guard broken: benign control line matched the forbidden pattern" >&2
    exit 1
fi

targets=("$@")
if [ "${#targets[@]}" -eq 0 ]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    targets=("$root/android/helper/app/src/main")
fi

violations="$(scan "${targets[@]}" || true)"
if [ -n "$violations" ]; then
    echo "$violations"
    echo "Forbidden: key/event payload appears in Android helper logging" >&2
    exit 1
fi

echo "log guard ok (self-test + scan clean): ${targets[*]}"
