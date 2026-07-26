#!/bin/bash
# Regenerates Resources/AppIcon.icns from icon.png.
#
# The source artwork is the mark alone on transparency. What the icon needs is
# a body to sit on, and it is built here rather than drawn by hand: a dark
# green-black gradient, lifted in the middle by a green radial glow so the mark
# looks lit rather than pasted on, with a faint white edge to keep the corners
# from dissolving into a dark Dock. The mark is inset within that body — it
# would touch the rounded corners otherwise.
#
# The body fills the whole 1024x1024 canvas (corner radius 230). Apple's own
# grid would inset it to 824, which is what makes most icons sit at a common
# size; this one deliberately runs edge to edge instead, so it reads slightly
# larger than its neighbours.
#
# Needs ImageMagick (`brew install imagemagick`); iconutil ships with macOS.
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="${1:-icon.png}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

magick -size 1024x1024 gradient:'#1E312B'-'#080D0C' "$WORK/body.png"
magick -size 1024x1024 radial-gradient:'#2FD4AE'-'#000000' \
    -evaluate multiply 0.30 "$WORK/glow.png"
magick "$WORK/body.png" "$WORK/glow.png" -compose screen -composite "$WORK/lit.png"

magick "$SRC" -resize 770x770 "$WORK/mark.png"
magick "$WORK/lit.png" "$WORK/mark.png" -gravity center -composite "$WORK/art.png"
magick "$WORK/art.png" -fill none -stroke 'rgba(255,255,255,0.10)' -strokewidth 6 \
    -draw "roundrectangle 3,3,1020,1020,228,228" "$WORK/edged.png"

magick -size 1024x1024 xc:black -fill white \
    -draw "roundrectangle 0,0,1023,1023,230,230" "$WORK/mask.png"
magick "$WORK/edged.png" "$WORK/mask.png" -alpha off \
    -compose CopyOpacity -composite "$WORK/icon.png"

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
