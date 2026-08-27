# ADR-0012 Level-3 — Legacy #62 Evidence Admissibility Assessment

**Status:** PENDING HUMAN ADJUDICATION (proposed credit: 36 accepted cycles)
**Evidence:** `docs/research/evidence/issue62-level1-usability/20260825T175101Z-d66a357/metadata.txt` (unchanged)
**Candidate lineage:** `d66a357bc5824707bcc0a3bb69d31c7fb3a939f6`
**Assessed against:** ADR-0012 §Evidence sufficiency, §Physical-cycle definition, §Evidence-window reset rules
**Analyzer result on this evidence:** `HOLD — MISSING_IDENTITY` (expected; see Q6)

## Question-by-question determination

### Q1. Is the evidence attributable strongly enough to one candidate lineage?

Yes, by build provenance rather than runtime marker. The metadata records the
tested candidate (`d66a357`) and the production-code equivalence to PR #66's
physically tested commit `6a48ab7` was verified by empty diff at acceptance
time. The window is single-candidate: the one mid-window transport failure is
fully explained by the user's phone reboot (ADB session ended; device absent
from the network ~01:45–01:57 KST), not by any candidate change. No
mixed-candidate condition exists.

However, attribution rests on out-of-band records (work order + evidence
metadata), not on a runtime diagnostic marker, because the marker did not
exist when the window was captured.

### Q2. Does it satisfy the physical-cycle definition?

Yes for 36 of 37 entries. Each accepted cycle has all three legs evidenced:

1. successful physical `remoteActive` entry (37 logged entries);
2. usable remote session (continuous UHID report successes — 29,748 pointer +
   92 keyboard reports delivered in window 2 alone; human visual confirmation
   of pointer motion, scroll, and clicks on the DeX display); and
3. return/local recovery (36 `remoteActive -> returning -> localActive`
   transitions with reason `boundaryCrossed`, i.e. normal returns).

### Q3. How many cycles can actually be proven complete?

**36.** The 37th entry ended in a classified environmental event (see Q4) and
earns no cycle credit under the fail-closed rule.

### Q4. Does the phone-reboot transport failure contribute a completed cycle or only a classified environmental event?

Only a **classified environmental event**. The recovery leg was the fail-safe
`remoteUnavailable` force-return caused by an external ADB session end —
correct product behavior, but not a *completed* physical handoff cycle (the
session did not end by intended local recovery). It is recorded, counted as
`transport_session_failures_environmental = 1`, and does not count toward the
100-cycle threshold either way.

### Q5. Is any required information missing?

One item, and only for automated re-analysis: the runtime candidate-identity
marker (`candidate identity app_version=… build_identifier=… candidate_identifier=…`)
did not exist in diagnostics at capture time. All substantive information
(candidate SHA, device, transport, counters, per-leg classification) is present.

### Q6. Does lack of the new runtime candidate marker force INSUFFICIENT_EVIDENCE?

For **automatic analyzer PASS credit, yes** — the analyzer correctly returns
`HOLD / MISSING_IDENTITY` on this evidence, and that verdict stands for any
unattended computation. But ADR-0012 explicitly permits human adjudication of
fail-closed classifications ("they require human adjudication before any
stability claim"). Because every other identity element is documented,
single-valued, and verifiable against git history, the missing marker is a
formality here, not an evidentiary gap. Hence: **pending human adjudication**,
with a concrete proposal below — not automatic credit, and not rejection.

### Q7. Does `c117c5da...` require a window reset from `d66a357...`?

**No.** `c117c5d` (PR #67) changed only documentation and evidence files:
`docs/research/evidence/issue62-level1-usability/20260825T175101Z-d66a357/metadata.txt`
and `docs/research/issue62-device-work-order.md`. ADR-0012's reset list covers
production changes with handoff semantics (InputCapture, InputSender,
ControlHandoffController, edge-switch state machine, session lifecycle, helper
pointer routing, CXI protocol). Docs-only changes explicitly do **not** reset
the window. Therefore the active Level-3 window remains the `d66a357` lineage,
and any adjudicated credit carries forward across `c117c5d`.

## Decision

| Item | Value |
|---|---|
| Analyzer verdict (automatic) | HOLD / MISSING_IDENTITY |
| Adjudication status | PENDING HUMAN ADJUDICATION |
| Proposed accepted legacy seed credit | **36 cycles** |
| Proposed rejected events | 1 entry (environmental transport failure, reboot) |
| Window continuity | `d66a357` lineage continues through `c117c5d` (docs-only, no reset) |

**Status 2026-08-27 — superseded for gate credit.** PR #69 changes production
`ControlHandoffController` code (pending-pointer lifecycle barrier, commit
`dd9b132`), which per ADR-0012 §Evidence-window reset rules starts a NEW
Level-3 window. This 36-cycle proposal describes the pre-#69 `d66a357`
window and can therefore never seed the post-#69 window: the canonical
tracker for the new window starts at **accepted = 0, required = 100,
remaining = 100**. This assessment is retained as historical adjudication
material only.
