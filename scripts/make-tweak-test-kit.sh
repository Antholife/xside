#!/bin/zsh
# Builds the tweak test kit into $OUT (default build/tweak-test/), from the sources in
# scripts/tweak-test-kit/, with Xcode's clang only (no Theos, no third-party binary):
#   XSideTweakTest.ipa       the test app (io.github.xside.tweaktest), unsigned: five lines, each
#                            "no" until a tweak changes it
#   ✅ plain.dylib, plain.deb                    ObjC runtime only (line 1)
#   🔧 substrate-rootful.deb  (data.tar.xz)      CydiaSubstrate -> ElleKit, jailbreak paths (lines 1-4)
#      substrate-rootless.deb (data.tar.gz)      same, rootless (/var/jb, @rpath/CydiaSubstrate…)
#      zstd.deb               (data.tar.zst)     the rootless tweak, compressed with build/zstd/zstd
#      cephei-user.deb                           links /Library/Frameworks/Cephei.framework/Cephei (line 5)
#   ❌ springboard.deb, arm64e-only.dylib, other-app.deb (overridable), needs-unknown.deb
#   ⬇ needs-altlist.deb, needs-cephei-old.deb   a missing dependency each, to download from the
#                                                trusted repos (opa334, Chariz) in the debug app
#   XST_CRASH=1: also crash.deb, a ✅ tweak that traps 3 s after launch.
#   OUT=<dir> builds elsewhere.
# The .debs are assembled with /usr/bin/ar -rcS (-S: macOS ar would otherwise put a __.SYMDEF
# member first) and /usr/bin/tar --format ustar. Needs the iOS SDK and build/zstd/zstd
# (scripts/build-unzstd.sh). Never shipped, never committed (build/).
set -euo pipefail
ROOT=${0:A:h:h}
KIT=$ROOT/scripts/tweak-test-kit
OUT=${OUT:-$ROOT/build/tweak-test}
ZSTD=$ROOT/build/zstd/zstd
[[ -x $ZSTD ]] || { echo "error: $ZSTD missing: run scripts/build-unzstd.sh first" >&2; exit 1; }
SDK=$(xcrun -sdk iphoneos --show-sdk-path)
SDKVER=$(xcrun -sdk iphoneos --show-sdk-version)
WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT
mkdir -p $OUT
rm -f $OUT/*.deb(N) $OUT/*.dylib(N) $OUT/*.ipa(N)

FLAGS=(-isysroot "$SDK" -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-unused-parameter)
CC=(xcrun -sdk iphoneos clang -target arm64-apple-ios15.0 $FLAGS)
APP_ID=io.github.xside.tweaktest

# --- Link stubs: CydiaSubstrate (C, both install names), Cephei and an unknown library (.tbd).
for layout in rootful rootless; do
    name=/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate
    [[ $layout == rootless ]] && name=@rpath/CydiaSubstrate.framework/CydiaSubstrate
    mkdir -p $WORK/stub-$layout/CydiaSubstrate.framework
    $CC -dynamiclib -install_name $name -o $WORK/stub-$layout/CydiaSubstrate.framework/CydiaSubstrate $KIT/CydiaSubstrateStub.c
done
tbd() {  # file install-name exports-yaml
    cat > $1 <<EOF
--- !tapi-tbd
tbd-version: 4
targets: [ arm64-ios ]
install-name: '$2'
exports:
  - targets: [ arm64-ios ]
$3
...
EOF
}
mkdir -p $WORK/stub-cephei/Cephei.framework $WORK/stub-nowhere
tbd $WORK/stub-cephei/Cephei.framework/Cephei.tbd /Library/Frameworks/Cephei.framework/Cephei \
'    symbols: [ _HBOutputForShellCommandWithReturnCode ]
    objc-classes: [ HBPreferences ]'
tbd $WORK/stub-nowhere/libnowhere.tbd /usr/lib/libnowhere.dylib '    symbols: [ _XSTNowhere ]'

# --- Tweak dylibs. Install names under @rpath: a jailbreak path in the binary would make it 🔧.
tweak() {  # output-name source extra-flags...
    local name=$1 src=$2; shift 2
    $CC -dynamiclib -framework Foundation -install_name @rpath/$name.dylib "$@" -o $WORK/$name.dylib $KIT/$src
}
tweak XSTestTweakPlain XSTestTweakPlain.m
tweak XSTestTweakSubstrate XSTestTweakSubstrate.m -F$WORK/stub-rootful -framework CydiaSubstrate
for name in XSTestTweakRootless XSTestTweakZstd; do
    tweak $name XSTestTweakSubstrate.m -DROOTLESS -F$WORK/stub-rootless -framework CydiaSubstrate \
        -Wl,-rpath,/var/jb/Library/Frameworks -Wl,-rpath,/var/jb/usr/lib
done
tweak XSTestTweakCephei XSTestTweakCephei.m -F$WORK/stub-cephei -framework Cephei
for name in XSTestSpringBoard XSTestOtherApp XSTestNeedsAltList XSTestNeedsCepheiOld; do
    tweak $name XSTestTweakPlain.m -DXST_QUIET
done
tweak XSTestNeedsUnknown XSTestTweakPlain.m -DXST_QUIET -Wl,-needed_library,$WORK/stub-nowhere/libnowhere.tbd
[[ ${XST_CRASH:-0} == 1 ]] && tweak XSTestTweakCrash XSTestTweakPlain.m -DXST_CRASH
xcrun -sdk iphoneos clang -target arm64e-apple-ios15.0 $FLAGS -dynamiclib -framework Foundation \
    -install_name @rpath/arm64e-only.dylib -o $OUT/arm64e-only.dylib $KIT/XSTestTweakPlain.m
cp $WORK/XSTestTweakPlain.dylib $OUT/plain.dylib

# --- .debs
TAR=(env COPYFILE_DISABLE=1 /usr/bin/tar --format ustar --uid 0 --gid 0 --uname root --gname root --no-mac-metadata)
deb() {  # out package name arch depends compression(xz|gz|zst) bundle dylib [root]
    local out=$1 package=$2 name=$3 arch=$4 depends=$5 comp=$6 bundle=$7 dylib=$8 root=${9:-}
    local d=$WORK/deb-${out%.deb}
    local lib=$d/data$root/Library/MobileSubstrate/DynamicLibraries
    mkdir -p $d/control $lib
    sed -e "s|@PACKAGE@|$package|" -e "s|@NAME@|$name|" -e "s|@ARCH@|$arch|" -e "s|@DEPENDS@|$depends|" \
        $KIT/control.in > $d/control/control
    [[ -n $depends ]] || sed -i '' '/^Depends: $/d' $d/control/control
    cp $WORK/$dylib.dylib $lib/$dylib.dylib
    sed "s|@BUNDLE@|$bundle|" $KIT/Filter.plist.in > $lib/$dylib.plist
    if [[ -n ${XST_FILES:-} ]]; then    # the files a converted tweak reads from the jailbreak's folders
        local support="$d/data$root/Library/Application Support"
        mkdir -p "$support/XSideTestTweak" "$support/XSideTestTweak.bundle"
        print "XSide marker OK" > "$support/XSideTestTweak/marker.txt"
        cat > "$support/XSideTestTweak.bundle/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>io.github.xside.testtweak.resources</string>
	<key>CFBundleName</key><string>XSideTestTweak</string>
	<key>CFBundlePackageType</key><string>BNDL</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>XSTMarker</key><string>XSide bundle OK</string>
</dict>
</plist>
EOF
    fi
    chmod -R u=rwX,go=rX $d
    print 2.0 > $d/debian-binary
    $TAR -czf $d/control.tar.gz -C $d/control ./control
    case $comp in
        xz) $TAR -cJf $d/data.tar.xz -C $d/data . ;;
        gz) $TAR -czf $d/data.tar.gz -C $d/data . ;;
        zst) $TAR -cf $d/data.tar -C $d/data . && $ZSTD -q -19 --rm $d/data.tar -o $d/data.tar.zst ;;
    esac
    (cd $d && /usr/bin/ar -rcS $OUT/$out debian-binary control.tar.gz data.tar.$comp)
}
FW='firmware (>= 15.0)'
deb plain.deb io.github.xside.testtweak.plain "XSide Test Plain" iphoneos-arm "$FW" xz $APP_ID XSTestTweakPlain
XST_FILES=1 deb substrate-rootful.deb io.github.xside.testtweak.rootful "XSide Test Substrate (rootful)" iphoneos-arm \
    "mobilesubstrate, $FW" xz $APP_ID XSTestTweakSubstrate
XST_FILES=1 deb substrate-rootless.deb io.github.xside.testtweak.rootless "XSide Test Substrate (rootless)" iphoneos-arm64 \
    "mobilesubstrate (>= 0.9.5000), $FW" gz $APP_ID XSTestTweakRootless /var/jb
XST_FILES=1 deb zstd.deb io.github.xside.testtweak.zstd "XSide Test zstd" iphoneos-arm64 \
    "mobilesubstrate (>= 0.9.5000), $FW" zst $APP_ID XSTestTweakZstd /var/jb
deb cephei-user.deb io.github.xside.testtweak.cephei "XSide Test Cephei" iphoneos-arm \
    "ws.hbang.common (>= 1.0), $FW" xz $APP_ID XSTestTweakCephei
deb springboard.deb io.github.xside.testtweak.springboard "XSide Test SpringBoard" iphoneos-arm "$FW" xz \
    com.apple.springboard XSTestSpringBoard
deb other-app.deb io.github.xside.testtweak.otherapp "XSide Test Other App" iphoneos-arm "$FW" xz \
    com.example.otherapp XSTestOtherApp
deb needs-unknown.deb io.github.xside.testtweak.unknowndep "XSide Test Unknown Dependency" iphoneos-arm \
    "com.example.nowhere, $FW" xz $APP_ID XSTestNeedsUnknown
deb needs-altlist.deb io.github.xside.testtweak.altlist "XSide Test Needs AltList" iphoneos-arm64 \
    "com.opa334.altlist, $FW" xz $APP_ID XSTestNeedsAltList
deb needs-cephei-old.deb io.github.xside.testtweak.cepheiold "XSide Test Needs Cephei < 2.0" iphoneos-arm \
    "ws.hbang.common (<< 2.0), $FW" xz $APP_ID XSTestNeedsCepheiOld
[[ ${XST_CRASH:-0} == 1 ]] && deb crash.deb io.github.xside.testtweak.crash "XSide Test Crash" iphoneos-arm "$FW" xz \
    $APP_ID XSTestTweakCrash

# --- The test app: SDK build, a scene manifest (required from SDK 27), lots of header room for
# XSide's load commands, no linker signature (XSide signs it).
P=$WORK/ipa/Payload/XSideTweakTest.app
mkdir -p $P
$CC -framework UIKit -Xlinker -headerpad -Xlinker 0x4000 -Xlinker -no_adhoc_codesign \
    -o $P/XSideTweakTest $KIT/XSTestApp.m
cat > $P/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>XSideTweakTest</string>
	<key>CFBundleIdentifier</key><string>$APP_ID</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>XSideTweakTest</string>
	<key>CFBundleDisplayName</key><string>Tweak Test</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
	<key>MinimumOSVersion</key><string>15.0</string>
	<key>LSRequiresIPhoneOS</key><true/>
	<key>UIDeviceFamily</key><array><integer>1</integer></array>
	<key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
	<key>UILaunchScreen</key><dict/>
	<key>UIApplicationSceneManifest</key>
	<dict>
		<key>UIApplicationSupportsMultipleScenes</key><false/>
	</dict>
	<key>DTPlatformName</key><string>iphoneos</string>
	<key>DTPlatformVersion</key><string>$SDKVER</string>
	<key>DTSDKName</key><string>iphoneos$SDKVER</string>
</dict>
</plist>
EOF
plutil -convert binary1 $P/Info.plist
printf 'APPL????' > $P/PkgInfo
(cd $WORK/ipa && zip -qry -X $OUT/XSideTweakTest.ipa Payload)

# --- Checks: the Substrate tweaks link the jailbreak's path, the arm64e sample has no arm64.
fail() { echo "error: $*" >&2; exit 1; }
otool -L $WORK/XSTestTweakSubstrate.dylib | grep -q '^	/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate ' \
    || fail "rootful tweak doesn't link /Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
otool -L $WORK/XSTestTweakRootless.dylib | grep -q '^	@rpath/CydiaSubstrate.framework/CydiaSubstrate ' \
    || fail "rootless tweak doesn't link @rpath/CydiaSubstrate.framework/CydiaSubstrate"
otool -L $WORK/XSTestTweakCephei.dylib | grep -q '^	/Library/Frameworks/Cephei.framework/Cephei ' \
    || fail "Cephei tweak doesn't link /Library/Frameworks/Cephei.framework/Cephei"
[[ $(lipo -archs $OUT/arm64e-only.dylib) == arm64e ]] || fail "arm64e-only.dylib is not arm64e only"
[[ $(lipo -archs $OUT/plain.dylib) == arm64 ]] || fail "plain.dylib is not arm64"
for f in $OUT/*.deb; do [[ $(head -c 8 $f) == '!<arch>' ]] || fail "${f:t} is not an ar archive"; done
echo "CydiaSubstrate: $(otool -L $WORK/XSTestTweakSubstrate.dylib | grep CydiaSubstrate | awk '{print $1}') (rootful)," \
     "$(otool -L $WORK/XSTestTweakRootless.dylib | grep CydiaSubstrate | awk '{print $1}') (rootless)"
echo "arm64e-only.dylib: $(lipo -archs $OUT/arm64e-only.dylib)"
ls -1 $OUT
