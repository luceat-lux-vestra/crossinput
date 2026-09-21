# Hardening Reassessment — 2026-09-20

Owning issue: #158

This pass re-evaluates CrossInput's existing repository hardening against current external GitHub/OpenSSF guidance. It deliberately does not change or reinterpret physical-device evidence obligations owned by the runtime architecture work.

## Existing controls retained

- checked-in hardening policy plus live drift readback;
- strict required-context producer validation;
- full-SHA action pins and least-privilege workflow checks;
- trusted issue/PR metadata automation;
- custom CodeQL authority for Actions, Python, and Swift; Java/Kotlin is an explicit temporary capability exception tracked by #157;
- protected-main and immutable publication-tag intent.

## PASS — dependency admission

Dependabot proposes dependency updates, but proposal automation is not PR-time admission control.

PR #159 proved `Dependency Review` on the exact candidate after live Dependency Graph enablement. PR #186 promoted the checked-in required-context contract, and authoritative 2026-09-22 readback confirmed live ruleset `21739720` requires `Dependency Review` with GitHub Actions integration id `15368` and no bypass actors.

Dependency Review is PR-diff-scoped and therefore has no merged-main execution proof; its post-promotion proof is checked-in/live policy reconciliation.

## GAP — workflow semantic/security scanners

The repository-owned policy checker already catches pinning, permissions, required-producer drift, unsafe privileged checkout, persisted credentials, and selected shell-injection risks. It does not replace a real GitHub Actions parser or an independent workflow-security scanner.

`scripts/check-actions-security.sh` now adds:

- checksum-pinned actionlint 1.7.12;
- checksum-pinned zizmor 1.30.0;
- full active-workflow scans;
- an adversarial negative fixture that both tools must reject for the expected reason.

The script runs inside the already-required `Evidence & Tooling Validation` context and the recurring hardening audit. No extra required context or ruleset churn is introduced.

## PARTIAL — CodeQL; Java/Kotlin capability exception

The custom CodeQL authority remains singular and uses only the pinned official `github/codeql-action` managed bundle.

Actions, Python, and Swift analysis remain active. Exact run 35563677611 proved that the stable CodeQL CLI 2.27.0 bundled by `github/codeql-action` v4.38.1 rejects the maintained Kotlin 2.4.20 compiler path as too recent. The Java/Kotlin leg is therefore temporarily removed rather than made green with the previously used third-party nightly tools override.

This is not a claim that Java/Kotlin source is security-scanned by CodeQL. Android Helper Build + Test remains the authoritative product gate for that surface. Issue #157 is the explicit reassessment trigger: restore Java/Kotlin only when the stable action-managed bundle accepts Kotlin 2.4.20 and exact-head extraction, analysis, and upload all succeed.

The repository policy rejects any future external `tools:` override. Kotlin will not be downgraded solely to satisfy an advisory scanner, and default setup will not be enabled alongside the custom workflow.

## Metadata

Existing issue-label automation remains in place. This reassessment does not create another taxonomy or classifier.

A follow-up quality review found that the legacy manual `workflow_dispatch` path treated dispatch itself as permission to mutate every open issue. That is weaker than the repository's current fail-closed bulk-operation standard.

The reconciler now requires two independent operator decisions:

- `backfill=false` by default, so an ordinary manual dispatch is a no-op;
- `dry_run=true` by default, so even an explicitly selected backlog pass reports changes before mutation.

Dry-run covers the complete mutation boundary: it cannot create/update the canonical label catalog, remove conflicting type labels, or add issue labels. The required repository policy checker has adversarial fixtures that independently break the backfill opt-in, dry-run default, issue-mutation guard, and label-catalog guard and requires each mutation to fail CI.

## Exit criteria

- exact final PR HEAD passes all existing required contexts;
- actionlint and zizmor both pass the real workflows and fail the negative control;
- Dependency Review behavior is observed and its live prerequisite is classified;
- hardening audit remains able to detect repository-policy drift;
- merged-main evidence is read back before closure;
- issue-label backlog reconciliation is reviewed in dry-run before any live bulk mutation;
- runtime/device evidence remains governed exclusively by its existing ADR/task proof gates.

`UNKNOWN`, `UNVERIFIED`, and `INSUFFICIENT EVIDENCE` remain FAIL for claimed controls.
