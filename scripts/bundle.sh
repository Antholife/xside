#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# XSIDE_CONFIG=debug builds a debug bundle (enables the DEBUG-only test hooks).
CONFIG="${XSIDE_CONFIG:-release}"

swift build -c "$CONFIG" --product XSideApp
swift build -c "$CONFIG" --product XSideWakeHelper
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP=build/XSide.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN_DIR/XSideApp" "$APP/Contents/MacOS/XSide"
cp "$BIN_DIR/XSideWakeHelper" "$APP/Contents/MacOS/XSideWakeHelper"
cp App/LaunchDaemons/io.github.xside.wakehelper.plist "$APP/Contents/Library/LaunchDaemons/"
cp App/Info.plist "$APP/Contents/Info.plist"
cp -R App/Resources/*.lproj "$APP/Contents/Resources/"
cp App/Resources/MenuBarIcon.pdf App/Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/ProvisioningTemplate "$APP/Contents/Resources/ProvisioningTemplate"

# Nested helper first (with its own identifier), then the app, which seals it.
codesign -s - --force --identifier io.github.xside.wakehelper "$APP/Contents/MacOS/XSideWakeHelper"
codesign -s - --force "$APP"
plutil -lint "$APP/Contents/Info.plist" "$APP/Contents/Library/LaunchDaemons/io.github.xside.wakehelper.plist"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($CONFIG)"
