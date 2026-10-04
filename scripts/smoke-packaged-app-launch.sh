#!/usr/bin/env bash
set -euo pipefail

APP="${1:-dist/Ampersand.app}"
BIN="$APP/Contents/MacOS/Ampersand"

if [ ! -x "$BIN" ]; then
  echo "ERROR: packaged app executable is missing or not executable: $BIN" >&2
  exit 1
fi

LOG="$(mktemp)"
PID=""

cleanup() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -f "$LOG"
}
trap cleanup EXIT INT TERM

"$BIN" >"$LOG" 2>&1 &
PID="$!"

# dyld/link failures and immediate startup crashes occur before this boundary.
sleep 3

if ! kill -0 "$PID" 2>/dev/null; then
  set +e
  wait "$PID"
  STATUS="$?"
  set -e
  echo "ERROR: packaged app exited during launch smoke (status=$STATUS)" >&2
  if [ -s "$LOG" ]; then
    cat "$LOG" >&2
  fi
  exit 1
fi

echo "packaged app launch smoke: process survived startup window"
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
PID=""
