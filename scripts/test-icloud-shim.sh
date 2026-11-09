#!/bin/bash
# Checks the "Simulate signed-out iCloud" library (App/ICloud) on the Mac: it is built for macOS
# with the same warnings as for iOS, loaded by scripts/test-icloud-shim.m (which links CloudKit
# and has no iCloud entitlement) and every probe must answer "signed out". Preferences go to a
# temporary home, never the user's.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
CFLAGS=(-fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -mmacosx-version-min=12.0)
xcrun clang "${CFLAGS[@]}" -dynamiclib -I App/ICloud -framework Foundation \
    -install_name @executable_path/XSideICloud.dylib \
    -o "$OUT/XSideICloud.dylib" App/ICloud/*.m
xcrun clang "${CFLAGS[@]}" -I App/ICloud -framework Foundation -framework CloudKit \
    -o "$OUT/test-icloud-shim" scripts/test-icloud-shim.m App/ICloud/XSICloudCore.m "$OUT/XSideICloud.dylib"
# What XSide writes at signing: the app's own id (the signed one is <original>.<TEAM>).
plutil -create xml1 "$OUT/Info.plist"
plutil -insert CFBundleIdentifier -string com.example.icloudtest.TEAM123456 "$OUT/Info.plist"
plutil -insert XSideOriginalBundleID -string com.example.icloudtest "$OUT/Info.plist"
mkdir -p "$OUT/home"
CFFIXED_USER_HOME="$OUT/home" "$OUT/test-icloud-shim"
