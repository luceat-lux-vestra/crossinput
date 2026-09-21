#!/usr/bin/env bash
# Research-only direct-Binder SurfaceFlinger oracle probe for issue #145.
#
# Builds a separate helper APK, launches one foreground app_process invocation,
# samples SurfaceFlinger --hwclayers through IBinder.dump(), and exits. It does
# not inject input, change display routing, require root, or leave a background
# process behind.
#
# While the probe runs, move the existing DeX pointer normally so the probe can
# prove that consecutive direct-Binder samples observe a live Sprite.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK="$ROOT/android/helper/app/build/outputs/apk/debug/app-debug.apk"
REMOTE_APK="/data/local/tmp/crossinput-sf-binder-probe.apk"
SAMPLES="${1:-24}"
DELAY_MS="${2:-50}"

if [ -n "${DEVICE:-}" ]; then
    if ! adb devices | awk 'NR>1 {print $1}' | grep -qx "$DEVICE"; then
        echo "selected DEVICE '$DEVICE' is not attached; refusing to fall back" >&2
        exit 1
    fi
elif [ -n "${ANDROID_SERIAL:-}" ]; then
    DEVICE="$ANDROID_SERIAL"
else
    DEVICE="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
fi

if [ -z "${DEVICE:-}" ]; then
    echo "no adb device" >&2
    exit 1
fi

if ! [[ "$SAMPLES" =~ ^[0-9]+$ ]] || [ "$SAMPLES" -lt 3 ] || [ "$SAMPLES" -gt 200 ]; then
    echo "samples must be an integer in [3, 200]" >&2
    exit 1
fi
if ! [[ "$DELAY_MS" =~ ^[0-9]+$ ]] || [ "$DELAY_MS" -gt 1000 ]; then
    echo "delay_ms must be an integer in [0, 1000]" >&2
    exit 1
fi

cleanup() {
    adb -s "$DEVICE" shell "rm -f '$REMOTE_APK' /data/local/tmp/crossinput-sf-binder-probe-*.txt"         >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

"$ROOT/scripts/build-android-helper.sh" assembleDebug
adb -s "$DEVICE" push "$APK" "$REMOTE_APK" >/dev/null

echo "device: $DEVICE"
echo "Move the pointer around inside DeX while the probe is running."
adb -s "$DEVICE" shell     "app_process -cp '$REMOTE_APK' / com.crossinput.helper.SurfaceFlingerBinderProbe '$SAMPLES' '$DELAY_MS'"
