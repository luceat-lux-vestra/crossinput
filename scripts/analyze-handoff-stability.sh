#!/usr/bin/env bash
# ADR-0012 Level-3 stability gate entry point.
#
# Usage: scripts/analyze-handoff-stability.sh [--required N] [--window-id ID]
#        [--json-out FILE] <evidence-log...>
#
# Offline, fail-closed analysis of sanitized diagnostics. Delegates to
# scripts/lib/handoff_stability.py (single canonical gate computation).
# Exit codes: 0 PASS/INCOMPLETE · 1 FAIL · 3 HOLD · 2 input error.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/lib/handoff_stability.py" "$@"
