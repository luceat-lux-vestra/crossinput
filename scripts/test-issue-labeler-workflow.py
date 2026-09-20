#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "issue-labeler.yml"

def fail(message: str) -> None:
    raise AssertionError(message)

def main() -> int:
    source = WORKFLOW.read_text(encoding="utf-8")

    required = [
        "dry_run:",
        "backfill:",
        "DRY_RUN:",
        "BACKFILL:",
        "const dryRun = process.env.DRY_RUN === 'true';",
        "const backfill = process.env.BACKFILL === 'true';",
        "if (!dryRun) await ensureLabels();",
        "if (dryRun) return;",
        "if (!backfill)",
    ]
    for value in required:
        if value not in source:
            fail(f"missing fail-closed backlog contract: {value}")

    dry_input = re.search(
        r"dry_run:\s*\n(?:\s+.*\n){0,6}?\s+default:\s*true\b",
        source,
    )
    if not dry_input:
        fail("workflow_dispatch dry_run must default to true")

    dispatch_start = source.index("workflow_dispatch:")
    permissions_start = source.index("\npermissions:", dispatch_start)
    dispatch_block = source[dispatch_start:permissions_start]
    if not re.search(r"backfill:\s*\n(?:\s+.*\n){0,6}?\s+default:\s*true\b", dispatch_block):
        fail("workflow_dispatch backfill must be explicit and default true")

    classify_start = source.index("async function classify(issue)")
    classify_end = source.index("\n            if (!dryRun) await ensureLabels();", classify_start)
    classify = source[classify_start:classify_end]
    dry_pos = classify.index("if (dryRun) return;")
    for mutation in ("github.rest.issues.removeLabel", "github.rest.issues.addLabels"):
        mutation_pos = classify.index(mutation)
        if mutation_pos < dry_pos:
            fail(f"{mutation} occurs before dry-run guard")

    ensure_start = source.index("async function ensureLabels()")
    ensure_end = source.index("async function classify(issue)", ensure_start)
    ensure = source[ensure_start:ensure_end]
    for mutation in ("github.rest.issues.updateLabel", "github.rest.issues.createLabel"):
        if mutation not in ensure:
            fail(f"expected catalog mutation anchor missing: {mutation}")
    call_pos = source.index("if (!dryRun) await ensureLabels();")
    if call_pos < classify_end:
        fail("label catalog guard must execute after reconciliation function definition")

    print("issue labeler dry-run contract: PASS")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
