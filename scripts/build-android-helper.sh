#!/usr/bin/env bash
set -euo pipefail

# Android helper build script
# Usage: ./scripts/build-android-helper.sh [assembleDebug|test|clean...]
# Default: assembleDebug

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK="${1:-assembleDebug}"

ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
JAVA_HOME="${JAVA_17_HOME:-$HOME/.sdkman/candidates/java/17.0.18-amzn}"

echo "==> build-android-helper: $TASK"
echo "    JAVA_HOME=$JAVA_HOME"
echo "    ANDROID_HOME=$ANDROID_HOME"

if [ ! -x "$ROOT/android/helper/gradlew" ]; then
  echo "ERROR: gradle wrapper missing: android/helper/gradlew" >&2
  echo "  open android/helper in Android Studio to generate 'gradle wrapper', or" >&2
  echo "  run the following with an installed gradle: gradle -p android/helper wrapper" >&2
  exit 1
fi

JAVA_HOME="$JAVA_HOME" ANDROID_HOME="$ANDROID_HOME" \
  "$ROOT/android/helper/gradlew" -p "$ROOT/android/helper" "$TASK" --console=plain
