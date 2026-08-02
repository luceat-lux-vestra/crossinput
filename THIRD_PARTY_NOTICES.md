# THIRD_PARTY_NOTICES.md

Records the origin of all upstream code and assets reused/derived by Ampersand.
AGENTS.md hard rule 7: **any copy or derivation of upstream code requires updating this file.**

| Component | Source | Version/Commit | License | Usage | Location in this repo |
|---|---|---|---|---|---|
| leap-scrcpy | https://github.com/yume-chan/leap-scrcpy | `f9aaf1b05118261d75b82ba88b462f08e37eecdc` | ISC | Idea/UHID reference (build verified only; run-level reproduction not completed — Phase 0 was verified with our own UHID probe) | `leap-scrcpy/` (gitignored checkout), `docs/research/upstream-inventory.md` |
| Deskflow | https://github.com/deskflow/deskflow | 1.26.0 (macOS arm64) | GPL-3.0 | Phase 0 verification Deskflow server (dev tool, not in distribution) | separate install `/Applications/Deskflow.app` |

## Usage rules

- The table above is for inventory purposes; no code has been copied yet.
- Once copying/deriving begins, subdivide entries: state the source commit and license per individual file, and keep the original copyright notice at the top of each file.
- Components with license compatibility issues (e.g. GPL) are not included in the final distribution.
