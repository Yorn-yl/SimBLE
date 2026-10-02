#!/bin/sh
# Regenerates Icon/AppIcon.icns from draw-icon.swift. The .icns is committed, so builds do not redraw it.
set -eu
cd "$(dirname "$0")"
work="$(mktemp -d)"
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
xcrun swift draw-icon.swift "$work/icon-1024.png" 1024
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$work/icon-1024.png" --out "$iconset/icon_${size}x${size}.png" > /dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$work/icon-1024.png" --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$iconset" -o AppIcon.icns
rm -rf "$work"
echo "Built $(pwd)/AppIcon.icns"
