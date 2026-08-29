# Ampersand — CrossInput

**A DeX-first, Android-capable macOS input bridge.**

CrossInput captures pointer and keyboard input on macOS and safely hands control
to a selected Android display at a configured screen edge. Its primary use case
is Samsung DeX: keep a Galaxy device useful as a desktop even when it is no
longer convenient to use as a handheld phone. The built-in phone display and
other discovered displays on the same connected Android device remain
selectable targets.

Push the pointer back to return to macOS. No phone app install or root is
required in the current workflow: after wireless-debugging setup, the Mac runs
the helper through ADB/app_process and communicates over CXI v1. Alternate
local transports and CXI v2 remain future extension points rather than current
implementation commitments.

```text
┌─ macOS app (Swift, menu bar) ─┐   ┌─ Android helper (Kotlin) ─┐
│ pointer + keyboard capture    │   │ display discovery          │
│ semantic input + edge handoff │   │ pointer/keyboard backends  │
└───────────┬────────────────────┘   └────────────┬──────────────┘
            │                                     │
            └──── CXI v1 over ADB/app_process ───►│
                                                  ▼
                                  DeX desktop / Android display
```

## Features

- **Edge switching**: push the pointer past a configured macOS screen edge to hand control to the selected Android target and push back to return.
- **Works with any pointer device**: trackpad, wired or wireless mouse — captured at the macOS level with CGEventTap.
- **Pointer**: movement, left/right/middle click, drag, vertical scroll, and horizontal scroll.
- **Keyboard**: macOS → Android key delivery with modifier/shortcut handling and the implemented Korean input path — [ADR-0007](docs/adr/ADR-0007-keyboard-delivery.md).
- **Samsung DeX first**: DeX is the primary target and product use case.
- **Selectable Android displays**: the built-in phone display and other discovered displays on the same Android device remain selectable.
- **Target-dependent pointer routing**: desktop sink candidates such as DeX prefer system-routed UHID so the visible Android cursor follows the native InputReader path; non-desktop targets use InputManager explicit-display routing.
- **No root / Knox bypass**: the helper runs through the existing ADB/app_process workflow.
- **Fail-safe local recovery**: helper/transport failure, timeout, emergency return, and capture shutdown must restore local macOS control.

## Clipboard roadmap

Clipboard is separate from input direction. Pointer and keyboard remain
macOS → Android, while clipboard/data sharing may be bidirectional.

- Near term: bidirectional UTF-8 text clipboard synchronization (#89).
- Backlog: bidirectional image clipboard synchronization (#90).
- Backlog: file clipboard / file transfer (#91).

Clipboard contents are never logged.

## Scope

CrossInput controls one Android device at a time. Multiple displays on that
device are supported through target selection; simultaneous multi-Android
control is not planned.

Current non-goals include Android → macOS pointer/keyboard input, using Android
as a pointing device for macOS, cloud relay/account infrastructure, root/Knox
bypass, and speculative platform frameworks.

Windows/Linux hosts, alternate local transports, and broader target families
may be evaluated later but are not current commitments.

## Protocol and transport

- **CXI v1** is the production protocol.
- **ADB/app_process** is the current/default transport.
- **CXI v2** remains a future semantic, capability-negotiated, target-normalized, backend-independent, and transport-independent design (#93).
- A future alternate local transport may be added when a concrete need exists; no second transport or transport-plugin framework is currently planned (#94).

## Status

Historical and current device evidence is tracked through the repository's
issues and `docs/research/`. Device-dependent behavior is not considered
verified from local tests alone; see [docs/testing.md](docs/testing.md) and
[AGENTS.md](AGENTS.md).

Released as `Ampersand-0.1.0.dmg` (ad-hoc signed, [ADR-0008](docs/adr/ADR-0008-v0.1.0-release-packaging.md)) — see the [latest release](https://github.com/luceat-lux-vestra/crossinput/releases) and [CHANGELOG.md](CHANGELOG.md).

Progress: [roadmap](docs/roadmap.md) · [product](docs/product.md) · [architecture](docs/architecture.md) · [ADR-0013](docs/adr/ADR-0013-product-scope-rebaseline.md) · [CXI v2 design](protocol/v2-design.md)

## Installation (v0.1.0)

Download `Ampersand-0.1.0.dmg` from the [latest release](https://github.com/luceat-lux-vestra/crossinput/releases), open it, and drag `Ampersand.app` into Applications. The app runs from the menu bar (no Dock icon).

> **First launch (Gatekeeper)**: the app is ad-hoc signed (no Apple Developer ID — see [ADR-0008](docs/adr/ADR-0008-v0.1.0-release-packaging.md)), so macOS may refuse the first launch. Right-click (or Control-click) the app in Finder → **Open** → **Open** to confirm it once.

Ampersand needs `adb` 37+ with mDNS wireless-debugging support on `PATH`; install it via Homebrew (`brew install android-platform-tools`) or Android SDK. Enable **Settings → Developer options → Wireless debugging** on the Android device and pair it once. A matching helper artifact must currently be deployed to `/data/local/tmp/crossinput-helper.apk`; use `scripts/deploy-helper.sh` during development.

## Requirements

| Component | Requirement |
|---|---|
| macOS | 14+ (Apple Silicon preferred) |
| Android | Android 10+; Samsung Galaxy/DeX is the primary supported use case |
| Device setup | Developer options → Wireless debugging |

## Development environment

| Component | Version |
|---|---|
| Xcode | 16+ (Swift 6) |
| JDK | 17 |
| Android SDK | platforms;android-35, build-tools;35.0.0 |
| adb | 37.x |
| Primary test device | Galaxy S10 5G (SM-G977N), Android 12 |

## Quick start (development)

```sh
# Repo setup (git hooks, gitignore, local config)
./scripts/bootstrap.sh

# Build the Android helper
./scripts/build-android-helper.sh

# Run (menu bar app)
./scripts/run-dev.sh
```

## Rules

Work rules live in [AGENTS.md](AGENTS.md). In particular:

- **No hardcoded display IDs** — the helper discovers displays and target selection decides routing.
- **No Electron / Node / Python runtime** in the final app (macOS: Swift, Android helper: Kotlin).
- **No device-dependent support claims without on-device evidence**.
- **No logging of keystrokes, clipboard contents, or raw input payloads**.
- macOS pointer/keyboard control must recover on failure; emergency return remains local and independent of Android health.
- do not broaden product scope through unrelated refactoring.

## License

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
Upstream code reuse is documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
