#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK="$ROOT/android/helper/app/build/outputs/apk/debug/app-debug.apk"
PACKAGE="com.crossinput.helper"
PERMISSION="android.permission.WRITE_SECURE_SETTINGS"
BOOTSTRAP_COMPONENT="$PACKAGE/.WirelessAdbBootstrapActivity"

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

echo "==> Explicitly starting bootstrap component"
# A newly installed Android package can remain in the stopped state until a
# component is explicitly launched. Start the no-display bootstrap Activity so
# future BOOT_COMPLETED delivery is not dependent on local screen interaction.
adb_cmd shell am start -W -n "$BOOTSTRAP_COMPONENT" >/dev/null

echo "==> Enabling Wireless debugging for the current boot"
# This command runs as the adb shell user. Future boots are handled by the
# installed receiver/job after Wi-Fi connectivity is available.
adb_cmd shell settings put global adb_wifi_enabled 1

GRANTED="$(adb_cmd shell dumpsys package "$PACKAGE" | grep -F "$PERMISSION: granted=true" || true)"
if [ -z "$GRANTED" ]; then
  echo "ERROR: $PERMISSION was not granted to $PACKAGE" >&2
  exit 1
fi

ENABLED="$(adb_cmd shell settings get global adb_wifi_enabled | tr -d '\r')"
if [ "$ENABLED" != "1" ]; then
  echo "ERROR: adb_wifi_enabled did not become 1" >&2
  exit 1
fi

cat <<EOF
Wireless ADB recovery bootstrap installed.

Package: $PACKAGE
Android API: $SDK
Current adb_wifi_enabled: $ENABLED

Next physical verification:
  1. Confirm 'adb mdns services' contains _adb-tls-connect._tcp.
  2. Reboot with 'adb reboot'.
  3. Do not use USB or local screen interaction.
  4. Confirm _adb-tls-connect._tcp reappears after Wi-Fi reconnects.
  5. Reconnect and inspect:
       adb logcat -d -s CrossInputWirelessAdb

To remove the bootstrap package without affecting the pushed app_process APK:
  adb uninstall $PACKAGE
EOF
