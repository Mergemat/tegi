#!/bin/sh
# Builds tegi.app, so macOS asks for Accessibility and Screen Recording for
# tegi itself rather than for the terminal it was started from.
#
#   ./scripts/app.sh          build .build/tegi.app
#   ./scripts/app.sh run      build, quit the running tegi, start the new one
#
#   VERSION=0.1.0             version to stamp (default: dev)
#   FAST=1                    rebuild in seconds, optimizing file by file; not for timing motion
#   SIGN_IDENTITY="Developer ID Application: …"   sign for distribution (default: ad-hoc)
set -e
cd "$(dirname "$0")/.."

bundle_id=io.github.mergemat.tegi
version=${VERSION:-dev}
arch_flags="--arch arm64"

# Optimizing the whole module at once takes ~20 s after any change, on one core.
[ "$FAST" = 1 ] && arch_flags="$arch_flags --build-system native --scratch-path .build/fast -Xswiftc -no-whole-module-optimization"
swift build -c release $arch_flags
bin="$(swift build -c release $arch_flags --show-bin-path)/tegi"

app=.build/tegi.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/tegi"
cp Resources/AppIcon.icns Resources/Assets.car "$app/Contents/Resources/"
# arm64e, as Dock is, to inject into it.
helper_arch="-arch arm64e"
clang $helper_arch -mmacosx-version-min=14.0 -O2 -dynamiclib \
    Helpers/WindowServer/Grant.c -F /System/Library/PrivateFrameworks -framework SkyLight -framework CoreGraphics \
    -o "$app/Contents/Resources/tegi-grant.dylib"
codesign --force --sign "${SIGN_IDENTITY:--}" "$app/Contents/Resources/tegi-grant.dylib"
# The loader runs as root without a password once tegi remembers it, so it injects only this exact library.
grant_sha256=$(shasum -a 256 "$app/Contents/Resources/tegi-grant.dylib" | cut -d' ' -f1)
clang $helper_arch -mmacosx-version-min=14.0 -O2 -DTEGI_GRANT_SHA256="\"$grant_sha256\"" \
    Helpers/WindowServer/Loader.m Helpers/WindowServer/Stub.S -framework Cocoa \
    -o "$app/Contents/Resources/tegi-dock-loader"
codesign --force --sign "${SIGN_IDENTITY:--}" "$app/Contents/Resources/tegi-dock-loader"
cp Helpers/WindowServer/LICENSE.yabai "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleName</key><string>tegi</string>
    <key>CFBundleDisplayName</key><string>tegi</string>
    <key>CFBundleExecutable</key><string>tegi</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --identifier "$bundle_id" "$app"
else
    # An ad-hoc signature otherwise pins permissions to this exact build, so every
    # update would silently lose Accessibility and Screen Recording.
    codesign --force --sign - --identifier "$bundle_id" \
        --requirements "=designated => identifier \"$bundle_id\"" "$app"
fi

if [ "$1" = run ]; then
    .build/release/tegi msg quit 2>/dev/null || true
    tries=0
    while pgrep -qx tegi; do
        tries=$((tries + 1))
        [ $tries -gt 50 ] && { echo "tegi didn't quit; quit it from its menu and run again" >&2; exit 1; }
        sleep 0.1
    done
    open "$app"
    echo "Started $app"
else
    echo "Built $app ($version)"
fi
