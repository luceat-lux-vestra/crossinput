# Issue #62 — Wireless ADB Latency/Timeout Investigation

**Status:** INVESTIGATION COMPLETE (observability + harness + measurement)
**Tested HEAD (executable code):** `6a48ab7af950cfd898df21b6c0d78dd0283e7fed` — physical run executed at this exact push; evidence + docs committed separately as commit B per review process note. Authoritative DeX display id (`dex_display_id=2`, selected by the production path via `isDesktop`) recorded in metadata; the shell-side dumpsys guess (16) is retained as `_shell_guess` and shown wrong.
**Date:** 2026-08-25 (rev 5 — post-review-round-5 cleanup; supersedes rev 1–4)
**Related:** issue #62, PR #63, PR #66 review, ADR-0011, ADR-0012

## Rev history

- **Rev 1:** burst profile waited per event (serialized RTT, not a burst);
  delivery results discarded; overstated conclusion. Superseded.
- **Rev 2:** real bursts + product fail-safe semantics + tombstone TTL fixes;
  aggregator `pct()` runtime bug and publication-order defects remained.
  Superseded.
- **Rev 5 (this):** telemetry ownership split — RemoteSession owns transport
  outcomes only; InputSender owns semantic outcomes only (`DecodeError` →
  malformed, explicit `partialDelivery` observation for movement partials
  that the product maps to force-return); ConnectionError is never re-emitted.
  DeX gate enforced in cxi-stress via `isDesktop` with authoritative display
  id persisted into evidence. rc=2/3 handled before JSON lookup (CI fixture).
  Helper provisioning reduced to APK deploy — AdbTransport owns lifecycle.
- **Rev 3/4:** aggregator fixed and CI-gated by a fixture test;
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
| DeX desktop display | **id=2**; authoritative source: production `LIST_DISPLAYS` → `isDesktop`. Shell dumpsys guess: 16 (non-authoritative, known incorrect) |
| Competing load | scrcpy OFF |
| Evidence | `docs/research/evidence/issue-62-wireless-latency/20260825T051359Z-6a48ab7/` |

## Workloads executed (wireless ADB)

All numbers from `latency-summary.json` at the HEAD above. Latency =
production request latency (request issue → correlated POINTER_RESULT).

| Profile | events | remote reqs | coalesced | shed | p50 | p95 | p99 | max | timeouts | late |
|---|---|---|---|---|---|---|---|---|---|---|
| baseline (serial) | 500 | 500 | 0 | 0 | 9.9 ms | 19.3 ms | 23.7 ms | 54.6 ms | 0 | 0 |
| scroll-burst (25×20) | 500 | 45 | 455 | 0 | 26.5 ms | 92.0 ms | 124.7 ms | 124.7 ms | 0 | 0 |
| move-burst (same shape) | 500 | 46 | 454 | 0 | 61.9 ms | 97.6 ms | 116.1 ms | 116.1 ms | 0 | 0 |
| mixed move+scroll | 500 | 500 | 0* | 0 | 10.1 ms | 18.5 ms | 22.4 ms | 57.9 ms | 0 | 0 |
| burst-idle cycles | 480 | 45 | 435 | 0 | 17.9 ms | 104.4 ms | 127.4 ms | 127.4 ms | 0 | 0 |
| queue-pressure (25×128 alternating) | 3,200 | 1,625 | 775 | 800 | 12.5 ms | 19.1 ms | 46.0 ms | 123.3 ms | 0 | 0 |
| **Total** | **5,680** | **2,761** | | **800** | | | | | **0** | **0** |

*mixed alternates kinds every event, so tail merging rarely engages by design.

Structural findings:

- Real bursts collapse ~13 events/request; deep alternating-kind pressure
  fills the 64-slot queue and sheds 800 events while remaining completely
  failure-free — local backpressure never masqueraded as transport failure
  (the PR #63 invariant holds on-device).
- Zero timeouts across 2,761 requests. Zero late responses. Zero partial /
  failed / helper-failure deliveries (persisted in evidence JSON).

## Root-cause statement

- **QUEUE-ADMISSION ROOT CAUSE: CONFIRMED** — by PR #63's code-path analysis,
  regression tests, and this run: 800 locally shed events produced no
  transport failure and no force-return signal.
- **WIRELESS RESIDUAL TIMEOUT CAUSE: NOT REPRODUCED / INCONCLUSIVE.** Genuine
  timeouts observed 3× during manual physical validation did not reproduce
  under unattended stress (0 across the rev-2/3/4 runs and the final `6a48ab7` run). If one recurs in the
  field, it is now auto-classified: the production app logs
  timeout/stream-closed/write-failed/malformed/helper-failure reasons to
  diag.log, and a bounded grace window captures late responses after any
  timeout.
- **0.75 s TIMEOUT CHANGE: NOT JUSTIFIED BY CURRENT DATA** (Case A). Highest
  observed p99 = 127.4 ms (burst-idle); highest observed max = 127.4 ms
  (burst-idle). The 750 ms budget remains ~5.9× above both. Unchanged per
  ADR-0011 §8.

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
