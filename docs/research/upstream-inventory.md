# Upstream Research Inventory (pre-Phase 0)

> Purpose: survey of candidates to base Ampersand's technology on.
> Survey date: 2026-08-03. Versions/commits are as of the survey.

## 1. leap-scrcpy (yume-chan) — adopted as Phase 0 verification baseline

- Repo: https://github.com/yume-chan/leap-scrcpy
- Commit: `f9aaf1b05118261d75b82ba88b462f08e37eecdc` ("chore: cache gradle packages")
- License: ISC
- Structure:
  - `server/` — Android side. Kotlin, app_process execution, direct `/dev/uhid` manipulation (no root needed). `DisplayManagerGlobal.getDisplayInfo(0)` — **display 0 hardcoded**.
  - `src/` — TypeScript client. Connects via `@yume-chan/adb`, pushes APK, spawns app_process, stdin/stdout protocol.
- Behavior: connects to a Deskflow (Input Leap family) server as a client named "Android". Pointer sent as absolute-coordinate stylus UHID. Includes rotation mapping (RotationMapper).
- Issue: completely unaware of desktop display — DeX external display routing unverified.
- Reuse candidates: UHID create/inject approach, HID descriptors, protocol framing ideas.

## 2. deskflow-android (jglanz) — reference only (not adopted as baseline)

- Repo: https://github.com/jglanz/deskflow-android
- Issue: public issues where input is not delivered to the DeX external display (delivered only to phone screen, pointer does not appear).
- Conclusion: reference material only.

## 3. InputShare-mac (wafflexyzz) — not adopted

- Repo: https://github.com/wafflexyzz/InputShare-mac
- Issues: Windows-centric, build confirmed impossible. Do not use.

## 4. Deskflow (deskflow) — used as verification server

- Repo: https://github.com/deskflow/deskflow
- Version: 1.26.0 (macOS arm64)
- License: GPL-3.0 — **must not be included in final distribution**, dev/verification tool only.
- Purpose: in Phase 0, Mac acts as a Deskflow server serving as the input source for the leap-scrcpy client.

## 5. scrcpy (Genymobile) — reference

- Origin of the UHID input approach; the source structure leap-scrcpy derives from.
- License: Apache-2.0. Reference when needed (update THIRD_PARTY_NOTICES.md if copying).

## Reuse decision

| Candidate | Decision | Reason |
|---|---|---|
| leap-scrcpy | Phase 0 reproduction + idea reference | Builds without modification, ADB-based, UHID approach |
| deskflow-android | reference only | DeX routing unresolved |
| InputShare-mac | do not use | Build impossible, Windows-centric |
| Deskflow | verification tool only | GPL-3.0 distribution constraint |
| scrcpy | reference | origin of the UHID approach |
