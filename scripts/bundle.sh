#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# CONFIG=debug builds build/XSide-debug.app (bundle id io.github.xside.XSide.debug), with the
# XSIDE_FAKE_* test hooks.
CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG" --product XSideApp
BIN="$(swift build -c "$CONFIG" --product XSideApp --show-bin-path)/XSideApp"

APP=build/XSide.app
[ "$CONFIG" = debug ] && APP=build/XSide-debug.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/XSide"
cp App/Info.plist "$APP/Contents/Info.plist"
# The debug bundle gets its own identity: its defaults, notifications and permissions stay apart
# from the release app's.
[ "$CONFIG" = debug ] && plutil -replace CFBundleIdentifier -string io.github.xside.XSide.debug "$APP/Contents/Info.plist"
# Build stamp for Settings > About: commit count as build number, short commit, build date.
if git rev-parse --git-dir >/dev/null 2>&1; then
    COMMIT="$(git rev-parse --short HEAD)"
    git diff --quiet HEAD -- 2>/dev/null || COMMIT="$COMMIT-dirty"
    plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
    plutil -replace XSideGitCommit -string "$COMMIT" "$APP/Contents/Info.plist"
fi
plutil -replace XSideBuildDate -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$APP/Contents/Info.plist"
cp -R App/Resources/*.lproj "$APP/Contents/Resources/"
cp App/Resources/MenuBarIcon.pdf App/Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/ProvisioningTemplate "$APP/Contents/Resources/ProvisioningTemplate"

# Ad-hoc signature. The release bundle gets the hardened runtime: the private CoreUI framework
# the icon helper loads is a system library, which the runtime allows.
SIGN_OPTIONS=()
[ "$CONFIG" = release ] && SIGN_OPTIONS=(--options runtime)
codesign -s - --force --deep "${SIGN_OPTIONS[@]+"${SIGN_OPTIONS[@]}"}" "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
