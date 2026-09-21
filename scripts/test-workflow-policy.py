#!/usr/bin/env python3
"""Negative fixtures for scripts/check-workflow-policy.py.

Each case mutates a throwaway copy of the real `.github/` tree and asserts the
gate turns red with the expected finding code. A gate that cannot be made to
fail is not a gate, so the unmutated tree must also pass. Run:

    python3 scripts/test-workflow-policy.py

Exit 0 = all fixtures pass.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CHECKER = os.path.join(HERE, "check-workflow-policy.py")

FAILURES = []


def run_checker(root):
    completed = subprocess.run(
        [sys.executable, CHECKER, "--root", root],
        capture_output=True, text=True, check=False)
    return completed.returncode, completed.stdout + completed.stderr


def workflow(root, name):
    return os.path.join(root, ".github", "workflows", name)


def edit(path, old, new, count=1):
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    if old not in text:
        raise AssertionError(f"fixture anchor not found in {path}: {old!r}")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text.replace(old, new, count))


def case(name, mutate, expect_code):
    """Apply `mutate` to a copy of .github/ and require `expect_code`."""
    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.join(tmp, "repo")
        os.makedirs(root)
        shutil.copytree(os.path.join(ROOT, ".github"), os.path.join(root, ".github"))
        mutate(root)
        status, output = run_checker(root)
        if status != 1:
            FAILURES.append(f"{name}: expected exit 1, got {status}\n{output}")
        elif expect_code not in output:
            FAILURES.append(f"{name}: expected finding {expect_code}, got:\n{output}")
        else:
            print(f"  ok  {name} -> {expect_code}")


def baseline():
    status, output = run_checker(ROOT)
    if status != 0:
        FAILURES.append(f"baseline: real .github/ must pass, got exit {status}\n{output}")
    else:
        print("  ok  baseline (real .github/ passes)")


def policy_edit(root, mutate):
    path = os.path.join(root, ".github", "hardening-policy.json")
    with open(path, "r", encoding="utf-8") as handle:
        policy = json.load(handle)
    mutate(policy)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(policy, handle, indent=2)


def run_embedded_failure_triage(body):
    path = workflow(ROOT, "failure-triage.yml")
    with open(path, "r", encoding="utf-8") as handle:
        lines = handle.read().splitlines()

    try:
        start = next(i for i, line in enumerate(lines) if line.strip() == "python3 - <<'PY'")
        end = next(i for i, line in enumerate(lines[start + 1:], start + 1)
                   if line.strip() == "PY")
    except StopIteration as error:
        raise AssertionError("failure-triage embedded Python heredoc not found") from error

    script = textwrap.dedent("\n".join(lines[start + 1:end])) + "\n"
    env = os.environ.copy()
    env.update({
        "PR_BODY": body,
        "PR_AUTHOR_TYPE": "User",
        "PR_AUTHOR_LOGIN": "luceat-lux-vestra",
    })
    completed = subprocess.run(
        [sys.executable, "-c", script],
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )
    return completed.returncode, completed.stdout + completed.stderr


def embedded_failure_triage_baseline():
    body = """<!-- failure-triage:v1:start -->
## Failure remediation

- [x] Not remediation for an observed failure
- [ ] Remediation for an observed failure

Observed:
<!-- not applicable -->

Classification:
<!-- not applicable -->

Basis:
<!-- not applicable -->

Root cause:
<!-- not applicable -->

Remediation:
<!-- not applicable -->

Proof:
<!-- candidate-side semantic execution of the embedded validator -->
<!-- failure-triage:v1:end -->"""
    status, output = run_embedded_failure_triage(body)
    if status != 0:
        FAILURES.append(
            "embedded failure-triage validator: expected exit 0 for valid "
            f"non-remediation body, got {status}\n{output}"
        )
    else:
        print("  ok  embedded failure-triage validator self-tests execute")


def main():
    baseline()
    embedded_failure_triage_baseline()

    # A required producer is renamed: the ruleset context would simply never be
    # reported again and the PR would sit "expected" forever - or, worse, the
    # context is dropped from the ruleset later to unblock it.
    case("renamed required producer",
         lambda root: edit(workflow(root, "ci.yml"),
                           "name: Documentation Validation",
                           "name: Docs Validation"),
         "GATE_NAME_DRIFT")

    # The producing job is deleted outright.
    case("missing required producer",
         lambda root: edit(workflow(root, "ci.yml"),
                           "  markdown:\n    name: Documentation Validation\n",
                           "  markdown-removed:\n    name: Documentation Validation\n"),
         "GATE_MISSING_JOB")

    # The policy still demands a context nothing produces any more.
    case("stale policy entry",
         lambda root: policy_edit(root, lambda policy: policy["required_status_checks"].append(
             {"context": "Ghost Check", "workflow": "ci.yml", "job": "ghost"})),
         "GATE_MISSING_JOB")

    case("missing staged producer",
         lambda root: policy_edit(root, lambda policy: policy.setdefault("staged_status_checks", []).append(
             {"context": "Ghost Staged Check", "workflow": "dependency-review.yml", "job": "missing-staged"})),
         "GATE_MISSING_JOB")

    # Path filters are the classic silent fail-open: the check never starts, so
    # it never turns red, and a strict ruleset can still be satisfied.
    case("path filter on required workflow",
         lambda root: edit(workflow(root, "ci.yml"),
                           "  pull_request:\n",
                           "  pull_request:\n    paths:\n      - 'apps/**'\n"),
         "GATE_PATH_FILTER")

    # A skipped job reports success to a required check.
    case("condition on required job",
         lambda root: edit(workflow(root, "ci.yml"),
                           "  markdown:\n    name: Documentation Validation\n",
                           "  markdown:\n    name: Documentation Validation\n"
                           "    if: github.actor != 'dependabot[bot]'\n"),
         "GATE_CONDITIONAL")

    case("pull_request_target outside audited failure triage",
         lambda root: policy_edit(
             root,
             lambda policy: policy["required_status_checks"][0].update(
                 {"trigger": "pull_request_target"})),
         "GATE_TARGET_TRIGGER_SCOPE")

    case("unexpected condition on required failure triage",
         lambda root: edit(
             workflow(root, "failure-triage.yml"),
             "    if: github.repository == 'luceat-lux-vestra/crossinput'\n",
             "    if: github.actor != 'dependabot[bot]'\n"),
         "GATE_CONDITIONAL")

    case("continue-on-error on required job",
         lambda root: edit(workflow(root, "ci.yml"),
                           "  markdown:\n    name: Documentation Validation\n",
                           "  markdown:\n    name: Documentation Validation\n"
                           "    continue-on-error: true\n"),
         "GATE_FAIL_OPEN")

    # Mutable action reference.
    case("mutable action ref",
         lambda root: edit(workflow(root, "ci.yml"),
                           "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1",
                           "actions/checkout@v7"),
         "ACTION_NOT_PINNED")

    case("branch-pinned action ref",
         lambda root: edit(workflow(root, "ci.yml"),
                           "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1",
                           "actions/checkout@main"),
         "ACTION_NOT_PINNED")

    # Workflow-wide write permission instead of a job-scoped one.
    case("top-level write permission",
         lambda root: edit(workflow(root, "ci.yml"),
                           "permissions:\n  contents: read\n",
                           "permissions:\n  contents: write\n"),
         "PERM_TOP_LEVEL_WRITE")

    case("undeclared job write permission",
         lambda root: edit(workflow(root, "ci.yml"),
                           "  markdown:\n    name: Documentation Validation\n",
                           "  markdown:\n    name: Documentation Validation\n"
                           "    permissions:\n      contents: write\n"),
         "PERM_UNDECLARED_WRITE")

    # Trust boundary: fork-controlled code executed by a privileged trigger.
    case("pull_request_target checks out code",
         lambda root: edit(workflow(root, "pr-labeler.yml"),
                           "    steps:\n",
                           "    steps:\n"
                           "      - uses: actions/checkout"
                           "@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
                           "        with:\n"
                           "          persist-credentials: false\n"
                           "          ref: ${{ github.event.pull_request.head.sha }}\n"),
         "TRUST_PRT_CHECKOUT")

    case("pull_request_target branch scope drift",
         lambda root: edit(workflow(root, "pr-labeler.yml"),
                           "    branches: [main]\n",
                           "    branches: [release]\n"),
         "TRUST_PRT_SCOPE")

    case("pull_request_target repository guard removed",
         lambda root: edit(workflow(root, "pr-labeler.yml"),
                           "    if: github.repository == 'luceat-lux-vestra/crossinput'\n",
                           ""),
         "TRUST_PRT_SCOPE")

    # Attacker-controlled text interpolated into shell.
    case("shell injection from PR title",
         lambda root: edit(workflow(root, "ci.yml"),
                           '      - name: "bash -n"\n        run: |\n',
                           '      - name: "bash -n"\n        run: |\n'
                           '          echo "${{ github.event.pull_request.title }}"\n'),
         "TRUST_SHELL_INJECTION")

    case("checkout persists credentials",
         lambda root: edit(workflow(root, "ci.yml"),
                           "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
                           "        with:\n          persist-credentials: false\n",
                           "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"),
         "TRUST_PERSISTED_CREDENTIALS")

    case("job without timeout",
         lambda root: edit(workflow(root, "ci.yml"),
                           "    runs-on: ubuntu-latest\n    timeout-minutes: 10\n",
                           "    runs-on: ubuntu-latest\n"),
         "HYGIENE_NO_TIMEOUT")

    # Automation referencing a label nothing guarantees exists.
    case("labeler references unmanaged label",
         lambda root: edit(os.path.join(root, ".github", "labeler.yml"),
                           "area/docs:\n", "area/nonexistent:\n"),
         "LABEL_UNMANAGED")

    case("issue form references unmanaged label",
         lambda root: edit(os.path.join(root, ".github", "ISSUE_TEMPLATE", "bug_report.md"),
                           "labels: type/bug", "labels: type/gone"),
         "LABEL_UNMANAGED")

    # Manual issue backlog reconciliation is destructive metadata automation;
    # prove that its safe defaults and dry-run guards cannot silently regress.
    case("issue backfill requires explicit opt-in",
         lambda root: edit(
             workflow(root, "issue-labeler.yml"),
             "backfill:\n        description: Reconcile all open issues\n"
             "        required: true\n        default: false\n",
             "backfill:\n        description: Reconcile all open issues\n"
             "        required: true\n        default: true\n"),
         "LABEL_BACKFILL_POLICY")

    case("issue backfill defaults to dry-run",
         lambda root: edit(
             workflow(root, "issue-labeler.yml"),
             "dry_run:\n        description: Report intended changes without mutating labels or issues\n"
             "        required: true\n        default: true\n",
             "dry_run:\n        description: Report intended changes without mutating labels or issues\n"
             "        required: true\n        default: false\n"),
         "LABEL_BACKFILL_POLICY")

    case("issue dry-run blocks issue mutation",
         lambda root: edit(workflow(root, "issue-labeler.yml"),
                           "              if (dryRun) return;\n",
                           "              if (false) return;\n"),
         "LABEL_DRYRUN_MUTATION")

    case("issue dry-run blocks label catalog mutation",
         lambda root: edit(workflow(root, "issue-labeler.yml"),
                           "              if (!dryRun) await ensureLabels();\n",
                           "              await ensureLabels();\n"),
         "LABEL_CATALOG_GUARD")
    case("issue body inference is forbidden",
         lambda root: edit(
             workflow(root, "issue-labeler.yml"),
             '            const { reconcileIssue } = require("./scripts/issue-metadata.cjs");\n',
             '            const { reconcileIssue } = require("./scripts/issue-metadata.cjs");\n'
             '            const body = (context.payload.issue.body || "").toLowerCase();\n'),
         "LABEL_BODY_INFERENCE")

    case("mutating issue backfill requires default-branch guard",
         lambda root: edit(
             workflow(root, "issue-labeler.yml"),
             '              core.setFailed(`Mutating backfill must run from ${defaultBranchRef}; got ${context.ref}`);\n',
             '              core.setFailed(`Mutating bulk operation rejected`);\n'),
         "LABEL_DEFAULT_BRANCH_GUARD")


    # Release provenance is a security contract, not documentation. Mutations
    # must turn the already-required Evidence & Tooling Validation context red.
    case("release recovery must run from exact tag ref",
         lambda root: edit(
             workflow(root, "release.yml"),
             '          expected_ref="refs/tags/${RELEASE_TAG}"\n',
             ''),
         "RELEASE_REF_GUARD")

    case("release attestation action cannot disappear",
         lambda root: edit(
             workflow(root, "release.yml"),
             "      - name: Attest verified DMG build provenance\n",
             "      - name: Removed provenance step\n"),
         "RELEASE_ATTESTATION")

    case("release attestation must precede publication",
         lambda root: edit(
             workflow(root, "release.yml"),
             "      - name: Attest verified DMG build provenance\n",
             "      - name: Create or refresh GitHub Release\n"
             "        if: ${{ false }}\n"
             "        run: echo negative-fixture\n\n"
             "      - name: Attest verified DMG build provenance\n"),
         "RELEASE_ATTESTATION_ORDER")

    case("release attestation permissions cannot be removed",
         lambda root: edit(
             workflow(root, "release.yml"),
             "      attestations: write\n",
             "      attestations: read\n"),
         "RELEASE_ATTESTATION_PERMISSION")

    # CodeQL authority: both a custom workflow and a default-setup policy.
    case("codeql dual authority",
         lambda root: policy_edit(
             root, lambda policy: policy.update({"codeql_authority": "default-setup"})),
         "CODEQL_AUTHORITY")

    case("CodeQL external tools override",
         lambda root: edit(workflow(root, "codeql.yml"),
                           "          build-mode: ${{ matrix.build-mode }}\n",
                           "          build-mode: ${{ matrix.build-mode }}\n"
                           "          tools: https://example.invalid/codeql-bundle.tar.zst\n"),
         "CODEQL_TOOLS_OVERRIDE")

    # An unparsable workflow must abort the audit (exit 2), never pass quietly.
    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.join(tmp, "repo")
        os.makedirs(root)
        shutil.copytree(os.path.join(ROOT, ".github"), os.path.join(root, ".github"))
        with open(workflow(root, "broken.yml"), "w", encoding="utf-8") as handle:
            handle.write("name: broken\nbase: &anchor\n  a: 1\ncopy: *anchor\n")
        status, output = run_checker(root)
        if status != 2 or "AUDIT ABORTED" not in output:
            FAILURES.append(f"unparsable workflow: expected exit 2 + abort, got {status}\n{output}")
        else:
            print("  ok  unparsable workflow -> AUDIT ABORTED")

    if FAILURES:
        print("\nFAILURES:")
        for failure in FAILURES:
            print(f"- {failure}")
        return 1
    print("\nall workflow-policy fixtures passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
