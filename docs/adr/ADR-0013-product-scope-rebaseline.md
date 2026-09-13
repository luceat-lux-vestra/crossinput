# ADR-0013: Rebaseline Product Scope as DeX-first, Android-capable

> Status: **accepted for product scope; architecture-preservation statements superseded by Architecture Leap #101 / ADR-0016**
> Date: 2026-08-29
> Supersedes: the product-positioning parts of ADR-0003 and ADR-0009
>
> **Architecture Leap note (2026-09-13):** this ADR remains authoritative for
> DeX-first/Android-capable product scope, supported input direction, target
> families, clipboard separation, transport status, and CXI v2 status. Its
> statements that a broad repository rewrite was not authorized and that the
> then-current lifecycle/class boundaries should remain intact were constraints
> on using **product repositioning alone** as a rewrite justification. They are
> superseded for internal ownership/concurrency/migration strategy by #101 and
> ADR-0016, which later documented concrete defects/change axes and explicitly
> authorized broad internal replacement while preserving this product scope.

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
3. The built-in phone display remains a supported secondary target through the Android display-selection model.
4. One Android device is controlled at a time; multiple displays on that device are supported, simultaneous multi-device control is not.
5. Pointer and keyboard input remain one-way macOS → Android.
6. Android → macOS pointer/keyboard input and using Android as a Mac pointing device are explicit non-goals.
7. Clipboard is a separate bidirectional data-sharing capability: text is near-term; image and file transfer remain backlog work.
8. ADB/app_process remains the current/default transport. Alternate local transports are an approved future extension point, not a current implementation commitment.
9. CXI v1 remains production. CXI v2 remains a future semantic, capability-negotiated, target-normalized, backend-independent, and transport-independent protocol design that may include clipboard/data sharing.
10. Product repositioning by itself does not justify speculative architecture or unrelated framework work. **Historical architecture-preservation implication superseded:** Architecture Leap #101 / ADR-0016 later established concrete ownership/concurrency change axes and authorizes broad internal redesign within this unchanged product scope.

## Architecture relationship

The following dependency/scope principles from the ADR-0009/ADR-0013 era remain
valid unless a later ADR explicitly supersedes them:

- Session, Control, Target, and capability are separate lifecycle concepts;
- transport and Android injection backends stay behind explicit boundaries;
- host/domain input moves toward platform-neutral semantic input;
- the helper/remote adapter owns Android-specific discovery/backend policy;
- CXI v1 remains the compatibility wire during the Leap unless separately
  approved protocol work supersedes it; and
- abstraction is introduced for demonstrated responsibilities/change axes, not
  hypothetical platforms or generic framework purity.

Concrete pre-Leap class/module boundaries are **not** retained by this ADR after
Architecture Leap. ADR-0016 is normative for SessionHandle, TargetLease,
ControlLease, InputIngress, RemoteCommandLane, remote-close fencing, recovery
cleanliness, and migration ownership.

This ADR still supersedes ADR-0009 where that ADR positioned Samsung DeX as
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

Rejected. The phone display is already a useful selectable target. A DeX-only
type model would remove current capability for naming purity.

### Rewrite the architecture solely because of the new product wording

Rejected. Product repositioning alone was not evidence for a repository rewrite.
Architecture Leap later reached a different implementation conclusion for a
different reason: #101/#102 documented concrete ownership, lifecycle,
concurrency, stale-work, blocking, and cleanup defects. ADR-0016 therefore
supersedes the preservation-first implementation consequence without changing
this ADR's product scope.

### Implement CXI v2 or a second transport as part of the rebaseline

Rejected. Both are approved future extension points, but each requires a
separate concrete need, migration/evaluation gate, and verification plan. This
remains unchanged by Architecture Leap.

## Consequences

Positive:

- Product motivation and documentation match the intended use case.
- Existing phone-display support is retained instead of removed for naming purity.
- Clipboard, CXI v2, and transport work receive explicit status without being mistaken for current commitments.
- Architecture Leap can replace internal ownership without using product scope as an excuse to broaden the product.

Negative:

- "DeX-first, Android-capable" requires care so neither DeX exclusivity nor generic-platform ambitions are implied.
- Keyboard behavior across simultaneous phone/DeX displays still requires explicit device verification.
- Historical ADRs must be read with their later supersession notes; product and implementation authority are intentionally separated.

## Validation

This is primarily a product/documentation decision, so validation is consistency-focused:

- `docs/product.md`, `docs/architecture.md`, `docs/roadmap.md`, README, `AGENTS.md`, and `protocol/v2-design.md` must agree on direction, targets, clipboard scope, transport status, and CXI v2 status.
- Documentation must match the implemented pointer policy: desktop sink candidates prefer system-routed UHID in AUTO mode; non-desktop targets use explicit-display InputManager routing.
- Internal ownership/class boundaries follow ADR-0016 rather than the pre-Leap implementation described by older ADRs.
- CXI v1 remains the production/compatibility protocol; additive v1 safety extensions such as #141 require their own protocol docs/fixtures/implementation/evidence.
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
implicitly through routine refactoring or Architecture Leap implementation work.
