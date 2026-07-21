#!/usr/bin/env bash
#
# make-appicon.sh — regenerate MachineSpirit Leader Key's Dock/⌘-Tab/Settings
# AppIcon from the menu-bar skull mark (HANDOFF-NOTES #38).
#
# machine-spirit philosophy #4 (runtime-light, pre-rendered assets): the
# expensive raster generation happens once, here, at build time; the rendered
# PNGs in AppIcon.appiconset are the committed artifact. This script is their
# reproducible source — re-run it if the skull mark or palette ever changes.
#
# The app icon is the *summoned* identity: the same skull silhouette as the
# menu-bar StatusItem, painted machine-spirit green (matching StatusItem-filled)
# on a dark squircle with a soft summon-glow halo — so the fork reads as the
# fork everywhere.
#
# Requires (build-only, not a runtime dep): ImageMagick + macOS `qlmanage`.
# Asset-catalog changes need an xcodebuild `clean build` to take effect
# (see AGENTS.md → "build, sign, redeploy").
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$HERE/../Leader Key/Assets.xcassets"
SRC_PDF="$ASSETS/StatusItem.imageset/StatusItem Copy.pdf"   # crisp vector silhouette

# The skull is the ONE machine-spirit identity — emitted to both bundles:
#   the launcher fork (menu-bar agent) and the MachineSpirit node-graph app.
# One source, one mark, so the suite reads as a single product in Dock + menu bar.
OUTS=(
  "$ASSETS/AppIcon.appiconset"                               # fork (launcher)
  "$HERE/../../../app/MachineSpirit/Assets.xcassets/AppIcon.appiconset"  # node-graph app
)

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

GREEN='#36DE6A'          # machine-spirit green (== StatusItem-filled summon glow)
CANVAS=1024; BODY=824; MARGIN=100; RADIUS=186; SKULL_H=520

command -v magick  >/dev/null || { echo "need ImageMagick (brew install imagemagick)"; exit 1; }
command -v qlmanage >/dev/null || { echo "need macOS qlmanage"; exit 1; }

# 1) Rasterize the vector skull at high res. QuickLook flattens PDF to black-on-white.
qlmanage -t -s 1024 -o "$TMP" "$SRC_PDF" >/dev/null 2>&1
mv "$TMP/$(basename "$SRC_PDF").png" "$TMP/skull.png"

# 2) Luminance -> mask (skull=white), then paint green keeping anti-aliasing + hollow
#    eye/nose/teeth cutouts (they fall through to the dark tile as sockets).
magick "$TMP/skull.png" -alpha off -colorspace Gray -negate "$TMP/mask.png"
magick -size ${CANVAS}x${CANVAS} xc:"$GREEN" "$TMP/mask.png" \
  -alpha off -compose CopyOpacity -composite "$TMP/skull_green.png"

# 3) Dark squircle tile + a soft green summon-glow halo hugging the skull.
magick -size ${BODY}x${BODY} gradient:'#181c1d'-'#0a0b0c' "$TMP/base.png"
magick -size ${BODY}x${BODY} xc:none -fill white \
  -draw "roundrectangle 0,0 $((BODY-1)),$((BODY-1)) $RADIUS,$RADIUS" "$TMP/rr.png"
magick "$TMP/base.png" "$TMP/rr.png" -alpha off -compose CopyOpacity -composite "$TMP/tile.png"
magick "$TMP/skull_green.png" -trim +repage -resize x${SKULL_H} "$TMP/skull_sized.png"
magick "$TMP/skull_sized.png" -background none -blur 0x26 \
  -channel A -evaluate multiply 0.55 +channel "$TMP/halo.png"
magick "$TMP/tile.png" \
  "$TMP/halo.png"        -gravity center -geometry +0-6 -compose over -composite \
  "$TMP/skull_sized.png" -gravity center -geometry +0-6 -compose over -composite \
  "$TMP/tile_full.png"

# 4) Master: place tile in the native macOS footprint (100px margin) with a drop shadow.
magick -size ${CANVAS}x${CANVAS} xc:none \
  \( "$TMP/tile_full.png" -background black -shadow 30x16+0+14 \) -gravity center -geometry +0+8 -composite \
  \(  "$TMP/tile_full.png" \)                                    -gravity northwest -geometry +${MARGIN}+${MARGIN} -composite \
  "$TMP/master.png"

# 5) Emit every size + Contents.json into each target bundle.
#    (mild unsharp keeps the skull crisp when tiny; same file backs two entries.)
read -r -d '' CONTENTS_JSON <<'JSON' || true
{
  "images" : [
    { "filename" : "icon_16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "machine-spirit", "version" : 1 }
}
JSON

for OUT in "${OUTS[@]}"; do
  [ -d "$OUT" ] || { echo "skip (no such iconset): $OUT"; continue; }
  rm -f "$OUT"/icon_*.png
  for s in 16 32 64 128 256 512 1024; do
    if [ "$s" -le 64 ]; then
      magick "$TMP/master.png" -filter Lanczos -resize ${s}x${s} -unsharp 0x0.6+0.6+0 -depth 8 -strip "$OUT/icon_${s}.png"
    else
      magick "$TMP/master.png" -filter Lanczos -resize ${s}x${s} -depth 8 -strip "$OUT/icon_${s}.png"
    fi
  done
  printf '%s\n' "$CONTENTS_JSON" > "$OUT/Contents.json"
  echo "AppIcon regenerated in: $OUT"
done
