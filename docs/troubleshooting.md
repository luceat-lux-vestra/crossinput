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

## Keyboard

| Symptom | Cause/Fix |
|---|---|
| "Change keyboard settings / set the language and layout" popup when Ampersand first connects | Android guides users when a new physical keyboard (the UHID device) registers — a harmless one-time system prompt; dismiss it. It may reappear whenever the helper restarts (the UHID `inputDeviceId` changes) |
| Keys repeat forever (one key press → continuous input) | Was the UHID key-state-reporting bug; fixed in v0.1.0 (report pressed-key sets, not raw key events). If it reappears, confirm the installed helper build is ≥ v0.1.0 |
| Korean (2-set) not composing | Composition happens in the Android IME — make sure a physical-keyboard-aware IME (e.g. Samsung Korean) is active on the phone/DeX |
