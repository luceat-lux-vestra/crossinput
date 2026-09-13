#!/usr/bin/env python3
"""Fail-closed source guard for Architecture Leap semantic input boundaries (#103)."""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
MACOS = ROOT / "apps" / "macos"
DOMAIN = MACOS / "Sources" / "InputDomain"
CAPTURE = MACOS / "Sources" / "InputCapture"
PACKAGE = MACOS / "Package.swift"


def fail(message: str) -> None:
    print(f"INPUT_BOUNDARY_GUARD=FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def swift_sources(path: pathlib.Path) -> list[pathlib.Path]:
    files = sorted(path.rglob("*.swift"))
    if not files:
        fail(f"no Swift sources found under {path.relative_to(ROOT)}")
    return files


def require_no_pattern(files: list[pathlib.Path], pattern: re.Pattern[str], label: str) -> None:
    for path in files:
        text = path.read_text(encoding="utf-8")
        match = pattern.search(text)
        if match:
            line = text.count("\n", 0, match.start()) + 1
            fail(f"{label}: {path.relative_to(ROOT)}:{line}: {match.group(0)!r}")


def main() -> None:
    domain_files = swift_sources(DOMAIN)
    capture_files = swift_sources(CAPTURE)
    all_macos_swift = swift_sources(MACOS / "Sources") + swift_sources(MACOS / "Tests")

    require_no_pattern(
        domain_files,
        re.compile(r"(?m)^\s*import\s+(?:CoreGraphics|AppKit|ApplicationServices|Protocol|AndroidBridge)\b"),
        "InputDomain imports a platform/protocol module",
    )
    # These spellings represent concrete Android wire constants rather than
    # prose that merely documents the forbidden dependency categories.
    require_no_pattern(
        domain_files,
        re.compile(r"\b(?:KEYCODE_|META_)"),
        "InputDomain contains Android key/meta constants",
    )
    require_no_pattern(
        capture_files,
        re.compile(r"\b(?:KEYCODE_|META_|androidKeyCode|androidMetaState)\b"),
        "InputCapture contains Android key/meta semantics",
    )
    require_no_pattern(
        all_macos_swift,
        re.compile(r"\bCapturedKeyEvent\s*\(\s*keyCode\s*:"),
        "legacy Android-shaped CapturedKeyEvent constructor remains",
    )

    package = PACKAGE.read_text(encoding="utf-8")
    delivery = re.search(
        r'\.target\(name:\s*"Delivery",\s*dependencies:\s*\[([^\]]*)\]\)',
        package,
    )
    if not delivery:
        fail("Delivery target declaration not found in Package.swift")
    if '"InputCapture"' in delivery.group(1):
        fail("Delivery target depends on InputCapture")
    if '"InputDomain"' not in delivery.group(1):
        fail("Delivery target does not depend on InputDomain")

    domain = re.search(
        r'\.target\(name:\s*"InputDomain",\s*dependencies:\s*\[([^\]]*)\]\)',
        package,
    )
    if not domain:
        fail("InputDomain target declaration not found in Package.swift")
    if domain.group(1).strip():
        fail("InputDomain must remain dependency-free")

    print("INPUT_BOUNDARY_GUARD=PASS")


if __name__ == "__main__":
    main()
