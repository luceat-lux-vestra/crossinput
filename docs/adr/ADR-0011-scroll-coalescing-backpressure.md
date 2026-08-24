# ADR-0011: Pointer Batch Admission and Delivery Semantics in InputSender

**Status:** Accepted
**Date:** 2026-08-24
**Issue:** #62
**Related:** ADR-0007 (keyboard delivery), ADR-0009 (architecture rebaseline), ADR-0010 (UHID desktop pointer routing), docs/architecture.md

## Context

Issue #62: during `remoteActive`, aggressive scroll bursts filled
`InputSender`'s bounded pointer queue (`maxPendingPointerItems = 64`). The
enqueue policy coalesced adjacent movement but treated every scroll as a new
queue item. When the queue saturated, the next scroll was rejected with
`.failed`, which `ControlHandoffController.apply(delivery:)` maps to the
fail-safe force-return (`reason: .remoteUnavailable`). Ordinary scrolling was
therefore misclassified as remote transport failure, yanking control back to
macOS mid-burst while the helper kept reporting successful delivery.

The queue's boundedness is a safety property, not a defect: it prevents an
unbounded backlog when delivery stalls. Raising capacity or timeouts would
only move the failure threshold without fixing the classification error.

An earlier draft of this ADR proposed fanning the aggregate batch result out
to one completion per contributing raw event (a "completion list"). That model
is **rejected**: it multiplies handoff accounting by the raw event count,
reintroduces exactly the bug class that caused #62 (a burst of N events
credited N times), adds O(n)-style callback copying on a hot input path, and
conflates queue admission with remote delivery.

## Decision

### 1. One pending element is a transport batch, not an event

`InputSender` queues semantic pointer delivery batches
(`PendingPointerBatch`). Multiple adjacent additive capture events may be
accumulated into one batch:

- `move(dx1, dy1) + move(dx2, dy2) → move(saturatingAdd, saturatingAdd)`
- `scroll(h1, v1) + scroll(h2, v2) → scroll(h1+h2, v1+v2)` (protocol Float)

Coalescing changes event cardinality **by design**. The merged batch has
exactly the semantic accumulated delta of the original sequence; the CXI wire
sign conventions are untouched. Because one batch represents one unit of
remote work, its acknowledgement and handoff accounting occur once per batch,
never once per original captured event. Per-event fan-out would credit the
aggregate movement N times — duplicating semantic movement and corrupting the
handoff position.

Merging only ever rewrites the queued tail's payload; it never searches
backward past another event and never creates a second acknowledgement
obligation.

### 2. Batch completion invariant

```
one PendingPointerBatch
  → one remote request
  → one delivery result
  → one completion
  → at most one handoff-accounting operation
```

If ten raw moves of +1 coalesce into one batch of move(+10), the helper sees
one request and `pointerMoved` is credited once with the aggregate. Callback
count equals helper request count; neither scales with raw captured event
count after coalescing.

### 3. Admission and delivery are different lifecycle domains

**Admission** decides what enters a batch: merge into a compatible tail,
append a new batch, locally shed an additive event under saturation, or fail
safe on an unretainable button. An additive event shed at admission was never
admitted for delivery: it produces **no transport request, no
`PointerDeliveryResult`, no completion invocation, no watchdog poke, and no
handoff accounting**. Local queue saturation is therefore not observable as
any delivery outcome at all — it cannot masquerade as `.cancelled` or
`.failed`.

**Delivery** produces one `PointerDeliveryResult` per admitted batch:
`.deliveredMovement` / `.partiallyDeliveredMovement` (with requested and
accepted deltas for issue #45 intent accounting), `.delivered` (confirmed
scroll or button), `.cancelled` (admitted work invalidated by lifecycle or
generation change), `.failed` (genuine delivery/safety failure).

Consequently `PointerDeliveryResult` gained no scroll-specific case: scroll
deltas stay inside `InputSender`; no consumer past the handoff boundary reads
them, and diagnostics do not justify carrying unused payloads through layers.

Invariant: **local queue saturation must never imply `remoteUnavailable`.**

### 4. Buttons are state transitions, never samples

A button down/up pair alters persistent remote state. Buttons never coalesce,
never reorder, and are never dropped silently. If bounded admission cannot
retain a button losslessly, that is a safety failure: the enqueue caller's
completion receives `.failed` synchronously and the existing fail-safe
force-return path applies.

### 5. Failure taxonomy

| Condition | Domain | Result/action |
|---|---|---|
| move/scroll merged into tail | admission | accepted into existing batch |
| new move/scroll/button with space | admission | new batch |
| move/scroll saturation | admission | local shed, no result |
| button saturation | admission/safety | synchronous `.failed`, fail-safe |
| delivered move | delivery | one `.deliveredMovement` |
| delivered scroll/button | delivery | `.delivered` |
| timeout / transport exception / unexpected response / helper failure | delivery | `.failed` |
| partial movement | delivery | existing partial safety path |
| stale session / stale pointer generation | lifecycle | `.cancelled` |

Genuine failure paths are unchanged from pre-existing behavior; local
backpressure simply no longer flows through them.

### 6. Complexity and concurrency

Admission is O(1): tail inspect, tail rewrite, append, capacity check. Memory
is O(maxPendingPointerItems); completions scale with delivery batches, not raw
events. All admission state lives behind the single `stateLock`; no second
synchronized object was added. Critical sections stay short: no transport I/O,
no external completion invocation, no MainActor dispatch, and only
rate-limited aggregate counters (coalesced batches, shed events) inside the
lock — their logging happens strictly outside it.

### 7. Watchdog semantics

Confirmed deliveries (`.deliveredMovement`, `.delivered`) poke the watchdog.
Locally shed events poke nothing: nothing was remotely confirmed. Genuine
transport stalls still trip the watchdog unchanged.

### 8. Timeout and capacity unchanged

`maxPendingPointerItems = 64` and `pointerRequestTimeout = 0.75 s` remain as
previously validated. Any evidence they need adjustment belongs in a separate
issue with reproducible measurements.

## Alternatives Rejected

- **Completion list fan-out (earlier draft of this PR):** one aggregate
  delivery result acknowledged once per contributing raw event multiplies
  handoff accounting N-fold, requires O(n) callback copying per coalesce, and
  blurs admission with delivery.
- **Larger/unbounded queue:** raises or removes the threshold while keeping
  the misclassification; violates the bounded-local-recovery invariant.
- **Reporting saturation as `.cancelled`:** still fabricates a delivery
  result for work that was never admitted; pollutes cancellation diagnostics
  (which mean lifecycle invalidation) with pressure noise.
- **Dropping button transitions lossily:** can strand a held button remotely;
  unacceptable.
- **Sleep/debounce/throttling at the event tap:** delays the macOS event-tap
  thread and adds arbitrary latency to all input.

## Consequences

- Scroll and move bursts coalesce into few requests; downstream handoff
  callbacks scale with batches, not raw events.
- Saturation involving only additive events degrades gracefully (silent local
  shed + watchdog); saturation involving a button fails safe.
- Cancellation diagnostics (`recordCancelledDelivery`) now exclusively mean
  lifecycle/generation invalidation, making them operationally meaningful.
- Aggregate metadata counters (shed count, coalesced scroll batches) provide
  pressure observability without logging any input contents.

## Validation

- Unit/integration: `InputSenderTests` — gated deterministic cardinality test
  (button boundary parked in flight; nine moves coalesce into one queued
  batch; request/callback counts asserted equal), end-to-end handoff
  accounting through `ControlHandoffController` + `EdgeSwitchStateMachine`
  (return fires from a single aggregated credit), gate-held scroll coalescing
  with exact accumulated deltas, seven-case horizontal/vertical accumulation
  matrix with tolerance, ordering boundaries (scroll→button→scroll,
  scroll→move→scroll, move→scroll→move, buttonDown→burst→buttonUp),
  deterministic saturation tests asserting zero delivery results for shed
  additive events, button overflow failing closed, genuine transport/helper/
  unexpected-response failures, partial movement after coalescing, replaced
  session never receiving stale work, cancelled in-flight movement never
  crediting handoff position. Full suite: 112 tests, 0 failures.
- Physical acceptance on SM-G977N DeX (issue #62 procedure): scroll stress
  must produce no `remoteActive -> returning reason=remoteUnavailable` line in
  `diag.log`; 100-cycle edge handoff test must pass 100/100 before merge.
  Physical validation follows code review PASS.

## Revisit Conditions

- Reproducible evidence that legitimate requests exceed 0.75 s after the
  queue fix (separate timeout issue).
- Introduction of additional additive pointer event kinds (e.g. momentum/
  inertial scroll) — extend the coalescing table rather than special-casing.
