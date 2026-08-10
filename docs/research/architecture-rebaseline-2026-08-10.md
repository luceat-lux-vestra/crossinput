# Architecture Rebaseline Audit and Verification

> Scope: issue #41 / PR #42 follow-up. Updated: 2026-08-11.
> This record separates implementation checks from real-device evidence.

## Implementation boundary

The follow-up completed the code boundaries that were previously only
described in ADR-0009:

- `SessionController` owns `SessionState`, helper lifecycle, reconnect entry,
  and stale-session callback rejection.
- `EdgeSwitchStateMachine` owns only `disabled`, `localActive`, `edgeArmed`,
  `remoteActive`, and `returning`. External failure is a
  `remoteUnavailable` control command, not a session state.
- `ControlHandoffController` owns capture suppression/release and credits the
  handoff position only after `InputSender` receives the helper's
  `POINTER_RESULT` accepted movement.
- `InputSender` is the normal macOS pointer/keyboard path. AppModel no longer
  owns UHID descriptors, reports, device IDs, or button state.
- `AdbTransport` owns ADB process and binary channel startup. `RemoteSession`
  owns CXI handshake, correlation, timeout, and event dispatch.
- The helper now has `PointerDispatcher`, `UhidPointerInjector`, and
  `InputManagerPointerInjector`. UHID is preferred; a failed report can fail
  over, while a partially delivered split movement is never retried.
- `TargetSelectionController` confirms `DISPLAY_CHANGED` before publishing a
  selected target and ignores stale A/B responses or disappeared targets.
- CXI v1 now carries `POINTER_RESULT` delivery status without a version bump;
  raw HID command compatibility remains unchanged.
- v1 `CREATE_HID_DEVICE`, `HID_REPORT`, and `DESTROY_HID_DEVICE` remain in the
  helper compatibility handler. The current Ampersand path sends semantic
  `POINTER_*` messages and does not use those raw commands.

## Local checks

Commands run from the repository on 2026-08-11:

```text
cd apps/macos && swift test --disable-sandbox
-> pass: 40 XCTest cases and 29 Swift Testing cases

cd android/helper && ./gradlew test
-> pass: Android helper unit tests and debug/release Kotlin compilation

cd android/helper && ./gradlew assembleDebug
-> pass: debug APK build

node protocol/scripts/check-fixtures.mjs
-> pass: 15 v1 fixtures verified

find scripts -name '*.sh' -print0 | xargs -0 -n1 bash -n
-> pass

git diff --check
-> pass
```

The Android run used the repository's declared JDK 17 / Gradle 8.10.2 toolchain.
The environment emitted existing compileSdk 35 / AGP 8.5.2 and SDK XML
compatibility warnings; no source or fixture validation failed.

## Device evidence status

The existing 2026-08-10 InputManager keyboard fallback evidence remains valid
for that unchanged keyboard fallback path. On 2026-08-11, a fresh helper-level
SM-G977N run also covered semantic pointer move/button/scroll delivery with
automatic UHID selection and a forced InputManager pointer fallback; both
returned `POINTER_RESULT` delivered statuses and shut down cleanly.

The follow-up run on 2026-08-11 did provide one real macOS app edge handoff and
100 consecutive real event-tap/helper edge handoffs. The diagnostic segment
contained 100 matching `boundaryCrossed` returns, balanced cursor hide/show
events, and no watchdog, remote-unavailable, or emergency return. The helper
also registered `Ampersand Mouse` as `CURSOR | EXTERNAL` during the run.

The preserved PR record is [PR #42 device verification comment](https://github.com/luceat-lux-vestra/crossinput/pull/42#issuecomment-5246363534).

The run still did not provide secure target-screen pixel confirmation,
keyboard text/composition regression after the controller split, target
selection rollback, or reconnect failure-path evidence. `screencap -d 6 -p`
returned an empty file for the target display. PR #42 must not close #41 or
claim full completion until the remaining screen-confirmed matrix is attached.

The handoff model was also exercised through 100 complete four-edge cycles
with `swift test --disable-sandbox --filter EdgeSwitchStateMachineTests`. That
test and the real left-edge event-tap repetition both passed, but neither is a
substitute for secure target-screen confirmation.

## Required next verification

Run the remaining matrix in [`docs/testing.md`](../testing.md), including DeX
and phone targets, semantic pointer movement/buttons/scroll, forced InputManager
pointer fallback, keyboard and Korean composition, helper/ADB failure recovery,
target removal/reappearance, and secure target-screen confirmation. Keep logs
metadata-only and attach the screen confirmation and ADB/logcat excerpts to
the PR or issue.
