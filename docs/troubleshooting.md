# Ampersand Troubleshooting

Issues found during development and verification, with causes and fixes. Work in progress — add entries as new issues surface.

## ADB

| Symptom | Cause/Fix |
|---|---|
| Device missing in `adb devices` | Wireless debugging pairing needs renewal. Settings → Developer options → Wireless debugging → pair again |
| Transport connection dropped | Wi-Fi change or power saving. Try `adb reconnect` |
| `no devices/emulators found` | Check the adb server (port 5037) is running: `adb start-server` |
| Wireless debugging stops after reboot | Pairing is revoked on some devices after reboot; re-pair once and the Mac app should remember the connection |

## DeX

| Symptom | Cause/Fix |
|---|---|
| DeX screen doesn't turn on | Check HDMI cable/adapter; Settings → Samsung DeX |
| Cursor invisible on the DeX screen | Samsung fades the cursor after ~3.5s idle — normal DeX behavior; move the pointer to bring it back |
| Input delivered to the phone screen instead of DeX | This is the known category B failure observed in upstream projects (deskflow-android etc.) — see `docs/research/upstream-inventory.md`. Historical Phase 0 evidence was category A (delivered to the DeX display); if it regresses, use the maintained **DeX input routing verification protocol** in `docs/testing.md`. |

## macOS native cursor presentation

The current #96 product symptom is a **remote-active presentation failure**:

- after Mac -> DeX ownership becomes ready, the Mac-side host cursor remains at
  the configured handoff edge;
- left/right ownership must present the native horizontal directional cursor;
- top/bottom ownership must present the native vertical directional cursor;
- an ordinary arrow during real remote ownership is #96 **BROKEN**.

This is not a post-return hover test. Normal local AppKit cursor behavior after
return is a separate regression check.

Production now gives this state an explicit owner. The directional cursor is
published only after the CoreHID lease and matching keyboard admission are
ready, and it is withdrawn at every synchronous local-return/failure gate before
CoreHID ownership is released. It uses only native `NSCursor.resizeLeftRight`
/ `.resizeUpDown`; it does not hide the cursor, warp the pointer, synthesize a
click/focus transition, or install a custom cursor.

### Historical cursor-corruption evidence

The older #96 standalone reproducer remains valid negative evidence. It showed
that repeated edge-hold `CGWarpMouseCursorPosition()` is sufficient to leave
native AppKit directional/resize cursor regions rendered as the ordinary arrow.
Previously investigated hide/show, association, synthetic move/click/focus,
private CGS/SkyLight, and equivalent reset stacks remain rejected.

Those historical recovery observations are diagnostic evidence only; they do
not define the current product contract and must not be used as a normal
recovery procedure.

## Keyboard

| Symptom | Cause/Fix |
|---|---|
| "Change keyboard settings / set the language and layout" popup when Ampersand first connects | Android guides users when a new physical keyboard (the UHID device) registers — a harmless one-time system prompt; dismiss it. It may reappear whenever the helper restarts (the UHID `inputDeviceId` changes) |
| Keys repeat forever (one key press → continuous input) | Was the UHID key-state-reporting bug; fixed in v0.1.0 (report pressed-key sets, not raw key events). If it reappears, confirm the installed helper build is ≥ v0.1.0 |
| Korean (2-set) not composing | Composition happens in the Android IME — make sure a physical-keyboard-aware IME (e.g. Samsung Korean) is active on the phone/DeX |

## External remote-control takeover

When Android owns input, a recognized external-control event requests local
macOS control. CrossInput releases suppression, cleans up captured key/button
state, skips the normal edge-return pointer warp, and passes the triggering
event through to macOS. CrossInput does not explicitly manage host cursor
visibility. RustDesk is the initially verified provider; physical source
characterization and takeover behavior must be confirmed on the target Mac
before treating the provider as verified.

To opt in to metadata-only event-source diagnostics, set the environment before
launching the app:

```sh
launchctl setenv CROSSINPUT_DIAG_EVENT_SOURCE 1
```

The diagnostic records event type, source PID, resolved bundle identifier, and
resolved executable/process identity. It never records key codes, text,
clipboard data, coordinates, or HID/input payloads. Reproduce physical local
input, CrossInput-generated synthetic input, and each external-control input
kind separately, then preserve the resulting metadata log with the physical
verification record. Clear the opt-in variable after characterization:

```sh
launchctl unsetenv CROSSINPUT_DIAG_EVENT_SOURCE
```
