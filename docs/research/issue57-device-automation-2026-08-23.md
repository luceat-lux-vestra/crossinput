# Issue #57 physical-device verification automation — first run record

Date: 2026-08-23 · Device: SM-G977N (Android 12 / API 31, wireless ADB) · DeX:
active as Samsung's **virtual Desktop display** (id 2,
`virtual:android,1000,Desktop,0`, 1920x1080) while the HDMI sink reports OFF
(DeX-for-PC style session). Target revision: PR #59 HEAD `2efdffa79960dd3d8e4c1e65b63e947784cfcd50`.

Tooling delivered under issue #60: `scripts/verify-device-issue57.sh`
(one-shot SSH driver), `scripts/check-log-guard.sh` (CI false-green fix), and
the test-only `--fail-uhid-report=N` hook. Evidence:
[`evidence/issue-57-device-verification/20260823T150545Z-2efdffa/`](evidence/issue-57-device-verification/20260823T150545Z-2efdffa/).

## Automated result summary (overall: FAIL)

| Check | Result |
|---|---|
| auto_uhid_selection (`backend=uhid routing=system`) | **FAIL** |
| first_move_after_select | PASS |
| uhid_device_registration | PASS |
| pointer_result_smoke | PASS |
| forced_uhid | PASS |
| forced_input_manager | **FAIL** |
| four_direction_protocol_semantics (kernel signs) | PASS |
| clean_shutdown | PASS |
| visible_pointer_motion / idle reappearance / visual scroll / edge handoff | MANUAL_REQUIRED |

## Finding 1 — AUTO routing heuristic misses Samsung's virtual Desktop display

`SystemRoutePolicy.isDesktopSink` gates on hidden `DisplayInfo.flags & FLAG_DESKTOP (0x40)`.
On this rig the DeX display exposes `type=5 (VIRTUAL)` and
`flags=0x20000002` (FLAG_SECURE | FLAG_OWN_CONTENT_ONLY-family bits; dumpsys
shows `FLAG_DESKTOP_DISPLAY`, a Samsung-specific flag) — no `0x40` bit — so
AUTO selects InputManager:

```
[PointerDispatcher] pointer backend selected backend=input-manager mode=auto
```

Consequence: injected events bypass InputReader; the visible DeX sprite does
not follow — exactly the defect class PR #59 set out to fix, resurfacing on
the DeX-for-PC/virtual-desktop topology. Forced UHID works perfectly on the
same display (all 12 semantic requests delivered; first-move race regression
passes immediately after SELECT_DISPLAY), so the UHID path itself is sound on
this device.

Candidate fix direction (for review in #57): extend the conservative
heuristic with a name/uniqueId match (`name == "Desktop"` or
`uniqueId` containing `,Desktop,`) alongside the flag check, keeping the
fail-closed reflection contract of AGENTS.md rule 9. Not applied to PR #59 by
automation per instructions.

## Finding 2 — InputManager injection rejects right/middle buttons

Forced `input-manager` session: moves, left-click down/up, and all four
scrolls deliver (`POINTER_RESULT status=0`); right-click and middle-click
down/up consistently fail with `injectInputEvent returned false` (4×4 across
runs). Device/build-specific rejection by Samsung's input pipeline. Tracked
as part of the Phase-2 item 5b pending work; not a regression introduced by
PR #59 (same behavior expected on origin/main).

## Verified-good signals

- CXI v1 wire interop end-to-end (HELLO_ACK → DISPLAY_LIST → DISPLAY_CHANGED
  → POINTER_RESULT), incl. immediate first-move after SELECT_DISPLAY.
- Kernel-level four-direction scroll contract on the UHID path via bounded
  single-node `getevent`: REL_WHEEL ±1 and REL_HWHEEL ∓/±1 signs match the
  CXI mapping (+v up, −v down, +h left, −h right).
- `Ampersand Mouse` visible in `dumpsys input`; graceful SHUTDOWN ×3.
- Mid-session failover item correctly recorded NOT_RUN: the deterministic
  `--fail-uhid-report` hook post-dates this revision (unit-tested only).

## Manual items outstanding for PR #59 acceptance

Visible pointer motion/appearance, idle-fade reappearance, visual scroll
direction, and the full macOS→Android→macOS handoff require human
confirmation on the physical DeX screen. A scrcpy recording of display 2 was
captured during the run (kept out of git; see `screen-recording.manifest.txt`)
to assist that review.
