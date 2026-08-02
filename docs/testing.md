# Ampersand Testing Guide

> On-device verification protocol. Linked to AGENTS.md hard rule 2 (no verification claim without on-device logs).

## General principles

- Emulator/local test passing ≠ verification complete.
- Claims of "it works" must attach one of:
  1. On-device `dumpsys display` log
  2. ADB `logcat` excerpt (no payloads/content — hard rule 4)
  3. Video/screen capture
  4. A list of commands that reproduce the verification procedure

## Verification environment (current)

| Item | Value |
|---|---|
| Device | Galaxy S10 5G (SM-G977N, beyondxks) |
| Android | 12, API 31 |
| ADB | 37.0.1, wireless debugging (mDNS TLS) |
| DeX | wired HDMI external display 1920x1080 |

## DeX input routing verification protocol

1. Pre-check: `adb shell dumpsys display` — DeX active (Desktop display ON, phone display DOZE)
2. After input injection, confirm pointer events via `adb shell getevent -lt` / `logcat`
3. Visual check: whether the pointer appears on the DeX screen (external monitor) and whether input reaches the phone screen
4. Repeat each verification item 10+ times

### Verification items (R1)

Status: ✅ verified on device (SM-G977N) · ⏳ not yet verified. Full results in [issue #2](https://github.com/luceat-lux-vestra/crossinput/issues/2).

| # | Item | Pass criteria | Status |
|---|---|---|---|
| 1 | Relative mouse | Pointer shown on DeX screen, moves across full resolution | ✅ (movement 1:1, pointer acceleration as on a real mouse) |
| 2 | Absolute mouse | Coordinate-pointer position match | ⏳ |
| 3 | Absolute stylus | hover movement | ⏳ |
| 4 | Composite mouse (wheel) | left/right click, drag, vertical/horizontal scroll | ⏳ (click and focus change verified; drag/scroll pending) |
| 5 | Input persists after app switch | delivered to DeX screen even after focus changes | ✅ (click delivered after focus change, displayId verified) |

## Edge switching stability (Phase 5)

- Not declared complete until 100 consecutive edge-switch repeat tests pass.
- For each failure case, verify state machine logs + recovery path.
