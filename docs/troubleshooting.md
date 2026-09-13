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
| Input delivered to the phone screen instead of DeX | This is the known category B failure observed in upstream projects (deskflow-android etc.) — see `docs/research/upstream-inventory.md`. Our Phase 0 verification was category A (delivered to the DeX display); if it regresses, start with the routing check in `docs/roadmap.md` Phase 0 |

## macOS native cursor presentation

On affected macOS configurations, the native directional/resize cursor can remain
visually rendered as the normal arrow after Mac ↔ DeX handoff even though pointer
movement, AppKit tracking, and cursor-region callbacks continue normally.

This is a **known macOS cursor-presentation limitation**, tracked in issue #96.
CrossInput keeps the current host-confinement architecture because repeated
edge-hold cursor repositioning is required to keep the Mac pointer confined while
raw relative movement is forwarded to DeX. A standalone AppKit/Quartz reproducer
confirmed that repeated edge-hold `CGWarpMouseCursorPosition()` calls are
sufficient to produce the presentation failure. The exact AppKit/WindowServer
root cause remains unverified.

Do not treat the visual arrow as loss of pointer capture by itself. If DeX input,
host confinement, and local return otherwise work, the failure is presentation-
only.

### Known recovery behavior

Recovery is display- and app/window-local. The following behaviors were verified
from known BROKEN states on the current P0 architecture:

- keyboard-only switching to an application with a window on the affected display
  can restore the native cursor presentation;
- TextEdit on the affected display was independently verified as a working
  recovery target;
- real activation/click of an application window on the affected display can
  restore presentation;
- clicking the affected display's menu-bar region can restore presentation.

The following are **not** reliable recovery actions:

- pressing Shift or other generic keyboard activity;
- Cmd-Tab to an application on another display;
- merely hovering the affected display's menu bar;
- arbitrary cursor-rect invalidation, redraw, or tracking-area rebuild in an
  unrelated diagnostic window.

Do not summarize this as “Cmd-Tab always fixes it.” The narrowest verified
workaround is to bring an application with a window on the **affected display**
frontmost; the exact recovery-producing macOS transition is still unknown.

CrossInput intentionally does **not** ship the investigated alternatives that
hide the macOS cursor, replace it with a custom cursor, use private SkyLight/CGS
cursor ownership as a production dependency, synthesize clicks/focus changes, or
allow the Mac pointer to move with remote DeX movement. Those approaches either
break required interaction invariants or remove the native-cursor oracle rather
than fixing the presentation state.

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
