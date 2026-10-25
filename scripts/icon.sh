#!/bin/sh
# Builds Resources/AppIcon.icns from the 1024 px artwork in Resources/brand/app-icon.png.
set -e
cd "$(dirname "$0")/.."
set_dir=$(mktemp -d)/AppIcon.iconset
mkdir -p "$set_dir"
for points in 16 32 128 256 512; do
    sips -z $points $points Resources/brand/app-icon.png --out "$set_dir/icon_${points}x${points}.png" >/dev/null
    sips -z $((points * 2)) $((points * 2)) Resources/brand/app-icon.png --out "$set_dir/icon_${points}x${points}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o Resources/AppIcon.icns
rm -rf "$(dirname "$set_dir")"
echo "Wrote Resources/AppIcon.icns"
