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
#   scripts/deploy-helper.sh pointer <id>     # select display, then move/click/scroll
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

# Keyboard backend override (test-only): auto|uhid|input-manager
KEYBOARD_BACKEND="${KEYBOARD_BACKEND:-auto}"
case "$KEYBOARD_BACKEND" in
    auto | uhid | input-manager) ;;
    *)
        echo "invalid KEYBOARD_BACKEND: $KEYBOARD_BACKEND (expected auto|uhid|input-manager)" >&2
        exit 1
        ;;
esac

# CXI frame presets (15-byte little-endian header; AGENTS.md rule 6 — keep in
# sync with protocol/protocol.md). Header: "CXI" + version u16 + type u16 +
# requestId u32 + payloadLen u32. Values mirror protocol/fixtures/*.bin.
FRAME_HELLO="4358490100010001000000020000000100"
FRAME_PING="435849010007000600000000000000"
FRAME_LIST="435849010002000200000000000000"
FRAME_SHUTDOWN="435849010008000000000000000000"
# POINTER_* presets (0x0009/0x000A/0x000B; values mirror protocol/fixtures/*.bin)
FRAME_PTR_MOVE="435849010009000a000000080000000c000000f8ffffff"
FRAME_PTR_BTN_DOWN="43584901000a000b000000050000000000000001"
FRAME_PTR_BTN_UP="43584901000a000c000000050000000000000000"
FRAME_PTR_SCROLL="43584901000b000d00000008000000000000000000803f"
# HID_REPORT presets (0x0006; values mirror protocol/fixtures/hid-report.bin):
# payload = deviceId u32 + reportLen u32 + report bytes (btn u8, dx i8, dy i8, wheel u8)
# e.g. rel(+60,+40) = 01000000 04000000 003c2800
FRAME_HID_CREATE="4358490100040004000000420000003e00000005010902a1010901a100050919012903150025019503750181029501750581010501093009311581257f75089502810609381581257f750895018106c0c0"
FRAME_HID_REL1="435849010006000f0000000c0000000100000004000000003c2800"
FRAME_HID_REL2="43584901000600100000000c000000010000000400000000643200"
FRAME_HID_REL3="43584901000600110000000c000000010000000400000000c85000"
FRAME_HID_REL4="43584901000600120000000c000000010000000400000000f0a000"

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
    kill_orphans
    deploy
    adb -s "$DEVICE" shell "rm -f $REMOTE_IN $REMOTE_OUT $REMOTE_LOG; touch $REMOTE_IN"
    # Probe-style detached launch (Phase 0 pattern): tail -f holds the helper
    # stdin open and streams appended bytes; nohup keeps it alive after the
    # adb session ends. tail dies with SIGPIPE when the helper exits.
    # Pass --keyboard-backend override for test-only deterministic selection
    local kb_arg="--keyboard-backend=$KEYBOARD_BACKEND"
    adb -s "$DEVICE" shell \
        "nohup sh -c 'tail -f $REMOTE_IN | app_process -cp $REMOTE_APK / com.crossinput.helper.Main $kb_arg > $REMOTE_OUT 2> $REMOTE_LOG' >/dev/null 2>&1 &"
    sleep 2
    if ! helper_running; then
        echo "helper failed to start — stderr log:" >&2
        adb -s "$DEVICE" shell "cat $REMOTE_LOG" >&2 || true
        exit 1
    fi
    echo "device: $DEVICE"
    echo "helper running (stdin <- tail -f $REMOTE_IN; stdout -> $REMOTE_OUT, stderr -> $REMOTE_LOG)"
    echo "keyboard backend: $KEYBOARD_BACKEND"
    echo "next: scripts/deploy-helper.sh list"
}

helper_running() {
    adb -s "$DEVICE" shell "ps -A -o ARGS" | grep -q "crossinput-helper.apk"
}

# Kill the helper and every (possibly orphaned) tail -f feeding its stdin.
# pkill patterns are matched twice (full-name and stdin-file patterns) so a
# stale tail from a previous start() cannot race a later session (observed on
# device: 6 orphaned tails interleaved garbage into the helper stream).
# NOTE: patterns use the [x] bracket trick so pkill/grep never match the
# remote shell's own command line (which contains the literal pattern text) —
# otherwise the shell kills itself mid-sequence and some processes survive.
kill_orphans() {
    adb -s "$DEVICE" shell \
        "pkill -f 'crossinput-[h]elper.apk' 2>/dev/null || true; pkill -f 'cxi-[h]elper-stdin' 2>/dev/null || true; \
         ps -A -o PID,ARGS | grep -E 'crossinput-[h]elper|cxi-[h]elper-stdin' | grep -v grep | awk '{print \$1}' | xargs kill -9 2>/dev/null || true" || true
    sleep 1
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
    pointer)
        id="${2:?pointer requires a display id}"
        hex="$(python3 -c 'import struct, sys; print("435849010003000300000004000000" + struct.pack("<I", int(sys.argv[1])).hex())' "$id")"
        send "$hex"
        sleep 1
        send "$FRAME_PTR_MOVE"
        sleep 1
        send "$FRAME_PTR_BTN_DOWN"
        sleep 1
        send "$FRAME_PTR_BTN_UP"
        sleep 1
        send "$FRAME_PTR_SCROLL"
        echo "pointer sequence sent to display $id (move + click + scroll)"
        ;;
    hid)
        send "$FRAME_HID_CREATE"
        sleep 1
        send "$FRAME_HID_REL1"
        sleep 1
        send "$FRAME_HID_REL2"
        sleep 1
        send "$FRAME_HID_REL3"
        sleep 1
        send "$FRAME_HID_REL4"
        echo "hid sequence sent (create + 4 relative moves)"
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
        kill_orphans
        adb -s "$DEVICE" shell "rm -f $REMOTE_IN $REMOTE_OUT $REMOTE_LOG" || true
        echo "stopped"
        ;;
    *)
        echo "unknown mode: $mode" >&2
        echo "usage: $0 [build|deploy|start|send <hex>|hello|ping|list|select <id>|pointer <id>|hid|dump|stop]" >&2
        exit 1
        ;;
esac
