# CrossInput Roadmap

> Updated: 2026-08-13. This roadmap distinguishes accepted decisions,
> implemented behavior, and evidence status. A green local build is not an
> on-device completion record.

## Product baseline

CrossInput is a macOS-to-Android input bridge. The current path is:

```text
macOS host → ADB/app_process → Android helper → selected display target
```

UHID remains available for system-routed pointer use. The normal selected-target
pointer path uses InputManager explicit-display routing because a UHID report
cannot name an Android display.
Samsung DeX is a supported target, not the product definition.

## Completed

- Repository bootstrap, CI, Swift macOS app, Kotlin helper, and CXI v1.
- CGEventTap pointer and keyboard capture with screen-edge handoff.
- ADB wireless transport and app_process helper startup.
- Android display discovery without a hardcoded display ID.
- Historical UHID pointer and keyboard paths were verified on SM-G977N / Android 12;
  the post-rebaseline semantic pointer path requires fresh evidence.
- InputManager keyboard fallback verified on SM-G977N / Android 12; evidence is
  recorded under `docs/research/inputmanager-keyboard-fallback-2026-08-10.md`.
- macOS shortcut suppression, modifier cleanup, reconnect handling, stale
  callback protection, and emergency release unit coverage.
- v0.1.0 DMG packaging and release documentation.

## Current stabilization

The architecture rebaseline is the current bounded work stream (issue #41):

- Product definition and non-goals.
- Session/control/target lifecycle boundary.
- Remote target terminology and target-selection policy.
- ADB transport versus CXI remote-session responsibility.
- Android pointer/keyboard injection backend boundary.
- CXI v1 leakage record and v2 design-only document.
- Behavior-preserving regression coverage and real-device evidence.
- HELLO capability negotiation rejects helpers that cannot return
  `POINTER_RESULT` or guarantee explicit selected-target routing.
- Pointer delivery uses a bounded queue that coalesces adjacent movement and
  adjacent scroll events (ADR-0011); button transitions remain ordered
  boundaries, and keyboard/safety events are not allowed to wait behind an
  unbounded move backlog. Local queue saturation of coalescible kinds is
  backpressure (cancelled), never reported as remote failure.
- Queued semantic input is tagged with a session generation so replacement
  connections cannot receive stale pointer or keyboard work; late pointer
  results cannot change handoff accounting.
- A session is not published to input delivery until HELLO and capability
  negotiation succeed; reconnect exhaustion fails closed and tears down the
  candidate or live transport.
- Initial target refresh waits for a confirmed `DISPLAY_CHANGED` response
  before input capture is enabled.
- External-control takeover returns locally without pointer warping, drains
  queued key releases, and releases accepted held pointer buttons.
- Android target selection, metric refresh, pointer injection, and shutdown
  are serialized across helper threads.
- The macOS menu preserves its per-host-display handoff-edge picker separately
  from the normalized Android remote-target list.

The implementation boundary was re-audited in PR #42 after rebasing onto the
current main branch. The PR does not close #41 until the remaining
screen-confirmed device matrix is attached. The real macOS event-tap/helper
100-cycle record is attached, but target-screen visibility is still pending.

The rebaseline does not include a protocol migration, reverse input, a new
transport, an installed APK, or a broad repository rewrite.

## Near term

- Display hot-plug and display ON/OFF reliability across the full matrix in
  issue #17.
- Reconnect robustness after wireless debugging drop and sleep/wake.
- Stale target selection and stale callback protection during refresh/reconnect.
- Diagnostics that expose lifecycle metadata without input payloads.
- Packaging/distribution follow-up: bundled ADB, Homebrew path, and notarization
  when their ADR gates are satisfied.
- Screen-confirmed edge-switch stability and remaining regression matrix.
- Matching-helper packaging/deployment for the shipped Mac application; the
  current runtime rejects an incompatible pre-existing helper instead.

## Future

- CXI v2 migration planning and compatibility strategy.
- Alternate handoff mechanisms.
- Alternate transports.
- Bidirectional-input feasibility study.
- Other host and target platforms.

These items are not current commitments. Each requires an explicit scope and
verification record before implementation.

## Accepted but not implemented

Existing ADRs may contain accepted future decisions. Their status remains
historical and is not silently rewritten by this roadmap. In particular:

- ADR-0004's bundled-ADB release path remains pending.
- ADR-0005's Homebrew tap remains pending.
- ADR-0006's installed-app UHID experiment remains deferred.
- ADR-0003's reverse-input path remains outside current scope.

See [architecture](architecture.md), [product definition](product.md), and the
[ADR index](adr/).
