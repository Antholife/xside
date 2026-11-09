#!/bin/bash
# Builds a release: build/release/XSide-<tag>.zip, signed for Sparkle, and its entry at the top
# of appcast.xml. Usage: scripts/release.sh 1.0.3-beta
#
# Then: publish the GitHub release v<tag> with the zip attached, and only after that commit and
# push appcast.xml to main (the feed must never point at a zip that isn't online yet).
# The EdDSA private key is in the login keychain (Sparkle's generate_keys): back it up with
# `generate_keys -x <file>`; without it, installed copies can't be updated anymore.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?usage: scripts/release.sh <version>, e.g. 1.0.3-beta}"
VERSION="${TAG%%-*}"
PLIST_VERSION="$(plutil -extract CFBundleShortVersionString raw App/Info.plist)"
[ "$VERSION" = "$PLIST_VERSION" ] || { echo "App/Info.plist says $PLIST_VERSION, not $VERSION" >&2; exit 1; }
# Untracked files count too: SwiftPM builds every file under Sources/.
[ -z "$(git status --porcelain)" ] || { echo "Commit first (untracked files too): the build is stamped with the commit" >&2; exit 1; }
# Sparkle shows the plain version ("1.0.5"), the beta channel marks it: "XSide 1.0.5-beta is
# available, you have 1.0.4" read oddly. The title keeps the tag.
grep -q "<title>XSide $TAG<" appcast.xml 2>/dev/null && { echo "$TAG is already in appcast.xml" >&2; exit 1; }

# Never the test reminder (a minute after launch) in a release, whatever the shell exports.
unset XSIDE_TEST_REMINDER XSIDE_TEST_LATE
CONFIG=release scripts/bundle.sh
APP=build/XSide.app
# Every app gets XSide's features through this library: no release without it, nor a test build of it.
WELCOME="$APP/Contents/Resources/XSideWelcome.dylib"
[ -f "$WELCOME" ] || { echo "No $WELCOME (iOS SDK missing?): not releasing without it" >&2; exit 1; }
if strings -a "$WELCOME" | grep -qE 'XSIDE_TEST_(REMINDER|LATE)_BUILD'; then
    echo "$WELCOME is a test build (XSIDE_TEST_REMINDER / XSIDE_TEST_LATE): not releasing it" >&2; exit 1
fi
# The "Simulate signed-out iCloud" option adds this one: an app would go without it silently.
ICLOUD="$APP/Contents/Resources/XSideICloud.dylib"
[ -f "$ICLOUD" ] || { echo "No $ICLOUD (iOS SDK missing?): not releasing without it" >&2; exit 1; }
# The iPhone Duo option adds this one to apps without scene support: without it they'd go without the option.
DUOLEGACY="$APP/Contents/Resources/XSideDuoLegacy.dylib"
[ -f "$DUOLEGACY" ] || { echo "No $DUOLEGACY (iOS SDK missing?): not releasing without it" >&2; exit 1; }
# Its manifest names this class: it must be in the library.
nm -gU "$DUOLEGACY" 2>/dev/null | grep -q '_OBJC_CLASS_$_XSDuoSceneDelegate' \
    || { echo "$DUOLEGACY has no XSDuoSceneDelegate class" >&2; exit 1; }
# Converted tweaks get this path redirect: without it they'd look for their files in /Library/...
TWEAKSUPPORT="$APP/Contents/Resources/XSideTweakSupport.dylib"
[ -f "$TWEAKSUPPORT" ] || { echo "No $TWEAKSUPPORT (iOS SDK missing?): not releasing without it" >&2; exit 1; }
# Its C core, and its switch: inert unless the app's Info.plist says XSideTweakPaths.
nm -gU "$TWEAKSUPPORT" 2>/dev/null | grep ' _xs_tweak_redirect$' >/dev/null \
    && strings -a "$TWEAKSUPPORT" | grep -x 'XSideTweakPaths' >/dev/null \
    || { echo "$TWEAKSUPPORT has no xs_tweak_redirect or no XSideTweakPaths switch" >&2; exit 1; }
# All are injected into iOS apps: an arm64 iOS Mach-O each, nothing else (a wrong build would only
# show on a device).
for LIB in "$WELCOME" "$ICLOUD" "$DUOLEGACY" "$TWEAKSUPPORT"; do
    [ "$(lipo -archs "$LIB" 2>/dev/null)" = arm64 ] || { echo "$LIB is not an arm64-only library" >&2; exit 1; }
    vtool -show-build "$LIB" 2>/dev/null | grep -qE 'platform IOS$' || { echo "$LIB is not built for iOS" >&2; exit 1; }
done
# CloudKit weakly linked: hooked before the app runs, even in an app that doesn't link it.
otool -l "$ICLOUD" | grep -A2 LC_LOAD_WEAK_DYLIB | grep -q '/CloudKit.framework/CloudKit' \
    || { echo "$ICLOUD doesn't link CloudKit weakly" >&2; exit 1; }
# The zstd decoder (.deb members, repo indexes): both architectures, and its BSD licence shipped.
UNZSTD="$APP/Contents/Helpers/xside-unzstd"
[ -f "$UNZSTD" ] || { echo "No $UNZSTD (zstd source missing?): not releasing without it" >&2; exit 1; }
[ "$(lipo -archs "$UNZSTD" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ')" = "arm64 x86_64 " ] \
    || { echo "$UNZSTD is not an x86_64 + arm64 binary" >&2; exit 1; }
codesign --verify --strict "$UNZSTD" 2>/dev/null || { echo "$UNZSTD is not code-signed" >&2; exit 1; }
. scripts/zstd.env
grep -q "^zstd $ZSTD_TAG (${ZSTD_COMMIT:0:7}) " "$APP/Contents/Resources/Acknowledgements.txt" 2>/dev/null \
    && grep -q "BSD License" "$APP/Contents/Resources/Acknowledgements.txt" \
    || { echo "Acknowledgements.txt has no zstd section: not releasing without it" >&2; exit 1; }
# ElleKit (Substrate tweaks' hooking library), built from pinned source: both iOS architectures,
# the Substrate API, nothing linked outside the system, and its BSD licence shipped twice
# (Acknowledgements.txt, and ElleKit-LICENSE.txt that XSide copies next to it in each app).
ELLEKIT="$APP/Contents/Resources/ElleKit.dylib"
[ -f "$ELLEKIT" ] || { echo "No $ELLEKIT (ElleKit source or iOS SDK missing?): not releasing without it" >&2; exit 1; }
[ -f "$APP/Contents/Resources/ElleKit-LICENSE.txt" ] || { echo "No ElleKit-LICENSE.txt: not releasing without it" >&2; exit 1; }
[ "$(lipo -archs "$ELLEKIT" 2>/dev/null)" = "arm64 arm64e" ] || { echo "$ELLEKIT is not exactly arm64 + arm64e" >&2; exit 1; }
[ "$(vtool -show-build "$ELLEKIT" 2>/dev/null | grep -cE 'platform IOS$')" = 2 ] \
    || { echo "$ELLEKIT is not built for iOS in both architectures" >&2; exit 1; }
for SYM in _MSHookMessageEx _MSHookFunction _MSFindSymbol _MSGetImageByName; do
    nm -gU "$ELLEKIT" 2>/dev/null | grep " $SYM$" >/dev/null || { echo "$ELLEKIT doesn't export $SYM" >&2; exit 1; }
done
ELLEKIT_ID="$(otool -D "$ELLEKIT" 2>/dev/null | sed -n 2p)"
[ "$ELLEKIT_ID" = @executable_path/Frameworks/XSideTweaks/ElleKit.dylib ] || { echo "$ELLEKIT has the id '$ELLEKIT_ID'" >&2; exit 1; }
OUTSIDE="$(otool -L "$ELLEKIT" 2>/dev/null | awk 'NF > 1 && /^\t/ { print $1 }' | grep -vE '^(/usr/lib/|/System/)' | grep -vxF "$ELLEKIT_ID" || true)"
[ -z "$OUTSIDE" ] || { echo "$ELLEKIT links outside the system: $OUTSIDE" >&2; exit 1; }
. scripts/ellekit.env
grep -q "^ElleKit $ELLEKIT_TAG (${ELLEKIT_COMMIT:0:7}) " "$APP/Contents/Resources/Acknowledgements.txt" 2>/dev/null \
    && grep -q "Neither ElleKit nor the names of its" "$APP/Contents/Resources/Acknowledgements.txt" \
    || { echo "Acknowledgements.txt has no ElleKit section: not releasing without it" >&2; exit 1; }
plutil -extract XSideElleKitLibhooker raw "$APP/Contents/Info.plist" >/dev/null 2>&1 \
    || { echo "Info.plist has no XSideElleKitLibhooker" >&2; exit 1; }
# Embedded tweak dependencies (scripts/tweak-deps.env), built from pinned source: exactly the
# expected packages, each with its package.json and its Acknowledgements section; every Mach-O in
# them arm64 + arm64e for iOS, named under its deps/ folder, linking only the system; no links.
DEPS="$APP/Contents/Resources/TweakDependencies"
. scripts/tweak-deps.env
[ "$(ls "$DEPS" 2>/dev/null | tr '\n' ' ')" = "ws.hbang.common " ] \
    || { echo "$DEPS doesn't hold exactly ws.hbang.common (source or iOS SDK missing?): not releasing without it" >&2; exit 1; }
[ -z "$(find "$DEPS" -type l)" ] || { echo "$DEPS has symbolic links" >&2; exit 1; }
for PKG in "$DEPS"/*; do
    [ -f "$PKG/package.json" ] || { echo "No $PKG/package.json" >&2; exit 1; }
    MACHOS=0
    while IFS= read -r -d '' FILE; do
        case "$(head -c 4 "$FILE" | xxd -p)" in cafebabe|cffaedfe|feedfacf) ;; *) continue ;; esac
        MACHOS=$((MACHOS + 1))
        [ "$(lipo -archs "$FILE" 2>/dev/null)" = "arm64 arm64e" ] || { echo "$FILE is not exactly arm64 + arm64e" >&2; exit 1; }
        [ "$(vtool -show-build "$FILE" 2>/dev/null | grep -cE 'platform IOS$')" = 2 ] \
            || { echo "$FILE is not built for iOS in both architectures" >&2; exit 1; }
        DEP_ID="$(otool -D "$FILE" 2>/dev/null | sed -n 2p)"
        [ "$DEP_ID" = "@executable_path/Frameworks/XSideTweaks/deps/${FILE#"$DEPS"/}" ] \
            || { echo "$FILE has the id '$DEP_ID'" >&2; exit 1; }
        OUTSIDE="$(otool -L "$FILE" 2>/dev/null | awk 'NF > 1 && /^\t/ { print $1 }' | grep -vE '^(/usr/lib/|/System/)' | grep -vxF "$DEP_ID" || true)"
        [ -z "$OUTSIDE" ] || { echo "$FILE links outside the system: $OUTSIDE" >&2; exit 1; }
    done < <(find "$PKG" -type f -print0)
    [ "$MACHOS" -gt 0 ] || { echo "$PKG has no library" >&2; exit 1; }
done
nm -gU "$DEPS/ws.hbang.common/Library/Frameworks/Cephei.framework/Cephei" 2>/dev/null | grep ' _OBJC_CLASS_$_HBPreferences$' >/dev/null \
    || { echo "Cephei has no HBPreferences class" >&2; exit 1; }
# Its section (from its heading to the next "<name> <tag> (<sha>) https://..." heading): Apache-2.0
# §4(b) wants XSide's changes stated, and the licence must be in that section itself.
CEPHEI_ACK="$(awk -v head="Cephei $CEPHEI_TAG (${CEPHEI_COMMIT:0:7}) " '
    index($0, head) == 1 { on = 1; print; next }
    on && /^[^ ]+ [^ ]+ \([0-9a-f]{7}\) https:\/\// { exit }
    on { print }' "$APP/Contents/Resources/Acknowledgements.txt" 2>/dev/null)"
[ -n "$CEPHEI_ACK" ] || { echo "Acknowledgements.txt has no Cephei section: not releasing without it" >&2; exit 1; }
grep -q "^Changes made by XSide: .*HBRespringController.m replaced" <<<"$CEPHEI_ACK" \
    || { echo "The Cephei section doesn't state XSide's changes (Apache-2.0 4(b))" >&2; exit 1; }
grep -q "Version 2.0, January 2004" <<<"$CEPHEI_ACK" && grep -q "Apache License" <<<"$CEPHEI_ACK" \
    || { echo "The Cephei section has no Apache-2.0 licence text" >&2; exit 1; }
ZIP="build/release/XSide-$TAG.zip"
mkdir -p build/release
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

BIN=.build/artifacts/sparkle/Sparkle/bin
SIGNATURE="$("$BIN/sign_update" "$ZIP")" # sparkle:edSignature="…" length="…"
BUILD="$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"
URL="https://github.com/Antholife/xside/releases/download/v$TAG/XSide-$TAG.zip"
# The version's CHANGELOG.md section, shown in Sparkle's update window.
NOTES_HTML="$(python3 -I scripts/changelog-html.py "$TAG")"
DATE="$(LC_ALL=C date -R)"
# Pre-releases ("1.0.3-beta") go to the beta channel; a stable release has none.
CHANNEL=""
[ "$TAG" != "$VERSION" ] && CHANNEL="
      <sparkle:channel>beta</sparkle:channel>"

ITEM="    <item>
      <title>XSide $TAG</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>$CHANNEL
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES_HTML]]></description>
      <sparkle:fullReleaseNotesLink>https://github.com/Antholife/xside/releases</sparkle:fullReleaseNotesLink>
      <enclosure url=\"$URL\" $SIGNATURE type=\"application/octet-stream\"/>
    </item>"

if [ ! -f appcast.xml ]; then
    cat > appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>XSide</title>
    <link>https://github.com/Antholife/xside</link>
    <!-- items -->
  </channel>
</rss>
EOF
fi
# Newest first, right after the marker.
ITEM="$ITEM" python3 -I -c '
import os, sys
path = "appcast.xml"
text = open(path).read()
marker = "    <!-- items -->\n"
if marker not in text:
    sys.exit("appcast.xml has no <!-- items --> marker: nothing added")
open(path, "w").write(text.replace(marker, marker + os.environ["ITEM"] + "\n", 1))
'

echo
echo "Built $ZIP (build $BUILD)"
echo "SHA-256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "Next: publish v$TAG on GitHub with the zip, then commit and push appcast.xml."
