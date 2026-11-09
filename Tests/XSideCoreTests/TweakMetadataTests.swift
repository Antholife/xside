import Foundation
import Testing
@testable import XSideCore

struct TweakMetadataTests {
    private let real = """
    Package: com.foo.tweak
    Name: Foo Tweak
    Version: 1.2-3
    Architecture: iphoneos-arm64
    Author: Jane <j@x.y>
    Description: does things
     with a continuation line
    Depends: mobilesubstrate, firmware (>= 15.0), ws.hbang.common (>= 1.17) | com.foo.alt
    Provides: com.foo.alt
    """

    @Test func parsesARealControl() throws {
        let c = try DebControl.parse(real)
        #expect(c.package == "com.foo.tweak")
        #expect(c.name == "Foo Tweak")
        #expect(c.version == "1.2-3")
        #expect(c.author == "Jane")
        #expect(c.architecture == "iphoneos-arm64")
        #expect(c.provides == ["com.foo.alt"])
        #expect(c.depends == [
            [DebDependency(package: "mobilesubstrate")],
            [DebDependency(package: "firmware", relation: ">=", version: "15.0")],
            [DebDependency(package: "ws.hbang.common", relation: ">=", version: "1.17"), DebDependency(package: "com.foo.alt")],
        ])
    }

    @Test func continuationLinesJoinDepends() throws {
        let c = try DebControl.parse("Package: a\nDepends: b,\n c (<< 2) [arm64],\n D:any\n")
        #expect(c.depends.map { $0[0].package } == ["b", "c", "d"])
        #expect(c.depends[1][0].relation == "<<")
    }

    @Test func controlWithoutPackageThrows() {
        #expect(throws: DebError.self) { try DebControl.parse("Name: x\nVersion: 1\n") }
        #expect(throws: DebError.self) { try DebControl.parse("") }
    }

    @Test func controlOver64KiBThrows() {
        let big = "Package: a\nName: " + String(repeating: "x", count: 70_000)
        #expect(throws: DebError.tooLarge) { try DebControl.parse(big) }
    }

    @Test func controlCharactersAreStripped() throws {
        let c = try DebControl.parse("Package: a\nName: Ev\u{1B}[31mil\u{202E}x\u{7}\nAuthor: Bob\u{0} <b@c>\n")
        #expect(c.name == "Ev[31milx")
        #expect(c.author == "Bob")
    }

    @Test func hostileFieldCountsAreCapped() throws {
        var text = "Package: a\n"
        for i in 0..<5000 { text += "X-\(i): v\n" }
        text += "Depends: " + (0..<5000).map { "p\($0)" }.joined(separator: ",") + "\n"
        let c = try DebControl.parse(String(text.prefix(60_000)))
        #expect(c.package == "a")
        #expect(c.depends.count <= ControlLimits.maxGroups)
    }

    @Test func firmwareRangeReadsBothBounds() throws {
        let c = try DebControl.parse("Package: a\nDepends: firmware (>= 14.0), firmware (>= 15.0), firmware (<< 17.0), firmware (<< 16.5), x\n")
        let r = DebControl.firmwareRange(c.depends)
        #expect(r.min == "15.0")
        #expect(r.belowMax == "16.5")
        let none = DebControl.firmwareRange([])
        #expect(none.min == nil && none.belowMax == nil)
    }

    @Test func readsPackagesStanzas() throws {
        let packages = """
        Package: ws.hbang.common
        Version: 1.17.1
        Architecture: iphoneos-arm
        Depends: firmware (>= 11.0)
        Filename: ./debs/ws.hbang.common_1.17.1_iphoneos-arm.deb
        SHA256: aa

        Package: ws.hbang.common
        Version: 1.18.0
        Architecture: iphoneos-arm64
        Filename: ./debs/ws.hbang.common_1.18.0_iphoneos-arm64.deb

        """
        let s = try DebControl.stanzas(packages)
        #expect(s.count == 2)
        #expect(s[1]["version"] == "1.18.0")
        #expect(s[0]["filename"]?.hasSuffix(".deb") == true)
        #expect(try DebControl.make(s[0]).depends.count == 1)
        #expect(throws: DebError.tooLarge) { try DebControl.stanzas(packages, maxStanzas: 1) }
    }

    @Test func parsesOpenStepFilterPlist() throws {
        let text = #"{ Filter = { Bundles = ("com.apple.UIKit", "com.foo.app"); Executables = (SpringBoard); Classes = (UIView); Mode = Any; }; }"#
        let f = try #require(TweakFilter.parse(Data(text.utf8)))
        #expect(f.bundles == ["com.apple.UIKit", "com.foo.app"])
        #expect(f.executables == ["SpringBoard"])
        #expect(f.classes == ["UIView"])
        #expect(f.anyMode)
    }

    @Test func parsesXMLFilterPlistDefaultsToAll() throws {
        let xml = try PropertyListSerialization.data(fromPropertyList: ["Filter": ["Bundles": ["a"]]], format: .xml, options: 0)
        let f = try #require(TweakFilter.parse(xml))
        #expect(f == TweakFilter(bundles: ["a"]))
    }

    @Test func filterIgnoresNonStringsAndCapsLists() throws {
        var items: [Any] = [1, true, ["x"], "keep"]
        items += (0..<2000).map { "b\($0)" }
        let data = try PropertyListSerialization.data(fromPropertyList: ["Filter": ["Bundles": items]], format: .binary, options: 0)
        let f = try #require(TweakFilter.parse(data))
        #expect(f.bundles.count == 512)
        #expect(f.bundles.first == "keep")
        #expect(TweakFilter.parse(Data("not a plist".utf8)) == nil)
    }

    @Test func filterOver64KiBIsNil() {
        let big = "{ Filter = { Bundles = (" + String(repeating: "a, ", count: 30_000) + "b); }; }"
        #expect(TweakFilter.parse(Data(big.utf8)) == nil)
    }

    @Test func knownDependencyTable() {
        for p in ["mobilesubstrate", "com.saurik.substrate", "org.coolstar.libhooker", "com.ex.substitute", "com.ex.libsubstitute", "ellekit"] {
            #expect(KnownDependency.role(of: p) == .hooking)
        }
        for p in ["firmware", "cy+cpu.arm64", "cy+model.iphone", "gsc.armv7"] { #expect(KnownDependency.role(of: p) == .ignored) }
        #expect(KnownDependency.role(of: "preferenceloader") == .settings)
        #expect(KnownDependency.role(of: "com.rpetrich.rocketbootstrap") == .jailbreakOnly("RocketBootstrap"))
        #expect(KnownDependency.role(of: "libactivator") == .jailbreakOnly("Activator"))
        #expect(KnownDependency.role(of: "com.muirey03.libmryipc") == .jailbreakOnly("libMRYIPC"))
        #expect(KnownDependency.role(of: "applist") == .jailbreakOnly("AppList"))
        #expect(KnownDependency.role(of: "com.opa334.libsandy") == .jailbreakOnly("libSandy"))
        #expect(KnownDependency.role(of: "ws.hbang.common") == .library("Cephei"))
        #expect(KnownDependency.role(of: "com.opa334.altlist") == .library("AltList"))
        #expect(KnownDependency.role(of: "libroot") == .library("libroot"))
        #expect(KnownDependency.role(of: "com.opa334.libroot") == .library("libroot"))
        #expect(KnownDependency.role(of: "com.mrgcgamer.libgcuniversal") == .library("libGCUniversal"))
        #expect(KnownDependency.role(of: "MobileSubstrate") == .hooking)
        #expect(KnownDependency.role(of: "com.unknown.thing") == nil)
    }
}
