#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APK="$ROOT/android/helper/app/build/outputs/apk/debug/app-debug.apk"
REMOTE_APK="/data/local/tmp/crossinput-helper.apk"
SHELL_PACKAGE="com.android.shell"
PROFILE="android.app.role.COMPANION_DEVICE_APP_STREAMING"
PROBE_MAC="02:14:50:00:00:01"
PROBE_DEVICE_NAME="CrossInput #145 Cursor Probe"

DISPLAY_ID="${1:-}"
if ! [[ "$DISPLAY_ID" =~ ^[0-9]+$ ]]; then
    echo "usage: bash scripts/probe-virtual-mouse-cursor.sh <display-id>" >&2
    exit 2
fi

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
if [ -z "$DEVICE" ]; then
    echo "no adb device" >&2
    exit 1
fi

SHELL_UID="$(adb -s "$DEVICE" shell id -u | tr -d '\r')"
if ! [[ "$SHELL_UID" =~ ^[0-9]+$ ]]; then
    echo "unable to resolve adb shell uid" >&2
    exit 1
fi
USER_ID=$((SHELL_UID / 100000))

list_associations() {
    adb -s "$DEVICE" shell cmd companiondevice list "$USER_ID" | tr -d '\r'
}

role_holders() {
    adb -s "$DEVICE" shell cmd role get-role-holders --user "$USER_ID" "$PROFILE" 2>/dev/null \
        | tr -d '\r' | LC_ALL=C sort
}

association_id() {
    list_associations | awk -F'|' -v pkg="$SHELL_PACKAGE" -v mac="$PROBE_MAC" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        NF >= 3 {
            id=trim($1); p=trim($2); m=tolower(trim($3));
            if (p == pkg && m == tolower(mac) && id ~ /^[0-9]+$/) {
                print id; exit
            }
        }'
}

if list_associations | grep -Fqi "$PROBE_MAC"; then
    echo "probe association address already exists; refusing to modify it: $PROBE_MAC" >&2
    exit 1
fi

BEFORE_ROLE="$(role_holders)"
ASSOCIATION_CREATED=0
cleanup() {
    rc=$?
    set +e
    cleanup_failed=0

    if [ "$ASSOCIATION_CREATED" -eq 1 ]; then
        adb -s "$DEVICE" shell cmd companiondevice disassociate \
            "$USER_ID" "$SHELL_PACKAGE" "$PROBE_MAC" >/dev/null 2>&1
        sleep 0.3

        if list_associations | grep -Fqi "$PROBE_MAC"; then
            echo "cleanup failure: temporary companion association still exists" >&2
            cleanup_failed=1
        fi

        AFTER_ROLE="$(role_holders)"
        if [ "$AFTER_ROLE" != "$BEFORE_ROLE" ]; then
            echo "cleanup failure: companion role-holder state did not return to baseline" >&2
            cleanup_failed=1
        fi
    fi

    for _ in 1 2 3 4 5; do
        if ! adb -s "$DEVICE" shell dumpsys input 2>/dev/null | grep -Fq "$PROBE_DEVICE_NAME"; then
            break
        fi
        sleep 0.2
    done
    if adb -s "$DEVICE" shell dumpsys input 2>/dev/null | grep -Fq "$PROBE_DEVICE_NAME"; then
        echo "cleanup failure: temporary VirtualMouse input device still exists" >&2
        cleanup_failed=1
    fi

    if [ "$cleanup_failed" -ne 0 ]; then
        rc=90
    fi
    trap - EXIT
    exit "$rc"
}
trap cleanup EXIT INT TERM

echo "device: $DEVICE"
echo "shell user: $USER_ID"
echo "creating temporary CDM association for cursor-oracle capability probe"

adb -s "$DEVICE" shell cmd companiondevice associate \
    "$USER_ID" "$SHELL_PACKAGE" "$PROBE_MAC" "$PROFILE" false >/dev/null
ASSOCIATION_CREATED=1
sleep 0.3

ASSOCIATION_ID="$(association_id)"
if ! [[ "$ASSOCIATION_ID" =~ ^[0-9]+$ ]]; then
    echo "failed to resolve temporary association id" >&2
    exit 3
fi

"$ROOT/scripts/build-android-helper.sh" assembleDebug --console=plain
adb -s "$DEVICE" push "$APK" "$REMOTE_APK" >/dev/null

adb -s "$DEVICE" shell \
    "app_process -cp $REMOTE_APK / com.crossinput.helper.VirtualMouseCursorProbeMain $ASSOCIATION_ID $DISPLAY_ID"
