# InputManager Held-Key Shutdown Evidence

Date: 2026-08-10

Device: Samsung Galaxy S10 5G (SM-G977N), Android 12 / API 31

Code under test: `1a9f5c8`

Pull request: [#40](https://github.com/luceat-lux-vestra/crossinput/pull/40)
CI: [run #77](https://github.com/luceat-lux-vestra/crossinput/actions/runs/31396421980)

This evidence covers the held-key acceptance case. The helper was started in
forced `input-manager` mode, the canonical key-down fixture was sent without a
key-up fixture, and SHUTDOWN was sent afterward.

## Evidence files

- [backend-selection.log](backend-selection.log): ADB-pulled startup log showing
  forced fallback selection and display/protocol metadata.
- [normal.png](normal.png): one-character result from the normal key down/up
  run.
- [modifier.png](modifier.png) and
  [modifier-after-wait.png](modifier-after-wait.png): modifier result and
  delayed no-repeat capture.
- [normal-stop.log](normal-stop.log): ADB-pulled normal-run shutdown log.
- [ready.png](ready.png): focused DeX search field before the held-key run.
- [before-stop.png](before-stop.png): one character visible after DOWN only,
  before SHUTDOWN.
- [after-stop.png](after-stop.png): same field after SHUTDOWN and delayed
  capture; no additional repeat is visible.
- [helper-stop.log](helper-stop.log): helper stderr log pulled from the device
  after graceful shutdown. It contains metadata only.

## Observed result

- `scripts/deploy-helper.sh stop` returned success after the actual helper
  `app_process` exited within the five-second bounded wait.
- Orphan cleanup was invoked only after the graceful-exit success decision.
- A post-stop process check found no helper or stdin-feeder process.
- The captured log contains no key codes, meta states, clipboard contents, or
  input/HID payloads.

## Reproduction

```sh
KEYBOARD_BACKEND=input-manager scripts/deploy-helper.sh start
scripts/deploy-helper.sh send "$(xxd -p protocol/fixtures/key-event-down.bin | tr -d '\n')"
STOP_TIMEOUT_SECONDS=5 scripts/deploy-helper.sh stop
```

The key-up fixture is intentionally omitted in this case.
