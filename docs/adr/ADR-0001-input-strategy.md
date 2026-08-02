# ADR-0001: DeX Input Delivery Method (UHID)

> Status: **accepted** — confirmed by Phase 0 leap-scrcpy baseline results.
> Date: 2026-08-03

## Context

Pointer input must be delivered to the Samsung DeX external display. Candidates: (a) UHID virtual HID device, (b) `input` shell command (needs root, speed limited), (c) Accessibility API (focus/click only, no absolute-coordinate movement), (d) virtual display + InputManager.
UHID can use `/dev/uhid` with shell permission without root and supports relative/absolute coordinates, buttons, wheel, and stylus.

## Decision (accepted)

Use UHID as the primary input delivery method. If Phase 0 verification showed "input not delivered to the DeX external display (category B)", the routing cause would be investigated first.

## Alternatives

- `input tap/swipe`: usable from the shell without root, but lacks relative movement/wheel and is slow.
- Accessibility: no move.
- sendevent: one device per node, unstable.

## Consequences

- Positive: relative/absolute/stylus/wheel all supported, good performance.
- Negative: needs re-evaluation in environments where `/dev/uhid` access is restricted (future Android versions).

## Validation

- (done) Phase 0: UHID relative mouse on-device verification — DeX external display click/move/cursor display confirmed (SM-G977N, Android 12)
- (done) UHID minimal CLI probe (relative mouse) works
- (pending) Whether `/dev/uhid` is accessible from an installed regular app (ADR-0006)

## Revisit conditions

- Re-evaluate if UHID fails to deliver input to the DeX screen.
