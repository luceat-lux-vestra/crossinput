# ADR-0006: Installed Regular App UHID Access Experiment

> Status: **deferred** — v1 is confirmed as adb push + run. The installed app is kept as a v2 candidate.
> Date: 2026-08-03

## Context

Wireless debugging (Developer options) is a barrier for regular users. If the helper can be shipped as an **installed regular APK** (Play Store/sideload) that injects UHID directly, both wireless debugging and adb bundling (ADR-0004) become unnecessary (the Mac connects over TCP directly).

Unknown: whether `/dev/uhid` access is allowed from the app uid (SELinux policy, device permissions). All existing verification ran under adb shell (app_process) — i.e. the shell uid. Access from the app uid (e.g. u0_aXXX) has never been tested.

## Decision (accepted: v1 is adb push + run)

Under the no-root premise, **v1's distribution/run method is confirmed as "adb push + app_process run"** (same pattern as scrcpy).

- Users install nothing on the phone (no home-screen icon/dialogs).
- The only manual step for the user: wireless debugging pairing once (Developer options → Wireless debugging → pairing code).
- adb is bundled with the release (ADR-0004).

The installed regular APK approach (`/dev/uhid` app-uid access) is **deferred as a v2 candidate**:
- The v1 adb push approach is arguably better UX since "the user does nothing on the phone".
- The benefit at this stage is limited relative to the verification cost (Play Store review risk, per-device SELinux differences).

## Alternatives

- Accept one-time wireless debugging pairing: stays as verified, only the entry barrier is high.
- Root/system app: out of scope.

## Consequences

- Positive (outcome A): removes the entry barrier for regular users, no adb bundle needed, distribution expands to Play/sideload.
- Negative: SELinux differs per Android version/device — device coverage must be checked (Samsung/Android 12 first).
- Negative (outcome B): v1 keeps wireless debugging — target power users explicitly.

## Validation

- (pending) `/dev/uhid` open success on a real device + `dumpsys deviceidle`/SELinux avc check
- (pending) UHID mouse create/click on-device verification from an installed app
