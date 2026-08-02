# Ampersand Architecture

> Status: draft (v1 in progress — Phase 0 verified on device; key decisions recorded in docs/adr/)

## Goal

macOS menu bar app. Pushing the MacBook trackpad pointer to the screen edge switches to the Samsung DeX external display; pushing again returns to macOS.

## System composition

```
┌───────────────────────────── macOS (Swift 6) ─────────────────────────────┐
│ Menu Bar UI  Edge Switch State Machine  CGEventTap (input capture)        │
│ Connection Manager ──► adb subprocess (ADB over Wi-Fi)                    │
└───────────────────────────────────┬──────────────────────────────────────┘
                                    │ ADB stdin/stdout framing (CXI protocol)
┌───────────────────────────────────▼──────────────────────────────────────┐
│                        Android helper (Kotlin)                           │
│  app_process entrypoint  │  display discovery (DisplayManager)           │
│ UHID create/inject │ display/rotation/state reporting                 │
└───────────────────────────────────┬──────────────────────────────────────┘
                                    │ UHID (virtual HID device)
                              ┌─────▼─────┐
                              │ DeX screen│ (external display, e.g. 1920x1080)
                              └───────────┘
```

## Tech stack

| Layer | Tech | Constraints |
|---|---|---|
| macOS app | Swift 6, SwiftUI, AppKit, CoreGraphics, Quartz Event Services, Swift Concurrency | Electron/Node/Python forbidden |
| Build | Swift Package Manager + XCTest | macOS 14+, Apple Silicon first (Xcode project not required — packaging via `scripts/package-macos.sh`) |
| Android helper | Kotlin, Java 17, Gradle Kotlin DSL, app_process execution | minSdk supports S10 5G |
| Communication | ADB over Wi-Fi (wireless debugging), CXI binary protocol | — |
| License | Apache-2.0 + LICENSE, NOTICE, THIRD_PARTY_NOTICES.md | — |

## Core components (macOS)

- **App**: menu bar UI, onboarding, status display
- **InputCapture**: CGEventTap — input suppression, delta preservation, cursor hide/show, edge warp
- **EdgeSwitch**: state machine — DISABLED/DISCONNECTED/CONNECTING/MAC_ACTIVE/EDGE_ARMED/DEX_ACTIVE/RECOVERING/ERROR
- **AndroidBridge**: adb subprocess management, protocol serialization/deserialization
- **Protocol**: CXI message definitions (Swift, golden fixture tests)
- **Diagnostics**: logging, status reporting
- **Settings**: settings storage (UserDefaults)

## Core components (Android helper)

- **Main**: app_process entry point, stdin/stdout event loop
- **DisplayDiscovery**: discovers/reports all displays via DisplayManager
- **HidDeviceManager**: UHID create/destroy/report injection
- **Protocol**: CXI message definitions (Kotlin, golden fixture tests)

## Design decisions

Decisions are recorded in ADR format in [docs/adr/](adr/).

## Verification strategy

- "It works" claims require on-device ADB logs + DeX screen confirmation (AGENTS.md hard rule 2).
- DeX input routing verification follows [docs/testing.md](testing.md).
- Edge switching: 100 repeat tests before declaring complete.
