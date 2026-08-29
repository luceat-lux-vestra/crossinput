# Pull-back from display-bound-pinned cursor — on-device verification (issue #45, PR #56)

Date: 2026-08-23 · Device: SM-G977N (beyondxks), Android 12 · DeX Desktop display id=2 (1920x1080) selected
Build: `main` @ e268dc5 deployed to /Applications/Ampersand.app (new-build marker `boundaryClamped` present in binary)

## Defect under test

When the Android cursor rested against a display bound in the pull-back
direction, the helper's InputManager clamp absorbed all return-direction
movement and acknowledged delivery with zero accepted delta. The Mac side
credited only accepted deltas, so the edge-switch virtual position never
moved toward macOS while every acknowledgement poked the watchdog: a
permanent trap (generation-6 signature). PR #56 credits return-direction
movement by full requested intent.

## Procedure

For each cycle (10 cycles, operator-driven):

1. Push the pointer across the configured handoff edge → `remoteActive`.
2. Drag the Android pointer fully against the DeX screen bound on the
   pull-back side until it cannot move further (pinned).
3. Sustain return-direction input without releasing (no ⇧⌘X, no waiting for
   the watchdog).
4. Observe return of macOS control.

## Result

- Operator screen confirmation: 10/10 cycles returned to macOS control with
  the Android cursor pinned; no cycle required the emergency shortcut or
  watchdog.
- Log evidence (`diag-excerpt.log`, session window 11:07:29–11:09:19 local,
  state sequences 10–133):
  - 31 handoff entries / 31 returns — no entry ever failed to return.
  - 20 returns with reason=`boundaryCrossed` (≥ 10 required).
  - 0 `watchdogTimeout`, 0 fatal errors.
  - Remaining returns are `emergencyReturn` (8) and `suppressionReleased`
    (3) from explicit operator safety presses during exploratory attempts,
    not from fail-safe timeouts.

## Evidence quality note

The per-move `boundaryClamped=true` marker exists in
`EdgeSwitchStateMachine.pointerMoved(requestedDx:requestedDy:deliveredDx:deliveredDy:)`
but is emitted only when state-machine diagnostics are enabled
(`isDiagnosticsEnabled`); the app constructs the machine with diagnostics
disabled, so this record relies on transition-level logs plus operator
screen confirmation — the same evidence quality used to diagnose the
generation-6 trap. A follow-up may env-gate that diagnostic for richer
future records (tracked under umbrella #52).

## Reproduction commands

```sh
adb devices -l                                  # SM-G977N connected (mDNS TLS)
adb shell dumpsys display                       # Desktop display ON, phone doze
open /Applications/Ampersand.app                # menu bar → Connect
# maneuver per cycle above; then:
tail -n +7163 ~/Library/Logs/Ampersand/diag.log > diag-excerpt.log
grep -c 'reason=boundaryCrossed' diag-excerpt.log
```
