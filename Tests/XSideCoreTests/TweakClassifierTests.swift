import Foundation
import Testing
@testable import XSideCore

/// The classification matrix: ✅ compatible / 🔧 converted (what changed) / ❌ not compatible (why).
struct TweakClassifierTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let dylibFolder = "Library/MobileSubstrate/DynamicLibraries/"
    private static let substrate = "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
    private static let cephei = "/Library/Frameworks/Cephei.framework/Cephei"

    private func slice(_ arch: String = "arm64", platform: UInt32? = 2, minOS: String? = "15.0") -> TweakSlice {
        TweakSlice(arch: arch, platform: platform, minOS: minOS)
    }

    private func entry(_ name: String = "Example", filter: TweakFilter? = TweakFilter(bundles: ["com.example.app"]),
                       slices: [TweakSlice]? = nil, linked: [String] = ["/usr/lib/libobjc.A.dylib"],
                       mentions: Bool = false) -> TweakBinary {
        TweakBinary(path: Self.dylibFolder + name + ".dylib", isEntry: true, filter: filter,
                    slices: slices ?? [slice()], linked: linked, mentionsJailbreakPaths: mentions,
                    imageName: name + ".dylib")
    }

    private func library(_ path: String, linked: [String] = []) -> TweakBinary {
        TweakBinary(path: path, isEntry: false, filter: nil, slices: [slice()], linked: linked,
                    mentionsJailbreakPaths: false, imageName: String(path.split(separator: "/").last ?? ""))
    }

    private func package(_ binaries: [TweakBinary], id: String = "0123456789abcdef", kind: TweakKind = .deb,
                         origin: TweakOrigin = .added, packageID: String = "com.example.tweak",
                         name: String = "Example Tweak", version: String? = "1.0", provides: [String] = [],
                         depends: [[DebDependency]] = [], extraFiles: [String] = []) -> TweakPackage {
        var files = extraFiles + binaries.map(\.path)
        for b in binaries where b.filter != nil {
            files.append(String(b.path.dropLast(".dylib".count)) + ".plist")
        }
        return TweakPackage(id: id, kind: kind, origin: origin, packageID: packageID, provides: provides, name: name,
                            version: version, depends: depends, files: files.sorted(), binaries: binaries, addedAt: Self.now)
    }

    private func context(others: [TweakPackage] = [], embedded: [TweakPackage] = [], deviceOS: String? = "17.5",
                         classes: Set<String>? = nil, frameworks: Set<String>? = nil,
                         appFiles: (@Sendable (String) -> Bool)? = nil,
                         elleKit: Bool = true, support: Bool = true, libhooker: Bool = false,
                         system: (@Sendable (String) -> Bool)? = nil, executable: String? = "Example") -> TweakContext {
        TweakContext(originalBundleID: "com.example.app", executableName: executable, appClassNames: classes,
                     appLinkedFrameworks: frameworks, appFiles: appFiles, deviceOS: deviceOS,
                     elleKitAvailable: elleKit, supportAvailable: support, elleKitHasLibhooker: libhooker,
                     isSystemLibrary: system ?? TweakClassifier.systemLibraries(sdk: nil),
                     others: others, embedded: embedded)
    }

    private func dep(_ p: String, _ rel: String? = nil, _ v: String? = nil) -> [DebDependency] {
        [DebDependency(package: p, relation: rel, version: v)]
    }

    private func embeddedCephei(version: String = "2.0") -> TweakPackage {
        package([library(String(Self.cephei.dropFirst()))], id: "ws.hbang.common", origin: .embedded,
                packageID: "ws.hbang.common", name: "Cephei", version: version)
    }

    private func verdict(_ p: TweakPackage, _ c: TweakContext? = nil) -> TweakVerdict {
        TweakClassifier.verdict(p, c ?? context())
    }

    // MARK: hooking

    @Test func plainObjCTweakForThisApp() {
        let p = package([entry(linked: ["/usr/lib/libobjc.A.dylib", "/System/Library/Frameworks/UIKit.framework/UIKit",
                                        "/usr/lib/libSystem.B.dylib"])])
        #expect(verdict(p) == .compatible)
        #expect(TweakClassifier.resolution(p, context()).isEmpty)
    }

    @Test func substrateTweak() {
        let p = package([entry(linked: [Self.substrate, "/usr/lib/libobjc.A.dylib"])])
        #expect(verdict(p) == .converted([.hookingLibrary]))
        #expect(TweakClassifier.resolution(p, context()) == [Self.substrate: TweakLayout.elleKitLoadPath])
    }

    @Test func substrateWithoutElleKit() {
        let p = package([entry(linked: [Self.substrate])])
        #expect(verdict(p, context(elleKit: false)) == .incompatible(.missingDependency("ElleKit")))
    }

    @Test func rootlessRpathSubstrate() {
        let p = package([entry(linked: ["@rpath/CydiaSubstrate.framework/CydiaSubstrate", "/var/jb/usr/lib/libsubstrate.dylib"])])
        #expect(verdict(p) == .converted([.hookingLibrary]))
    }

    @Test func libhookerOnlyWhenElleKitHasIt() {
        let p = package([entry(linked: ["/usr/lib/libhooker.dylib"])])
        #expect(verdict(p, context(libhooker: true)) == .converted([.hookingLibrary]))
        #expect(verdict(p, context(libhooker: false)) == .incompatible(.needsJailbreak("libhooker.dylib")))
        #expect(TweakClassifier.isHookingLibrary("/usr/lib/libhooker.dylib", libhooker: true))
        #expect(!TweakClassifier.isHookingLibrary("/usr/lib/libhooker.dylib", libhooker: false))
        #expect(TweakClassifier.isHookingLibrary("/usr/lib/libsubstitute.dylib", libhooker: false))
        #expect(!TweakClassifier.isHookingLibrary("/usr/lib/libobjc.A.dylib", libhooker: true))
    }

    // MARK: filter

    @Test func springBoardOnly() {
        let v = verdict(package([entry(filter: TweakFilter(bundles: ["com.apple.springboard"]))]))
        #expect(v == .incompatible(.needsJailbreak("com.apple.springboard")))
        #expect(!v.canOverride)
    }

    @Test func executablesSpringBoard() {
        let v = verdict(package([entry(filter: TweakFilter(executables: ["SpringBoard", "backboardd"]))]))
        #expect(v == .incompatible(.needsJailbreak("SpringBoard")))
        #expect(!v.canOverride)
    }

    @Test func anotherApp() {
        let v = verdict(package([entry(filter: TweakFilter(bundles: ["com.other.app"]))]))
        #expect(v == .incompatible(.madeForAnotherApp(["com.other.app"])))
        #expect(v.canOverride)
        // Another app next to an Apple daemon is still another app, not a jailbreak-only tweak.
        let mixed = verdict(package([entry(filter: TweakFilter(bundles: ["com.apple.springboard", "com.other.app"]))]))
        #expect(mixed == .incompatible(.madeForAnotherApp(["com.apple.springboard", "com.other.app"])))
    }

    @Test func mixedSpringBoardAndThisApp() {
        let p = package([entry(filter: TweakFilter(bundles: ["com.apple.springboard", "com.example.app"]))])
        #expect(verdict(p) == .compatible)
    }

    @Test func bundleIDsCompareWithoutCase() {
        #expect(verdict(package([entry(filter: TweakFilter(bundles: ["COM.Example.App"]))])) == .compatible)
    }

    @Test func uikitFilterMatchesAnyApp() {
        for id in ["com.apple.UIKit", "com.apple.Foundation", "com.apple.CoreFoundation"] {
            #expect(verdict(package([entry(filter: TweakFilter(bundles: [id]))]), context(frameworks: [])) == .compatible)
        }
    }

    @Test func webKitFilterNeedsTheAppToLinkWebKit() {
        let p = package([entry(filter: TweakFilter(bundles: ["com.apple.WebKit"]))])
        #expect(verdict(p, context(frameworks: ["UIKit"])) == .incompatible(.needsJailbreak("com.apple.WebKit")))
        #expect(verdict(p, context(frameworks: ["UIKit", "WebKit"])) == .compatible)
        #expect(verdict(p, context(frameworks: nil)) == .compatible)
    }

    @Test func classesFilterUsesTheAppClasses() {
        let p = package([entry(filter: TweakFilter(classes: ["YTPlayerView"]))])
        #expect(verdict(p, context(classes: ["YTPlayerView", "AppDelegate"])) == .compatible)
        #expect(verdict(p, context(classes: ["AppDelegate"])) == .incompatible(.madeForAnotherApp(["YTPlayerView"])))
        #expect(verdict(p, context(classes: nil)) == .compatible)
    }

    @Test func modeAnyVsAll() {
        let all = package([entry(filter: TweakFilter(bundles: ["com.example.app"], executables: ["Other"]))])
        #expect(verdict(all) == .incompatible(.madeForAnotherApp(["Other"])))
        let any = package([entry(filter: TweakFilter(bundles: ["com.example.app"], executables: ["Other"], anyMode: true))])
        #expect(verdict(any) == .compatible)
        let none = package([entry(filter: TweakFilter(bundles: ["com.other.app"], executables: ["Other"], anyMode: true))])
        #expect(verdict(none) == .incompatible(.madeForAnotherApp(["com.other.app", "Other"])))
    }

    @Test func anEmptyFilterSaysNoApp() {
        let v = verdict(package([entry(filter: TweakFilter())]))
        #expect(v == .incompatible(.noFilter))
        #expect(v.canOverride)
    }

    @Test func aDroppedDylibIsForThisApp() {
        let p = package([entry(filter: nil)], kind: .dylib)
        #expect(verdict(p) == .compatible)
    }

    // MARK: architecture and iOS

    @Test func arm64eOnly() {
        let p = package([entry(slices: [slice("arm64e")])])
        #expect(verdict(p) == .incompatible(.wrongArchitecture(["arm64e"])))
        #expect(verdict(package([entry(slices: [slice("arm64e"), slice("arm64")])])) == .compatible)
    }

    @Test func catalystSlice() {
        #expect(verdict(package([entry(slices: [slice(platform: 6)])])) == .incompatible(.notForIOS))
        #expect(verdict(package([entry(slices: [slice(platform: nil)])])) == .compatible)
    }

    @Test func minOSAboveDevice() {
        let p = package([entry(slices: [slice(minOS: "18.0")])])
        #expect(verdict(p) == .incompatible(.iOSVersion(required: "18.0", device: "17.5")))
        #expect(verdict(p, context(deviceOS: "18.0")) == .compatible)
    }

    @Test func firmwareBelowMax() {
        let below17 = package([entry()], depends: [dep("firmware", "<<", "17.0")])
        #expect(verdict(below17) == .incompatible(.iOSVersion(required: "< 17.0", device: "17.5")))
        #expect(verdict(below17, context(deviceOS: "16.7")) == .compatible)
        // `<=` is inclusive, `>>` exclusive.
        #expect(verdict(package([entry()], depends: [dep("firmware", "<=", "17.5")])) == .compatible)
        #expect(verdict(package([entry()], depends: [dep("firmware", ">>", "17.5")]))
                == .incompatible(.iOSVersion(required: "> 17.5", device: "17.5")))
        let range = package([entry()], depends: [dep("firmware", ">=", "15.0"), dep("firmware", "<<", "17.0")])
        #expect(verdict(range) == .incompatible(.iOSVersion(required: "≥ 15.0, < 17.0", device: "17.5")))
        #expect(verdict(package([entry()], depends: [dep("firmware", ">=", "18.0")]))
                == .incompatible(.iOSVersion(required: "18.0", device: "17.5")))
    }

    @Test func firmwareEqualsIsThatVersionOnly() {
        let only17 = package([entry()], depends: [dep("firmware", "=", "17.0")])
        #expect(verdict(only17) == .incompatible(.iOSVersion(required: "= 17.0", device: "17.5")))
        #expect(verdict(only17, context(deviceOS: "17.0")) == .compatible)
    }

    @Test func anUnreadableFirmwareConstraintIsNeverSatisfied() {
        let p = package([entry()], depends: [[DebDependency(package: "firmware", unparseable: true)]])
        #expect(verdict(p) == .incompatible(.unreadableRequirement("iOS")))
        #expect(verdict(p, context(deviceOS: nil)) == .incompatible(.unreadableRequirement("iOS")))
    }

    @Test func unknownDeviceOSPasses() {
        let p = package([entry(slices: [slice(minOS: "99.0")])], depends: [dep("firmware", ">=", "99.0")])
        #expect(verdict(p, context(deviceOS: nil)) == .compatible)
    }

    // MARK: dependencies

    @Test func rocketBootstrap() {
        let p = package([entry()], depends: [dep("mobilesubstrate"), dep("com.rpetrich.rocketbootstrap")])
        #expect(verdict(p) == .incompatible(.needsJailbreak("RocketBootstrap")))
    }

    @Test func cepheiEmbedded() {
        let p = package([entry(linked: [Self.cephei])], depends: [dep("ws.hbang.common", ">=", "1.17")])
        let c = context(embedded: [embeddedCephei()])
        #expect(verdict(p, c) == .converted([.dependencyAdded("Cephei 2.0")]))
        #expect(TweakClassifier.providers(p, c) == [embeddedCephei()])
        #expect(TweakClassifier.resolution(p, c) == [
            Self.cephei: "@executable_path/Frameworks/XSideTweaks/deps/ws.hbang.common/Library/Frameworks/Cephei.framework/Cephei",
        ])
    }

    @Test func rootlessRpathCepheiUsesTheEmbeddedCopy() {
        let p = package([entry(linked: ["@rpath/Cephei.framework/Cephei"])], depends: [dep("ws.hbang.common")])
        let c = context(embedded: [embeddedCephei()])
        #expect(verdict(p, c) == .converted([.dependencyAdded("Cephei 2.0")]))
        #expect(TweakClassifier.resolution(p, c)["@rpath/Cephei.framework/Cephei"]
                == "@executable_path/Frameworks/XSideTweaks/deps/ws.hbang.common/Library/Frameworks/Cephei.framework/Cephei")
    }

    @Test func cepheiNotEmbeddedAndNotAdded() {
        let p = package([entry(linked: [Self.cephei])], depends: [dep("ws.hbang.common", ">=", "1.17")])
        #expect(verdict(p) == .incompatible(.missingDependency("Cephei")))
        // Linked without being declared: still named, not called a jailbreak library.
        #expect(verdict(package([entry(linked: [Self.cephei])])) == .incompatible(.missingDependency("Cephei")))
    }

    @Test func libGCUniversalIsKnownButNotEmbedded() {
        let p = package([entry()], depends: [dep("com.mrgcgamer.libgcuniversal")])
        #expect(verdict(p) == .incompatible(.missingDependency("libGCUniversal")))
    }

    @Test func theOnesDebWinsOverTheEmbeddedCopy() {
        let theirs = package([library(String(Self.cephei.dropFirst()))], id: "aaaaaaaaaaaaaaaa", packageID: "ws.hbang.common",
                             name: "Cephei", version: "1.17")
        let embedded = embeddedCephei(version: "2.0")
        let p = package([entry(linked: [Self.cephei])], depends: [dep("ws.hbang.common", ">=", "1.17")])
        let c = context(others: [theirs], embedded: [embedded])
        #expect(verdict(p, c) == .converted([.dependency("Cephei")]))
        #expect(TweakClassifier.resolution(p, c)[Self.cephei]
                == "@executable_path/Frameworks/XSideTweaks/aaaaaaaaaaaaaaaa/Library/Frameworks/Cephei.framework/Cephei")
        #expect(TweakClassifier.providers(p, c).isEmpty)

        let newer = package([entry(linked: [Self.cephei])], depends: [dep("ws.hbang.common", ">=", "1.18")])
        #expect(verdict(newer, c) == .converted([.dependencyAdded("Cephei 2.0")]))
        #expect(TweakClassifier.resolution(newer, c)[Self.cephei]
                == "@executable_path/Frameworks/XSideTweaks/deps/ws.hbang.common/Library/Frameworks/Cephei.framework/Cephei")
        #expect(TweakClassifier.providers(newer, c) == [embedded])
        // Neither satisfies: missing, named.
        let tooNew = package([entry()], depends: [dep("ws.hbang.common", ">=", "3.0")])
        #expect(verdict(tooNew, c) == .incompatible(.missingDependency("Cephei")))
    }

    @Test func providesSatisfiesADependency() {
        let fork = package([library("usr/lib/libfoobar.dylib")], id: "bbbbbbbbbbbbbbbb", packageID: "com.someone.foobar-fork",
                           name: "Foo Bar Fork", provides: ["com.foo.bar"])
        let p = package([entry(linked: ["/usr/lib/libfoobar.dylib"])], depends: [dep("com.foo.bar")])
        let c = context(others: [fork])
        #expect(verdict(p, c) == .converted([.dependency("Foo Bar Fork")]))
        #expect(TweakClassifier.resolution(p, c)["/usr/lib/libfoobar.dylib"]
                == "@executable_path/Frameworks/XSideTweaks/bbbbbbbbbbbbbbbb/usr/lib/libfoobar.dylib")
        // An unversioned Provides never satisfies a versioned dependency (Debian's rule).
        let versioned = package([entry()], depends: [dep("com.foo.bar", ">=", "2")])
        #expect(TweakClassifier.dependencies(versioned, c).map(\.1) == [.missing(DebDependency(package: "com.foo.bar", relation: ">=", version: "2"))])
    }

    @Test func twoProvidersFirstEnabledWins() {
        let first = package([library("usr/lib/libfoo.dylib")], id: "1111111111111111", packageID: "com.foo", name: "Foo One")
        let second = package([library("usr/lib/libfoo.dylib")], id: "2222222222222222", packageID: "com.foo2", name: "Foo Two",
                             provides: ["com.foo"])
        let p = package([entry(linked: ["/usr/lib/libfoo.dylib"])], depends: [dep("com.foo")])
        let c = context(others: [first, second])
        #expect(verdict(p, c) == .converted([.dependency("Foo One")]))
        #expect(TweakClassifier.resolution(p, c)["/usr/lib/libfoo.dylib"]
                == "@executable_path/Frameworks/XSideTweaks/1111111111111111/usr/lib/libfoo.dylib")
        let swapped = context(others: [second, first])
        #expect(verdict(p, swapped) == .converted([.dependency("Foo Two")]))
        #expect(TweakClassifier.dependencies(p, swapped).map(\.1) == [.addedByYou("Foo Two")])
    }

    @Test func alternativesTakeTheFirstSatisfiedOne() {
        let p = package([entry()], depends: [[DebDependency(package: "com.rpetrich.rocketbootstrap"),
                                               DebDependency(package: "ws.hbang.common")]])
        let c = context(embedded: [embeddedCephei()])
        #expect(verdict(p, c) == .converted([.dependencyAdded("Cephei 2.0")]))
        #expect(TweakClassifier.dependencies(p, c).map(\.1) == [.providedByXSide("Cephei 2.0")])
        // None satisfied: the first alternative's problem.
        #expect(verdict(p) == .incompatible(.needsJailbreak("RocketBootstrap")))
    }

    @Test func anUnreadableConstraintIsReportedNotSatisfied() {
        let p = package([entry()], depends: [[DebDependency(package: "ws.hbang.common", unparseable: true)]])
        #expect(verdict(p, context(embedded: [embeddedCephei()])) == .incompatible(.unreadableRequirement("Cephei")))
        let unknown = package([entry()], depends: [[DebDependency(package: "com.foo.bar", unparseable: true)]])
        let other = package([library("usr/lib/libbar.dylib")], id: "cccccccccccccccc", packageID: "com.foo.bar", name: "Bar")
        #expect(verdict(unknown, context(others: [other])) == .incompatible(.unreadableRequirement("com.foo.bar")))
    }

    @Test func dependenciesListsEachGroupWithItsStatus() {
        let p = package([entry()], depends: [dep("mobilesubstrate"), dep("ws.hbang.common", ">=", "1.17"),
                                              dep("com.foo.bar", ">=", "2"), dep("com.rpetrich.rocketbootstrap")])
        let list = TweakClassifier.dependencies(p, context(embedded: [embeddedCephei()]))
        #expect(list.map(\.0.package) == ["mobilesubstrate", "ws.hbang.common", "com.foo.bar", "com.rpetrich.rocketbootstrap"])
        #expect(list.map(\.1) == [.notNeeded, .providedByXSide("Cephei 2.0"),
                                  .missing(DebDependency(package: "com.foo.bar", relation: ">=", version: "2")),
                                  .jailbreakOnly("RocketBootstrap")])
    }

    @Test func libroot_isBuiltIntoTheTweak() {
        // libroot_dyn.a is linked into each tweak, and XSide's path redirect does the rootless
        // mapping: `Depends: libroot` (or its alias) is never a missing dependency.
        for id in ["libroot", "com.opa334.libroot"] {
            for d in [dep(id), dep(id, ">=", "1.0")] {
                let p = package([entry()], depends: [d])
                #expect(verdict(p) == .compatible, "\(id)")
                #expect(TweakClassifier.dependencies(p, context()).map(\.1) == [.builtIntoTweak("libroot")], "\(id)")
            }
        }
        // In an alternative group, and before a copy the person added (never copied in).
        let added = package([library("usr/lib/libroot.dylib")], id: "eeeeeeeeeeeeeeee", packageID: "libroot", name: "libroot")
        let p = package([entry()], depends: [[DebDependency(package: "libroot"), DebDependency(package: "com.foo.bar")]])
        let c = context(others: [added])
        #expect(verdict(p, c) == .compatible)
        #expect(TweakClassifier.providers(p, c).isEmpty)
        #expect(TweakClassifier.dependencies(p, c).map(\.1) == [.builtIntoTweak("libroot")])
    }

    @Test func altListStaysARealDependency() {
        let p = package([entry()], depends: [dep("com.opa334.altlist")])
        #expect(verdict(p) == .incompatible(.missingDependency("AltList")))
        #expect(TweakClassifier.dependencies(p, context()).map(\.1) == [.missing(DebDependency(package: "com.opa334.altlist"))])
        let added = package([library("Library/Frameworks/AltList.framework/AltList")], id: "ffffffffffffffff",
                            packageID: "com.opa334.altlist", name: "AltList")
        #expect(verdict(p, context(others: [added])) == .converted([.dependency("AltList")]))
    }

    @Test func aSubstrateDebAddedByThePersonIsNotUsed() {
        // Hooking frameworks are always XSide's ElleKit, even when someone added a Substrate .deb.
        let sub = package([library("Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate")], id: "dddddddddddddddd",
                          packageID: "mobilesubstrate", name: "Cydia Substrate")
        let p = package([entry(linked: [Self.substrate])], depends: [dep("mobilesubstrate")])
        let c = context(others: [sub])
        #expect(verdict(p, c) == .converted([.hookingLibrary]))
        #expect(TweakClassifier.dependencies(p, c).map(\.1) == [.notNeeded])
        #expect(TweakClassifier.resolution(p, c) == [Self.substrate: TweakLayout.elleKitLoadPath])
    }

    // MARK: linked libraries

    @Test func rpathLibrariesComeFromThePackageThenTheApp() {
        let own = package([entry(linked: ["@rpath/Foo.framework/Foo"]), library("Library/Frameworks/Foo.framework/Foo")])
        #expect(verdict(own) == .compatible)
        #expect(TweakClassifier.resolution(own, context())["@rpath/Foo.framework/Foo"]
                == "@executable_path/Frameworks/XSideTweaks/0123456789abcdef/Library/Frameworks/Foo.framework/Foo")

        let fromApp = package([entry(linked: ["@rpath/Bar.framework/Bar", "@loader_path/../Frameworks/Baz.framework/Baz"])])
        #expect(verdict(fromApp, context(appFiles: nil)) == .compatible)
        #expect(verdict(fromApp, context(appFiles: { _ in true })) == .compatible)
        #expect(verdict(fromApp, context(appFiles: { $0 == "Frameworks/Baz.framework/Baz" })) == .incompatible(.missingDependency("Bar.framework")))
        #expect(TweakClassifier.resolution(fromApp, context(appFiles: { _ in true })).isEmpty)
    }

    @Test func absolutePathsInThePackageAreConverted() {
        let p = package([entry(linked: ["/var/jb/Library/Frameworks/Foo.framework/Foo"]),
                         library("Library/Frameworks/Foo.framework/Foo")])
        #expect(verdict(p) == .converted([.jailbreakPaths]))
        #expect(TweakClassifier.resolution(p, context())["/var/jb/Library/Frameworks/Foo.framework/Foo"]
                == "@executable_path/Frameworks/XSideTweaks/0123456789abcdef/Library/Frameworks/Foo.framework/Foo")
    }

    @Test func anUnknownJailbreakLibraryNeedsAJailbreak() {
        #expect(verdict(package([entry(linked: ["/Library/Frameworks/Unknown.framework/Unknown"])]))
                == .incompatible(.needsJailbreak("Unknown.framework")))
    }

    @Test func resourcesMeanPathConversion() {
        let p = package([entry()], extraFiles: ["Library/Application Support/Example/icon.png"])
        #expect(verdict(p) == .converted([.jailbreakPaths]))
        #expect(verdict(package([entry(mentions: true)])) == .converted([.jailbreakPaths]))
        // A framework's own resources travel with it.
        let fw = package([entry(linked: ["@rpath/Foo.framework/Foo"]), library("Library/Frameworks/Foo.framework/Foo")],
                         extraFiles: ["Library/Frameworks/Foo.framework/Info.plist"])
        #expect(verdict(fw) == .compatible)
    }

    @Test func conversionsAccumulateInOrderAndOnce() {
        let p = package([entry(linked: [Self.substrate, Self.cephei], mentions: true),
                         entry("Second", linked: [Self.substrate])],
                        depends: [dep("ws.hbang.common")])
        #expect(verdict(p, context(embedded: [embeddedCephei()])) == .converted([.dependencyAdded("Cephei 2.0"), .hookingLibrary, .jailbreakPaths]))
    }

    @Test func theFirstProblemWins() {
        let p = package([entry(filter: TweakFilter(bundles: ["com.other.app"]), slices: [slice("arm64e")])],
                        depends: [dep("com.rpetrich.rocketbootstrap")])
        #expect(verdict(p) == .incompatible(.wrongArchitecture(["arm64e"])))
    }

    @Test func pathsWithoutSupportLibrary() {
        let p = package([entry(mentions: true)])
        #expect(verdict(p, context(support: false)) == .incompatible(.missingDependency("XSideTweakSupport")))
    }

    @Test func unknownUsrLibIsJailbreakWhenNotInTheSDK() throws {
        let sdk = TestTemp.root.appendingPathComponent("sdk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sdk) }
        try FileManager.default.createDirectory(at: sdk.appendingPathComponent("usr/lib/system"), withIntermediateDirectories: true)
        try Data().write(to: sdk.appendingPathComponent("usr/lib/libz.1.tbd"))
        try Data().write(to: sdk.appendingPathComponent("usr/lib/system/libsystem_kernel.tbd"))
        let system = TweakClassifier.systemLibraries(sdk: sdk)
        #expect(system("/usr/lib/libz.1.dylib"))
        #expect(system("/usr/lib/system/libsystem_kernel.dylib"))
        #expect(system("/System/Library/Frameworks/UIKit.framework/UIKit"))
        #expect(system("/usr/lib/swift/libswiftCore.dylib"))
        #expect(!system("/usr/lib/libcolorpicker.dylib"))
        #expect(!system("/usr/lib/../../tmp/libz.1.dylib"))
        #expect(!system("/System/../var/jb/usr/lib/libfoo.dylib"))
        #expect(!system("@rpath/libz.1.dylib"))

        let p = package([entry(linked: ["/usr/lib/libcolorpicker.dylib", "/usr/lib/libz.1.dylib"])])
        #expect(verdict(p, context(system: system)) == .incompatible(.needsJailbreak("libcolorpicker.dylib")))
        #expect(verdict(package([entry(linked: ["/usr/lib/libz.1.dylib"])]), context(system: system)) == .compatible)
        #expect(verdict(package([entry(linked: ["/usr/lib/libunknownthing.dylib"])]), context(system: system))
                == .incompatible(.missingDependency("libunknownthing.dylib")))

        // Without an SDK, only the shipped list of iOS's /usr/lib names counts as system.
        let noSDK = TweakClassifier.systemLibraries(sdk: nil)
        for lib in ["/usr/lib/libobjc.A.dylib", "/usr/lib/libSystem.B.dylib", "/usr/lib/libc++.1.dylib", "/usr/lib/libz.1.dylib",
                    "/usr/lib/libsqlite3.dylib", "/usr/lib/system/libsystem_kernel.dylib", "/usr/lib/swift/libswiftCore.dylib",
                    "/System/Library/Frameworks/UIKit.framework/UIKit"] {
            #expect(noSDK(lib), "\(lib)")
        }
        #expect(!noSDK("/usr/lib/libcolorpicker.dylib"))
        #expect(!noSDK("/usr/lib/libunknownthing.dylib"))
        #expect(!noSDK("/usr/lib/TweakInject/libobjc.A.dylib"))
        #expect(!noSDK("/usr/lib/libsubstrate.dylib"))
        #expect(!noSDK("/Library/Frameworks/Cephei.framework/Cephei"))
        #expect(!noSDK("/var/jb/usr/lib/libz.dylib"))
        #expect(!noSDK("@rpath/Foo.framework/Foo"))
        #expect(!noSDK("/System/../Library/Frameworks/X.framework/X"))
    }

    @Test func libraryPackageIsCompatible() {
        #expect(verdict(package([library("usr/lib/libfoo.dylib", linked: ["/usr/lib/libobjc.A.dylib"])])) == .compatible)
        #expect(verdict(package([], kind: .bundle, extraFiles: ["Example.bundle/icon.png"])) == .compatible)
    }

    @Test func libraryPackagesAreClassifiedByTheirOwnBinaries() {
        #expect(verdict(package([library("usr/lib/libfoo.dylib", linked: [Self.substrate])])) == .converted([.hookingLibrary]))
        let arm64e = TweakBinary(path: "usr/lib/libfoo.dylib", isEntry: false, filter: nil, slices: [slice("arm64e")], linked: [],
                                 mentionsJailbreakPaths: false, imageName: "libfoo.dylib")
        #expect(verdict(package([arm64e])) == .incompatible(.wrongArchitecture(["arm64e"])))
        #expect(verdict(package([library("usr/lib/libfoo.dylib", linked: ["/usr/lib/libactivator.dylib"])]))
                == .incompatible(.needsJailbreak("Activator")))
    }

    @Test func aProvidersProblemIsTheTweaksProblem() {
        let arm64eCephei = package([TweakBinary(path: String(Self.cephei.dropFirst()), isEntry: false, filter: nil,
                                                slices: [slice("arm64e")], linked: [], mentionsJailbreakPaths: false,
                                                imageName: "Cephei")],
                                   id: "ws.hbang.common", origin: .embedded, packageID: "ws.hbang.common", name: "Cephei", version: "2.0")
        let p = package([entry(linked: [Self.cephei])], depends: [dep("ws.hbang.common")])
        #expect(verdict(p, context(embedded: [arm64eCephei])) == .incompatible(.wrongArchitecture(["arm64e"])))

        let jbLib = package([library("usr/lib/libfoo.dylib", linked: ["/usr/lib/librocketbootstrap.dylib"])], id: "eeeeeeeeeeeeeeee",
                            packageID: "com.foo", name: "Foo")
        let q = package([entry(linked: ["/usr/lib/libfoo.dylib"])], depends: [dep("com.foo")])
        #expect(verdict(q, context(others: [jbLib])) == .incompatible(.needsJailbreak("RocketBootstrap")))
        // Two packages depending on each other never loop.
        let a = package([library("usr/lib/liba.dylib", linked: ["/usr/lib/libb.dylib"])], id: "aaaaaaaaaaaaaaaa", packageID: "com.a",
                        name: "A", depends: [dep("com.b")])
        let b = package([library("usr/lib/libb.dylib", linked: ["/usr/lib/liba.dylib"])], id: "bbbbbbbbbbbbbbbb", packageID: "com.b",
                        name: "B", depends: [dep("com.a")])
        let r = package([entry(linked: ["/usr/lib/liba.dylib"])], depends: [dep("com.a")])
        #expect(verdict(r, context(others: [a, b])) == .converted([.dependency("A")]))
    }

    @Test func jailbreakOnlyPackagesTheyAddedStillNeedAJailbreak() {
        let rb = package([library("usr/lib/librocketbootstrap.dylib")], id: "ffffffffffffffff",
                         packageID: "com.rpetrich.rocketbootstrap", name: "RocketBootstrap")
        let p = package([entry(linked: ["/usr/lib/librocketbootstrap.dylib"])], depends: [dep("com.rpetrich.rocketbootstrap")])
        let c = context(others: [rb])
        #expect(verdict(p, c) == .incompatible(.needsJailbreak("RocketBootstrap")))
        #expect(TweakClassifier.dependencies(p, c).map(\.1) == [.jailbreakOnly("RocketBootstrap")])
        #expect(TweakClassifier.resolution(p, c).isEmpty)
        // Undeclared, rootful or rootless (@rpath, app facts unknown): still named.
        #expect(verdict(package([entry(linked: ["/usr/lib/librocketbootstrap.dylib"])]), c) == .incompatible(.needsJailbreak("RocketBootstrap")))
        #expect(verdict(package([entry(linked: ["@rpath/librocketbootstrap.dylib"])])) == .incompatible(.needsJailbreak("RocketBootstrap")))
        #expect(verdict(package([entry(linked: ["@rpath/libhooker.dylib"])])) == .incompatible(.needsJailbreak("libhooker.dylib")))
        #expect(verdict(package([entry(linked: ["@rpath/libhooker.dylib"])]), context(libhooker: true)) == .converted([.hookingLibrary]))
    }

    @Test func aJailbreakAlternativeIsNotDroppedForAnUnknownOne() {
        let p = package([entry()], depends: [[DebDependency(package: "com.rpetrich.rocketbootstrap"),
                                               DebDependency(package: "com.unknown.thing")]])
        #expect(verdict(p) == .incompatible(.needsJailbreak("RocketBootstrap")))
        let flipped = package([entry()], depends: [[DebDependency(package: "com.unknown.thing"),
                                                     DebDependency(package: "com.rpetrich.rocketbootstrap")]])
        #expect(verdict(flipped) == .incompatible(.needsJailbreak("RocketBootstrap")))
        // A real alternative that is satisfied still wins.
        let ok = package([entry()], depends: [[DebDependency(package: "com.rpetrich.rocketbootstrap"),
                                                DebDependency(package: "ws.hbang.common")]])
        #expect(verdict(ok, context(embedded: [embeddedCephei()])) == .converted([.dependencyAdded("Cephei 2.0")]))
    }

    @Test func dependenciesNeverOfferAJailbreakOnlyPackage() {
        let rb = package([library("usr/lib/librocketbootstrap.dylib")], id: "ffffffffffffffff",
                         packageID: "com.rpetrich.rocketbootstrap", name: "RocketBootstrap", provides: ["com.foo.ipc"])
        let p = package([entry()], depends: [dep("com.foo.ipc")])
        let c = context(others: [rb])
        #expect(TweakClassifier.dependencies(p, c).map(\.1) == [.missing(DebDependency(package: "com.foo.ipc"))])
        #expect(verdict(p, c) == .compatible)   // unknown and nobody usable provides it: left to the linked names
    }

    @Test func jailbreakOnlyFrameworksAreNamed() {
        for (path, name) in [("/Library/Frameworks/RocketBootstrap.framework/RocketBootstrap", "RocketBootstrap"),
                             ("@rpath/Activator.framework/Activator", "Activator"),
                             ("/var/jb/Library/Frameworks/AppList.framework/AppList", "AppList"),
                             ("@rpath/libSandy.framework/libSandy", "libSandy")] {
            #expect(verdict(package([entry(linked: [path])])) == .incompatible(.needsJailbreak(name)), "\(path)")
        }
    }

    @Test func commonDaemonsNeedAJailbreakAtAddTime() {
        for daemon in ["kbd", "lockdownd", "backboardd", "mediaserverd", "assertiond", "locationd", "imagent", "bluetoothd",
                       "wifid", "configd", "UserEventAgent"] {
            let p = package([entry(filter: TweakFilter(executables: [daemon]))])
            #expect(verdict(p, context(executable: nil)) == .incompatible(.needsJailbreak(daemon)), "\(daemon)")
        }
    }

    @Test func libhookerDependsNeedsElleKitsLibhooker() {
        let p = package([entry()], depends: [dep("org.coolstar.libhooker")])
        #expect(verdict(p) == .incompatible(.needsJailbreak("libhooker")))
        #expect(TweakClassifier.dependencies(p, context()).map(\.1) == [.jailbreakOnly("libhooker")])
        #expect(verdict(p, context(libhooker: true)) == .compatible)
        #expect(TweakClassifier.dependencies(p, context(libhooker: true)).map(\.1) == [.notNeeded])
    }

    @Test func firmwareInsideAnAlternativesGroup() {
        let p = package([entry()], depends: [[DebDependency(package: "firmware", relation: ">=", version: "18.0"),
                                               DebDependency(package: "firmware", relation: "<<", version: "16.0")]])
        #expect(verdict(p) == .incompatible(.iOSVersion(required: "18.0", device: "17.5")))
        #expect(verdict(p, context(deviceOS: "15.0")) == .compatible)
        #expect(verdict(p, context(deviceOS: "18.1")) == .compatible)
        let bad = package([entry()], depends: [[DebDependency(package: "firmware", unparseable: true),
                                                 DebDependency(package: "firmware", relation: "<<", version: "16.0")]])
        #expect(verdict(bad) == .incompatible(.unreadableRequirement("iOS")))
    }

    @Test func systemLibrariesAreNeverShadowed() {
        let shadow = package([library("usr/lib/libobjc.A.dylib")], id: "9999999999999999", packageID: "com.shadow", name: "Shadow")
        let p = package([entry(linked: ["/usr/lib/libobjc.A.dylib"])], depends: [dep("com.shadow")])
        #expect(TweakClassifier.resolution(p, context(others: [shadow]))["/usr/lib/libobjc.A.dylib"] == nil)
        // A package nothing depends on is never searched for a linked library.
        let lib = package([library("usr/lib/libfoo.dylib")], id: "8888888888888888", packageID: "com.foo", name: "Foo")
        let q = package([entry(linked: ["/usr/lib/libfoo.dylib"])])
        #expect(verdict(q, context(others: [lib])) == .incompatible(.missingDependency("libfoo.dylib")))
        #expect(TweakClassifier.resolution(q, context(others: [lib])).isEmpty)
    }

    @Test func aFilterProblemNeverHidesAnother() {
        let other = TweakFilter(bundles: ["com.other.app"])
        let rb = package([entry(filter: other)], depends: [dep("com.rpetrich.rocketbootstrap")])
        #expect(verdict(rb) == .incompatible(.needsJailbreak("RocketBootstrap")))
        #expect(!verdict(rb).canOverride)
        #expect(TweakClassifier.verdict(rb, context(), overridingFilter: true) == .incompatible(.needsJailbreak("RocketBootstrap")))
        let noCephei = package([entry(filter: TweakFilter())], depends: [dep("ws.hbang.common")])
        #expect(verdict(noCephei) == .incompatible(.missingDependency("Cephei")))
        let unknown = package([entry(filter: other, linked: ["/Library/Frameworks/Unknown.framework/Unknown"])])
        #expect(verdict(unknown) == .incompatible(.needsJailbreak("Unknown.framework")))
        #expect(verdict(package([entry(filter: other, linked: [Self.substrate])]), context(elleKit: false))
                == .incompatible(.missingDependency("ElleKit")))

        // Forced: the 🔧 list that applies once « Injecter quand même » is chosen.
        let forced = package([entry(filter: other, linked: [Self.substrate])])
        #expect(verdict(forced) == .incompatible(.madeForAnotherApp(["com.other.app"])))
        #expect(verdict(forced).canOverride)
        #expect(TweakClassifier.verdict(forced, context(), overridingFilter: true) == .converted([.hookingLibrary]))
        #expect(TweakClassifier.verdict(package([entry(filter: TweakFilter())]), context(), overridingFilter: true) == .compatible)
        let all = TweakClassifier.classify(forced, context())
        #expect(all.verdict == verdict(forced))
        #expect(all.verdictOverridingFilter == .converted([.hookingLibrary]))
        #expect(all.resolution == [Self.substrate: TweakLayout.elleKitLoadPath])
        #expect(all.providers.isEmpty)
    }

    @Test func systemProcessFiltersNeedAJailbreakWithUnknownAppFacts() {
        let exe = package([entry(filter: TweakFilter(executables: ["SpringBoard"]))])
        #expect(verdict(exe, context(executable: nil)) == .incompatible(.needsJailbreak("SpringBoard")))
        #expect(verdict(package([entry(filter: TweakFilter(executables: ["Example"]))]), context(executable: nil)) == .compatible)
        let sb = package([entry(filter: TweakFilter(classes: ["SBIconController", "SBHomeScreenViewController"]))])
        #expect(verdict(sb, context(classes: nil)) == .incompatible(.needsJailbreak("SBIconController")))
        #expect(verdict(sb, context(classes: ["AppDelegate"])) == .incompatible(.needsJailbreak("SBIconController")))
        #expect(verdict(package([entry(filter: TweakFilter(classes: ["SBFoo", "YTPlayerView"]))]), context(classes: nil)) == .compatible)
    }

    @Test func deliberatelyEmptyDebIsNothingToInject() {
        let v = verdict(package([], extraFiles: ["Library/Application Support/Example/readme.txt"]))
        #expect(v == .incompatible(.nothingToInject))
        #expect(!v.canOverride)
    }

    @Test func hostileNamesNeverTrap() {
        let names = ["", "/", "@rpath/", "@rpath/../../..", "@loader_path", "relative.dylib", "/var/jb/", "/var/jb",
                     String(repeating: "/a", count: 2000), "@executable_path/\u{0}"]
        let p = package([entry(linked: names)])
        if case .incompatible = verdict(p, context(appFiles: { _ in false })) {} else { Issue.record("expected a problem") }
        _ = TweakClassifier.resolution(p, context())
    }

    // MARK: verdict

    @Test func onlyAnotherAppAndNoFilterCanBeOverridden() {
        let problems: [TweakProblem] = [.needsJailbreak("x"), .wrongArchitecture(["arm64e"]), .notForIOS,
                                        .iOSVersion(required: "18.0", device: "17.5"), .missingDependency("x"),
                                        .nothingToInject, .unreadableRequirement("x")]
        for problem in problems { #expect(!TweakVerdict.incompatible(problem).canOverride) }
        #expect(TweakVerdict.incompatible(.madeForAnotherApp(["a"])).canOverride)
        #expect(TweakVerdict.incompatible(.noFilter).canOverride)
        #expect(!TweakVerdict.compatible.canOverride)
        #expect(!TweakVerdict.converted([.hookingLibrary]).canOverride)
    }

    @Test func verdictsRoundTripThroughJSON() throws {
        let verdicts: [TweakVerdict] = [.compatible, .converted([.hookingLibrary, .dependency("A"), .dependencyAdded("B"), .jailbreakPaths]),
                                        .incompatible(.iOSVersion(required: "18.0", device: "17.5")),
                                        .incompatible(.madeForAnotherApp(["a", "b"])), .incompatible(.noFilter)]
        let data = try JSONEncoder().encode(verdicts)
        #expect(try JSONDecoder().decode([TweakVerdict].self, from: data) == verdicts)
    }

    @Test func everyReasonExistsInEnglishAndFrench() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func table(_ lang: String) throws -> [String: String] {
            let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/\(lang).lproj/Localizable.strings"))
            return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] ?? [:]
        }
        let en = try table("en"), fr = try table("fr")
        let problems: [TweakProblem] = [.needsJailbreak("x"), .madeForAnotherApp(["a"]), .wrongArchitecture(["arm64e"]), .notForIOS,
                                        .iOSVersion(required: "18.0", device: "17.5"), .missingDependency("x"), .nothingToInject,
                                        .noFilter, .unreadableRequirement("x")]
        let conversions: [TweakConversion] = [.hookingLibrary, .jailbreakPaths, .dependency("x"), .dependencyAdded("x")]
        let keys = problems.map(\.stringKey) + conversions.map(\.stringKey) + [TweakVerdict.overrideKey]
        #expect(Set(keys).count == keys.count)
        for key in keys {
            #expect(en[key] != nil, "missing in English: \(key)")
            #expect(fr[key] != nil, "missing in French: \(key)")
        }
        #expect(fr[TweakProblem.noFilter.stringKey] == "Ce tweak ne dit pas dans quelles apps il se charge.")
        #expect(en[TweakProblem.noFilter.stringKey] == "This tweak doesn't say which apps it loads into.")
        #expect(fr[TweakVerdict.overrideKey] == "Injecter quand même")
        #expect(fr[TweakConversion.dependencyAdded("x").stringKey] == "Dépendance ajoutée : %@")
    }

    /// « Demande un jailbreak » reads differently for where the tweak loads (its filter) and for a
    /// library it uses: the text key says which.
    @Test func needsJailbreakIsWordedForAProcessOrALibrary() {
        let sb = package([entry(filter: TweakFilter(bundles: ["com.apple.springboard"], executables: ["SpringBoard"],
                                                    classes: ["SBIconController"]))])
        for target in ["com.apple.springboard", "SpringBoard", "SBIconController"] {
            #expect(TweakProblem.needsJailbreak(target).stringKey(for: sb) == "tweaks.problem.needsJailbreak")
        }
        #expect(TweakProblem.needsJailbreak("RocketBootstrap").stringKey(for: sb) == "tweaks.problem.needsJailbreakLibrary")
        #expect(TweakProblem.needsJailbreak("RocketBootstrap").stringKey(for: package([entry(filter: nil)]))
                == "tweaks.problem.needsJailbreakLibrary")
        #expect(TweakProblem.notForIOS.stringKey(for: sb) == TweakProblem.notForIOS.stringKey)
    }

    // MARK: C function hooks

    /// A tweak hooking C functions stays 🔧 (its Objective-C hooks work) with a warning: stock iOS
    /// kills the app when it patches code.
    @Test func cFunctionHooksGetAWarningButKeepTheirVerdict() {
        var hooking = entry(linked: ["/usr/lib/libobjc.A.dylib", Self.substrate])
        hooking.cFunctionHooks = ["MSHookFunction"]
        var lib = library("usr/lib/libhelper.dylib")
        lib.cFunctionHooks = ["LHHookFunctions", "MSHookFunction"]
        let p = package([hooking, lib])
        #expect(p.cFunctionHooks == ["LHHookFunctions", "MSHookFunction"])
        #expect(TweakClassifier.warnings(p) == [.cFunctionHooks(["LHHookFunctions", "MSHookFunction"])])
        #expect(TweakWarning.cFunctionHooks(["MSHookFunction"]).stringKey == "tweaks.warning.cFunctionHooks")
        guard case .converted(let list) = TweakClassifier.verdict(p, context()) else {
            Issue.record("expected 🔧"); return
        }
        #expect(list.contains(.hookingLibrary))
        // ObjC hooks only, or analysed before XSide looked (nil): no warning.
        #expect(TweakClassifier.warnings(package([entry(linked: [Self.substrate])])).isEmpty)
        var none = entry(); none.cFunctionHooks = []
        #expect(TweakClassifier.warnings(package([none])).isEmpty)
    }

    @Test func cFunctionHooksSurviveCodingAndOlderFilesHaveNone() throws {
        var b = entry(); b.cFunctionHooks = ["MSHookFunction"]
        let back = try JSONDecoder().decode(TweakBinary.self, from: JSONEncoder().encode(b))
        #expect(back == b)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry())) as? [String: Any])
        json["cFunctionHooks"] = nil
        let old = try JSONDecoder().decode(TweakBinary.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.cFunctionHooks == nil)
    }
}

// MARK: One Cephei per device (device round 2, item 16)

extension TweakClassifierTests {
    /// Chariz's rootful Cephei 1.17.1: its frameworks are in usr/lib (the deb's
    /// /Library/Frameworks/Cephei.framework is a symlink, not a file XSide keeps).
    private func downloadedCephei117() -> TweakPackage {
        package([library("usr/lib/Cephei.framework/Cephei"),
                 library("usr/lib/CepheiUI.framework/CepheiUI", linked: [Self.cephei])],
                id: "47b661fc09c06549", origin: .downloaded(repo: "chariz", url: "https://repo.chariz.com/x.deb", sha256: String(repeating: "a", count: 64)),
                packageID: "ws.hbang.common", name: "Cephei Tweak Support", version: "1.17.1",
                depends: [[DebDependency(package: "firmware", relation: "<<", version: "8.0"),
                           DebDependency(package: "firmware", relation: ">=", version: "11.0")]])
    }

    private func cepheiUser() -> TweakPackage {
        package([entry("XSTestTweakCephei", linked: ["/usr/lib/libobjc.A.dylib", Self.cephei])], id: "80d9f075745add78",
                packageID: "io.github.xside.testtweak.cephei", name: "XSide Test Cephei",
                depends: [dep("ws.hbang.common", ">=", "1.0")])
    }

    private func needsCepheiOld() -> TweakPackage {
        package([entry("XSTestNeedsCepheiOld")], id: "d2b50f75948bf215", packageID: "io.github.xside.testtweak.cepheiold",
                name: "XSide Test Needs Cephei < 2.0", depends: [dep("ws.hbang.common", "<<", "2.0")])
    }

    /// The device's exact case: cephei-user + needs-cephei-old + XSide's Cephei 2.0 + the
    /// downloaded 1.17.1 on that device. 1.17.1 satisfies both (≥ 1.0 and < 2.0), so both use it,
    /// and cephei-user's /Library/Frameworks/Cephei.framework/Cephei is found in its usr/lib copy
    /// (it was « missing Cephei » and left out at signing).
    @Test func cepheiUserAndNeedsCepheiOldShareTheDownloadedCephei() {
        let user = cepheiUser(), old = needsCepheiOld(), c117 = downloadedCephei117()
        let c = context(others: [old, c117], embedded: [embeddedCephei()])
        let v = verdict(user, c)
        #expect(v == .converted([.dependency("Cephei")]))
        #expect(TweakClassifier.resolution(user, c)[Self.cephei]
                == TweakLayout.loadPrefix + TweakLayout.directory(c117) + "/usr/lib/Cephei.framework/Cephei")
        #expect(TweakClassifier.providers(user, c).isEmpty) // XSide's 2.0 isn't copied too
        let cOld = context(others: [user, c117], embedded: [embeddedCephei()])
        #expect(verdict(old, cOld) == .converted([.dependency("Cephei")]))
        #expect(DependencyRows.missing(old, cOld).isEmpty)
        #expect(TweakClassifier.dependencies(user, c).map(\.1) == [.addedByYou("Cephei Tweak Support")])
        // The downloaded copy's own CepheiUI finds its Cephei in usr/lib too.
        if case .incompatible(let p) = verdict(c117, context(embedded: [embeddedCephei()])) { Issue.record("1.17.1 ❌: \(p)") }
    }

    /// Without the downloaded copy on that device, XSide's 2.0 serves cephei-user.
    @Test func withoutTheDownloadedCopyXSidesCepheiServes() {
        let user = cepheiUser()
        let c = context(others: [needsCepheiOld()], embedded: [embeddedCephei()])
        #expect(verdict(user, c) == .converted([.dependencyAdded("Cephei 2.0")]))
        #expect(TweakClassifier.providers(user, c).map(\.id) == ["ws.hbang.common"])
    }

    /// Two tweaks on one device that need versions no single copy satisfies (≥ 2.0 and < 2.0):
    /// both are ❌ with the conflict (one process can load only one Cephei).
    @Test func twoTweaksNeedingDifferentVersionsConflict() {
        let new = package([entry("NeedsNew", linked: [Self.cephei])], id: "1111111111111111", packageID: "com.example.new",
                          name: "Needs New", depends: [dep("ws.hbang.common", ">=", "2.0")])
        let old = needsCepheiOld(), c117 = downloadedCephei117()
        let problem = TweakProblem.dependencyConflict("Cephei 2.0", ["≥ 2.0", "< 2.0"]) // XSide's copy, named with its version
        #expect(verdict(new, context(others: [old, c117], embedded: [embeddedCephei()])) == .incompatible(problem))
        #expect(verdict(old, context(others: [new, c117], embedded: [embeddedCephei()]))
                == .incompatible(.dependencyConflict("Cephei", ["< 2.0", "≥ 2.0"])))
        #expect(!TweakVerdict.incompatible(problem).canOverride)
        // Off on that device (not in `others`): no conflict.
        #expect(verdict(new, context(others: [c117], embedded: [embeddedCephei()])) == .converted([.dependencyAdded("Cephei 2.0")]))
    }
}
