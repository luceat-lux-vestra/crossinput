# ADR-0011: Scroll Coalescing and Local Backpressure Semantics in InputSender

**Status:** Accepted
**Date:** 2026-08-24
**Issue:** #62
**Related:** ADR-0007 (keyboard delivery), ADR-0010 (UHID desktop pointer routing), docs/architecture.md

## Context

Issue #62: during `remoteActive`, aggressive scroll bursts filled
`InputSender`'s bounded pointer queue (`maxPendingPointerItems = 64`). The
enqueue policy coalesced adjacent movement but treated every scroll as a new
queue item. When the queue saturated, the next scroll was rejected with
`.failed`, which `ControlHandoffController.apply(delivery:)` maps to the
fail-safe force-return (`reason: .remoteUnavailable`). Ordinary scrolling was
therefore misclassified as remote transport failure, yanking control back to
macOS mid-burst while the device-side helper kept reporting successful UHID
delivery.

The queue's boundedness is a safety property, not a defect: it prevents an
unbounded backlog when delivery stalls, and its cancellation path is what
keeps local recovery prompt. Raising capacity or timeouts would only move the
failure threshold without fixing the classification error.

## Decision

1. **Adjacent same-kind events are semantically accumulable, so they merge.**
   The enqueue policy now merges the pending tail item with an incoming event
   of the same kind for the same session generation:
   - `move(dx1, dy1) + move(dx2, dy2) → move(dx1+dx2 saturating, dy1+dy2 saturating)`
   - `scroll(h1, v1) + scroll(h2, v2) → scroll(h1+h2, v1+v2)` (Float add)

   The merged batch has exactly the semantic accumulated delta of the original
   sequence; the CXI wire sign convention is untouched. Merging never searches
   backward past another event: it only ever rewrites the queue tail.
2. **Ordering boundaries are inviolable.** Button transitions (down/up pairs)
   and any kind change terminate a merge run. `scroll→button→scroll`,
   `scroll→move→scroll`, `move→scroll→move`, and
   `buttonDown→scroll burst→buttonUp` all keep their request order; buttons
   are never reordered, dropped, or silently replaced.
3. **Local overload is not remote failure.** Queue saturation is classified by
   event kind:
   - Coalescible kinds (move/scroll) rejected at enqueue are reported as
     `.cancelled` — a local backpressure outcome. The remote endpoint is
     healthy; control stays on Android. The existing fail-safe watchdog still
     guards genuine stalls, so this weakens nothing about transport failure.
   - A button transition that cannot be enqueued losslessly remains `.failed`
     and keeps the fail-safe force-return: dropping a button down/up pair can
     leave remote button state inconsistent.
   Invariant: **`remoteUnavailable` must not be generated merely because
   ordinary scroll production temporarily exceeds pointer delivery
   throughput.**
4. **Completions fan out per enqueued event.** A coalesced batch carries a
   completion list; every contributing enqueue is acknowledged exactly once
   with the single batch result. No caller-visible acknowledgement count
   changes.
5. **Scroll results carry requested deltas.** `PointerDeliveryResult`
   gains `deliveredScroll(requestedHorizontal:requestedVertical:)` so
   diagnostics can account coalesced scroll work without logging user input
   contents; confirmed scrolls poke the watchdog but credit no handoff
   position (scrolls do not move the pointer).
6. **Timeout unchanged.** `pointerRequestTimeout` stays 0.75 s. Any evidence
   that legitimate requests still time out after the queue fix belongs in a
   separate issue with reproducible measurements.
7. **Diagnostics stay metadata-only:** aggregate counters for coalesced
   scrolls and saturation drops, rate-limited (every N-th event). No scroll
   values, payloads, or input contents.

## Alternatives Rejected

- **Larger queue only (64 → N):** raises the threshold; the misclassification
  remains and latency grows under bursts.
- **Unbounded queue:** violates the bounded-local-recovery safety invariant;
  a stalled helper would grow memory without limit.
- **Dropping button transitions lossily:** can strand a held button remotely;
  unacceptable.
- **Arbitrary `pointerRequestTimeout` increase:** masks latency with a longer
  trap window; no reproducible evidence yet that 0.75 s is inadequate.
- **Sleep/debounce/throttling on the capture callback:** delays the macOS
  event-tap thread and adds arbitrary latency to every input.

## Consequences

- Scroll bursts coalesce into few requests; queue pressure from scrolling is
  effectively eliminated at realistic rates.
- Genuine failures (transport/request errors, timeout, malformed response,
  helper `.failed`, partial movement) still reach `.failed` and force-return.
- Saturation involving only movement/scroll degrades gracefully (cancelled +
  watchdog); saturation involving a button fails safe.
- `recordCancelledDelivery()` rate-limited logging already covers the
  cancelled path; no new diagnostics surface is required beyond counters.

## Validation

- Unit: `InputSenderTests` — scroll coalescing bound + accumulated deltas,
  independent horizontal/vertical accumulation including cancellation,
  ordering boundaries around scroll/move/button, gated deterministic
  saturation (`scroll → .cancelled`, button overflow → `.failed`),
  genuine-failure regression via a throwing session, stale-session
  cancellation of coalesced scroll work. All pre-existing movement, partial,
  cancellation, held-button, keyboard, and ordering tests remain green
  (`swift test`: 104 tests, 0 failures).
- Physical acceptance on SM-G977N DeX (issue #62 procedure): scroll stress
  must produce no `remoteActive -> returning reason=remoteUnavailable` line
  in `diag.log`; 100-cycle edge handoff test must pass 100/100 before merge.

## Revisit Conditions

- Reproducible evidence that legitimate requests exceed 0.75 s after the
  queue fix (separate timeout issue).
- Introduction of additional additive pointer event kinds (e.g. momentum/
  inertial scroll) — extend the coalescing table rather than special-casing.
