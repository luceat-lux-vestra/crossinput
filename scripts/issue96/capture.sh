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
    require_command git
    require_command pgrep
    require_command ps
    require_command swiftc
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
    mkdir -p "$run_dir/raw" "$run_dir/snapshots" "$run_dir/bin"

    local compile_log="$run_dir/raw/helper-compile.log"
    : >"$compile_log"
    if ! swiftc -o "$run_dir/bin/state_snapshot" "$SCRIPT_DIR/state_snapshot.swift" >>"$compile_log" 2>&1; then
        die "state_snapshot helper compilation failed; see $compile_log"
    fi
    if ! swiftc -o "$run_dir/bin/workspace_observer" "$SCRIPT_DIR/workspace_observer.swift" >>"$compile_log" 2>&1; then
        die "workspace_observer helper compilation failed; see $compile_log"
    fi
    if ! swiftc -o "$run_dir/bin/crossinput_identity" "$SCRIPT_DIR/crossinput_identity.swift" >>"$compile_log" 2>&1; then
        die "crossinput_identity helper compilation failed; see $compile_log"
    fi

    if ! "$run_dir/bin/crossinput_identity" >"$run_dir/crossinput-build-identity.json" 2>"$run_dir/raw/crossinput-identity.stderr"; then
        die "no unambiguous running Ampersand/CrossInput application identity was found; see $run_dir/raw/crossinput-identity.stderr"
    fi

    python3 - "$run_dir/run.json" "$run_id" "$REPO_ROOT" "$run_dir/crossinput-build-identity.json" "$run_dir/bin" "${ISSUE96_INCLUDE_HIDUTIL:-0}" <<'PY'
import datetime as dt
import hashlib
import json
import os
import subprocess
import sys
import time

path, run_id, repo, identity_path, helper_dir, include_hidutil = sys.argv[1:]
now = time.time_ns()
stamp = dt.datetime.fromtimestamp(now / 1_000_000_000, dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
try:
    harness_source_sha = subprocess.check_output(["git", "-C", repo, "rev-parse", "HEAD"], text=True).strip()
    harness_dirty = bool(subprocess.check_output(["git", "-C", repo, "status", "--porcelain"], text=True).strip())
except (OSError, subprocess.CalledProcessError):
    harness_source_sha = "unknown"
    harness_dirty = True
try:
    macos = subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip()
except (OSError, subprocess.CalledProcessError):
    macos = "unknown"
try:
    with open(identity_path, encoding="utf-8") as fh:
        crossinput_identity = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"invalid CrossInput build identity metadata: {exc}")
if not isinstance(crossinput_identity, dict) or crossinput_identity.get("resolved") is not True:
    raise SystemExit("CrossInput build identity is unresolved")
helpers = {}
for name in ("state_snapshot", "workspace_observer"):
    helper = os.path.join(helper_dir, name)
    with open(helper, "rb") as fh:
        helpers[name] = {
            "path": os.path.relpath(helper, os.path.dirname(path)),
            "sha256": hashlib.sha256(fh.read()).hexdigest(),
        }
data = {
    "schema": 2,
    "run_id": run_id,
    "started_at_utc": stamp,
    "started_epoch_ns": now,
    "harness_source_sha": harness_source_sha,
    "harness_worktree_clean": not harness_dirty,
    "crossinput_build_identity": crossinput_identity,
    "evidence_mode": {"include_hidutil": include_hidutil == "1"},
    "helpers": helpers,
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
    "$run_dir/bin/workspace_observer" >"$run_dir/raw/workspace-events.jsonl" 2>"$run_dir/raw/workspace-observer.stderr" &
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
        *"lifecycle_monitor.py"*|*"unified_capture.py"*|*"workspace_observer"*) return 0 ;;
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
    local stop_requested_utc
    stop_requested_utc="$(date -u '+%Y-%m-%dT%H:%M:%S.%NZ')"
    printf 'stop_requested_utc=%s\n' "$stop_requested_utc" >>"$run_dir/raw/capture-stop.log"
    local initial_missing=0 term_failures=0
    for pid in "$LIFECYCLE_PID" "$UNIFIED_PID" "$WORKSPACE_PID"; do
        if is_pid_alive "$pid"; then
            if kill "$pid" 2>>"$run_dir/raw/capture-stop.log"; then
                :
            else
                term_failures=$((term_failures + 1))
            fi
        else
            initial_missing=1
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
    local forced_kill=0
    if [ "$alive" -ne 0 ]; then
        forced_kill=1
        echo "term_timeout=true" >>"$run_dir/raw/capture-stop.log"
        for pid in "$LIFECYCLE_PID" "$UNIFIED_PID" "$WORKSPACE_PID"; do
            if is_pid_alive "$pid" && validated_command_for_pid "$pid"; then
                kill -KILL "$pid" 2>>"$run_dir/raw/capture-stop.log" || true
            fi
        done
    fi
    local remaining_pids=""
    for pid in "$LIFECYCLE_PID" "$UNIFIED_PID" "$WORKSPACE_PID"; do
        if is_pid_alive "$pid"; then
            remaining_pids="${remaining_pids}${remaining_pids:+,}$pid"
        fi
    done
    python3 - "$run_dir/run.json" "$stop_requested_utc" "$initial_missing" "$term_failures" "$forced_kill" "$remaining_pids" <<'PY'
import datetime as dt
import json
import sys
path, requested_at, initial_missing, term_failures, forced_kill, remaining_pids = sys.argv[1:]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
clean = (initial_missing == "0" and term_failures == "0" and forced_kill == "0" and not remaining_pids)
data["state"] = "stopped" if not remaining_pids else "cleanup_incomplete"
data["stopped_at_utc"] = dt.datetime.now(dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
data["shutdown"] = {
    "requested": True,
    "requested_at_utc": requested_at,
    "clean": clean,
    "forced_kill": forced_kill == "1",
    "term_timeout_seconds": 5,
    "remaining_pids": [int(value) for value in remaining_pids.split(",") if value],
}
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
