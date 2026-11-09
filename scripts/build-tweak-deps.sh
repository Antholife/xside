#!/bin/bash
# Builds XSide's embedded tweak dependencies from pinned source (scripts/tweak-deps.env):
#   build/tweak-deps/TweakDependencies/<packageID>/  package.json + the files, laid out as on a jailbreak
#   build/tweak-deps/Acknowledgements.txt           one section per dependency (bundle.sh appends it)
# Only Xcode's tools (no Theos), arm64 + arm64e, iOS 15. Everything under build/.
# Without the source (no network, no cache) it warns and exits 3: nothing is built.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/tweak-deps.env
OUT=build/tweak-deps
rm -rf "$OUT/TweakDependencies" "$OUT/Acknowledgements.txt"
mkdir -p "$OUT/TweakDependencies"
: > "$OUT/Acknowledgements.txt"
SDK="$(xcrun -sdk iphoneos --show-sdk-path)"
ARCHS=(arm64 arm64e)
PREFIX=@executable_path/Frameworks/XSideTweaks/deps

# A JSON string; control fields and paths here are plain text (anything else stops the build).
json() {
    LC_ALL=C; [[ "$1" != *[[:cntrl:]]* ]] || { echo "error: control character in '$1'" >&2; exit 1; }
    local s="${1//\\/\\\\}"; printf '"%s"' "${s//\"/\\\"}"
}
# A control file field (first stanza, single line).
field() { sed -n "s/^$1: *//p" "$2" | head -1 | tr -d '\r'; }

# What XSide reads from a Mach-O (TweakAnalyzer's store()): slices in file order, linked libraries
# (arm64 slices first, each name once), jailbreak path strings, the image name.
binary_json() {
    local file="$1" path="$2" archs arch slices="" linked="" names=() name jb=false
    archs="$(lipo -archs "$file")"
    for arch in $archs; do
        local build platform minos
        build="$(vtool -arch "$arch" -show-build "$file")"
        platform="$(awk '$1 == "platform" { print $2; exit }' <<<"$build")"
        minos="$(awk '$1 == "minos" { print $2; exit }' <<<"$build")"
        [ "$platform" = IOS ] && [ -n "$minos" ] || { echo "error: $file ($arch) is not an iOS build" >&2; exit 1; }
        slices+="${slices:+, }{\"arch\": $(json "$arch"), \"platform\": 2, \"minOS\": $(json "$minos")}"
    done
    for arch in $(tr ' ' '\n' <<<"$archs" | grep -x arm64) $(tr ' ' '\n' <<<"$archs" | grep -vx arm64); do
        while IFS= read -r name; do
            [[ " ${names[*]+"${names[*]}"} " == *" $name "* ]] && continue
            names+=("$name")
            linked+="${linked:+, }$(json "$name")"
        done < <(otool -arch "$arch" -l "$file" | awk '
            $1 == "cmd" { want = ($2 ~ /^LC_(LOAD_DYLIB|LOAD_WEAK_DYLIB|REEXPORT_DYLIB|LAZY_LOAD_DYLIB|LOAD_UPWARD_DYLIB)$/) }
            want && $1 == "name" { print $2; want = 0 }')
    done
    LC_ALL=C grep -aqF -e /var/jb/ -e /Library/MobileSubstrate/ -e "/Library/Application Support/" \
        -e /Library/PreferenceBundles/ "$file" && jb=true
    printf '{"path": %s, "isEntry": false, "slices": [%s], "linked": [%s], "mentionsJailbreakPaths": %s, "imageName": %s}' \
        "$(json "$path")" "$slices" "$linked" "$jb" "$(json "$(basename "$file")")"
}

# package.json for <dir> from <control>: a TweakPackage (origin embedded, id = package id).
# Depends: plain comma-separated "name (op version)" groups only.
package_json() {
    local dir="$1" control="$2" id files="" binaries="" depends="" f group
    id="$(field Package "$control")"
    while IFS= read -r -d '' f; do
        f="${f#"$dir"/}"
        files+="${files:+, }$(json "$f")"
        case "$(head -c 4 "$dir/$f" | xxd -p)" in
            cafebabe|cffaedfe|feedfacf) binaries+="${binaries:+, }$(binary_json "$dir/$f" "$f")" ;;
        esac
    done < <(find "$dir" -type f ! -name package.json -print0 | LC_ALL=C sort -z)
    IFS=',' read -ra groups <<<"$(field Depends "$control")"
    for group in "${groups[@]+"${groups[@]}"}"; do
        group="$(sed -E 's/^ +| +$//g' <<<"$group")"
        [ -n "$group" ] || continue
        if [[ "$group" =~ ^([a-z0-9][a-z0-9+.-]*)\ *\((<<|<=|=|>=|>>)\ *([^ ()]+)\)$ ]]; then
            depends+="${depends:+, }[{\"package\": $(json "${BASH_REMATCH[1]}"), \"relation\": $(json "${BASH_REMATCH[2]}"), \"version\": $(json "${BASH_REMATCH[3]}"), \"unparseable\": false}]"
        elif [[ "$group" =~ ^[a-z0-9][a-z0-9+.-]*$ ]]; then
            depends+="${depends:+, }[{\"package\": $(json "$group"), \"unparseable\": false}]"
        else
            echo "error: $control: unsupported Depends group '$group'" >&2; exit 1
        fi
    done
    printf '{"id": %s, "kind": "deb", "origin": {"embedded": {}}, "packageID": %s, "provides": [], "name": %s, "version": %s, "author": %s, "architecture": %s, "depends": [%s], "files": [%s], "binaries": [%s], "notes": [], "addedAt": "2001-01-01T00:00:00Z"}\n' \
        "$(json "$id")" "$(json "$id")" "$(json "$(field Name "$control")")" "$(json "$(field Version "$control")")" \
        "$(json "$(field Author "$control" | sed -E 's/ *<[^>]*>$//')")" "$(json "$(field Architecture "$control")")" \
        "$depends" "$files" "$binaries" > "$dir/package.json"
}

# The toolchain each output was built with (build/tweak-deps/build-info.txt, and in the Acknowledgements).
TOOLCHAIN="$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//'); $(xcrun swiftc --version 2>/dev/null | grep -m1 "Swift version"); $(xcrun -sdk iphoneos clang --version | head -1); iPhoneOS SDK $(xcrun -sdk iphoneos --show-sdk-version)"
echo "$TOOLCHAIN" > "$OUT/build-info.txt"
echo "tweak dependencies built with: $TOOLCHAIN" >&2

acknowledge() {   # <name> <tag> <commit> <repo> <licence file> <changes made by XSide> [NOTICE]
    {
        echo "$1 $2 (${3:0:7}) ${4%.git}"
        echo
        echo "Changes made by XSide: $6"
        echo "Built with: $TOOLCHAIN"
        echo
        cat "$5"
        [ -n "${7:-}" ] && [ -f "$7" ] && { echo; cat "$7"; }
        echo
    } >> "$OUT/Acknowledgements.txt"
}

# Cephei (ws.hbang.common): only Cephei.framework (main/), without CepheiUI and CepheiPrefs (ui/, prefs/)
# nor the defaults tool. Built as Cephei's own "embedded" mode (CEPHEI_EMBEDDED=1, its Makefile's
# switch for a copy inside an app): HBPreferences on the app's own preferences, no IPC to SpringBoard
# (which a sideloaded app can't reach), so no LightMessaging, RocketBootstrap or sandbox API. Theos's
# makefiles are replaced by the clang/swiftc lines below; Theos's private headers by the few
# declarations in shims/ (nothing private is linked), and HBRespringController by a no-op.
CEPHEI_SRC="$(scripts/fetch-pinned.sh cephei "$CEPHEI_REPO" "$CEPHEI_COMMIT")" || exit $?
grep -q "Apache License" "$CEPHEI_SRC/LICENSE.md" && grep -q "Version 2.0, January 2004" "$CEPHEI_SRC/LICENSE.md" \
    || { echo "error: Cephei's LICENSE.md is not Apache-2.0 at $CEPHEI_COMMIT" >&2; exit 1; }
[ "$(field Package "$CEPHEI_SRC/control")" = ws.hbang.common ] && [ "$(field Version "$CEPHEI_SRC/control")" = "$CEPHEI_TAG" ] \
    || { echo "error: Cephei's control is not ws.hbang.common $CEPHEI_TAG" >&2; exit 1; }
WORK="$OUT/cephei"
rm -rf "$WORK"
mkdir -p "$WORK/shims/UIKit" "$WORK/shims/LightMessaging" "$WORK/gen"
# Theos's <version.h> (IS_IOS_OR_NEWER...): nothing in main/ uses it.
: > "$WORK/shims/version.h"
cat > "$WORK/shims/UIKit/UIApplication+Private.h" <<'H'
#import <UIKit/UIApplication.h>
@interface UIApplication (XSidePrivate)
+ (BOOL)registerAsSystemApp;
@end
H
# Only the connection type, for HBPreferencesCommon.h's two constants (unused when embedded).
cat > "$WORK/shims/LightMessaging/LightMessaging.h" <<'H'
#import <mach/mach.h>
typedef struct { mach_port_t serverPort; const char *serverName; } LMConnection;
H
# HBRespringController restarts SpringBoard: a sideloaded app can't, and its private API values
# (SBSRelaunchActionOptions) come from Theos's headers, not from Cephei. Its file in main/ is replaced
# by this one (XSide's own code): the same class and methods, doing nothing.
cat > "$WORK/gen/HBRespringController.m" <<'M'
// Modified by XSide: this file replaces Cephei's main/HBRespringController.m
// (https://github.com/hbang/libcephei, Apache License 2.0) in XSide's build of Cephei.
// Same class and methods; respring does nothing, since a sideloaded app can't restart SpringBoard.
#import "HBRespringController.h"

@implementation HBRespringController

+ (nullable NSURL *)_preferencesReturnURL {
	return nil;
}

+ (void)respring {
}

+ (void)respringAndReturnTo:(nullable NSURL *)returnURL {
}

@end
M
FW_REL=Library/Frameworks/Cephei.framework
CEPHEI_ID="$PREFIX/ws.hbang.common/$FW_REL/Cephei"
SLICES=()
for ARCH in "${ARCHS[@]}"; do
    O="$WORK/obj/$ARCH"
    mkdir -p "$O"
    TARGET="$ARCH-apple-ios15.0"
    xcrun -sdk iphoneos swiftc -target "$TARGET" -sdk "$SDK" -O -wmo -parse-as-library -module-name Cephei \
        -application-extension -emit-objc-header -emit-objc-header-path "$WORK/gen/Cephei-Swift.h" \
        -emit-module -emit-module-path "$O/Cephei.swiftmodule" -c "$CEPHEI_SRC"/main/*.swift -o "$O/Command.o"
    OBJS=("$O/Command.o")
    # swiftc leaves class_ro_t pointers unsigned on arm64e; clang signs them by default. One image
    # must agree: the unsigned form, which every arm64e iOS runtime reads.
    PTRAUTH=()
    [ "$ARCH" = arm64e ] && PTRAUTH=(-fno-ptrauth-objc-class-ro)
    # -Wno-sometimes-uninitialized: HBPreferences.m's container branch, empty when embedded (never taken).
    # HBPreferencesServer.x is Logos, but all of it is under #if !CEPHEI_EMBEDDED: plain Objective-C
    # here (an empty object, compiled to show nothing is left out by mistake).
    SOURCES=()
    for SRC_FILE in "$CEPHEI_SRC"/main/*.m "$CEPHEI_SRC"/main/*.x; do
        [ "$(basename "$SRC_FILE")" = HBRespringController.m ] || SOURCES+=("$SRC_FILE")
    done
    for SRC_FILE in "${SOURCES[@]}" "$WORK/gen/HBRespringController.m"; do
        OBJ="$O/$(basename "$SRC_FILE").o"   # names are unique: the replaced file isn't built
        xcrun -sdk iphoneos clang -target "$TARGET" -isysroot "$SDK" -x objective-c -fobjc-arc -fmodules -O2 \
            -Wall -Wextra -Wno-unused-parameter -Wno-unused-function -Wno-sometimes-uninitialized \
            -fapplication-extension "${PTRAUTH[@]+"${PTRAUTH[@]}"}" \
            -I "$WORK/shims" -I "$WORK/gen" -I "$CEPHEI_SRC/main" -include "$CEPHEI_SRC/main/Global.h" \
            -DTHEOS -DTHEOS_LEAN_AND_MEAN -DCEPHEI_EMBEDDED=1 -DROCKETBOOTSTRAP_LOAD_DYNAMIC \
            -DCEPHEI_VERSION="\"$CEPHEI_TAG\"" -DINSTALL_PREFIX='"/var/jb"' \
            -c "$SRC_FILE" -o "$OBJ"
        OBJS+=("$OBJ")
    done
    xcrun -sdk iphoneos swiftc -target "$TARGET" -sdk "$SDK" -emit-library -application-extension \
        -o "$O/Cephei" "${OBJS[@]}" -framework Foundation -framework CoreGraphics \
        -Xlinker -install_name -Xlinker "$CEPHEI_ID" -Xlinker -no_warn_inits
    SLICES+=("$O/Cephei")
done
PKG="$OUT/TweakDependencies/ws.hbang.common"
mkdir -p "$PKG/$FW_REL"
lipo -create "${SLICES[@]}" -output "$WORK/Cephei"
# XSide signs it again at each install; ad-hoc until then (signed alone, before it is in a
# .framework folder: no _CodeSignature folder in the package).
codesign -s - --force "$WORK/Cephei"
cp "$WORK/Cephei" "$PKG/$FW_REL/Cephei"
cp "$CEPHEI_SRC/main/Resources/Info.plist" "$PKG/$FW_REL/Info.plist"
package_json "$PKG" "$CEPHEI_SRC/control"
CEPHEI_CHANGES="built from main/ only (Cephei.framework; CepheiUI, CepheiPrefs and defaults omitted), in Cephei's embedded mode (CEPHEI_EMBEDDED=1), with clang/swiftc instead of Theos's makefiles; main/HBRespringController.m replaced by a no-op (a sideloaded app can't restart SpringBoard); Theos's private headers (version.h, LightMessaging, UIApplication+Private) replaced by minimal declarations; install name set for XSide's Frameworks/XSideTweaks/deps/ws.hbang.common/ folder."
acknowledge Cephei "$CEPHEI_TAG" "$CEPHEI_COMMIT" "$CEPHEI_REPO" "$CEPHEI_SRC/LICENSE.md" "$CEPHEI_CHANGES" "$CEPHEI_SRC/NOTICE"
echo "$OUT/TweakDependencies"
