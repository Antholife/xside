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
        let c = try DebControl.parse(text)
        #expect(c.package == "a")
        let deps = "Package: a\nDepends: " + (0..<5000).map { "p\($0)" }.joined(separator: ",") + "\n"
        #expect(throws: DebError.tooLarge) { try DebControl.parse(deps) }
    }

    @Test(arguments: ["../../x", "a b", "A", "-a", ".a", "a/b", "", "a\u{e9}", String(repeating: "a", count: 129)])
    func invalidPackageIDsThrow(_ id: String) {
        #expect(throws: DebError.self) { try DebControl.parse("Package: \(id)\nVersion: 1\n") }
    }

    @Test func validPackageIDsPass() throws {
        for id in ["a", "0ad", "libc++-dev", "com.foo.bar-baz+1", String(repeating: "a", count: 128)] {
            #expect(try DebControl.parse("Package: \(id)\n").package == id)
        }
    }

    @Test func crlfControlAndPackagesParse() throws {
        let c = try DebControl.parse("Package: com.foo\r\nName: Foo\r\nDepends: firmware (>= 15.0),\r\n mobilesubstrate\r\n")
        #expect(c.package == "com.foo")
        #expect(c.name == "Foo")
        #expect(c.depends.count == 2)
        let s = try DebControl.stanzas("Package: a\r\nVersion: 1\r\n\r\nPackage: b\r\nVersion: 2\r\n")
        #expect(s.count == 2)
        #expect(s[1]["package"] == "b")
    }

    @Test func manyContinuationLinesAreLinear() throws {
        let text = "Package: a\nDescription: x\n" + String(repeating: " y\n", count: 1_500_000)
        let start = Date()
        let c = try DebControl.stanzas(text)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(c[0]["description"]!.utf8.count <= ControlLimits.maxFieldBytes + 4)
    }

    @Test func overCapDependsAreRefusedNotTruncated() {
        let many = (0..<600).map { "p\($0)" }.joined(separator: ", ")
        #expect(throws: DebError.tooLarge) { try DebControl.parse("Package: a\nDepends: \(many), firmware (>= 99)\n") }
    }

    @Test func unreadableConstraintsAreNotAnyVersion() throws {
        let c = try DebControl.parse("Package: a\nDepends: firmware (>=15.0 beta), x (~ 1), y (>= 1\n")
        #expect(c.depends.allSatisfy { $0[0].unparseable })
        #expect(!c.depends[0][0].isSatisfied(by: "99"))
        #expect(DebControl.firmwareBounds(c.depends).unparseable)
        #expect(!DebControl.firmwareBounds(c.depends).allows("99"))
    }

    @Test func firmwareBoundsExclusiveAndInclusive() throws {
        let gt = DebControl.firmwareBounds(try DebControl.parse("Package: a\nDepends: firmware (>> 15.0)\n").depends)
        #expect(gt.min == "15.0" && gt.minExclusive)
        #expect(!gt.allows("15.0") && gt.allows("15.0.1") && !gt.allows("14"))
        let le = DebControl.firmwareBounds(try DebControl.parse("Package: a\nDepends: firmware (<= 16.0)\n").depends)
        #expect(le.maxInclusive && le.allows("16.0") && !le.allows("16.1"))
        let lt = DebControl.firmwareBounds(try DebControl.parse("Package: a\nDepends: firmware (<< 16.0)\n").depends)
        #expect(!lt.allows("16.0") && lt.allows("15.9"))
        #expect(DebControl.firmwareRange(try DebControl.parse("Package: a\nDepends: firmware (>> 15.0)\n").depends).min == "15.0")
    }

    @Test func wrongTypedFilterIsNil() throws {
        for obj in [["Filter": "x"], ["Filter": ["Bundles": "com.a"]], ["Filter": ["Classes": ["Foo": 1]]]] as [[String: Any]] {
            let d = try PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0)
            #expect(TweakFilter.parse(d) == nil)
        }
    }

    /// A hand-built binary plist: `depth` nested one-element arrays around a string, ~3 bytes each.
    private func nestedBinaryPlist(depth: Int) -> Data {
        var out = Array("bplist00".utf8)
        var offsets: [Int] = []
        for i in 0..<depth {
            offsets.append(out.count)
            out += [0xA1, UInt8((i + 1) >> 8), UInt8((i + 1) & 0xFF)]
        }
        offsets.append(out.count)
        out += [0x51, 0x61]
        let tableAt = out.count
        for o in offsets { out += [UInt8(o >> 8), UInt8(o & 0xFF)] }
        func be(_ v: Int) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * (7 - $0))) & 0xFF) } }
        out += [0, 0, 0, 0, 0, 0, 2, 2] + be(offsets.count) + be(0) + be(tableAt)
        return Data(out)
    }

    @Test func deepBinaryPlistNestingIsRefusedNotTrapped() throws {
        // Shallow, written by Foundation: parses, non-strings skipped.
        var v: Any = "x"
        for _ in 0..<20 { v = [v] }
        let shallow = try PropertyListSerialization.data(fromPropertyList: ["Filter": ["Bundles": ["a", v]]], format: .binary, options: 0)
        #expect(TweakFilter.parse(shallow)?.bundles == ["a"])
        // Hand-built nested arrays past what Foundation accepts: nil, no crash.
        for depth in [10, 500, 5000, 20_000] { #expect(TweakFilter.parse(nestedBinaryPlist(depth: depth)) == nil) }
        #expect(TweakFilter.parse(Data("bplist00".utf8) + Data(repeating: 0xA1, count: 3000)) == nil)
    }

    @Test func loneCarriageReturnFailsSafe() throws {
        // A bare \r is not a line break; it is stripped, which merges the lines. The merged Package
        // is not a valid id, so the control is refused instead of mis-read.
        #expect(throws: DebError.self) { try DebControl.parse("Package: a\rName: b\n") }
        let c = try DebControl.parse("Package: a\nName: b\rc\n")
        #expect(c.name == "bc")
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
