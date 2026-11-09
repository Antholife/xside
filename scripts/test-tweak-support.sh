#!/bin/bash
# Checks the converted tweaks' path redirect (App/TweakSupport) on the Mac:
#  1. the C core (XSTweakPathsCore.c) against Tests/XSideCoreTests/Fixtures/tweak-paths-fixture.json,
#     the fixture TweakPathsTests runs through the Swift mirror (Sources/XSideCore/TweakPaths.swift);
#  2. the library, built for macOS with the same warnings as for iOS (its UIKit part is iOS-only),
#     loaded by scripts/test-tweak-support.m in an app laid out as XSide signs it
#     (Frameworks/XSideTweaks/<id>/…, deps/<packageID>/…): with XSideTweakPaths = true in the
#     Info.plist the jailbreak paths lead to the copies; without it, or with a string instead of a
#     boolean, nothing is redirected.
# Everything lives in a temporary folder; nothing is written to /Library or /var/jb.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
CFLAGS=(-fobjc-arc -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mmacosx-version-min=12.0)
for P in "/Library/Application Support/XSTweakSupportTest" "/Library/Application Support/XSTweakSupportTestB.bundle" \
         /Library/MobileSubstrate /var/jb /Library/Frameworks/XSTestDep.framework /usr/lib/libXSTweakSupportTest.dylib; do
    [ ! -e "$P" ] || { echo "FAIL $P exists on this Mac: the test can't tell a redirect from the real file" >&2; exit 1; }
done

# 1. The fixture through the C core.
xcrun clang "${CFLAGS[@]}" -I App/TweakSupport -framework Foundation \
    -o "$OUT/test-core" scripts/test-tweak-support.m App/TweakSupport/XSTweakPathsCore.c
"$OUT/test-core" fixture Tests/XSideCoreTests/Fixtures/tweak-paths-fixture.json

# 2. The library in a process.
APP="$OUT/app"
T="$APP/Frameworks/XSideTweaks"
P1="$T/0123456789abcdef"
P2="$T/fedcba9876543210"
mkdir -p "$T" "$APP/plain"
xcrun clang "${CFLAGS[@]}" -dynamiclib -I App/TweakSupport -framework Foundation \
    -install_name @executable_path/Frameworks/XSideTweaks/XSideTweakSupport.dylib \
    -o "$T/XSideTweakSupport.dylib" App/TweakSupport/*.m App/TweakSupport/*.c
xcrun clang "${CFLAGS[@]}" -I App/TweakSupport -framework Foundation \
    -o "$APP/test-tweak-support" scripts/test-tweak-support.m "$T/XSideTweakSupport.dylib"
otool -l "$T/XSideTweakSupport.dylib" | grep -q __interpose || { echo "FAIL no __interpose section" >&2; exit 1; }
AS="Library/Application Support/XSTweakSupportTest"
mkdir -p "$P1/$AS" "$P2/$AS" "$P1/Library/MobileSubstrate/DynamicLibraries" \
    "$P2/XSTweakSupportTestB.bundle" "$T/deps/com.example.xstestdep/Library/Frameworks/XSTestDep.framework" \
    "$T/notapackage/$AS"
printf 'hello from p1\n' > "$P1/$AS/hello.txt"
printf 'from p2\n' > "$P2/$AS/hello.txt"
printf 'p2\n' > "$P2/$AS/only2.txt"
printf 'evil\n' > "$T/notapackage/$AS/evil.txt"
printf 'dep\n' > "$T/deps/com.example.xstestdep/Library/Frameworks/XSTestDep.framework/data.txt"
plutil -create xml1 "$P1/$AS/prefs.plist" && plutil -insert k -string v "$P1/$AS/prefs.plist"
plutil -create xml1 "$P2/XSTweakSupportTestB.bundle/Info.plist"
plutil -insert CFBundleIdentifier -string com.example.xstestb "$P2/XSTweakSupportTestB.bundle/Info.plist"
echo 'int xs_test_value(void) { return 42; }' > "$OUT/tweak.c"
xcrun clang -dynamiclib -mmacosx-version-min=12.0 -o "$P1/Library/MobileSubstrate/DynamicLibraries/XSTweakSupportTest.dylib" "$OUT/tweak.c"
mkdir -p "$P1/usr/lib"
xcrun clang -dynamiclib -mmacosx-version-min=12.0 -o "$P1/usr/lib/libXSTweakSupportTest.dylib" "$OUT/tweak.c"
# A tweak that ships a library named like one iOS has: it must never answer for it.
echo 'int xs_fake_objc(void) { return 1; }' > "$OUT/fakeobjc.c"
xcrun clang -dynamiclib -mmacosx-version-min=12.0 -o "$P1/usr/lib/libobjc.A.dylib" "$OUT/fakeobjc.c"
echo 'int xs_plain(void) { return 1; }' > "$OUT/plain.c"
xcrun clang -dynamiclib -mmacosx-version-min=12.0 -install_name @loader_path/plain/libplain.dylib \
    -o "$APP/plain/libplain.dylib" "$OUT/plain.c"
# Folders it must not use, and the copies kept for the inert runs.
cp -R "$APP" "$OUT/inert"
cp -R "$APP" "$OUT/string"
cp -R "$APP" "$OUT/tailcall"
plutil -create xml1 "$APP/Info.plist"
plutil -insert CFBundleIdentifier -string com.example.tweaktest.TEAM123456 "$APP/Info.plist"
plutil -insert XSideTweakPaths -bool YES "$APP/Info.plist"
"$APP/test-tweak-support" active
# The same with dyld's dlopen_from treated as missing (a test-only build): dlopen's fallback, a
# tail call that keeps the caller, must give the same answers.
xcrun clang "${CFLAGS[@]}" -dynamiclib -DXS_TEST_NO_DLOPEN_FROM -I App/TweakSupport -framework Foundation \
    -install_name @executable_path/Frameworks/XSideTweaks/XSideTweakSupport.dylib \
    -o "$OUT/tailcall/Frameworks/XSideTweaks/XSideTweakSupport.dylib" App/TweakSupport/*.m App/TweakSupport/*.c
cp "$APP/Info.plist" "$OUT/tailcall/Info.plist"
XS_EXPECT_TAIL_CALL=1 "$OUT/tailcall/test-tweak-support" active
# Signed before with a converted tweak, now without: the library is still there but stays inert.
plutil -create xml1 "$OUT/inert/Info.plist"
plutil -insert CFBundleIdentifier -string com.example.tweaktest.TEAM123456 "$OUT/inert/Info.plist"
"$OUT/inert/test-tweak-support" inert
plutil -create xml1 "$OUT/string/Info.plist"
plutil -insert XSideTweakPaths -string true "$OUT/string/Info.plist"
"$OUT/string/test-tweak-support" inert
