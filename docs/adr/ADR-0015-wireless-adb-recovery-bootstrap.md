# ADR-0015: Opt-in Wireless ADB Recovery Bootstrap

**Status:** Accepted for implementation under issue #133; physical verification pending
**Date:** 2026-09-13
**Issue:** #133

## Context

Ampersand/CrossInput currently uses ADB plus `app_process` as its Android transport. The helper APK is pushed to `/data/local/tmp` and executed as a shell process; it is not normally installed as an Android application.

The primary Android 12 test device can be operated without its local phone display, but an unattended reboot can leave Wireless debugging disabled. Re-enabling it from the screen is not viable on a device with a broken/unusable display.

A Termux:Boot prototype was rejected. Running the Android `settings` CLI from the Termux application UID hit an `INTERACT_ACROSS_USERS` permission check even after granting `WRITE_SECURE_SETTINGS`. The CLI path is therefore the wrong privilege boundary for this requirement.

Android's Wireless debugging UI is backed by the non-public global setting key `adb_wifi_enabled`. Writing that key from an installed app process succeeds only when the app has `WRITE_SECURE_SETTINGS`, which is granted explicitly once over an already-authorized ADB connection. The setting key is not a supported public API contract and therefore must remain isolated and fail cleanly when unavailable.

## Decision

Keep the existing ADB/`app_process` transport unchanged. Add an **opt-in recovery bootstrap** by also installing the existing helper APK as package `com.crossinput.helper` on devices that need unattended reboot recovery.

The installed package:

1. receives `LOCKED_BOOT_COMPLETED` and `BOOT_COMPLETED`;
2. schedules a `JobScheduler` job instead of blocking inside the broadcast receiver;
3. waits for Android to report network availability and independently verifies that a Wi-Fi transport exists;
4. gates the mechanism to Android 11 / API 30 or newer;
5. accesses only the isolated `adb_wifi_enabled` key through `AndroidWirelessAdbSettingStore`;
6. writes `1`, waits briefly, and reads the value back because Android may clear Wireless debugging again if Wi-Fi was not actually ready;
7. requests exponential-backoff retry only for transient states such as missing Wi-Fi or a write that did not stick;
8. treats `SecurityException` as a permanent permission failure for that run and does not create a retry storm; and
9. logs only metadata/outcome state under `CrossInputWirelessAdb`.

The bootstrap requires one explicit setup step:

```sh
./scripts/setup-wireless-adb-recovery.sh
```

The script builds and installs the helper APK, grants:

```text
android.permission.WRITE_SECURE_SETTINGS
```

and enables Wireless debugging for the current boot using the already-authorized ADB shell. The exported bootstrap Activity is protected by the same privileged permission so an ordinary third-party application cannot trigger the helper's privileged recovery path. The setup script grants the package first and then launches the Activity from the authorized ADB shell; inability to cross that permission boundary fails setup before reboot. Future boots are handled by the non-exported receiver/job.

Uninstalling `com.crossinput.helper` removes the bootstrap package but does not affect the separate APK pushed to `/data/local/tmp` for `app_process` execution.

## Why this satisfies the non-SDK rule

`adb_wifi_enabled` is intentionally treated as an unstable platform integration detail:

- it exists in exactly one Android adapter;
- Android version support is checked at runtime;
- permission failure is explicit and permanent for the current job;
- write success is verified by readback;
- retry is bounded by `JobScheduler` exponential backoff rather than an application spin loop;
- normal CrossInput transport remains unchanged if the mechanism is absent or fails; and
- physical Android 12 verification is required before merge-ready status.

No root, Knox bypass, hidden Binder API, reflection, or system-package modification is introduced by this feature.

## Alternatives considered

### Rely only on Android/AOSP Wireless debugging persistence

Rejected as the sole mechanism. OEM behavior and boot timing can clear the setting, and the target requirement is unattended recovery after arbitrary reboot rather than best-effort persistence.

### Termux:Boot plus `/system/bin/settings`

Rejected. The `settings` CLI executes through a user-aware shell-command path that requires `INTERACT_ACROSS_USERS` when invoked from the Termux app UID on the target Android 12 build. Adding more privileged Termux permissions would be broader and less maintainable than using the project-owned APK.

### Root/init service

Rejected. Root and Knox bypass are explicit product non-goals and are unnecessary for this requirement.

### Replace ADB transport

Rejected for this issue. Alternate transports remain a separate product/architecture decision. Issue #133 is only a bootstrap/recovery capability for the current transport.

## Consequences

Positive:

- broken-screen/unattended Android devices can recover the existing Wireless ADB transport after reboot;
- no Termux/Termux:Boot dependency;
- no change to CXI, helper protocol, pointer/keyboard routing, or `app_process` execution;
- missing privilege/platform support fails locally without affecting normal USB ADB use.

Costs/risks:

- `adb_wifi_enabled` is not a stable public SDK contract and may change on future Android/OEM releases;
- the recovery package must be installed and granted `WRITE_SECURE_SETTINGS` once while ADB is already available;
- the one exported setup Activity is permission-protected by `WRITE_SECURE_SETTINGS`; setup must fail closed if the authorized ADB shell cannot launch it;
- OEM background/boot behavior still requires real-device evidence; unit tests cannot prove boot-time execution;
- installing the APK creates an additional Android package lifecycle that must remain narrowly scoped to recovery.

## Validation

Automated acceptance:

- Android helper build and unit tests pass;
- recovery policy tests cover unsupported platform, no Wi-Fi/transient retry, idempotent already-enabled state, enable-and-verify success, failed write, write-cleared verification failure, and permission denial.

Physical Android 12 acceptance on the exact PR HEAD:

1. run the setup script over an authorized ADB connection;
2. confirm `_adb-tls-connect._tcp` is advertised;
3. reboot without USB/local-screen recovery;
4. wait for the device to reconnect to Wi-Fi;
5. confirm `_adb-tls-connect._tcp` reappears through mDNS;
6. reconnect and capture `adb logcat -d -s CrossInputWirelessAdb`;
7. confirm the existing `app_process` helper workflow still starts normally.

No merge-ready claim is valid until this physical check is recorded.

## Revisit conditions

Revisit or remove this mechanism when any of the following becomes true:

- Android provides a stable public unattended Wireless debugging recovery API;
- the `adb_wifi_enabled` behavior changes or stops working on supported devices;
- the product adopts a non-ADB transport that removes the reboot dependency; or
- future Android Wireless ADB behavior makes this bootstrap redundant and equivalent reliability is physically demonstrated.
