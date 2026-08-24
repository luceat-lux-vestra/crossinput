# Issue #62 — Physical Device Verification Work Order (PR #63)

**Status:** IN_PROGRESS — code-reviewed candidate ready; targeted physical
acceptance pending (per ADR-0012 verification policy)
**Current code-reviewed candidate:** `5485008f721acfcf99fb5733b6739bce972c5d38`
(rebased onto main `8537dbe`, includes policy PR #65)
**Device:** Samsung SM-G977N (DeX / virtual "Desktop" target), wireless ADB
**Date:** 2026-08-25 (historical preflight), 2026-08-25 (candidate update)

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

## Remaining targeted physical acceptance (#62 only)

Per ADR-0012 Level 1 — no repetitive cycles required. To be performed with
the app built from the final candidate HEAD:

- [ ] Mac -> DeX handoff entry works.
- [ ] Pointer actually moves on the DeX screen.
- [ ] Vertical scroll direction correct.
- [ ] Aggressive vertical scroll burst does not cause false return to Mac.
- [ ] Aggressive horizontal/mixed scroll burst where physically practical does
      not cause false return.
- [ ] Pointer remains usable immediately after bursts.
- [ ] Left / right / middle click remain usable; no stuck-button state.
- [ ] Small return-direction movement does not trigger early return.
- [ ] Intentional pull back to Mac returns normally.

After stress: inspect `~/Library/Logs/Ampersand/diag.log` for
`remoteActive -> returning reason=remoteUnavailable`. Zero occurrences caused
by healthy scroll bursts is the pass signal. These lines are expected and are
not failures: `pointer scroll batches coalesced ...`,
`pointer queue saturation shed ...` (shed is the intended overload
degradation). Correlate any Mac-side `remoteUnavailable` against
`/data/local/tmp/cxi-helper.log`.

## Former 100-cycle gate

Moved to the repository release-stability gate. **Not a #62 PR acceptance
requirement.** See [ADR-0012](../adr/ADR-0012-real-use-handoff-stability-evidence.md),
the verification-level taxonomy in `docs/testing.md`, and tracking issue #64.
