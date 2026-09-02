# Security Policy

## Supported versions

v0.1.0 is the first public release; there are no LTS/stability guarantees yet.
All reports are welcome until a stable release exists.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting feature for this repository (Security → Report a vulnerability) to report security issues privately. Do not include credentials, ADB pairing information, clipboard contents, keystrokes, or other sensitive data in public issues.

- Response SLA: first response within 7 days.

## Repository controls

The machine-checkable half of these controls lives in
`.github/hardening-policy.json` and is enforced by
`scripts/check-workflow-policy.py`, which runs in the `Evidence & Tooling
Validation` required check (static) and weekly via `.github/workflows/hardening-audit.yml`
(static plus a live readback of rulesets, CodeQL setup and Actions policy).

- **Required checks on `main`:** `macOS App Build + Test`, `Android Helper Build + Test`,
  `Documentation Validation`, `Evidence & Tooling Validation`, all produced by `ci.yml`
  on every pull request with no path or condition filters, under a strict ruleset with
  no bypass actors and squash-only merges.
- **Code scanning authority:** the custom `.github/workflows/codeql.yml` workflow is the
  single authority (Actions, Java/Kotlin, Swift, Python). GitHub's CodeQL *default setup*
  is intentionally left `not-configured`; enabling it would duplicate analysis, and the
  audit fails if it is ever turned on while the custom workflow remains authoritative.
- **Actions policy:** repository settings require full-SHA action pins, the default
  workflow token is read-only, and workflows may not approve pull requests. Write
  permissions are job-scoped and enumerated in `.github/hardening-policy.json`.
- **Releases:** `v*` tags are immutable (deletion and update blocked, no bypass). The
  release workflow builds only from the tag's exact commit, verifies checkout identity,
  and re-verifies tag, commit and asset identity after publishing. An inconclusive
  release lookup aborts rather than creating a release.

CI never satisfies the ADR-0012 physical-device evidence gate. The audit checks that the
evidence analyzers and verifiers are present and unbroken; acceptance of a device cycle
remains a real-hardware activity tracked in issue #68.

## Security principles (linked to AGENTS.md hard rules)

- Keystrokes / clipboard / input payloads are never logged (AGENTS.md hard rule 4).
- No cloud relay, root, or Knox bypass. Device interaction remains local. Any internal Android API use must be isolated, documented, feature-detected, and fail safely (AGENTS.md hard rule 9).
- Pointer-trapping code is not allowed on any path except test-only.
