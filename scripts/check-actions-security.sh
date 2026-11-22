#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_DIR="${RUNNER_TEMP:-$(mktemp -d)}/crossinput-workflow-security"
ACTIONLINT_BIN="${ACTIONLINT_BIN:-$ROOT/actionlint}"
mkdir -p "$TOOLS_DIR"

if [ ! -x "$ACTIONLINT_BIN" ]; then
  echo "managed actionlint binary is missing or not executable: $ACTIONLINT_BIN" >&2
  exit 1
fi

"$ACTIONLINT_BIN" "$ROOT"/.github/workflows/*.yml

fixture_dir="$TOOLS_DIR/negative/.github/workflows"
mkdir -p "$fixture_dir"
fixture="$fixture_dir/unsafe.yml"
cat > "$fixture" <<'YAML'
name: Deliberately Unsafe
on: push
permissions: write-all
jobs:
  unsafe:
    runs-on: ubuntu-nonexistent-runner
    steps:
      - uses: actions/checkout@v4
YAML

actionlint_status=0
actionlint_output="$("$ACTIONLINT_BIN" -no-color "$fixture" 2>&1)" || actionlint_status=$?
if [ "$actionlint_status" -eq 0 ] || ! grep -q 'runner-label' <<<"$actionlint_output"; then
  echo "workflow-security negative control: actionlint did not prove the expected runner finding" >&2
  printf '%s\n' "$actionlint_output" >&2
  exit 1
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "zizmor_fixture=$fixture_dir" >> "$GITHUB_OUTPUT"
fi

echo "managed actionlint static analysis and runner-label negative control: PASS"
