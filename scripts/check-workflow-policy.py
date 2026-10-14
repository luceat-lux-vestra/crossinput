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

    def manual_unverified(self, where, message):
        self.items.append(("MANUAL_UNVERIFIED", where, message))

    @property
    def fatal(self):
        return [
            item for item in self.items
            if item[0] not in {"SKIPPED", "MANUAL_UNVERIFIED"}
        ]


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


def needs_of(job):
    value = job.get("needs")
    if isinstance(value, str):
        return {value}
    if isinstance(value, list):
        return set(value)
    return set()


def check_android_dependency_submission_contract(workflows, findings):
    """Keep Android dependency publication narrow, trusted, and cache read-only."""
    filename = "android-dependency-submission.yml"
    workflow = workflows.get(filename)
    if workflow is None:
        findings.add("ANDROID_DEPS_SUBMISSION", filename,
                     "missing protected-main Android dependency publisher")
        return

    events = triggers(workflow)
    push = events.get("push")
    expected_paths = {
        "android/helper/**/*.gradle*",
        "android/helper/**/gradle.properties",
        "android/helper/**/gradle-wrapper.properties",
        "android/helper/gradle/**",
        ".github/workflows/android-dependency-submission.yml",
    }
    actual_paths = (push or {}).get("paths") if isinstance(push, dict) else None
    if (
        not isinstance(push, dict)
        or push.get("branches") != ["main"]
        or not isinstance(actual_paths, list)
        or len(actual_paths) != len(expected_paths)
        or set(actual_paths) != expected_paths
        or "workflow_dispatch" not in events
        or "pull_request" in events
        or "pull_request_target" in events
    ):
        findings.add(
            "ANDROID_DEPS_SUBMISSION",
            filename,
            f"publisher trigger/input scope drift: push={push!r}, events={sorted(events)}",
        )

    submit = (workflow.get("jobs") or {}).get("submit") or {}
    if submit.get("if") != "${{ github.ref == 'refs/heads/main' }}":
        findings.add("ANDROID_DEPS_SUBMISSION", filename,
                     "publisher job must be fenced to refs/heads/main")
    if submit.get("permissions") != {"contents": "write"}:
        findings.add("ANDROID_DEPS_SUBMISSION", filename,
                     "publisher job must hold only contents: write")

    step = next(
        (step for step in steps_of(submit)
         if step.get("name") == "Generate and submit Android Gradle dependency graph"),
        None,
    )
    if not step:
        findings.add("ANDROID_DEPS_SUBMISSION", filename,
                     "missing Gradle dependency-submission step")
        return

    uses = step.get("uses") or ""
    if not uses.startswith("gradle/actions/dependency-submission@"):
        findings.add("ANDROID_DEPS_SUBMISSION", filename,
                     f"unexpected dependency publisher action: {uses!r}")

    inputs = step.get("with") or {}
    expected_inputs = {
        "build-root-directory": "android/helper",
        "dependency-graph": "generate-and-submit",
        "cache-read-only": True,
        "validate-wrappers": True,
    }
    for key, expected in expected_inputs.items():
        if inputs.get(key) != expected:
            findings.add(
                "ANDROID_DEPS_SUBMISSION",
                filename,
                f"{key} must be {expected!r}, got {inputs.get(key)!r}",
            )


def check_android_seed_contract(workflows, findings):
    """Only trusted main may write, and only real Gradle cache-key inputs seed."""
    filename = "android-cache-seed.yml"
    workflow = workflows.get(filename)
    if workflow is None:
        findings.add("ANDROID_SEED_INPUTS", filename, "missing trusted-main Android producer")
        return
    events = triggers(workflow)
    push = events.get("push")
    expected = {
        "android/helper/**/*.gradle*",
        "android/helper/**/gradle.properties",
        "android/helper/**/gradle-wrapper.properties",
        "android/helper/gradle/**",
        ".github/workflows/android-cache-seed.yml",
    }
    actual = (push or {}).get("paths") if isinstance(push, dict) else None
    if (
        not isinstance(actual, list)
        or len(actual) != len(expected)
        or set(actual) != expected
        or push.get("branches") != ["main"]
        or "workflow_dispatch" not in events
    ):
        findings.add("ANDROID_SEED_INPUTS", filename,
                     f"protected-main dependency input guard drift: paths={actual!r}")
    jobs = workflow.get("jobs") or {}
    seed = jobs.get("seed") or {}
    if seed.get("if") != "${{ github.ref == 'refs/heads/main' }}":
        findings.add("ANDROID_SEED_AUTHORITY", filename, "seed must write only on main")
    java = next((step for step in seed.get("steps", [])
                 if step.get("name") == "Seed architecture-matched Java 25 / Gradle caches"), {})
    with_input = java.get("with") or {}
    if with_input.get("cache-read-only") is not False:
        findings.add("ANDROID_SEED_AUTHORITY", filename,
                     "trusted-main producer must be the only explicit Android writer")


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

        components = entry.get("components") or []
        if components:
            expected_component_ids = {component["job"] for component in components}
            actual_needs = needs_of(job)
            if actual_needs != expected_component_ids:
                findings.add(
                    "GATE_AGGREGATE",
                    where,
                    f"aggregate needs {sorted(actual_needs)!r}, expected "
                    f"{sorted(expected_component_ids)!r}",
                )

            for component in components:
                component_id = component["job"]
                expected_name = component["name"]
                component_where = f"{filename}:{component_id}"
                component_job = jobs.get(component_id)
                if component_job is None:
                    findings.add("GATE_MISSING_JOB", component_where,
                                 "Merge Gate component job is missing")
                    continue
                if component_job.get("name") != expected_name:
                    findings.add(
                        "GATE_NAME_DRIFT",
                        component_where,
                        f"component name {component_job.get('name')!r}, expected {expected_name!r}",
                    )
                if component_job.get("if") is not None:
                    findings.add(
                        "GATE_CONDITIONAL",
                        component_where,
                        "Merge Gate component has a job-level if condition and can disappear",
                    )
                if component_job.get("continue-on-error"):
                    findings.add("GATE_FAIL_OPEN", component_where,
                                 "Merge Gate component sets continue-on-error")
                for step in steps_of(component_job):
                    if isinstance(step, dict) and step.get("continue-on-error"):
                        findings.add(
                            "GATE_FAIL_OPEN",
                            component_where,
                            f"step {step.get('name') or step.get('uses')!r} sets continue-on-error",
                        )

        trigger = entry.get("trigger", "pull_request")
        if trigger == "pull_request_target":
            findings.add("GATE_TARGET_TRIGGER_SCOPE", where,
                         "required status producers must use unprivileged pull_request")
            continue
        if trigger != "pull_request":
            findings.add("GATE_TRIGGER_UNSUPPORTED", where,
                         f"{filename} declares unsupported required trigger {trigger!r}")
            continue

        on = triggers(workflow)
        event_config = on.get(trigger)
        if trigger not in on:
            findings.add("GATE_NOT_ON_PR", where,
                         f"{filename} does not run on {trigger}; the required context "
                         f"would never be reported")
        elif isinstance(event_config, dict):
            for filter_key in ("paths", "paths-ignore"):
                if filter_key in event_config:
                    findings.add("GATE_PATH_FILTER", where,
                                 f"{filename} {trigger} has a {filter_key} filter; the required "
                                 f"context can silently never start on some PRs")
            if "branches-ignore" in event_config:
                findings.add("GATE_BRANCH_FILTER", where,
                             f"{filename} {trigger} uses branches-ignore")
            branches = event_config.get("branches")
            if branches is not None and policy["protected_branch"] not in branches:
                findings.add("GATE_BRANCH_FILTER", where,
                             f"{filename} {trigger} branches {branches} exclude "
                             f"{policy['protected_branch']!r}")

        condition = job.get("if")
        if components:
            normalized_condition = str(condition or "").strip()
            if normalized_condition not in {"${{ always() }}", "always()"}:
                findings.add(
                    "GATE_AGGREGATE",
                    where,
                    f"aggregate must use exact always(); got {normalized_condition!r}",
                )
        elif condition is not None:
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


def check_docs_only_fast_path(workflows, findings):
    """Keep the bounded documentation fast path narrow and fail-closed."""
    workflow = workflows.get("ci.yml")
    if workflow is None:
        findings.add("CI_SCOPE_POLICY", "ci.yml", "CI workflow is missing")
        return

    expected_exact = {"README.md", "CONTRIBUTING.md", "AGENTS.md"}
    expected_regex = 'test("^docs/.*[.]md$")'

    for job_id in ("macos-app", "android-helper"):
        job = (workflow.get("jobs") or {}).get(job_id)
        where = f"ci.yml:{job_id}"
        if job is None:
            findings.add("CI_SCOPE_POLICY", where, "docs-only product job is missing")
            continue

        steps = [step for step in steps_of(job) if isinstance(step, dict)]
        scope_steps = [step for step in steps if step.get("name") == "Detect documentation-only scope"]
        if len(scope_steps) != 1:
            findings.add("CI_SCOPE_POLICY", where,
                         "expected exactly one documentation-only scope detector")
            continue

        run = str(scope_steps[0].get("run") or "")
        exact_paths = set(re.findall(r'\. == "([^"]+)"', run))
        if exact_paths != expected_exact or expected_regex not in run:
            findings.add(
                "CI_SCOPE_POLICY",
                where,
                f"docs-only allowlist drifted: exact={sorted(exact_paths)!r}",
            )
        for fragment in (
            "gh api --paginate --slurp",
            "Could not establish the changed-file set; using full validation.",
            "Changed-file set is empty or unreadable; using full validation.",
            'echo "docs_only=false" >> "$GITHUB_OUTPUT"',
        ):
            if fragment not in run:
                findings.add("CI_SCOPE_POLICY", where,
                             f"scope detector lost fail-closed fragment {fragment!r}")

        placeholders = [step for step in steps
                        if step.get("name") == "Documentation-only fast path"]
        if len(placeholders) != 1 or "steps.scope.outputs.docs_only == 'true'" not in str(
                placeholders[0].get("if") if placeholders else ""):
            findings.add("CI_SCOPE_POLICY", where,
                         "documentation-only success placeholder is missing or conditional drifted")

        for step in steps:
            if step in scope_steps or step in placeholders:
                continue
            condition = str(step.get("if") or "")
            if "steps.scope.outputs.docs_only != 'true'" not in condition:
                findings.add(
                    "CI_SCOPE_POLICY",
                    where,
                    f"step {step.get('name') or step.get('uses')!r} is not guarded by full-validation scope",
                )


def check_staged_gates(workflows, policy, findings):
    staged = policy.get("staged_status_checks") or []
    if not staged:
        return
    staged_policy = dict(policy)
    staged_policy["required_status_checks"] = staged
    check_required_gates(workflows, staged_policy, findings)


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


def check_trust_boundaries(workflows, policy, findings):
    protected_branch = policy["protected_branch"]
    repository_full_name = policy["repository_full_name"]
    for filename, workflow in workflows.items():
        trigger_map = triggers(workflow)
        privileged = "pull_request_target" in trigger_map
        if privileged:
            config = trigger_map.get("pull_request_target")
            branches = config.get("branches") if isinstance(config, dict) else None
            if branches != [protected_branch]:
                findings.add(
                    "TRUST_PRT_SCOPE",
                    filename,
                    f"pull_request_target must be limited to {protected_branch!r}; got {branches!r}",
                )
        for job_id, job in (workflow.get("jobs") or {}).items():
            where = f"{filename}:{job_id}"
            if privileged:
                condition = str(job.get("if") or "")
                expected_guard = f"github.repository == '{repository_full_name}'"
                if expected_guard not in condition:
                    findings.add(
                        "TRUST_PRT_SCOPE",
                        where,
                        f"pull_request_target job must carry repository guard {expected_guard!r}",
                    )
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



def check_issue_labeler_safety(root, workflows, findings):
    workflow = workflows.get("issue-labeler.yml")
    if workflow is None:
        findings.add("LABEL_BACKFILL_POLICY", "issue-labeler.yml",
                     "issue label automation is missing")
        return

    dispatch = triggers(workflow).get("workflow_dispatch")
    inputs = dispatch.get("inputs") if isinstance(dispatch, dict) else None
    if not isinstance(inputs, dict):
        findings.add("LABEL_BACKFILL_POLICY", "issue-labeler.yml",
                     "workflow_dispatch must declare explicit backfill/dry_run inputs")
        return

    backfill = inputs.get("backfill")
    dry_run = inputs.get("dry_run")
    if not isinstance(backfill, dict) or backfill.get("default") is not False:
        findings.add("LABEL_BACKFILL_POLICY", "issue-labeler.yml",
                     "manual backlog mutation must require backfill=true explicitly")
    if not isinstance(dry_run, dict) or dry_run.get("default") is not True:
        findings.add("LABEL_BACKFILL_POLICY", "issue-labeler.yml",
                     "workflow_dispatch dry_run must default to true")

    job = (workflow.get("jobs") or {}).get("classify") or {}
    env = job.get("env") or {}
    if "inputs.dry_run" not in str(env.get("DRY_RUN") or ""):
        findings.add("LABEL_DRYRUN_ENV", "issue-labeler.yml:classify",
                     "DRY_RUN must derive from workflow_dispatch dry_run input")
    if "inputs.backfill" not in str(env.get("BACKFILL") or ""):
        findings.add("LABEL_BACKFILL_ENV", "issue-labeler.yml:classify",
                     "BACKFILL must derive from workflow_dispatch backfill input")

    path = os.path.join(root, ".github", "workflows", "issue-labeler.yml")
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()

    required = {
        "LABEL_DRYRUN_MUTATION": "if (dryRun) return;",
        "LABEL_CATALOG_GUARD": "if (!dryRun) await ensureLabels();",
        "LABEL_BACKFILL_GUARD": 'if (context.eventName === "workflow_dispatch" && backfill)',
        "LABEL_NOOP_NOTICE": "No backlog reconciliation selected; no label or issue mutation performed.",
        "LABEL_CLASSIFIER_MODULE": 'require("./scripts/issue-metadata.cjs")',
        "LABEL_DEFAULT_BRANCH_GUARD": "Mutating backfill must run from",
    }
    for code, fragment in required.items():
        if fragment not in text:
            findings.add(code, "issue-labeler.yml",
                         f"missing fail-safe issue-labeler contract fragment: {fragment}")

    if "issue.body" in text or "const body =" in text:
        findings.add("LABEL_BODY_INFERENCE", "issue-labeler.yml",
                     "issue body text must not be used as authoritative metadata classification input")

def check_codeql_authority(root, workflows, policy, findings):
    """Static half of the single-authority and trusted PR-scope contracts."""
    authority = policy["codeql_authority"]
    has_custom = "codeql.yml" in workflows
    if authority == "custom-workflow" and not has_custom:
        findings.add("CODEQL_AUTHORITY", ".github/workflows",
                     "policy names the custom workflow as CodeQL authority but codeql.yml is gone")
    if authority == "default-setup" and has_custom:
        findings.add("CODEQL_AUTHORITY", ".github/workflows/codeql.yml",
                     "policy names default setup as CodeQL authority but a custom workflow "
                     "is also present; analysis would be duplicated")

    if authority != "custom-workflow" or not has_custom:
        return

    workflow = workflows["codeql.yml"]
    jobs = workflow.get("jobs") or {}

    for job_id, job in jobs.items():
        for step in steps_of(job):
            if not isinstance(step, dict):
                continue
            uses = str(step.get("uses") or "")
            if uses.startswith("github/codeql-action/init@"):
                with_block = step.get("with") or {}
                if "tools" in with_block:
                    findings.add(
                        "CODEQL_TOOLS_OVERRIDE",
                        f"codeql.yml:{job_id}",
                        "custom CodeQL authority must use the bundle managed by the "
                        "pinned github/codeql-action; external tools overrides require "
                        "a separately reviewed supply-chain policy",
                    )

    coverage = policy.get("codeql_coverage") or {}
    expected_scope_policy = {
        "classifier": "scripts/codeql-scope.py",
        "trusted_base": True,
        "always_analyze": ["actions"],
        "fail_closed": True,
        "full_scan_paths": [
            ".github/workflows/codeql.yml",
            "scripts/codeql-scope.py",
            ".github/codeql/**",
        ],
    }
    if coverage.get("pr_language_scope") != expected_scope_policy:
        findings.add(
            "CODEQL_SCOPE_POLICY",
            ".github/hardening-policy.json",
            "CodeQL PR language-scope policy drifted from the trusted fail-closed contract",
        )

    scope = jobs.get("scope")
    analyze = jobs.get("analyze")
    if not isinstance(scope, dict) or not isinstance(analyze, dict):
        findings.add(
            "CODEQL_SCOPE_CONTRACT",
            ".github/workflows/codeql.yml",
            "CodeQL must retain both the trusted scope job and analyze matrix job",
        )
        return

    if scope.get("permissions") != {"contents": "read", "pull-requests": "read"}:
        findings.add(
            "CODEQL_SCOPE_CONTRACT",
            "codeql.yml:scope",
            "scope job must hold exactly contents:read and pull-requests:read",
        )

    expected_outputs = {
        "actions_impact": "${{ steps.scope.outputs.actions_impact }}",
        "swift_impact": "${{ steps.scope.outputs.swift_impact }}",
        "java_impact": "${{ steps.scope.outputs.java_impact }}",
        "python_impact": "${{ steps.scope.outputs.python_impact }}",
        "reason": "${{ steps.scope.outputs.reason }}",
    }
    if scope.get("outputs") != expected_outputs:
        findings.add(
            "CODEQL_SCOPE_CONTRACT",
            "codeql.yml:scope",
            "scope job outputs must expose every language impact plus the reason",
        )

    scope_steps = {step.get("id"): step for step in steps_of(scope) if isinstance(step, dict)}
    trusted = scope_steps.get("trusted_base")
    classifier = scope_steps.get("scope")
    if not isinstance(trusted, dict):
        findings.add(
            "CODEQL_SCOPE_CONTRACT", "codeql.yml:scope",
            "trusted-base checkout step is missing",
        )
    else:
        trusted_with = trusted.get("with") or {}
        if (
            trusted.get("continue-on-error") is not True
            or trusted_with.get("ref") != "${{ github.event.pull_request.base.sha }}"
            or trusted_with.get("path") != ".codeql-trusted-base"
            or trusted_with.get("persist-credentials") is not False
        ):
            findings.add(
                "CODEQL_SCOPE_CONTRACT",
                "codeql.yml:scope",
                "scope policy must be loaded from the immutable PR base with no persisted credentials",
            )

    if not isinstance(classifier, dict):
        findings.add(
            "CODEQL_SCOPE_CONTRACT", "codeql.yml:scope",
            "language-impact classifier step is missing",
        )
    else:
        run = str(classifier.get("run") or "")
        required = [
            'helper=".codeql-trusted-base/scripts/codeql-scope.py"',
            "gh api --paginate --slurp",
            'emit_full_scan "github-api-failure"',
            'emit_full_scan "trusted-base-helper-missing"',
            'emit_full_scan "trusted-base-helper-failure"',
        ]
        if any(fragment not in run for fragment in required):
            findings.add(
                "CODEQL_SCOPE_CONTRACT",
                "codeql.yml:scope",
                "classifier must use trusted-base policy and fail closed on missing or malformed evidence",
            )

    needs = analyze.get("needs")
    if needs != "scope" and not (isinstance(needs, list) and "scope" in needs):
        findings.add(
            "CODEQL_SCOPE_CONTRACT",
            "codeql.yml:analyze",
            "analyze job must depend on the trusted scope decision",
        )

    matrix = ((analyze.get("strategy") or {}).get("matrix") or {}).get("include") or []
    languages = [item.get("language") for item in matrix if isinstance(item, dict)]
    if languages != coverage.get("active_languages"):
        findings.add(
            "CODEQL_SCOPE_CONTRACT",
            "codeql.yml:analyze",
            f"CodeQL matrix languages drifted: {languages!r}",
        )

    analyze_steps = {
        step.get("name"): step
        for step in steps_of(analyze)
        if isinstance(step, dict) and step.get("name")
    }
    skip = analyze_steps.get("Trusted scope skip")
    if not isinstance(skip, dict):
        findings.add(
            "CODEQL_SCOPE_CONTRACT", "codeql.yml:analyze",
            "non-impacting languages must retain an explicit successful skip step",
        )
    else:
        skip_if = str(skip.get("if") or "")
        if not all(
            fragment in skip_if
            for fragment in (
                "needs.scope.outputs.java_impact != 'true'",
                "needs.scope.outputs.python_impact != 'true'",
                "needs.scope.outputs.swift_impact != 'true'",
            )
        ):
            findings.add(
                "CODEQL_SCOPE_CONTRACT",
                "codeql.yml:analyze",
                "skip step is not fenced by every heavy-language impact output",
            )

    for step_name in ("Checkout repository", "Initialize CodeQL", "Perform CodeQL Analysis"):
        step = analyze_steps.get(step_name)
        condition = str((step or {}).get("if") or "")
        if not isinstance(step, dict) or not all(
            fragment in condition
            for fragment in (
                "matrix.language == 'actions'",
                "needs.scope.outputs.java_impact == 'true'",
                "needs.scope.outputs.python_impact == 'true'",
                "needs.scope.outputs.swift_impact == 'true'",
            )
        ):
            findings.add(
                "CODEQL_SCOPE_CONTRACT",
                f"codeql.yml:analyze:{step_name}",
                "heavy CodeQL steps must run for Actions and every impacted language only",
            )

    for step_name in (
        "Set up Java",
        "Set up Android SDK",
        "Install Android 17 SDK",
        "Install native ARM64 Android 37 build tools",
        "Validate Gradle wrapper",
        "Build Android helper for CodeQL",
        "Verify Java 25 / Android 17 toolchain",
    ):
        step = analyze_steps.get(step_name)
        if not isinstance(step, dict) or "needs.scope.outputs.java_impact == 'true'" not in str(step.get("if") or ""):
            findings.add(
                "CODEQL_SCOPE_CONTRACT",
                f"codeql.yml:analyze:{step_name}",
                "Java/Kotlin build path must be fenced by trusted Java impact",
            )

    swift_step = analyze_steps.get("Autobuild Swift sources for CodeQL")
    if not isinstance(swift_step, dict) or "needs.scope.outputs.swift_impact == 'true'" not in str(swift_step.get("if") or ""):
        findings.add(
            "CODEQL_SCOPE_CONTRACT",
            "codeql.yml:analyze:Autobuild Swift sources for CodeQL",
            "Swift autobuild must be fenced by trusted Swift impact",
        )

    if "needs.scope.outputs.swift_impact != 'true'" not in str(analyze.get("runs-on") or ""):
        findings.add(
            "CODEQL_SCOPE_CONTRACT",
            "codeql.yml:analyze",
            "non-impacting Swift checks must avoid allocating the macOS runner",
        )

    ci = workflows.get("ci.yml") or {}
    scripts_job = (ci.get("jobs") or {}).get("scripts") or {}
    if not any(
        str(step.get("run") or "").strip() == "python3 scripts/test-codeql-scope.py"
        for step in steps_of(scripts_job)
        if isinstance(step, dict)
    ):
        findings.add(
            "CODEQL_SCOPE_CONTRACT",
            "ci.yml:scripts",
            "required Evidence & Tooling Validation must execute CodeQL scope fixtures",
        )



def check_release_codeql_security(root, workflows, policy, findings):
    """Stage A: protect the exact-SHA scan and new automated Release path."""
    spec = policy.get("release_codeql_security")
    where = ".github/workflows/codeql.yml"
    if (not isinstance(spec, dict)
        or spec.get("workflow") != "codeql.yml"
        or spec.get("scan_events") != ["pull_request", "schedule", "workflow_dispatch"]
        or spec.get("retained_languages") != ["actions", "java-kotlin", "python", "swift"]
        or spec.get("exact_sha_input") != "candidate_sha"
        or spec.get("sarif_retention_days") != 90):
        findings.add("CODEQL_RELEASE_POLICY", ".github/hardening-policy.json",
                     "release security policy must retain full four-language exact-SHA evidence")
    codeql = workflows.get("codeql.yml") or {}
    events = triggers(codeql)
    manual = (events.get("workflow_dispatch") or {}).get("inputs", {})
    candidate = manual.get("candidate_sha") if isinstance(manual, dict) else None
    if (not isinstance(candidate, dict) or candidate.get("required") is not True
        or candidate.get("type") != "string"
        or "pull_request" not in events or "schedule" not in events):
        findings.add("CODEQL_RELEASE_TRIGGER", where,
                     "retain PR/schedule plus mandatory exact-SHA manual dispatch in Stage A")
    analyze = (codeql.get("jobs") or {}).get("analyze") or {}
    steps = {s.get("name"): s for s in steps_of(analyze) if isinstance(s, dict)}
    guard = steps.get("Require exact protected-main source for full CodeQL evidence") or {}
    guard_run = str(guard.get("run") or "")
    if (guard.get("if") != "github.event_name != 'pull_request'"
        or not all(x in guard_run for x in (
            '[[ "$GITHUB_REF" == "refs/heads/main" && "$GITHUB_SHA" == "$EXPECTED_SHA" ]]',
            'remote_main="$(gh api', '[[ "$remote_main" == "$EXPECTED_SHA" ]]'
        ))):
        findings.add("CODEQL_RELEASE_SOURCE", where, "exact main source verification missing")
    env = analyze.get("env") or {}
    if env.get("EXPECTED_SHA") != "${{ github.event_name == 'workflow_dispatch' && inputs.candidate_sha || github.sha }}":
        findings.add("CODEQL_RELEASE_SOURCE", where, "wrong expected candidate SHA selection")
    checkout = steps.get("Checkout repository") or {}
    if (checkout.get("with") or {}).get("ref") != "${{ github.event_name != 'pull_request' && env.EXPECTED_SHA || github.sha }}":
        findings.add("CODEQL_RELEASE_SOURCE", where, "full scan checkout must pin expected exact SHA")
    operation = steps.get("Perform CodeQL Analysis") or {}
    analysis_options = operation.get("with") or {}
    if (operation.get("id") != "analyze"
        or analysis_options.get("upload") != "${{ github.event_name == 'workflow_dispatch' && 'never' || 'always' }}"
        or analysis_options.get("output") != "${{ runner.temp }}/release-codeql-${{ matrix.language }}"):
        findings.add("CODEQL_RELEASE_SARIF", where, "CodeQL must emit raw SARIF on every full scan")
    artifact = steps.get("Retain exact-main raw CodeQL SARIF") or {}
    opts = artifact.get("with") or {}
    if (artifact.get("if") != "github.event_name != 'pull_request'"
        or not str(artifact.get("uses") or "").startswith("actions/upload-artifact@")
        or opts.get("name") != "release-codeql-${{ env.EXPECTED_SHA }}-${{ matrix.language }}"
        or opts.get("path") != "${{ steps.analyze.outputs.sarif-output }}"
        or opts.get("if-no-files-found") != "error"
        or opts.get("retention-days") != 90):
        findings.add("CODEQL_RELEASE_SARIF", where, "raw per-language SARIF artifact retention drift")
    verdict = steps.get("Reject invalid or High/Critical exact-main SARIF") or {}
    verdict_run = str(verdict.get("run") or "")
    if (verdict.get("if") != "github.event_name != 'pull_request'"
        or "python3 scripts/release_codeql_verdict.py" not in verdict_run
        or '[[ "$remote_main" == "$EXPECTED_SHA" ]]' not in verdict_run):
        findings.add("CODEQL_RELEASE_VERDICT", where, "full scan must fail closed on SARIF and main drift")
    release = (workflows.get("release.yml") or {}).get("jobs", {}).get("dmg") or {}
    release_steps = steps_of(release)
    named = {s.get("name"): (i, s) for i, s in enumerate(release_steps) if isinstance(s, dict)}
    state = named.get("Classify existing release recovery")
    gate = named.get("Verify exact-tag CodeQL before first GitHub Release publication")
    build = named.get("Build DMG")
    publish = named.get("Create or refresh GitHub Release")
    source = named.get("Verify checked-out tag identity")
    if not all((state, gate, build, publish, source)):
        findings.add("RELEASE_CODEQL_ORDER", "release.yml", "missing source, recovery state, CodeQL gate or publish step")
    else:
        si, state_step = state
        gi, gate_step = gate
        bi, _ = build
        pi, publish_step = publish
        if not (source[0] < si < gi < bi < pi):
            findings.add("RELEASE_CODEQL_ORDER", "release.yml", "pre-publication CodeQL gate must precede all builds and release mutation")
        gate_run = str(gate_step.get("run") or "")
        state_run = str(state_step.get("run") or "")
        pub_run = str(publish_step.get("run") or "")
        if (gate_step.get("if") != "steps.release_state.outputs.mode == 'new'"
            or "--candidate-sha" not in gate_run
            or "scripts/release_codeql_gate.py" not in gate_run
            or "mode=new" not in state_run or "mode=recovery" not in state_run
            or "new:HTTP*" not in pub_run or "recovery:HTTP*" not in pub_run
            or "RELEASE_MODE" not in (publish_step.get("env") or {})):
            findings.add("RELEASE_CODEQL_GATE", "release.yml", "fail-closed first publication vs recovery fence drift")
    if (release.get("permissions") or {}).get("actions") != "read":
        findings.add("RELEASE_CODEQL_GATE", "release.yml", "release verifier needs actions:read")
    scripts = (workflows.get("ci.yml") or {}).get("jobs", {}).get("scripts") or {}
    commands = {str(s.get("run") or "").strip() for s in steps_of(scripts) if isinstance(s, dict)}
    for cmd in ("python3 scripts/release_codeql_verdict.py --self-test",
                "python3 scripts/release_codeql_gate.py --self-test"):
        if cmd not in commands:
            findings.add("RELEASE_CODEQL_TESTS", "ci.yml:scripts", f"missing required offline negative fixture: {cmd}")


MANUAL_LIVE_READBACKS = {
    "codeql",
    "actions/permissions",
    "actions/permissions/workflow",
}


def check_manual_live_readback_policy(policy, findings):
    configured = policy.get("manual_live_readbacks")
    if not isinstance(configured, dict):
        findings.add(
            "LIVE_READBACK_POLICY",
            ".github/hardening-policy.json",
            "manual_live_readbacks must be an object naming every admin-only readback",
        )
        return

    actual = set(configured)
    missing = MANUAL_LIVE_READBACKS - actual
    unexpected = actual - MANUAL_LIVE_READBACKS
    if missing or unexpected:
        findings.add(
            "LIVE_READBACK_POLICY",
            ".github/hardening-policy.json",
            f"manual live-readback inventory drifted; missing={sorted(missing)}, "
            f"unexpected={sorted(unexpected)}",
        )

    for name, reason in configured.items():
        if not isinstance(reason, str) or not reason.strip():
            findings.add(
                "LIVE_READBACK_POLICY",
                ".github/hardening-policy.json",
                f"manual live readback {name!r} requires a non-empty rationale",
            )


def check_release_provenance(root, workflows, policy, findings):
    expected = policy.get("release_provenance")
    if not expected:
        return

    filename = expected.get("workflow")
    workflow = workflows.get(filename)
    if workflow is None:
        findings.add("RELEASE_PROVENANCE", filename or "<missing>",
                     "release provenance policy names a missing workflow")
        return

    jobs = workflow.get("jobs") or {}
    job = jobs.get(expected.get("job", "dmg"))
    if job is None:
        findings.add("RELEASE_PROVENANCE", filename,
                     "release provenance requires the canonical dmg job")
        return

    permissions = job.get("permissions") or {}
    for scope in ("contents", "id-token", "attestations"):
        if permissions.get(scope) != "write":
            findings.add("RELEASE_ATTESTATION_PERMISSION", filename,
                         f"release job must grant job-local {scope}: write")

    path = os.path.join(root, ".github", "workflows", filename)
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()

    ref_fragments = [
        'expected_ref="refs/tags/${RELEASE_TAG}"',
        'test "${GITHUB_REF}" = "${expected_ref}"',
        'gh workflow run release.yml --ref ${RELEASE_TAG} -f tag=${RELEASE_TAG}',
    ]
    for fragment in ref_fragments:
        if fragment not in text:
            findings.add("RELEASE_REF_GUARD", filename,
                         f"exact-tag recovery provenance guard is missing: {fragment}")

    expected_action = expected.get("attestation_action")
    attestation_fragments = [
        "Attest verified DMG build provenance",
        expected_action,
        "subject-path: ${{ steps.artifact.outputs.dmg }}",
    ]
    for fragment in attestation_fragments:
        if not fragment or fragment not in text:
            findings.add("RELEASE_ATTESTATION", filename,
                         f"release attestation contract is missing: {fragment}")

    attest_steps = [
        step for step in steps_of(job)
        if isinstance(step, dict) and step.get("name") == "Attest verified DMG build provenance"
    ]
    if len(attest_steps) != 1:
        findings.add("RELEASE_ATTESTATION", filename,
                     f"expected exactly one build-provenance attestation step, got {len(attest_steps)}")
    else:
        attest_step = attest_steps[0]
        if attest_step.get("uses") != expected_action:
            findings.add("RELEASE_ATTESTATION", filename,
                         f"attestation action drifted to {attest_step.get('uses')!r}")
        inputs = attest_step.get("with") or {}
        if inputs.get("subject-path") != "${{ steps.artifact.outputs.dmg }}":
            findings.add("RELEASE_ATTESTATION", filename,
                         "attestation subject must be the exact verified DMG output")
        # actions/attest defaults to SLSA build provenance only when no SBOM or
        # custom-predicate inputs are supplied. Pin that semantic mode, not just
        # the action SHA/name, so a future edit cannot silently change the claim.
        forbidden = {
            key for key in ("sbom-path", "predicate-type", "predicate", "predicate-path")
            if key in inputs
        }
        if forbidden:
            findings.add("RELEASE_ATTESTATION_MODE", filename,
                         "DMG attestation must remain default SLSA build provenance; "
                         f"found alternate predicate inputs: {sorted(forbidden)}")
        if inputs.get("push-to-registry") not in (None, False, "false"):
            findings.add("RELEASE_ATTESTATION_MODE", filename,
                         "file DMG provenance must not use registry-push attestation mode")

    verify_pos = text.find("Verify version, signature, and DMG integrity")
    attest_pos = text.find("Attest verified DMG build provenance")
    publish_pos = text.find("Create or refresh GitHub Release")
    if min(verify_pos, attest_pos, publish_pos) < 0 or not (verify_pos < attest_pos < publish_pos):
        findings.add("RELEASE_ATTESTATION_ORDER", filename,
                     "artifact verification must precede attestation, and attestation must precede release mutation")

def check_hardening_audit_lifecycle(root, workflows, findings):
    workflow = workflows.get("hardening-audit.yml")
    if workflow is None:
        findings.add("AUDIT_RECOVERY", "hardening-audit.yml", "missing hardening audit workflow")
        return

    report = (workflow.get("jobs") or {}).get("report")
    if report is None:
        findings.add("AUDIT_RECOVERY", "hardening-audit.yml:report", "missing report job")
        return

    if str(report.get("if") or "").strip() != "always()":
        findings.add(
            "AUDIT_RECOVERY",
            "hardening-audit.yml:report",
            "report job must run on both drift and recovery",
        )

    permissions = report.get("permissions") or {}
    if permissions.get("issues") != "write":
        findings.add(
            "AUDIT_RECOVERY",
            "hardening-audit.yml:report",
            "recovery reporter must isolate issues: write at job scope",
        )

    path = os.path.join(root, ".github", "workflows", "hardening-audit.yml")
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    required = (
        "DETECT_RESULT: ${{ needs.detect.result }}",
        "if (process.env.DETECT_RESULT === 'success')",
        "Hardening audit recovered",
        "state: 'closed'",
    )
    for fragment in required:
        if fragment not in text:
            findings.add(
                "AUDIT_RECOVERY",
                "hardening-audit.yml:report",
                f"owned-issue recovery contract missing: {fragment}",
            )


def gh_api(path, findings, where, manual=False):
    def unreadable(message):
        if manual:
            findings.manual_unverified(where, message)
        else:
            findings.skip(where, message)

    try:
        completed = subprocess.run(
            ["gh", "api", path], capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        unreadable(f"live readback unavailable: {error}")
        return None
    if completed.returncode != 0:
        unreadable(f"live readback failed ({completed.stderr.strip()[:200]})")
        return None
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        unreadable(f"live readback returned non-JSON: {error}")
        return None


def check_live(repo, policy, findings):
    manual = set((policy.get("manual_live_readbacks") or {}).keys())
    rulesets = gh_api(f"repos/{repo}/rulesets", findings, "rulesets")
    if rulesets is not None:
        branch = next((item for item in rulesets if item.get("target") == "branch"), None)
        tag = next((item for item in rulesets if item.get("target") == "tag"), None)
        _check_branch_ruleset(repo, branch, policy, findings)
        _check_tag_ruleset(repo, tag, policy, findings)

    default_setup = gh_api(
        f"repos/{repo}/code-scanning/default-setup",
        findings,
        "codeql",
        manual="codeql" in manual,
    )
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

    actions = gh_api(
        f"repos/{repo}/actions/permissions",
        findings,
        "actions/permissions",
        manual="actions/permissions" in manual,
    )
    expected = policy["actions_policy"]
    if actions is not None and actions.get("sha_pinning_required") != expected["sha_pinning_required"]:
        findings.add("ACTIONS_POLICY_DRIFT", "actions/permissions",
                     f"sha_pinning_required={actions.get('sha_pinning_required')}, "
                     f"expected {expected['sha_pinning_required']}")

    workflow_permissions = gh_api(
        f"repos/{repo}/actions/permissions/workflow",
        findings,
        "actions/permissions/workflow",
        manual="actions/permissions/workflow" in manual,
    )
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
    check_staged_gates(workflows, policy, findings)
    check_docs_only_fast_path(workflows, findings)
    check_action_pins(workflows, findings)
    check_permissions(workflows, policy, findings)
    check_trust_boundaries(workflows, policy, findings)
    check_hygiene(workflows, findings)
    check_labels(args.root, findings)
    check_issue_labeler_safety(args.root, workflows, findings)
    check_codeql_authority(args.root, workflows, policy, findings)
    check_android_seed_contract(workflows, findings)
    check_android_dependency_submission_contract(workflows, findings)
    check_manual_live_readback_policy(policy, findings)
    check_hardening_audit_lifecycle(args.root, workflows, findings)
    check_release_provenance(args.root, workflows, policy, findings)
    check_release_codeql_security(args.root, workflows, policy, findings)
    if args.live:
        check_live(args.repo, policy, findings)

    if not findings.items:
        print(f"hardening policy OK: {len(workflows)} workflow(s), "
              f"{len(policy['required_status_checks'])} required context(s)")
        return 0

    for code, where, message in findings.items:
        print(f"{code}: {where}: {message}")

    skipped = sum(1 for code, _, _ in findings.items if code == "SKIPPED")
    manual = sum(1 for code, _, _ in findings.items if code == "MANUAL_UNVERIFIED")
    if findings.fatal:
        print(
            f"\n{len(findings.fatal)} hardening finding(s), "
            f"{skipped} unexpected skipped readback(s), "
            f"{manual} manual-unverified readback(s)",
            file=sys.stderr,
        )
        return 1
    if skipped and not args.allow_live_skip:
        print(f"\n{skipped} unexpected live readback(s) could not be performed", file=sys.stderr)
        return 1
    if manual:
        print(
            f"\n{manual} admin-only live readback(s) remain MANUAL_UNVERIFIED; "
            "this run does not claim those controls as live-proven."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
