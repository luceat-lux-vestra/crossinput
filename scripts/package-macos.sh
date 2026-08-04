#!/usr/bin/env bash
set -euo pipefail

# macOS app packaging script — wraps the SPM executable into a distributable
# Ampersand.app bundle (menu bar app, LSUIElement).
#
# Usage: ./scripts/package-macos.sh [release|debug]
#   Default configuration is release.
#
# Produces:
#   dist/Ampersand.app/Contents/{MacOS/Ampersand, Info.plist}
#   dist/Ampersand.app.dSYM (release only, if present in the build)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"

DIST="$ROOT/dist"
BUNDLE="$DIST/Ampersand.app"
CONTENTS="$BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> package-macos ($CONFIG)"
echo "    root: $ROOT"

case "$CONFIG" in
  release)
    (cd "$ROOT/apps/macos" && swift build -c release)
    BIN_DIR="$ROOT/apps/macos/.build/arm64-apple-macosx/release"
    ;;
  debug)
    (cd "$ROOT/apps/macos" && swift build)
    BIN_DIR="$ROOT/apps/macos/.build/arm64-apple-macosx/debug"
    ;;
  *)
    echo "ERROR: unknown config '$CONFIG' (expected release|debug)" >&2
    exit 1
    ;;
esac

BIN="$BIN_DIR/Ampersand"
[ -f "$BIN" ] || { echo "ERROR: built binary not found: $BIN" >&2; exit 1; }

rm -rf "$DIST"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN" "$MACOS/Ampersand"
cp "$ROOT/apps/macos/Resources/Info.plist" "$CONTENTS/Info.plist"
[ -f "$ROOT/apps/macos/Resources/AppIcon.icns" ] && \
  cp "$ROOT/apps/macos/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"

if [ -d "$BIN_DIR/Ampersand.dSYM" ]; then
  cp -R "$BIN_DIR/Ampersand.dSYM" "$CONTENTS/Resources/Ampersand.dSYM"
fi

# Ad-hoc code signature (required on Apple Silicon for local running).
codesign --force --deep --sign - "$BUNDLE"

echo "==> done: $BUNDLE"
echo "    run: open $BUNDLE"