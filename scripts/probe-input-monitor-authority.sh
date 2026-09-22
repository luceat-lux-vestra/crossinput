#!/usr/bin/env bash
set -euo pipefail

# Research-only physical probe for issue #145.
#
# Builds the current Android helper, pushes it to a separate research path, and
# invokes InputMonitorProbeMain under the same adb shell/app_process identity
# used by production. No input events or payloads are captured.
#
# Usage:
#   ./scripts/probe-input-monitor-authority.sh [dex-display-id]
#
# If no display id is supplied, the script discovers Samsung DeX's "Desktop"
# logical display from dumpsys output. It never assumes display id 2.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK="$ROOT/android/helper/app/build/outputs/apk/debug/app-debug.apk"
REMOTE_APK="/data/local/tmp/crossinput-input-monitor-probe.apk"

if [ -n "${DEVICE:-}" ]; then
    if ! adb devices | awk 'NR>1 && $2=="device" {print $1}' | grep -qx "$DEVICE"; then
        echo "selected DEVICE is not attached; refusing to fall back" >&2
        exit 2
    fi
elif [ -n "${ANDROID_SERIAL:-}" ]; then
    DEVICE="$ANDROID_SERIAL"
else
    mapfile -t DEVICES < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
    if [ "${#DEVICES[@]}" -ne 1 ]; then
        echo "expected exactly one usable adb device; set ANDROID_SERIAL or DEVICE" >&2
        exit 2
    fi
    DEVICE="${DEVICES[0]}"
fi

DISPLAY_ID="${1:-}"
if [ -z "$DISPLAY_ID" ]; then
    DISPLAY_DUMP="$(adb -s "$DEVICE" shell dumpsys display)"
    DISPLAY_ID="$(
        printf '%s\n' "$DISPLAY_DUMP" | python3 -c '
import re, sys
text = sys.stdin.read()
ids = sorted(set(re.findall(r"""mBaseDisplayInfo=DisplayInfo\{"Desktop", displayId (\d+)""", text)))
if len(ids) != 1:
    raise SystemExit("could not resolve exactly one Samsung DeX Desktop display; pass display id explicitly")
print(ids[0])
'
    )"
fi

if ! [[ "$DISPLAY_ID" =~ ^[0-9]+$ ]]; then
    echo "invalid display id: $DISPLAY_ID" >&2
    exit 2
fi

echo "==> issue #145 InputMonitor authority probe"
echo "    device model: $(adb -s "$DEVICE" shell getprop ro.product.model | tr -d '\r')"
echo "    android: $(adb -s "$DEVICE" shell getprop ro.build.version.release | tr -d '\r') (SDK $(adb -s "$DEVICE" shell getprop ro.build.version.sdk | tr -d '\r'))"
echo "    execution identity: $(adb -s "$DEVICE" shell id | tr -d '\r')"
echo "    DeX display id: $DISPLAY_ID"

"$ROOT/scripts/build-android-helper.sh" assembleDebug --console=plain
adb -s "$DEVICE" push "$APK" "$REMOTE_APK" >/dev/null

set +e
OUTPUT="$(
    adb -s "$DEVICE" shell         "app_process -cp $REMOTE_APK / com.crossinput.helper.InputMonitorProbeMain $DISPLAY_ID"         2>&1
)"
ADB_RC=$?
set -e

printf '%s\n' "$OUTPUT"

RESULT="$(printf '%s\n' "$OUTPUT" | sed -n 's/.*PROBE_RESULT=\([A-Z_]*\).*/\1/p' | tail -1)"

case "$RESULT" in
    ALLOWED)
        echo "VERDICT=MONITOR_INPUT_RUNTIME_ALLOWED"
        exit 0
        ;;
    DENIED)
        echo "VERDICT=MONITOR_INPUT_RUNTIME_DENIED"
        exit 3
        ;;
    UNAVAILABLE|NO_SYSTEM_CONTEXT)
        echo "VERDICT=MONITOR_INPUT_API_UNAVAILABLE adb_rc=$ADB_RC"
        exit 4
        ;;
    INVALID_ARGUMENT)
        echo "VERDICT=PROBE_INVALID_ARGUMENT"
        exit 2
        ;;
    *)
        echo "VERDICT=PROBE_INCONCLUSIVE adb_rc=$ADB_RC" >&2
        exit 5
        ;;
esac
