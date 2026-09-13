# ADR-0003: Supported Scope (mac→Android One-Way First, Protocol Prepared for Both Directions)

> Status: **accepted historically; current product direction superseded by ADR-0013, keyboard scope superseded by ADR-0007**
> Date: 2026-08-03
>
> **Current interpretation:** the one-way macOS → Android topology remains
> current, but ADR-0013 later made Android → macOS pointer/keyboard control an
> explicit product non-goal unless a new product decision reopens it. The
> reverse-direction mechanisms listed below are historical feasibility notes,
> not current roadmap/extension commitments. ADR-0016 separately governs the
> current internal ownership/concurrency architecture and does not reopen the
> reverse direction.

## Context

The product's essence is an "input bridge". The primary direction (macOS input → Android) was verified on device for the injection side (UHID); at this historical point the macOS capture side (CGEventTap) was still planned. The reverse direction (dex→mac) was also considered at user request. The iPad (iPadOS) has no CGEventTap-equivalent API, so input capture would require a different design.

## Decision

1. **macOS → Android one-way** is the supported input direction (both the DeX external display and the phone screen). **Retained and strengthened by ADR-0013.**
2. **Mac pointer devices** — trackpad, wired mouse, wireless mouse — are captured through the host input mechanism without per-device configuration. The concrete host ownership/mechanism is subject to ADR-0016 rather than frozen by this historical ADR.
3. ~~**Keyboard (mac → Android) is not in v1**~~ **Superseded by [ADR-0007](ADR-0007-keyboard-delivery.md)** (2026-08-05): keyboard delivery, macOS system-shortcut handling, and Korean 2-set input entered scope. ADR-0013 retains one-way macOS → Android keyboard input.
4. The CXI message space was designed to permit additive message types. **This is a protocol-structure observation, not a current commitment to bidirectional input; ADR-0013 controls product direction.**
5. Historical feasibility exploration for reverse direction identified possible mechanisms:
   - Android touch capture: AccessibilityService (limited/no-root surface)
   - Android software keyboard capture: custom IME app (`InputMethodService`)
   - macOS injection: `CGEventPost`

   **Superseded as product scope by ADR-0013:** these mechanisms are not current
   implementation targets or approved extension points. Reopening Android →
   macOS pointer/keyboard requires a new explicit product decision.
6. **iPad is out of current scope.** A future iPad host would require a separate
   product/architecture decision rather than being inferred from this ADR.

## Alternatives

- Implement both directions from the start: rejected; increases complexity and
  depended on unverified Android input-capture UX. ADR-0013 later made the
  reverse direction an explicit non-goal rather than merely deferred work.
- Include iPad: requires a materially different host-input architecture and is
  not a current commitment.

## Consequences

- Positive: product input direction stays focused on macOS → Android.
- Positive: protocol extensibility does not silently become product scope.
- Historical negative: reverse direction would behave like a separate product
  with Android capture/IME constraints. Under ADR-0013 that observation supports
  keeping it out of the current roadmap.

## Validation

- (done) UHID mouse: DeX external display click/move/cursor display on-device verified (SM-G977N)
- (done) CXI extension: mac→Android keyboard message type defined and shipped (`KEY_EVENT`, ADR-0007, PR #23)

These historical validations do not alter the current product authority in
ADR-0013 or the Architecture Leap ownership contract in ADR-0016.
