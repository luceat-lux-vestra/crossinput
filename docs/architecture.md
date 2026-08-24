# CrossInput Architecture

> Status: rebaseline implementation re-audited for v0.1.x stabilization on
> 2026-08-13. The current v1 implementation remains macOS → Android and
> keeps the ADB, app_process, UHID, and InputManager paths. Fresh device
> evidence for the semantic pointer path remains a separate completion gate.

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
                                ├─ InputManager backend (explicit target routing)
                                └─ UHID backend (system-routed compatibility/use)
```

An Android phone display, a Samsung DeX desktop display, and another Android
display exposed by the helper are all instances of the remote-target concept.
DeX is a supported target/use case, not a CrossInput core state or type.

## Responsibility boundaries

### macOS application

```text
Presentation
├─ MenuBar
├─ Settings              per-host-display handoff edge
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
owns the current `SessionState`, keeps a candidate session private until HELLO
and capability negotiation succeed, and replaces stale sessions;
`TargetSelectionController` confirms `SELECT_DISPLAY` before publishing a
selection and rejects stale responses; `InputSender` returns a semantic
delivery result; and `ControlHandoffController` is the thin capture/safety
composition boundary. The pointer queue is bounded: adjacent movement events
and adjacent scroll events coalesce into one delivery batch (ADR-0011),
button transitions stay ordered boundaries, and saturation of a coalescible
kind is local backpressure (`.cancelled`) rather than remote failure.
The menu bar composition root wires the controllers, while `AppModel` exposes
their presentation-facing state. Host display enumeration and persisted edge
choices remain presentation/configuration concerns: every current macOS
display is shown independently from the Android remote-target list, and its
selected edge is applied to `InputCapture`.

### Android helper

```text
Session
└─ CXI session and frame dispatch

Target discovery
└─ AndroidDisplayDiscovery
   └─ Android DisplayManager/reflection adapter
      └─ optional runtime-detected system display IDs

Input dispatcher
├─ PointerDispatcher       target-routing policy and failure handling
│  ├─ InputManagerPointerInjector (explicit display routing)
│  └─ UhidPointerInjector (system-routed)
└─ KeyboardInjector
   ├─ UhidKeyboardInjector
   └─ InputManagerKeyboardInjector
```

The helper is the only layer that interprets Android display metadata and
chooses an injection backend. The macOS side receives a v1-compatible display
record today, but application code consumes a normalized remote-target model.
UHID descriptors, HID reports, reflection, hidden Android constants, and
backend failure policy do not cross the application boundary. The helper's
`PointerDispatcher` owns semantic pointer backend selection. UHID reports are
system-routed and do not carry a selected display ID, so the normal selected-
target path uses `InputManagerPointerInjector`, which sets the event display ID
explicitly and fails closed when that API is unavailable. `POINTER_RESULT`
carries the accepted movement back to macOS, so handoff accounting never
trusts only a successful pipe write.

On Samsung builds where the public `DisplayManager.displays` list omits a
system-visible DeX virtual display, the helper's discovery adapter optionally
reflects `DisplayManagerGlobal.getDisplayIds()` at runtime and merges those
handles into `DISPLAY_LIST`. If that hidden API is unavailable, the public
display list remains the bounded fallback.

## Lifecycle separation

The three lifecycles are related but not interchangeable:

| Lifecycle | States | Owns |
|---|---|---|
| Session | `disconnected`, `connecting`, `ready`, `reconnecting`, `failed` | ADB/helper process, CXI handshake, request correlation, disconnect/reconnect |
| Control | `local`, `arming(edge)`, `remote`, `returning` | Pointer ownership, edge handoff, emergency release, key/button cleanup |
| Target | `unavailable`, `available`, `selecting(targetId)`, `selected(targetId)` | Discovery snapshot, confirmed selection validity, display disappearance/reappearance |

Session failure must release local input without waiting for a target refresh.
A target disappearing invalidates selection without implying that the ADB
session is dead. A control return does not disconnect the remote session.

The existing `EdgeSwitchStateMachine` remains the serialized safety mechanism
for edge hysteresis, watchdogs, stale-transition rejection, and emergency
return. Its implementation is a handoff component; connection lifecycle is
owned by the application/session layer and must not be added to the handoff
state model.

`DisplayDiscovery` currently reports display removal as helper diagnostics and
does not emit a dedicated v1 removal frame. Selected-target invalidation and
display reappearance propagation remain follow-up work in issue #17; this is a
known verification boundary, not a completed current capability.

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
- Selected-target pointer delivery requires an explicit-display backend. UHID
  remains available for system-routed use but is not reported as a successful
  target-specific backend.
- Emergency release is local, bounded, and fail-safe on every failure path.

## Safety invariant

> No CrossInput state may permanently trap the user's local pointer or
> keyboard control.

The invariant requires local recovery for helper crash, timeout, unexpected
disconnect, stale callbacks, failed handoff, and capture shutdown. Held
modifiers and buttons are released during remote-to-local transition, external
control takeover, and helper cleanup. A takeover passes the triggering external
event through and never warps the pointer. No diagnostic path logs key codes,
clipboard contents, or input payloads.

## Technology decisions retained

- Swift native macOS menu bar application and native macOS APIs.
- CGEventTap pointer/keyboard capture and screen-edge handoff.
- ADB transport with `app_process` helper execution.
- UHID semantic pointer injection as a system-routed backend.
- InputManager semantic pointer injection as the explicit-display backend for
  selected-target delivery.
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
[CXI v2 design](../protocol/v2-design.md). The rebased integration audit is
recorded in
[the 2026-08-13 research note](research/architecture-rebaseline-2026-08-13.md).
