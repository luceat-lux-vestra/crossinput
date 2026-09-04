# Ampersand

**A DeX-first macOS-to-Android input bridge.**

Ampersand captures pointer and keyboard input on macOS and hands control to a selected Android display when the pointer crosses a configured screen edge. Its primary use case is Samsung DeX: use a Galaxy device as a desktop target while keeping keyboard and pointer control on the Mac.

Pointer and keyboard input are intentionally one-way: **macOS → Android**. Push the pointer back to return to macOS. No root or phone-side app installation is required in the current runtime model; the helper is launched through ADB/app_process after wireless-debugging setup.

The user-facing product and macOS application are **Ampersand**. This repository keeps `crossinput` as its repository and technical namespace, while the wire protocol uses the **CXI** prefix.

```text
┌─ Ampersand for macOS (Swift) ─┐   ┌─ Android helper (Kotlin) ─┐
│ pointer + keyboard capture     │   │ display discovery          │
│ semantic input + edge handoff  │   │ pointer/keyboard backends  │
└──────────────┬─────────────────┘   └──────────────┬─────────────┘
               │                                    │
               └──── CXI v1 over ADB/app_process ─►│
                                                    ▼
                                      DeX / Android display
```

## Features

- **Edge switching** — cross a configured macOS screen edge to hand control to Android, then push back to return.
- **Pointer support** — movement, left/right/middle click, drag, vertical scroll, and horizontal scroll.
- **Keyboard support** — macOS → Android key delivery with modifier/shortcut handling and the implemented Korean input path.
- **DeX-first routing** — desktop targets such as DeX prefer system-routed UHID so the visible Android cursor follows the normal Android input path.
- **Selectable Android displays** — the built-in phone display and other discovered displays on the connected device can remain selectable targets.
- **No root / Knox bypass** — the helper runs through the existing ADB/app_process workflow.
- **Fail-safe local recovery** — helper failure, transport failure, timeout, emergency return, and capture shutdown must restore macOS control.

## Current release

`Ampersand-0.1.0.dmg` is the current ad-hoc-signed macOS release artifact. See the [latest release](https://github.com/luceat-lux-vestra/crossinput/releases) and [CHANGELOG.md](CHANGELOG.md).

## Installation

1. Download `Ampersand-0.1.0.dmg` from the latest release.
2. Open the DMG and drag `Ampersand.app` into Applications.
3. Because the build is ad-hoc signed rather than Developer-ID notarized, first launch may require Finder → right-click/Control-click → **Open** → **Open**.
4. Install `adb` 37+ with mDNS wireless-debugging support, for example through Homebrew (`brew install android-platform-tools`) or the Android SDK.
5. Enable **Developer options → Wireless debugging** on the Android device and pair it once.

### Current helper packaging limitation

The v0.1.0 release is **not yet fully self-contained**: a matching helper artifact must currently be deployed to `/data/local/tmp/crossinput-helper.apk`. During development this is handled by:

```sh
./scripts/deploy-helper.sh
```

Making the released app bootstrap the matching helper itself remains part of release hardening rather than something the README hides behind the DMG installation step.

## Requirements

| Component | Requirement |
|---|---|
| macOS | 14+; Apple Silicon preferred |
| Android | Android 10+; Samsung Galaxy/DeX is the primary supported use case |
| Device setup | Developer options + Wireless debugging |
| adb | 37+ with mDNS wireless-debugging support |

Primary device evidence currently includes Galaxy S10 5G (SM-G977N), Android 12. Device-dependent support claims require on-device evidence; see [docs/testing.md](docs/testing.md).

## Scope

Ampersand controls one Android device at a time. Multiple displays on that device are supported through target selection; simultaneous control of multiple Android devices is not currently planned.

Current non-goals include:

- Android → macOS pointer/keyboard control;
- using Android itself as a pointing device for macOS;
- cloud relay or account infrastructure;
- root or Knox bypass;
- speculative transport/plugin frameworks without a concrete product need.

Windows/Linux hosts, alternate local transports, and broader target families may be evaluated later but are not current commitments.

## Protocol and transport

- **CXI v1** is the current production protocol.
- **ADB/app_process** is the current/default transport.
- **CXI v2** is a future semantic, capability-negotiated, backend-independent design and is not a current implementation claim.

See [protocol/v2-design.md](protocol/v2-design.md) for the future protocol direction.

## Clipboard direction

Clipboard is intentionally separate from pointer/keyboard control.

- Near term: bidirectional UTF-8 text clipboard synchronization (#89).
- Backlog: bidirectional image clipboard synchronization (#90).
- Backlog: file clipboard / file transfer (#91).

Bidirectional clipboard/data sharing does not make pointer or keyboard control bidirectional. Clipboard contents are never logged.

## Development

```sh
# Repository/bootstrap setup
./scripts/bootstrap.sh

# Build the Android helper
./scripts/build-android-helper.sh

# Run the macOS menu-bar app
./scripts/run-dev.sh
```

Development environment:

| Component | Version |
|---|---|
| Xcode | 16+ / Swift 6 |
| JDK | 17 |
| Android SDK | platforms;android-35, build-tools;35.0.0 |
| adb | 37.x |

## Architecture and project docs

- [Product scope](docs/product.md)
- [Architecture](docs/architecture.md)
- [Testing and evidence policy](docs/testing.md)
- [Roadmap](docs/roadmap.md)
- [ADR-0007 — keyboard delivery](docs/adr/ADR-0007-keyboard-delivery.md)
- [ADR-0008 — v0.1.0 packaging](docs/adr/ADR-0008-v0.1.0-release-packaging.md)
- [ADR-0013 — product scope rebaseline](docs/adr/ADR-0013-product-scope-rebaseline.md)
- [ADR-0014 — product brand and technical naming](docs/adr/ADR-0014-product-brand-and-technical-naming.md)

## Safety and privacy constraints

- No hardcoded display IDs; target selection uses discovered displays.
- No Electron, Node, or Python runtime in the final application.
- No device-dependent support claims without on-device evidence.
- No logging of keystrokes, clipboard contents, or raw input payloads.
- macOS control recovery remains local and must not depend on Android health.

## License

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE). Upstream code reuse is documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
