#!/usr/bin/env bash
set -euo pipefail

# Ampersand repository bootstrap script
# Usage: ./scripts/bootstrap.sh [--no-git]
#
# What it does:
#   1. install git hooks (if present)
#   2. verify Android SDK location (~/Library/Android/sdk)
#   3. verify the Android helper Gradle wrapper
#   4. verify required tools (adb, xcodebuild, java 17)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ANDROID_SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
JAVA_17="${JAVA_17_HOME:-$HOME/.sdkman/candidates/java/17.0.18-amzn}"

echo "==> Ampersand bootstrap"
echo "    root: $ROOT"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# --- tool checks ------------------------------------------------------------
command -v adb >/dev/null || fail "adb not found in PATH (platform-tools)"
command -v xcodebuild >/dev/null || fail "xcodebuild not found (Xcode required)"
[ -d "$ANDROID_SDK" ] || fail "Android SDK not found: $ANDROID_SDK (set ANDROID_HOME)"
[ -d "$JAVA_17" ] || fail "Java 17 not found: $JAVA_17 (set JAVA_17_HOME)"

echo "    adb:        $(adb version | head -1)"
echo "    android SDK: $ANDROID_SDK"
echo "    java 17:    $JAVA_17"

# --- Android helper wrapper -----------------------------------------------
if [ ! -x "android/helper/gradlew" ]; then
  echo "==> android/helper gradle wrapper missing — generate it:"
  echo "    (open the project in Android Studio, or run 'gradle wrapper' with gradle installed)"
fi
# --- git hooks --------------------------------------------------------------
if [ -d .git ] && [ -d scripts/hooks ]; then
  echo "==> installing git hooks"
  cp scripts/hooks/* .git/hooks/ 2>/dev/null || true
fi

echo "==> done. Next: ./scripts/build-android-helper.sh"
