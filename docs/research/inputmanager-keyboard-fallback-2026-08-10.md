# InputManager Keyboard Fallback Verification

Date: 2026-08-10
Device: Samsung Galaxy S10 5G (SM-G977N), Android 12 / API 31
Issue: #33
Pull request: #40

## Scope

Verify the Android helper's test-only forced `input-manager` backend on a
physical DeX session. The run must prove backend selection, key down/up
delivery, modifier delivery, no repeated input after release, metadata-only
logging, and deterministic clean shutdown, including synthetic release of a
held key when SHUTDOWN arrives without a key-up message.

## Procedure

1. Build and deploy the current Android helper with `KEYBOARD_BACKEND=input-manager`.
2. Confirm the helper log contains:
   `keyboard backend selected backend=input-manager mode=forced`.
3. Open a focused search field on the DeX display.
4. Send the canonical key down/up fixture pair.
5. Send a key down/up pair with a modifier state.
6. Capture the DeX display immediately and after a delay, then shut down the helper.
7. Start a fresh helper, send only the canonical key-down fixture, and send
   SHUTDOWN without sending the key-up fixture.
8. Confirm the helper's actual `app_process` exits within the bounded stop
   timeout before any orphan cleanup is attempted.

## Result

- The forced backend marker was present at startup; no UHID keyboard device was
  created for the forced fallback run.
- The canonical key down/up pair produced exactly one character in the focused
  DeX search field.
- The modifier pair produced exactly one additional character.
- A delayed screen capture showed no additional repeated input after release.
- In the held-key run, the down-only fixture produced one character before
  shutdown; after SHUTDOWN, the field remained unchanged during a delayed
  capture, demonstrating that the cleanup-generated key-up did not leave a
  stuck or repeating key.
- `scripts/deploy-helper.sh stop` reported `graceful shutdown complete` and
  returned success after the actual helper `app_process` exited. Orphan
  cleanup ran only after that success decision; no helper or stdin-feeder
  process remained afterward.
- The captured helper log contained backend, display, and protocol metadata
  only; it contained no key codes, meta states, clipboard contents, or HID
  report payloads.
- InputManager API-unavailable, rejected-injection, and `SecurityException`
  fail-safe behavior passed in the Android unit tests in the same build. These
  failure branches were not artificially triggered on the physical device.

## Reproduction commands

```sh
KEYBOARD_BACKEND=input-manager scripts/deploy-helper.sh start
scripts/deploy-helper.sh hello
scripts/deploy-helper.sh list
scripts/deploy-helper.sh send "$(xxd -p protocol/fixtures/key-event-down.bin | tr -d '\n')"
scripts/deploy-helper.sh send "$(xxd -p protocol/fixtures/key-event-up.bin | tr -d '\n')"
scripts/deploy-helper.sh ping
STOP_TIMEOUT_SECONDS=5 scripts/deploy-helper.sh stop

# Held-key shutdown: send DOWN, deliberately omit UP, then stop.
KEYBOARD_BACKEND=input-manager scripts/deploy-helper.sh start
scripts/deploy-helper.sh send "$(xxd -p protocol/fixtures/key-event-down.bin | tr -d '\n')"
STOP_TIMEOUT_SECONDS=5 scripts/deploy-helper.sh stop
```

The run also used `adb shell dumpsys display` to confirm the active DeX
environment and ADB screen captures of the external display for visual
confirmation. No display ID is hardcoded by the helper.
