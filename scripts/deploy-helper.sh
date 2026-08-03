#!/usr/bin/env bash
# CrossInput Android helper driver — build, deploy, and drive the CXI
# protocol over ADB for on-device verification (Phase 2, issue #6).
#
# The helper speaks the binary CXI protocol on stdin/stdout. stdin is fed by
# a device-side `tail -f` on a regular file (mkfifo is blocked on this device
# by SELinux, and adb-forwarded stdin EOFs unpredictably). Frames are appended
# to the file host-side, exactly like Phase 0's uhid-probe.sh pattern, so the
# helper stays alive independent of the host session. stdout is redirected
# on-device to a file for later `dump`.
#
# NOTE: a clean helper shutdown (EOF or SHUTDOWN) manifests as exit code 137
# with "Killed" in the stderr log — ART kills the process at System.exit(0).
# "Killed" in the log is the expected shutdown signature, not a crash.
#
# Usage:
#   scripts/deploy-helper.sh build            # assembleDebug only
#   scripts/deploy-helper.sh deploy           # build + push APK
#   scripts/deploy-helper.sh start            # deploy + launch helper (background)
#   scripts/deploy-helper.sh send <hex>       # append one CXI frame to helper stdin
#   scripts/deploy-helper.sh hello|ping|list  # preset request frames
#   scripts/deploy-helper.sh select <id>      # SELECT_DISPLAY frame (id = display id)
#   scripts/deploy-helper.sh dump             # pull captured frames + stderr log
#   scripts/deploy-helper.sh stop             # SHUTDOWN frame, then clean up processes
#
# Canonical frame bytes for fixtures live in protocol/fixtures/*.bin
# (e.g. `xxd -p protocol/fixtures/create-hid.bin | tr -d '\n'`).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK="$ROOT/android/helper/app/build/outputs/apk/debug/app-debug.apk"
REMOTE_APK="/data/local/tmp/crossinput-helper.apk"
REMOTE_IN="/data/local/tmp/cxi-helper-stdin"
REMOTE_OUT="/data/local/tmp/cxi-helper-stdout.bin"
REMOTE_LOG="/data/local/tmp/cxi-helper.log"

# CXI frame presets (15-byte little-endian header; AGENTS.md rule 6 — keep in
# sync with protocol/protocol.md). Header: "CXI" + version u16 + type u16 +
# requestId u32 + payloadLen u32. Values mirror protocol/fixtures/*.bin.
FRAME_HELLO="4358490100010001000000020000000100"
FRAME_PING="435849010007000600000000000000"
FRAME_LIST="435849010002000200000000000000"
FRAME_SHUTDOWN="435849010008000000000000000000"

DEVICE="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
if [ -z "$DEVICE" ]; then
    echo "no adb device" >&2
    exit 1
fi

build() {
    "$ROOT/scripts/build-android-helper.sh" assembleDebug --console=plain
}

deploy() {
    build
    adb -s "$DEVICE" push "$APK" "$REMOTE_APK" >/dev/null
    echo "deployed: $REMOTE_APK"
}

start() {
    deploy
    adb -s "$DEVICE" shell "rm -f $REMOTE_IN $REMOTE_OUT $REMOTE_LOG; touch $REMOTE_IN"
    # Probe-style detached launch (Phase 0 pattern): tail -f holds the helper
    # stdin open and streams appended bytes; nohup keeps it alive after the
    # adb session ends. tail dies with SIGPIPE when the helper exits.
    adb -s "$DEVICE" shell \
        "nohup sh -c 'tail -f $REMOTE_IN | app_process -cp $REMOTE_APK / com.crossinput.helper.Main > $REMOTE_OUT 2> $REMOTE_LOG' >/dev/null 2>&1 &"
    sleep 2
    if ! helper_running; then
        echo "helper failed to start — stderr log:" >&2
        adb -s "$DEVICE" shell "cat $REMOTE_LOG" >&2 || true
        exit 1
    fi
    echo "device: $DEVICE"
    echo "helper running (stdin <- tail -f $REMOTE_IN; stdout -> $REMOTE_OUT, stderr -> $REMOTE_LOG)"
    echo "next: scripts/deploy-helper.sh list"
}

helper_running() {
    adb -s "$DEVICE" shell "ps -A -o ARGS" | grep -q "crossinput-helper.apk"
}

send() {
    local hex="$1"
    if ! [[ "$hex" =~ ^[0-9a-fA-F]+$ ]] || [ $(( ${#hex} % 2 )) -ne 0 ]; then
        echo "bad hex: $hex (even-length hex string expected)" >&2
        exit 1
    fi
    if ! helper_running; then
        echo "helper not running (start it with: scripts/deploy-helper.sh start)" >&2
        exit 1
    fi
    # Host-side hex -> \xNN escapes, appended to the tail-f fed file via adb
    # stdin forwarding (binary-safe; toybox printf escapes would mangle \x00).
    local esc
    esc="$(python3 -c 'import sys; s=sys.argv[1]; print("".join(r"\x" + s[i:i+2] for i in range(0, len(s), 2)))' "$hex")"
    printf "$esc" | adb -s "$DEVICE" shell "cat >> $REMOTE_IN"
    echo "sent: ${hex:0:10}.. (${#hex} hex chars, $(( ${#hex} / 2 )) bytes)"
}

mode="${1:-}"
case "$mode" in
    build) build ;;
    deploy) deploy ;;
    start) start ;;
    send) send "${2:-}" ;;
    hello) send "$FRAME_HELLO" ;;
    ping) send "$FRAME_PING" ;;
    list) send "$FRAME_LIST" ;;
    select)
        id="${2:?select requires a display id}"
        hex="$(python3 -c 'import struct, sys; print("435849010003000300000004000000" + struct.pack("<I", int(sys.argv[1])).hex())' "$id")"
        send "$hex"
        ;;
    dump)
        adb -s "$DEVICE" pull "$REMOTE_OUT" /tmp/cxi-helper-stdout.bin >/dev/null
        echo "== stdout frames ($(wc -c </tmp/cxi-helper-stdout.bin) bytes):"
        xxd /tmp/cxi-helper-stdout.bin
        echo "== stderr log:"
        adb -s "$DEVICE" shell "tail -30 $REMOTE_LOG"
        ;;
    stop)
        send "$FRAME_SHUTDOWN" 2>/dev/null || true
        sleep 2
        adb -s "$DEVICE" shell "pkill -f 'crossinput-helper.apk' 2>/dev/null || true; pkill -f 'cxi-helper-stdin' 2>/dev/null || true; rm -f $REMOTE_IN $REMOTE_OUT $REMOTE_LOG" || true
        echo "stopped"
        ;;
    *)
        echo "unknown mode: $mode" >&2
        echo "usage: $0 [build|deploy|start|send <hex>|hello|ping|list|select <id>|dump|stop]" >&2
        exit 1
        ;;
esac
