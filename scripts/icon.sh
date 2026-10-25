#!/bin/sh
# Compiles Resources/AppIcon.icon (Icon Composer format, full-bleed art that macOS masks itself)
# into Resources/Assets.car, plus Resources/AppIcon.icns for macOS before 26. Needs Xcode.
set -e
cd "$(dirname "$0")/.."
out=$(mktemp -d)
xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$out" --app-icon AppIcon --platform macosx \
    --minimum-deployment-target 14.0 --output-partial-info-plist "$out/partial.plist" >/dev/null
cp "$out/Assets.car" "$out/AppIcon.icns" Resources/
rm -rf "$out"
echo "Wrote Resources/Assets.car and Resources/AppIcon.icns"
