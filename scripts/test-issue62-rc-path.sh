#!/usr/bin/env bash
# CI fixture for review round 5 item 6: exercises the ACTUAL rc/result-
# discovery code in verify-device-issue62.sh via its --self-test-rc-path
# mode (cxi-stress exits 3 with no result JSON; the production loop must
# reach the PRECONDITION branch and exit 3, not abort under set -euo pipefail).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/verify-device-issue62.sh" --self-test-rc-path
