#!/bin/bash
# Builds the CLI and the menu bar app, and assembles Ambilight.app.
#
# Both targets link Engine.swift. The app does NOT bundle the CLI binary: it
# runs the engine in-process, because macOS attributes a screen-capture request
# to the binary that makes it, and a spawned helper has no grantable TCC
# identity of its own.
set -e
cd "$(dirname "$0")"

APP="Ambilight.app"
MACOS="$APP/Contents/MacOS"

echo "==> cli"
swiftc -O Engine.swift main.swift -o ambilight

echo "==> self-test"
./ambilight --selftest >/dev/null

echo "==> app"
swiftc -O Engine.swift app/MenuBarApp.swift -o /tmp/AmbilightApp.bin

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$MACOS"
cp /tmp/AmbilightApp.bin "$MACOS/Ambilight"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Ambilight</string>
  <key>CFBundleDisplayName</key><string>Ambilight</string>
  <key>CFBundleIdentifier</key><string>local.ambilight.menubar</string>
  <key>CFBundleExecutable</key><string>Ambilight</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Ambilight sends colours to your LED controller over Bluetooth.</string>
  <key>NSBluetoothPeripheralUsageDescription</key>
  <string>Ambilight sends colours to your LED controller over Bluetooth.</string>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (codesign skipped)"

test -f "$MACOS/Ambilight" || { echo "!! bundle missing its binary"; exit 1; }
echo "==> done: $PWD/$APP"
