# Issue #62 — Physical Device Verification Work Order (PR #63)

**Status:** IN_PROGRESS — code phase complete, human visual checks pending
**Final tested HEAD:** `7804f0ee8587409db32e590fd8deeed43a182f63`
**Device:** Samsung SM-G977N (DeX / virtual "Desktop" target), wireless ADB
**Date:** 2026-08-25

## Automated verification completed

### Code phase

| Item | Result |
|---|---|
| Local build (`swift build`) | exit 0, 0 warnings |
| Local tests (`swift test`) | exit 0; 116 XCTest + 30 Swift Testing, 0 failures |
| CI run 32742906885 (HEAD merged as `73dfafd` onto main) | all 4 jobs PASS |
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

## Human visual checks (§§30–45): MANUAL_REQUIRED

To be performed by the user with the installed `/Applications/Ampersand.app`
built from HEAD `7804f0e` and the running helper. Checklist per work order:
handoff entry, pointer movement fidelity, vertical/horizontal scroll direction,
aggressive vertical/horizontal/mixed scroll bursts, sustained pressure,
pointer-after-burst responsiveness, button behavior after pressure, idle
reappearance, small return-direction movement (no false return), intentional
return, rapid scroll-then-return repeats.

## Diagnostics inspection after user stress testing (§46–47): PENDING

Check `~/Library/Logs/Ampersand/diag.log` for:

- FAIL signal: `remoteActive -> returning reason=remoteUnavailable` during healthy scroll bursts
- expected metadata: `pointer queue saturation shed count=` (acceptable under extreme pressure),
  `pointer scroll batches coalesced count=` (expected),
  `watchdogTimeout` (must not occur during healthy delivery)
- correlate any Mac-side `remoteUnavailable` against helper log
  (`/data/local/tmp/cxi-helper.log`); helper continued reporting success while
  Mac reported remoteUnavailable would mean the issue is not closed.

## 100-cycle edge handoff/return gate (§§48–49): MANUAL_REQUIRED

Physical 100/100 cycles with scroll-pressure segments per work order grouping.
