# CrossInput Roadmap

> Updated: 2026-09-03. The current product baseline remains DeX-first and
> Android-capable, but the **target implementation architecture is being
> deliberately re-evaluated under Architecture Leap #101**. Historical classes,
> modules, controllers, queues, and protocol adapters are evidence, not
> preservation requirements.

## Product baseline

CrossInput is a **DeX-first, Android-capable macOS input bridge**.

The validated product direction remains:

```text
macOS host -> local control handoff -> one Android device -> selected display
```

Samsung DeX is the primary target/use case. The built-in phone display remains a
supported secondary target through display selection. Pointer and keyboard input
are macOS → Android. Clipboard/data sharing is a separate capability and may be
bidirectional.

The currently shipped/validated transport and protocol baseline remains ADB /
`app_process` with CXI v1 until an explicitly approved migration supersedes it.

## Current program

### Architecture Leap — #101

[Architecture Leap #101](https://github.com/luceat-lux-vestra/crossinput/issues/101)
is the authority for the target architecture and implementation sequencing.

The Leap intentionally permits broad internal redesign, replacement, deletion,
and module restructuring when that produces clearer ownership and safer
lifecycle/concurrency behavior. **Current class/module boundaries are not
compatibility requirements.**

The stable responsibility Tracks are:

- #114 — architecture: target ownership, concurrency, and semantic boundaries;
- #115 — host: macOS capability, capture, suppression, and control ownership;
- #116 — remote: delivery, Android helper, protocol, and backend boundaries;
- #117 — app: composition and presentation ownership; and
- #118 — quality: adversarial verification, physical acceptance, and legacy
  removal.

Code-heavy Leap work remains gated by the accepted production outcome of #96 as
described by #101. Task-level GitHub dependencies are authoritative for actual
execution order.

### Repository hardening — #110

Repository/delivery hardening is separately owned by Epic #110. Its controls do
not define the runtime target architecture.

The hardening baseline includes protected merge gates, workflow-security/drift
checks, release provenance, and the independent ADR-0012 physical stability
evidence contract.

### ADR-0012 Level-3 physical stability — #68

Issue #68 remains the canonical release-stability tracker. Its current
post-rewrite lineage is **0 / 100 accepted physical handoff/return cycles** and
therefore **INCOMPLETE**.

CI, unit tests, state-machine loops, or Leap task acceptance cannot satisfy this
gate. Eligible credit comes only from real physical cycles on one valid release-
candidate lineage, classified by the canonical analyzer. Production behavior
changes that invalidate the lineage reset/apply the accounting rules in
ADR-0012.

See [testing](testing.md) and
[ADR-0012](adr/ADR-0012-real-use-handoff-stability-evidence.md).

## Validated behavior to preserve unless explicitly superseded

Architecture may change; validated product semantics and safety evidence do not
silently disappear. The Leap must revalidate and intentionally preserve or
supersede relevant behavior including:

- pointer movement, buttons, drag, vertical/horizontal scroll;
- keyboard delivery, modifier handling, shortcut suppression, and Korean input;
- screen-edge handoff and emergency local return;
- Android display discovery/selection without a hardcoded display ID;
- DeX desktop pointer behavior currently validated through system-routed UHID;
- non-desktop explicit-display pointer behavior through InputManager;
- reconnect/stale-work rejection and held-input cleanup;
- bounded/nonblocking host input paths;
- CXI v1 compatibility during the migration unless a separately approved
  protocol migration supersedes it; and
- privacy rules that prohibit input payloads, key contents, clipboard contents,
  or equivalent sensitive data from normal diagnostics.

Preserving a behavior does not require preserving the class or mechanism that
currently implements it.

## Product backlog

### Text clipboard — #89

Bidirectional UTF-8 text clipboard synchronization remains a near-term product
capability. It requires capability negotiation, echo-loop suppression, bounded
payloads, lifecycle/reconnect behavior, and metadata-only diagnostics.

Its implementation must fit the architecture approved under #101 rather than
freezing the pre-Leap `InputSender`/session structure.

### Image clipboard — #90

Bidirectional image clipboard synchronization remains backlog work after text
clipboard semantics are stable.

### File transfer — #91

File clipboard / transfer remains backlog work and requires explicit streaming,
storage, cancellation, validation, and size-limit design.

### Keyboard target behavior — #92

Phone-versus-DeX keyboard routing when both displays are present still requires
physical evidence. Do not infer routing from implementation structure.

## Future extension points

### CXI v2 — #93

CXI v2 remains a future migration target for normalized targets, semantic input,
capability negotiation, clipboard/data sharing, backend independence, and
transport independence. v1 remains the compatibility baseline until a separate
go/no-go decision and migration evidence supersede it.

### Alternate local transports — #94

ADB/`app_process` remains the current/default transport. A second local
transport may be evaluated only when a concrete product need justifies it. Do
not build a speculative transport plugin framework.

### Other platforms

Windows/Linux hosts or broader target families remain future considerations,
not current commitments and not architecture drivers without a concrete use
case.

## Completed stabilization work

Items already completed should not remain in the active backlog merely because
an older roadmap listed them. In particular, #47 (explicit Disable Edge Switch
and Disconnect controls) is complete; its behavior is now baseline evidence to
revalidate through the Leap rather than unfinished roadmap work.

## Explicit product non-goals

Unless a separately approved product decision changes them:

- Android → macOS pointer or keyboard input;
- Android as a macOS pointing device;
- simultaneous control of multiple Android devices;
- cloud relay/account/server infrastructure; and
- root or Knox bypass.

A **broad internal redesign is no longer a non-goal**. #101 explicitly permits
it when performed through independently reviewable tasks and when validated
product/safety behavior remains coherent at every merged step.

## Decision rule

> Preserve validated product semantics, device facts, safety invariants, and
> reproducible evidence. Re-design implementation ownership freely where the
> approved Leap shows that the old structure is unsafe or unnecessarily hard to
> reason about.

See [architecture](architecture.md), [product definition](product.md), the
[ADR index](adr/), and [CXI v2 design](../protocol/v2-design.md).
