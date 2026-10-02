# Hardening Reassessment — 2026-09-20

Owning issue: #158 (completed)

> **Historical reassessment record.** This file preserves the 2026-09-20 reassessment and subsequent closure notes. Current repository-hardening ownership continues under #110/#112/#113 and the active checked-in/live policy; historical rollout wording below is not a new backlog.

This pass re-evaluates CrossInput's existing repository hardening against current external GitHub/OpenSSF guidance. It deliberately does not change or reinterpret physical-device evidence obligations owned by the runtime architecture work.

> **2026-09-28 CI scope update.** Documentation-only pull requests now use a mechanically bounded fast path only for `README.md`, `CONTRIBUTING.md`, `AGENTS.md`, and Markdown under `docs/**`. The internal macOS/Android component jobs remain present but skip product runtime work; documentation, evidence/tooling, and dependency validation remain active. Mixed, unreadable, or unlisted scope falls back to full validation. PR #207 provided the default-branch proof case for that path.
>
> **2026-09-28 required-gate aggregation.** PR #209 completed the aggregation: the five validation jobs remain authoritative components, while the live `Protect main` ruleset now requires one fail-closed `Merge Gate` context. `Merge Gate` depends directly on macOS, Android, documentation, evidence/tooling, and Dependency Review and fails unless every component succeeds.

## Existing controls retained

- checked-in hardening policy plus live drift readback;
- strict required-context producer validation;
- full-SHA action pins and least-privilege workflow checks;
- trusted issue/PR metadata automation;
- custom CodeQL authority for Actions, Java/Kotlin, Python, and Swift on the pinned official action-managed bundle;
- protected-main and immutable publication-tag intent.

## PASS — dependency admission

Dependabot proposes dependency updates, but proposal automation is not PR-time admission control.

PR #159 proved `Dependency Review` on the exact candidate after live Dependency Graph enablement. PR #186 promoted the checked-in required-context contract, and authoritative 2026-09-22 readback confirmed that it was independently required with GitHub Actions integration id `15368` and no bypass actors.

After the 2026-09-28 gate aggregation, Dependency Review remains mandatory as an internal `Merge Gate` component rather than an independently required live context. Its PR-diff semantics and fail-on-moderate policy are unchanged.

## GAP — workflow semantic/security scanners

The repository-owned policy checker already catches pinning, permissions, required-producer drift, unsafe privileged checkout, persisted credentials, and selected shell-injection risks. It does not replace a real GitHub Actions parser or an independent workflow-security scanner.

`scripts/check-actions-security.sh` now adds:

- checksum-pinned actionlint 1.7.12;
- checksum-pinned zizmor 1.30.0;
- full active-workflow scans;
- an adversarial negative fixture that both tools must reject for the expected reason.

The script runs inside the already-required `Evidence & Tooling Validation` context and the recurring hardening audit. No extra required context or ruleset churn is introduced.

## PASS — CodeQL; Java/Kotlin stable coverage restored

The custom CodeQL authority remains singular and uses only the pinned official `github/codeql-action` managed bundle.

Exact run 35563677611 previously proved that CodeQL CLI 2.27.0 in `github/codeql-action` v4.38.1 rejected the maintained Kotlin 2.4.20 compiler path as too recent. GitHub subsequently shipped Kotlin 2.4.20 support in stable CodeQL 2.27.1, and `github/codeql-action` v4.38.2 moved its default managed bundle to 2.27.1.

The Java/Kotlin leg is therefore restored with the repository's maintained JDK 25 / Android 17 manual build path. Actions, Java/Kotlin, Python, and Swift are all covered by the same custom workflow. The repository policy continues to reject any external `tools:` override; Kotlin is not downgraded for scanning, and default setup remains disabled so there is still only one CodeQL authority.

Issue #157 owns exact-candidate proof and is closed only after extraction, the Android build, analysis, SARIF processing, and all required CI succeed on the final PR HEAD.

## Metadata

Existing issue-label automation remains in place. This reassessment does not create another taxonomy or classifier.

A follow-up quality review found that the legacy manual `workflow_dispatch` path treated dispatch itself as permission to mutate every open issue. That is weaker than the repository's current fail-closed bulk-operation standard.

The reconciler now requires two independent operator decisions:

- `backfill=false` by default, so an ordinary manual dispatch is a no-op;
- `dry_run=true` by default, so even an explicitly selected backlog pass reports changes before mutation.

Dry-run covers the complete mutation boundary: it cannot create/update the canonical label catalog, remove conflicting type labels, or add issue labels. The required repository policy checker has adversarial fixtures that independently break the backfill opt-in, dry-run default, issue-mutation guard, and label-catalog guard and requires each mutation to fail CI.

## Hardening drift signal quality

A resumed quality review found that the scheduled hardening audit conflated two different states:

- confirmed repository/policy drift or an unexpected loss of a normally-readable control;
- a known administration-only endpoint that the low-privilege scheduled token is not authorized to read.

Those are no longer reported as the same failure.

`.github/hardening-policy.json` now declares the exact administration-only readbacks: CodeQL default-setup administration state, repository Actions execution policy, and default workflow-token policy. If the scheduled token cannot read one of those, the audit emits `MANUAL_UNVERIFIED`: visible evidence that the control was **not** live-proven, but not false evidence of repository drift. An unexpected readback failure anywhere outside that explicit inventory remains fatal.

The scheduled detector does not receive a permanent administration PAT. Exact merge/exit audits may still use a scoped admin-read credential to convert those manual controls into authoritative live proof.

The owned drift issue now also has a complete lifecycle: a non-clean detector creates/reopens/updates it, while a later clean detector records recovery and closes it. Static policy validation and a negative fixture prevent either the manual-readback inventory or recovery-close path from silently disappearing.

## Exit criteria

- exact final PR HEAD passes `Merge Gate`, with all five internal validation components successful;
- actionlint and zizmor both pass the real workflows and fail the negative control;
- Dependency Review behavior is observed and its live prerequisite is classified;
- hardening audit remains able to detect repository-policy drift;
- merged-main evidence is read back before closure;
- issue-label backlog reconciliation is reviewed in dry-run before any live bulk mutation;
- runtime/device evidence remains governed exclusively by its existing ADR/task proof gates.

`UNKNOWN`, `UNVERIFIED`, and `INSUFFICIENT EVIDENCE` remain FAIL for claimed controls.
