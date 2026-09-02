# CrossInput Architecture

> Status: **Architecture Leap in progress, 2026-09-03.**
>
> [Architecture Leap #101](https://github.com/luceat-lux-vestra/crossinput/issues/101)
> is the authority for the target architecture and sequencing. This document
> describes the product invariants, validated current behavior, and target
> architectural constraints that the Leap must preserve or deliberately
> supersede. Pre-Leap classes/modules are not architectural commitments.

CrossInput is a **DeX-first, Android-capable macOS input bridge**. Samsung DeX is
the primary product use case while the built-in phone display remains a
supported secondary target on the same connected Android device.

## Architecture authority

The previous architecture document treated the then-current controller/module
layout as the retained baseline and listed broad repository redesign as a
non-goal. That position is superseded by #101.

The current rule is:

- preserve validated user-visible behavior, device/protocol facts, safety
  invariants, and reproducible evidence;
- re-audit historical behavior before treating it as a requirement;
- allow broad internal redesign, replacement, deletion, and module
  restructuring where it materially improves ownership and correctness;
- keep every merged step coherent and independently reviewable; and
- do not preserve an abstraction merely because historical code/tests contain
  it.

The Leap's native Track hierarchy is the stable target responsibility map:

```text
#101 Architecture Leap
├── #114 architecture — target ownership, concurrency, semantic boundaries
├── #115 host         — macOS capability/capture/suppression/control ownership
├── #116 remote       — delivery/Android helper/protocol/backend boundaries
├── #117 app          — composition and presentation ownership
└── #118 quality      — adversarial verification/physical acceptance/legacy purge
```

Task-level dependencies inside those Tracks are authoritative for implementation
order.

## Current validated topology

The production baseline being reworked is approximately:

```text
macOS host
  -> CGEventTap pointer/keyboard capture
  -> local/remote control handoff
  -> semantic CXI v1 events
  -> ADB / app_process transport
  -> Android helper
  -> selected Android display
     -> desktop sink: system-routed UHID preferred
     -> other target: explicit-display InputManager
```

This topology is **evidence about current behavior**, not a requirement that the
same controller classes, queue structure, process boundaries, or adapter layout
survive the Leap.

## Non-negotiable safety invariants

The target architecture must make these properties explicit and testable:

1. local macOS pointer/keyboard control can never be permanently trapped;
2. stale work from an invalidated Control/Session/Target owner cannot reach a
   replacement owner;
3. held remote keys/buttons are cleaned up or safely invalidated on every
   relevant exit/failure path;
4. local control restoration never waits for successful remote cleanup;
5. input payloads, raw coordinates/deltas, key contents, HID reports, clipboard
   contents, and equivalent sensitive data do not enter normal diagnostics;
6. Session, Control, Target, capability, capture/suppression, and delivery
   ownership are explicit and non-overlapping;
7. Android routing/hidden-API/backend details do not leak into host/domain
   semantics;
8. CoreGraphics/AppKit/TCC details do not leak into remote/domain semantics;
9. capture/event hot paths remain bounded and nonblocking; and
10. cancellation, replacement, reconnect, failure, and disposal have
    deterministic stale-work and cleanup semantics.

These invariants come from #101 and outrank compatibility with pre-Leap internal
structure.

## Product semantics to preserve

Unless an explicit product decision and evidence supersede them, the Leap must
preserve:

- DeX-first operation with selectable Android display targets on one device;
- macOS → Android pointer and keyboard direction;
- explicit local emergency return;
- dynamic display discovery rather than hardcoded display IDs;
- current CXI v1 compatibility during migration;
- ADB/`app_process` as the current production transport until a separately
  approved transport migration exists;
- semantic pointer/keyboard delivery rather than host code constructing Android
  backend details;
- bounded delivery/backpressure behavior;
- deterministic reconnect/replacement and stale-work rejection; and
- metadata-only/redacted diagnostics.

## Current device-routing facts

These facts are useful constraints because they were established by real-device
behavior, even if their implementation owner changes.

### Pointer

For a Samsung DeX desktop sink, the current AUTO path prefers a system-routed
UHID mouse. Device evidence showed that explicit InputManager injection could
deliver events while leaving the visible DeX pointer sprite stationary.

For a non-desktop target such as the built-in phone display, current production
behavior uses explicit-display InputManager routing.

A system-routed UHID device must never be described as explicitly targeting an
arbitrary display ID. Any replacement architecture must keep backend/routing
claims semantically honest.

### Keyboard

Current keyboard delivery uses UHID with an InputManager virtual-injection
fallback. Phone-versus-DeX routing with both displays present remains an
explicit physical-evidence question (#92); implementation structure is not proof
of the resulting target behavior.

## Target ownership model

#101 intentionally requires the Leap to establish the final ownership model
rather than inheriting the old one. At minimum the approved design must make the
following concepts explicit:

### Host capability and capture

Own macOS permissions/capability state, capture/suppression lifetime, local
fail-safe restoration, and interaction with external control. Platform APIs
remain behind host adapters.

### Control

Own whether CrossInput currently controls local or remote input and the bounded
transitions between those states. Control must not become an implicit side
effect of connection callbacks.

### Session / remote connection

Own connection, handshake, replacement, request correlation, cancellation,
reconnect, and invalidation of stale remote work. A failed remote cleanup must
not block local restoration.

### Target

Own discovered remote-target identity, selection, disappearance/reappearance,
and stale selection rejection separately from connection lifetime.

### Semantic input and delivery

Host event capture should produce platform-neutral semantic input before the
remote/Android boundary. Delivery owns serialization/backpressure/cancellation
and must not leak Android injection mechanisms back into host semantics.

### Android helper and backend policy

The helper/Android boundary owns display metadata, hidden/public Android API
adaptation, UHID/InputManager mechanisms, and target-dependent backend policy.
Those details must not become application-domain concepts.

### Application and presentation

Composition/presentation projects authoritative lifecycle/domain state; it does
not become an accidental owner of infrastructure lifetimes, persistence, or
concurrency correctness.

The exact classes/modules implementing these responsibilities are intentionally
not frozen by this document.

## Protocol and transport

CXI and transport remain separate concepts.

CXI v1 is the current compatibility wire protocol. CXI v2 (#93) is a future
migration target for normalized targets, semantic events, capability
negotiation, clipboard/data sharing, backend independence, and transport
independence. A v2 design is not permission to migrate before its go/no-go gate.

ADB/`app_process` is the current/default transport. An alternate local transport
(#94) requires a concrete product need and separate evidence; do not build a
speculative plugin framework.

## Clipboard boundary

Clipboard/data sharing is not input ownership. Planned text clipboard (#89),
image clipboard (#90), and file transfer (#91) require their own semantic,
privacy, lifecycle, size/resource, and loop-suppression contracts.

Clipboard contents must never enter normal diagnostics. Clipboard implementation
must fit the approved Leap architecture rather than reusing a pre-Leap class
solely because it exists.

## Verification authority

Automated tests/CI establish deterministic code/protocol/repository properties.
They do **not** substitute for physical-device evidence when the claim depends on
macOS + Samsung DeX behavior.

Issue #68 remains the canonical ADR-0012 Level-3 release-stability tracker. Its
current post-rewrite lineage is **0 / 100 accepted physical handoff/return
cycles** and therefore incomplete. Leap task acceptance evidence and CI do not
credit that counter.

See [testing](testing.md) and
[ADR-0012](adr/ADR-0012-real-use-handoff-stability-evidence.md).

## Explicit product non-goals

Unless separately approved:

- Android → macOS pointer or keyboard input;
- Android as a macOS pointing device;
- simultaneous control of multiple Android devices;
- cloud relay/account/server infrastructure; and
- root or Knox bypass.

A broad **internal** redesign is not a non-goal. It is explicitly authorized by
#101 when decomposed into reviewable work and constrained by the product/safety
evidence above.

## Historical architecture records

Existing ADRs, research notes, and pre-Leap architecture snapshots remain
historical evidence. Do not rewrite an old observation merely because the target
architecture later changed. When an old decision no longer governs current
implementation, mark or interpret it through its supersession/current-status
record.

See [roadmap](roadmap.md), [product definition](product.md), the [ADR index](adr/),
and [CXI v2 design](../protocol/v2-design.md).
