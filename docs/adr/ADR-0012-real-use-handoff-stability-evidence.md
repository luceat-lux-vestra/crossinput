# ADR-0012: Real-Use Handoff Stability Evidence

**Status:** Accepted
**Date:** 2026-08-25
**Issue:** #64
**Related:** AGENTS.md (Verification criteria), docs/testing.md (Verification levels), ADR-0009, ADR-0011, ADR-0016

> **Architecture Leap note (2026-09-13):** this ADR remains the authority for
> physical Level-3 evidence. Its reset rules are responsibility/behavior based,
> not tied to pre-Leap class names. Historical names such as `InputCapture`,
> `InputSender`, and `ControlHandoffController` identify the old implementation
> of those responsibilities only. Replacing those classes under ADR-0016 does
> not avoid an evidence-window reset when the production behavior that can affect
> handoff/return safety changes.
>
> **Level-3 revision (2026-10-06):** the former 100-cycle release blocker is
> replaced by a risk-based physical qualification matrix: 30 real-device
> scenario executions, a representative real-use soak, fail-closed diagnostics,
> and zero safety failures. One hundred or more physical cycles remain useful
> optional extended-confidence evidence, but are not a release blocker.

## Context

The repository previously required: "Edge switching stability is not declared
complete until 100 repeat edge-switch tests pass." In practice this was read
as a per-PR merge gate requiring a person to bounce the pointer across the
edge 100 times in one sitting.

Problems with the manual-repetition reading:

1. **Artificial usage pattern.** One hundred deliberate back-and-forth
   crossings in a row exercises neither the event diversity nor the session
   durations of real use.
2. **Human counting error.** Manual counting of long repetitive actions is
   unreliable; the evidence value degrades exactly when the count matters.
3. **Expensive and discouraging.** The cost falls entirely on the one person
   with hardware access, which discourages re-running verification after any
   change.
4. **Poor reproduction diversity.** Repetition in one sitting samples one
   posture, one app mix, one thermal state — real use samples many.
5. **Weaker operational evidence than natural usage.** A week of real DeX use
   with diagnostics says more about operational stability than 5 minutes of
   mechanical repetition.

The underlying intent — require real-device operational evidence before
declaring release stability — is retained. The original fixed 100-cycle quota
is not: repetitive count alone is expensive, samples too few failure modes, and
does not by itself establish a sufficiently strong reliability bound. Level 3
therefore uses a risk-based scenario matrix plus a real-use soak, while keeping
fail-closed diagnostics and zero-tolerance safety outcomes. Issue #62 / PR #63
exposed the original conflict: a bug-fix PR was being asked to satisfy a
release-level gate before merge.

## Decision

### Verification levels

Three explicit levels (full definition in `docs/testing.md`):

1. **Level 1 — Issue/PR acceptance.** Unit/integration tests + CI green +
   targeted real-device verification of the behavior the change touched +
   human visual confirmation where machines cannot observe. Never impose the
   release-level matrix as a per-PR ritual.
2. **Level 2 — Feature stabilization.** After all blocker issues for a feature
   close: release-candidate build, representative physical smoke test,
   diagnostics readiness for all classifiable failure modes.
3. **Level 3 — Release stability.** On one release-candidate lineage, complete
   the risk-based physical qualification matrix below, run a representative
   real-use soak, and obtain a fail-closed diagnostic PASS with zero safety
   failures.

A bug-fix PR is gated by Level 1 only. The Level-3 scenario matrix is a
feature/release gate, not a per-PR merge gate.

### Physical-cycle definition

One physical cycle requires a real physical target:

```text
local -> successful physical remote-active entry -> usable remote session
      -> return/local recovery
```

Synthetic loops (`testOneHundredEdgeHandoffCyclesStaySafe`, state-machine
replays) are deterministic regression tests worth keeping, but contribute
**zero** physical qualification credit.

The Level-3 matrix is deliberately broader than this normal-cycle definition.
Emergency return, transport/helper failure, reconnect/re-entry, and lifecycle
safety scenarios are real-device qualification executions even when they do not
produce a normal `boundaryCrossed` completed-cycle credit.

### Candidate identity

Every RC log line must be attributable to a candidate. Minimum identity
fields recorded at runtime: app version, build identifier, candidate
identifier. Development/RC builds inject the git SHA at build time; nothing
reads `.git` at runtime. Logs mixing candidates cannot produce a PASS.

### Failure taxonomy

Diagnostics must allow classifying every observed anomaly into semantic
categories that survive architecture changes:

- normal return;
- external takeover;
- emergency return;
- genuine transport/session failure (ADB disconnect, helper crash, app
  disable);
- explicit fail-safe return because remote input/control is unavailable;
- watchdog recovery;
- bounded-admission / additive-coalescing pressure events;
- cancelled/retired remote work caused by lifecycle closure/replacement;
- held-input cleanup attempted/succeeded/failed/ambiguous; and
- Session/remote-state recovery required because cleanliness cannot be proved.

Concrete diagnostic event names may change during the Leap, but the analyzer
must preserve equivalent semantic classification.

Exactly-classified environmental events (ADB disconnect, helper crash,
external takeover, emergency shortcut) are recorded but do not count as
handoff correctness failures.

Fail-closed classification: an unknown reason is `UNCLASSIFIED`; insufficient
log detail is `INSUFFICIENT_EVIDENCE`; mixed build identities are
`MIXED_CANDIDATES`. None of these can yield an automatic PASS; they require
human adjudication before any stability claim.

### Privacy boundaries

Raw input is never logged (AGENTS.md hard rule 4). Evidence consists of
metadata only: transition reasons, counts, timings, sequence/ownership identity
metadata, candidate identity, and cleanup/recovery classification. Raw pointer
coordinates/deltas, key codes/typed contents, HID reports, and clipboard
contents remain prohibited.

### Evidence sufficiency

Level-3 release qualification requires all of the following on one eligible
candidate lineage:

| Physical scenario | Minimum |
| --- | ---: |
| Normal Mac -> remote -> Mac handoff/return | 10 |
| Emergency return | 5 |
| Transport/helper failure with fail-local recovery | 5 |
| Session reconnect/replacement followed by successful re-entry | 5 |
| Control/lifecycle safety paths (enable/disable, takeover, capability/capture loss, held-input cleanup, or equivalent) | 5 |

The matrix therefore contains at least **30 real-device scenario executions**.
The control/lifecycle group should cover representative distinct paths rather
than repeating one easy case five times.

In addition:

- perform at least **30 minutes** of representative real DeX use on the same
  candidate lineage (60 minutes is recommended when practical);
- pointer trap = 0;
- known stuck-key/button incident = 0;
- unexplained fail-safe remote-unavailable return = 0;
- healthy-session watchdog recovery = 0;
- unclassified control failure = 0;
- every other observed event is classified into the taxonomy above; and
- the exact candidate identity, matrix record, soak duration, and retained
  evidence are independently reviewed.

The offline analyzer (`scripts/analyze-handoff-stability.sh`) remains the
canonical fail-closed diagnostic classifier. It automatically requires at least
10 contract-complete normal physical cycles and verifies the machine-observable
zero-failure conditions. Analyzer PASS **does not by itself complete Level 3**:
the emergency/failure/reconnect/lifecycle matrix and soak are reviewed physical
evidence tracked by #68.

## Evidence-window reset rules

Accumulated cycle credit belongs to one release-candidate lineage. Start a
**new** evidence window whenever a production change can materially affect any
of these behaviors/responsibilities, regardless of the concrete class/file name:

- host capability, event capture, suppression, confinement, emergency/watchdog
  release, or external-control takeover;
- local/remote Control ownership, acquisition/return linearization, edge/handoff
  policy, or remote-control eligibility;
- InputIngress/admission, backpressure/coalescing policy, ordered delivery, or
  stateful command ordering;
- persistent key/button outcome accounting, remote-close fencing, held-input
  cleanup, or ambiguity/recovery classification;
- Session lifecycle, replacement/reconnect, Target selection/routing barriers,
  or remote-state cleanliness/recovery;
- helper pointer/keyboard routing, backend selection/failover, backend cleanup or
  reset semantics; or
- CXI protocol/capability/result semantics relevant to handoff, persistent input,
  target routing, cleanup, or recovery.

Historical examples of reset-sensitive implementations include `InputCapture`,
`InputSender`, `ControlHandoffController`, `EdgeSwitchStateMachine`, Session /
Target controllers, and helper pointer routing. Their replacement under
Architecture Leap does not narrow this policy.

Do **not** reset for changes with no effect on handoff/return semantics (docs,
comments, CI configuration, README fixes, unrelated subsystems). When impact is
uncertain, strict evidence policy treats UNKNOWN as reset-sensitive until the
change is proven behavior-neutral.

## Alternatives Rejected

- **Manual 100 consecutive cycles per PR** — artificial usage pattern; human
  counting error; expensive to the single hardware holder; poor reproduction
  diversity (one sitting samples one posture/app/thermal state); yields weaker
  operational evidence than natural usage; discourages repeated verification.
  Not rejected because it was inconvenient — it was rejected as *weaker
  evidence*.
- **Keeping 100 physical cycles as the mandatory release blocker** — rejected
  because a large repetitive quota is costly while under-sampling distinct
  safety and recovery paths. The replacement keeps a quantitative floor but
  distributes it across risk-bearing scenarios and adds a real-use soak.
- **Counting synthetic/state-machine loop executions toward the total** —
  violates the physical-target requirement; a state-machine replay proves
  logic, not device behavior.
- **Per-PR 10+ repetitions for every touched item** (legacy "repeat each item
  10+" rule): kept only where a threshold has a stated rationale (e.g.
  reproducing an intermittent defect); otherwise replaced by targeted
  acceptance scoped to what the change could affect.
- **Reset rules keyed to source class names** — rejected after Architecture Leap
  #101. A class rename/replacement must not preserve stale physical-cycle credit
  when the same safety-critical production behavior changed.

## Consequences

- Bug-fix PRs (#63-style) merge on targeted physical acceptance; feature
  stabilization tracks the aggregate.
- Users are not asked to satisfy a large repetitive handoff quota; Level 3 is
  executed as a bounded scenario matrix plus representative real use.
- Architecture Leap runtime slices that materially change the responsibilities
  above reset the Level-3 candidate window even when they delete/rename all old
  implementation types.
- Requires runtime candidate identity and diagnostics sufficient to map new
  architecture events back to the semantic failure taxonomy.
- Stability tracking issue records the active candidate window and reset events.

## Validation

- Policy adopted in AGENTS.md (Verification criteria) and `docs/testing.md`
  (Verification levels, Physical handoff cycle definition).
- Applied to PR #63: acceptance reduced to targeted #62 physical checks; the
  broader physical qualification remains a release-level gate.
- ADR-0016 keeps this physical-evidence policy authoritative while replacing the
  implementation ownership model.

## Revisit Conditions

- Optional extended qualification may accumulate 100+ physical cycles,
  manually or through an approved physical automation harness, when additional
  confidence is useful. This evidence supplements rather than blocks the
  scenario-based Level-3 gate.
- If the analyzer's classification rate is too low (many UNCLASSIFIED),
  extend diagnostic metadata rather than loosening the fail-closed rule.
- If wireless ADB latency produces legitimate timeouts during accumulation,
  handle timeout tuning as a separate measured issue, not inside this gate.
- If a future architecture introduces a new responsibility that can affect
  handoff/return safety, add that responsibility category to the reset policy;
  do not key the policy to a particular source filename.
