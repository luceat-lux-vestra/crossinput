# AGENTS.md

Rules that agents (and developers) must follow when working on Ampersand.

## Absolute prohibitions (Hard rules)

1. **Never trap the pointer** — code that holds the macOS pointer is not allowed on any path. Exception: test-only scripts explicitly approved by the user.
2. **No "verified complete" claim without on-device logs** — success cannot be claimed from emulator/local tests alone. Requires real-device (SM-G977N) ADB logs + screen confirmation.
3. **No hardcoded display ID 2** — the DeX display ID differs per device/settings. The helper discovers all displays via `DisplayManager` and decides with a documented selection rule.
4. **No logging of keystrokes / clipboard / input payloads** — key codes, clipboard contents, and HID report payloads are never logged. In debugging, log metadata only (type, length, direction).
5. **Suppression code requires timeout + fail-safe** — input suppression must have a timeout and a release path; on any failure path the pointer returns to the user immediately.
6. **Protocol changes require updating fixtures + protocol.md** — changing a protocol message requires updating `protocol/protocol.md` and the golden fixtures in `protocol/fixtures/`.
7. **Update THIRD_PARTY_NOTICES.md when copying upstream code** — record which files came from which upstream (repo, commit, license).
8. **No Electron / Node / Python runtime in the final app** — macOS app in Swift, Android helper in Kotlin. (Dev tools excluded — e.g. doc generation.)
9. **No cloud / root / Knox bypass** — DeX control stays device-local (UHID, DisplayManager, etc.). No cloud relay. Internal or non-SDK Android APIs may be used only when the usage is isolated behind an adapter, documented in an ADR, runtime-detected, covered by a safe fallback or clean failure path, and never treated as universally available.
10. **English for all repository artifacts** — commits, PR titles/descriptions, issues, docs, and code comments are written in English. Korean is only allowed in chat with the user. New documents must be written in English; existing Korean documents are migrated to English as they are updated.

## Verification criteria

- "It works" claims must attach one of: real-device `dumpsys display` log, ADB `logcat` excerpt, video/screen capture, or a reproducible command list of the verification procedure.
- DeX input routing verification follows the protocol in `docs/testing.md`.
- Edge switching stability is not declared complete until 100 repeat edge-switch tests pass.

## Workflow

1. Read the relevant docs (docs/, protocol/) before working.
2. Create a GitHub issue when starting work (labels required: `type/*`, `area/*`, `priority/*`) — track each work item as an issue, record progress in the issue.
3. After code changes: build + lint + related tests.
4. Record verification results in `docs/research/` or in issues/PRs.
5. PRs must reference the issue (`Fixes #N`) and must not be merged without verification records.
6. On completion, close the issue and leave the merge record in the issue.

## Documentation requirements

- Decisions are recorded in `docs/adr/` in ADR format (context/decision/alternatives/consequences/validation/revisit conditions).
- Commands and versions are recorded reproducibly (include commands + dependency versions in docs).
