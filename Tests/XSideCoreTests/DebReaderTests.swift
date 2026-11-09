import Foundation
import Testing
@testable import XSideCore

struct DebReaderTests {
    private let control = "Package: io.github.xside.test\nVersion: 1.0\nArchitecture: iphoneos-arm64\n"
    private let files: [FakeDeb.Entry] = [
        .dir("./Library"), .file("./Library/MobileSubstrate/DynamicLibraries/T.dylib", Data("dylib".utf8)),
        .file("./Library/MobileSubstrate/DynamicLibraries/T.plist", Data("plist".utf8)),
    ]

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("debreader-\(UUID().uuidString)")
    }
    private func write(_ data: Data) throws -> URL {
        let url = scratch().appendingPathExtension("deb")
        try data.write(to: url)
        return url
    }

    @Test(arguments: ["gz", "xz", "bz2", "lzma", "zst", ""])
    func readsEveryCompression(_ compression: String) async throws {
        let deb = try write(try await FakeDeb.deb(control: control, files: files, compression: compression))
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: deb); try? FileManager.default.removeItem(at: root) }
        let result = try await DebReader.read(deb, into: root, runner: ProcessRunner(), keep: { _ in true })
        #expect(result.control.contains("Package: io.github.xside.test"))
        #expect(Set(result.extraction.files) == ["Library/MobileSubstrate/DynamicLibraries/T.dylib",
                                                  "Library/MobileSubstrate/DynamicLibraries/T.plist"])
        #expect(try Data(contentsOf: root.appendingPathComponent("Library/MobileSubstrate/DynamicLibraries/T.dylib")) == Data("dylib".utf8))
    }

    @Test func keepFiltersFiles() async throws {
        let deb = try write(try await FakeDeb.deb(control: control, files: files, compression: "gz"))
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: deb); try? FileManager.default.removeItem(at: root) }
        let result = try await DebReader.read(deb, into: root, runner: ProcessRunner(), keep: { $0.hasSuffix(".plist") })
        #expect(result.extraction.files == ["Library/MobileSubstrate/DynamicLibraries/T.plist"])
    }

    @Test func aDataBombIsStoppedAtTheCap() async throws {
        let bomb = [FakeDeb.Entry.file("./big", Data(count: 4 << 20))]
        for compression in ["gz", "zst"] {
            let deb = try write(try await FakeDeb.deb(control: control, files: bomb, compression: compression))
            let root = scratch()
            defer { try? FileManager.default.removeItem(at: deb); try? FileManager.default.removeItem(at: root) }
            await #expect(throws: DebError.tooLarge) {
                _ = try await DebReader.read(deb, into: root, runner: ProcessRunner(), keep: { _ in true }, maxDataBytes: 1 << 20)
            }
            #expect(!FileManager.default.fileExists(atPath: root.path))
        }
    }

    @Test func controlTarOverOneMegabyteIsRefused() async throws {
        let big = control + String(repeating: "X-Pad: " + String(repeating: "a", count: 900) + "\n", count: 1500)
        let deb = try write(try await FakeDeb.deb(control: big, files: files, compression: "gz"))
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: deb); try? FileManager.default.removeItem(at: root) }
        await #expect(throws: DebError.tooLarge) {
            _ = try await DebReader.read(deb, into: root, runner: ProcessRunner(), keep: { _ in true })
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func aDebOver256MegabytesIsRefusedBeforeReading() async throws {
        let url = scratch().appendingPathExtension("deb")
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(DebLimits.maxDebBytes) + 1)
        try h.close()
        await #expect(throws: DebError.tooLarge) {
            _ = try await DebReader.read(url, into: root, runner: ProcessRunner(), keep: { _ in true })
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func magicWinsOverName() async throws {
        #expect(CompressionKind.sniff(Data([0x1F, 0x8B, 8, 0]), name: "data.tar.xz") == .gzip)
        #expect(CompressionKind.sniff(Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]), name: "data.tar.gz") == .xz)
        #expect(CompressionKind.sniff(Data("BZh9".utf8), name: "x") == .bzip2)
        #expect(CompressionKind.sniff(Data([0x5D, 0, 0, 0x80]), name: "x") == .lzma)
        #expect(CompressionKind.sniff(Data(Zstd.magic), name: "x.gz") == .zstd)
        #expect(CompressionKind.sniff(FakeDeb.tar([.file("a")]), name: "x.gz") == .none)
        #expect(CompressionKind.sniff(Data(), name: "x.xz") == .xz)
        // A whole deb whose member names lie about the compression.
        var data = try await FakeDeb.deb(control: control, files: files, compression: "xz")
        for name in ["control.tar.xz", "data.tar.xz"] {
            let range = data.range(of: Data(name.utf8))!
            data.replaceSubrange(range, with: Data((name.dropLast(2) + "gz").utf8))
        }
        let deb = try write(data)
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: deb); try? FileManager.default.removeItem(at: root) }
        let result = try await DebReader.read(deb, into: root, runner: ProcessRunner(), keep: { _ in true })
        #expect(result.extraction.files.count == 2)
    }

    @Test func aWriteFailureLeavesNothing() async throws {
        let deb = try write(try await FakeDeb.deb(control: control, files: files, compression: "gz"))
        let root = scratch()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)   // writes fail
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: deb); try? FileManager.default.removeItem(at: root)
        }
        await #expect(throws: DebError.self) {
            _ = try await DebReader.read(deb, into: root, runner: ProcessRunner(), keep: { _ in true })
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func createdParentFoldersGoOnFailure() async throws {
        let deb = try write(Data("junk".utf8))
        let top = scratch(), root = top.appendingPathComponent("a/b")
        defer { try? FileManager.default.removeItem(at: deb) }
        await #expect(throws: DebError.self) {
            _ = try await DebReader.read(deb, into: root, runner: ProcessRunner(), keep: { _ in true })
        }
        #expect(!FileManager.default.fileExists(atPath: top.path))
    }

    @Test func aNonEmptyDestinationIsRefusedAndLeftAlone() async throws {
        let deb = try write(try await FakeDeb.deb(control: control, files: files, compression: "gz"))
        let root = scratch()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("mine".utf8).write(to: root.appendingPathComponent("keep.txt"))
        defer { try? FileManager.default.removeItem(at: deb); try? FileManager.default.removeItem(at: root) }
        await #expect(throws: DebError.malformed("destination is not empty")) {
            _ = try await DebReader.read(deb, into: root, runner: ProcessRunner(), keep: { _ in true })
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep.txt").path))
    }

    @Test func garbageIsRefusedAndLeavesNothing() async throws {
        let deb = try write(Data("not a deb at all".utf8))
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: deb) }
        await #expect(throws: DebError.self) {
            _ = try await DebReader.read(deb, into: root, runner: ProcessRunner(), keep: { _ in true })
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    /// An `ar` with valid control and a data member of the given bytes.
    private func debWith(data member: Data, name: String) async throws -> URL {
        let good = try await FakeDeb.deb(control: control, files: files, compression: "none")
        let members = try DebArchive.members(good)
        let ctl = good[members[1].range]
        return try write(FakeDeb.ar([("debian-binary", Data("2.0\n".utf8)), ("control.tar", Data(ctl)), (name, member)]))
    }
    private func gzip(_ data: Data) throws -> Data {
        let src = scratch(), out = scratch()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
        try data.write(to: src)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip"); p.arguments = ["-c"]
        p.standardInput = try FileHandle(forReadingFrom: src)
        FileManager.default.createFile(atPath: out.path, contents: nil)
        p.standardOutput = try FileHandle(forWritingTo: out)
        try p.run(); p.waitUntilExit()
        return try Data(contentsOf: out)
    }

    @Test func anMtreeMemberCannotPullLocalFilesIn() async throws {
        let secret = scratch().appendingPathExtension("txt")
        try Data("SECRET-LOCAL-FILE".utf8).write(to: secret)
        let mtree = Data("#mtree\n./Library/T.dylib type=file contents=\(secret.path)\n".utf8)
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: secret); try? FileManager.default.removeItem(at: root) }
        for (data, name) in [(try gzip(mtree), "data.tar.gz"), (mtree, "data.tar")] {
            let deb = try await debWith(data: data, name: name)
            defer { try? FileManager.default.removeItem(at: deb) }
            await #expect(throws: DebError.self) {
                _ = try await DebReader.read(deb, into: root, runner: ProcessRunner(), keep: { _ in true })
            }
            #expect(!FileManager.default.fileExists(atPath: root.path))
        }
    }

    @Test func otherArchiveFormatsAreNotTars() async throws {
        let cpio = Data("070701".utf8) + Data(repeating: 0x30, count: 200)
        let zip = Data([0x50, 0x4B, 3, 4]) + Data(count: 100)
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        for (data, name) in [(cpio, "data.tar"), (zip, "data.tar"), (try gzip(cpio), "data.tar.gz"), (try gzip(zip), "data.tar.gz")] {
            let deb = try await debWith(data: data, name: name)
            defer { try? FileManager.default.removeItem(at: deb) }
            await #expect(throws: DebError.self) {
                _ = try await DebReader.read(deb, into: root, runner: ProcessRunner(), keep: { _ in true })
            }
            #expect(!FileManager.default.fileExists(atPath: root.path))
        }
    }
}
