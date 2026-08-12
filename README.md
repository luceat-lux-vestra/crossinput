# Ampersand — CrossInput

**A macOS-to-Android input bridge.**

CrossInput captures pointer and keyboard input on macOS and safely hands control
to a selected Android display at a configured screen edge. Samsung DeX is a
supported Android target/use case, not the product definition. Push the pointer
back to return to macOS. No phone app install or root is required: after a
one-time wireless-debugging setup, the Mac controls the selected Android target.

```
┌─ macOS app (Swift, menu bar) ─┐   ┌─ Android helper (Kotlin) ─┐
│ semantic input + edge handoff │   │ backend dispatcher         │
│ shortcut suppression          │   │ UHID → InputManager       │
└───────────┬────────────────────┘   └────────────┬──────────────┘
            │                                     │
            └──► ADB over Wi-Fi (wireless debugging) ► Android helper
                                                    ▼
                                    DeX display / Android screen
```

## Features

- **Edge switching**: push the pointer past the screen edge to switch between macOS and the selected Android target
- **Works with any pointer device**: trackpad, wired or wireless mouse — captured at the macOS level (CGEventTap), no device-specific setup
- **Semantic pointer path**: movement, clicks, and wheel use CXI `POINTER_*` messages; the helper returns accepted movement through `POINTER_RESULT` and never claims a target-specific UHID route it cannot provide
- **Two pointer injection backends**: UHID virtual mouse remains available for system-routed use, while the selected-target application path uses InputManager injection via reflection to set the explicit display ID
- **Works across Android targets**: DeX external display, phone screen, or another discovered Android display — DeX is not required
- **No app install on the phone**: development tooling pushes and runs the helper via ADB (scrcpy-style). The packaged Mac app launches the helper artifact already present at its configured path and rejects an incompatible helper during HELLO; automatic helper packaging/deployment is a follow-up.
- **Keyboard**: mac → Android keyboard delivery — UHID keyboard backend plus an InputManager virtual-injection fallback via reflection (both implemented and verified on SM-G977N / Android 12), with macOS system-shortcut suppression while captured and Korean 2-set composition on Android — [ADR-0007](docs/adr/ADR-0007-keyboard-delivery.md)

## Status

Historical device evidence exists for the pre-rebaseline UHID pointer path,
UHID keyboard path, shortcut suppression, Korean 2-set composition, and the
forced InputManager keyboard fallback on SM-G977N / Android 12. The semantic
pointer/backend path and controller split require a fresh device regression;
see [docs/testing.md](docs/testing.md) and the audit record.

Released as `Ampersand-0.1.0.dmg` (ad-hoc signed, [ADR-0008](docs/adr/ADR-0008-v0.1.0-release-packaging.md)) — see the [latest release](https://github.com/luceat-lux-vestra/crossinput/releases) and [CHANGELOG.md](CHANGELOG.md). Edge-switch stability hardening remains open (issue [#17](https://github.com/luceat-lux-vestra/crossinput/issues/17)).

Progress: [docs/roadmap.md](docs/roadmap.md) · Product: [docs/product.md](docs/product.md) · Design: [docs/architecture.md](docs/architecture.md) · [ADR-0009](docs/adr/ADR-0009-architecture-rebaseline.md) · [CXI v2 design](protocol/v2-design.md)

## Installation (v0.1.0)

Download `Ampersand-0.1.0.dmg` from the [latest release](https://github.com/luceat-lux-vestra/crossinput/releases), open it, and drag `Ampersand.app` into Applications. The app runs from the menu bar (no Dock icon).

> **First launch (Gatekeeper)**: the app is ad-hoc signed (no Apple Developer ID — see [ADR-0008](docs/adr/ADR-0008-v0.1.0-release-packaging.md)), so on first `open` macOS may refuse with "cannot be opened because the developer cannot be verified". To run it: **right-click (or Control-click) the app in Finder → Open → Open** (confirm once). From then on it launches normally.

Ampersand needs `adb` 37+ (with mDNS wireless debugging support) on `PATH`; install it via Homebrew (`brew install android-platform-tools`) or Android SDK. The one-time phone setup: **Settings → Developer options → Wireless debugging** (pair once; the app then auto-discovers the phone). A matching helper artifact must be deployed to `/data/local/tmp/crossinput-helper.apk`; use `scripts/deploy-helper.sh` during development.

## Requirements

| Component | Requirement |
|---|---|
| macOS | 14+ (Apple Silicon preferred) |
| Android target | Android 10+; Samsung Galaxy/DeX is a supported target/use case |
| Phone setup | Developer options → Wireless debugging (one-time) |

## Development environment

| Component | Version |
|---|---|
| Xcode | 16+ (Swift 6) |
| JDK | 17 |
| Android SDK | platforms;android-35, build-tools;35.0.0 |
| adb | 37.x |
| Test device | Galaxy S10 5G (SM-G977N), Android 12 |

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

Work rules for this repository live in [AGENTS.md](AGENTS.md). Highlights:

- **No hardcoded display IDs** — the helper discovers all displays and picks via selection rules
- **No Electron / Node / Python runtime** in the final app (macOS: Swift, Android helper: Kotlin)
- **No "supported" claims without on-device logs**
- macOS pointer control must recover immediately on error; the emergency return shortcut must always work, independent of the Android connection

## License

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
Upstream code reuse is documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
