# Upstream Research Inventory (pre-Phase 0)

> Purpose: survey of candidates to base Ampersand's technology on.
> Survey date: 2026-08-03. Versions/commits are as of the survey.

## 1. leap-scrcpy (yume-chan) — idea reference; build verified only

- Repo: https://github.com/yume-chan/leap-scrcpy
- Commit: `f9aaf1b05118261d75b82ba88b462f08e37eecdc` ("chore: cache gradle packages")
- License: ISC
- Structure:
  - `server/` — Android side. Kotlin, app_process execution, direct `/dev/uhid` manipulation (no root needed). `DisplayManagerGlobal.getDisplayInfo(0)` — **display 0 hardcoded** (we must not copy this — AGENTS.md hard rule 3).
  - `src/` — TypeScript client. Connects via `@yume-chan/adb`, pushes the APK, spawns app_process, stdin/stdout protocol.
- Behavior: connects to a Deskflow (Input Leap family) server as a client named "Android". Pointer sent as absolute-coordinate stylus UHID. Includes rotation mapping (RotationMapper).
- Issue: completely unaware of the desktop display — DeX external display routing unverified.
- **Status**: the server APK and the TS client were built successfully, but the run-level baseline reproduction was never completed. The Phase 0 verification (category A) was instead performed with our own minimal UHID probe (`scripts/uhid-probe.sh` + `UhidProbe.kt`) — see `docs/roadmap.md` Phase 0.
- Reuse candidates: UHID create/inject approach, HID descriptors, protocol framing ideas (all reimplemented, not copied).

## 2. deskflow-android (jglanz) — reference only (not adopted as baseline)

- Repo: https://github.com/jglanz/deskflow-android
- Issue: public issues where input is not delivered to the DeX external display (delivered only to the phone screen, pointer does not appear).
- Conclusion: reference material only.

## 3. InputShare-mac (wafflexyzz) — not adopted

- Repo: https://github.com/wafflexyzz/InputShare-mac
- Issues: Windows-centric, build confirmed impossible. Do not use.

## 4. Deskflow (deskflow) — used as verification server

- Repo: https://github.com/deskflow/deskflow
- Version: 1.26.0 (macOS arm64)
- License: GPL-3.0 — **must not be included in the final distribution**, dev/verification tool only.
- Purpose: in Phase 0, the Mac acts as a Deskflow server providing the input source for a deskflow client.

## 5. scrcpy (Genymobile) — reference

- Origin of the UHID input approach; the source structure leap-scrcpy derives from.
- License: Apache-2.0. Reference when needed (update THIRD_PARTY_NOTICES.md if copying).

## Reuse decision

| Candidate | Decision | Reason |
|---|---|---|
| leap-scrcpy | idea reference (build verified only) | ADB-based, UHID approach; run-level reproduction not completed — our own probe verified Phase 0 instead |
| deskflow-android | reference only | DeX routing unresolved |
| InputShare-mac | do not use | Build impossible, Windows-centric |
| Deskflow | verification tool only | GPL-3.0 distribution constraint |
| scrcpy | reference | origin of the UHID approach |
