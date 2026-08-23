# ADR-0010: Prefer the system-routed UHID pointer on desktop sinks

**Status:** Accepted
**Date:** 2026-08-23
**Issue:** #57
**Related:** ADR-0007 (keyboard delivery), docs/research/evidence/pullback-boundary-pin-2026-08-23

## Context

Issue #57: with the helper in `auto` mode, the DeX pointer sprite stayed frozen
at the display center while macOS moved the local cursor. Root cause chain:

1. `PointerDispatcher.AUTO` required `uhid.routing == EXPLICIT_DISPLAY` before
   choosing UHID. `UhidPointerInjector` is honestly system-routed, so AUTO
   always fell through to InputManager injection.
2. Injected `MotionEvent`s (`InputManager.injectInputEvent`) bypass InputReader,
   so they never reach `PointerController`; only the app-facing cursor state
   moves. The internal virtual cursor was initialized at the display center and
   never visibly moved.
3. Counter-experiments show that a `/dev/uhid` relative mouse *does* move the
   visible DeX sprite: UHID devices enter InputReader as real input devices and
   drive the native `InputReader -> PointerController` pipeline (with pointer
   acceleration and click handling identical to a physical mouse).

DeX displays are identifiable through the hidden `DisplayInfo.FLAG_DESKTOP`
bit, which `DisplayDiscovery` already uses to classify protocol display type 7.

An external design review flagged two additional defects that this ADR folds
in: the drafted AC Pan HID descriptor bytes were wrong, and the horizontal
scroll sign handling contradicted verified platform conventions.

## Decision

1. **AUTO backend selection.** When the selected target looks like a desktop
   system sink, prefer the system-routed UHID mouse
   (`uhid.selectSystemRoute()`); otherwise use InputManager with explicit
   display targeting. Reflection failure of the predicate degrades to
   InputManager (conservative false negative).
2. **FLAG_DESKTOP is a heuristic, not a guarantee.** `SystemRoutePolicy`
   isolates the hidden-API read behind an injectable predicate
   (`isSystemRouteCandidate`). Desktop classification does not formally
   guarantee where the system pointer controller routes; the counter-experiment
   evidence remains part of acceptance validation.
3. **Forced UHID mode becomes usable.** `--pointer-backend=uhid` logs a warning
   that target selection is ignored and activates the system route via
   `selectSystemRoute()` instead of failing. `UhidPointerInjector.selectDisplay()`
   keeps its existing honest semantics (always `false` for target-specific
   selection). The forced-UHID HELLO_ACK capability set is unchanged (no
   `explicitPointerRouting` advertisement).
4. **Horizontal scrolling rides AC Pan.** The semantic UHID descriptor gains a
   Consumer AC Pan field — usage page `0x0C`, usage `0x0238`, encoded as the
   16-bit usage item `05 0C 0A 38 02` (Linux maps `HID_CP_AC_PAN` to
   `REL_HWHEEL`). Reports grow from 4 to 5 bytes
   `[buttons, dx, dy, wheel, pan]`. Sign handling is derived from verified
   conventions:
   - CXI wire contract: positive horizontal = LEFT (mirrors the macOS scroll
     axes actually sent by the Mac client).
   - Android/Linux native chain treats positive values as RIGHT
     (`AXIS_HSCROLL` normalized −1 left … +1 right; `REL_HWHEEL` passes through
     `CursorInputMapper` without inversion).
   - Therefore the UHID backend inverts CXI horizontal into the pan field, and
     the previously verbatim InputManager passthrough now negates horizontal
     into `AXIS_HSCROLL`. Both adapters convert at their boundary; the wire
     contract is unchanged.
   - The historical raw v1 fixture `protocol/fixtures/create-hid.bin` (4-byte
     reports) remains untouched; the two descriptors live as independent
     constants with byte-exact unit coverage.
5. **Failover stays sticky per selection epoch.** After a UHID write failure or
   partial delivery, the dispatcher switches to InputManager until the next
   `SELECT_DISPLAY`; no periodic retry (avoids device churn and event-ordering
   hazards). Held buttons are released best-effort before the virtual device
   closes; release-write failures log a metadata-only warning. The failover
   matrix under test covers idle, held-button, drag/chunking, partial-delivery,
   and epoch-reset cases.
6. **Raw HID path stays wire-level fire-and-forget.** Local `sendReport()`
   failures remain observable through LOG_EVENT diagnostics (metadata only);
   no protocol response message is introduced.
7. **No CXI wire-format change.** Only documentation corrections: the
   `POINTER_SCROLL` annotation (the old "Android AXIS_* convention" note
   misstated the convention), the `explicitPointerRouting` capability wording
   ("the helper can serve targets through an explicit-display-routing backend
   when required"), and the application-path prose describing desktop-sink
   routing.

## Alternatives considered

- **Blind InputManager side-channel for scroll while UHID owns the pointer**
  (rejected): `ACTION_SCROLL` is routed by pointer position; the stale virtual
  cursor would scroll the wrong window — semantic corruption, not degradation.
- **Hidden pointer-position sync API** (rejected): adds another non-SDK
  surface with Samsung version coupling for no routing benefit.
- **Drop horizontal scrolling on the UHID path** (fallback only): loses
  function but avoids wrong-target delivery; acceptable emergency behavior,
  not the shipped design.
- **Make `selectDisplay()` return true in forced mode** (rejected): would make
  the injector abstraction lie about target-specific selection.
- **Periodic retry after failover** (rejected): UHID destroy/create churn
  mid-session risks duplicate events, drag breakage, and pointer discontinuity.

## Consequences

- The DeX sprite follows the remote pointer again; movement, clicks, drags,
  wheel, and now horizontal scroll all ride the native pipeline with standard
  acceleration.
- Desktop sinks give up explicit target routing: the system decides where the
  UHID mouse points. This is accepted for the single-desktop use case; the
  heuristic fails toward the previous explicit-routing behavior.
- Two descriptor/report formats now coexist intentionally (raw v1 4-byte vs
  semantic 5-byte). The divergence hazard is contained by separate constants
  plus golden-byte and report-layout tests.
- Wheel/pan magnitudes currently collapse to one notch per semantic event
  (sign-only mapping), matching the pre-existing vertical behavior; preserving
  magnitude is a candidate follow-up if fine-grained scrolling is needed.

## Validation

- Unit (all green, 98 tests): dispatcher AUTO preference/non-preference,
  UHID-unavailable fallback, forced-UHID system routing and capability
  advertising, failover retry-once, sticky switch without retry after partial
  delivery, held-button handoff, selection-epoch reset; golden descriptor bytes
  including `05 0C 0A 38 02`, pan sign inversion, zero-pan regression on other
  reports, chunked large deltas, close-time button release.
- On-device (SM-G977N, pending): docs/testing.md "Issue #57 acceptance" —
  sprite follow in auto mode, four-direction scroll semantics on both backends,
  immediate move after select (create race), and mid-session failure handoff.
  Per AGENTS.md rule 2, #57 is not "verified complete" until those logs exist.

## Revisit conditions

- An OEM/Android release exposing explicit per-display routing for virtual
  mice would justify re-evaluating UHID vs injected routing.
- If on-device four-direction testing shows a horizontal direction mismatch
  (e.g., natural-scrolling variance on the Mac side), flip the conversion and
  its tests together in one commit.
