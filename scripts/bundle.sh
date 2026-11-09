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
# Third-party components built from pinned source (scripts/*.env, scripts/fetch-pinned.sh). Each adds
# a section to Acknowledgements.txt: "<name> <tag> (<short SHA>) <repo URL>", then its LICENSE verbatim.
ACK="$APP/Contents/Resources/Acknowledgements.txt"
: > "$ACK"
# zstd: the decompression-only helper for .deb members and repo indexes.
. scripts/zstd.env
UNZSTD_STATUS=0
scripts/build-unzstd.sh >/dev/null || UNZSTD_STATUS=$?
if [ "$UNZSTD_STATUS" = 0 ]; then
    cp build/zstd/xside-unzstd "$APP/Contents/Helpers/xside-unzstd"
    {
        echo "zstd $ZSTD_TAG (${ZSTD_COMMIT:0:7}) ${ZSTD_REPO%.git}"
        echo
        cat build/zstd-src/LICENSE
        [ -f build/zstd-src/NOTICE ] && { echo; cat build/zstd-src/NOTICE; }
        echo
    } >> "$ACK"
elif [ "$UNZSTD_STATUS" = 3 ]; then
    echo "warning: building without the zstd helper (no source); release.sh will refuse this build" >&2
else
    exit "$UNZSTD_STATUS"
fi
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
    # XSIDE_TEST_LATE=1: the launch pill always in its late (or paused) state, to see it.
    TEST_FLAGS=""
    [ "${XSIDE_TEST_REMINDER:-}" = 1 ] && TEST_FLAGS="$TEST_FLAGS -DXS_TEST_REMINDER" && echo "warning: test reminder build"
    [ "${XSIDE_TEST_LATE:-}" = 1 ] && TEST_FLAGS="$TEST_FLAGS -DXS_TEST_LATE" && echo "warning: test late pill build"
    # Every App/Welcome/*.m (XSChannelCore.m and XSSettingsCore.m are also checked on the Mac by
    # scripts/test-welcome-hmac.sh).
    xcrun -sdk iphoneos clang -dynamiclib -arch arm64 -mios-version-min=15.0 -fobjc-arc -O2 -Wall \
        -I "$WELCOME_GEN" -I App/Welcome $TEST_FLAGS \
        -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics -framework UserNotifications \
        -framework Network -framework Security \
        -install_name @executable_path/Frameworks/XSideWelcome.dylib \
        -o "$APP/Contents/Resources/XSideWelcome.dylib" App/Welcome/*.m
    rm -rf "$WELCOME_GEN"
    # The "Simulate signed-out iCloud" library (App/ICloud), an install option of its own:
    # independent of the module above, added only to the installations that have the option.
    # CloudKit linked weakly: loaded before the library's constructor, which hooks it at once, even
    # in an app that doesn't link it (Core Data/SwiftData load it at runtime and use it right away).
    # Same warnings as scripts/test-icloud-shim.sh.
    xcrun -sdk iphoneos clang -dynamiclib -arch arm64 -mios-version-min=15.0 -fobjc-arc -O2 \
        -Wall -Wextra -Werror -Wno-unused-parameter \
        -I App/ICloud -framework Foundation -weak_framework CloudKit \
        -install_name @executable_path/Frameworks/XSideICloud.dylib \
        -o "$APP/Contents/Resources/XSideICloud.dylib" App/ICloud/*.m
    # The iPhone Duo option's compatibility module (App/DuoLegacy), added only to apps without scene
    # support of their own when the option is on; independent of XSide's module too.
    xcrun -sdk iphoneos clang -dynamiclib -arch arm64 -mios-version-min=15.0 -fobjc-arc -O2 \
        -Wall -Wextra -Werror -Wno-unused-parameter \
        -framework UIKit -framework Foundation -framework CoreGraphics -weak_framework CoreMotion \
        -install_name @executable_path/Frameworks/XSideDuoLegacy.dylib \
        -o "$APP/Contents/Resources/XSideDuoLegacy.dylib" App/DuoLegacy/*.m
    # The converted tweaks' path redirect (App/TweakSupport), added with them under
    # Frameworks/XSideTweaks/; inert unless the Info.plist says XSideTweakPaths. UIKit is looked up
    # at runtime, not linked. Same warnings as scripts/test-tweak-support.sh.
    xcrun -sdk iphoneos clang -dynamiclib -arch arm64 -mios-version-min=15.0 -fobjc-arc -O2 \
        -Wall -Wextra -Werror -Wno-unused-parameter \
        -I App/TweakSupport -framework Foundation \
        -install_name @executable_path/Frameworks/XSideTweaks/XSideTweakSupport.dylib \
        -o "$APP/Contents/Resources/XSideTweakSupport.dylib" App/TweakSupport/*.m App/TweakSupport/*.c
    # ElleKit (scripts/ellekit.env): the hooking library that replaces Substrate in converted
    # tweaks, added under Frameworks/XSideTweaks/ with its licence (ElleKit-LICENSE.txt).
    # Its Xcode project's "ellekit" scheme builds the hooking library alone (target ellekit,
    # libellekit.dylib, sources ellekit/ + ellekitc/), without the injector, launchd hook, pspawn
    # loader or safe mode. No Theos needed. Always a Release build, in build/ellekit (derived data
    # included, nothing in ~/Library).
    . scripts/ellekit.env
    ELLEKIT_STATUS=0
    ELLEKIT_SRC="$(scripts/fetch-pinned.sh ellekit "$ELLEKIT_REPO" "$ELLEKIT_COMMIT")" || ELLEKIT_STATUS=$?
    if [ "$ELLEKIT_STATUS" = 0 ]; then
        ELLEKIT_OUT=build/ellekit
        mkdir -p "$ELLEKIT_OUT"
        if ! xcodebuild -quiet -project "$ELLEKIT_SRC/ellekit.xcodeproj" -scheme ellekit -configuration Release \
            -destination 'generic/platform=iOS' -derivedDataPath "$ELLEKIT_OUT" \
            ARCHS="arm64 arm64e" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=15.0 \
            build > "$ELLEKIT_OUT/build.log" 2>&1; then
            grep -E 'error:' "$ELLEKIT_OUT/build.log" | head -20 >&2
            echo "error: ElleKit build failed (log: $ELLEKIT_OUT/build.log)" >&2
            exit 1
        fi
        ELLEKIT_LIB="$APP/Contents/Resources/ElleKit.dylib"
        cp "$ELLEKIT_OUT/Build/Products/Release-iphoneos/libellekit.dylib" "$ELLEKIT_LIB"
        install_name_tool -id @executable_path/Frameworks/XSideTweaks/ElleKit.dylib "$ELLEKIT_LIB" 2>/dev/null
        # install_name_tool voids the linker's ad-hoc signature (XSide signs it again at each install).
        codesign -s - --force "$ELLEKIT_LIB" 2>/dev/null
        cp "$ELLEKIT_SRC/LICENSE" "$APP/Contents/Resources/ElleKit-LICENSE.txt"
        {
            echo "ElleKit $ELLEKIT_TAG (${ELLEKIT_COMMIT:0:7}) ${ELLEKIT_REPO%.git}"
            echo
            cat "$ELLEKIT_SRC/LICENSE"
            echo
        } >> "$ACK"
        # libhooker's API (LHHookFunctions...): tweaks linking libhooker count as converted only
        # when this ElleKit has it.
        LIBHOOKER=false
        nm -gU "$ELLEKIT_LIB" | grep ' _LHHookFunctions$' >/dev/null && LIBHOOKER=true
        plutil -replace XSideElleKitLibhooker -bool "$LIBHOOKER" "$APP/Contents/Info.plist"
    elif [ "$ELLEKIT_STATUS" = 3 ]; then
        echo "warning: building without ElleKit (no source): Substrate tweaks can't be converted; release.sh will refuse this build" >&2
    else
        exit "$ELLEKIT_STATUS"
    fi
    # The common tweak dependencies XSide adds by itself (scripts/tweak-deps.env, Cephei for now):
    # Resources/TweakDependencies/<packageID>/ (package.json + files laid out as on a jailbreak, read
    # by TweakDependencyCatalog), each with its section in Acknowledgements.txt.
    DEPS_STATUS=0
    DEPS_DIR="$(scripts/build-tweak-deps.sh)" || DEPS_STATUS=$?
    if [ "$DEPS_STATUS" = 0 ]; then
        cp -R "$DEPS_DIR" "$APP/Contents/Resources/TweakDependencies"
        cat build/tweak-deps/Acknowledgements.txt >> "$ACK"
    elif [ "$DEPS_STATUS" = 3 ]; then
        echo "warning: building without the embedded tweak dependencies (no source); release.sh will refuse this build" >&2
    else
        exit "$DEPS_STATUS"
    fi
else
    echo "warning: no iOS SDK, building without the welcome popup, signed-out iCloud, iPhone Duo compatibility and tweak support libraries" >&2
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
[ -f "$APP/Contents/Helpers/xside-unzstd" ] && codesign -s - --force "${SIGN_OPTIONS[@]+"${SIGN_OPTIONS[@]}"}" "$APP/Contents/Helpers/xside-unzstd"
codesign -s - --force "${SIGN_OPTIONS[@]+"${SIGN_OPTIONS[@]}"}" --entitlements App/XSide.entitlements "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
