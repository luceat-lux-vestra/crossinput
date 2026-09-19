#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
JAVA_HOME="${JAVA_25_HOME:-${JAVA_HOME:-$HOME/.sdkman/candidates/java/current}}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[ -x "$JAVA_HOME/bin/java" ] || fail "JAVA_HOME does not contain java: $JAVA_HOME"
JAVA_VERSION="$("$JAVA_HOME/bin/java" -version 2>&1 | awk -F'"' '/version/ {print $2; exit}')"
[ "${JAVA_VERSION%%.*}" = "25" ] || fail "Java 25 required; found $JAVA_VERSION"

[ -f "$ANDROID_HOME/platforms/android-37.0/android.jar" ] ||
  fail "Android 17 platform missing: $ANDROID_HOME/platforms/android-37.0/android.jar"
[ -d "$ANDROID_HOME/build-tools/37.0.0" ] ||
  fail "Android build-tools 37.0.0 missing: $ANDROID_HOME/build-tools/37.0.0"

GRADLE_INFO="$(
  cd "$ROOT/android/helper"
  JAVA_HOME="$JAVA_HOME" ANDROID_HOME="$ANDROID_HOME" ./gradlew --version
)"
printf '%s\n' "$GRADLE_INFO"
printf '%s\n' "$GRADLE_INFO" | grep -Eq '^Gradle 9\.7\.1$' ||
  fail "Gradle wrapper is not 9.7.1"
printf '%s\n' "$GRADLE_INFO" | grep -Eq '^(Launcher JVM|JVM): .*25' ||
  fail "Gradle is not running on Java 25"

python3 - "$ROOT/android/helper/app/build" <<'PY'
from pathlib import Path
import sys

build = Path(sys.argv[1])
candidates = [
    p for p in build.rglob("*.class")
    if "/com/crossinput/helper/" in p.as_posix()
]

if not candidates:
    searched = "\n".join(
        str(p.relative_to(build))
        for p in sorted(build.rglob("*.class"))[:50]
    )
    raise SystemExit(
        "ERROR: no compiled helper Kotlin classes found under app/build"
        + (f"\nObserved classfiles:\n{searched}" if searched else "")
    )

bad = []
for path in candidates:
    data = path.read_bytes()[:8]
    if len(data) < 8 or data[:4] != b"\xca\xfe\xba\xbe":
        bad.append((path, "invalid-classfile"))
        continue
    major = int.from_bytes(data[6:8], "big")
    if major != 69:
        bad.append((path, f"major={major}"))

if bad:
    for path, reason in bad[:20]:
        print(f"ERROR: {path}: {reason}", file=sys.stderr)
    raise SystemExit(
        f"ERROR: expected Java 25 classfile major 69; {len(bad)} class(es) differ"
    )

print(f"Verified {len(candidates)} Kotlin classfiles at Java 25 major 69")
PY

echo "Toolchain verified: Java=$JAVA_VERSION Android=37 BuildTools=37.0.0 Gradle=9.7.1 classfile=69"
