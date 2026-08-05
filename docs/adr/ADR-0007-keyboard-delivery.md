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
   registers a keyboard HID descriptor, and reports pressed-key state (the set of
   currently held keys) derived from the CXI keyboard message.
   Verified device path (mouse already works on SM-G977N / Android 12).
2. **Virtual keyboard injection**: the helper constructs `KeyEvent` objects and
   delivers them through Android's internal `InputManager.injectInputEvent`
   API (resolved and invoked via reflection). No UHID dependency; the fallback
   for devices where `/dev/uhid` keyboard support differs or is unavailable.
   There is **no AccessibilityService and no accessibility permission** — the
   helper process runs under the shell UID (app_process) and injects directly
   into the input pipeline.

No CXI keyboard message existed before this work (only mouse `HID_REPORT` /
`POINTER_*`); the single `KEY_EVENT` message type was introduced with this ADR.

## Decision

1. **Delivery: `KEY_EVENT` is the single CXI keyboard abstraction; the backend
   selection and conversion live in the Android helper.** The mac→Android
   protocol gains exactly one keyboard message type (`KEY_EVENT` 0x000C, Android
   KeyEvent semantics), and the Android side implements both a UHID keyboard
   backend and a virtual-keyboard fallback backend. If UHID keyboard creation
   or reporting fails on a device, the helper falls back to the virtual backend
   automatically.
   **UHID is the primary backend**; the InputManager fallback is engaged only
   when UHID creation or reporting fails on a device.

   Backend conversion:
   - UHID backend: converts `KEY_EVENT` into a HID pressed-key-state report
     (the set of currently held keys) sent over the existing UHID device.
   - InputManager fallback: converts `KEY_EVENT` into an Android `KeyEvent`
     and injects it through the internal `InputManager.injectInputEvent` API
     (resolved through reflection). There is no AccessibilityService. Because
     the API is internal/non-SDK, availability and behavior may vary by Android
     version and vendor; resolution failure, rejection, or `SecurityException`
     must not abort the CXI session — the event is dropped and the failure is
     reported through metadata-only logging, and the backend releases any
     pressed-key state to prevent stuck keys.
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
- Negative: the virtual fallback relies on the internal `InputManager` injection
  API (non-SDK, reflection-based), which may behave differently across Android
  versions and vendors; it must stay isolated behind feature detection and a
  fail-safe path (AGENTS.md rule 2 requires on-device verification per device).

## Validation

- (done) Protocol: keyboard message type (`KEY_EVENT` 0x000C) + fixtures pass `scripts/check-fixtures.mjs` and `swift test`
- (done) Android: UHID keyboard create + HID report on-device (SM-G977N) — `Ampersand Keyboard` registered as `KEYBOARD | ALPHAKEY | EXTERNAL`
- (done) Android: key-state reporting fix verified on-device (no infinite key repeat; issue #21, PR #26)
- (pending) Android: virtual fallback injects keys via the internal `InputManager.injectInputEvent` API (per-device, AGENTS.md rule 2) — UHID path verified; fallback not yet exercised on-device
- (done) macOS: typing reaches a DeX-focused field; Cmd+Tab / Spotlight do not fire on the Mac while captured (user-confirmed on-device)
- (done) Korean: 2-set composition produces correct hangul in a DeX field (user-confirmed)