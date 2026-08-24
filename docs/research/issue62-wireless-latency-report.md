# Issue #62 — Wireless ADB Latency/Timeout Investigation

**Status:** INVESTIGATION COMPLETE (observability + harness + measurement)
**Tested HEAD:** `40a0786137596088345855e6d8a2db491c49cc1f`
**Date:** 2026-08-25 (rev 3 — post-review-round-2; supersedes rev 1/2)
**Related:** issue #62, PR #63, PR #66 review, ADR-0011, ADR-0012

## Rev history

- **Rev 1:** burst profile waited per event (serialized RTT, not a burst);
  delivery results discarded; overstated conclusion. Superseded.
- **Rev 2:** real bursts + product fail-safe semantics + tombstone TTL fixes;
  aggregator `pct()` runtime bug and publication-order defects remained.
  Superseded.
- **Rev 3 (this):** aggregator fixed and CI-gated by a fixture test;
  result-summary/latency-summary now generated into the raw zone and published
  through the sanitizer like every other artifact; queue-pressure rewritten to
  produce REAL saturation (alternating non-mergeable kinds → shed > 0);
  tombstone recorded only when the timeout wins the eviction race; bounded
  late-response grace window after any timeout; production failure/late
  telemetry sink wired into the app (`Diagnostics.log`); `DecodeError`
  classified as `malformedResponse`; delivery-result counters persisted in
  evidence JSON.

## Environment

| Item | Value |
|---|---|
| Device | Samsung SM-G977N (beyondxks), Android 12 (API 31) |
| Transport | **Wireless ADB**, mDNS/TLS (`_adb-tls-connect._tcp`) — fail-closed precondition |
| Host | Darwin 25.5.0 arm64, headless over SSH |
| Display | DeX desktop display discovered at runtime (`dex_display_id=16`) |
| Competing load | scrcpy OFF |
| Evidence | `docs/research/evidence/issue-62-wireless-latency/20260825T025810Z-40a0786/` |

## Workloads executed (wireless ADB)

All numbers from `latency-summary.json` at the HEAD above. Latency =
production request latency (request issue → correlated POINTER_RESULT).

| Profile | events | remote reqs | coalesced | shed | p50 | p95 | p99 | max | timeouts | late |
|---|---|---|---|---|---|---|---|---|---|---|
| baseline (serial) | 500 | 500 | 0 | 0 | 11.3 ms | 19.3 ms | 27.1 ms | 31.3 ms | 0 | 0 |
| scroll-burst (25×20) | 500 | 37 | 463 | 0 | 64.4 ms | 97.3 ms | 105.6 ms | 105.6 ms | 0 | 0 |
| move-burst (same shape) | 500 | 39 | 461 | 0 | 64.1 ms | 106.2 ms | 117.5 ms | 117.5 ms | 0 | 0 |
| mixed move+scroll | 500 | 500 | 0* | 0 | 10.7 ms | 19.2 ms | 23.6 ms | 25.6 ms | 0 | 0 |
| burst-idle cycles | 480 | 35 | 445 | 0 | 72.5 ms | 99.9 ms | 113.9 ms | 113.9 ms | 0 | 0 |
| queue-pressure (25×128 alternating) | 3,200 | 1,616 | 784 | 800 | 14.2 ms | 21.7 ms | 75.6 ms | 123.4 ms | 0 | 0 |
| **Total** | **5,680** | **2,727** | | **800** | | | | | **0** | **0** |

*mixed alternates kinds every event, so tail merging rarely engages by design.

Structural findings:

- Real bursts collapse ~13 events/request; deep alternating-kind pressure
  fills the 64-slot queue and sheds 800 events while remaining completely
  failure-free — local backpressure never masqueraded as transport failure
  (the PR #63 invariant holds on-device).
- Zero timeouts across 2,727 requests. Zero late responses. Zero partial /
  failed / helper-failure deliveries (persisted in evidence JSON).

## Root-cause statement

- **QUEUE-ADMISSION ROOT CAUSE: CONFIRMED** — by PR #63's code-path analysis,
  regression tests, and this run: 800 locally shed events produced no
  transport failure and no force-return signal.
- **WIRELESS RESIDUAL TIMEOUT CAUSE: NOT REPRODUCED / INCONCLUSIVE.** Genuine
  timeouts observed 3× during manual physical validation did not reproduce
  under unattended stress (0 across rev-2 + rev-3 runs). If one recurs in the
  field, it is now auto-classified: the production app logs
  timeout/stream-closed/write-failed/malformed/helper-failure reasons to
  diag.log, and a bounded grace window captures late responses after any
  timeout.
- **0.75 s TIMEOUT CHANGE: NOT JUSTIFIED BY CURRENT DATA** (Case A). Healthy
  p99 ≤ ~118 ms even under real bursts and saturation; budget stays ≥6× above
  worst case. Unchanged per ADR-0011 §8.

## Recommendation

1. No timeout change.
2. Keep observability permanently (production sink + harness).
3. Issue #62 stays OPEN pending the targeted physical usability check
   (ADR-0012 Level 1).

## Reproduction

```sh
scripts/verify-device-issue62.sh <HEAD-sha>                    # six profiles
scripts/verify-device-issue62.sh <sha> --profile queue-pressure
```

Exit codes: 0 pass · 1 product failure · 2 usage/env · 3 precondition
(wireless/DeX fail-closed unless `ALLOW_NON_WIRELESS_DIAGNOSTIC=1`).
