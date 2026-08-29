# ADR-0013: Rebaseline Product Scope as DeX-first, Android-capable

> Status: **accepted**
> Date: 2026-08-29
> Supersedes: the product-positioning parts of ADR-0003 and ADR-0009

## Context

CrossInput began from a concrete Samsung DeX use case: use a Mac's input devices
to control a Galaxy device in DeX mode, including devices that are no longer
convenient to use as handheld phones. During implementation the product wording
became broader than the actual motivation and roadmap, while useful generic
implementation seams such as `RemoteTarget` and `AdbTransport` were also added.

The current implementation supports pointer and keyboard input, selectable
Android displays including the built-in phone display, and a DeX-specific
pointer routing policy required for the visible desktop cursor. Future clipboard
support, alternate transports, and CXI v2 also need a stable scope so extension
points do not become speculative frameworks.

## Decision

1. CrossInput is **DeX-first, Android-capable**.
2. Samsung DeX is the primary target and product use case.
3. The built-in phone display remains a supported secondary target through the existing Android display-selection model.
4. One Android device is controlled at a time; multiple displays on that device are supported, simultaneous multi-device control is not.
5. Pointer and keyboard input remain one-way macOS → Android.
6. Android → macOS pointer/keyboard input and using Android as a Mac pointing device are explicit non-goals.
7. Clipboard is a separate bidirectional data-sharing capability: text is near-term; image and file transfer remain backlog work.
8. ADB/app_process remains the current/default transport. Alternate local transports are an approved future extension point, not a current implementation commitment.
9. CXI v1 remains production. CXI v2 remains a future semantic, capability-negotiated, target-normalized, backend-independent, and transport-independent protocol design that may include clipboard/data sharing.
10. Existing justified architecture boundaries remain. A broad repository rewrite is not authorized by this product rebaseline.

## Architecture retained from ADR-0009

ADR-0009 remains valid for these architecture decisions:

- Session, control-handoff, and target lifecycles are separate.
- Transport and Android injection backends stay behind explicit boundaries.
- macOS application logic consumes normalized targets and semantic input.
- The helper owns Android-specific discovery and backend policy.
- CXI v1 compatibility is preserved during ordinary stabilization work.
- Abstraction is introduced for demonstrated change axes, not every class.

This ADR supersedes ADR-0009 only where that ADR positioned Samsung DeX as
merely incidental to the product definition.

## Pointer-routing clarification

The current AUTO policy is not "InputManager for every selected target".
Desktop sink candidates such as Samsung DeX prefer system-routed UHID because
that path passes through InputReader and moves the visible desktop cursor.
Non-desktop targets use InputManager explicit-display routing. This behavior is
a product-relevant device constraint and must be documented consistently.

The keyboard backend, unlike pointer selection, is not explicitly bound to the
selected display ID. Actual phone-versus-DeX keyboard routing therefore remains
a verification question (#92), not a product guarantee inferred from code.

## Alternatives considered

### Keep the generic host-to-remote positioning

Rejected. It accurately describes some implementation boundaries but no longer
captures the primary product motivation and encourages roadmap drift toward
platforms and directions with no current requirement.

### Make CrossInput DeX-only in the architecture

Rejected. The phone display is already a useful selectable target, and existing
`RemoteTarget`/target-selection abstractions solve a real current problem. A
DeX-only type model would remove capability for naming purity.

### Rewrite the architecture around the new product wording

Rejected. Session, Control, Target, transport, and backend boundaries are
independently justified by current behavior and failure modes. Product
repositioning is not evidence for a repository rewrite.

### Implement CXI v2 or a second transport as part of the rebaseline

Rejected. Both are approved future extension points, but each requires a
separate concrete need, migration/evaluation gate, and verification plan.

## Consequences

Positive:

- Product motivation and documentation match the intended use case.
- Existing phone-display support is retained instead of removed for naming purity.
- Clipboard, CXI v2, and transport work receive explicit status without being mistaken for current commitments.
- Existing lifecycle and backend architecture can remain stable.

Negative:

- "DeX-first, Android-capable" requires care so neither DeX exclusivity nor generic-platform ambitions are implied.
- Keyboard behavior across simultaneous phone/DeX displays still requires explicit device verification.
- Historical ADRs now need to be read together with this superseding product-scope decision.

## Validation

This is primarily a product/documentation decision, so validation is consistency-focused:

- `docs/product.md`, `docs/architecture.md`, `docs/roadmap.md`, README, `AGENTS.md`, and `protocol/v2-design.md` must agree on direction, targets, clipboard scope, transport status, and CXI v2 status.
- Documentation must match the implemented pointer policy: desktop sink candidates prefer system-routed UHID in AUTO mode; non-desktop targets use explicit-display InputManager routing.
- Existing Session/Control/Target and transport/backend boundaries must remain intact unless a separate issue demonstrates a defect.
- CXI v1 fixtures and production source behavior are unchanged by this ADR.
- Device-dependent claims remain subject to `AGENTS.md` and `docs/testing.md`; this ADR does not convert unverified keyboard routing into a support claim.

## Revisit conditions

Revisit this ADR when one of these becomes a concrete product requirement:

- a second production transport,
- a second host platform,
- simultaneous multiple Android devices,
- Android → host input,
- a CXI v2 migration,
- a broader target family that materially changes the product rather than only the implementation.

Each such change requires an explicit scope decision and must not be introduced
implicitly through a routine refactor.
