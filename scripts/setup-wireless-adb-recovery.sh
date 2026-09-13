#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK="$ROOT/android/helper/app/build/outputs/apk/debug/app-debug.apk"
PACKAGE="com.crossinput.helper"
PERMISSION="android.permission.WRITE_SECURE_SETTINGS"
BOOTSTRAP_COMPONENT="$PACKAGE/.WirelessAdbBootstrapActivity"
LOG_TAG="CrossInputWirelessAdb"

adb_cmd() {
  if [ -n "${ANDROID_SERIAL:-}" ]; then
    adb -s "$ANDROID_SERIAL" "$@"
  else
    adb "$@"
  fi
}

if ! command -v adb >/dev/null 2>&1; then
  echo "ERROR: adb not found in PATH" >&2
  exit 1
fi

SDK="$(adb_cmd shell getprop ro.build.version.sdk | tr -d '\r')"
if ! [[ "$SDK" =~ ^[0-9]+$ ]] || [ "$SDK" -lt 30 ]; then
  echo "ERROR: Wireless debugging recovery requires Android 11 / API 30 or newer (device API: ${SDK:-unknown})" >&2
  exit 1
fi

echo "==> Building Android helper"
"$ROOT/scripts/build-android-helper.sh" assembleDebug

if [ ! -f "$APK" ]; then
  echo "ERROR: helper APK not found after build: $APK" >&2
  exit 1
fi

echo "==> Installing recovery package"
adb_cmd install -r "$APK"

echo "==> Granting WRITE_SECURE_SETTINGS"
adb_cmd shell pm grant "$PACKAGE" "$PERMISSION"

GRANTED="$(adb_cmd shell dumpsys package "$PACKAGE" | grep -F "$PERMISSION: granted=true" || true)"
if [ -z "$GRANTED" ]; then
  echo "ERROR: $PERMISSION was not granted to $PACKAGE" >&2
  exit 1
fi

echo "==> Enabling Wireless debugging for the current boot"
# Keep the current transport alive while validating the installed-app path.
adb_cmd shell settings put global adb_wifi_enabled 1
ENABLED="$(adb_cmd shell settings get global adb_wifi_enabled | tr -d '\r')"
if [ "$ENABLED" != "1" ]; then
  echo "ERROR: adb_wifi_enabled did not become 1" >&2
  exit 1
fi

echo "==> Explicitly starting bootstrap component"
adb_cmd shell am start -W -n "$BOOTSTRAP_COMPONENT"

echo "==> Package user state"
adb_cmd shell dumpsys package "$PACKAGE" \
  | grep -E 'User [0-9]+:|stopped=|notLaunched=|WRITE_SECURE_SETTINGS' \
  || true

echo "==> Waiting for installed-app recovery preflight"
PREFLIGHT_OK=0
for _ in $(seq 1 15); do
  LOGS="$(adb_cmd logcat -d -t 200 -s "$LOG_TAG:I" '*:S' 2>/dev/null || true)"
  if printf '%s\n' "$LOGS" | grep -q 'bootstrap activity started' \
    && printf '%s\n' "$LOGS" | grep -q 'wireless ADB recovery succeeded outcome='; then
    PREFLIGHT_OK=1
    break
  fi
  sleep 1
done

if [ "$PREFLIGHT_OK" -ne 1 ]; then
  echo "ERROR: installed recovery path did not complete its preflight." >&2
  echo >&2
  echo "=== $LOG_TAG logs ===" >&2
  adb_cmd logcat -d -t 200 -s "$LOG_TAG:I" '*:S' >&2 || true
  echo >&2
  echo "=== package state ===" >&2
  adb_cmd shell dumpsys package "$PACKAGE" \
    | grep -E 'User [0-9]+:|stopped=|notLaunched=|enabled=|WRITE_SECURE_SETTINGS' >&2 \
    || true
  echo >&2
  echo "=== jobscheduler ===" >&2
  adb_cmd shell dumpsys jobscheduler "$PACKAGE" >&2 || true
  exit 1
fi

echo "==> Recovery preflight passed"
adb_cmd logcat -d -t 50 -s "$LOG_TAG:I" '*:S' || true

cat <<EOF
Wireless ADB recovery bootstrap installed and preflight-verified.

Package: $PACKAGE
Android API: $SDK
Current adb_wifi_enabled: $ENABLED

Next physical verification:
  1. Confirm 'adb mdns services' contains _adb-tls-connect._tcp.
  2. Reboot with 'adb reboot'.
  3. Do not use USB or local screen interaction.
  4. Confirm _adb-tls-connect._tcp reappears after Wi-Fi reconnects.
  5. Reconnect and inspect:
       adb logcat -d -t 200 -s $LOG_TAG:I '*:S'

To remove the bootstrap package without affecting the pushed app_process APK:
  adb uninstall $PACKAGE
EOF
