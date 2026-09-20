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

Preserve validated product behavior, device/protocol facts, safety invariants, and reproducible evidence. Existing internal abstractions are not compatibility requirements. Under Architecture Leap #101 / ADR-0016, an abstraction may be replaced or deleted when the approved ownership/concurrency design makes that the safer and clearer implementation. New abstractions still require a concrete responsibility and must not broaden product scope speculatively.

## Absolute prohibitions (Hard rules)

1. **Never leave the pointer trapped** — intentional host confinement is allowed only while one valid remote-control SuppressionLease is active under the accepted #96 P0 contract. It must always have an idempotent local release, watchdog, and emergency return; Session/Target/delivery/capability failure must fail toward local control without waiting for Android.
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
13. **Do not preserve architecture merely to minimize the diff** — Architecture Leap #101 and ADR-0016 authorize broad internal redesign when it materially improves ownership, lifecycle correctness, concurrency safety, or testability. Preserve validated behavior and evidence, not pre-Leap class/module shape. Decompose large migrations into coherent reviewable slices; never use “rewrite freedom” to mix unrelated product/protocol/transport changes.

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
3. Keep changes bounded to the issue's responsibility and accepted architecture. “Bounded” means one independently reviewable purpose, not preserving old files/classes or artificially minimizing the diff. Do not mix product/protocol/transport migrations into unrelated fixes.
4. After code changes: build + lint + related tests.
5. Record verification results in `docs/research/` or in issues/PRs.
6. PRs must reference the issue and must not be merged without the required verification record.
7. On completion, close the issue and leave the merge record in the issue.

## Failure classification before remediation

A failing runtime observation, device test, CI check, evidence gate, hardening
audit, or other red signal is an **observation**, not a patch target. Before a
non-trivial remediation, classify the observed failure as exactly one of:

- `implementation defect` — CrossInput product code violates the accepted
  product, protocol, lifecycle, routing, or safety contract;
- `test defect` — a harness, fixture, simulator, assertion, automation step,
  or verification procedure is wrong for the intended contract;
- `evidence defect` — device/runtime evidence capture, attribution,
  provenance, freshness, parsing, or proof construction is wrong or
  insufficient;
- `workflow-policy drift` — CI, hardening, repository policy, checked-in
  governance, or live repository settings have diverged;
- `environment failure` — host/device state, ADB transport, permissions,
  toolchain, runner, platform service, resource state, or another execution
  environment condition caused the failure;
- `UNKNOWN` — available evidence does not justify any of the five classes.

Project-specific subtypes may refine the canonical class. In particular,
device/platform capability limitations must be recorded explicitly instead of
being silently treated as product bugs. A missing or unsupported device
capability may be classified as `environment failure / device capability`
only when the accepted product contract already treats that capability as
optional or runtime-detected; otherwise keep the responsibility `UNKNOWN`
until product detection, harness, evidence, and environment causes are
separated.

`UNKNOWN`, `UNVERIFIED`, and `INSUFFICIENT EVIDENCE` remain fail-closed.
Classification is itself a proof obligation. Preserve at least:

```text
Observed:
Classification:
Basis:
Root cause:
Remediation:
Proof:
```

The `Basis` must justify the selected responsibility layer and identify
plausible alternatives that were rejected or remain unresolved. Do not treat a
device/runtime symptom as an implementation defect until product code,
harness/test, device capability, evidence, workflow-policy, and host/device
environment causes have been separated.

A deterministic/reproducible failure does not become an
`environment failure` merely because a later rerun passes. Never weaken a
valid device test, verifier, safety invariant, evidence requirement, or
hardening/review policy merely to obtain green.

If remediation changes product code, a test/harness, device-capability
assumption, evidence procedure, workflow/policy, or another premise of the
reviewed revision, invalidate the affected evidence. Re-run the relevant
targeted/device proof and required CI on the new exact final PR HEAD before
merge.

## Documentation requirements

- Decisions are recorded in `docs/adr/` in ADR format (context/decision/alternatives/consequences/validation/revisit conditions).
- Commands and versions are recorded reproducibly (include commands + dependency versions in docs where relevant).
- Product, architecture, roadmap, protocol design, README, and issues must not make contradictory support claims.
