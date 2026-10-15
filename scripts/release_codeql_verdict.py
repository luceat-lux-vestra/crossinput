#!/usr/bin/env python3
"""Fail-closed release candidate CodeQL SARIF verdict. No publishing capability.

A manual or scheduled CodeQL run analyzes an exact protected-main SHA and retains the
unaltered SARIF as evidence. This gate rejects corrupt reports, missing security
severity, and any High/Critical finding; it does not grant release authorization.
"""
import argparse
import hashlib
import json
import math
import re
import sys
import tempfile
from pathlib import Path

LANGUAGES = {"actions", "java-kotlin", "python", "swift"}
COMMIT = re.compile(r"[0-9a-f]{40}\Z")


EXTRACTION = {
    "actions": {
        "actual": {"actions/diagnostics/successfully-extracted-files"},
        "expected": {"cli/expected-extracted-files/actions"},
        "warnings": set(),
    },
    "java-kotlin": {
        "actual": {"java/diagnostics/successfully-extracted-files"},
        "expected": {"cli/expected-extracted-files/java", "cli/expected-extracted-files/kotlin"},
        "warnings": {"java/diagnostics/extraction-warnings"},
    },
    "python": {
        "actual": {"py/diagnostics/successfully-extracted-files"},
        "expected": {"cli/expected-extracted-files/python"},
        "warnings": {"py/diagnostics/extraction-warnings"},
    },
    "swift": {
        "actual": {"swift/diagnostics/successfully-extracted-files"},
        "expected": {"cli/expected-extracted-files/swift"},
        "warnings": {"swift/diagnostics/extraction-warnings"},
    },
}


def _notification_paths(notes, ids):
    paths = set()
    for note in notes:
        if not isinstance(note, dict):
            raise ValueError("malformed CodeQL tool notification")
        descriptor = note.get("descriptor", {})
        if not isinstance(descriptor, dict):
            raise ValueError("malformed CodeQL notification descriptor")
        if descriptor.get("id") not in ids:
            continue
        locations = note.get("locations")
        if not isinstance(locations, list) or not locations:
            raise ValueError("extraction diagnostic has no source location")
        for location in locations:
            if not isinstance(location, dict):
                raise ValueError("malformed extraction source location")
            physical = location.get("physicalLocation", {})
            artifact = physical.get("artifactLocation", {}) if isinstance(physical, dict) else {}
            uri = artifact.get("uri") if isinstance(artifact, dict) else None
            if not isinstance(uri, str) or not uri:
                raise ValueError("extraction diagnostic has invalid source URI")
            paths.add(uri)
    return paths


def _expected_source(path, language):
    if language == "actions":
        return path.startswith(".github/workflows/") and path.endswith((".yml", ".yaml"))
    if language == "java-kotlin":
        return path.endswith((".java", ".kt"))
    if language == "python":
        return path.endswith(".py")
    if language == "swift":
        return path.endswith(".swift") and "/Tests/" not in path
    raise ValueError("unexpected language")


def extraction_coverage(run, language):
    spec = EXTRACTION[language]
    notes = []
    for invocation in run.get("invocations", []):
        current = invocation.get("toolExecutionNotifications", [])
        if not isinstance(current, list):
            raise ValueError("malformed CodeQL tool notifications")
        notes.extend(current)
    for note in notes:
        descriptor = note.get("descriptor", {}) if isinstance(note, dict) else {}
        notification_id = descriptor.get("id") if isinstance(descriptor, dict) else None
        if isinstance(note, dict) and note.get("level") == "error":
            raise ValueError(f"CodeQL tool execution error: {notification_id or 'unknown'}")
        if notification_id in spec["warnings"]:
            raise ValueError(f"CodeQL extraction warning: {notification_id}")

    actual = _notification_paths(notes, spec["actual"])
    expected_all = _notification_paths(notes, spec["expected"])
    expected = {path for path in expected_all if _expected_source(path, language)}
    if not expected:
        raise ValueError("no expected repository source files for CodeQL language")
    if not actual:
        raise ValueError("no successfully extracted source files")
    missing = sorted(expected - actual)
    if missing:
        preview = ", ".join(missing[:8])
        raise ValueError(
            f"CodeQL did not extract {len(missing)} expected source file(s): {preview}"
        )
    return {"extracted_files": len(actual), "expected_source_files": len(expected)}


def check(directory: Path, language: str, candidate_sha: str) -> dict:
    if language not in LANGUAGES:
        raise ValueError("unexpected language")
    if not COMMIT.fullmatch(candidate_sha):
        raise ValueError("candidate must be an exact immutable SHA")
    files = sorted(directory.rglob("*.sarif"))
    if len(files) != 1:
        raise ValueError(f"expected exactly one SARIF file, got {len(files)}")
    path = files[0]
    if not path.is_file() or not path.stat().st_size:
        raise ValueError("empty or unreadable SARIF")
    raw = path.read_bytes()
    data = json.loads(raw)
    if not isinstance(data, dict) or data.get("version") != "2.1.0":
        raise ValueError("not SARIF version 2.1.0")
    runs = data.get("runs")
    if not isinstance(runs, list) or len(runs) != 1 or not isinstance(runs[0], dict):
        raise ValueError("expected exactly one CodeQL SARIF run")
    run = runs[0]
    driver = run.get("tool", {}).get("driver", {})
    if not isinstance(driver, dict) or driver.get("name") != "CodeQL":
        raise ValueError("not CodeQL output")
    automation_id = run.get("automationDetails", {}).get("id")
    if not isinstance(automation_id, str) or automation_id not in {"/language:" + language, "/language:" + language + "/"}:
        raise ValueError("SARIF category does not match scanned language")
    invocations = run.get("invocations", [])
    if not isinstance(invocations, list) or len(invocations) == 0 or any(
        not isinstance(x, dict) or x.get("executionSuccessful") is False for x in invocations
    ):
        raise ValueError("CodeQL analysis reports an unsuccessful invocation")
    coverage = extraction_coverage(run, language)
    # CodeQL SARIF puts query rules in tool.extensions[].rules, not in
    # tool.driver.rules. A clean scan may contain zero results and no driver rules.
    tool = run.get("tool", {})
    extensions = tool.get("extensions")
    if not isinstance(extensions, list):
        raise ValueError("missing CodeQL query pack metadata")
    query_pack = {
        "actions": "codeql/actions-queries",
        "java-kotlin": "codeql/java-queries",
        "python": "codeql/python-queries",
        "swift": "codeql/swift-queries",
    }[language]
    packs = [(i, component) for i, component in enumerate(extensions)
             if isinstance(component, dict) and component.get("name") == query_pack]
    if len(packs) != 1:
        raise ValueError("missing or duplicate expected CodeQL query pack")
    component_index, component = packs[0]
    rules = component.get("rules")
    if not isinstance(rules, list) or len(rules) == 0:
        raise ValueError("no CodeQL rule metadata")
    by_id = {}
    for index, rule in enumerate(rules):
        if not isinstance(rule, dict) or not isinstance(rule.get("id"), str) or not rule["id"]:
            raise ValueError("malformed CodeQL rule")
        if rule["id"] in by_id:
            raise ValueError("duplicate CodeQL rule ID")
        by_id[rule["id"]] = (index, rule)
    results = run.get("results")
    if not isinstance(results, list):
        raise ValueError("missing or malformed result set")
    high = []
    for result in results:
        if not isinstance(result, dict) or not isinstance(result.get("ruleId"), str):
            raise ValueError("result missing rule ID")
        rule_id = result["ruleId"]
        entry = by_id.get(rule_id)
        if entry is None:
            raise ValueError(f"result references unknown rule: {rule_id}")
        rule_index, rule = entry
        reference = result.get("rule")
        if not isinstance(reference, dict) or reference.get("id") != rule_id:
            raise ValueError(f"result has invalid SARIF rule reference: {rule_id}")
        tool_component = reference.get("toolComponent")
        if (not isinstance(tool_component, dict)
                or tool_component.get("index") != component_index
                or reference.get("index") != rule_index):
            raise ValueError(f"result rule reference points outside verified CodeQL query pack: {rule_id}")
        properties = rule.get("properties", {})
        if not isinstance(properties, dict):
            raise ValueError("rule properties are malformed")
        result_properties = result.get("properties", {})
        if not isinstance(result_properties, dict):
            raise ValueError("result properties are malformed")
        tags = properties.get("tags", [])
        if not isinstance(tags, list):
            raise ValueError("rule tags are malformed")
        security = "security" in tags or any(
            isinstance(t, str) and (t.startswith("external/cwe/") or t.startswith("cwe/"))
            for t in tags
        )
        # SARIF CodeQL security-severity can be stored at rule level; any explicit
        # result-level override must also be validated rather than silently ignored.
        scores = [item.get("security-severity") for item in (properties, result_properties)
                  if "security-severity" in item]
        if security and not scores:
            raise ValueError(f"security finding has no severity: {rule_id}")
        for score in scores:
            try:
                val = float(score)
            except (TypeError, ValueError) as exc:
                raise ValueError(f"unparseable security severity: {rule_id}") from exc
            if not math.isfinite(val) or not 0 <= val <= 10:
                raise ValueError(f"out-of-range security severity: {rule_id}")
            if val >= 7.0:
                high.append((rule_id, val))
    if high:
        findings = ", ".join(f"{rid}({score:g})" for rid, score in high[:8])
        raise ValueError(f"High/Critical CodeQL findings ({len(high)}): {findings}")
    return {"candidate_sha": candidate_sha, "language": language,
            "sarif_sha256": hashlib.sha256(raw).hexdigest(), "results": len(results),
            "rules": len(rules), "high_or_critical": 0,
            "extracted_files": coverage["extracted_files"],
            "expected_source_files": coverage["expected_source_files"]}


def self_test() -> None:
    sha = "a" * 40
    def fixture(language="java-kotlin", score="5.0", results=True, security=True):
        rule = {"id": "java/test", "properties": {
            "tags": ["security"] if security else ["correctness"]}}
        if score is not None:
            rule["properties"]["security-severity"] = score
        return {"version": "2.1.0", "runs": [{
            "tool": {"driver": {"name": "CodeQL"}, "extensions": [
                {"name": "codeql/java-queries", "rules": [rule]}]},
            "automationDetails": {"id": "/language:" + language + "/"},
            "invocations": [{"executionSuccessful": True, "toolExecutionNotifications": [
                {"descriptor": {"id": {
                    "actions": "actions/diagnostics/successfully-extracted-files",
                    "java-kotlin": "java/diagnostics/successfully-extracted-files",
                    "python": "py/diagnostics/successfully-extracted-files",
                    "swift": "swift/diagnostics/successfully-extracted-files",
                }[language]}, "locations": [{"physicalLocation": {
                    "artifactLocation": {"uri": {
                        "actions": ".github/workflows/ci.yml",
                        "java-kotlin": "src/main/kotlin/App.kt",
                        "python": "scripts/tool.py",
                        "swift": "Sources/App.swift",
                    }[language]}}}]},
                {"descriptor": {"id": {
                    "actions": "cli/expected-extracted-files/actions",
                    "java-kotlin": "cli/expected-extracted-files/kotlin",
                    "python": "cli/expected-extracted-files/python",
                    "swift": "cli/expected-extracted-files/swift",
                }[language]}, "locations": [{"physicalLocation": {
                    "artifactLocation": {"uri": {
                        "actions": ".github/workflows/ci.yml",
                        "java-kotlin": "src/main/kotlin/App.kt",
                        "python": "scripts/tool.py",
                        "swift": "Sources/App.swift",
                    }[language]}}}]},
            ]}],
            "results": [{"ruleId": "java/test", "rule": {
                "id": "java/test", "index": 0, "toolComponent": {"index": 0}
            }}] if results else []}]}

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "result.sarif"
        def probe(doc, expected_failure=None, language="java-kotlin", current_sha=sha):
            path.write_text(json.dumps(doc), encoding="utf-8")
            try:
                verdict = check(Path(tmp), language, current_sha)
            except (ValueError, TypeError, KeyError, json.JSONDecodeError) as error:
                if expected_failure is None or expected_failure not in str(error):
                    raise AssertionError(f"unexpected verdict: {error}") from error
            else:
                if expected_failure is not None:
                    raise AssertionError(f"failure not detected: {expected_failure}")
                assert verdict["high_or_critical"] == 0
                assert verdict["extracted_files"] >= verdict["expected_source_files"] >= 1

        probe(fixture())
        # Real CodeQL 2.27.2 clean SARIF has zero driver rules/results but
        # retains query descriptors in tool.extensions[].rules.
        probe(fixture(results=False))
        for language, pack in (
            ("actions", "codeql/actions-queries"),
            ("java-kotlin", "codeql/java-queries"),
            ("python", "codeql/python-queries"),
            ("swift", "codeql/swift-queries"),
        ):
            clean = fixture(language=language, results=False)
            clean["runs"][0]["tool"]["extensions"][0]["name"] = pack
            probe(clean, language=language)
        probe(fixture(score="7.0"), "High/Critical")
        probe(fixture(score="9.8"), "High/Critical")
        probe(fixture(score=None), "no severity")
        probe(fixture(score="NaN"), "out-of-range")
        probe(fixture(score="-1"), "out-of-range")
        probe(fixture(score="not-a-number"), "unparseable")
        probe(fixture(security=False, score=None))
        probe(fixture(), "candidate must be", current_sha="main")
        probe(fixture(), "category does not match", language="actions")
        bad = fixture()
        bad["runs"][0]["tool"]["extensions"][0]["name"] = "codeql/other-queries"
        probe(bad, "missing or duplicate expected CodeQL query pack")
        bad = fixture()
        bad["runs"][0]["results"][0]["rule"]["toolComponent"]["index"] = 5
        probe(bad, "outside verified CodeQL query pack")
        bad = fixture()
        bad["runs"][0]["invocations"][0]["executionSuccessful"] = False
        probe(bad, "unsuccessful invocation")
        bad = fixture()
        bad["runs"][0]["invocations"][0]["toolExecutionNotifications"] = [
            bad["runs"][0]["invocations"][0]["toolExecutionNotifications"][1]
        ]
        probe(bad, "no successfully extracted source files")
        bad = fixture()
        bad["runs"][0]["invocations"][0]["toolExecutionNotifications"][0]["locations"][0][
            "physicalLocation"]["artifactLocation"]["uri"] = "src/main/kotlin/Other.kt"
        probe(bad, "did not extract")
        bad = fixture()
        bad["runs"][0]["invocations"][0]["toolExecutionNotifications"].append({
            "descriptor": {"id": "java/diagnostics/extraction-warnings"},
            "locations": [{"physicalLocation": {"artifactLocation": {
                "uri": "src/main/kotlin/App.kt"}}}],
        })
        probe(bad, "extraction warning")
        bad = fixture()
        bad["runs"][0]["invocations"][0]["toolExecutionNotifications"].append({
            "level": "error",
            "descriptor": {"id": "cli/extractor-error"},
            "locations": [{"physicalLocation": {"artifactLocation": {
                "uri": "src/main/kotlin/App.kt"}}}],
        })
        probe(bad, "tool execution error")
        bad = fixture()
        bad["runs"][0]["results"][0]["ruleId"] = "missing"
        probe(bad, "unknown rule")
        bad = fixture()
        bad["runs"][0]["tool"]["extensions"][0]["rules"] = []
        probe(bad, "no CodeQL rule")
        bad = fixture()
        bad["runs"][0].pop("results")
        probe(bad, "missing or malformed result")
        path.write_text("{bad", encoding="utf-8")
        try:
            check(Path(tmp), "java-kotlin", sha)
        except json.JSONDecodeError:
            pass
        else:
            raise AssertionError("malformed SARIF accepted")
        path.unlink()
        try:
            check(Path(tmp), "java-kotlin", sha)
        except ValueError as error:
            assert "exactly one" in str(error)
        else:
            raise AssertionError("missing SARIF accepted")
        print("release CodeQL SARIF negative controls passed")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--sarif-dir", type=Path)
    parser.add_argument("--language")
    parser.add_argument("--candidate-sha")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.sarif_dir or not args.language or not args.candidate_sha:
        parser.error("--sarif-dir, --language and --candidate-sha are required")
    try:
        verdict = check(args.sarif_dir, args.language, args.candidate_sha)
    except (ValueError, TypeError, KeyError, json.JSONDecodeError) as error:
        print(f"::error::Release CodeQL evidence rejected: {error}", file=sys.stderr)
        raise SystemExit(1) from error
    print("Release CodeQL evidence accepted: " + json.dumps(verdict, sort_keys=True))


if __name__ == "__main__":
    main()
