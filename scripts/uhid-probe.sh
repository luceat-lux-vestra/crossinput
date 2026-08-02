#!/usr/bin/env bash
# UHID probe 드라이버 — APK push + 기기 측 FIFO stdin 연결.
#
# 사용법:
#   scripts/uhid-probe.sh [mouse-rel|mouse-abs|mouse-wheel|stylus] [start|stop|send]
#     (인자 없이 type만 주면 start)
#
# start: 프로브를 기기에서 백그라운드로 실행 (호스트 세션 종료에도 유지)
# send:  "cmd" 를 기기 FIFO로 전송 (예: "abs 100 100", "down 0", "up 0", "wheel 3", "quit")
# stop:  프로브 종료 (quit 전송 후 대기)
#
# 명령: echo "abs 100 100" > ... 등으로 직접 보낼 수도 있음.
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
        echo "프로브 실행됨 (기기 백그라운드, 호스트 세션과 독립)."
        echo "명령 주입: scripts/uhid-probe.sh $TYPE send 'abs 100 100'"
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
