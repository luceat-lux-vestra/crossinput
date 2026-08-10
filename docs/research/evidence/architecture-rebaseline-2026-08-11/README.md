# Architecture Rebaseline Device Smoke

Date: 2026-08-11

Device: SM-G977N, Android 12, API 31. The run used an explicit connected ADB
serial. Display IDs were discovered from `dumpsys display` and the helper's
`LIST_DISPLAYS`; no display ID was assumed in the implementation.

Commands:

```text
POINTER_BACKEND=auto ./scripts/deploy-helper.sh start
./scripts/deploy-helper.sh list
./scripts/deploy-helper.sh pointer <discovered-display-id>
./scripts/deploy-helper.sh dump
./scripts/deploy-helper.sh stop

POINTER_BACKEND=input-manager KEYBOARD_BACKEND=input-manager \
  ./scripts/deploy-helper.sh start
./scripts/deploy-helper.sh pointer <same-discovered-display-id>
./scripts/deploy-helper.sh dump
./scripts/deploy-helper.sh stop
```

Result: debug helper build/push succeeded. The helper reported two display
records; the selected external target was the ID returned by discovery. In the
automatic run, UHID keyboard and pointer backends were selected, the semantic
move/button/scroll sequence returned `POINTER_RESULT` frames with delivered
status, and SHUTDOWN destroyed both UHID devices. In the forced run, the
InputManager keyboard and pointer backends were selected, the same semantic
pointer sequence returned delivered `POINTER_RESULT` frames, and SHUTDOWN
completed cleanly.

Metadata-only stderr excerpt:

```text
[Main] keyboard backend mode=auto
[Main] pointer backend mode=auto
[HidDeviceManager] device created id=1 name=Ampersand Keyboard inputDeviceId=11
[UhidKeyboardInjector] UHID keyboard created id=1
[KeyboardBackend] keyboard backend selected backend=uhid mode=auto
[UhidPointerInjector] pointer backend ready backend=uhid
[PointerDispatcher] pointer backend selected backend=uhid mode=auto
[Main] listing 2 display(s)
[Main] selected target display id=<discovered-id>
[Main] shutdown requested
[Main] stdin closed; shutting down
[HidDeviceManager] device destroyed id=2
[Main] pointer backend mode=input-manager
[InputManagerPointerInjector] selected target <discovered-id> (1920x1080)
[PointerDispatcher] pointer backend selected backend=input-manager mode=input-manager
[Main] shutdown requested
[Main] stdin closed; shutting down
```

This first record is helper-level evidence for semantic pointer delivery and
backend selection. The follow-up below adds the real macOS event-tap run; it
does not replace the required screen confirmation.

## Automated handoff-model repetition

The control-handoff state machine was exercised independently of the macOS
event tap with all four edges rotated across 100 complete cycles:

```text
cd apps/macos
swift test --disable-sandbox --filter EdgeSwitchStateMachineTests
-> pass: 13 tests, including testOneHundredEdgeHandoffCyclesStaySafe
```

Each cycle entered `remoteActive`, ignored the first post-capture movement,
crossed the return boundary and hysteresis, reached `localActive`, and then
deactivated cleanly. This remains automated state-machine evidence only.

## Real macOS event-tap and device repetition

Follow-up run: 2026-08-11. The host pre-check reported
`CGMainDisplayID=1`, five macOS screens, Accessibility trusted, Screen Capture
preflight allowed, and a listen-only CGEvent tap that could be created. The
helper was connected to SM-G977N / Android 12 / API 31 over an explicit ADB
serial. Its `LIST_DISPLAYS` response selected the discovered external target
and the app logged `selected target display id=6` for this run; the ID was not
assumed by the implementation.

One real app handoff completed with this metadata-only sequence:

```text
localActive -> edgeArmed -> remoteActive
cursor hidden (balanced)
Ampersand Mouse UHID report delivered on the device
remoteActive -> returning reason=boundaryCrossed
cursor shown (balanced)
returning -> localActive reason=boundaryCrossed
```

The same packaged macOS app/event-tap path then completed 100 consecutive
left-edge handoffs against the real helper. The extracted diagnostic segment
reported:

The original PR evidence is preserved at [PR #42 device verification comment](https://github.com/luceat-lux-vestra/crossinput/pull/42#issuecomment-5246363534).

| Event | Count |
|---|---:|
| `localActive -> edgeArmed` | 100 |
| `edgeArmed -> remoteActive` | 100 |
| `remoteActive -> returning reason=boundaryCrossed` | 100 |
| `returning -> localActive reason=boundaryCrossed` | 100 |
| `cursor hidden (balanced)` | 100 |
| `cursor shown (balanced)` | 100 |
| watchdog/remote-unavailable/emergency returns | 0 |

After the run, the macOS app and helper exited and no `Ampersand` input device
remained in the device input dump. This is real event-tap and device-routing
evidence, but it is not screen confirmation: `adb exec-out screencap -d 6 -p`
returned an empty file for the secure target display. Therefore pointer
visibility on the target screen remains unverified, and issue #41 / PR #42
must remain open and blocked until the screen-confirmed matrix is captured.
