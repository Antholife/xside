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
}
