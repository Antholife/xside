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
git diff --quiet HEAD -- || { echo "Commit first: the build is stamped with the commit" >&2; exit 1; }

scripts/bundle.sh
APP=build/XSide.app
ZIP="build/release/XSide-$TAG.zip"
mkdir -p build/release
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

BIN=.build/artifacts/sparkle/Sparkle/bin
SIGNATURE="$("$BIN/sign_update" "$ZIP")" # sparkle:edSignature="…" length="…"
BUILD="$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"
URL="https://github.com/Antholife/xside/releases/download/v$TAG/XSide-$TAG.zip"
NOTES="https://github.com/Antholife/xside/releases/tag/v$TAG"
DATE="$(LC_ALL=C date -R)"

ITEM="    <item>
      <title>XSide $TAG</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$TAG</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$NOTES</sparkle:releaseNotesLink>
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
import os
path = "appcast.xml"
text = open(path).read()
marker = "    <!-- items -->\n"
open(path, "w").write(text.replace(marker, marker + os.environ["ITEM"] + "\n", 1))
'

echo
echo "Built $ZIP (build $BUILD)"
echo "SHA-256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "Next: publish v$TAG on GitHub with the zip, then commit and push appcast.xml."
