# Ampersand Roadmap

> Updated: 2026-08-05 (v0.1.0 released; keyboard primary path + distribution shipped)
> Original plan: `DEXCURSOR_IMPLEMENTATION_PLAN.md` (1221 lines, kept in local Downloads — historical document)

## Phase overview

| Phase | Content | Completion criteria | Status |
|---|---|---|---|
| 0 | UHID input verification (DeX external display delivery) | On-device click/move/cursor display confirmed | ✅ done (category A) |
| 0.5 | Execution method decided (ADR-0006) | v1 = adb push + run confirmed; installed app deferred to v2 | ✅ done |
| 1 | Repository bootstrap | bootstrap.sh / build-android-helper.sh / swift build + tests / CI green | ✅ done (macOS packaging via `scripts/package-macos.sh` deferred to Phase 8) |
| 2 | Android helper minimal implementation | display discovery + UHID + CXI protocol | ✅ done |
| — | InputManager pointer fallback (SdkPointerBackend) | implemented; UHID pointer path verified on-device, pointer fallback on-device verification tracked separately | 🔶 implemented; on-device verification pending (not yet exercised on device) |
| 3 | DeX input routing | UHID input delivered to the DeX external display (leverages Phase 0 findings) | ✅ done (on-device, UHID pointer path) |
| 4 | CGEventTap prototype | input capture verified against the real Android sink | ✅ done |
| 5 | Edge switching | macOS↔DeX switching | 🔶 implemented; 100-repeat stability open (see below) |
| 6 | Menu bar app + onboarding | settings/status UI + wireless debugging pairing guide | ✅ done |
| 7 | Recovery & performance | sleep/wake, permission revocation, error recovery | 🔶 auto-reconnect done; sleep/wake edge cases open |
| 8 | Distribution | **v0.1.0 shipped**: `Ampersand-0.1.0.dmg` on GitHub Releases, ad-hoc signed (ADR-0008). Open: Homebrew tap (ADR-0005), adb bundling (ADR-0004), notarization when a Developer ID exists | ✅ v0.1.0 shipped 🔶 |
| 9 | Keyboard extension (mac→Android) | keyboard delivery + system-shortcut handling + Korean 2-set, per ADR-0007 | 🔶 UHID path verified on-device; InputManager fallback on-device verification pending |

## Phase 9: Keyboard extension — partially done

Completion criteria split (per ADR-0007):

- **protocol/KEY_EVENT delivery** — done (PR #23)
- **UHID keyboard backend** — done, verified on device (key-state reporting; infinite repeat fixed — PR #24, #26)
- **macOS system-shortcut suppression while captured** — done, verified on device (PR #25)
- **Korean 2-set composition via Android IME** — done, verified on device
- **InputManager virtual-injection fallback** — implemented, unit/build validated, **on-device verification pending** (issue #33)

## Phase 0: UHID input verification — done

**Result: category A — UHID relative mouse fully controls the DeX external display.** (SM-G977N, Android 12)

- Mouse movement: 1:1 mapping + pointer acceleration (same as a real mouse)
- Click: delivered to the DeX (display 2) window, focus change confirmed
- Cursor display: arrow shown while moving, fades after ~3.5s idle (Samsung default UX)
- Input path: app_process (shell uid) UHID — no root required

## Issue breakdown

- Epic A (Feasibility): A-01~A-07 — Phase 0 done
- Epic B (Android helper): B-01~B-07
- Epic C (macOS input): C-01~C-07
- Epic D (edge switching): D-01~D-07
- Epic E (productization): E-01~E-07
- Epic F (extension — dex→mac): F-01~F-07 (see ADR-0003: accessibility touch + custom IME keyboard, after v1)

## Extension scope (after v1, ADR-0003)
> mac→Android keyboard completed in Phase 9 (ADR-0007) — see above.

- ~~mac→Android keyboard: UHID keyboard delivery; macOS system-shortcut handling (Cmd+Tab etc.) was the open item~~ → **Phase 9, ADR-0007 — UHID path done on device**: keyboard message type + UHID keyboard backend on Android, system-shortcut suppression in the macOS capture tap, Korean 2-set via Android IME. InputManager virtual-injection fallback implemented; on-device verification pending (issue #33)
- dex→mac touch: AccessibilityService capture + CGEventPost injection
- dex→mac keyboard: custom IME app (our keyboard must be the active IME), Korean via text transport
- iPad: out of scope (no CGEventTap-equivalent API on iPadOS)

## Open future work items

- **Display list auto-refresh (unreliable, issue #17)** — the macOS app refreshes the display list only via the manual "Refresh Displays" menu action (LIST_DISPLAYS re-issue). A DISPLAY_CHANGED handler exists but auto-sync is NOT declared reliable and must be fixed in a future work item. The reporter cannot enumerate all failure cases, so **all of the following cases must be verified during that work** (do not assume a single root cause):
  - DeX display hot-plug while the app runs (connect/disconnect HDMI)
  - DeX display state toggling ON/OFF without removal (helper reports stale OFF states)
  - Multiple display IDs (0 = phone built-in / DeX desktop / HDMI) with per-display edge config
  - Wireless-debugging drop (Samsung disables on Wi-Fi drop/sleep) + auto-reconnect — reconnected session must re-fetch the list and restore selection
  - Stale ConnectionManager callbacks racing a fresh connect
  - List when DeX is off (only built-in display 0 present) — decide desired behavior (show nothing vs. still show phone screen)
  - "Refresh Displays" while app is disconnected — currently logged as ignored; confirm expected UX

## Progress log

- 2026-08-05: **v0.1.0 released** — `Ampersand-0.1.0.dmg` on GitHub Releases (PR #28): ad-hoc signed + DMG packaging (ADR-0008), `release.yml` CI publishing on v* tags, README install docs, CHANGELOG.
- 2026-08-05: keyboard extension primary path complete (ADR-0007, Phase 9) — UHID keyboard (PR #23–#26), macOS system-shortcut suppression, Korean 2-set; infinite key-repeat fixed on the UHID path (key-state reporting); verified on device (SM-G977N). InputManager virtual-injection fallback implemented but not yet exercised on a physical device (issue #33)
- 2026-08-04: display handling work committed (commit 65c4766): DISPLAY_CHANGED live update, manual Refresh Displays, stale-list clearing on connect/disconnect, wireless auto-reconnect; per-display list refresh remains manual for now, auto-update tracked as issue #17
- 2026-08-03: environment check complete (SM-G977N, Android 12, wireless ADB connected, DeX active — display 0 phone / 2 Desktop / 6 HDMI)
- 2026-08-03: leap-scrcpy server APK built (`app-debug.apk` 5.8MB), client built (`pnpm build`)
- 2026-08-03: UHID mouse on-device verification complete — move/click/cursor display (category A)
- 2026-08-03: product name Ampersand / tagline CrossInput / repo crossinput (ADR-0002), scope (ADR-0003), adb bundling (ADR-0004), distribution (ADR-0005), execution method decided (ADR-0006: v1 = adb push + run, installed app deferred to v2)
- 2026-08-03: repository bootstrap complete — CI green (macOS swift build+test / Android gradle build / protocol fixture checks), repo `crossinput` created on GitHub (private)
- 2026-08-03: verification results recorded in issue #2; docs/ migrated to English
