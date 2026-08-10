# Architecture Rebaseline Audit and Verification

> Scope: issue #41 / architecture rebaseline. Date: 2026-08-10.
> This record separates local checks from real-device evidence.

## 1. Problems found in the previous baseline

- Product and architecture documents described CrossInput primarily as a DeX
  switcher even though the helper already supported a phone display.
- `AppModel` exposed a connection `phase`, an edge `SwitchState`, raw
  `DisplayInfo`, reconnect subprocesses, target selection, input delivery, and
  emergency release in one application file.
- `ConnectionManager` owned both ADB process startup and CXI request/response
  correlation.
- Application code selected targets using raw v1 display type/flag values.
- The Android `Controller` depended directly on the concrete SDK pointer and
  keyboard backend classes.
- CXI v1 intentionally exposes Android display IDs, display flags/state, Android
  key constants, HID descriptors, and HID reports, but this leakage was not
  listed with a containment boundary.
- The roadmap mixed completed implementation, accepted decisions, pending
  device evidence, and future features in one phase table.

## 2. Boundary changes

- Added `SessionState`, `ControlState`, and `TargetState` as independent
  application lifecycle models.
- Added `RemoteTargetID`, `RemoteTarget`, and `RemoteTargetCatalog`; the menu
  bar now consumes normalized targets rather than raw display records.
- Renamed the session role to `RemoteSession` while retaining a deprecated
  `ConnectionManager` compatibility alias.
- Extracted ADB discovery, mDNS endpoint parsing, reconnect, and connected
  serial lookup into `AdbTransport`.
- Added Android `PointerInjector` and `KeyboardInjector` seams. The existing
  SDK pointer implementation is named `InputManagerPointerInjector` with a
  compatibility typealias.
- Extracted UHID keyboard lifecycle into `UhidKeyboardInjector` and renamed the
  reflection implementation to `InputManagerKeyboardInjector`; backend choice
  remains in `KeyboardBackend`.
- Changed the Swift package's application target to an explicit executable
  target and kept the composition root in `App.swift`, resolving the implicit
  `main.swift` target ambiguity without changing startup behavior.

The existing edge state machine remains the safety-critical serialized
implementation for hysteresis, transition sequencing, and emergency release.
Its connection transition methods are a migration seam and are recorded as
technical debt below; the application-facing lifecycle is now separate.

## 3. State model

| Previous application view | Rebaseline view |
|---|---|
| `phase = idle/connecting/ready/error` | `SessionState = disconnected/connecting/ready/reconnecting/failed` |
| `SwitchState` used as the UI state | `ControlState = local/arming(edge)/remote(targetId)/returning` projection |
| raw display selection | `TargetState = unavailable/available/selected(targetId)` |

The edge machine still receives connection-loss/fatal signals for fail-safe
cleanup, but connection status is no longer the menu bar model's source of
truth. A target disappearing invalidates selection and does not imply session
loss. A control return does not disconnect the session.

## 4. Connection and composition responsibilities

- `App.swift` creates the menu-bar scene and application model.
- `AppModel` currently coordinates the lifecycle transition while the split is
  introduced; its ADB subprocess discovery/reconnect code is now delegated to
  `AdbTransport`.
- `RemoteSession` owns CXI framing, pending request correlation, helper stream
  lifetime, and disconnect callbacks. ADB process ownership remains the next
  extraction seam inside that type.
- `AdbTransport` owns ADB-specific endpoint discovery and reconnect commands.

This is deliberately incremental: no speculative dependency-injection layer or
event bus was introduced.

## 5. Android backend responsibilities

- `PointerInjector` is the semantic pointer boundary used by CXI dispatch.
- `InputManagerPointerInjector` retains the existing reflection-based pointer
  injection and display metric behavior.
- `KeyboardInjector` is the semantic keyboard boundary used by CXI dispatch.
- `UhidKeyboardInjector` retains pressed-key-state reporting, device cleanup,
  and report failure handling.
- `InputManagerKeyboardInjector` retains virtual `KeyEvent` construction and
  hidden-API failure handling.
- `KeyboardBackend` retains AUTO/UHID/INPUT_MANAGER selection, fallback policy,
  metadata-only logging, and virtual-key cleanup.

No UHID descriptor, report format, or InputManager implementation detail is
exposed to the macOS application model.

## 6. CXI v1 leakage and v2 design

The complete inventory is in [`protocol/v2-design.md`](../../protocol/v2-design.md).
The important compatibility boundary is:

- v1 `displayId`, `type`, `flags`, and `state` remain decoded as wire fields;
- v1 `KEY_EVENT` retains Android keyCode/metaState semantics;
- v1 `CREATE_HID_DEVICE` and `HID_REPORT` remain available;
- new application code consumes normalized remote targets;
- CXI v2 is documented only and is not negotiated or shipped here.

## 7. Local regression results

Commands run from the repository on 2026-08-11:

```text
cd apps/macos && swift test
→ pass: 85 XCTest cases + 28 Swift Testing cases

JAVA_17_HOME=<JDK 17 installation> \
ANDROID_HOME=<Android SDK installation> \
  ./scripts/build-android-helper.sh test
→ pass: Gradle test and Android helper compilation

node protocol/scripts/check-fixtures.mjs
→ pass: 14 v1 fixtures verified

find scripts -name '*.sh' -print0 | xargs -0 -n1 bash -n
→ pass
```

The Android build emitted only the existing compileSdk/AGP compatibility
warning and `Display.getRealMetrics` deprecation warnings. No protocol fixture
was changed.

## 8. Real-device status

A bounded, non-pointer device smoke was performed on 2026-08-11 against the
available SM-G977N / Android 12 (API 31). The debug helper was rebuilt and
pushed, then driven through HELLO, LIST_DISPLAYS, and SHUTDOWN. The helper
reported a v1 handshake, listed two display records, created and destroyed the
UHID keyboard, and exited cleanly. The metadata-only log excerpt is preserved
in [`evidence/architecture-rebaseline-2026-08-11/`](evidence/architecture-rebaseline-2026-08-11/).

This smoke did not send pointer or keyboard input, select a target, or provide
screen confirmation. Therefore this rebaseline does not claim newly verified
completion for pointer handoff, keyboard delivery, display hot-plug, reconnect,
InputManager pointer fallback, or emergency recovery.

The pre-existing SM-G977N / Android 12 records remain valid evidence for the
unchanged UHID and InputManager keyboard behavior, especially
[`inputmanager-keyboard-fallback-2026-08-10.md`](inputmanager-keyboard-fallback-2026-08-10.md).
The full rebaseline device matrix still needs to be run using
[`docs/testing.md`](../testing.md), including target selection, input routing,
screen confirmation, and 100 repeat edge switches.

## 9. Remaining technical debt

- Extract ADB process/channel ownership from `RemoteSession` into the
  `AdbTransport` runtime seam.
- Move application orchestration from `AppModel` into focused session,
  handoff, and target-selection controllers when tests can preserve the same
  callback ordering.
- Remove connection lifecycle cases from the legacy edge machine after the
  existing transition tests are migrated to the independent control model.
- Add a true helper-side normalized target message when CXI v2 migration is
  authorized; do not alter v1 fields during stabilization.
- Split the generic `HidDeviceManager` lifecycle from semantic pointer delivery
  if a second pointer backend creates a real change axis.

## 10. Next bounded issues

- Issue #17: complete the display hot-plug/ON-OFF/reconnect/stale-selection
  regression matrix.
- Issue #41 follow-up: extract the remaining `RemoteSession` and `AppModel`
  orchestration seams, with no behavior change.
- Future issue: CXI v2 compatibility/migration plan, design first and separate
  from runtime refactoring.
