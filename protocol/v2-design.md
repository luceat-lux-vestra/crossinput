# CXI v2 Design

> Status: design only. CXI v1 remains the production compatibility protocol.
> This document does not change message numbers, fixtures, or implementations.

## Goals

CXI v2 should describe a remote target and semantic input without requiring the
macOS caller to understand Android display constants or an injection backend.
The design must preserve the current one-way macOS → Android product direction
while leaving room for target capability negotiation.

## Target model

The target list should use an opaque identifier and normalized fields:

```text
TARGET_LIST

targetId       opaque identifier; not an Android display ID in the contract
name           user-facing target name
type           normalized target kind (phone, external, virtual, unknown)
geometry       width, height, density, rotation
capabilities   semantic input capabilities
availability   available/unavailable with a reason when known
```

The helper may use an Android display ID internally. It must not make that
implementation identifier the v2 contract. A selected target remains valid only
while its opaque ID is present and available in the current catalog.

## Semantic input

The protocol's center is an input event, not a HID packet:

```text
POINTER_MOVE   relative dx/dy
POINTER_BUTTON button and state
POINTER_SCROLL horizontal/vertical scroll
KEY_DOWN       semantic key identity and modifiers
KEY_UP         semantic key identity and modifiers
```

The exact key identity representation needs a separate compatibility review;
v1 currently carries Android `KeyEvent` values. A v2 sender must not construct
UHID reports or depend on `InputManager` behavior.

## Capability negotiation

The session may negotiate capabilities such as:

```text
pointer.relative
pointer.buttons
pointer.scroll
keyboard.physical
keyboard.text
target.multi-display
```

Unknown capabilities are ignored. A capability that is unavailable must result
in an explicit unsupported outcome or a safe local recovery path, never silent
input loss that leaves a key or button held.

## Backend independence

The v2 protocol must not expose:

- UHID descriptor bytes.
- UHID report layout.
- InputManager reflection or hidden API names.
- Android input-device lifecycle.
- Android `Display.FLAG_*` values or raw display IDs.

The Android helper maps semantic events to the selected local backend. Backend
selection remains helper policy: UHID first, then InputManager where available,
with metadata-only diagnostics and deterministic cleanup.

## v1 leakage inventory and containment

The following v1 fields are intentionally retained for compatibility but are
platform-specific:

| v1 field/behavior | Leakage | Containment until v2 |
|---|---|---|
| `displayId` | Android display identifier is exposed | Treat as an opaque value in application code and isolate selection in a target adapter |
| `type` value `7` | `FLAG_DESKTOP`-derived desktop classification | Normalize on the helper side for new APIs; keep v1 codec compatibility |
| `flags` | Raw Android `Display.FLAG_*` bit mask | Do not branch on flags outside the v1 compatibility adapter |
| `state` | Android `Display.STATE_*` numeric values | Map to availability at the target boundary |
| `KEY_EVENT.keyCode` | Android `KeyEvent.KEYCODE_*` values | Keep v1 semantics; define a platform-neutral v2 key identity |
| `KEY_EVENT.metaState` | Android `KeyEvent.META_*` bit mask | Keep v1 semantics; define normalized modifier bits in v2 |
| `CREATE_HID_DEVICE` | HID descriptor crosses the wire | Keep for v1 UHID compatibility; remove from the v2 semantic path |
| `HID_REPORT` | HID report payload and device ID cross the wire | Keep for v1 mouse compatibility; v2 sends semantic events only |

This is documentation and containment, not a v1 wire change. New application
code should depend on normalized target and input models even while the v1
decoder remains available.

## Migration constraints

1. Add v2 negotiation without changing v1 fixtures.
2. Implement a v1-compatible adapter during any transition period.
3. Keep v1 and v2 behavior independently testable.
4. Do not ship v2 in the architecture-rebaseline work.
5. Require device evidence for target selection, pointer, keyboard, fallback,
   disconnect, and emergency recovery before retiring v1 paths.

## Open design questions

- Opaque target-ID stability across helper restarts.
- Whether key identity should be physical usage, logical key, or a negotiated
  pair of physical/text events.
- How to represent target removal versus temporary unavailability.
- Whether semantic input acknowledgements are needed for bounded cleanup.
- How a v2 session can coexist with older v1 helpers during reconnect.
