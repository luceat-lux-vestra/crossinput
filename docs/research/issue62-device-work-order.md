# Issue #62 — Physical Device Verification Work Order

**Status:** COMPLETE — Level-1 physical acceptance PASSED at main
`d66a357bc5824707bcc0a3bb69d31c7fb3a939f6`; issue #62 closed 2026-08-26.
Authoritative stress evidence remains PR #66's
`20260825T051359Z-6a48ab7/`; the final usability check is recorded in
`evidence/issue62-level1-usability/20260825T175101Z-d66a357/`.
**Device:** Samsung SM-G977N (DeX wired HDMI, display id=2), wireless ADB (mDNS/TLS)
**Dates:** 2026-08-25 (preflight + PR #66 measurement), 2026-08-26 (final Level-1 acceptance)

## Final Level-1 physical acceptance (2026-08-26) — PASSED

Performed against main `d66a357bc5824707bcc0a3bb69d31c7fb3a939f6` (production
code identical to PR #66's physical-evidence commit `6a48ab7`; local suite at
the candidate: 140 XCTest + 30 Swift Testing, 0 failures). Two bounded windows,
SM-G977N DeX over wireless mDNS/TLS ADB, natural representative interaction —
no artificial repetition counts. Full sanitized record:
[`evidence/issue62-level1-usability/20260825T175101Z-d66a357/metadata.txt`](evidence/issue62-level1-usability/20260825T175101Z-d66a357/metadata.txt).

Checklist result: all items pass. Handoff entry, pointer visibility/motion,
vertical scroll direction, aggressive scroll bursts (2,200+ coalesced batches in
one burst cluster) with no false return, pointer/clicks usable after pressure,
no stuck-button state, no premature return on small return-direction movement,
normal pull-back return, and successful re-entry after stress.

Classification (PR #66 taxonomy): 37 remoteActive entries; 36 normal returns;
1 `remoteUnavailable` force-return classified as a **genuine transport/session
failure** — the wireless ADB session ended when the phone rebooted mid-window;
UHID reports had succeeded continuously up to the drop, and the window contains
zero request timeouts, late responses, partial/failed deliveries, shed events,
or watchdog recoveries. Queue-pressure-induced `remoteUnavailable` count: **0**.
Cancelled-delivery lines are single-batch lifecycle invalidations at return
boundaries (ADR-0011 semantics), not failures. Unclassified events: 0.

Human visual confirmation: entry, pointer motion, vertical scroll feel, click
functionality after stress, absence of false returns — confirmed by the user on
the DeX display. One observation recorded as out of scope: horizontal scroll is
perceived slower than vertical; no causal path to #62, tracked separately if
evidence emerges.

**Verdict: PASS — issue #62 closure-ready.** `pointerRequestTimeout = 0.75 s`
remains unchanged; nothing observed contradicts the PR #66 conclusion that
raising it is currently unsupported.

## Former 100-cycle gate

Moved to the repository release-stability gate. **Not a #62 PR acceptance
requirement.** See [ADR-0012](../adr/ADR-0012-real-use-handoff-stability-evidence.md),
the verification-level taxonomy in `docs/testing.md`, and the canonical
Level-3 tracking issue (#68 — ADR-0012 release-stability gate; #64 was the
completed policy change and is no longer an active tracker).

## Historical automated preflight

Recorded against implementation HEAD `7804f0ee8587409db32e590fd8deeed43a182f63`
under the previous CI/test-count baseline. Preserved as-is; superseded by the
"Current code-reviewed candidate" section below.

### Code phase

| Item | Result |
|---|---|
| Local build (`swift build`) | exit 0, 0 warnings |
| Local tests (`swift test`) | exit 0; 116 XCTest + 30 Swift Testing, 0 failures |
| CI run 32742906885 | all 4 jobs PASS |
| macOS job log inspection | correct HEAD checked out; `swift build` + `swift test` clean; 116 XCTest + 30 Swift Testing executed; 0 compiler warnings |
| Mutation-killing regression proof | `testTenRawMovesProduceOneMoveRequestAndOneMovementCompletion` and `testCoalescedFirstMovementBatchIsAppliedExactlyOnce` fail on fan-out implementation (commit ae15c22 semantics); `testCancelledInFlightReturnMovementNeverCreditsHandoff` fails if generation/stale-result protection is removed (−100 ≤ −60 would force return) |

### Automated physical sanity checks (§29)

Performed 2026-08-25 ~00:15–00:20 KST at HEAD `7804f0e`, helper APK rebuilt from same HEAD:

1. device visible through adb: OK (`adb devices` lists the SM-G977N over TLS)
2. helper starts successfully: OK (`app_process` launch via `scripts/deploy-helper.sh start`; stderr shows `[Main] handshake ok (v1 capabilities=3)`)
3. display list discovered: OK (3 displays: Built-in Screen, HDMI Screen, Desktop)
4. DeX Desktop target discovered dynamically: OK (`virtual:android,1000,Desktop,0`, display id **2** read from `dumpsys display` at runtime, not hardcoded)
5. session handshake succeeds: OK (HELLO → HELLO_ACK rid=1)
6. correct pointer backend selected: OK (`[PointerDispatcher] pointer backend selected backend=uhid mode=auto target=2 routing=system`)
7. `pointerResult status success under ordinary input`: OK (parsed stdout frames: `POINTER_RESULT rid=10 status=0 dx=12 dy=-8`; rid=11..13 status=0)
8. no repeated transport timeout: OK (0 timeout/error lines in helper stderr log)
9. no duplicate request-ID anomalies: OK (request ids strictly increasing 10..13)

Helper UHID reports delivered: `report sent id=2 len=5 written=11` (metadata only).

## Current code-reviewed candidate

| Item | Result |
|---|---|
| HEAD | `5485008f721acfcf99fb5733b6739bce972c5d38` (branch rebased onto main `8537dbe` after policy PR #65) |
| Local build (`swift build`) | exit 0, 0 warnings |
| Local tests | exit 0; 120 XCTest + 30 Swift Testing, 0 failures |
| CI run #130 ([32759694491](https://github.com/luceat-lux-vestra/crossinput/actions/runs/32759694491)) | all four jobs PASS (pre-rebase equivalent content; fresh run required at final post-rebase SHA before merge) |
| Held-button cleanup semantics | best-effort; outcomes reported accurately as attempted/succeeded/failed; a failed release is never counted as released |

## Remaining targeted physical acceptance (#63-era — satisfied 2026-08-26)

The checklist below was defined for the PR #63 candidate and has since been
executed in full against main `d66a357` (see "Final Level-1 physical
acceptance" above). Retained verbatim for history:

- [x] Mac -> DeX handoff entry works.
- [x] Pointer actually moves on the DeX screen.
- [x] Vertical scroll direction correct.
- [x] Aggressive vertical scroll burst does not cause false return to Mac.
- [x] Aggressive horizontal/mixed scroll burst where physically practical does
      not cause false return.
- [x] Pointer remains usable immediately after bursts.
- [x] Left / right / middle click remain usable; no stuck-button state.
- [x] Small return-direction movement does not trigger early return.
- [x] Intentional pull back to Mac returns normally.
