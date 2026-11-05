#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# CONFIG=debug builds build/XSide-debug.app (bundle id io.github.xside.XSide.debug), with the
# XSIDE_FAKE_* test hooks.
CONFIG="${CONFIG:-release}"
# The release app runs on Apple silicon and Intel Macs.
ARCHS=()
[ "$CONFIG" = release ] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" --product XSideApp "${ARCHS[@]+"${ARCHS[@]}"}"
swift build -c "$CONFIG" --product xside "${ARCHS[@]+"${ARCHS[@]}"}"
BIN_DIR="$(swift build -c "$CONFIG" --product XSideApp "${ARCHS[@]+"${ARCHS[@]}"}" --show-bin-path)"
BIN="$BIN_DIR/XSideApp"

APP=build/XSide.app
[ "$CONFIG" = debug ] && APP=build/XSide-debug.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/XSide"
# The command line tool (Settings > General links it into the PATH). Not in MacOS/: "xside" and
# "XSide" are the same name on a case-insensitive disk.
mkdir -p "$APP/Contents/Helpers"
cp "$BIN_DIR/xside" "$APP/Contents/Helpers/xside"
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
cp App/Resources/MenuBarIcon.pdf App/Resources/AppIcon.icns App/Resources/GitHubMark.svg "$APP/Contents/Resources/"
cp -R Resources/ProvisioningTemplate "$APP/Contents/Resources/ProvisioningTemplate"
# The welcome popup's iOS library (see App/Welcome): signed again by XSide at each install.
if xcrun -sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    # Its logo, compiled in (no file to add to the app): the app icon at 180 px.
    WELCOME_GEN="$(mktemp -d)"
    sips -Z 180 docs/assets/icon.png --out "$WELCOME_GEN/icon.png" >/dev/null
    (cd "$WELCOME_GEN" && xxd -i -n XSWelcomeIcon icon.png > XSideWelcomeIcon.h)
    # XSIDE_TEST_REMINDER=1: the on-device reminder fires a minute after launch, to try it.
    TEST_FLAGS=""
    [ "${XSIDE_TEST_REMINDER:-}" = 1 ] && TEST_FLAGS="-DXS_TEST_REMINDER" && echo "warning: test reminder build"
    xcrun -sdk iphoneos clang -dynamiclib -arch arm64 -mios-version-min=15.0 -fobjc-arc -O2 \
        -I "$WELCOME_GEN" $TEST_FLAGS \
        -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics -framework UserNotifications \
        -install_name @executable_path/Frameworks/XSideWelcome.dylib \
        -o "$APP/Contents/Resources/XSideWelcome.dylib" App/Welcome/XSideWelcome.m
    rm -rf "$WELCOME_GEN"
else
    echo "warning: no iOS SDK, building without the welcome popup library" >&2
fi
# Sparkle (self-updates): the framework next to the executable, found through its rpath.
mkdir -p "$APP/Contents/Frameworks"
cp -R "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/XSide" 2>/dev/null || true
# Only the system's Swift and the bundle's own Frameworks: the toolchain's paths (inside
# Xcode.app, writable by an admin) are searched before Frameworks, and library validation is off.
otool -l "$APP/Contents/MacOS/XSide" | awk '/LC_RPATH/ { getline; getline; print $2 }' | sort -u | while read -r path; do
    case "$path" in
        /usr/lib/swift|@executable_path/../Frameworks) ;;
        *) while install_name_tool -delete_rpath "$path" "$APP/Contents/MacOS/XSide" 2>/dev/null; do :; done ;;
    esac
done
# The debug app never updates itself (it would become the release app).
[ "$CONFIG" = debug ] && plutil -remove SUFeedURL "$APP/Contents/Info.plist"

# Ad-hoc signature. The release bundle gets the hardened runtime: the private CoreUI framework
# the icon helper loads is a system library, which the runtime allows.
SIGN_OPTIONS=()
[ "$CONFIG" = release ] && SIGN_OPTIONS=(--options runtime)
# Sparkle comes signed by its own team: re-signed ad hoc, innermost first (helpers, then the
# framework), or the hardened runtime refuses to load it into XSide ("different Team IDs").
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
# XSide isn't sandboxed: Sparkle's XPC services are for sandboxed apps only (its docs allow
# removing them), and less code ships in a process without library validation.
rm -rf "$SPARKLE/Versions/B/XPCServices"
for helper in "$SPARKLE"/Versions/B/XPCServices/*.xpc "$SPARKLE"/Versions/B/Autoupdate "$SPARKLE"/Versions/B/Updater.app; do
    [ -e "$helper" ] && codesign -s - --force "${SIGN_OPTIONS[@]+"${SIGN_OPTIONS[@]}"}" "$helper"
done
codesign -s - --force "${SIGN_OPTIONS[@]+"${SIGN_OPTIONS[@]}"}" "$SPARKLE"
codesign -s - --force "${SIGN_OPTIONS[@]+"${SIGN_OPTIONS[@]}"}" "$APP/Contents/Helpers/xside"
codesign -s - --force "${SIGN_OPTIONS[@]+"${SIGN_OPTIONS[@]}"}" --entitlements App/XSide.entitlements "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
