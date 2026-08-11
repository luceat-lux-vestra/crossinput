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

Result: debug helper build/push succeeded. This section preserves the earlier
helper smoke record; the target-routing follow-up below supersedes its pointer
backend selection policy. The current selected-target path does not report
system-routed UHID as target-specific delivery.

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

## Target-routing follow-up

Follow-up run: 2026-08-11, after the c22d04c hardening changes. The device was
SM-G977N / Android 12 / API 31 on the explicit ADB serial
`192.168.0.224:40577`. Display IDs were discovered from `dumpsys display`:

| Target | Discovered ID | Source metadata |
|---|---:|---|
| Phone | 0 | `Built-in Screen` |
| DeX | 2 | `Desktop`, `virtual:android,1000,Desktop,0` |
| External HDMI | 6 | `HDMI Screen` |

After the DisplayDiscovery fix, `LIST_DISPLAYS` returned all three records.
The macOS smoke tool selected the DeX record by its normalized Desktop marker:

```text
HELLO handshake OK
displays: 3
id=2 ... name='Desktop' ... desktop=true
SELECT_DISPLAY(2) -> Desktop
PING -> pong
SMOKE OK
```

The helper's `auto` and forced `input-manager` runs selected the target display
with explicit display routing and returned delivered `POINTER_RESULT` frames
for relative move, left button down/up, and scroll on both DeX and phone
targets. Metadata-only helper logs included:

```text
[Main] handshake ok (v1 capabilities=3)
[Main] listing 3 display(s)
[InputManagerPointerInjector] selected target 2 (1920x1080)
[PointerDispatcher] pointer backend selected backend=input-manager mode=auto
[InputManagerPointerInjector] selected target 0 (1440x3040)
[PointerDispatcher] pointer backend selected backend=input-manager mode=input-manager
```

In the final forced-InputManager run, a metadata-only frame summary counted 8
`POINTER_RESULT` responses across the DeX and phone move/button/scroll
sequences, all with status `DELIVERED` (`status=0`). Shutdown then completed
gracefully and the helper process was gone.

Forcing `POINTER_BACKEND=uhid` while selecting the discovered DeX target was
rejected immediately with `UHID cannot guarantee explicit target routing in
forced mode`; no false `DISPLAY_CHANGED` success was emitted.

The current phone screenshot was black because the built-in display reported
an off/locked state. A reduced DeX screenshot was successfully captured, but
the pointer sprite was not visible in screencap output. Direct physical
pointer visibility and click/scroll effect on the external DeX screen remain
`not verified` by pixel evidence. The original real app 100-cycle record is
preserved below and at the linked PR comment.

## Final correctness hardening after `a14bac8`

The final follow-up adds two correctness guards without changing the
architecture boundary:

- `SessionReference` now advances a monotonic generation whenever a session is
  installed or cleared. `InputSender` captures that generation when pointer or
  keyboard work is queued, rejects work from an older generation, and treats a
  late pointer result as cancelled so it cannot advance handoff accounting.
- `PointerDispatcher.supportsExplicitDisplayRouting` is mode-aware. Forced UHID
  no longer advertises the InputManager capability; forced InputManager and
  AUTO advertise explicit routing only when the selected backend can provide
  it.

The new macOS session-isolation tests and Android dispatcher capability tests
pass in the corresponding hosted build. This section does not convert the
following device items into a pass: current-path screen confirmation on DeX or
phone, a fresh current-path 100-cycle run, fresh keyboard observation, or
helper/ADB failure recovery. Those remain `NOT VERIFIED` unless a person
observes the physical screens and recovery behavior and records the result.

## Final verification matrix for `488ded3`

Recorded: 2026-08-11. The final PR HEAD is
`488ded331a4f97089d9cd82223276fa79b21b156`.

| Check | Result | Evidence boundary |
|---|---|---|
| Final-head hosted CI | PASS | macOS, Android, documentation, and shell jobs all passed for `488ded3` in [CI run 31454181120](https://github.com/luceat-lux-vestra/crossinput/actions/runs/31454181120) |
| Local macOS tests | PASS | 50 XCTest cases and 30 Swift Testing cases passed; release binary also built with `swift build -c release --disable-sandbox` |
| Protocol fixtures and shell/diff gates | PASS | 15 fixtures verified; all shell scripts passed `bash -n`; `git diff --check` passed |
| Helper target/routing smoke | PASS | Installed helper listed phone `0`, Desktop/DeX `2`, and HDMI `6`; AUTO selected InputManager and returned eight delivered pointer results across DeX/phone move, button, and scroll sequences |
| DeX actual pointer screen | NOT VERIFIED | DeX screencap showed the desktop but no pointer sprite; no direct external-monitor observation was available |
| Phone actual pointer screen | NOT VERIFIED | Phone capture was black/off; no direct phone-screen observation was available |
| Current InputManager 100-cycle edge run | NOT VERIFIED | The automated handoff model passed 100 cycles and the historical UHID event-tap run remains preserved, but a fresh current-path physical 100-cycle run was not observed |
| Fresh keyboard regression | NOT VERIFIED | Existing keyboard evidence is preserved; fresh physical key, Korean composition, and shortcut-suppression observation was not performed |
| Helper kill / ADB loss / emergency return | NOT VERIFIED | Safety unit tests passed, but final-head physical recovery was not directly observed |

The helper smoke used the APK already present on the connected device, while the
final-head Android source was built and tested by hosted CI. Therefore the
helper-level routing result is not presented as final-head packaged-app screen
evidence. No item marked `NOT VERIFIED` is treated as a merge acceptance.

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
