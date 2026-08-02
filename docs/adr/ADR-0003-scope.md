# ADR-0003: Supported Scope (mac→Android One-Way First, Protocol Prepared for Both Directions)

> Status: **accepted**
> Date: 2026-08-03

## Context

The product's essence is an "input bridge". The primary direction (macOS input → Android) is verified on device for the injection side (UHID); the macOS capture side (CGEventTap) is planned for Phase 4 and not yet implemented. The reverse direction (dex→mac) was also considered at user request. The iPad (iPadOS) has no CGEventTap-equivalent API, so input capture is impossible with the current architecture.

## Decision

1. **v1 release scope is mac → Android one-way** (both the DeX external display and the phone screen). Phone-screen control also works on Android without DeX.
2. **v1 input devices: all pointer devices on the Mac** — trackpad, wired mouse, wireless mouse — captured via CGEventTap, which is device-agnostic. No per-device setup.
3. **Keyboard (mac → Android) is not in v1** — deferred to a post-v1 extension. Delivery to Android via a UHID keyboard device is straightforward, but macOS system-shortcut handling (Cmd+Tab, Spotlight, etc.) while input is captured is an unresolved problem and the reason for the deferral.
4. **The CXI protocol is designed so both directions can be supported by adding message types only** (message type space separated without direction prefixes; types added later).
5. The reverse direction extension is only possible via the following paths:
   - Android touch capture: **AccessibilityService** (no root, limited touch)
   - Android software keyboard capture: **custom IME app** (`InputMethodService`, no root, our keyboard must be the active IME)
   - macOS injection: `CGEventPost`
6. **iPad is out of scope** (not technically impossible, but requires a separate design).

## Alternatives

- Implement both directions from the start: increases v1 complexity and delays release. The UX of Android input capture (keyboard switching, etc.) is unverified.
- Include iPad: no CGEventTap on iPadOS — requires a completely different architecture (screen sharing/managed profiles, etc.).

## Consequences

- Positive: fast release within the verified v1 scope. Protocol extensibility is preserved.
- Negative: the reverse direction takes on the character of a separate product (phone → Mac wireless input device). Android keyboard capture cannot receive input from other IMEs such as GBoard.

## Validation

- (done) UHID mouse: DeX external display click/move/cursor display on-device verified (SM-G977N)
- (pending) CXI extension design: reference this ADR when defining extended message types
