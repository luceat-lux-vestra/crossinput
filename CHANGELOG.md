# Changelog

All notable changes to this project follow the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.
Versioning follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- (empty — redaction fix lands with the key-code logging PR)

## [0.1.0] - 2026-08-05

### Added

- macOS menu bar app: pointer capture + edge switching (macOS ↔ DeX via UHID)
- Pointer input: relative move, buttons, scroll (UHID primary, InputManager injection fallback) — verified on device (SM-G977N, Android 12)
- Keyboard input: UHID keyboard backend + InputManager virtual-injection fallback (ADR-0007), system-shortcut suppression while captured, Korean 2-set via Android IME. UHID keyboard delivery, shortcut suppression, and Korean 2-set composition were verified on device. The InputManager injection fallback is implemented but has not yet been exercised on a physical device.
- Wireless ADB (mDNS TLS) auto-discovery and reconnect
- Display handling: live DISPLAY_CHANGED updates, manual Refresh Displays
- App packaging: `Ampersand.app` menu bar bundle (LSUIElement) + `Ampersand-0.1.0.dmg` (ADR-0008)
- CI: `ci.yml` (swift/android/fixtures) + `release.yml` (DMG on v* tags)
- Decisions recorded: ADR-0007 (keyboard delivery), ADR-0008 (v0.1.0 release packaging)

#### Project groundwork

- Repository bootstrap: AGENTS.md, doc skeleton, license (Apache-2.0), CI workflows
- Phase 0 UHID input verification completed on device (SM-G977N): mouse move/click/cursor display on the DeX external display (category A)
- Product identity: Ampersand (brand) / CrossInput (tagline), repo `crossinput`, protocol prefix CXI (ADR-0002)
- Decisions recorded: ADR-0001 (UHID input strategy), ADR-0003 (scope), ADR-0004 (adb bundling), ADR-0005 (distribution), ADR-0006 (execution method)
- CI: macOS swift build+test / Android gradle build / protocol fixture checks (all green)

### Changed

- Keyboard delivery protocol: KEY_EVENT metaState u16 → u32 aligned with real Android META_* constants

### Fixed

- UHID keyboard infinite key repeat: report key-state (pressed set) instead of raw key events
