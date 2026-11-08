#!/usr/bin/env python3
"""Read-only PR compatibility adapter for the Android Gradle dependency publisher."""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

SHA = re.compile(r"[0-9a-f]{40}\Z")
JOB = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$", re.MULTILINE)
ACTION_PREFIXES = (
    "actions/checkout",
    "actions/setup-java",
    "android-actions/setup-android",
    "gradle/actions/dependency-submission",
)
CONTROL_PATHS = {
    ".github/workflows/android-dependency-submission.yml",
    ".github/workflows/ci.yml",
    ".github/hardening-policy.json",
    "scripts/trusted-dependency-submission-validation.py",
    "scripts/check-workflow-policy.py",
    "scripts/test-workflow-policy.py",
    "scripts/test-fast-evidence.py",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def safe_path(value: object) -> str:
    require(isinstance(value, str) and value, "missing changed-file path")
    require(not value.startswith("/") and ".." not in value.split("/"),
            "unsafe changed-file path")
    return value


def dependency_input(path: str) -> bool:
    if path in CONTROL_PATHS:
        return True
    if not path.startswith("android/helper/"):
        return False
    rel = path[len("android/helper/"):]
    if rel.startswith("gradle/"):
        return True
    name = rel.rsplit("/", 1)[-1]
    return (
        name.endswith(".gradle")
        or name.endswith(".gradle.kts")
        or name == "gradle.properties"
        or name == "gradle-wrapper.properties"
    )


def classify(pull: dict, pages: list, expected_head: str) -> bool:
    require(SHA.fullmatch(expected_head or "") is not None, "invalid expected PR HEAD")
    require(isinstance(pull, dict) and isinstance(pull.get("head"), dict),
            "missing PR metadata")
    require(pull["head"].get("sha") == expected_head,
            "PR HEAD changed during classification")
    count = pull.get("changed_files")
    require(type(count) is int and 0 < count <= 3000,
            "invalid or unsupported PR changed-file count")
    require(isinstance(pages, list) and pages
            and all(isinstance(page, list) for page in pages),
            "invalid paginated changed-file listing")
    entries = [entry for page in pages for entry in page]
    require(len(entries) == count, "incomplete PR changed-file listing")

    seen: set[str] = set()
    paths: set[str] = set()
    for entry in entries:
        require(isinstance(entry, dict), "malformed changed-file entry")
        name = safe_path(entry.get("filename"))
        require(name not in seen, "duplicate changed-file entry")
        seen.add(name)
        status = entry.get("status")
        require(status in {
            "added", "modified", "removed", "renamed",
            "copied", "changed", "unchanged",
        }, "unknown changed-file status")
        paths.add(name)
        if status == "renamed":
            paths.add(safe_path(entry.get("previous_filename")))
        if name == ".github/workflows/android-dependency-submission.yml":
            require(status == "modified",
                    "production dependency publisher may only be modified in-place")
    return any(dependency_input(path) for path in paths)


def extract_job(workflow: str, job_id: str) -> str:
    marker = re.search(rf"^  {re.escape(job_id)}:\s*$", workflow, re.MULTILINE)
    require(marker is not None, f"missing workflow job {job_id}")
    tail = workflow[marker.end():]
    end = JOB.search(tail)
    return tail[:end.start()] if end else tail


def action_pin(text: str, action: str) -> str:
    pins = re.findall(
        rf"uses:\s*{re.escape(action)}@([0-9a-f]{{40}})(?:\s+#.*)?$",
        text,
        re.MULTILINE,
    )
    require(len(pins) == 1, f"expected exactly one {action} pin")
    return pins[0]


def check_contract(production: str, pr_workflow: str) -> None:
    require("  pull_request:" not in production
            and "  pull_request_target:" not in production,
            "production Android dependency publisher must not run on PR events")
    require("github.ref == 'refs/heads/main'" in production,
            "production publisher lost protected-main guard")
    require("      contents: write" in production,
            "production publisher lost contents:write authority")
    require("dependency-graph: generate-and-submit" in production,
            "production publisher is not in generate-and-submit mode")
    require("build-root-directory: android/helper" in production,
            "production publisher build root drifted")
    require("cache-read-only: true" in production,
            "production publisher may write Gradle cache")
    require("validate-wrappers: true" in production,
            "production publisher no longer validates wrappers")

    job = extract_job(pr_workflow, "dependencySubmissionValidation")
    require("    permissions:\n      contents: read\n      pull-requests: read\n" in job,
            "PR dependency adapter permissions must be explicitly read-only")
    require(re.search(r"^\s+\S+:\s*write(?:\s+#.*)?$", job, re.MULTILINE) is None,
            "PR dependency adapter gained write authority")
    require(
        "repository: ${{ github.event.pull_request.head.repo.full_name }}" in job
        and "ref: ${{ github.event.pull_request.head.sha }}" in job,
        "PR dependency adapter must checkout exact PR-head repository/SHA",
    )
    require("persist-credentials: false" in job,
            "PR dependency adapter checkout credentials must not persist")
    require("dependency-graph: generate-and-upload" in job,
            "PR dependency adapter must use generate-and-upload")
    require("dependency-graph: generate-and-submit" not in job,
            "PR dependency adapter must never submit")
    require("dependency-graph-report-dir: dependency-graph-reports-pr" in job,
            "PR dependency adapter report directory drifted")
    require("build-root-directory: android/helper" in job,
            "PR dependency adapter build root drifted")
    require("cache-read-only: true" in job,
            "PR dependency adapter may write Gradle cache")
    require("validate-wrappers: true" in job,
            "PR dependency adapter no longer validates wrappers")
    require("distribution: temurin" in production and "distribution: temurin" in job,
            "Java distribution drifted between production and PR adapter")
    require('java-version: "25.0.4"' in production
            and 'java-version: "25.0.4"' in job,
            "Java version drifted between production and PR adapter")
    require(
        'sdkmanager --install "platforms;android-37.0" "build-tools;37.0.0"'
        in production
        and 'sdkmanager --install "platforms;android-37.0" "build-tools;37.0.0"'
        in job,
        "Android SDK setup drifted between production and PR adapter",
    )

    for action in ACTION_PREFIXES:
        require(action_pin(production, action) == action_pin(job, action),
                f"PR adapter {action} pin does not match production publisher")


def expected_coordinates(root: Path) -> set[str]:
    top = (root / "android/helper/build.gradle.kts").read_text(encoding="utf-8")
    app = (root / "android/helper/app/build.gradle.kts").read_text(encoding="utf-8")

    kgp = re.findall(
        r'classpath\("org[.]jetbrains[.]kotlin:kotlin-gradle-plugin:([^"]+)"\)',
        top,
    )
    agp = re.findall(
        r'id\("com[.]android[.]application"\) version "([^"]+)" apply false',
        top,
    )
    require(len(kgp) == 1 and len(agp) == 1,
            "Android build plugin versions could not be derived exactly")
    test_coordinates = re.findall(r'testImplementation\("([^"]+)"\)', app)
    require(len(test_coordinates) >= 3,
            "Android test dependency coverage unexpectedly shrank")
    return {
        f"org.jetbrains.kotlin:kotlin-gradle-plugin:{kgp[0]}",
        f"com.android.tools.build:gradle:{agp[0]}",
        *test_coordinates,
    }


def production_eligible(graph: dict, source_sha: str) -> bool:
    return graph.get("sha") == source_sha and graph.get("ref") == "refs/heads/main"


def verify_graph(
    directory: Path,
    expected_head: str,
    event_ref: str,
    root: Path,
) -> dict:
    require(SHA.fullmatch(expected_head or "") is not None, "invalid expected PR HEAD")
    require(isinstance(event_ref, str) and event_ref.startswith("refs/pull/"),
            "dependency graph did not run in pull_request ref context")
    require(event_ref != "refs/heads/main",
            "PR dependency graph cannot use protected-main provenance")
    files = sorted(directory.rglob("*.json"))
    require(len(files) == 1,
            f"expected exactly one dependency graph report, got {len(files)}")
    data = json.loads(files[0].read_text(encoding="utf-8"))
    require(isinstance(data, dict), "dependency graph report is not an object")
    require(data.get("sha") == expected_head,
            "dependency graph source SHA is not exact PR HEAD")
    require(data.get("ref") == event_ref,
            "dependency graph ref is not the PR event ref")
    require(not production_eligible(data, expected_head),
            "PR dependency graph was admitted as production evidence")

    manifests = data.get("manifests")
    require(isinstance(manifests, dict) and manifests,
            "dependency graph has no manifests")
    resolved: dict[str, dict] = {}
    for manifest in manifests.values():
        require(isinstance(manifest, dict), "malformed dependency graph manifest")
        nodes = manifest.get("resolved")
        require(isinstance(nodes, dict),
                "dependency graph manifest lacks resolved dependencies")
        resolved.update(nodes)

    require(resolved, "dependency graph resolved set is empty")
    required = expected_coordinates(root)
    missing = required - resolved.keys()
    require(not missing,
            f"dependency graph lost required Android coordinates: {sorted(missing)}")
    direct = sum(
        isinstance(node, dict) and node.get("relationship") == "direct"
        for node in resolved.values()
    )
    require(direct > 0, "dependency graph lost all direct dependency coverage")
    return {
        "source_sha": expected_head,
        "event_ref": event_ref,
        "manifests": len(manifests),
        "resolved": len(resolved),
        "direct": direct,
        "required_coordinates": len(required),
        "production_evidence": False,
    }


def self_test() -> None:
    import tempfile

    sha = "a" * 40
    pull = {"head": {"sha": sha}, "changed_files": 1}
    assert classify(
        pull,
        [[{"filename": "android/helper/app/build.gradle.kts", "status": "modified"}]],
        sha,
    )
    assert classify(
        pull,
        [[{"filename": ".github/workflows/ci.yml", "status": "modified"}]],
        sha,
    )
    assert not classify(
        pull,
        [[{"filename": "README.md", "status": "modified"}]],
        sha,
    )

    bad_cases = (
        ({"head": {"sha": sha}, "changed_files": 2},
         [[{"filename": "README.md", "status": "modified"}]], sha),
        (pull, [[{"filename": "../bad", "status": "modified"}]], sha),
        (pull, [[{"filename": "new", "status": "renamed"}]], sha),
        (pull, [[{
            "filename": ".github/workflows/android-dependency-submission.yml",
            "status": "removed",
        }]], sha),
        (pull, [[{"filename": "README.md", "status": "modified"}]], "b" * 40),
    )
    for bad_pull, pages, bad_sha in bad_cases:
        try:
            classify(bad_pull, pages, bad_sha)
        except ValueError:
            pass
        else:
            raise AssertionError("unsafe PR changed-file classification was accepted")

    prod = (
        "on:\n  push:\n  workflow_dispatch:\npermissions:\n  contents: read\n"
        "jobs:\n  submit:\n"
        "    if: ${{ github.ref == 'refs/heads/main' }}\n"
        "    permissions:\n      contents: write\n    steps:\n"
        "      - uses: actions/checkout@" + "1" * 40 + "\n"
        "        with:\n          persist-credentials: false\n"
        "      - uses: actions/setup-java@" + "2" * 40 + "\n"
        "        with:\n          distribution: temurin\n"
        "          java-version: \"25.0.4\"\n"
        "      - uses: android-actions/setup-android@" + "3" * 40 + "\n"
        "      - name: Install Android 17 SDK\n        run: |\n"
        "          sdkmanager --install \"platforms;android-37.0\" "
        "\"build-tools;37.0.0\"\n"
        "      - uses: gradle/actions/dependency-submission@" + "4" * 40 + "\n"
        "        with:\n          build-root-directory: android/helper\n"
        "          dependency-graph: generate-and-submit\n"
        "          cache-read-only: true\n          validate-wrappers: true\n"
    )
    pr = (
        "jobs:\n  dependencySubmissionValidation:\n"
        "    permissions:\n      contents: read\n      pull-requests: read\n"
        "    steps:\n      - uses: actions/checkout@" + "1" * 40 + "\n"
        "        with:\n"
        "          repository: ${{ github.event.pull_request.head.repo.full_name }}\n"
        "          ref: ${{ github.event.pull_request.head.sha }}\n"
        "          persist-credentials: false\n"
        "      - uses: actions/setup-java@" + "2" * 40 + "\n"
        "        with:\n          distribution: temurin\n"
        "          java-version: \"25.0.4\"\n"
        "      - uses: android-actions/setup-android@" + "3" * 40 + "\n"
        "      - name: Install Android 17 SDK\n        run: |\n"
        "          sdkmanager --install \"platforms;android-37.0\" "
        "\"build-tools;37.0.0\"\n"
        "      - uses: gradle/actions/dependency-submission@" + "4" * 40 + "\n"
        "        with:\n          build-root-directory: android/helper\n"
        "          dependency-graph: generate-and-upload\n"
        "          dependency-graph-report-dir: dependency-graph-reports-pr\n"
        "          cache-read-only: true\n          validate-wrappers: true\n"
    )
    check_contract(prod, pr)
    for mutation in (
        pr.replace("generate-and-upload", "generate-and-submit"),
        pr.replace("contents: read", "contents: write", 1),
        pr.replace(
            "gradle/actions/dependency-submission@" + "4" * 40,
            "gradle/actions/dependency-submission@" + "5" * 40,
        ),
    ):
        try:
            check_contract(prod, mutation)
        except ValueError:
            pass
        else:
            raise AssertionError("unsafe PR dependency adapter contract was accepted")

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "android/helper/app").mkdir(parents=True)
        (root / "android/helper/build.gradle.kts").write_text(
            'buildscript { dependencies { '
            'classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.4.21") } }\n'
            'plugins { id("com.android.application") version "9.5.0" apply false }\n',
            encoding="utf-8",
        )
        (root / "android/helper/app/build.gradle.kts").write_text(
            'dependencies {\n'
            '  testImplementation("junit:junit:4.13.2")\n'
            '  testImplementation("org.mockito:mockito-core:5.24.0")\n'
            '  testImplementation("org.mockito.kotlin:mockito-kotlin:6.4.0")\n'
            '}\n',
            encoding="utf-8",
        )
        coords = expected_coordinates(root)
        resolved = {coord: {"relationship": "direct"} for coord in coords}
        graph = {
            "sha": sha,
            "ref": "refs/pull/7/merge",
            "manifests": {"android": {"resolved": resolved}},
        }
        report = root / "report"
        report.mkdir()
        (report / "graph.json").write_text(json.dumps(graph), encoding="utf-8")
        result = verify_graph(report, sha, "refs/pull/7/merge", root)
        assert result["required_coordinates"] == 5
        assert result["production_evidence"] is False

        try:
            verify_graph(report, sha, "refs/heads/main", root)
        except ValueError:
            pass
        else:
            raise AssertionError("protected-main provenance was accepted")

        graph["sha"] = "b" * 40
        (report / "graph.json").write_text(json.dumps(graph), encoding="utf-8")
        try:
            verify_graph(report, sha, "refs/pull/7/merge", root)
        except ValueError:
            pass
        else:
            raise AssertionError("wrong graph source SHA was accepted")

    print("trusted Android dependency-submission PR adapter self-tests passed")


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    classify_p = sub.add_parser("classify")
    classify_p.add_argument("--pull", type=Path, required=True)
    classify_p.add_argument("--pages", type=Path, required=True)
    classify_p.add_argument("--head", required=True)

    contract_p = sub.add_parser("check-contract")
    contract_p.add_argument("--production", type=Path, required=True)
    contract_p.add_argument("--pr-workflow", type=Path, required=True)

    verify_p = sub.add_parser("verify")
    verify_p.add_argument("--dir", type=Path, required=True)
    verify_p.add_argument("--head", required=True)
    verify_p.add_argument("--event-ref", required=True)
    verify_p.add_argument("--root", type=Path, required=True)

    sub.add_parser("self-test")
    args = parser.parse_args()

    try:
        if args.command == "classify":
            required = classify(
                json.loads(args.pull.read_text(encoding="utf-8")),
                json.loads(args.pages.read_text(encoding="utf-8")),
                args.head,
            )
            print("required=" + str(required).lower())
        elif args.command == "check-contract":
            check_contract(
                args.production.read_text(encoding="utf-8"),
                args.pr_workflow.read_text(encoding="utf-8"),
            )
        elif args.command == "verify":
            print(json.dumps(
                verify_graph(args.dir, args.head, args.event_ref, args.root),
                sort_keys=True,
            ))
        else:
            self_test()
    except (ValueError, OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
        print(
            f"::error::Trusted Android dependency-submission PR validation rejected: {exc}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
