#!/usr/bin/env bash
# Record a human-observed state marker. This script never touches cursor/input
# state and performs no UI interaction.
set -euo pipefail

RUNS_DIR="${ISSUE96_RUNS_DIR:-${HOME:?HOME is required}/Library/Logs/CrossInput/issue96}"
ACTIVE_FILE="$RUNS_DIR/active-run"

die() { echo "issue96 mark: $*" >&2; exit 2; }

[ $# -eq 1 ] || die "usage: mark.sh healthy|broken|recovered"
label="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
case "$label" in healthy|broken|recovered) ;; *) die "invalid marker: $1" ;; esac
[ -f "$ACTIVE_FILE" ] || die "no active capture; run capture.sh start first"
run_dir="$(<"$ACTIVE_FILE")"
[ -f "$run_dir/run.json" ] || die "active run metadata is missing: $run_dir/run.json"

python3 - "$run_dir" "$label" <<'PY'
import datetime as dt
import json
import os
import pathlib
import subprocess
import sys
import time

run_dir = pathlib.Path(sys.argv[1])
label = sys.argv[2]
with (run_dir / "run.json").open(encoding="utf-8") as fh:
    run = json.load(fh)
if run.get("state") != "running":
    raise SystemExit(f"capture is not running: {run.get('state')}")
markers_path = run_dir / "markers.jsonl"
if markers_path.exists():
    for line in markers_path.read_text(encoding="utf-8").splitlines():
        if line.strip() and json.loads(line).get("marker") == label:
            raise SystemExit(f"marker already exists: {label}")
try:
    output = subprocess.check_output(["pgrep", "-x", "SystemUIServer"], text=True, stderr=subprocess.DEVNULL)
    systemui = [int(value) for value in output.split() if value.isdigit()]
except (OSError, subprocess.CalledProcessError):
    systemui = []
epoch_ns = time.time_ns()
stamp = dt.datetime.fromtimestamp(epoch_ns / 1_000_000_000, dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
entry = {
    "schema": 1,
    "run_id": run["run_id"],
    "marker": label,
    "timestamp_utc": stamp,
    "epoch_ns": epoch_ns,
    "monotonic_ns": time.monotonic_ns(),
    "systemuiserver_pids": systemui,
    "source_sha": run.get("source_sha", "unknown"),
}
with markers_path.open("a", encoding="utf-8") as fh:
    fh.write(json.dumps(entry, sort_keys=True) + "\n")
    fh.flush()
    os.fsync(fh.fileno())
print(f"marked {label}: {stamp} run={run['run_id']}")
PY
