# ADR-0007: Keyboard Delivery (mac→Android, UHID + Virtual Injection)

> Status: **accepted**
> Date: 2026-08-05
> Supersedes: ADR-0003 decision 3 ("keyboard is not in v1, deferred post-v1")

## Context

ADR-0003 deferred mac→Android keyboard to a post-v1 extension because the macOS
capture side has an unresolved problem: while the CGEventTap captures keyboard,
system shortcuts (Cmd+Tab, Spotlight, etc.) also fire on the Mac, which is the
reported blocker. Work is now starting on the keyboard extension, so the delivery
policy must be fixed in advance.

Ampersand delivers pointer input over a UHID device created by the helper.
Two candidate keyboard delivery paths exist:

1. **UHID keyboard device** (same path as the mouse): helper opens `/dev/uhid`,
   registers a keyboard HID descriptor, and the Mac forwards HID keyboard reports.
   Verified device path (mouse already works on SM-G977N / Android 12).
2. **Virtual keyboard injection**: Android injects `KeyEvent`s via an
   AccessibilityService (SDK `injectInputEvent` equivalent). No UHID dependency;
   the fallback for devices where `/dev/uhid` keyboard support differs.

There is no keyboard message type in the CXI protocol yet (only mouse
`HID_REPORT` / `POINTER_*`).

## Decision

1. **Delivery: both paths are supported via the protocol, with runtime fallback**.
   The mac→Android protocol gains a keyboard message type (`KEYBOARD_HID_REPORT`/
   keyboard HID descriptor for UHID), and the Android side implements both a UHID
   keyboard backend and a virtual-keyboard fallback backend. If UHID keyboard
   creation or reporting fails on a device, the helper falls back to the virtual
   backend automatically. A single protocol message set abstracts both backends.
2. **macOS system-shortcut handling is in scope** of this work. While keyboard is
   captured, system shortcuts must not bubble up to the Mac (Cmd+Tab, Spotlight,
   Cmd+H, etc.). The capture tap intercepts and suppresses these. This is the key
   open problem that previously blocked the feature — it is now a first-class
   requirement, not a don't-do.
3. **Korean (2-set) input is in scope.** The Mac captures the intended text/keys
   and the Android side composes hangul via the active IME or the fallback
   backend. No HID keycode-level composition on the Mac: the Mac treats input as
   key events and the Android side resolves composition.
4. This does not change ADR-0003 decisions 1–2 (mac→Android one-way v1, pointer
   devices). The reverse direction (dex→mac keyboard via custom IME) remains a
   separate extension (ADR-0003 decision 5).

## Alternatives

- **UHID keyboard only**: simpler, but ties reliability to `/dev/uhid` keyboard
  behavior per device/SELinux — the virtual backend is the safety net.
- **Virtual injection only**: no UHID dependency but loses the system-level input
  device semantics (hardware keyboard behavior) that UHID gives.
- **Text-transport keyboard** (paste-style): unsuitable for password fields and
  breaks shortcut semantics; rejected.

## Consequences

- Positive: same proven UHID path as mouse, plus a no-root fallback; one protocol
  abstraction regardless of backend.
- Positive: system-shortcut suppression is explicitly scoped (no "known issue").
- Positive: Korean handled on Android (IME already composes 2-set); Mac stays
  keycode-simple.
- Negative: protocol + fixtures must be extended (AGENTS.md rule 6) and the
  macOS capture tap gets a second, keyboard-tap mode with suppression logic.
- Negative: virtual fallback usefulness depends on the accessibility permission
  on-device; requires on-device verification per device (AGENTS.md rule 2).

## Validation

- (pending) Protocol: keyboard message type + fixtures pass `scripts/check-fixtures.mjs` and `swift test`
- (pending) Android: UHID keyboard create + HID report on-device (SM-G977N)
- (pending) Android: virtual fallback injects keys via accessibility
- (pending) macOS: typing reaches DeX-focused field; Cmd+Tab / Spotlight do not
  fire on the Mac while captured (on-device logcat + screen confirmation)
- (pending) Korean: 2-set composition produces correct hangul in a DeX field