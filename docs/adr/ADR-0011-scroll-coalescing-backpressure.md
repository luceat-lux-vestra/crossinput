# ADR-0011: Pointer Batch Admission and Delivery Semantics in InputSender

**Status:** Accepted for backpressure/coalescing evidence; pre-Leap `InputSender` / split-queue / generation / cleanup ownership contract superseded by ADR-0016
**Date:** 2026-08-24
**Issue:** #62
**Related:** ADR-0007 (keyboard delivery), ADR-0009 (architecture rebaseline), ADR-0010 (UHID desktop pointer routing), ADR-0016 (Leap ownership/concurrency), docs/architecture.md

> **Architecture Leap note (2026-09-13):** the measured/problem-solving results
> in this ADR remain authoritative where ADR-0016 explicitly retains them:
> bounded admission, O(1) adjacent additive coalescing, admission-vs-delivery
> separation, non-lossy persistent button transitions, aggregate/payload-safe
> diagnostics, and the fact that local additive saturation must not masquerade
> as remote transport failure. The concrete pre-Leap ownership model is
> historical. The final Leap architecture does **not** retain separate pointer
> and keyboard queues, `InputSender` as the owner, raw generation-based stale
> rejection, or "clear held tracking regardless of cleanup outcome" as proof of
> clean remote state. Those are replaced by one semantic lane per ControlLease,
> immutable Session/Target/Control ownership, semantic outcome accounting,
> predecessor remote-close fencing, and Session recovery cleanliness when
> persistent state is ambiguous.

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

The pre-Leap implementation queues semantic pointer delivery batches
(`PendingPointerBatch`). Multiple adjacent additive capture events may be
accumulated into one batch:

- `move(dx1, dy1) + move(dx2, dy2) → move(saturatingAdd, saturatingAdd)`
- `scroll(h1, v1) + scroll(h2, v2) → scroll(h1+h2, v1+v2)` (protocol Float)

Coalescing changes event cardinality **by design**. The merged batch has exactly
the semantic accumulated delta of the original sequence; the CXI wire sign
conventions are untouched. One coalesced semantic unit has one downstream
acknowledgement/accounting obligation, never one per original captured sample.
Per-event fan-out would credit the aggregate movement N times and corrupt
handoff position.

ADR-0016 retains this semantic rule while moving it into one ordered semantic
lane per ControlLease rather than preserving a pointer-only queue.

### 2. Batch completion invariant

Historical/pre-Leap shape:

```text
one PendingPointerBatch
  → one remote request
  → one delivery result
  → one completion
  → at most one handoff-accounting operation
```

If ten raw moves of +1 coalesce into one batch of move(+10), the helper sees one
request and `pointerMoved` is credited once with the aggregate. The Leap may
rename/remove these concrete types, but must preserve the semantic accounting
invariant for coalesced additive work.

### 3. Admission and delivery are different lifecycle domains

**Admission** decides whether work is accepted/coalesced, locally shed when the
event class permits it, or safety-rejected. An additive event shed at admission
was never delivered, so it must not fabricate a transport failure or completion.

**Delivery** produces outcomes only for admitted remote work. The pre-Leap
`PointerAdmissionOutcome` / `PointerDeliveryResult` concrete APIs are historical;
ADR-0016/#106 may replace them while preserving the domain separation.

Invariant retained by the Leap: **local queue/ingress saturation must never imply
`remoteUnavailable`.** Failure classification is event-class-specific.

### 4. Buttons are state transitions, never samples

A button down/up pair alters persistent remote state. Buttons never coalesce,
never reorder, and are never dropped silently. If bounded admission cannot retain
a button transition losslessly, admission safety-rejects it rather than sending
an incomplete state transition.

The pre-Leap implementation responds through `ControlHandoffController` and
`InputSender.releaseRemotelyHeldButtons()`. Its historical cleanup behavior was:

- record buttons after helper acknowledgement;
- best-effort ordered release of acknowledged held buttons on local return;
- per-generation stale-work rejection;
- aggregate attempted/succeeded/failed diagnostics; and
- no retry loop that delays local return.

**Leap supersession:** these implementation details are not the final ownership
contract. In ADR-0016/#106:

- the triggering non-droppable host transition that fails admission is not
  silently consumed; local return occurs synchronously;
- confirmed held state belongs to the closing Control's outcome-based delivery
  ledger;
- already-issued persistent transitions retain correlation/outcome ownership
  after local return;
- terminal cleanup runs under the old routing context behind the predecessor
  remote-close fence; and
- cleanup failure/ambiguity does **not** become clean merely because local
  bookkeeping is cleared. The Session enters recovery/non-control-capable state
  until remote cleanliness is proved.

Local host control still never waits for cleanup.

### 5. Failure taxonomy

Historical #62 classification and retained interpretation:

| Condition | Domain | Retained semantic action |
|---|---|---|
| move/scroll merged into adjacent compatible tail | admission | coalesced semantic work; no duplicate accounting |
| new additive/stateful work with capacity | admission | accepted |
| move/scroll saturation | admission | local shed allowed only under explicit additive policy; no fabricated remote failure |
| button/key persistent transition saturation | admission/safety | non-lossy fail-local; triggering persistent host event is not silently consumed |
| delivered additive/persistent work | delivery | semantic success/ack according to the remote contract |
| timeout / transport / malformed protocol | delivery | classify by event semantics and transport trust; persistent ambiguity is stronger than additive uncertainty |
| stale old owner | lifecycle | reject structurally through lease/session ownership, not a replacement global generation |

The old `.cancelled` / `.failed` enum names and generation plumbing are not target
architecture requirements.

### 6. Complexity and concurrency

The retained hot-path requirement is bounded/O(1)-style admission: inspect or
rewrite an adjacent tail, append/capacity check, and return immediately. The
capture path performs no transport I/O, actor wait, semaphore wait, or arbitrary
callback while holding its tiny safety/admission lock.

The old `stateLock` and pointer-only queue are implementation history. ADR-0016
uses one bounded synchronous `InputIngress` per ControlLease and one ordered
semantic delivery lane.

### 7. Watchdog semantics

Confirmed remote progress may feed watchdog policy. Work shed locally before
remote admission is not remote confirmation and must not fabricate watchdog
progress or remote failure.

### 8. Historical timeout and capacity

`maxPendingPointerItems = 64` and `pointerRequestTimeout = 0.75 s` were validated
for the pre-Leap implementation. They remain useful measurements/baselines, not
immutable target-architecture constants. #106 may retain or revise concrete
capacity/timeout values only with deterministic tests and measurements; changing
ownership architecture alone does not justify arbitrary tuning.

## Leap interpretation summary

Retained:

- bounded admission;
- adjacent additive coalescing with semantic sum preservation;
- one accounting obligation for one coalesced semantic delivery unit;
- admission and delivery are distinct domains;
- additive saturation may degrade by policy rather than masquerade as transport
  failure;
- persistent key/button transitions are non-lossy/non-reorderable;
- payload-safe aggregate diagnostics; and
- local return never waits indefinitely for remote cleanup.

Superseded by ADR-0016/#105/#106/#107/#141:

- `InputSender` as the architectural owner;
- separate pointer and keyboard queues;
- raw generation counters as primary stale-work correctness;
- the old `ControlHandoffController` failure path;
- cleanup bookkeeping being cleared as if that proved remote state clean;
- cancellation of already-issued persistent work without preserved outcome
  ownership; and
- any interpretation where old in-flight stateful work may execute after a
  replacement Control becomes active.

## Alternatives Rejected

- **Completion list fan-out:** one aggregate delivery result acknowledged once per
  contributing raw event multiplies handoff accounting N-fold, requires O(n)
  callback copying per coalesce, and blurs admission with delivery.
- **Larger/unbounded queue:** raises/removes a threshold while preserving wrong
  failure classification; violates bounded-local-recovery goals.
- **Reporting local saturation as delivery cancellation/failure:** fabricates a
  remote result for work never admitted.
- **Dropping button/key transitions lossily:** can strand persistent remote or
  local state; unacceptable.
- **Sleep/debounce/throttling at the event tap:** delays the macOS event-tap
  thread and adds arbitrary latency.

## Consequences

- Scroll and move bursts may coalesce into fewer semantic remote operations.
- Additive-only saturation can degrade gracefully according to bounded policy.
- Persistent transition saturation fails local rather than silently losing
  state.
- The Leap must reproduce the #62 semantic properties without preserving the old
  pointer-only queue/controller/generation architecture.
- Remote cleanliness after failed persistent cleanup is now stricter than this
  ADR's pre-Leap bookkeeping model: uncertainty gates Session reuse.

## Validation

Historical unit/integration evidence for #62 includes:

- admission outcome separation from delivery results;
- ten raw moves coalescing to one move request/accounting unit with aggregate
  delta preserved;
- handoff accounting once per coalesced semantic batch;
- stale in-flight result not crediting replacement handoff state;
- scroll accumulation/ordering matrices;
- buttonDown → large scroll burst → buttonUp remaining lossless;
- additive saturation shedding without fabricated callbacks/requests;
- button overflow safety rejection without sending a partial button frame;
- timeout/transport/malformed/helper failure coverage;
- lifecycle cancellation/replacement coverage; and
- aggregate metadata diagnostics without input payload logging.

The final pre-Leap suite recorded 120 XCTest + 30 Swift Testing tests with zero
failures at that historical candidate and targeted physical #62 acceptance on
SM-G977N DeX.

Those results remain evidence for coalescing/backpressure semantics; they are not
proof of ADR-0016's new ownership, remote-close, acquisition-linearization,
semantic-key-outcome, or recovery-fence contracts. Each implementation slice
must supply its own exact-final-HEAD deterministic and, where device-dependent,
physical evidence.

## Revisit Conditions

- Reproducible evidence that legitimate requests exceed the chosen delivery
  timeout after the Leap implementation.
- Introduction of additional additive input kinds (for example momentum/inertial
  scroll) — extend the semantic coalescing table rather than special-casing.
- A measured reason to pipeline the stateful RemoteCommandLane, subject to the
  ADR-0016 ordering/barrier proof obligations.
