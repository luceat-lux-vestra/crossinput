# Ampersand — CrossInput

**One MacBook trackpad for macOS and Samsung DeX.**

Push your pointer to the screen edge to switch from macOS to the DeX external display; push it back to return. No app install on your phone and no root required — after a one-time wireless debugging setup, your MacBook trackpad becomes the mouse on the DeX screen.

```
┌─ macOS app (Swift, menu bar) ─┐   ┌─ Android helper (Kotlin) ─┐
│ trackpad capture · edge switch │   │ UHID virtual mouse        │
└───────────┬───────────────────┘   └────────────┬──────────────┘
            │  ADB over Wi-Fi (wireless debugging) │ UHID (no root)
            └───────────► ────────────► ──────────┘
                                          ▼
                              DeX display / Android screen
```

## Features

- **Edge switching**: push the pointer past the screen edge to switch between macOS and DeX
- **Native mouse behavior**: movement (including pointer acceleration), clicks, and wheel via the UHID kernel interface
- **Phone screen too**: when DeX is not in use, control the Android screen directly
- **No installable app**: the helper is pushed and run via ADB (scrcpy-style) — no home-screen icon, no dialogs
- **Scope**: v1 is mac → Android one-way (reverse direction and keyboard are roadmap extensions — [ADR-0003](docs/adr/ADR-0003-scope.md))

## Status

Early development. Android input injection (UHID) is verified on device (SM-G977N, Android 12): mouse movement, clicks, and cursor rendering work on the DeX external display. macOS input capture and app UI are in progress.

Progress: [docs/roadmap.md](docs/roadmap.md) · Design: [docs/architecture.md](docs/architecture.md)

## Requirements

| Component | Requirement |
|---|---|
| macOS | 14+ (Apple Silicon preferred) |
| Samsung Galaxy | Android 10+ (DeX-capable device) |
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
