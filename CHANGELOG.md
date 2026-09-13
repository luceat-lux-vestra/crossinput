# Changelog

All notable changes to this project follow the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.
Versioning follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.1] - 2026-09-13

Ampersand 0.1.1 is a pre-Architecture-Leap field-use maintenance release built from the reviewed production `main` lineage. It does not claim ADR-0012 Level-3 release-stability completion, and it does not satisfy the separate 0.2.0 permission/onboarding blocker tracked by #99.

### Added

- Explicit **Enable/Disable Edge Switch** and **Disconnect** controls, keeping control ownership separate from Android session teardown.
- Test-only deterministic pointer/keyboard backend selection and failure hooks used to verify UHID/InputManager routing and failover paths.
- Metadata-only delivery/transport diagnostics, candidate build identity, wireless-ADB stress tooling, and the ADR-0012 fail-closed stability analyzer.
- Physical-device verification coverage for the forced InputManager keyboard fallback on SM-G977N / Android 12, including held-key shutdown cleanup.
- Hardened CI, CodeQL, release provenance, checksum generation, evidence sanitization, and repository policy checks.

### Changed

- Reworked the macOS application around explicit Session, Target, Control, delivery, and transport boundaries while retaining CXI v1 compatibility.
- DeX desktop pointer routing now prefers a system-routed UHID mouse so the visible Android cursor follows the normal InputReader path; non-desktop targets continue to use explicit-display InputManager routing.
- Semantic pointer commands now use explicit pointer delivery results, including accepted movement, while helper backend selection/failover remains isolated on Android.
- Horizontal scrolling is supported consistently on the UHID and InputManager pointer paths.
- Keyboard backend selection is deterministic under test overrides; AUTO continues to prefer UHID and fall back to InputManager where applicable.
- Helper shutdown and backend cleanup sequencing were strengthened, including release of accepted virtual key-down state before teardown.
- Product positioning and documentation now use **Ampersand** as the user-facing application name and **CrossInput/CXI** for repository/protocol terminology.

### Fixed

- Prevented immediate or directionally inverted edge returns by normalizing the first movement after entry and applying one consistent four-edge direction model.
- Fixed pull-back from a clamped Android boundary by crediting return-direction requested intent instead of losing it when accepted remote movement is zero.
- Made the suppression watchdog actually execute independently of the event-tap run loop and blocked dead-session edge re-entry after fail-safe return.
- Moved the Shift-Cmd-X emergency return check into the event tap so it remains available while keyboard events are suppressed.
- Scoped edge handoff to the macOS display that actually contains the current pointer event, avoiding stale multi-display geometry.
- Prevented scroll/move queue pressure from being misclassified as remote transport failure; adjacent additive work coalesces and bounded overload sheds additive samples instead of forcing a false `remoteUnavailable` return.
- Prevented stale event-tap callbacks from being relabeled into a later suppression generation and delivered into a replacement remote-control epoch.
- Corrected InputManager right/middle-click metadata and strengthened backend failover/lifecycle handling.
- Removed raw key-code/error-payload logging from keyboard failure paths and added guards against input-payload logging regressions.

### Known limitations / evidence status

- The packaged macOS app still does not bootstrap its matching Android helper automatically; the helper must be deployed separately with the documented development workflow.
- Issue #96 is an accepted macOS native cursor-presentation limitation under repeated host confinement. Pointer/control safety behavior is retained; the exact AppKit/WindowServer root cause remains unverified.
- Issue #99 remains an explicit **0.2.0 release blocker** for first-run input-permission onboarding and runtime permission recovery.
- ADR-0012 Level-3 physical release-stability evidence remains tracked separately in #68 and is **INCOMPLETE (0/100 accepted cycles for the current post-rewrite lineage)**. This 0.1.1 field-use release does not claim Level-3 PASS.

## [0.1.0] - 2026-08-05

### Added

- macOS menu bar app: pointer capture + edge switching (macOS ↔ DeX via UHID)
- Pointer input: relative move, buttons, scroll (UHID primary — verified on device, SM-G977N / Android 12; InputManager injection fallback implemented, on-device verification pending)
- Keyboard input: UHID keyboard backend + InputManager virtual-injection fallback (ADR-0007), system-shortcut suppression while captured, Korean 2-set via Android IME. UHID keyboard delivery, shortcut suppression, and Korean 2-set composition were verified on device. The InputManager injection fallback was verified on SM-G977N / Android 12 on 2026-08-10; see issue #33.
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
