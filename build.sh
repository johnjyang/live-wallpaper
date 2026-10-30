#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
stage="$(mktemp -d /tmp/live-wallpaper-build.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
app="$stage/Live Wallpaper.app"
mkdir -p "$app/Contents/MacOS"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -O -whole-module-optimization Sources/Core.swift Sources/App.swift -framework AppKit -framework AVFoundation -o "$app/Contents/MacOS/LiveWallpaper"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LiveWallpaper</string>
<key>CFBundleIdentifier</key><string>com.local.LiveWallpaper</string>
<key>CFBundleName</key><string>Live Wallpaper</string>
<key>CFBundleDisplayName</key><string>Live Wallpaper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -cr "$app"
codesign --force --sign - "$app"
output="$HOME/Library/Caches/com.local.LiveWallpaper/build/Live Wallpaper.app"
mkdir -p "$(dirname "$output")"
ditto --norsrc --noextattr "$app" "$output"
codesign --verify --strict "$output"
echo "$output"
