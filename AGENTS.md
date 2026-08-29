# AGENTS.md

Rules that agents (and developers) must follow when working on Ampersand / CrossInput.

## Product baseline

CrossInput is **DeX-first, Android-capable**.

- macOS is the current host.
- Samsung DeX is the primary target/use case.
- The built-in phone display remains a supported secondary target through the existing Android display-selection model.
- Pointer and keyboard input are macOS → Android.
- Clipboard/data sharing is a separate capability and may be bidirectional.
- One Android device is controlled at a time; multiple displays on that device are supported, simultaneous multi-device control is not.
- ADB/app_process is the current/default transport.
- Alternate local transports and CXI v2 are approved future extension points, not permission to implement speculative frameworks.

Existing justified abstractions stay unless a concrete defect or requirement justifies changing them. New abstractions require a current requirement or an explicitly accepted extension with a concrete use case.

## Absolute prohibitions (Hard rules)

1. **Never trap the pointer** — code that holds the macOS pointer is not allowed on any path. Exception: test-only scripts explicitly approved by the user.
2. **No "verified complete" claim without on-device logs** — success cannot be claimed from emulator/local tests alone. Requires real-device ADB logs + screen confirmation for device-dependent behavior.
3. **No hardcoded display ID 2** — display IDs differ per device/settings. The helper discovers all displays via `DisplayManager` and selection uses the target model.
4. **No logging of keystrokes / clipboard / input payloads** — key codes, clipboard contents, and HID report payloads are never logged. In debugging, log metadata only (type, length, direction).
5. **Suppression code requires timeout + fail-safe** — input suppression must have a timeout and a release path; on any failure path the pointer returns to the user immediately.
6. **Protocol changes require updating fixtures + protocol.md** — changing a production protocol message requires updating `protocol/protocol.md`, both implementations as applicable, and relevant golden fixtures in `protocol/fixtures/`.
7. **Update THIRD_PARTY_NOTICES.md when copying upstream code** — record which files came from which upstream (repo, commit, license).
8. **No Electron / Node / Python runtime in the final app** — macOS app in Swift, Android helper in Kotlin. (Dev tools excluded — e.g. doc generation.)
9. **No cloud / root / Knox bypass** — CrossInput stays device-local. Internal or non-SDK Android APIs may be used only when the usage is isolated behind an adapter, documented in an ADR, runtime-detected, covered by a safe fallback or clean failure path, and never treated as universally available.
10. **English for all repository artifacts** — commits, PR titles/descriptions, issues, docs, and code comments are written in English. Korean is only allowed in chat with the user. New documents must be written in English; existing Korean documents are migrated to English as they are updated.
11. **Do not conflate bidirectional clipboard with bidirectional input** — clipboard may synchronize both ways; Android → macOS pointer/keyboard is a separate product decision and is currently a non-goal.
12. **Do not broaden the product through refactoring** — Windows/Linux hosts, simultaneous multi-Android control, new target families, alternate transports, or CXI v2 implementation require explicit scope approval and must not be smuggled into cleanup work.
13. **Do not rewrite working architecture for purity** — Session, Control, Target, transport, target normalization, and Android backend seams remain unless a demonstrated problem requires a targeted change.

## Device-specific routing rules

- Desktop sink candidates such as Samsung DeX use system-routed UHID in the current AUTO pointer policy because the visible cursor follows Android's InputReader path.
- Non-desktop targets use InputManager explicit-display pointer routing.
- Never claim target-specific UHID routing: a system-routed UHID device cannot name an arbitrary Android display ID.
- The keyboard backend is not explicitly bound to the selected display ID. Phone-versus-DeX keyboard routing must be described only from device evidence; do not assume a focus or target-routing policy that has not been verified.

## Verification criteria

- "It works" claims must attach one of: real-device `dumpsys display` log, ADB `logcat`/helper excerpt, video/screen capture, or a reproducible command list of the verification procedure appropriate to the claim.
- DeX and phone-display input routing verification follows the protocol in `docs/testing.md`.
- Edge-switching release stability is not declared complete until at least
  100 real physical handoff/return cycles have been observed on a
  release-candidate build with sufficient diagnostics to classify unexpected
  failures. Cycles may accumulate naturally during real use or through an
  approved physical automation harness; synthetic unit/state-machine loops do
  not satisfy the physical-cycle requirement. Individual bug-fix PRs require
  targeted physical verification of the affected behavior only — they never
  require 100 repetitive manual cycles, and a user is never required to
  manually repeat the same handoff 100 times in one sitting. See
  `docs/testing.md` (verification levels) and ADR-0012 for the full policy.

## Workflow

1. Read the relevant product, architecture, ADR, protocol, and testing docs before working.
2. Create or identify a GitHub issue before implementation (labels required: `type/*`, `area/*`, `priority/*`) and record progress in the issue.
3. Keep implementation changes bounded to the issue. Do not mix product/protocol/transport migrations into unrelated fixes.
4. After code changes: build + lint + related tests.
5. Record verification results in `docs/research/` or in issues/PRs.
6. PRs must reference the issue and must not be merged without the required verification record.
7. On completion, close the issue and leave the merge record in the issue.

## Documentation requirements

- Decisions are recorded in `docs/adr/` in ADR format (context/decision/alternatives/consequences/validation/revisit conditions).
- Commands and versions are recorded reproducibly (include commands + dependency versions in docs where relevant).
- Product, architecture, roadmap, protocol design, README, and issues must not make contradictory support claims.
