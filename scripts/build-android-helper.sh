#!/usr/bin/env bash
set -euo pipefail

# Android helper build script
# Usage: ./scripts/build-android-helper.sh [assembleDebug|test|clean...]
# Default: assembleDebug
#
# The project build/runtime JDK is Java 25 LTS. JAVA_25_HOME can override
# JAVA_HOME explicitly; otherwise the caller's JAVA_HOME is respected.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK="${1:-assembleDebug}"

ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
JAVA_HOME="${JAVA_25_HOME:-${JAVA_HOME:-$HOME/.sdkman/candidates/java/current}}"

if [ ! -x "$JAVA_HOME/bin/java" ]; then
  echo "ERROR: Java 25 JDK not found at JAVA_HOME=$JAVA_HOME" >&2
  echo "  set JAVA_HOME (or JAVA_25_HOME) to a Java 25 installation" >&2
  exit 1
fi

JAVA_VERSION="$("$JAVA_HOME/bin/java" -version 2>&1 | awk -F'"' '/version/ {print $2; exit}')"
JAVA_MAJOR="${JAVA_VERSION%%.*}"
if [ "$JAVA_MAJOR" != "25" ]; then
  echo "ERROR: Java 25 is required, found $JAVA_VERSION at $JAVA_HOME" >&2
  echo "  with SDKMAN: sdk install java 25.0.4-tem && sdk use java 25.0.4-tem" >&2
  exit 1
fi

if [ ! -f "$ANDROID_HOME/platforms/android-37.0/android.jar" ]; then
  echo "ERROR: Android 17 platform (API 37) is missing under $ANDROID_HOME" >&2
  echo '  install with: sdkmanager --install "platforms;android-37.0" "build-tools;37.0.0"' >&2
  exit 1
fi

if [ ! -d "$ANDROID_HOME/build-tools/37.0.0" ]; then
  echo "ERROR: Android build-tools 37.0.0 is missing under $ANDROID_HOME" >&2
  echo '  install with: sdkmanager --install "platforms;android-37.0" "build-tools;37.0.0"' >&2
  exit 1
fi

echo "==> build-android-helper: $TASK"
echo "    JAVA_HOME=$JAVA_HOME"
echo "    JAVA_VERSION=$JAVA_VERSION"
echo "    ANDROID_HOME=$ANDROID_HOME"

if [ ! -x "$ROOT/android/helper/gradlew" ]; then
  echo "ERROR: gradle wrapper missing: android/helper/gradlew" >&2
  echo "  open android/helper in Android Studio to generate 'gradle wrapper', or" >&2
  echo "  run the following with an installed gradle: gradle -p android/helper wrapper" >&2
  exit 1
fi

JAVA_HOME="$JAVA_HOME" ANDROID_HOME="$ANDROID_HOME" \
  "$ROOT/android/helper/gradlew" -p "$ROOT/android/helper" "$TASK" --console=plain
