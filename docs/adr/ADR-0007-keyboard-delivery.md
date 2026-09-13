# ADR-0007: Keyboard Delivery (mac→Android, UHID + Virtual Injection)

> Status: **accepted for product/backend evidence; Leap target outcome/ownership semantics superseded by ADR-0016 and #141**
> Date: 2026-08-05
> Supersedes: ADR-0003 decision 3 ("keyboard is not in v1, deferred post-v1")
>
> **Architecture Leap note (2026-09-13):** this ADR remains authoritative for
> the established macOS → Android keyboard product behavior, UHID-primary /
> InputManager-fallback backend evidence, shortcut suppression, Korean-input
> validation, and the existing CXI v1 compatibility surface. It is **not** the
> target architecture for keyboard ownership or delivery certainty. ADR-0016
> supersedes the pre-Leap host-domain Android-key semantics and fire-and-forget
> failure model; #103 moves platform-neutral semantic input in front of the CXI
> v1 adapter, and #141 requires an additive correlated semantic key outcome.
> Where this ADR says a failed/rejected key may simply be dropped with metadata
> logging while the Session stays alive, that describes the current pre-Leap
> implementation only and must not be carried into the final Leap delivery
> architecture.

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

1. **Delivery: `KEY_EVENT` is the current CXI v1 keyboard wire abstraction; the
   backend selection and conversion live in the Android helper.** The mac→Android
   protocol has one keyboard message type (`KEY_EVENT` 0x000C, Android KeyEvent
   semantics on the compatibility wire), and the Android side implements both a
   UHID keyboard backend and a virtual-keyboard fallback backend. If UHID
   keyboard creation or reporting fails on a device, the helper falls back to
   the virtual backend automatically.
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
     must not abort the CXI session.

   **Pre-Leap implementation note:** the current helper may drop such a failed
   event and report only metadata diagnostics. ADR-0016/#141 supersede that as a
   target delivery contract: persistent key transitions require correlated
   semantic certainty (`applied`, proven `notApplied`, or `ambiguous`) and an
   ambiguous result cannot seed a clean replacement Control/Session context.
   The compatibility wire may continue to carry Android-shaped v1 data at the
   remote adapter boundary, but the host/domain API introduced by #103 must be
   platform-neutral.
2. **macOS system-shortcut handling is in scope.** While keyboard is captured,
   system shortcuts must not bubble up to the Mac (Cmd+Tab, Spotlight, Cmd+H,
   etc.). The capture tap intercepts and suppresses these. This is the key open
   problem that previously blocked the feature — it is now a first-class
   requirement.
3. **Korean (2-set) input is in scope.** The Mac captures the intended text/keys
   and the Android side composes hangul via the active IME or the fallback
   backend. No HID keycode-level composition on the Mac: the Mac treats input as
   key events and the Android side resolves composition.
4. This does not change ADR-0003 decisions 1–2 (mac→Android one-way v1, pointer
   devices). The reverse direction (dex→mac keyboard via custom IME) remains a
   separate extension (ADR-0003 decision 5).

## Leap interpretation

The following facts from this ADR remain inputs to the Leap:

- macOS → Android keyboard direction and shortcut suppression;
- UHID-primary / InputManager-fallback backend policy until separately changed;
- the validated Korean-input behavior;
- CXI v1 compatibility during the migration; and
- the requirement that backend failure is isolated and metadata-only in
  diagnostics.

The following pre-Leap implementation assumptions are **not** retained as target
architecture:

- host/domain input carrying Android `KEYCODE_*` / `META_*` semantics;
- fire-and-forget `KEY_EVENT` as sufficient proof of persistent delivery;
- treating helper/backend rejection as merely a logged drop while the host keeps
  assuming known key state; or
- teardown cleanup as a substitute for per-transition semantic outcome.

See ADR-0016, #103, #106, #107, and #141 for the replacement ownership,
serialization, cleanup, and outcome contracts.

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
  keycode-simple at the product level while #103 moves platform-specific
  translation behind the host/remote adapters.
- Negative: protocol + fixtures must be extended for the Leap semantic outcome
  contract (#141; AGENTS.md rule 6).
- Negative: the virtual fallback relies on the internal `InputManager` injection
  API (non-SDK, reflection-based), which may behave differently across Android
  versions and vendors; it must stay isolated behind feature detection and a
  fail-safe path and requires on-device verification.

## Validation

- (done) Protocol: keyboard message type (`KEY_EVENT` 0x000C) + fixtures pass `scripts/check-fixtures.mjs` and `swift test`
- (done) Android: UHID keyboard create + HID report on-device (SM-G977N) — `Ampersand Keyboard` registered as `KEYBOARD | ALPHAKEY | EXTERNAL`
- (done) Android: key-state reporting fix verified on-device (no infinite key repeat; issue #21, PR #26)
- (done, 2026-08-10) Android: virtual fallback injects keys via the internal `InputManager.injectInputEvent` API on SM-G977N / Android 12 — forced backend selection, single key delivery, modifier delivery, release behavior, metadata-only logging, and clean shutdown verified (issue #33). A down-only held-key run also verified synthetic release during SHUTDOWN and graceful process-exit detection before orphan cleanup.
- (done) Test-only deterministic backend override: `--keyboard-backend=uhid|input-manager|auto` enables forced backend selection for testing; an unknown value aborts startup rather than degrading to AUTO; production default remains AUTO (UHID preferred with automatic fallback)
- (done) Automated tests: backend selection, forced-mode semantics, failure paths, and metadata-only logging covered by unit tests against a fake injector (`KeyboardBackendTest`, `KeyboardBackendModeTest`) — off-device only, so this does not satisfy AGENTS.md rule 2
- (done) macOS: typing reaches a DeX-focused field; Cmd+Tab / Spotlight do not fire on the Mac while captured (user-confirmed on-device)
- (done) Korean: 2-set composition produces correct hangul in a DeX field (user-confirmed)

These validations prove the historical/current behavior they exercised. They do
not prove the new #141 semantic-outcome contract or the final Leap ownership
model; those require their own exact-head automated and physical evidence.
