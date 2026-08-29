# CrossInput Roadmap

> Updated: 2026-08-29. This roadmap separates current product commitments,
> near-term work, backlog features, and future extension points. A green local
> build is not an on-device completion record.

## Product baseline

CrossInput is **DeX-first, Android-capable**.

```text
macOS host → CXI v1 → ADB/app_process → one Android device → selected display
```

Samsung DeX is the primary target/use case. The built-in phone display remains
a supported secondary target through the existing display-selection model.
Pointer and keyboard input are macOS → Android. Clipboard/data sharing is a
separate capability and may be bidirectional.

## Current / stabilization

- Pointer movement, buttons, drag, vertical/horizontal scroll.
- Keyboard delivery, modifier handling, shortcut suppression, and Korean input.
- Screen-edge handoff and emergency return.
- Android display discovery and selection without a hardcoded display ID.
- DeX desktop pointer routing through system-routed UHID in AUTO mode.
- Non-desktop pointer routing through InputManager explicit-display injection.
- Session/control/target lifecycle separation.
- Reconnect, stale-session protection, bounded pointer/scroll delivery, and fail-safe input cleanup.
- HELLO/capability negotiation before a candidate session is published for input delivery.
- Display hot-plug/state reliability and remaining regression work (#17).
- Explicit disable/disconnect UI lifecycle controls (#47).
- Remaining pointer-trap/release-stability evidence (#52, #68).
- Helper packaging/deployment and distribution follow-up.
- Verify keyboard behavior when selecting phone versus DeX while both displays are present (#92).

The current architecture remains the baseline. This roadmap does not authorize a repository rewrite, reverse input, a new transport implementation, or a CXI v2 migration as part of stabilization.

## Near term

### Bidirectional text clipboard (#89)

Implement UTF-8 text clipboard synchronization between macOS and Android.
Requirements include capability negotiation, echo-loop suppression, bounded
payload handling, lifecycle/reconnect behavior, and metadata-only diagnostics.
CXI v1 may be extended additively if that is the lowest-risk implementation;
text clipboard does not require a v2 migration.

### Product/documentation consistency (#88)

Complete the product-scope rebaseline so product, architecture, ADRs, protocol
design, README, and issue backlog describe the same system.

### Current stabilization backlog

- Complete display hot-plug/state regression (#17).
- Add explicit disable/disconnect UI controls (#47).
- Complete pointer-trap escape-path verification (#52).
- Accumulate ADR-0012 Level-3 physical stability evidence (#68).
- Continue helper packaging/deployment and distribution work under the existing ADR gates.

## Backlog

- Bidirectional image clipboard synchronization (#90).
- File clipboard / file transfer with explicit streaming/storage, cancellation, validation, and size-limit design (#91).
- Additional clipboard MIME types only after text/image behavior is stable.

These are planned backlog capabilities, not non-goals.

## Future extension points

### CXI v2 (#93)

Keep and refine the v2 design as a future migration target. The design should
cover normalized opaque targets, semantic pointer/keyboard events, capability
negotiation, clipboard/data sharing, backend independence, and transport
independence. Migration requires a separate go/no-go gate; v1 remains production
until then.

### Alternate local transports (#94)

ADB/app_process remains the current/default transport. Future work may evaluate
a second local transport such as direct LAN/TCP or another USB-local channel
when a real product need exists. Preserve the transport seam, but do not build a
transport plugin framework or second implementation speculatively.

### Other platforms

Windows/Linux hosts or broader target families may be evaluated later. They are
not current commitments and must not drive current architecture without a
concrete use case.

## Explicit non-goals

- Android → macOS pointer or keyboard input.
- Android as a macOS pointing device.
- Simultaneous control of multiple Android devices.
- Cloud relay/account/server infrastructure.
- Root or Knox bypass.
- Broad repository rewrite solely for architectural purity.

## Accepted but not implemented

Existing ADRs remain historical records unless explicitly superseded. In particular:

- ADR-0004's bundled-ADB release path remains pending.
- ADR-0005's Homebrew tap remains pending.
- ADR-0006's installed-app UHID experiment remains deferred.
- ADR-0003 and ADR-0009 are superseded only in product-positioning statements by ADR-0013; their compatible historical and architecture decisions remain documented.

## Decision rule

> Preserve existing proven behavior and justified seams. Add new abstraction or implementation complexity only for a current requirement or an explicitly approved extension with a concrete use case.

See [product definition](product.md), [architecture](architecture.md), the
[ADR index](adr/), and [CXI v2 design](../protocol/v2-design.md).
