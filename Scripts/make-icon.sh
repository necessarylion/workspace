#!/bin/bash
# Regenerates Resources/AppIcon.icns from icon.png.
#
# The source artwork is a full-bleed square whose glyph is *cut out* (alpha 0),
# so it gets composited over white first, then inset to Apple's icon grid: an
# 824x824 rounded body (corner radius 185) centred on a 1024x1024 canvas. Without
# that inset the icon looks noticeably larger than every other app in the Dock.
#
# Needs ImageMagick (`brew install imagemagick`); iconutil ships with macOS.
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="${1:-icon.png}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

magick "$SRC" -resize 824x824 "$WORK/body.png"
magick -size 824x824 xc:white "$WORK/body.png" -composite "$WORK/art.png"
magick -size 824x824 xc:black -fill white \
    -draw "roundrectangle 0,0,823,823,185,185" "$WORK/mask.png"
magick "$WORK/art.png" "$WORK/mask.png" -alpha off \
    -compose CopyOpacity -composite "$WORK/rounded.png"
magick -size 1024x1024 xc:none "$WORK/rounded.png" -gravity center -composite "$WORK/icon.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"
gen() { magick "$WORK/icon.png" -resize "${1}x${1}" "$ICONSET/${2}.png"; }
gen 16   icon_16x16;   gen 32   icon_16x16@2x
gen 32   icon_32x32;   gen 64   icon_32x32@2x
gen 128  icon_128x128; gen 256  icon_128x128@2x
gen 256  icon_256x256; gen 512  icon_256x256@2x
gen 512  icon_512x512; gen 1024 icon_512x512@2x

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Resources/AppIcon.icns"
