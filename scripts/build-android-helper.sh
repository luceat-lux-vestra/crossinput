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
  local sdkman_dir="$HOME/.sdkman/candidates/java"

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

  # Native macOS JDK discovery when the JDK is registered with java_home.
  if [ "$(uname -s)" = "Darwin" ] && [ -x /usr/libexec/java_home ]; then
    candidate="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
    if is_java_17_home "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  # SDKMAN 'current' may point at a newer default JDK. Scan every installed
  # SDKMAN candidate and select the first actual Java 17 home instead of
  # assuming that the current symlink is Java 17.
  if [ -d "$sdkman_dir" ]; then
    for candidate in "$sdkman_dir"/*; do
      [ -d "$candidate" ] || continue
      if is_java_17_home "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi

  return 1
}

JAVA_HOME="$(resolve_java_17_home || true)"
if [ -z "$JAVA_HOME" ]; then
  echo "ERROR: JDK 17 not found." >&2
  echo "  Install/configure JDK 17, or set JAVA_17_HOME to its home directory." >&2
  echo "  SDKMAN check: ls -1 \"$HOME/.sdkman/candidates/java\"" >&2
  if [ "$(uname -s)" = "Darwin" ]; then
    echo "  macOS check: /usr/libexec/java_home -V" >&2
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
