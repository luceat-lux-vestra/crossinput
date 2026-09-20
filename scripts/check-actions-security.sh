#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_DIR="${RUNNER_TEMP:-$(mktemp -d)}/crossinput-workflow-security"
mkdir -p "$TOOLS_DIR"

ACTIONLINT_VERSION="1.7.12"
ACTIONLINT_SHA256="8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
ZIZMOR_VERSION="1.30.0"
ZIZMOR_SHA256="ec8c95cd800845abb9bbc5f377ec7c57d2eb8e2386a00a201d3a74ee4092e5ed"

actionlint_archive="$TOOLS_DIR/actionlint.tar.gz"
zizmor_archive="$TOOLS_DIR/zizmor.tar.gz"

curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error   "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"   --output "$actionlint_archive"
echo "${ACTIONLINT_SHA256}  ${actionlint_archive}" | sha256sum -c -
tar -xzf "$actionlint_archive" -C "$TOOLS_DIR" actionlint

curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error   "https://github.com/zizmorcore/zizmor/releases/download/v${ZIZMOR_VERSION}/zizmor-x86_64-unknown-linux-gnu.tar.gz"   --output "$zizmor_archive"
echo "${ZIZMOR_SHA256}  ${zizmor_archive}" | sha256sum -c -
tar -xzf "$zizmor_archive" -C "$TOOLS_DIR" zizmor

"$TOOLS_DIR/actionlint" "$ROOT"/.github/workflows/*.yml
"$TOOLS_DIR/zizmor" --no-online-audits --format plain "$ROOT"/.github/workflows/

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
actionlint_output="$("$TOOLS_DIR/actionlint" -no-color "$fixture" 2>&1)" || actionlint_status=$?
if [ "$actionlint_status" -eq 0 ] || ! grep -q 'runner-label' <<<"$actionlint_output"; then
  echo "workflow-security negative control: actionlint did not prove the expected runner finding" >&2
  printf '%s\n' "$actionlint_output" >&2
  exit 1
fi

zizmor_status=0
zizmor_output="$("$TOOLS_DIR/zizmor" --no-online-audits --format plain --no-progress "$fixture_dir" 2>&1)" || zizmor_status=$?
if [ "$zizmor_status" -eq 0 ] || ! grep -q 'unpinned-uses' <<<"$zizmor_output"; then
  echo "workflow-security negative control: zizmor did not prove the expected unpinned action finding" >&2
  printf '%s\n' "$zizmor_output" >&2
  exit 1
fi

echo "workflow static analysis: PASS"
