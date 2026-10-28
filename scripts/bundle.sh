#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product XSideApp
BIN="$(swift build -c release --product XSideApp --show-bin-path)/XSideApp"

APP=build/XSide.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/XSide"
cp App/Info.plist "$APP/Contents/Info.plist"
cp -R App/Resources/*.lproj "$APP/Contents/Resources/"
cp App/Resources/MenuBarIcon.pdf App/Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/ProvisioningTemplate "$APP/Contents/Resources/ProvisioningTemplate"

codesign -s - --force --deep "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
