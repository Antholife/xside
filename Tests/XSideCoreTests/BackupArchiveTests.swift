import Foundation
import Testing
@testable import XSideCore

@Suite struct BackupArchiveTests {
    static let manifest = BackupManifest(
        schema: 1, originalBundleID: "com.example.app", signedBundleID: "com.example.app.ABC",
        teamID: "TEAM123456", deviceID: "DEV-1", deviceName: "iPhone",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), includedCaches: false,
        appVersion: "1.2.3", xsideVersion: "1.0.4")

    private func makeTree(_ dir: URL) throws -> URL {
        let tree = dir.appendingPathComponent("tree", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: tree.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: tree.appendingPathComponent("Documents/a.txt"))
        try Data("two".utf8).write(to: tree.appendingPathComponent("b.txt"))
        return tree
    }

    @Test func packTree_thenUnpackTree_roundTrips() async throws {
        try await withTemporaryDirectory("archive") { dir in
            let src = dir.appendingPathComponent("src", isDirectory: true)
            let fm = FileManager.default
            try fm.createDirectory(at: src.appendingPathComponent("apps/APP1/tweaks/pkg"), withIntermediateDirectories: true)
            try Data("ipa-bytes".utf8).write(to: src.appendingPathComponent("apps/APP1/original.ipa"))
            try Data("deb".utf8).write(to: src.appendingPathComponent("apps/APP1/tweaks/pkg/x.deb"))
            try Data("{\"v\":1}".utf8).write(to: src.appendingPathComponent("manifest.json"))

            let zip = dir.appendingPathComponent("full.xsbak")
            try BackupArchive.packTree(src, to: zip)
            let out = try BackupArchive.unpackTree(zip, to: dir.appendingPathComponent("dest", isDirectory: true))

            #expect(try Data(contentsOf: out.appendingPathComponent("manifest.json")) == Data("{\"v\":1}".utf8))
            #expect(try Data(contentsOf: out.appendingPathComponent("apps/APP1/original.ipa")) == Data("ipa-bytes".utf8))
            #expect(try Data(contentsOf: out.appendingPathComponent("apps/APP1/tweaks/pkg/x.deb")) == Data("deb".utf8))
        }
    }

    @Test func unpackTree_rejectsSymlinkArchive() async throws {
        try await withTemporaryDirectory("archive") { dir in
            let src = dir.appendingPathComponent("src", isDirectory: true)
            let fm = FileManager.default
            try fm.createDirectory(at: src, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: src.appendingPathComponent("real.txt"))
            try fm.createSymbolicLink(at: src.appendingPathComponent("link"),
                                      withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
            let zip = dir.appendingPathComponent("evil.zip")
            // Use the system zip preserving the symlink entry (-y), to prove unpackTree rejects it.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.arguments = ["-q", "-r", "-y", "-X", zip.path, "--", "."]
            p.currentDirectoryURL = src
            try p.run(); p.waitUntilExit()
            #expect(throws: BackupArchiveError.unsafeArchive) {
                _ = try BackupArchive.unpackTree(zip, to: dir.appendingPathComponent("dest", isDirectory: true))
            }
        }
    }

    @Test func export_thenReadManifest_roundTrips() async throws {
        try await withTemporaryDirectory("archive") { dir in
            let tree = try makeTree(dir)
            let zip = dir.appendingPathComponent("out.zip")
            try BackupArchive.export(snapshotDir: tree, manifest: Self.manifest, to: zip)
            #expect(try BackupArchive.readManifest(zipURL: zip) == Self.manifest)
        }
    }

    @Test func unpack_restoresTreeAndManifest() async throws {
        try await withTemporaryDirectory("archive") { dir in
            let tree = try makeTree(dir)
            let zip = dir.appendingPathComponent("out.zip")
            try BackupArchive.export(snapshotDir: tree, manifest: Self.manifest, to: zip)
            let dest = dir.appendingPathComponent("dest", isDirectory: true)
            let result = try BackupArchive.unpack(zipURL: zip, to: dest)
            #expect(result.manifest == Self.manifest)
            #expect(try String(contentsOf: result.contentDir.appendingPathComponent("Documents/a.txt"), encoding: .utf8) == "one")
            #expect(try String(contentsOf: result.contentDir.appendingPathComponent("b.txt"), encoding: .utf8) == "two")
        }
    }

    @Test func readManifest_nilWhenMissing() async throws {
        try await withTemporaryDirectory("archive") { dir in
            let tree = try makeTree(dir)
            let zip = dir.appendingPathComponent("bare.zip")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.arguments = ["-q", "-r", "-X", zip.path, "."]
            p.currentDirectoryURL = tree
            try p.run(); p.waitUntilExit()
            #expect(try BackupArchive.readManifest(zipURL: zip) == nil)
            let dest = dir.appendingPathComponent("dest", isDirectory: true)
            let result = try BackupArchive.unpack(zipURL: zip, to: dest)
            #expect(result.manifest == nil)
            #expect(FileManager.default.fileExists(atPath: result.contentDir.appendingPathComponent("b.txt").path))
        }
    }

    private func zipTree(_ tree: URL, to zip: URL, flags: [String] = []) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-q", "-r", "-X"] + flags + [zip.path, "--", "."]
        p.currentDirectoryURL = tree
        try p.run(); p.waitUntilExit()
    }

    @Test func unpack_rejectsArchiveWithSymlinkEntry() async throws {
        try await withTemporaryDirectory("archive") { dir in
            let outside = dir.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let tree = dir.appendingPathComponent("evil", isDirectory: true)
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("link").path,
                                                       withDestinationPath: outside.path)
            let zip = dir.appendingPathComponent("evil.zip")
            try zipTree(tree, to: zip, flags: ["-y"])
            let dest = dir.appendingPathComponent("dest", isDirectory: true)
            #expect(throws: BackupArchiveError.unsafeArchive) { try BackupArchive.unpack(zipURL: zip, to: dest) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
            let left = (try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? []
            #expect(left.isEmpty)
        }
    }

    @Test func unpack_rejectsDotDotEntry() async throws {
        try await withTemporaryDirectory("archive") { dir in
            let py = dir.appendingPathComponent("mk.py")
            let zip = dir.appendingPathComponent("dd.zip")
            try Data("import zipfile,sys\nz=zipfile.ZipFile(sys.argv[1],'w')\nz.writestr('../escaped.txt','x')\nz.close()\n".utf8).write(to: py)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [py.path, zip.path]
            try p.run(); p.waitUntilExit()
            guard FileManager.default.fileExists(atPath: zip.path) else { return }
            let dest = dir.appendingPathComponent("dest", isDirectory: true)
            #expect(throws: BackupArchiveError.unsafeArchive) { try BackupArchive.unpack(zipURL: zip, to: dest) }
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("escaped.txt").path))
        }
    }

    @Test func readManifest_nilOnInvalidJSON() async throws {
        try await withTemporaryDirectory("archive") { dir in
            let tree = try makeTree(dir)
            try Data("not json".utf8).write(to: tree.appendingPathComponent("xside-backup.json"))
            let zip = dir.appendingPathComponent("bad.zip")
            try zipTree(tree, to: zip)
            #expect(try BackupArchive.readManifest(zipURL: zip) == nil)
        }
    }

    @Test func export_dropsSymlinksSoArchiveIsSymlinkFree() async throws {
        try await withTemporaryDirectory("archive") { dir in
            let tree = try makeTree(dir)
            let fm = FileManager.default
            try fm.createSymbolicLink(atPath: tree.appendingPathComponent("a").path, withDestinationPath: ".")
            try fm.createSymbolicLink(atPath: tree.appendingPathComponent("link").path, withDestinationPath: "b.txt")
            let zip = dir.appendingPathComponent("out.zip")
            try BackupArchive.export(snapshotDir: tree, manifest: Self.manifest, to: zip)
            let dest = dir.appendingPathComponent("dest", isDirectory: true)
            let result = try BackupArchive.unpack(zipURL: zip, to: dest)
            #expect(fm.fileExists(atPath: result.contentDir.appendingPathComponent("b.txt").path))
            #expect(fm.fileExists(atPath: result.contentDir.appendingPathComponent("Documents/a.txt").path))
            #expect((try? fm.destinationOfSymbolicLink(atPath: result.contentDir.appendingPathComponent("a").path)) == nil)
            #expect(!fm.fileExists(atPath: result.contentDir.appendingPathComponent("a").path))
            #expect(!fm.fileExists(atPath: result.contentDir.appendingPathComponent("link").path))
        }
    }
}
