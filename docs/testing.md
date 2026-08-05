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

## Phase 2: CXI helper verification (issue #6)

Drives the Android helper over the binary CXI protocol using
`scripts/deploy-helper.sh`. Prereqs: DeX active (same setup as Phase 0),
APK buildable (`scripts/build-android-helper.sh assembleDebug`).

1. Pre-check display state: `adb shell dumpsys display` — the Desktop display must be present (do not assume any display id; AGENTS.md rule 3).
2. `scripts/deploy-helper.sh start` — build + push + launch `app_process` with FIFO stdin.
3. `scripts/deploy-helper.sh hello` — expect HELLO_ACK (type 0x8001) in `dump` output.
4. `scripts/deploy-helper.sh list` — expect DISPLAY_LIST (0x8002) containing the Desktop display.
5. `scripts/deploy-helper.sh select <desktop-id>` — expect DISPLAY_CHANGED (0x8003) echo for that display.
6. `scripts/deploy-helper.sh send <frame-hex>` with the create-hid fixture frame (`xxd -p protocol/fixtures/create-hid.bin | tr -d '\n'`) — expect HID_CREATED (0x8004).
7. `scripts/deploy-helper.sh send <frame-hex>` with the hid-report fixture frame (same command on `protocol/fixtures/hid-report.bin`) — pointer must appear/move on the DeX screen.
8. `scripts/deploy-helper.sh dump` — inspect captured frames + helper stderr log (metadata only; hard rule 4).
9. `scripts/deploy-helper.sh stop` — SHUTDOWN frame; helper must destroy UHID devices and exit cleanly (B-07).

Keyboard (Phase 9, ADR-0007 — added to the same helper session):

10. `scripts/deploy-helper.sh start` — helper log shows `Ampersand Keyboard` UHID device created; `adb shell "dumpsys input | grep -A2 'Ampersand Keyboard'"` shows `KEYBOARD | ALPHAKEY | EXTERNAL` classes.
11. Send one key down/up pair using the dedicated fixtures, then verify as follows (character input is only asserted after the full down/up pair):
    ```sh
    DOWN_HEX="$(xxd -p protocol/fixtures/key-event-down.bin | tr -d '\n')"
    UP_HEX="$(xxd -p protocol/fixtures/key-event-up.bin | tr -d '\n')"

    scripts/deploy-helper.sh send "$DOWN_HEX"
    scripts/deploy-helper.sh send "$UP_HEX"
    ```
    - Step 1 (`key-event-down.bin`, action 0): reports the key as pressed.
    - Step 2 (`key-event-up.bin`, action 1): reports the key as released.
    - After the complete down/up sequence, confirm that exactly one character was entered in the focused DeX field.
    - Confirm that no repeated input continues after the key-up report.
    - Run `scripts/deploy-helper.sh stop` and confirm that no stuck-key state remains after shutdown.
12. macOS app while captured: Cmd+Tab / Spotlight must NOT fire on the Mac (system-shortcut suppression); typing reaches the Android IME and Korean 2-set composes.

Canonical frame bytes live in `protocol/fixtures/*.bin`; `protocol/scripts/check-fixtures.mjs` keeps them in sync with `protocol/protocol.md`.

### Virtual-injection fallback verification (Status: Pending on-device)

The InputManager virtual-injection fallback is implemented but has **not yet
been exercised on a physical device** (issue #33). When a test-only backend
override exists, run this procedure (until then, the override itself is tracked
in issue #33):

1. Force the fallback backend via the test-only override; helper log must show the fallback engaged.
2. Select a focused text field on the DeX display.
3. Send a single key down/up pair — exactly one character must appear (no repeat, no stuck key).
4. Repeat with a modifier combination (e.g. Shift+letter).
5. Confirm no repeated input after release, and that shutdown leaves no stuck key state.
6. Attach logcat/screen evidence; confirm the logs contain metadata only (no key codes or payloads; hard rule 4).

A forced-selection switch does not exist yet — a test-only override has been
filed as part of issue #33; do not invent ad-hoc commands for this.

### Verification items (Phase 2)

Status per item — ✅ verified on device (SM-G977N, 2026-08) · ⏳ not yet verified. Full results in issue [#6](https://github.com/luceat-lux-vestra/crossinput/issues/6); keyboard work in issue [#21](https://github.com/luceat-lux-vestra/crossinput/issues/21); InputManager fallback remains pending (issue [#33](https://github.com/luceat-lux-vestra/crossinput/issues/33)).

| # | Item | Pass criteria | Status |
|---|---|---|---|
| 1 | HELLO/HELLO_ACK | HELLO_ACK with matching requestId within 2s | ✅ |
| 2 | LIST_DISPLAYS/DISPLAY_LIST | All displays reported, Desktop display present with correct size/density | ✅ |
| 3 | SELECT_DISPLAY | Unknown id → FATAL_ERROR; known id → DISPLAY_CHANGED echo | ✅ |
| 4 | CREATE_HID_DEVICE | HID_CREATED with device id; `/dev/uhid` created (log metadata) | ✅ |
| 5 | HID_REPORT (pointer, UHID) | Pointer visible + moves on DeX external display | ✅ |
| 5b | InputManager pointer fallback (SdkPointerBackend) | Implemented; UHID pointer path verified on device above. Pointer fallback on-device verification is tracked separately and is pending — no verification claim for the fallback path | ⏳ pending (no on-device record; UHID path verified only) |
| 6 | UHID keyboard | `Ampersand Keyboard` registered as `KEYBOARD | ALPHAKEY | EXTERNAL`; single key-down/up yields exactly one character | ✅ |
| 7 | macOS shortcut suppression | Cmd+Tab / Spotlight do not fire on the Mac while captured | ✅ |
| 8 | Korean 2-set | Hangul composes in a DeX field via Android IME | ✅ |
| 9 | SHUTDOWN | Clean exit; UHID devices destroyed; stdout flushed | ✅ |
| 10 | InputManager virtual-injection fallback | Fallback engaged (forced), single char + modifier, no repeat, no stuck keys, shutdown clean | ⏳ pending (issue #33) |

## Edge switching stability (Phase 5)
- Not declared complete until 100 consecutive edge-switch repeat tests pass.
- For each failure case, verify state machine logs + recovery path.
