#!/usr/bin/env bash
# Bounded, read-only Issue #96 state snapshot.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS_DIR="${ISSUE96_RUNS_DIR:-${HOME:?HOME is required}/Library/Logs/CrossInput/issue96}"
ACTIVE_FILE="$RUNS_DIR/active-run"

die() { echo "issue96 snapshot: $*" >&2; exit 2; }
[ $# -eq 1 ] || die "usage: snapshot.sh healthy|broken|recovered"
label="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
case "$label" in healthy|broken|recovered) ;; *) die "invalid snapshot label: $1" ;; esac
[ -f "$ACTIVE_FILE" ] || die "no active capture; run capture.sh start first"
run_dir="$(<"$ACTIVE_FILE")"
[ -f "$run_dir/run.json" ] || die "active run metadata is missing: $run_dir/run.json"

python3 - "$run_dir/markers.jsonl" "$label" <<'PY'
import json
import sys
path, wanted = sys.argv[1:]
try:
    values = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"cannot read markers: {exc}")
if not any(value.get("marker") == wanted for value in values):
    raise SystemExit(f"mark {wanted} before taking its snapshot")
PY

index=1
while :; do
    snapshot_dir="$run_dir/snapshots/$(printf '%03d' "$index")-$label"
    [ ! -e "$snapshot_dir" ] && break
    index=$((index + 1))
done
mkdir "$snapshot_dir"
manifest="$snapshot_dir/commands.tsv"
: >"$manifest"
failures=0

record_command() {
    local name="$1" required="$2" output="$3"
    shift 3
    local status=ok
    if ! "$@" >"$snapshot_dir/$output" 2>"$snapshot_dir/$output.stderr"; then
        status=failed
        failures=$((failures + 1))
    fi
    printf '%s\t%s\t%s\n' "$required" "$name" "$status" >>"$manifest"
}

record_systemui_process() {
    local pids
    pids="$(pgrep -x SystemUIServer 2>/dev/null || true)"
    [ -n "$pids" ] || return 1
    local pid
    while read -r pid; do
        [ -n "$pid" ] || continue
        ps -p "$pid" -o pid=,ppid=,comm=
    done <<<"$pids"
}

record_hid_registry() {
    local class="$1"
    ioreg -r -c "$class" -l -w 0 | awk '
        /(^|[+| -])+-o / { line=$0; sub(/<class.*$/, "", line); print line }
        /"(Transport|VendorID|ProductID|LocationID|PrimaryUsagePage|PrimaryUsage|Built-in|BuiltIn|IOHIDVirtualDevice|Product|Manufacturer|IORegistryEntryID|RegistryEntryID)"[[:space:]]*=/ { print }
    '
}

record_launchctl() {
    local domain label
    domain="gui/$(id -u)"
    for label in com.apple.SystemUIServer.agent com.apple.SystemUIServer com.apple.systemuiserver.agent; do
        if launchctl print "$domain/$label" 2>/dev/null | awk '
            /state =|pid =|program =|path =|active count|last exit|service name/ { print }
        '; then
            return 0
        fi
    done
    return 1
}

record_ampersand_diag() {
    local source="${CROSSINPUT_DIAG_LOG:-${HOME:?HOME is required}/Library/Logs/Ampersand/diag.log}"
    [ -f "$source" ] || return 0
    # Existing CrossInput diagnostics are metadata-only by contract; retain
    # only lifecycle/cursor/display lines for bounded correlation.
    tail -n 500 "$source" | awk '/candidate identity|handoff transition|suppression |cursor |display |lifecycle|external-control|watchdog|remoteUnavailable/ { print }'
}

record_hidutil() {
    if [ "${ISSUE96_INCLUDE_HIDUTIL:-0}" = "1" ]; then
        hidutil list
    else
        echo "not_requested=true"
        echo "enable_with=ISSUE96_INCLUDE_HIDUTIL=1"
    fi
}

record_command "systemuiserver_process" required systemuiserver-process.txt record_systemui_process
record_command "hidutil_list" optional hidutil-list.txt record_hidutil
record_command "iohid_device_registry" required iohid-device-registry.txt record_hid_registry IOHIDDevice
record_command "iohid_event_system" required iohid-event-system.txt record_hid_registry IOHIDEventSystem
record_command "iohid_event_system_client" required iohid-event-system-client.txt record_hid_registry IOHIDEventSystemClient
record_command "iohid_event_service" required iohid-event-service.txt record_hid_registry IOHIDEventService
record_command "display_workspace_accessibility" required display-workspace.json swift "$SCRIPT_DIR/state_snapshot.swift"
record_command "systemui_launchctl_state" required systemuiserver-service.txt record_launchctl
record_command "ampersand_metadata_diag" optional ampersand-diag.filtered.log record_ampersand_diag

python3 - "$snapshot_dir/snapshot.meta.json" "$run_dir" "$label" "$failures" "$manifest" <<'PY'
import datetime as dt
import json
import pathlib
import sys
import time

out, run_dir, label, failures, manifest = sys.argv[1:]
with open(pathlib.Path(run_dir) / "run.json", encoding="utf-8") as fh:
    run = json.load(fh)
commands = []
for line in pathlib.Path(manifest).read_text(encoding="utf-8").splitlines():
    required, name, status = line.split("\t")
    commands.append({"required": required == "required", "name": name, "status": status})
epoch_ns = time.time_ns()
stamp = dt.datetime.fromtimestamp(epoch_ns / 1_000_000_000, dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
markers = []
marker_path = pathlib.Path(run_dir) / "markers.jsonl"
if marker_path.exists():
    markers = [json.loads(line) for line in marker_path.read_text(encoding="utf-8").splitlines() if line.strip()]
marker = next(value for value in markers if value.get("marker") == label)
data = {
    "schema": 1,
    "run_id": run["run_id"],
    "label": label,
    "captured_at_utc": stamp,
    "captured_epoch_ns": epoch_ns,
    "marker_timestamp_utc": marker["timestamp_utc"],
    "commands": commands,
    "failed_command_count": int(failures),
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

echo "snapshot $label: $snapshot_dir"
[ "$failures" -eq 0 ] || { echo "snapshot incomplete: $failures command(s) failed; partial evidence preserved" >&2; exit 3; }
