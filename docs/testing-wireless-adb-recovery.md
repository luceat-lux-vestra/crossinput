# Wireless ADB Reboot Recovery Verification

Issue: #133  
Target baseline: Galaxy S10 5G (SM-G977N), Android 12 / API 31  
Transport: Android Wireless debugging (`_adb-tls-connect._tcp` over mDNS TLS)

This procedure verifies only the opt-in reboot bootstrap. It does not replace the existing Android helper/DeX verification in `docs/testing.md`.

## Preconditions

- Exactly one usable ADB target is connected, or `ANDROID_SERIAL` is set.
- The host is already paired/authorized for Android Wireless debugging.
- The target is connected to the Wi-Fi network that will be available after reboot.
- Build prerequisites for `scripts/build-android-helper.sh` are installed.

## Install the bootstrap

From repository root:

```sh
./scripts/setup-wireless-adb-recovery.sh
```

The script must finish with:

```text
Wireless ADB recovery bootstrap installed and preflight-verified.
```

Verify the privileged grant and current setting:

```sh
adb shell dumpsys package com.crossinput.helper \
  | grep -F 'android.permission.WRITE_SECURE_SETTINGS: granted=true'
adb shell settings get global adb_wifi_enabled
```

Expected:

```text
android.permission.WRITE_SECURE_SETTINGS: granted=true
1
```

Verify the current Wireless ADB service:

```sh
adb mdns services
```

There must be an `_adb-tls-connect._tcp` entry for the target device. Do not assume the port is stable across reboot.

## Exact-HEAD reboot test

Record the tested source revision before building/installing:

```sh
git rev-parse HEAD
```

Then:

```sh
adb reboot
```

After issuing the reboot:

- do not attach USB to recover ADB;
- do not use the phone screen to toggle Developer options/Wireless debugging;
- allow the device to reconnect to Wi-Fi normally.

Poll discovery from the host:

```sh
while true; do
  date
  adb mdns services
  sleep 5
done
```

PASS condition: the target's `_adb-tls-connect._tcp` service reappears after reboot without USB or local screen interaction.

Once it appears, stop the polling loop and confirm the ADB host reconnects. If automatic mDNS connection does not occur, use the newly advertised address:

```sh
adb connect <ip>:<port>
adb devices -l
```

## Recovery diagnostics

After reconnecting:

```sh
adb logcat -d -s CrossInputWirelessAdb
```

Expected successful terminal outcome:

```text
wireless ADB recovery succeeded outcome=enabled
```

or, when the system restored the setting before the job ran:

```text
wireless ADB recovery succeeded outcome=already-enabled
```

A transient Wi-Fi/setting race may first show:

```text
wireless ADB recovery deferred outcome=retry
```

followed by a successful outcome after JobScheduler backoff.

The following are clean failures, not success:

```text
wireless ADB recovery stopped outcome=permission-denied
wireless ADB recovery stopped outcome=unsupported
```

For scheduler state when diagnosing a retry:

```sh
adb shell dumpsys jobscheduler com.crossinput.helper
```

Do not attach logs containing unrelated input payloads, key contents, clipboard contents, or device identifiers to issue/PR evidence.

## Regression check: existing helper transport

The installed bootstrap must not replace the existing app_process path. After Wireless ADB has recovered, run:

```sh
scripts/deploy-helper.sh start
scripts/deploy-helper.sh hello
scripts/deploy-helper.sh list
scripts/deploy-helper.sh stop
```

Expected: the normal pushed `/data/local/tmp/crossinput-helper.apk` helper session behaves exactly as before.

## Remove the bootstrap

To remove only the installed reboot-recovery package:

```sh
adb uninstall com.crossinput.helper
```

This does not delete `/data/local/tmp/crossinput-helper.apk`; the ordinary `scripts/deploy-helper.sh` workflow can still push/run the helper through `app_process`.

## Acceptance record

For issue/PR acceptance, record:

- exact Git SHA;
- Android model/API version;
- setup script result;
- pre-reboot `_adb-tls-connect._tcp` presence;
- post-reboot `_adb-tls-connect._tcp` reappearance without USB/screen interaction;
- sanitized `CrossInputWirelessAdb` logcat outcome; and
- existing helper HELLO/LIST/STOP regression result.

Per `AGENTS.md`, automated/unit results alone are insufficient to claim this device-dependent behavior verified.
