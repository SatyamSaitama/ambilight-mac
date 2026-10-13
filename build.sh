#!/bin/bash
# Build both targets against the same engine; validate before replacing the app.
set -euo pipefail
cd "$(dirname "$0")"

stage=$(mktemp -d "${TMPDIR:-/tmp/}ambilight-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
shared=(Engine.swift Configuration.swift Output.swift Cinema.swift)

echo "Building CLI and regression suite"
swiftc -O "${shared[@]}" SelfTests.swift main.swift -o "$stage/ambilight"
"$stage/ambilight" --selftest

echo "Building menu app"
app="$stage/Ambilight.app"
mkdir -p "$app/Contents/MacOS"
swiftc -O "${shared[@]}" app/MenuBarApp.swift -o "$app/Contents/MacOS/Ambilight"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Ambilight</string>
  <key>CFBundleDisplayName</key><string>Ambilight</string>
  <key>CFBundleIdentifier</key><string>local.ambilight.menubar</string>
  <key>CFBundleExecutable</key><string>Ambilight</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Ambilight sends screen colours to your selected light controller over Bluetooth.</string>
  <key>NSBluetoothPeripheralUsageDescription</key><string>Ambilight sends colours to your selected light controller over Bluetooth.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Ambilight samples your selected screen or movie window to match its lighting.</string>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - --identifier local.ambilight.menubar "$app"
codesign --verify --strict "$app"

# Retain the original working binary as well as the user's v0 Git snapshot.
if [ -d Ambilight.app ] && [ ! -d backups/Ambilight-v0.app ]; then
  mkdir -p backups
  ditto Ambilight.app backups/Ambilight-v0.app
fi
if [ -d Ambilight.app ]; then mv Ambilight.app "$stage/previous.app"; fi
if ! mv "$app" Ambilight.app; then
  if [ -d "$stage/previous.app" ]; then mv "$stage/previous.app" Ambilight.app; fi
  exit 1
fi
mv "$stage/ambilight" ambilight
echo "Built: $PWD/Ambilight.app"
