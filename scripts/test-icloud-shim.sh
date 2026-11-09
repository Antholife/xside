#!/bin/bash
# Checks the "Simulate signed-out iCloud" library (App/ICloud) on the Mac: it is built for macOS
# with the same flags as for iOS (CloudKit linked weakly), loaded by scripts/test-icloud-shim.m
# (which links CloudKit and has no iCloud entitlement) and every probe must answer "signed out";
# then by scripts/test-icloud-shim-coredata.m (Core Data + CloudKit sync without linking CloudKit,
# main thread busy after loading the stores), which must not crash. Preferences go to a temporary
# home, never the user's.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
CFLAGS=(-fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -mmacosx-version-min=12.0)
xcrun clang "${CFLAGS[@]}" -dynamiclib -I App/ICloud -framework Foundation -weak_framework CloudKit \
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
# Core Data + CloudKit in a program that doesn't link CloudKit: Core Data loads it at runtime and
# starts mirroring while the main thread is still busy.
xcrun clang "${CFLAGS[@]}" -framework Foundation -framework CoreData \
    -o "$OUT/test-icloud-shim-coredata" scripts/test-icloud-shim-coredata.m "$OUT/XSideICloud.dylib"
if otool -L "$OUT/test-icloud-shim-coredata" | grep -q CloudKit.framework; then
    echo "FAIL the Core Data test program must not link CloudKit" >&2; exit 1
fi
mkdir -p "$OUT/store"
CFFIXED_USER_HOME="$OUT/home" "$OUT/test-icloud-shim-coredata" "$OUT/store"
