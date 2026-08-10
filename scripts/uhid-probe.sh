#!/usr/bin/env bash
# UHID probe driver — APK push + on-device FIFO stdin.
#
# Usage:
#   scripts/uhid-probe.sh [mouse-rel|mouse-abs|mouse-wheel|stylus] [start|stop|send]
#     (start is the default when only the type is given)
#
# start: run the probe on the device in the background (survives host session end)
# send:  send "cmd" to the on-device FIFO (e.g. "abs 100 100", "down 0", "up 0", "wheel 3", "quit")
# stop:  terminate the probe (send quit, wait)
#
# Commands can also be sent directly, e.g.: echo "abs 100 100" > ...
set -euo pipefail

TYPE="${1:-mouse-rel}"
MODE="${2:-start}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APK="$ROOT/android/helper/app/build/outputs/apk/debug/app-debug.apk"
REMOTE="/data/local/tmp/crossinput-helper.apk"
REMOTE_CMD="/data/local/tmp/uhid-probe-cmd"
REMOTE_LOG="/data/local/tmp/uhid-probe-out.log"

DEVICE="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
if [ -z "$DEVICE" ]; then
    echo "no adb device" >&2
    exit 1
fi

case "$MODE" in
    start)
        adb -s "$DEVICE" push "$APK" "$REMOTE" >/dev/null
        adb -s "$DEVICE" shell "rm -f $REMOTE_CMD $REMOTE_LOG" >/dev/null
        EXTRA="${3:-} ${4:-} ${5:-}"
        adb -s "$DEVICE" shell \
            "nohup sh -c 'app_process -cp $REMOTE / com.crossinput.helper.UhidProbe $TYPE $REMOTE_CMD $EXTRA > $REMOTE_LOG 2>&1' >/dev/null 2>&1 &" >/dev/null
        sleep 2
        echo "device: $DEVICE  type: $TYPE  extra: [$EXTRA]"
        echo "probe running (device background, independent of the host session)."
        echo "inject: scripts/uhid-probe.sh $TYPE send 'abs 100 100'"
        ;;
    send)
        adb -s "$DEVICE" shell "echo '$3' >> $REMOTE_CMD" >/dev/null
        echo "sent: $3"
        ;;
    stop)
        adb -s "$DEVICE" shell "echo 'quit' >> $REMOTE_CMD" >/dev/null
        sleep 1
        adb -s "$DEVICE" shell "rm -f $REMOTE_CMD" >/dev/null
        echo "stopped"
        ;;
    *)
        echo "unknown mode: $MODE (start|send|stop)" >&2
        exit 1
        ;;
esac
