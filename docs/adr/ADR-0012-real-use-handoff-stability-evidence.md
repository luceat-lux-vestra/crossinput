# ADR-0012: Real-Use Handoff Stability Evidence

**Status:** Accepted
**Date:** 2026-08-25
**Issue:** #64
**Related:** AGENTS.md (Verification criteria), docs/testing.md (Verification levels), ADR-0009, ADR-0011

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

The underlying intent — accumulate at least 100 real physical handoff/return
cycles of operational evidence before declaring release stability — is sound
and is retained. Only the manual execution method is removed. Issue #62 / PR
#63 exposed the concrete conflict: a bug-fix PR was being asked to satisfy a
release-level gate before merge.

## Decision

### Verification levels

Three explicit levels (full definition in `docs/testing.md`):

1. **Level 1 — Issue/PR acceptance.** Unit/integration tests + CI green +
   targeted real-device verification of the behavior the change touched +
   human visual confirmation where machines cannot observe. Never repetitive
   cycles; never 100 cycles.
2. **Level 2 — Feature stabilization.** After all blocker issues for a feature
   close: release-candidate build, representative physical smoke test,
   diagnostics readiness for all classifiable failure modes.
3. **Level 3 — Release stability.** On one release-candidate lineage:
   >=100 real physical completed handoff cycles with sufficient diagnostics;
   final stability verdict.

A bug-fix PR is gated by Level 1 only. The >=100-cycle criterion is a
feature/release gate (Level 3), not a per-PR merge gate.

### Physical-cycle definition

One physical cycle requires a real physical target:

```
local -> successful physical remoteActive entry -> usable remote session
      -> return/local recovery
```

Synthetic loops (`testOneHundredEdgeHandoffCyclesStaySafe`, state-machine
replays) are deterministic regression tests worth keeping, but contribute
**zero** physical cycles.

### Candidate identity

Every RC log line must be attributable to a candidate. Minimum identity
fields recorded at runtime: app version, build identifier, candidate
identifier. Development/RC builds inject the git SHA at build time; nothing
reads `.git` at runtime. Logs mixing candidates cannot produce a PASS.

### Failure taxonomy

Diagnostics must allow classifying every observed anomaly into:

- normal return
- external takeover
- emergency return
- genuine transport/session failure (ADB disconnect, helper crash, app
  disable)
- `remoteUnavailable` force-return
- watchdog recovery
- queue shed / scroll coalescing pressure events
- cancelled-delivery burst
- held-button cleanup attempted/succeeded/failed

Exactly-classified environmental events (ADB disconnect, helper crash,
external takeover, emergency shortcut) are recorded but do not count as
handoff correctness failures.

Fail-closed classification: an unknown reason is `UNCLASSIFIED`; insufficient
log detail is `INSUFFICIENT_EVIDENCE`; mixed build identities are
`MIXED_CANDIDATES`. None of these can yield an automatic PASS; they require
human adjudication before any stability claim.

### Privacy boundaries

Raw input is never logged (AGENTS.md hard rule 4). Evidence consists of
metadata only: transition reasons, counts, timings, sequence numbers,
candidate identity.

### Evidence sufficiency

A stability verdict requires, per candidate window:

- `completed physical cycles >= 100`
- pointer trap = 0
- known stuck-button incident = 0
- unexplained `remoteUnavailable` = 0
- healthy-session watchdog recovery = 0
- unclassified control failure = 0
- every other observed event classified into the taxonomy above

An offline analyzer (e.g. `scripts/analyze-handoff-stability.sh`) emits these
counters and a fail-closed `STABILITY_GATE` verdict from sanitized diag logs.

## Evidence-window reset rules

Accumulated cycle credit belongs to a candidate lineage. Start a **new**
window when a production change lands in:

- `InputCapture`
- `InputSender`
- `ControlHandoffController`
- edge-switch state machine
- session lifecycle management
- helper pointer routing
- CXI protocol semantics relevant to handoff

Do **not** reset for changes with no effect on handoff semantics (docs,
comments, CI config, README fixes, unrelated subsystems).

## Alternatives Rejected

- **Manual 100 consecutive cycles per PR** — artificial usage pattern; human
  counting error; expensive to the single hardware holder; poor reproduction
  diversity (one sitting samples one posture/app/thermal state); yields weaker
  operational evidence than natural usage; discourages repeated verification.
  Not rejected because it was inconvenient — it was rejected as *weaker
  evidence*.
- **Removing the 100-cycle requirement entirely** — discards the only
  quantitative operational-confidence threshold; replaced here by natural-use
  accumulation instead.
- **Counting synthetic/state-machine loop executions toward the total** —
  violates the physical-target requirement; a state-machine replay proves
  logic, not device behavior.
- **Per-PR 10+ repetitions for every touched item** (legacy "repeat each item
  10+" rule): kept only where a threshold has a stated rationale (e.g.
  reproducing an intermittent defect); otherwise replaced by targeted
  acceptance scoped to what the change could affect.

## Consequences

- Bug-fix PRs (#63-style) merge on targeted physical acceptance; feature
  stabilization tracks the aggregate.
- Users are never asked to mechanically repeat a handoff 100 times.
- Requires runtime candidate identity in logs and eventually an offline
  analyzer script; until those exist, Level-3 verdicts are made by hand from
  sanitized diag excerpts.
- Stability tracking issue must record the active candidate window and reset
  events.

## Validation

- Policy adopted in AGENTS.md (Verification criteria) and `docs/testing.md`
  (Verification levels, Physical handoff cycle definition).
- Applied to PR #63: acceptance reduced to targeted #62 physical checks; the
  100-cycle section moved to this release-level gate.

## Revisit Conditions

- If natural-use accumulation proves too slow to ever reach 100 cycles,
  design and approve a physical automation harness (robotic or scripted HID
  input against real hardware) — still physical, never synthetic loops.
- If the analyzer's classification rate is too low (many UNCLASSIFIED),
  extend diagnostic metadata rather than loosening the fail-closed rule.
- If wireless ADB latency produces legitimate timeouts during accumulation,
  handle timeout tuning as a separate measured issue, not inside this gate.
