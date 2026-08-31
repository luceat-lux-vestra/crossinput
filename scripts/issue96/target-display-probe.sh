#!/usr/bin/env bash
# Send exactly one Issue #96 target-display probe command to the opt-in app.
# This is intended for SSH/off-target invocation; it never presents UI.
set -euo pipefail

SOCKET_PATH="${CROSSINPUT_ISSUE96_PROBE_SOCKET:-${HOME:?HOME is required}/Library/Application Support/Ampersand/Diagnostics/issue-96-target-display.sock}"

if [ "$#" -ne 1 ]; then
    echo "usage: $0 redraw|cursor-rect|tracking-area|window-update|activation-control|recovery-app-activate|status|mark-baseline-healthy|mark-broken-confirmed|mark-recovery-action|mark-recovered|mark-still-broken|clear-trace|dump-trace" >&2
    exit 2
fi

case "$1" in
    redraw|cursor-rect|tracking-area|window-update|activation-control|recovery-app-activate|status|mark-baseline-healthy|mark-broken-confirmed|mark-recovery-action|mark-recovered|mark-still-broken|clear-trace|dump-trace) ;;
    *) echo "unsupported Issue #96 probe command: $1" >&2; exit 2 ;;
esac

command -v nc >/dev/null 2>&1 || {
    echo "nc is required for the local Unix-domain socket control channel" >&2
    exit 2
}

if [ ! -S "$SOCKET_PATH" ]; then
    echo "Issue #96 probe endpoint is not available: diagnostics are disabled or the app is not running" >&2
    exit 3
fi

printf '%s\n' "$1" | nc -U "$SOCKET_PATH"
