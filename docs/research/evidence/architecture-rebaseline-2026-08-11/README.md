# Architecture Rebaseline Device Smoke

Date: 2026-08-11

Device: SM-G977N, Android 12, API 31. The run used an explicit connected ADB
serial. No pointer-driving, keyboard-content, or screen-interaction command
was sent; this is a helper lifecycle and CXI session smoke only.

Commands:

```text
./scripts/deploy-helper.sh start
./scripts/deploy-helper.sh hello
./scripts/deploy-helper.sh list
./scripts/deploy-helper.sh dump
./scripts/deploy-helper.sh stop
```

Result: debug helper build/push succeeded; HELLO/LIST_DISPLAYS completed; the
helper reported two display records; SHUTDOWN completed after the helper
process exited; the UHID keyboard was created and destroyed cleanly.

Metadata-only stderr excerpt:

```text
[Main] keyboard backend mode=auto
[HidDeviceManager] device created id=1 name=Ampersand Keyboard inputDeviceId=11
[UhidKeyboardInjector] UHID keyboard created id=1
[KeyboardBackend] keyboard backend selected backend=uhid mode=auto
[DisplayDiscovery] display changed id=0
[Main] handshake ok (v1)
[Main] listing 2 display(s)
[Main] shutdown requested
[Main] stdin closed; shutting down
[HidDeviceManager] device destroyed id=1
```

This record is not evidence of pointer routing, keyboard text delivery,
target selection, screen behavior, or edge-switch stability. Those checks
remain governed by [`docs/testing.md`](../../../testing.md).
