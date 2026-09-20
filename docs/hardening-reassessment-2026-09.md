# Hardening Reassessment — 2026-09-20

Owning issue: #158

This pass re-evaluates CrossInput's existing repository hardening against current external GitHub/OpenSSF guidance. It deliberately does not change or reinterpret physical-device evidence obligations owned by the runtime architecture work.

## Existing controls retained

- checked-in hardening policy plus live drift readback;
- strict required-context producer validation;
- full-SHA action pins and least-privilege workflow checks;
- trusted issue/PR metadata automation;
- custom CodeQL for Actions, Java/Kotlin, Python, and Swift;
- protected-main and immutable publication-tag intent.

## GAP — dependency admission

Dependabot proposes dependency updates, but proposal automation is not PR-time admission control.

`Dependency Review` is added as a staged candidate. It is not inserted into the live required-context ruleset in this change. Promotion requires:

1. ordinary-PR reliability;
2. live Dependency Graph support;
3. one atomic checked-in policy + live ruleset update;
4. fresh authoritative post-merge policy/ruleset readback.

Dependency Review is PR-diff-scoped and therefore has no merged-main execution proof.

## GAP — workflow semantic/security scanners

The repository-owned policy checker already catches pinning, permissions, required-producer drift, unsafe privileged checkout, persisted credentials, and selected shell-injection risks. It does not replace a real GitHub Actions parser or an independent workflow-security scanner.

`scripts/check-actions-security.sh` now adds:

- checksum-pinned actionlint 1.7.12;
- checksum-pinned zizmor 1.30.0;
- full active-workflow scans;
- an adversarial negative fixture that both tools must reject for the expected reason.

The script runs inside the already-required `Evidence & Tooling Validation` context and the recurring hardening audit. No extra required context or ruleset churn is introduced.

## PASS — CodeQL

The existing custom CodeQL authority already covers the security-relevant languages in this repository: Actions, Java/Kotlin, Python, and Swift. No second CodeQL authority is added.

## Metadata

Existing issue-label automation remains in place. This reassessment does not create another taxonomy or classifier.

## Exit criteria

- exact final PR HEAD passes all existing required contexts;
- actionlint and zizmor both pass the real workflows and fail the negative control;
- Dependency Review behavior is observed and its live prerequisite is classified;
- hardening audit remains able to detect repository-policy drift;
- merged-main evidence is read back before closure;
- runtime/device evidence remains governed exclusively by its existing ADR/task proof gates.

`UNKNOWN`, `UNVERIFIED`, and `INSUFFICIENT EVIDENCE` remain FAIL for claimed controls.
