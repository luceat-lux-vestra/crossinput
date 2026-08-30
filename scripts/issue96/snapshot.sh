#!/usr/bin/env bash
# Bounded, read-only Issue #96 state snapshot.
set -euo pipefail

RUNS_DIR="${ISSUE96_RUNS_DIR:-${HOME:?HOME is required}/Library/Logs/CrossInput/issue96}"
ACTIVE_FILE="$RUNS_DIR/active-run"

die() { echo "issue96 snapshot: $*" >&2; exit 2; }
[ $# -eq 1 ] || die "usage: snapshot.sh healthy|broken|recovered"
label="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
case "$label" in healthy|broken|recovered) ;; *) die "invalid snapshot label: $1" ;; esac
[ -f "$ACTIVE_FILE" ] || die "no active capture; run capture.sh start first"
run_dir="$(<"$ACTIVE_FILE")"
[ -f "$run_dir/run.json" ] || die "active run metadata is missing: $run_dir/run.json"

python3 - "$run_dir/run.json" "${ISSUE96_INCLUDE_HIDUTIL:-0}" <<'PY'
import json
import sys
path, requested = sys.argv[1:]
with open(path, encoding="utf-8") as fh:
    run = json.load(fh)
if run.get("state") != "running":
    raise SystemExit(f"capture is not running: {run.get('state')}")
mode = run.get("evidence_mode")
if not isinstance(mode, dict) or not isinstance(mode.get("include_hidutil"), bool):
    raise SystemExit("run evidence mode metadata is missing")
if mode["include_hidutil"] != (requested == "1"):
    raise SystemExit("ISSUE96_INCLUDE_HIDUTIL does not match capture start evidence mode")
PY

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
    local evidence=present
    if ! "$@" >"$snapshot_dir/$output" 2>"$snapshot_dir/$output.stderr"; then
        status=failed
        evidence=failed
        failures=$((failures + 1))
    else
        if ! evidence="$(python3 - "$snapshot_dir/$output" <<'PY'
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
if not text.strip():
    print("empty")
    raise SystemExit(0)
try:
    value = json.loads(text)
except json.JSONDecodeError:
    if re.search(r"not_available|[\"']?evidence[\"']?\s*[:=]", text, re.IGNORECASE):
        print("invalid_sentinel")
    else:
        print("present")
else:
    if isinstance(value, dict) and "evidence" in value:
        if (set(value) == {"evidence", "reason"}
                and value.get("evidence") == "not_available"
                and isinstance(value.get("reason"), str)
                and value["reason"]):
            print("not_available")
        else:
            print("invalid_sentinel")
    else:
        print("present")
PY
)"; then
            evidence=invalid_sentinel
        fi
        case "$evidence" in
            present|not_available) ;;
            *)
                status=failed
                failures=$((failures + 1))
                ;;
        esac
    fi
    printf '%s\t%s\t%s\t%s\n' "$required" "$name" "$status" "$evidence" >>"$manifest"
}

emit_not_available() {
    printf '{"evidence":"not_available","reason":"%s"}\n' "$1"
}

record_systemui_process() {
    local pids pgrep_status=0
    pids="$(pgrep -x SystemUIServer 2>/dev/null)" || pgrep_status=$?
    [ "$pgrep_status" -eq 0 ] || [ "$pgrep_status" -eq 1 ] || return 1
    if [ -z "$pids" ]; then
        emit_not_available "no_systemuiserver_process_at_snapshot"
        return 0
    fi
    local pid
    while read -r pid; do
        [ -n "$pid" ] || continue
        ps -p "$pid" -o pid=,ppid=,comm=
    done <<<"$pids"
}

record_hid_registry() {
    local class="$1"
    local output
    if ! output="$(ioreg -r -c "$class" -l -w 0 | awk '
        /(^|[+| -])+-o / { line=$0; sub(/<class.*$/, "", line); print line }
        /"(Transport|VendorID|ProductID|LocationID|PrimaryUsagePage|PrimaryUsage|Built-in|BuiltIn|IOHIDVirtualDevice|Product|Manufacturer|IORegistryEntryID|RegistryEntryID)"[[:space:]]*=/ { print }
    ')"; then
        return 1
    fi
    if [ -n "$output" ]; then
        printf '%s\n' "$output"
    else
        emit_not_available "no_matching_${class}_entries"
    fi
}

record_launchctl() {
    local domain label raw filtered attempted=0
    domain="gui/$(id -u)"
    for label in com.apple.SystemUIServer.agent com.apple.SystemUIServer com.apple.systemuiserver.agent; do
        if raw="$(launchctl print "$domain/$label" 2>/dev/null)"; then
            attempted=1
            filtered="$(printf '%s\n' "$raw" | awk '
            /state =|pid =|program =|path =|active count|last exit|service name/ { print }
        ')"
            if [ -n "$filtered" ]; then
                printf '%s\n' "$filtered"
                return 0
            fi
        fi
    done
    if [ "$attempted" -eq 1 ]; then
        emit_not_available "systemuiserver_service_has_no_allowlisted_fields"
    else
        emit_not_available "systemuiserver_service_not_exposed_in_gui_domain"
    fi
}

record_ampersand_diag() {
    local source="${CROSSINPUT_DIAG_LOG:-${HOME:?HOME is required}/Library/Logs/Ampersand/diag.log}"
    [ -f "$source" ] || { emit_not_available "crossinput_metadata_log_not_available"; return 0; }
    # Existing CrossInput diagnostics are metadata-only by contract; retain
    # only lifecycle/cursor/display lines for bounded correlation.
    local output
    output="$(tail -n 500 "$source" | awk '/candidate identity|handoff transition|suppression |cursor |display |lifecycle|external-control|watchdog|remoteUnavailable/ { print }')"
    if [ -n "$output" ]; then
        printf '%s\n' "$output"
    else
        emit_not_available "crossinput_metadata_log_has_no_allowlisted_lines"
    fi
}

record_hidutil() {
    if [ "${ISSUE96_INCLUDE_HIDUTIL:-0}" = "1" ]; then
        if command -v hidutil >/dev/null 2>&1; then
            hidutil list
        else
            emit_not_available "hidutil_not_available"
        fi
    else
        emit_not_available "hidutil_not_requested_default"
    fi
}

record_command "systemuiserver_process" required systemuiserver-process.txt record_systemui_process
record_command "hidutil_list" optional hidutil-list.txt record_hidutil
record_command "iohid_device_registry" required iohid-device-registry.txt record_hid_registry IOHIDDevice
record_command "iohid_event_system" required iohid-event-system.txt record_hid_registry IOHIDEventSystem
record_command "iohid_event_system_client" required iohid-event-system-client.txt record_hid_registry IOHIDEventSystemClient
record_command "iohid_event_service" required iohid-event-service.txt record_hid_registry IOHIDEventService
record_command "display_workspace_accessibility" required display-workspace.json "$run_dir/bin/state_snapshot"
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
    required, name, status, evidence = line.split("\t")
    commands.append({"required": required == "required", "name": name, "status": status, "evidence": evidence})
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
    "evidence_contract_schema": 1,
    "evidence_mode": run.get("evidence_mode"),
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

echo "snapshot $label: $snapshot_dir"
[ "$failures" -eq 0 ] || { echo "snapshot incomplete: $failures command(s) failed; partial evidence preserved" >&2; exit 3; }
