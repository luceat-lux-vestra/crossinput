# CXI v2 Design

> Status: design only. CXI v1 remains the production compatibility protocol.
> This document does not change message numbers, fixtures, or implementations
> and does not commit CrossInput to a v2 migration.

## Purpose

CXI v2 is a future protocol design for CrossInput's existing input and
data-sharing model. It should make the wire contract semantic,
capability-negotiated, target-normalized, backend-independent, and
transport-independent without turning CrossInput into a universal input
framework.

The current product remains DeX-first and Android-capable. v2 should improve the
protocol boundary, not broaden the product by itself.

## Transport independence

CXI is logically above the byte-stream transport.

```text
CrossInput application
      ↓ CXI frames/messages
Transport
      ↓
Remote helper
```

ADB/app_process is the current/default transport. A future v2 design must not
encode ADB process details into the protocol contract so another local transport
can be evaluated later without redefining semantic input or clipboard messages.
Transport independence does not require implementing another transport now.

## Target model

Target records should use an opaque identifier and normalized fields:

```text
TARGET_LIST

targetId       opaque identifier
name           user-facing target name
type           normalized target kind (phone, external, virtual, unknown)
geometry       width, height, density, rotation
capabilities   target/session capabilities
availability   available/unavailable with a reason when known
```

The helper may use an Android display ID internally. It must not make that
implementation identifier the v2 identity contract. A selected target remains
valid only while its opaque ID is present and available in the current catalog.

The product currently controls one Android device at a time but may select among
multiple displays on that device. v2 does not need multi-device orchestration to
model that behavior.

## Semantic input

Pointer and keyboard input remain macOS → Android in the current product. The
protocol's center is a semantic event, not a HID packet:

```text
POINTER_MOVE   relative dx/dy
POINTER_BUTTON button and state
POINTER_SCROLL horizontal/vertical scroll
KEY_DOWN       semantic key identity and modifiers
KEY_UP         semantic key identity and modifiers
TEXT_INPUT     optional negotiated semantic text path if justified
```

The exact key identity representation needs a separate compatibility review;
v1 currently carries Android `KeyEvent` values. A v2 sender must not construct
UHID reports or depend on InputManager behavior. The remote helper maps semantic
input to its local backend.

## Clipboard and data sharing

Clipboard is distinct from input direction and may be bidirectional.

A v2 design should support semantic concepts such as:

```text
CLIPBOARD_OFFER / CLIPBOARD_CHANGED
CLIPBOARD_REQUEST
CLIPBOARD_CONTENT
```

Capabilities should distinguish payload classes rather than assuming every peer
supports them:

```text
clipboard.text
clipboard.image
clipboard.file
```

Text synchronization is the near-term product requirement. Image and file
support are backlog capabilities and may require chunking/streaming rather than
embedding arbitrary large payloads in a single frame.

The design must support echo-loop suppression without logging clipboard
contents. Origin, revision/sequence, and/or content identity may be used, but the
final mechanism belongs to the clipboard implementation design.

## Capability negotiation

Candidate capabilities include:

```text
pointer.relative
pointer.buttons
pointer.scroll
keyboard.physical
keyboard.text
clipboard.text
clipboard.image
clipboard.file
target.multi-display
```

Unknown capabilities are ignored. An unavailable capability must result in an
explicit unsupported outcome or a safe degradation path, never silent input
loss that leaves a key or button held.

## Backend independence

The v2 protocol must not expose:

- UHID descriptor bytes or report layout.
- InputManager reflection or hidden API names.
- Android input-device lifecycle.
- Android `Display.FLAG_*`, `Display.STATE_*`, or raw display IDs as product semantics.

The helper chooses the backend according to target/device policy. On current
Samsung DeX devices, a desktop sink may require system-routed UHID so the visible
cursor follows InputReader, while a non-desktop target can use InputManager
explicit-display routing. v2 must express semantic intent/results without
pretending both backends have identical routing mechanics.

## v1 leakage inventory and containment

The following v1 fields are intentionally retained for compatibility but are
platform-specific:

| v1 field/behavior | Leakage | Containment until v2 |
|---|---|---|
| `displayId` | Android display identifier is exposed | Treat as an opaque value in application code and isolate selection in a target adapter |
| display `type`/`flags`/`state` | Android display constants | Normalize at the target boundary |
| `KEY_EVENT.keyCode/metaState` | Android keyboard constants | Keep v1 semantics; define a platform-neutral v2 key identity |
| `CREATE_HID_DEVICE` / `HID_REPORT` | HID mechanics cross the wire | Keep for v1 compatibility; normal application input remains semantic |

This is documentation and containment, not a v1 wire change. New application
code should depend on normalized target and input models even while the v1
decoder remains available.

## Migration gate

A migration is not automatically scheduled by this document. Before v2
implementation is approved, record:

- the concrete v1 pain or product benefit that justifies migration;
- compatibility and rollout strategy;
- v1/v2 fixture and test strategy;
- helper/app version negotiation;
- device verification matrix;
- rollback and failure behavior.

If migration is accepted:

1. Preserve v1 fixtures and compatibility during transition.
2. Negotiate protocol/capability support explicitly.
3. Keep v1 and v2 behavior independently testable.
4. Require device evidence for pointer, keyboard, target selection, clipboard, fallback, disconnect, and emergency recovery as applicable.
5. Do not combine protocol migration with an unrelated architecture rewrite or transport migration.

## Non-goals

CXI v2 does not by itself commit CrossInput to:

- Android → macOS pointer or keyboard input.
- multiple Android devices simultaneously.
- Windows/Linux hosts.
- arbitrary remote platforms.
- cloud relay.
- a transport plugin framework.

Those require separate product decisions.

## Open design questions

- Opaque target-ID stability across helper restarts.
- Physical vs logical keyboard identity and text-input negotiation.
- Target removal versus temporary unavailability.
- Whether semantic input acknowledgements need broader generalization beyond the current pointer result path.
- Clipboard echo suppression and revision model.
- Clipboard payload size limits and whether image/file data use chunked streams.
- v1/v2 coexistence during helper reconnect and upgrade.

Tracked by issue #93.
