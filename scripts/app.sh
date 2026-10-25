#!/bin/sh
# Builds tegi.app, so macOS asks for Accessibility and Screen Recording for
# tegi itself rather than for the terminal it was started from.
# With "run", also quits the running tegi and starts the new build.
set -e
cd "$(dirname "$0")/.."
swift build -c release
app=.build/tegi.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/tegi "$app/Contents/MacOS/tegi"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.tegi</string>
    <key>CFBundleName</key><string>tegi</string>
    <key>CFBundleExecutable</key><string>tegi</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - --identifier dev.tegi "$app"

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
    echo "Built $app. Start it with: open $app (or ./scripts/app.sh run)"
fi
