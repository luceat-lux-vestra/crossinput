# Ampersand Troubleshooting

Troubleshooting guide (work in progress — issues found during verification are recorded here)

## ADB

| Symptom | Cause/Fix |
|---|---|
| Device missing in `adb devices` | Wireless debugging pairing needs renewal. Settings → Developer options → Wireless debugging → re-register pairing code |
| Transport connection dropped | Wi-Fi change, power saving. Try `adb reconnect` |
| `no devices/emulators found` (Node client) | Check adb server (5037) is running: `adb start-server` |

## DeX

| Symptom | Cause/Fix |
|---|---|
| DeX screen doesn't turn on | Check HDMI cable/adapter, Settings → Samsung DeX |
| Input delivered to phone screen | Phase 0 category B — display routing issue. See `docs/research/leap-scrcpy-baseline.md` |
