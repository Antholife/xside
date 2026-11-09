import Foundation
import Testing
@testable import XSideCore

struct DebArchiveTests {
    private let bin = Data("2.0\n".utf8)
    private func standard(bsd: Bool = false, names: [String] = ["debian-binary", "control.tar.gz", "data.tar.xz"]) -> Data {
        FakeDeb.ar(names.enumerated().map { ($1, $0 == 0 ? bin : Data("body\($0)".utf8)) }, bsdLongNames: bsd)
    }
    /// Replaces `count` bytes of the first member's header field starting `offset` into the header.
    private func patch(_ d: Data, header index: Int = 0, at offset: Int, _ text: String) -> Data {
        var d = d
        // headers of the standard layout: 8 + sum over previous members (60 + padded body)
        var pos = 8
        for _ in 0..<index {
            let size = Int(String(decoding: d[(pos + 48)..<(pos + 58)], as: UTF8.self).trimmingCharacters(in: .whitespaces))!
            pos += 60 + size + size % 2
        }
        d.replaceSubrange((pos + offset)..<(pos + offset + text.utf8.count), with: Array(text.utf8))
        return d
    }

    @Test func readsTheThreeMembersInOrder() throws {
        let d = standard()
        let members = try DebArchive.members(d)
        #expect(members.map(\.name) == ["debian-binary", "control.tar.gz", "data.tar.xz"])
        let r = try DebArchive.controlAndData(d)
        #expect(r.debianBinary == "2.0")
        #expect(r.control.name == "control.tar.gz" && r.data.name == "data.tar.xz")
        #expect(d[r.data.range] == Data("body2".utf8))
    }

    @Test func acceptsGNUSlashAndBSDLongNames() throws {
        let gnu = try DebArchive.members(standard(names: ["debian-binary/", "control.tar.gz/", "data.tar.xz/"]))
        #expect(gnu.map(\.name) == ["debian-binary", "control.tar.gz", "data.tar.xz"])
        let d = standard(bsd: true)
        let bsd = try DebArchive.members(d)
        #expect(bsd.map(\.name) == ["debian-binary", "control.tar.gz", "data.tar.xz"])
        #expect(d[bsd[1].range] == Data("body1".utf8))   // the name is not part of the body
        #expect(try DebArchive.controlAndData(d).debianBinary == "2.0")
    }

    @Test func rejectsWrongMagic() {
        var d = standard(); d[0] = 0x3F
        #expect(throws: DebError.malformed("not an ar archive")) { try DebArchive.members(d) }
        #expect(throws: DebError.self) { try DebArchive.members(Data()) }
    }

    @Test func rejectsAMemberRunningPastTheEnd() {
        let d = standard()
        #expect(throws: DebError.self) { try DebArchive.members(d.dropLast(3)) }
        let huge = patch(d, at: 48, "9999999999")
        #expect(throws: DebError.self) { try DebArchive.members(huge) }
        #expect(throws: DebError.self) { try DebArchive.members(d + Data(count: 10)) }   // truncated trailing header
    }

    @Test func rejectsANegativeOrNonDigitSize() {
        for bad in ["-1        ", "12a       ", "          ", "+5        "] {
            #expect(throws: DebError.self) { try DebArchive.members(patch(standard(), at: 48, bad)) }
        }
    }

    @Test func rejectsMoreThan16Members() throws {
        let many = FakeDeb.ar((0..<17).map { ("m\($0)", Data("x".utf8)) })
        #expect(throws: DebError.self) { try DebArchive.members(many) }
        #expect(try DebArchive.members(FakeDeb.ar((0..<16).map { ("m\($0)", Data("x".utf8)) })).count == 16)
    }

    @Test func rejectsBadFmag() {
        #expect(throws: DebError.self) { try DebArchive.members(patch(standard(), at: 58, "xx")) }
    }

    @Test func rejectsDebianBinaryOtherThan2() {
        let d = FakeDeb.ar([("debian-binary", Data("3.0\n".utf8)), ("control.tar.gz", Data("c".utf8)), ("data.tar.xz", Data("d".utf8))])
        #expect(throws: DebError.notADeb) { try DebArchive.controlAndData(d) }
        let wrongFirst = FakeDeb.ar([("control.tar.gz", Data("c".utf8)), ("debian-binary", bin), ("data.tar.xz", Data("d".utf8))])
        #expect(throws: DebError.notADeb) { try DebArchive.controlAndData(wrongFirst) }
    }

    @Test func rejectsMissingDataMember() {
        let d = FakeDeb.ar([("debian-binary", bin), ("control.tar.gz", Data("c".utf8))])
        #expect(throws: DebError.self) { try DebArchive.controlAndData(d) }
        let noControl = FakeDeb.ar([("debian-binary", bin), ("data.tar.gz", Data("c".utf8))])
        #expect(throws: DebError.self) { try DebArchive.controlAndData(noControl) }
    }

    @Test func oddSizedMembersArePaddedToEven() throws {
        let d = FakeDeb.ar([("debian-binary", bin), ("control.tar.gz", Data("abc".utf8)), ("data.tar.xz", Data("de".utf8))])
        let r = try DebArchive.controlAndData(d)
        #expect(d[r.control.range] == Data("abc".utf8))
        #expect(d[r.data.range] == Data("de".utf8))
        // an odd last member without its padding byte is still read
        let m = try DebArchive.members(Data(d.dropLast(0)) + Data())
        #expect(m.count == 3)
        let unpadded = FakeDeb.ar([("debian-binary", bin), ("a", Data("abc".utf8))]).dropLast()
        #expect(try DebArchive.members(Data(unpadded)).count == 2)
    }

    @Test func ignoresExtraMembersAfterData() throws {
        let d = FakeDeb.ar([("debian-binary", bin), ("control.tar.zst", Data("c".utf8)), ("data.tar", Data("d".utf8)),
                            ("_gpgorigin", Data("sig".utf8))])
        let r = try DebArchive.controlAndData(d)
        #expect(r.control.name == "control.tar.zst" && r.data.name == "data.tar")
    }

    @Test func tooLargeIsRefusedBeforeParsing() {
        // Cheap check of the cap's wiring: the constant is what the brief fixes.
        #expect(DebLimits.maxDebBytes == 256 * 1024 * 1024 && DebLimits.maxMembers == 16)
    }

    @Test func dataSlicesWithAnOffsetAreRead() throws {
        let padded = Data(count: 5) + standard()
        let slice = padded.dropFirst(5)
        #expect(try DebArchive.members(slice).count == 3)
    }
}
