import Foundation
import Testing
@testable import XSideCore

struct TarReaderTests {
    private func scratch() throws -> (parent: URL, root: URL) {
        let parent = TestTemp.root.appendingPathComponent("tar-\(UUID().uuidString)")
        let root = parent.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (parent, root)
    }
    private func listing(_ url: URL) -> [String] {
        (FileManager.default.subpaths(atPath: url.path) ?? []).sorted()
    }
    private func attrs(_ url: URL) -> [FileAttributeKey: Any] { (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:] }

    @Test func normalizesPaths() {
        #expect(TarPath.normalize("./Library/x") == "Library/x")
        #expect(TarPath.normalize("/var/jb/usr/lib/a.dylib") == "usr/lib/a.dylib")
        #expect(TarPath.normalize("./var/jb/usr/x") == "usr/x")
        #expect(TarPath.normalize("a//./b") == "a/b")
        #expect(TarPath.normalize("var/other/x") == "var/other/x")
        for bad in ["../x", "a/../../x", "a/..", "a\\b", "a\u{0}b", "", ".", "./", "/", "var/jb",
                    String(repeating: "a", count: 256),
                    String(repeating: "a/", count: 33) + "a",
                    String(repeating: "a/", count: 600)] {
            #expect(TarPath.normalize(bad) == nil, "\(bad.prefix(20))")
        }
        #expect(TarPath.normalize(String(repeating: "a", count: 255)) != nil)
    }

    @Test func readsEntriesAndKinds() throws {
        let t = FakeDeb.tar([.dir("d/"), .file("d/f", Data("hello".utf8)), .symlink("l", to: "f"),
                             .hardlink("h", to: "d/f"), .device("dev")])
        let e = try TarReader.entries(t)
        #expect(e.map(\.kind) == [.directory, .file, .symlink, .hardlink, .other])
        #expect(e[1].path == "d/f" && e[1].size == 5)
        #expect(t[e[1].dataRange] == Data("hello".utf8))
    }

    @Test func rejectsTheWholeArchiveOnTraversal() throws {
        let (parent, root) = try scratch(); defer { try? FileManager.default.removeItem(at: parent) }
        let t = FakeDeb.tar([.file("ok.txt"), .file("../escape.txt")])
        #expect(throws: DebError.self) { try TarReader.extract(t, to: root) }
        #expect(listing(root).isEmpty)
        #expect(listing(parent) == ["root"])
        let abs = FakeDeb.tar([.file("a/b"), .file("x/../../y")])
        #expect(throws: DebError.self) { try TarReader.extract(abs, to: root) }
        #expect(listing(root).isEmpty)
        // also when the unsafe entry is a link or a device
        #expect(throws: DebError.self) { try TarReader.extract(FakeDeb.tar([.symlink("../up", to: "x")]), to: root) }
    }

    @Test func skipsSymlinksHardlinksAndDevices() throws {
        let (parent, root) = try scratch(); defer { try? FileManager.default.removeItem(at: parent) }
        let outside = parent.appendingPathComponent("target"); try Data("secret".utf8).write(to: outside)
        let t = FakeDeb.tar([.symlink("lib", to: "../target"), .hardlink("hard", to: "lib"), .device("dev"),
                             .file("lib", Data("mine".utf8)), .file("sub/ok", Data("ok".utf8))])
        let r = try TarReader.extract(t, to: root)
        #expect(r.skippedLinks == 2 && r.skippedOther == 1)
        #expect(r.files.sorted() == ["lib", "sub/ok"])
        #expect(attrs(root.appendingPathComponent("lib"))[.type] as? FileAttributeType == .typeRegular)
        #expect(try Data(contentsOf: root.appendingPathComponent("lib")) == Data("mine".utf8))
        #expect(try Data(contentsOf: outside) == Data("secret".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("hard").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("dev").path))
    }

    @Test func doesNotFollowASymlinkAlreadyInRoot() throws {
        let (parent, root) = try scratch(); defer { try? FileManager.default.removeItem(at: parent) }
        let outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("d"), withDestinationURL: outside)
        #expect(throws: DebError.self) { try TarReader.extract(FakeDeb.tar([.file("d/x")]), to: root) }
        #expect(listing(outside).isEmpty)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("f"), withDestinationURL: outside.appendingPathComponent("new"))
        #expect(throws: DebError.self) { try TarReader.extract(FakeDeb.tar([.file("f")]), to: root) }
        #expect(listing(outside).isEmpty)
    }

    @Test func rejectsDuplicatePathsAndCaseCollisions() throws {
        let (parent, root) = try scratch(); defer { try? FileManager.default.removeItem(at: parent) }
        for entries in [[FakeDeb.Entry.file("A/x"), .file("a/x")], [.file("x"), .file("x")], [.file("a"), .file("./a")],
                        [.file("Dir/f"), .dir("dir")]] {
            #expect(throws: DebError.self) { try TarReader.extract(FakeDeb.tar(entries), to: root) }
            #expect(listing(root).isEmpty)
        }
        // a repeated directory entry is harmless
        _ = try TarReader.extract(FakeDeb.tar([.dir("d"), .dir("./d/"), .file("d/f")]), to: root)
    }

    @Test func rejectsFileThenDirectoryAtTheSamePath() throws {
        let (parent, root) = try scratch(); defer { try? FileManager.default.removeItem(at: parent) }
        for entries in [[FakeDeb.Entry.file("a"), .dir("a")], [.dir("a"), .file("a")], [.file("a"), .file("a/b")]] {
            #expect(throws: DebError.self) { try TarReader.extract(FakeDeb.tar(entries), to: root) }
            #expect(listing(root).isEmpty)
        }
    }

    @Test func honoursPaxPathAndSize() throws {
        let long = String(repeating: "dir/", count: 40) + "file.txt"      // > 100 bytes
        var e = FakeDeb.Entry.file(long, Data("pax!".utf8)); e.paxPath = true; e.paxSize = true
        let t = FakeDeb.tar([e, .file("after", Data("z".utf8))])
        let entries = try TarReader.entries(t)
        #expect(entries.map(\.path) == [long, "after"])
        #expect(entries[0].size == 4 && t[entries[0].dataRange] == Data("pax!".utf8))
    }

    @Test func ignoresPaxGlobalHeaders() throws {
        var t = FakeDeb.tar([.file("a")])
        var g = Data(count: 512)
        let tmp = FakeDeb.tar([.file("g", Data())])
        g = Data(tmp.prefix(512))
        // flip it into a 'g' header carrying no records, and fix the checksum
        var bytes = [UInt8](g); bytes[156] = UInt8(ascii: "g")
        for i in 148..<156 { bytes[i] = 0x20 }
        let sum = bytes.reduce(0) { $0 + Int($1) }
        let s = String(sum, radix: 8); let field = String(repeating: "0", count: 6 - s.count) + s
        for (i, c) in field.utf8.enumerated() { bytes[148 + i] = c }
        bytes[154] = 0; bytes[155] = 0x20
        t = Data(bytes) + t
        #expect(try TarReader.entries(t).map(\.path) == ["a"])
    }

    @Test func badChecksumThrows() {
        var t = FakeDeb.tar([.file("a")]); t[0] ^= 0x01
        #expect(throws: DebError.self) { try TarReader.entries(t) }
    }

    @Test func sizePastEndThrows() {
        var e = FakeDeb.Entry.file("a", Data("hi".utf8)); e.declaredSize = 100_000
        #expect(throws: DebError.self) { try TarReader.entries(FakeDeb.tar([e])) }
        #expect(throws: DebError.self) { try TarReader.entries(Data(FakeDeb.tar([.file("a", Data(count: 2000))]).prefix(700))) }
    }

    @Test func moreThanMaxEntriesThrows() throws {
        let t = FakeDeb.tar((0..<4).map { .file("f\($0)") })
        #expect(throws: DebError.self) { try TarReader.entries(t, maxEntries: 3) }
        #expect(try TarReader.entries(t, maxEntries: 4).count == 4)
    }

    @Test func fileOverMaxFileBytesThrows() {
        var e = FakeDeb.Entry.file("a"); e.declaredSize = DebLimits.maxFileBytes + 1
        #expect(throws: DebError.tooLarge) { try TarReader.entries(FakeDeb.tar([e])) }
        var huge = FakeDeb.Entry.file("a"); huge.declaredSize = 0o77777777777
        #expect(throws: DebError.self) { try TarReader.entries(FakeDeb.tar([huge])) }
    }

    @Test func hostileSizeFieldsNeverTrap() {
        // all-0xFF size field (base-256 / garbage), non-octal digits, and random headers
        var t = FakeDeb.tar([.file("a")])
        for i in 124..<136 { t[i] = 0xFF }
        #expect(throws: DebError.self) { try TarReader.entries(t) }
        var g = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let junk = Data((0..<1536).map { _ in UInt8.random(in: 0...255, using: &g) })
            _ = try? TarReader.entries(junk)
        }
    }

    @Test func keepFilterLeavesOtherFilesUnwritten() throws {
        let (parent, root) = try scratch(); defer { try? FileManager.default.removeItem(at: parent) }
        let t = FakeDeb.tar([.file("keep/a.dylib"), .file("skip/b"), .dir("skip2")])
        let r = try TarReader.extract(t, to: root, keep: { $0.hasPrefix("keep/") })
        #expect(r.files == ["keep/a.dylib"])
        #expect(listing(root) == ["keep", "keep/a.dylib"])
    }

    @Test func permissionsFollowTheMachOMagic() throws {
        let (parent, root) = try scratch(); defer { try? FileManager.default.removeItem(at: parent) }
        let macho = Data([0xCF, 0xFA, 0xED, 0xFE]) + Data(count: 8)
        let r = try TarReader.extract(FakeDeb.tar([.file("bin/tool", macho), .file("share/x.txt")]), to: root)
        #expect(r.directories.sorted() == ["bin", "share"])
        #expect((attrs(root.appendingPathComponent("bin/tool"))[.posixPermissions] as? Int) == 0o755)
        #expect((attrs(root.appendingPathComponent("share/x.txt"))[.posixPermissions] as? Int) == 0o644)
    }

    @Test func stripsVarJbAndSkipsTheRootEntry() throws {
        let (parent, root) = try scratch(); defer { try? FileManager.default.removeItem(at: parent) }
        let r = try TarReader.extract(FakeDeb.tar([.dir("./"), .dir("./var/jb/"), .file("./var/jb/usr/lib/a.dylib")]), to: root)
        #expect(r.files == ["usr/lib/a.dylib"])
        #expect(listing(root) == ["usr", "usr/lib", "usr/lib/a.dylib"])
    }

    @Test func extractionIsBoundedInTotal() throws {
        let (parent, root) = try scratch(); defer { try? FileManager.default.removeItem(at: parent) }
        var e = FakeDeb.Entry.file("a"); e.declaredSize = DebLimits.maxFileBytes + 1
        #expect(throws: DebError.self) { try TarReader.extract(FakeDeb.tar([e]), to: root) }
        #expect(listing(root).isEmpty)
    }
}
