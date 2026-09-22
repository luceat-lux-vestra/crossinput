#!/usr/bin/env bash
# Research-only issue #145 boundary-stall oracle probe.
#
# Creates a temporary relative UHID mouse, sends only horizontal movement, and
# observes the post-InputReader SurfaceFlinger Sprite through direct Binder.
# No buttons/keys/clipboard payloads are generated or logged.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK="$ROOT/android/helper/app/build/outputs/apk/debug/app-debug.apk"
REMOTE_APK="/data/local/tmp/crossinput-sf-stall-probe.apk"
MAX_RIGHT_SAMPLES="${1:-600}"
SETTLE_MS="${2:-20}"

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

cleanup() {
    adb -s "$DEVICE" shell "rm -f '$REMOTE_APK'" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

"$ROOT/scripts/build-android-helper.sh" assembleDebug
adb -s "$DEVICE" push "$APK" "$REMOTE_APK" >/dev/null

echo "device: $DEVICE"
echo "Do not move the Mac/DeX pointer until the probe finishes."
say "Do not move the pointer. The boundary probe will move it automatically." 2>/dev/null || true

adb -s "$DEVICE" shell     "app_process -cp '$REMOTE_APK' / com.crossinput.helper.SurfaceFlingerBoundaryStallProbe '$MAX_RIGHT_SAMPLES' '$SETTLE_MS'"

say "Boundary probe finished." 2>/dev/null || true