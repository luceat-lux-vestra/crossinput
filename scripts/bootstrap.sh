#!/usr/bin/env bash
set -euo pipefail

# Ampersand 저장소 초기화 스크립트
# 사용: ./scripts/bootstrap.sh [--no-git]
#
# 하는 일:
#   1. git hooks 설치 (존재하면)
#   2. Android SDK 위치 확인 (~/Library/Android/sdk)
#   3. Android helper Gradle wrapper 확인
#   4. 필요 도구 확인 (adb, xcodebuild, java 17)

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

# --- 도구 확인 ------------------------------------------------------------
command -v adb >/dev/null || fail "adb가 PATH에 없습니다 (platform-tools)"
command -v xcodebuild >/dev/null || fail "xcodebuild가 없습니다 (Xcode 필요)"
[ -d "$ANDROID_SDK" ] || fail "Android SDK 없음: $ANDROID_SDK (ANDROID_HOME 설정 필요)"
[ -d "$JAVA_17" ] || fail "Java 17 없음: $JAVA_17 (JAVA_17_HOME 설정 필요)"

echo "    adb:        $(adb version | head -1)"
echo "    android SDK: $ANDROID_SDK"
echo "    java 17:    $JAVA_17"

# --- Android helper wrapper -----------------------------------------------
if [ ! -x "android/helper/gradlew" ]; then
  echo "==> android/helper gradle wrapper 없음 — 생성:"
  echo "    (Android Studio에서 프로젝트를 열거나, gradle 설치 후 gradle wrapper 실행)"
fi

# --- git hooks --------------------------------------------------------------
if [ -d .git ] && [ -d scripts/hooks ]; then
  echo "==> git hooks 설치"
  cp scripts/hooks/* .git/hooks/ 2>/dev/null || true
fi

echo "==> 완료. 다음: ./scripts/build-android-helper.sh"
