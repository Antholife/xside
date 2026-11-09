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
# All are injected into iOS apps: an arm64 iOS Mach-O each, nothing else (a wrong build would only
# show on a device).
for LIB in "$WELCOME" "$ICLOUD" "$DUOLEGACY"; do
    [ "$(lipo -archs "$LIB" 2>/dev/null)" = arm64 ] || { echo "$LIB is not an arm64-only library" >&2; exit 1; }
    vtool -show-build "$LIB" 2>/dev/null | grep -qE 'platform IOS$' || { echo "$LIB is not built for iOS" >&2; exit 1; }
done
# CloudKit weakly linked: hooked before the app runs, even in an app that doesn't link it.
otool -l "$ICLOUD" | grep -A2 LC_LOAD_WEAK_DYLIB | grep -q '/CloudKit.framework/CloudKit' \
    || { echo "$ICLOUD doesn't link CloudKit weakly" >&2; exit 1; }
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
