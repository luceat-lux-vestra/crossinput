# CrossInput Architecture

> Status: product scope rebaseline, 2026-08-29. The implementation architecture
> is retained. This document corrects product positioning and records the
> pointer-routing behavior already implemented in the current v1 code.

CrossInput is a **DeX-first, Android-capable macOS input bridge**. Samsung DeX is
the primary product use case, while the existing remote-target abstraction
continues to support the built-in phone display and other discovered displays on
the same connected Android device.

## Current topology

```text
macOS host
  └─ Host input capture (pointer, keyboard)
       └─ Screen-edge control handoff
            └─ Remote session
                 └─ CXI v1
                      └─ current transport: ADB/app_process
                           └─ Android target display
                                └─ Android input dispatcher
                                     ├─ desktop sink → UHID system routing
                                     └─ other target → InputManager explicit routing
```

Only one Android device is controlled at a time. Target selection is display
selection within that device, not multi-device orchestration.

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
└─ AdbTransport            current ADB process and byte-stream ownership

Protocol
└─ CXI v1                  production compatibility wire codec
```

These boundaries are implemented in the current source and remain justified.
`SessionController` owns `SessionState`, keeps a candidate session private until
HELLO and capability negotiation succeed, and replaces stale sessions;
`TargetSelectionController` confirms `SELECT_DISPLAY` before publishing a
selection and rejects stale responses; `InputSender` returns semantic delivery
results; and `ControlHandoffController` is the capture/safety composition
boundary.

The pointer queue remains bounded: adjacent movement and scroll events coalesce
into delivery batches (ADR-0011), button transitions stay ordered boundaries,
and saturation sheds a coalescible kind locally rather than turning local
pressure into a remote failure. Queued semantic input is generation-tagged so a
replacement session cannot receive stale pointer or keyboard work.

The menu-bar composition root wires the controllers, while `AppModel` exposes
their presentation-facing state. Host-display enumeration and persisted edge
choices remain separate from the Android remote-target list.

`RemoteTarget` remains justified. DeX is the primary target, but the phone
screen is already represented and selectable through the same target model.
Renaming the domain object to a DeX-specific type would remove useful behavior
without solving a current problem.

### Android helper

```text
Session
└─ CXI session and frame dispatch

Target discovery
└─ DisplayDiscovery
   └─ Android DisplayManager/reflection adapter
      └─ optional runtime-detected system display IDs

Input dispatcher
├─ PointerDispatcher       target-routing policy and failure handling
│  ├─ UhidPointerInjector (system-routed)
│  └─ InputManagerPointerInjector (explicit display routing)
└─ KeyboardBackend
   ├─ UhidKeyboardInjector
   └─ InputManagerKeyboardInjector
```

The helper is the only layer that interprets Android display metadata and
chooses an injection backend. The macOS side receives a v1-compatible display
record today, but application code consumes a normalized remote-target model.
UHID descriptors, HID reports, reflection, hidden Android constants, and backend
failure policy do not cross the application boundary.

On Samsung builds where the public `DisplayManager.displays` list omits a
system-visible DeX virtual display, the helper's discovery adapter may reflect
`DisplayManagerGlobal.getDisplayIds()` and merge those handles into
`DISPLAY_LIST`. If that hidden API is unavailable, the public display list
remains the bounded fallback.

## Pointer routing policy

The current production AUTO policy is target dependent:

1. For a desktop sink candidate such as Samsung DeX, the helper prefers the
   **system-routed UHID mouse**. UHID flows through Android's native InputReader
   path, so the visible DeX pointer sprite follows the virtual mouse.
2. For a non-desktop target such as the built-in phone display, the helper uses
   **InputManager explicit-display routing** and sets the selected display ID.
3. If desktop UHID delivery fails, AUTO may fall back to InputManager for the
   selected display according to `PointerDispatcher` failure policy.

A system-routed UHID mouse cannot claim that it targets an arbitrary display ID.
Its use for DeX is intentional because device evidence showed that explicit
InputManager injection can deliver events without moving the visible DeX cursor
sprite. `POINTER_RESULT` still carries semantic delivery results back to macOS,
so handoff accounting does not trust only a successful pipe write.

## Keyboard routing

Keyboard delivery uses UHID with an InputManager virtual-injection fallback.
Unlike pointer selection, the current keyboard backend does not receive the
selected target display ID. The actual routing behavior when phone and DeX
screens are both present must therefore be established by device evidence (#92)
rather than assumed from implementation structure.

## Lifecycle separation

The three lifecycles are related but not interchangeable:

| Lifecycle | States | Owns |
|---|---|---|
| Session | `disconnected`, `connecting`, `ready`, `reconnecting`, `failed` | ADB/helper process, CXI handshake, request correlation, disconnect/reconnect |
| Control | `disabled`, `local`, `arming(edge)`, `remote`, `returning` | edge-switch acquisition, pointer ownership, edge handoff, emergency release, key/button cleanup |
| Target | `unavailable`, `available`, `selecting(targetId)`, `selected(targetId)` | discovery snapshot, confirmed selection validity, display disappearance/reappearance |

Session failure must release local input without waiting for a target refresh. A
A target disappearing invalidates selection without implying that the ADB session
is dead. A control return does not disconnect the remote session.

The `disabled` control state is an intentional user choice, not a disconnected
session state. Disabling Edge Switch releases local ownership and held remote
input while leaving the Session and Target lifecycles ready. Disconnect is an
application-level orchestration boundary: it disables Control first, then asks
SessionController to close the helper/session and invalidate its callbacks.
The menu derives its Enable/Disable and Disconnect actions from these
application projections rather than maintaining a second UI state. A later
explicit Connect runs the established reconnect/target-refresh path and
enables edge switching after a valid target is confirmed.

The existing `EdgeSwitchStateMachine` remains the serialized safety mechanism
for edge hysteresis, watchdogs, stale-transition rejection, and emergency
return. Connection lifecycle is owned by the application/session layer and must
not be added to the handoff state model.

`DisplayDiscovery` currently reports display removal as helper diagnostics and
does not emit a dedicated v1 removal frame. Selected-target invalidation and
display reappearance propagation remain follow-up work in issue #17.

## Clipboard boundary

Clipboard is not part of input ownership. Planned clipboard synchronization is
bidirectional even though pointer/keyboard input remains macOS → Android.

The clipboard feature should use a dedicated semantic boundary rather than
being hidden inside `InputSender`. Text synchronization is near-term; image and
file transfer are separate backlog capabilities. Clipboard contents must never
be logged.

## Protocol and transport boundaries

CXI and transport are separate concepts:

```text
CrossInput application
      ↓ semantic CXI
Transport implementation
      ↓
Android helper
```

ADB/app_process is the current/default transport. `AdbTransport` remains a real
seam because alternate local transports are an approved future extension point,
but no plugin framework or second transport is implemented until a concrete
requirement exists.

CXI v1 remains production. CXI v2 remains a future semantic protocol design for
normalized targets, capability negotiation, backend independence, clipboard and
data sharing, and transport independence. It is not a universal protocol
framework and is not shipped by this rebaseline.

## Dependency rules

- Edge switching calls a remote-session/input-sender boundary; it does not run an ADB command.
- Session orchestration does not know UHID report descriptors or Android input backend classes.
- macOS application code does not interpret Android `Display.FLAG_*`, desktop constants, or hidden display IDs. The v1 decoder remains a compatibility adapter.
- macOS owns semantic events (`PointerMove`, `PointerButton`, `Scroll`, `KeyDown`, and `KeyUp`), not normal-path HID reports.
- The normal Ampersand pointer path uses `POINTER_MOVE_REL`, `POINTER_BUTTON`, and `POINTER_SCROLL`. v1 raw HID handlers remain only for compatibility clients.
- Android-specific discovery and backend selection stay behind helper adapters.
- Emergency release is local, bounded, and fail-safe on every failure path.
- Existing justified abstractions stay; new abstractions require a current requirement or an explicitly accepted future extension point.
- A future extension point is not permission to implement speculative framework machinery before a second implementation exists.

## Safety invariant

> No CrossInput state may permanently trap the user's local pointer or keyboard control.

The invariant requires local recovery for helper crash, timeout, unexpected
disconnect, stale callbacks, failed handoff, capture shutdown, and emergency
return. Held modifiers and buttons are released during relevant remote-to-local
transitions and helper cleanup. No diagnostic path logs key codes, clipboard
contents, or input payloads.

## Technology decisions retained

- Swift native macOS menu bar application and native macOS APIs.
- CGEventTap pointer/keyboard capture and screen-edge handoff.
- ADB transport with `app_process` helper execution.
- UHID semantic pointer injection as a system-routed backend for desktop sink candidates.
- InputManager semantic pointer injection as the explicit-display backend for non-desktop targets and fallback where applicable.
- macOS → Android one-way pointer/keyboard input for the current scope.
- CXI v1 compatibility during stabilization.

## Explicit non-goals

- Android → macOS pointer or keyboard input.
- Using Android as a pointing device for macOS.
- Simultaneous control of multiple Android devices.
- Cloud relay/account/server infrastructure.
- Root or Knox bypass.
- Broad repository rewrite or a new architecture framework without a concrete defect or requirement.

Windows/Linux hosts, additional target families, and alternate transports are
future considerations only and must not distort current code structure.

## Verification boundary

Unit/build checks establish protocol compatibility and failure-path behavior.
They do not replace on-device evidence. A release or completion claim for
pointer routing, keyboard delivery, display selection, reconnect, or emergency
recovery requires the real-device evidence required by `AGENTS.md` and
`docs/testing.md`.

Edge-switch stability is governed by the ADR-0012 release-stability gate: at
least 100 real physical completed handoff/return cycles on one
release-candidate lineage, accumulated through natural use or approved physical
automation and analyzed by `scripts/analyze-handoff-stability.sh`. See
[ADR-0012](adr/ADR-0012-real-use-handoff-stability-evidence.md).

See [product definition](product.md), [roadmap](roadmap.md),
[ADR-0013](adr/ADR-0013-product-scope-rebaseline.md),
[ADR-0009](adr/ADR-0009-architecture-rebaseline.md), and the
[CXI v2 design](../protocol/v2-design.md). The prior architecture audit remains
recorded in [the 2026-08-13 research note](research/architecture-rebaseline-2026-08-13.md).
