#!/usr/bin/env bash
set -euo pipefail

# Generate Ampersand.app icon set (AppIcon.icns) from the source SVG.
# Requires: rsvg-convert (or magick), sips, iconutil (macOS).
# Usage: ./scripts/build-macos-icon.sh
# Output: apps/macos/Resources/AppIcon.icns  (committed)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/apps/macos/Resources/AmpersandIcon.svg"
ICONSET="$ROOT/apps/macos/Resources/AppIcon.iconset"
OUT="$ROOT/apps/macos/Resources/AppIcon.icns"

[ -f "$SRC" ] || { echo "ERROR: SVG missing: $SRC" >&2; exit 1; }

echo "==> build-macos-icon"
echo "    source: $SRC"

SIZES=(16 32 64 128 256 512 1024)
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

if command -v rsvg-convert >/dev/null 2>&1; then
  RENDER=rsvg
elif command -v magick >/dev/null 2>&1; then
  RENDER=magick
else
  echo "ERROR: need rsvg-convert or magick for SVG->PNG" >&2
  exit 1
fi

for s in "${SIZES[@]}"; do
  px="${s}x${s}"
  if [ "$RENDER" = rsvg ]; then
    rsvg-convert -w "$s" -h "$s" "$SRC" -o "$ICONSET/icon_${s}x${s}.png"
  else
    magick "$SRC" -resize "${s}x${s}" "$ICONSET/icon_${s}x${s}.png"
  fi
done

# Standard (non-retina) entries: 16, 32, 128, 256, 512
for s in 16 32 128 256 512; do
  cp "$ICONSET/icon_${s}x${s}.png" "$ICONSET/icon_${s}x${s}@1x.png"
done
# Retina entries: 32, 64, 256, 512, 1024
for s in 32 64 256 512 1024; do
  r=$((s / 2))
  if [ "$RENDER" = rsvg ]; then
    rsvg-convert -w "$s" -h "$s" "$SRC" -o "$ICONSET/icon_${r}x${r}@2x.png"
  else
    magick "$SRC" -resize "${s}x${s}" "$ICONSET/icon_${r}x${r}@2x.png"
  fi
done

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET"
echo "==> done: $OUT ($(stat -f %z "$OUT") bytes)"