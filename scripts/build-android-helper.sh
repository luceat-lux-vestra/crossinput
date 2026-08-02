#!/usr/bin/env bash
set -euo pipefail

# Android helper 빌드 스크립트
# 사용: ./scripts/build-android-helper.sh [assembleDebug|test|clean...]
# 기본: assembleDebug

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK="${1:-assembleDebug}"

ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
JAVA_HOME="${JAVA_17_HOME:-$HOME/.sdkman/candidates/java/17.0.18-amzn}"

echo "==> build-android-helper: $TASK"
echo "    JAVA_HOME=$JAVA_HOME"
echo "    ANDROID_HOME=$ANDROID_HOME"

if [ ! -x "$ROOT/android/helper/gradlew" ]; then
  echo "ERROR: gradle wrapper 없음: android/helper/gradlew" >&2
  echo "  Android Studio에서 android/helper를 열어 'gradle wrapper'를 생성하거나," >&2
  echo "  설치된 gradle로 다음을 실행하세요: gradle -p android/helper wrapper" >&2
  exit 1
fi

JAVA_HOME="$JAVA_HOME" ANDROID_HOME="$ANDROID_HOME" \
  "$ROOT/android/helper/gradlew" -p "$ROOT/android/helper" "$TASK" --console=plain
