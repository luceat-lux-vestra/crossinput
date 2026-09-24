#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADB="${ADB:-adb}"
AMPERSAND_LOG="${AMPERSAND_LOG:-$HOME/Library/Logs/Ampersand/diag.log}"
STATE_ROOT="${TMPDIR:-/tmp}/crossinput-diagnostics-state"
ACTIVE="$STATE_ROOT/active"
ARTIFACT_ROOT="${CROSSINPUT_DIAG_ROOT:-${TMPDIR:-/tmp}/crossinput-diagnostics}"

usage() {
    cat <<'EOF'
Usage:
  bash scripts/capture-diagnostics.sh start
  bash scripts/capture-diagnostics.sh stop
  bash scripts/capture-diagnostics.sh status
  bash scripts/capture-diagnostics.sh snapshot

Environment:
  DEVICE / ANDROID_SERIAL   Explicit ADB target. If supplied and unavailable,
                            the script fails instead of falling back.
  CROSSINPUT_DIAG_ROOT      Artifact root (default: $TMPDIR/crossinput-diagnostics).
  AMPERSAND_LOG             Ampersand diag path
                            (default: ~/Library/Logs/Ampersand/diag.log).
  ADB                       adb executable (default: adb).

The capture is metadata-oriented. It does not intentionally record keystrokes,
clipboard contents, CXI payload bytes, or HID report payloads.
EOF
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing required command: $1" >&2
        exit 2
    }
}

select_device() {
    local requested=""
    if [[ -n "${DEVICE:-}" ]]; then
        requested="$DEVICE"
    elif [[ -n "${ANDROID_SERIAL:-}" ]]; then
        requested="$ANDROID_SERIAL"
    fi

    if [[ -n "$requested" ]]; then
        if ! "$ADB" devices | awk 'NR>1 && $2=="device" {print $1}' | grep -Fxq "$requested"; then
            echo "selected ADB device is not attached/ready; refusing fallback" >&2
            exit 3
        fi
        printf '%s\n' "$requested"
        return
    fi

    local -a devices=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && devices+=("$line")
    done < <("$ADB" devices | awk 'NR>1 && $2=="device" {print $1}')

    if (( ${#devices[@]} == 0 )); then
        echo "no ready ADB device" >&2
        exit 3
    fi
    if (( ${#devices[@]} > 1 )); then
        echo "multiple ADB devices are ready; set DEVICE or ANDROID_SERIAL explicitly" >&2
        exit 3
    fi
    printf '%s\n' "${devices[0]}"
}

active_value() {
    local key="$1"
    [[ -f "$ACTIVE/$key" ]] || return 1
    cat "$ACTIVE/$key"
}

collect_static_metadata() {
    local out="$1"
    local device="$2"

    {
        echo "captured_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "git_head=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unavailable)"
        echo "git_branch=$(git -C "$ROOT" symbolic-ref --short -q HEAD 2>/dev/null || echo detached)"
        echo "ampersand_log=$AMPERSAND_LOG"
        echo "android_serial=<redacted>"
        echo
        echo "[git-status]"
        git -C "$ROOT" status --short 2>/dev/null || true
        echo
        echo "[host]"
        sw_vers 2>/dev/null || true
        echo
        echo "[adb-version]"
        "$ADB" version 2>&1 || true
        echo
        echo "[device]"
        echo "model=$("$ADB" -s "$device" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
        echo "device=$("$ADB" -s "$device" shell getprop ro.product.device 2>/dev/null | tr -d '\r')"
        echo "android=$("$ADB" -s "$device" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
        echo "sdk=$("$ADB" -s "$device" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
        echo "fingerprint=$("$ADB" -s "$device" shell getprop ro.build.fingerprint 2>/dev/null | tr -d '\r')"
    } > "$out/metadata.txt"
}

collect_snapshot() {
    local out="$1"
    local device="$2"
    local suffix="${3:-final}"

    "$ADB" -s "$device" shell dumpsys input         > "$out/dumpsys-input-$suffix.txt" 2>&1 || true
    "$ADB" -s "$device" shell dumpsys display         > "$out/dumpsys-display-$suffix.txt" 2>&1 || true
    "$ADB" -s "$device" shell "ps -A -o PID,ARGS | grep -E 'crossinput-[h]elper|app_process' || true"         > "$out/helper-processes-$suffix.txt" 2>&1 || true
}

start_capture() {
    require_cmd "$ADB"
    require_cmd git

    if [[ -d "$ACTIVE" ]]; then
        echo "diagnostics capture already active: $(active_value out 2>/dev/null || echo unknown)" >&2
        exit 2
    fi

    local device
    device="$(select_device)"
    local stamp
    stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    local head
    head="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo no-git)"
    local out="$ARTIFACT_ROOT/${stamp}-${head}"

    mkdir -p "$out" "$ACTIVE"
    printf '%s\n' "$out" > "$ACTIVE/out"
    printf '%s\n' "$device" > "$ACTIVE/device"

    local start_line=0
    if [[ -f "$AMPERSAND_LOG" ]]; then
        start_line="$(wc -l < "$AMPERSAND_LOG" | tr -d '[:space:]')"
    fi
    printf '%s\n' "$start_line" > "$ACTIVE/diag-start-line"

    collect_static_metadata "$out" "$device"
    collect_snapshot "$out" "$device" "start"

    # Helper stderr is already forwarded into Ampersand Diagnostics by
    # SessionController. Keep logcat tag-filtered at the producer so the
    # artifact never contains an unbounded full-system log. With no shell pipeline,
    # $! is the adb process itself and stop can retire it reliably.
    nohup "$ADB" -s "$device" logcat -v threadtime -T 1 AndroidRuntime:V ActivityManager:I InputReader:V InputDispatcher:V InputManager:V InputManager-JNI:V DisplayManagerService:V WindowManager:V '*:S' > "$out/android-logcat.txt" 2>&1 </dev/null &
    printf '%s\n' "$!" > "$ACTIVE/logcat-pid"

    echo "diagnostics capture started"
    echo "artifacts: $out"
    echo "Ampersand diagnostics baseline line: $start_line"
    echo
    echo "Reproduce the failure now, then run:"
    echo "  bash scripts/capture-diagnostics.sh stop"
}

stop_capture() {
    [[ -d "$ACTIVE" ]] || {
        echo "no diagnostics capture is active" >&2
        exit 2
    }

    local out device start_line pid
    out="$(active_value out)"
    device="$(active_value device)"
    start_line="$(active_value diag-start-line)"
    pid="$(active_value logcat-pid 2>/dev/null || true)"

    # Ampersand flushes diagnostics periodically. Give the final quiet lines
    # one flush interval before snapshotting the file.
    sleep 2

    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi

    if [[ -f "$AMPERSAND_LOG" ]]; then
        local first=$((start_line + 1))
        tail -n "+$first" "$AMPERSAND_LOG" > "$out/ampersand-diag.log" 2>/dev/null || true
    else
        : > "$out/ampersand-diag.log"
    fi

    collect_snapshot "$out" "$device" "final"

    {
        echo "# CrossInput runtime diagnostics summary"
        echo
        echo "Artifacts: $out"
        echo
        echo "## Ampersand relevant diagnostics"
        grep -Ea 'candidate|connect failed|helper:|helper log:|fatal|session|target|display|handoff|corehid|edge|capture|permission|unavailable|failed|error'             "$out/ampersand-diag.log" 2>/dev/null | tail -n 250 || true
        echo
        echo "## Android relevant logcat"
        tail -n 250 "$out/android-logcat.txt" 2>/dev/null || true
    } > "$out/summary.txt"

    rm -rf "$ACTIVE"

    echo "diagnostics capture stopped"
    echo "artifacts: $out"
    echo
    cat "$out/summary.txt"
}

status_capture() {
    if [[ ! -d "$ACTIVE" ]]; then
        echo "diagnostics capture: inactive"
        return
    fi
    echo "diagnostics capture: active"
    echo "artifacts: $(active_value out)"
    echo "android serial: <redacted>"
    local pid
    pid="$(active_value logcat-pid 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        echo "logcat collector: running"
    else
        echo "logcat collector: not running"
    fi
}

snapshot_capture() {
    [[ -d "$ACTIVE" ]] || {
        echo "no diagnostics capture is active" >&2
        exit 2
    }
    local out device stamp
    out="$(active_value out)"
    device="$(active_value device)"
    stamp="$(date -u '+%H%M%SZ')"
    collect_snapshot "$out" "$device" "$stamp"
    echo "snapshot captured: $out (*-$stamp.txt)"
}

case "${1:-}" in
    start) start_capture ;;
    stop) stop_capture ;;
    status) status_capture ;;
    snapshot) snapshot_capture ;;
    -h|--help|help|"") usage ;;
    *)
        usage >&2
        exit 2
        ;;
esac