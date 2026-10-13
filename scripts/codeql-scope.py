#!/usr/bin/env python3
"""Fail-closed CodeQL language-impact classifier for pull requests.

The workflow executes this file from the trusted pull-request base, never from
the proposed head. It consumes GitHub PR metadata plus the fully paginated
pull-request files response and decides which repository languages require
heavy CodeQL analysis.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

ALLOWED_STATUSES = {
    "added",
    "modified",
    "removed",
    "renamed",
    "copied",
    "changed",
    "unchanged",
}

FULL_SCAN_PATHS = {
    ".github/workflows/codeql.yml",
    "scripts/codeql-scope.py",
}

JAVA_BUILD_INPUTS = {
    "scripts/setup-android-arm64-build-tools.sh",
    "scripts/check-android-toolchain.sh",
}

PYTHON_CONFIG_NAMES = {
    "pyproject.toml",
    "Pipfile",
    "Pipfile.lock",
    "poetry.lock",
    "uv.lock",
    "setup.py",
    "setup.cfg",
    "tox.ini",
}


def _well_formed_path(value: Any) -> bool:
    if not isinstance(value, str) or not value:
        return False
    path = PurePosixPath(value)
    return not path.is_absolute() and ".." not in path.parts


def _under(path: str, prefix: str) -> bool:
    return path == prefix or path.startswith(prefix + "/")


def full_scan_path(path: Any) -> bool:
    if not _well_formed_path(path):
        return True
    value = str(path)
    return value in FULL_SCAN_PATHS or _under(value, ".github/codeql")


def swift_input_path(path: Any) -> bool:
    if not _well_formed_path(path):
        return True
    return _under(str(path), "apps/macos")


def java_input_path(path: Any) -> bool:
    if not _well_formed_path(path):
        return True
    value = str(path)
    return _under(value, "android/helper") or value in JAVA_BUILD_INPUTS


def python_input_path(path: Any) -> bool:
    if not _well_formed_path(path):
        return True
    value = str(path)
    name = PurePosixPath(value).name
    return (
        value.endswith((".py", ".pyi", ".pyw"))
        or name in PYTHON_CONFIG_NAMES
        or (name.startswith("requirements") and name.endswith(".txt"))
    )


def flatten_pages(value: Any) -> list[dict[str, Any]]:
    """Flatten `gh api --paginate --slurp` output, rejecting unknown shapes."""
    if not isinstance(value, list):
        raise ValueError("paginated response must be a list")

    if all(isinstance(item, dict) for item in value):
        return list(value)

    if not all(isinstance(page, list) for page in value):
        raise ValueError("paginated response must be a list of pages")

    flattened: list[dict[str, Any]] = []
    for page in value:
        if not all(isinstance(item, dict) for item in page):
            raise ValueError("each page must contain file records")
        flattened.extend(page)
    return flattened


def _full_scan(reason: str, observed: int, expected: Any) -> dict[str, Any]:
    return {
        "actions_impact": True,
        "swift_impact": True,
        "java_impact": True,
        "python_impact": True,
        "reason": reason,
        "observed_file_count": observed,
        "expected_file_count": expected,
    }


def classify(records: Any, expected_count: Any) -> dict[str, Any]:
    """Classify changed files. Any malformed or incomplete evidence scans all."""
    if not isinstance(expected_count, int) or isinstance(expected_count, bool) or expected_count <= 0:
        return _full_scan("invalid-expected-count", 0, expected_count)
    if not isinstance(records, list):
        return _full_scan("invalid-records", 0, expected_count)
    if len(records) != expected_count:
        return _full_scan("count-mismatch", len(records), expected_count)

    swift = False
    java = False
    python = False
    reasons: list[str] = []

    for record in records:
        if not isinstance(record, dict):
            return _full_scan("malformed-record", len(records), expected_count)

        status = record.get("status")
        filename = record.get("filename")
        previous = record.get("previous_filename")

        if status not in ALLOWED_STATUSES:
            return _full_scan("unknown-status", len(records), expected_count)
        if not _well_formed_path(filename):
            return _full_scan("malformed-filename", len(records), expected_count)

        paths = [str(filename)]
        if status in {"renamed", "copied"}:
            if not _well_formed_path(previous):
                return _full_scan("malformed-previous-filename", len(records), expected_count)
            paths.append(str(previous))
        elif previous not in (None, ""):
            return _full_scan("unexpected-previous-filename", len(records), expected_count)

        for path in paths:
            if full_scan_path(path):
                return _full_scan(f"full-scan-input:{path}", len(records), expected_count)
            if swift_input_path(path):
                if not swift:
                    reasons.append(f"swift-input:{path}")
                swift = True
            if java_input_path(path):
                if not java:
                    reasons.append(f"java-input:{path}")
                java = True
            if python_input_path(path):
                if not python:
                    reasons.append(f"python-input:{path}")
                python = True

    if not reasons:
        reasons.append("no-heavy-language-input-change")

    return {
        "actions_impact": True,
        "swift_impact": swift,
        "java_impact": java,
        "python_impact": python,
        "reason": ",".join(reasons),
        "observed_file_count": len(records),
        "expected_file_count": expected_count,
    }


def classify_payload(meta: Any, pages: Any) -> dict[str, Any]:
    try:
        if not isinstance(meta, dict):
            raise ValueError("pull-request metadata must be an object")
        expected_count = meta.get("changed_files")
        records = flatten_pages(pages)
        return classify(records, expected_count)
    except (TypeError, ValueError) as exc:
        expected = meta.get("changed_files") if isinstance(meta, dict) else None
        return _full_scan(f"metadata-error:{exc}", 0, expected)


def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _write_github_output(path: Path, result: dict[str, Any]) -> None:
    with path.open("a", encoding="utf-8") as stream:
        for key in ("actions_impact", "swift_impact", "java_impact", "python_impact"):
            stream.write(f"{key}={str(result[key]).lower()}\n")
        stream.write(f"reason={result['reason']}\n")


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--meta", type=Path, required=True)
    parser.add_argument("--pages", type=Path, required=True)
    parser.add_argument("--output-json", type=Path)
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args(list(argv) if argv is not None else None)

    try:
        meta = _read_json(args.meta)
        pages = _read_json(args.pages)
        result = classify_payload(meta, pages)
    except (OSError, json.JSONDecodeError) as exc:
        result = _full_scan(f"input-error:{exc.__class__.__name__}", 0, None)

    encoded = json.dumps(result, indent=2, sort_keys=True)
    print(encoded)

    if args.output_json:
        args.output_json.write_text(encoded + "\n", encoding="utf-8")
    if args.github_output:
        _write_github_output(args.github_output, result)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
