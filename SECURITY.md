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
  `Documentation Validation`, `Evidence & Tooling Validation`, `failure-triage`, and
  `Dependency Review`. The first four are always produced by `ci.yml`; the latter two
  are produced by their dedicated workflows. The active ruleset is strict, has no bypass
  actors, requires review-thread resolution, and allows squash-only merges.
- **Code scanning authority:** the custom `.github/workflows/codeql.yml` workflow is the
  single authority. Actions, Python, and Swift are active. Java/Kotlin is a documented
  temporary capability exception tracked by issue #157 because the stable action-managed
  CodeQL bundle does not yet accept the maintained Kotlin 2.4.20 compiler path. GitHub's
  CodeQL *default setup* is intentionally left `not-configured`; enabling it would create
  a competing authority, and the hardening policy rejects that drift.
- **Actions policy:** repository settings require full-SHA action pins, the default
  workflow token is read-only, and workflows may not approve pull requests. Write
  permissions are job-scoped and enumerated in `.github/hardening-policy.json`.
- **Releases:** `v*` tags are immutable (deletion and update blocked, no bypass). The
  release workflow builds only from the tag's exact reviewed-`main` commit, verifies
  checkout/version/signature/DMG identity, generates the checksum, attests the verified
  DMG build provenance with GitHub artifact attestations, publishes only after those
  checks, and re-verifies tag, commit and asset identity after publication. An
  inconclusive release lookup aborts rather than creating or mutating a release.

### Failure classification control

The required `failure-triage` check is an unprivileged `pull_request` adapter to the
organization's centrally maintained failure-declaration action, pinned by full commit SHA.
It validates the PR's failure-remediation declaration but does not classify GitHub Actions
failures by itself.

The trusted `Failure classification` workflow runs from the default branch after tracked
workflows complete. It rebuilds active failures for the exact PR HEAD and upserts one sticky
`CI Failure Classification` comment. The reporter treats logs and metadata as untrusted
data: it never checks out or executes PR code, never executes downloaded artifacts, and has
no workflow-level write authority. Its only mutation authority is job-local
`pull-requests: write`; workflow evidence access is job-local `actions: read`.

A repository is not considered fully rolled out merely because the reporter workflow was
merged. GitHub loads `workflow_run` workflows from the default branch, so the PR that first
introduces the reporter cannot prove its own reporter path. Rollout requires a later PR,
after the reporter is present on `main`, whose exact final HEAD passes the ordinary
required checks and receives exactly one sticky classification report for that same HEAD.
With no active failure or pending tracked workflow, that report must reach `CLEAR`.

`AUTO_PROVEN` may establish a canonical failure class only when deterministic evidence is
sufficient. `CANDIDATE` and `UNKNOWN` remain fail-closed and do not authorize remediation.

CI never satisfies the ADR-0012 physical-device evidence gate. The audit checks that the
evidence analyzers and verifiers are present and unbroken; acceptance of a device cycle
remains a real-hardware activity tracked in issue #68.

## Security principles (linked to AGENTS.md hard rules)

- Keystrokes / clipboard / input payloads are never logged (AGENTS.md hard rule 4).
- No cloud relay, root, or Knox bypass. Device interaction remains local. Any internal Android API use must be isolated, documented, feature-detected, and fail safely (AGENTS.md hard rule 9).
- Pointer-trapping code is not allowed on any path except test-only.
