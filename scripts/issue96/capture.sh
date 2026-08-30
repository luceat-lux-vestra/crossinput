#!/usr/bin/env bash
# Issue #96 bounded, observation-only capture lifecycle.
#
# Usage:
#   capture.sh start [run-id]
#   capture.sh stop [run-directory]
#
# The default evidence directory is outside the repository. Override it with
# ISSUE96_RUNS_DIR when a different local evidence location is required.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNS_DIR="${ISSUE96_RUNS_DIR:-${HOME:?HOME is required}/Library/Logs/CrossInput/issue96}"
ACTIVE_FILE="$RUNS_DIR/active-run"

die() { echo "issue96 capture: $*" >&2; exit 2; }

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command unavailable: $1"
}

valid_run_id() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

next_run_id() {
    local n=1 candidate
    while :; do
        candidate="run-$(printf '%03d' "$n")"
        [ ! -e "$RUNS_DIR/$candidate" ] && { printf '%s\n' "$candidate"; return; }
        n=$((n + 1))
    done
}

is_pid_alive() {
    case "$1" in
        ''|*[!0-9]*|0|1) return 1 ;;
    esac
    kill -0 "$1" >/dev/null 2>&1
}

read_active_run() {
    [ -f "$ACTIVE_FILE" ] || return 1
    local run
    run="$(<"$ACTIVE_FILE")"
    [ -n "$run" ] || return 1
    printf '%s\n' "$run"
}

valid_run_path() {
    case "$1" in
        "$RUNS_DIR"/*) return 0 ;;
        *) return 1 ;;
    esac
}

start_capture() {
    require_command python3
    [ -x /usr/bin/log ] || die "required command unavailable: /usr/bin/log"
    require_command pgrep
    require_command ps
    require_command swift
    require_command ioreg
    require_command launchctl
    require_command sw_vers
    mkdir -p "$RUNS_DIR"

    if active_run="$(read_active_run 2>/dev/null)"; then
        if [ -f "$active_run/pids.env" ]; then
            # shellcheck disable=SC1090
            # shellcheck disable=SC1091
            source "$active_run/pids.env"
            if { is_pid_alive "${UNIFIED_PID:-0}" || is_pid_alive "${LIFECYCLE_PID:-0}" || is_pid_alive "${WORKSPACE_PID:-0}"; }; then
                die "capture already running: $active_run"
            fi
        fi
        die "stale active-run marker remains: $ACTIVE_FILE; inspect and remove it only after confirming no capture process is alive"
    fi

    local run_id="${1:-$(next_run_id)}"
    valid_run_id "$run_id" || die "invalid run id: $run_id"
    local run_dir="$RUNS_DIR/$run_id"
    [ ! -e "$run_dir" ] || die "run already exists: $run_dir"
    mkdir -p "$run_dir/raw" "$run_dir/snapshots"

    python3 - "$run_dir/run.json" "$run_id" "$REPO_ROOT" <<'PY'
import datetime as dt
import json
import os
import subprocess
import sys
import time

path, run_id, repo = sys.argv[1:]
now = time.time_ns()
stamp = dt.datetime.fromtimestamp(now / 1_000_000_000, dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
try:
    source_sha = subprocess.check_output(["git", "-C", repo, "rev-parse", "HEAD"], text=True).strip()
except (OSError, subprocess.CalledProcessError):
    source_sha = "unknown"
try:
    macos = subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip()
except (OSError, subprocess.CalledProcessError):
    macos = "unknown"
data = {
    "schema": 1,
    "run_id": run_id,
    "started_at_utc": stamp,
    "started_epoch_ns": now,
    "source_sha": source_sha,
    "macos_product_version": macos,
    "state": "starting",
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

    python3 "$SCRIPT_DIR/lifecycle_monitor.py" "$run_dir" >"$run_dir/raw/lifecycle-monitor.stdout" 2>"$run_dir/raw/lifecycle-monitor.stderr" &
    local lifecycle_pid=$!
    python3 "$SCRIPT_DIR/unified_capture.py" "$run_dir" >"$run_dir/raw/unified-capture.stdout" 2>"$run_dir/raw/unified-capture.stderr" &
    local unified_pid=$!
    swift "$SCRIPT_DIR/workspace_observer.swift" >"$run_dir/raw/workspace-events.jsonl" 2>"$run_dir/raw/workspace-observer.stderr" &
    local workspace_pid=$!

    sleep 0.4
    if ! is_pid_alive "$lifecycle_pid" || ! is_pid_alive "$unified_pid" || ! is_pid_alive "$workspace_pid"; then
        kill "$lifecycle_pid" "$unified_pid" "$workspace_pid" 2>/dev/null || true
        die "one or more capture processes exited during startup; see $run_dir/raw"
    fi

    cat >"$run_dir/pids.env" <<EOF
LIFECYCLE_PID=$lifecycle_pid
UNIFIED_PID=$unified_pid
WORKSPACE_PID=$workspace_pid
EOF
    python3 - "$run_dir/run.json" "$lifecycle_pid" "$unified_pid" "$workspace_pid" <<'PY'
import json
import sys
path, lifecycle, unified, workspace = sys.argv[1:]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data.update({
    "state": "running",
    "lifecycle_pid": int(lifecycle),
    "unified_pid": int(unified),
    "workspace_pid": int(workspace),
})
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
    local active_tmp="$ACTIVE_FILE.$$"
    printf '%s\n' "$run_dir" >"$active_tmp"
    mv "$active_tmp" "$ACTIVE_FILE"
    echo "capture started: $run_dir"
}

validated_command_for_pid() {
    local pid="$1" command_line
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$command_line" in
        *"lifecycle_monitor.py"*|*"unified_capture.py"*|*"workspace_observer.swift"*) return 0 ;;
        *) return 1 ;;
    esac
}

stop_capture() {
    local run_dir="${1:-$(read_active_run 2>/dev/null || true)}"
    [ -n "$run_dir" ] || die "no active capture; pass a run directory to stop"
    valid_run_path "$run_dir" || die "refusing run directory outside ISSUE96_RUNS_DIR: $run_dir"
    [ -f "$run_dir/pids.env" ] || die "missing PID manifest: $run_dir/pids.env"
    # shellcheck disable=SC1090,SC1091
    source "$run_dir/pids.env"
    local pid
    for pid in "$LIFECYCLE_PID" "$UNIFIED_PID" "$WORKSPACE_PID"; do
        if is_pid_alive "$pid" && ! validated_command_for_pid "$pid"; then
            die "refusing to signal unexpected process PID $pid; inspect $run_dir/pids.env"
        fi
    done
    : >"$run_dir/raw/capture-stop.log"
    printf 'stop_requested_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%S.%NZ')" >>"$run_dir/raw/capture-stop.log"
    for pid in "$LIFECYCLE_PID" "$UNIFIED_PID" "$WORKSPACE_PID"; do
        if is_pid_alive "$pid"; then
            kill "$pid" 2>>"$run_dir/raw/capture-stop.log" || true
        fi
    done

    local deadline=$((SECONDS + 5)) alive=0
    while [ "$SECONDS" -lt "$deadline" ]; do
        alive=0
        for pid in "$LIFECYCLE_PID" "$UNIFIED_PID" "$WORKSPACE_PID"; do
            is_pid_alive "$pid" && alive=1
        done
        [ "$alive" -eq 0 ] && break
        sleep 0.2
    done
    if [ "$alive" -ne 0 ]; then
        echo "term_timeout=true" >>"$run_dir/raw/capture-stop.log"
        for pid in "$LIFECYCLE_PID" "$UNIFIED_PID" "$WORKSPACE_PID"; do
            if is_pid_alive "$pid" && validated_command_for_pid "$pid"; then
                kill -KILL "$pid" 2>>"$run_dir/raw/capture-stop.log" || true
            fi
        done
    fi
    python3 - "$run_dir/run.json" <<'PY'
import datetime as dt
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data["state"] = "stopped"
data["stopped_at_utc"] = dt.datetime.now(dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
    if [ -f "$ACTIVE_FILE" ] && [ "$(<"$ACTIVE_FILE")" = "$run_dir" ]; then
        rm -f "$ACTIVE_FILE"
    fi
    echo "capture stopped: $run_dir"
    [ "$alive" -eq 0 ] || exit 3
}

case "${1:-}" in
    start) start_capture "${2:-}" ;;
    stop) stop_capture "${2:-}" ;;
    *) die "usage: capture.sh start [run-id] | capture.sh stop [run-directory]" ;;
esac
