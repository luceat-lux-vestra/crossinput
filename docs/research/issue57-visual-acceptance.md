# Issue #57 physical visual acceptance — 2026-08-24

Revision under test: `d78cf45` branch HEAD (product fixes at `ea890ea`).
Device: SM-G977N + Samsung DeX (virtual Desktop display, dynamically
discovered). macOS app: `/Applications/Ampersand.app` built from the same
HEAD. Tester: human operator on the physical DeX screen.

Automated driver results for this revision: see
`evidence/issue-57-device-verification/20260823T192306Z-8f1976c/`
(overall AUTOMATED_PASS_PHYSICAL_VISUAL_PENDING). This record covers the
four items the driver marks MANUAL_REQUIRED.

| item | result | notes |
|---|---|---|
| visible_pointer_motion | **PASS** | DeX pointer sprite visibly follows Mac cursor; not frozen at center |
| idle_pointer_reappearance | **PASS** | pointer hides after ~3–5 s of inactivity (shorter than the assumed 15 s window) and reappears and follows on next movement |
| visual_scroll_direction | **PASS** | vertical and horizontal directions were both visually confirmed on physical DeX content: +v up / −v down / +h left / −h right. Sustained or rapid scroll bursts can force-return the session to macOS because of the separate pre-existing pointer-queue overflow tracked in #62; the horizontal movement and direction were visibly observed before that return. |
| full_edge_handoff_return | **PASS with known issue** | entry and return work repeatedly (sequences 134–157 in diag.log); no trapping, pointer recoverable. During rapid scroll bursts the session force-returns — root-caused to the macOS pointer queue overflow, filed as #62 (pre-existing macOS app defect, independent of PR #59's Android fixes) |

## Follow-ups

- #62: scroll burst queue overflow force-return (macOS, pre-existing).
