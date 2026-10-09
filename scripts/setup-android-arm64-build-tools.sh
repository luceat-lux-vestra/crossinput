#!/usr/bin/env bash
# GitHub ARM64 runner only: replace Android SDK's x86_64 native build tools
# with SHA-256 pinned, AOSP-built native binaries. No downloaded install script.
set -euo pipefail

test "$(uname -m)" = "aarch64"
: "${ANDROID_HOME:?Android SDK must be installed first}"
sdk_bin="$ANDROID_HOME/build-tools/37.0.0"
test -d "$sdk_bin"
tool_dir="$(mktemp -d)"
trap 'rm -rf "$tool_dir"' EXIT
base="https://github.com/Commit451/android-arm-build-tools/releases/download/platform-tools-37.0.0"

# The pinned 2026-06-18 ARM release is not an official Google distribution.
# Verify each release asset's published GitHub SHA-256 and ELF architecture.
while read -r name digest; do
  curl --proto '=https' --tlsv1.2 --fail --location --retry 3 --silent --show-error \
    "$base/$name" --output "$tool_dir/$name"
  printf '%s  %s\n' "$digest" "$tool_dir/$name" | sha256sum --check --strict
  readelf --file-header "$tool_dir/$name" | grep -Eq 'Machine:[[:space:]]*AArch64'
  install -m 0755 "$tool_dir/$name" "$sdk_bin/$name"
done <<'ASSETS'
aapt2 a41b31103da2bac2fadb53017b57e8d1f11499b8e2ff9ed89d5e31158406ae4d
aidl 71d53217765b1100c926ad6c86545f145081d3342bc914f83adc59ec315eaa64
zipalign 8d04801629e7021c10ee419a3e22a9ebc382289911ac366a94a09db798eb5d07
split-select 08f438823583fcced382a43414f789d157e85baa9f97fdcbddbc32ebd1b3f364
ASSETS

# AGP 9.x otherwise fetches an x86_64-only AAPT2 artifact from Google Maven.
# Configure the runner only: never commit machine-specific SDK paths to product.
mkdir -p "$HOME/.gradle"
printf '\nandroid.aapt2FromMavenOverride=%s/aapt2\n' "$sdk_bin" >> "$HOME/.gradle/gradle.properties"
"$sdk_bin/aapt2" version
echo "Verified native ARM Android Build Tools 37.0.0 (4 binaries) with AAPT2 override"
