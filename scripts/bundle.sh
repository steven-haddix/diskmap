#!/usr/bin/env bash
# Builds a release DiskMap.app in the repo root. A real .app bundle (rather than
# the bare binary) is what lets you grant it Full Disk Access.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product DiskMap
bin="$(swift build -c release --show-bin-path)/DiskMap"

app=DiskMap.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/DiskMap"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DiskMap</string>
    <key>CFBundleDisplayName</key><string>DiskMap</string>
    <key>CFBundleIdentifier</key><string>local.diskmap</string>
    <key>CFBundleExecutable</key><string>DiskMap</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "Built $(pwd)/$app"
