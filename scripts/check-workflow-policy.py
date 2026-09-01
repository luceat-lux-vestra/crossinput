#!/usr/bin/env python3
"""Repository hardening gate: workflows vs. `.github/hardening-policy.json`.

Static mode (default, offline) answers "can a required gate silently vanish or
fail open, and is every workflow pinned and least-privilege?".

    python3 scripts/check-workflow-policy.py

Live mode additionally reads the actual GitHub configuration through `gh` and
compares it with the same policy file.

    python3 scripts/check-workflow-policy.py --live

Exit codes: 0 = no findings, 1 = findings, 2 = the audit itself could not run
(unparsable workflow, missing policy). Live readbacks that cannot be performed
are reported as SKIPPED findings rather than being treated as a pass; use
--allow-live-skip to keep those non-fatal.
"""

import argparse
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))

import workflow_yaml  # noqa: E402

SHA_PINNED = re.compile(r"^[\w.-]+/[\w./-]+@[0-9a-f]{40}$")
LABEL_DEF = re.compile(r"\[\s*'([A-Za-z0-9/_-]+)'\s*,\s*'[0-9A-Fa-f]{6}'")
FRONT_MATTER_LABELS = re.compile(r"^labels:\s*(.+)$", re.MULTILINE)
# Contexts that carry attacker-influenced text straight into an expression.
UNTRUSTED_EXPRESSION = re.compile(
    r"\$\{\{\s*(github\.event\.|github\.head_ref|inputs\.|github\.actor|env\.GITHUB_HEAD_REF)"
)
READ_ONLY_PERMISSIONS = {"read", "none", None}


class Findings:
    def __init__(self):
        self.items = []

    def add(self, code, where, message):
        self.items.append((code, where, message))

    def skip(self, where, message):
        self.items.append(("SKIPPED", where, message))

    @property
    def fatal(self):
        return [item for item in self.items if item[0] != "SKIPPED"]


def load_workflows(root):
    directory = os.path.join(root, ".github", "workflows")
    workflows = {}
    for name in sorted(os.listdir(directory)):
        if not name.endswith((".yml", ".yaml")):
            continue
        path = os.path.join(directory, name)
        try:
            workflows[name] = workflow_yaml.load_file(path)
        except workflow_yaml.WorkflowYamlError as error:
            print(f"AUDIT ABORTED: {path}: {error}", file=sys.stderr)
            raise SystemExit(2)
    return workflows


def triggers(workflow):
    on = workflow.get("on")
    if isinstance(on, dict):
        return on
    if isinstance(on, list):
        return {key: None for key in on}
    if isinstance(on, str):
        return {on: None}
    return {}


def steps_of(job):
    return job.get("steps") or []


def check_required_gates(workflows, policy, findings):
    """Contexts <-> producing jobs, and no way for a producer to disappear."""
    seen = set()
    for entry in policy["required_status_checks"]:
        context, filename, job_id = entry["context"], entry["workflow"], entry["job"]
        where = f"{filename}:{job_id}"
        if context in seen:
            findings.add("GATE_DUPLICATE", where, f"duplicate required context {context!r}")
        seen.add(context)

        workflow = workflows.get(filename)
        if workflow is None:
            findings.add("GATE_MISSING_WORKFLOW", where,
                         f"required context {context!r} has no producing workflow {filename}")
            continue
        jobs = workflow.get("jobs") or {}
        job = jobs.get(job_id)
        if job is None:
            findings.add("GATE_MISSING_JOB", where,
                         f"required context {context!r} has no producing job {job_id!r}")
            continue
        if job.get("name") != context:
            findings.add("GATE_NAME_DRIFT", where,
                         f"job name {job.get('name')!r} no longer produces required context "
                         f"{context!r}; the ruleset check would never report")

        on = triggers(workflow)
        pull_request = on.get("pull_request", None)
        if "pull_request" not in on:
            findings.add("GATE_NOT_ON_PR", where,
                         f"{filename} does not run on pull_request; the required context "
                         f"would never be reported")
        elif isinstance(pull_request, dict):
            for filter_key in ("paths", "paths-ignore"):
                if filter_key in pull_request:
                    findings.add("GATE_PATH_FILTER", where,
                                 f"{filename} pull_request has a {filter_key} filter; the required "
                                 f"context can silently never start on some PRs")
            if "branches-ignore" in pull_request:
                findings.add("GATE_BRANCH_FILTER", where,
                             f"{filename} pull_request uses branches-ignore")
            branches = pull_request.get("branches")
            if branches is not None and policy["protected_branch"] not in branches:
                findings.add("GATE_BRANCH_FILTER", where,
                             f"{filename} pull_request branches {branches} exclude "
                             f"{policy['protected_branch']!r}")

        if job.get("if") is not None:
            findings.add("GATE_CONDITIONAL", where,
                         f"required job has an `if:` condition and can be skipped "
                         f"(a skipped required check never turns red)")
        if job.get("continue-on-error"):
            findings.add("GATE_FAIL_OPEN", where, "required job sets continue-on-error")
        for step in steps_of(job):
            if isinstance(step, dict) and step.get("continue-on-error"):
                findings.add("GATE_FAIL_OPEN", where,
                             f"step {step.get('name') or step.get('uses')!r} sets continue-on-error")

    # Stale/duplicate producers: a job that emits a required context but is not
    # the one the policy points at is a rename waiting to break the ruleset.
    declared = {(entry["workflow"], entry["job"]): entry["context"]
                for entry in policy["required_status_checks"]}
    contexts = set(declared.values())
    for filename, workflow in workflows.items():
        for job_id, job in (workflow.get("jobs") or {}).items():
            name = job.get("name")
            if name in contexts and declared.get((filename, job_id)) != name:
                findings.add("GATE_UNDECLARED_PRODUCER", f"{filename}:{job_id}",
                             f"job also produces required context {name!r} but is not the "
                             f"declared producer in .github/hardening-policy.json")


def check_action_pins(workflows, findings):
    for filename, workflow in workflows.items():
        for job_id, job in (workflow.get("jobs") or {}).items():
            for step in steps_of(job):
                if not isinstance(step, dict):
                    continue
                uses = step.get("uses")
                if uses is None or uses.startswith(("./", "docker://")):
                    continue
                if not SHA_PINNED.match(uses):
                    findings.add("ACTION_NOT_PINNED", f"{filename}:{job_id}",
                                 f"`uses: {uses}` is not pinned to a full 40-character commit SHA")


def check_permissions(workflows, policy, findings):
    allowed = policy["workflows_allowed_write_permissions"]
    observed = {}
    for filename, workflow in workflows.items():
        top = workflow.get("permissions")
        if top is None:
            findings.add("PERM_MISSING", filename,
                         "workflow does not declare top-level `permissions:`")
        elif isinstance(top, str):
            findings.add("PERM_TOP_LEVEL_WRITE", filename,
                         f"top-level `permissions: {top}` is not least-privilege")
        else:
            for scope, value in top.items():
                if value not in READ_ONLY_PERMISSIONS:
                    findings.add("PERM_TOP_LEVEL_WRITE", filename,
                                 f"top-level permission {scope}: {value} must be job-scoped")

        writes = set()
        for job_id, job in (workflow.get("jobs") or {}).items():
            job_permissions = job.get("permissions")
            if isinstance(job_permissions, str):
                findings.add("PERM_JOB_BROAD", f"{filename}:{job_id}",
                             f"`permissions: {job_permissions}` is not least-privilege")
                continue
            for scope, value in (job_permissions or {}).items():
                if value in READ_ONLY_PERMISSIONS:
                    continue
                writes.add(scope)
                if scope not in allowed.get(filename, []):
                    findings.add("PERM_UNDECLARED_WRITE", f"{filename}:{job_id}",
                                 f"write permission {scope}: {value} is not declared in "
                                 f".github/hardening-policy.json")
        observed[filename] = writes

    for filename, scopes in allowed.items():
        if filename not in workflows:
            findings.add("PERM_POLICY_STALE", filename,
                         "policy allows write permissions for a workflow that no longer exists")
            continue
        for scope in scopes:
            if scope not in observed.get(filename, set()):
                findings.add("PERM_POLICY_STALE", filename,
                             f"policy allows unused write permission {scope!r}")


def check_trust_boundaries(workflows, findings):
    for filename, workflow in workflows.items():
        privileged = "pull_request_target" in triggers(workflow)
        for job_id, job in (workflow.get("jobs") or {}).items():
            where = f"{filename}:{job_id}"
            for step in steps_of(job):
                if not isinstance(step, dict):
                    continue
                uses = step.get("uses") or ""
                if privileged and uses.startswith("actions/checkout@"):
                    findings.add("TRUST_PRT_CHECKOUT", where,
                                 "pull_request_target workflow checks out a ref; fork-controlled "
                                 "code must never run with the privileged token")
                run = step.get("run")
                if isinstance(run, str) and UNTRUSTED_EXPRESSION.search(run):
                    match = UNTRUSTED_EXPRESSION.search(run).group(0)
                    findings.add("TRUST_SHELL_INJECTION", where,
                                 f"`run:` interpolates {match}...; pass it through `env:` instead")
                if uses.startswith("actions/checkout@"):
                    with_block = step.get("with") or {}
                    ref = with_block.get("ref")
                    if isinstance(ref, str) and UNTRUSTED_EXPRESSION.search(ref) and privileged:
                        findings.add("TRUST_PRT_CHECKOUT", where,
                                     f"checkout ref {ref!r} is attacker-controllable")
                    if with_block.get("persist-credentials") is not False:
                        findings.add("TRUST_PERSISTED_CREDENTIALS", where,
                                     "checkout leaves the job token in .git/config; set "
                                     "`persist-credentials: false` unless a later step pushes")


def check_hygiene(workflows, findings):
    for filename, workflow in workflows.items():
        if "concurrency" not in workflow:
            findings.add("HYGIENE_NO_CONCURRENCY", filename,
                         "workflow does not declare `concurrency:`")
        for job_id, job in (workflow.get("jobs") or {}).items():
            if job.get("timeout-minutes") is None:
                findings.add("HYGIENE_NO_TIMEOUT", f"{filename}:{job_id}",
                             "job does not declare `timeout-minutes:`")


def managed_labels(root):
    """Labels the labeler workflows create/maintain, i.e. guaranteed to exist."""
    names = set()
    for filename in ("issue-labeler.yml", "pr-labeler.yml"):
        path = os.path.join(root, ".github", "workflows", filename)
        if not os.path.exists(path):
            continue
        with open(path, "r", encoding="utf-8") as handle:
            names.update(LABEL_DEF.findall(handle.read()))
    return names


def check_labels(root, findings):
    managed = managed_labels(root)
    if not managed:
        findings.add("LABEL_NO_MANAGED_SET", ".github/workflows",
                     "no managed label definitions found; label drift cannot be checked")
        return

    labeler_path = os.path.join(root, ".github", "labeler.yml")
    if os.path.exists(labeler_path):
        for key, value in workflow_yaml.load_file(labeler_path).items():
            if not isinstance(value, list):
                continue  # labeler tuning knobs, not label keys
            if key not in managed:
                findings.add("LABEL_UNMANAGED", ".github/labeler.yml",
                             f"path rule applies label {key!r} that no workflow guarantees exists")

    template_dir = os.path.join(root, ".github", "ISSUE_TEMPLATE")
    if os.path.isdir(template_dir):
        for name in sorted(os.listdir(template_dir)):
            path = os.path.join(template_dir, name)
            if not os.path.isfile(path):
                continue
            with open(path, "r", encoding="utf-8") as handle:
                text = handle.read()
            for raw in FRONT_MATTER_LABELS.findall(text):
                raw = raw.strip()
                if raw.startswith("["):
                    raw = raw[1:-1]
                for label in [part.strip().strip("\"'") for part in raw.split(",")]:
                    if label and label not in managed:
                        findings.add("LABEL_UNMANAGED", f".github/ISSUE_TEMPLATE/{name}",
                                     f"issue form applies label {label!r} that no workflow "
                                     f"guarantees exists")

    dependabot_path = os.path.join(root, ".github", "dependabot.yml")
    if os.path.exists(dependabot_path):
        for update in workflow_yaml.load_file(dependabot_path).get("updates") or []:
            for label in update.get("labels") or []:
                if label not in managed:
                    findings.add("LABEL_UNMANAGED", ".github/dependabot.yml",
                                 f"dependabot applies label {label!r} that no workflow "
                                 f"guarantees exists")


def check_codeql_authority(root, workflows, policy, findings):
    """Static half of the single-authority rule; --live checks default setup."""
    authority = policy["codeql_authority"]
    has_custom = "codeql.yml" in workflows
    if authority == "custom-workflow" and not has_custom:
        findings.add("CODEQL_AUTHORITY", ".github/workflows",
                     "policy names the custom workflow as CodeQL authority but codeql.yml is gone")
    if authority == "default-setup" and has_custom:
        findings.add("CODEQL_AUTHORITY", ".github/workflows/codeql.yml",
                     "policy names default setup as CodeQL authority but a custom workflow "
                     "is also present; analysis would be duplicated")


def gh_api(path, findings, where):
    try:
        completed = subprocess.run(
            ["gh", "api", path], capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        findings.skip(where, f"live readback unavailable: {error}")
        return None
    if completed.returncode != 0:
        findings.skip(where, f"live readback failed ({completed.stderr.strip()[:200]})")
        return None
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        findings.skip(where, f"live readback returned non-JSON: {error}")
        return None


def check_live(repo, policy, findings):
    rulesets = gh_api(f"repos/{repo}/rulesets", findings, "rulesets")
    if rulesets is not None:
        branch = next((item for item in rulesets if item.get("target") == "branch"), None)
        tag = next((item for item in rulesets if item.get("target") == "tag"), None)
        _check_branch_ruleset(repo, branch, policy, findings)
        _check_tag_ruleset(repo, tag, policy, findings)

    default_setup = gh_api(f"repos/{repo}/code-scanning/default-setup", findings, "codeql")
    if default_setup is not None:
        state = default_setup.get("state")
        authority = policy["codeql_authority"]
        if authority == "custom-workflow" and state != "not-configured":
            findings.add("CODEQL_DUPLICATE_AUTHORITY", "code-scanning/default-setup",
                         f"default setup is {state!r} while the custom workflow is the declared "
                         f"authority; both would analyse the same code")
        if authority == "default-setup" and state != "configured":
            findings.add("CODEQL_AUTHORITY", "code-scanning/default-setup",
                         f"default setup is {state!r} but policy names it the authority")

    actions = gh_api(f"repos/{repo}/actions/permissions", findings, "actions/permissions")
    expected = policy["actions_policy"]
    if actions is not None and actions.get("sha_pinning_required") != expected["sha_pinning_required"]:
        findings.add("ACTIONS_POLICY_DRIFT", "actions/permissions",
                     f"sha_pinning_required={actions.get('sha_pinning_required')}, "
                     f"expected {expected['sha_pinning_required']}")

    workflow_permissions = gh_api(
        f"repos/{repo}/actions/permissions/workflow", findings, "actions/permissions/workflow")
    if workflow_permissions is not None:
        for key in ("default_workflow_permissions", "can_approve_pull_request_reviews"):
            if workflow_permissions.get(key) != expected[key]:
                findings.add("ACTIONS_POLICY_DRIFT", "actions/permissions/workflow",
                             f"{key}={workflow_permissions.get(key)}, expected {expected[key]}")


def _check_branch_ruleset(repo, summary, policy, findings):
    expected = policy["branch_ruleset"]
    if summary is None:
        findings.add("RULESET_MISSING", "rulesets",
                     f"no branch ruleset protects refs/heads/{policy['protected_branch']}")
        return
    ruleset = gh_api(f"repos/{repo}/rulesets/{summary['id']}", findings, "rulesets/branch")
    if ruleset is None:
        return
    where = f"ruleset {summary['id']}"
    if ruleset.get("enforcement") != expected["enforcement"]:
        findings.add("RULESET_DRIFT", where, f"enforcement={ruleset.get('enforcement')}")
    if ruleset.get("bypass_actors") and not expected["allow_bypass_actors"]:
        findings.add("RULESET_BYPASS", where,
                     f"{len(ruleset['bypass_actors'])} bypass actor(s) configured")
    includes = (ruleset.get("conditions") or {}).get("ref_name", {}).get("include") or []
    if f"refs/heads/{policy['protected_branch']}" not in includes:
        findings.add("RULESET_DRIFT", where, f"ref conditions {includes} no longer cover main")

    rules = {rule["type"]: rule.get("parameters") or {} for rule in ruleset.get("rules") or []}
    for rule_type in expected["required_rule_types"]:
        if rule_type not in rules:
            findings.add("RULESET_DRIFT", where, f"missing rule {rule_type!r}")

    pull_request = rules.get("pull_request") or {}
    if pull_request:
        if sorted(pull_request.get("allowed_merge_methods") or []) != sorted(
                expected["allowed_merge_methods"]):
            findings.add("RULESET_DRIFT", where,
                         f"allowed_merge_methods={pull_request.get('allowed_merge_methods')}")
        if pull_request.get("require_extra_approval_for_unattributed_changes") != expected[
                "require_extra_approval_for_unattributed_changes"]:
            findings.add("RULESET_DRIFT", where,
                         "require_extra_approval_for_unattributed_changes drifted")

    status_checks = rules.get("required_status_checks") or {}
    if status_checks:
        if status_checks.get("strict_required_status_checks_policy") != expected[
                "strict_required_status_checks_policy"]:
            findings.add("RULESET_DRIFT", where, "strict required status checks policy drifted")
        live = {check["context"] for check in status_checks.get("required_status_checks") or []}
        declared = {entry["context"] for entry in policy["required_status_checks"]}
        for context in sorted(declared - live):
            findings.add("RULESET_CHECK_MISSING", where,
                         f"required context {context!r} is declared in policy but not enforced")
        for context in sorted(live - declared):
            findings.add("RULESET_CHECK_STALE", where,
                         f"ruleset requires {context!r}, which no declared workflow job produces")


def _check_tag_ruleset(repo, summary, policy, findings):
    expected = policy["tag_ruleset"]
    if summary is None:
        findings.add("RULESET_MISSING", "rulesets",
                     f"no tag ruleset protects {expected['ref_pattern']}")
        return
    ruleset = gh_api(f"repos/{repo}/rulesets/{summary['id']}", findings, "rulesets/tag")
    if ruleset is None:
        return
    where = f"ruleset {summary['id']}"
    if ruleset.get("enforcement") != expected["enforcement"]:
        findings.add("RULESET_DRIFT", where, f"enforcement={ruleset.get('enforcement')}")
    if ruleset.get("bypass_actors") and not expected["allow_bypass_actors"]:
        findings.add("RULESET_BYPASS", where,
                     f"{len(ruleset['bypass_actors'])} bypass actor(s) configured")
    includes = (ruleset.get("conditions") or {}).get("ref_name", {}).get("include") or []
    if expected["ref_pattern"] not in includes:
        findings.add("RULESET_DRIFT", where, f"ref conditions {includes} no longer cover v* tags")
    rules = {rule["type"] for rule in ruleset.get("rules") or []}
    for rule_type in expected["required_rule_types"]:
        if rule_type not in rules:
            findings.add("RULESET_DRIFT", where, f"missing rule {rule_type!r}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))
    parser.add_argument("--live", action="store_true",
                        help="also read the live GitHub configuration through `gh`")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY",
                                                         "luceat-lux-vestra/crossinput"))
    parser.add_argument("--allow-live-skip", action="store_true",
                        help="treat unreachable live readbacks as reported-but-non-fatal")
    args = parser.parse_args()

    policy_path = os.path.join(args.root, ".github", "hardening-policy.json")
    try:
        with open(policy_path, "r", encoding="utf-8") as handle:
            policy = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        print(f"AUDIT ABORTED: cannot read {policy_path}: {error}", file=sys.stderr)
        return 2

    workflows = load_workflows(args.root)
    findings = Findings()

    check_required_gates(workflows, policy, findings)
    check_action_pins(workflows, findings)
    check_permissions(workflows, policy, findings)
    check_trust_boundaries(workflows, findings)
    check_hygiene(workflows, findings)
    check_labels(args.root, findings)
    check_codeql_authority(args.root, workflows, policy, findings)
    if args.live:
        check_live(args.repo, policy, findings)

    if not findings.items:
        print(f"hardening policy OK: {len(workflows)} workflow(s), "
              f"{len(policy['required_status_checks'])} required context(s)")
        return 0

    for code, where, message in findings.items:
        print(f"{code}: {where}: {message}")

    skipped = len(findings.items) - len(findings.fatal)
    if findings.fatal:
        print(f"\n{len(findings.fatal)} hardening finding(s), {skipped} skipped readback(s)",
              file=sys.stderr)
        return 1
    if skipped and not args.allow_live_skip:
        print(f"\n{skipped} live readback(s) could not be performed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
