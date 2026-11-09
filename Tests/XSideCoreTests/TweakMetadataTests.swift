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

    @Test func deepBinaryPlistNestingDoesNotTrap() {
        for depth in [10, 500, 5000, 20_000] {
            let d = nestedBinaryPlist(depth: depth)
            #expect(d.count <= DebLimits.maxPlistBytes || depth > 5000)
            _ = TweakFilter.parse(d)
        }
        _ = TweakFilter.parse(Data("bplist00".utf8) + Data(repeating: 0xA1, count: 3000))
    }
}
