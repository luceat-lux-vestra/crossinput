# CrossInput Architecture

> Status: rebaseline implementation complete for v0.1.x stabilization. The
> current v1 implementation remains macOS → Android and keeps the ADB,
> app_process, UHID, and InputManager paths. Fresh device evidence for the
> semantic pointer path remains a separate completion gate.

CrossInput is an input bridge. It captures semantic input on a local host and
safely hands control to a selected remote target. The current product is
distributed as Ampersand, but the domain is CrossInput rather than Samsung DeX.

## Current topology

```text
macOS host
  └─ Host input capture (pointer, keyboard)
       └─ Screen-edge control handoff
            └─ Remote session
                 └─ CXI v1 over ADB
                      └─ Android target display
                           └─ Android input dispatcher
                                ├─ UHID backend (primary)
                                └─ InputManager backend (fallback)
```

An Android phone display, a Samsung DeX desktop display, and another Android
display exposed by the helper are all instances of the remote-target concept.
DeX is a supported target/use case, not a CrossInput core state or type.

## Responsibility boundaries

### macOS application

```text
Presentation
├─ MenuBar
├─ Settings
└─ Diagnostics

Application
├─ SessionController       connection/reconnect orchestration
├─ ControlHandoffController edge activation and emergency return
└─ TargetSelectionController refresh/selection policy

Host Input
├─ PointerCapture
├─ KeyboardCapture
└─ EmergencyRelease

Remote
├─ RemoteSession           CXI request/event session
├─ RemoteTargetCatalog     normalized target list and selection
└─ InputSender             semantic pointer/keyboard delivery

Transport
└─ AdbTransport            adb process and byte-stream ownership

Protocol
└─ CXI v1                   compatibility wire codec
```

These boundaries are implemented in the current source. `SessionController`
owns the current `SessionState` and replaces stale sessions;
`TargetSelectionController` confirms `SELECT_DISPLAY` before publishing a selection and rejects
stale responses; `InputSender` returns a semantic delivery result; and
`ControlHandoffController` is the thin capture/safety composition boundary.
The menu bar composition root wires the controllers, while `AppModel` exposes
their presentation-facing state.

### Android helper

```text
Session
└─ CXI session and frame dispatch

Target discovery
└─ AndroidDisplayDiscovery
   └─ Android DisplayManager/reflection adapter

Input dispatcher
├─ PointerDispatcher       UHID primary and deterministic fallback policy
│  ├─ UhidPointerInjector
│  └─ InputManagerPointerInjector
└─ KeyboardInjector
   ├─ UhidKeyboardInjector
   └─ InputManagerKeyboardInjector
```

The helper is the only layer that interprets Android display metadata and
chooses an injection backend. The macOS side receives a v1-compatible display
record today, but application code consumes a normalized remote-target model.
UHID descriptors, HID reports, reflection, hidden Android constants, and
backend failure policy do not cross the application boundary. The helper's
`PointerDispatcher` owns semantic pointer backend selection; a failed UHID
write returns a delivery result and may fail over without retrying a partially
delivered multi-report move. `POINTER_RESULT` carries the accepted movement
back to macOS, so handoff accounting never trusts only a successful pipe write.

## Lifecycle separation

The three lifecycles are related but not interchangeable:

| Lifecycle | States | Owns |
|---|---|---|
| Session | `disconnected`, `connecting`, `ready`, `reconnecting`, `failed` | ADB/helper process, CXI handshake, request correlation, disconnect/reconnect |
| Control | `local`, `arming(edge)`, `remote(target)`, `returning` | Pointer ownership, edge handoff, emergency release, key/button cleanup |
| Target | `unavailable`, `available`, `selecting(targetId)`, `selected(targetId)` | Discovery snapshot, confirmed selection validity, display disappearance/reappearance |

Session failure must release local input without waiting for a target refresh.
A target disappearing invalidates selection without implying that the ADB
session is dead. A control return does not disconnect the remote session.

The existing `EdgeSwitchStateMachine` remains the serialized safety mechanism
for edge hysteresis, watchdogs, stale-transition rejection, and emergency
return. Its implementation is a handoff component; connection lifecycle is
owned by the application/session layer and must not be added to the handoff
state model.

## Dependency rules

- Edge switching calls a remote-session/input-sender boundary; it does not run
  an ADB command.
- Session orchestration does not know UHID report descriptors or Android input
  backend classes.
- macOS application code does not interpret Android `Display.FLAG_*`, desktop
  constants, or hidden display IDs. The v1 decoder remains a compatibility
  adapter until the v2 target model is introduced.
- macOS owns semantic events (`PointerMove`, `PointerButton`, `Scroll`,
  `KeyDown`, and `KeyUp`), not HID reports.
- The normal Ampersand pointer path uses `POINTER_MOVE_REL`, `POINTER_BUTTON`,
  and `POINTER_SCROLL`. v1 `CREATE_HID_DEVICE`, `HID_REPORT`, and
  `DESTROY_HID_DEVICE` remain decoded and handled by the helper only for
  legacy compatibility clients.
- Android-specific discovery and backend selection stay behind helper adapters.
- Emergency release is local, bounded, and fail-safe on every failure path.

## Safety invariant

> No CrossInput state may permanently trap the user's local pointer or
> keyboard control.

The invariant requires local recovery for helper crash, timeout, unexpected
disconnect, stale callbacks, failed handoff, and capture shutdown. Held
modifiers and buttons are released during remote-to-local transition and helper
cleanup. No diagnostic path logs key codes, clipboard contents, or input
payloads.

## Technology decisions retained

- Swift native macOS menu bar application and native macOS APIs.
- CGEventTap pointer/keyboard capture and screen-edge handoff.
- ADB transport with `app_process` helper execution.
- UHID as the primary Android injection path.
- InputManager injection as the Android fallback where available.
- macOS → Android one-way input for the current scope.
- CXI v1 compatibility during the rebaseline.

## Explicit non-goals

This rebaseline does not introduce Electron, Node, Python, an installed helper
APK, Bluetooth HID, a network transport replacement, bidirectional input,
distributed control, a dependency-injection framework, a generic event bus, or
a repository rewrite. CXI v2 is design-only and is not shipped by this work.

## Verification boundary

Unit/build checks establish protocol compatibility and failure-path behavior.
They do not replace on-device evidence. A release or completion claim for
pointer routing, keyboard delivery, display selection, reconnect, or emergency
recovery requires the real-device ADB logs and screen confirmation required by
`AGENTS.md`. Edge-switch stability requires 100 repeat edge-switch tests.

See [product definition](product.md), [roadmap](roadmap.md),
[ADR-0009](adr/ADR-0009-architecture-rebaseline.md), and the
[CXI v2 design](../protocol/v2-design.md).
