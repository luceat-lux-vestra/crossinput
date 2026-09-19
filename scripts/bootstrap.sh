#!/usr/bin/env bash
set -euo pipefail

# Ampersand repository bootstrap script
# Usage: ./scripts/bootstrap.sh [--no-git]
#
# What it does:
#   1. install git hooks (if present)
#   2. verify Android SDK location (~/Library/Android/sdk)
#   3. verify the Android helper Gradle wrapper
#   4. verify required tools (adb, xcodebuild, Java 25 LTS, Node.js 26)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ANDROID_SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
JAVA_25="${JAVA_25_HOME:-${JAVA_HOME:-$HOME/.sdkman/candidates/java/current}}"

echo "==> Ampersand bootstrap"
echo "    root: $ROOT"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# --- tool checks ------------------------------------------------------------
command -v adb >/dev/null || fail "adb not found in PATH (platform-tools)"
command -v xcodebuild >/dev/null || fail "xcodebuild not found (Xcode required)"
command -v node >/dev/null || fail "node not found in PATH (Node.js 26.9.0 required)"
[ -d "$ANDROID_SDK" ] || fail "Android SDK not found: $ANDROID_SDK (set ANDROID_HOME)"
[ -f "$ANDROID_SDK/platforms/android-37.0/android.jar" ] || fail "Android 17 SDK platform missing: $ANDROID_SDK/platforms/android-37.0/android.jar"
[ -d "$ANDROID_SDK/build-tools/37.0.0" ] || fail "Android build-tools 37.0.0 missing: $ANDROID_SDK/build-tools/37.0.0"
[ -x "$JAVA_25/bin/java" ] || fail "Java 25 not found: $JAVA_25 (set JAVA_HOME or JAVA_25_HOME)"
JAVA_VERSION="$("$JAVA_25/bin/java" -version 2>&1 | awk -F'"' '/version/ {print $2; exit}')"
[ "${JAVA_VERSION%%.*}" = "25" ] || fail "Java 25 required: found $JAVA_VERSION at $JAVA_25"

echo "    adb:        $(adb version | head -1)"
echo "    android SDK: $ANDROID_SDK"
NODE_VERSION="$(node -p 'process.versions.node')"
[ "${NODE_VERSION%%.*}" = "26" ] || fail "Node.js 26 required: found $NODE_VERSION"
echo "    java 25:    $JAVA_25 ($JAVA_VERSION)"
echo "    node:       $NODE_VERSION"

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
