#!/usr/bin/env bash
# ADR-0012 Level-3 stability gate entry point.
#
# Usage: scripts/analyze-handoff-stability.sh [--window-id ID] [--json-out FILE]
#        [--lineage-manifest MANIFEST.json] <evidence-log...>
#
# Offline, fail-closed analysis of sanitized diagnostics. Delegates to
# scripts/lib/handoff_stability.py (single canonical gate computation).
# The automatic diagnostic subset requires 10 contract-complete normal
# physical cycles per ADR-0012. Full Level-3 completion additionally requires
# the reviewed scenario matrix and real-use soak; analyzer PASS alone is not
# sufficient.
# Exit codes: 0 PASS/INCOMPLETE · 1 FAIL · 3 HOLD · 2 input error.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/lib/handoff_stability.py" "$@"
