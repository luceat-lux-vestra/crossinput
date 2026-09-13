#!/usr/bin/env bash
set -euo pipefail

# Android helper build script
# Usage: ./scripts/build-android-helper.sh [assembleDebug|test|clean...]
# Default: assembleDebug

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK="${1:-assembleDebug}"

ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

is_java_17_home() {
  local home="$1"
  [ -n "$home" ] || return 1
  [ -x "$home/bin/java" ] || return 1
  "$home/bin/java" -version 2>&1 | head -n1 | grep -Eq 'version "17([."]|$)'
}

resolve_java_17_home() {
  local candidate=""

  # Explicit project override wins when valid.
  if is_java_17_home "${JAVA_17_HOME:-}"; then
    printf '%s\n' "$JAVA_17_HOME"
    return 0
  fi

  # Respect an already-correct shell JAVA_HOME.
  if is_java_17_home "${JAVA_HOME:-}"; then
    printf '%s\n' "$JAVA_HOME"
    return 0
  fi

  # Native macOS JDK discovery; avoids machine-specific SDKMAN paths.
  if [ "$(uname -s)" = "Darwin" ] && [ -x /usr/libexec/java_home ]; then
    candidate="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
    if is_java_17_home "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  # Common SDKMAN fallback without pinning a particular patch/vendor directory.
  candidate="$HOME/.sdkman/candidates/java/current"
  if is_java_17_home "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

JAVA_HOME="$(resolve_java_17_home || true)"
if [ -z "$JAVA_HOME" ]; then
  echo "ERROR: JDK 17 not found." >&2
  echo "  Install/configure JDK 17, or set JAVA_17_HOME to its home directory." >&2
  if [ "$(uname -s)" = "Darwin" ]; then
    echo "  macOS check: /usr/libexec/java_home -v 17" >&2
  fi
  exit 1
fi

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
