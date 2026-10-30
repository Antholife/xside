import Testing
import Foundation
@testable import XSideCore

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// Zips `<root>/Payload` into a real `.ipa` with ditto.
private func zipIPA(_ root: URL) async throws -> URL {
    let ipa = root.appendingPathComponent("Test.ipa")
    let r = try await ProcessRunner().run("/usr/bin/ditto",
        ["-c", "-k", "--keepParent", root.appendingPathComponent("Payload").path, ipa.path], cwd: nil)
    #expect(r.status == 0)
    return ipa
}

/// Rewrites the Unix mode of every folder entry in `ipa`'s central directory, as some tools write
/// them (`rw-r--r--`: no search bit). Returns how many entries were changed.
private func setFolderModes(_ ipa: URL, _ mode: UInt32) throws -> Int {
    var data = try Data(contentsOf: ipa)
    func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
    var changed = 0, pos = 0
    while let start = data[pos...].firstRange(of: Data([0x50, 0x4B, 0x01, 0x02]))?.lowerBound {
        let nameLength = u16(start + 28)
        let name = String(decoding: data[(start + 46)..<(start + 46 + nameLength)], as: UTF8.self)
        if name.hasSuffix("/") {
            data[start + 5] = 3 // made by Unix: the high 16 bits of the external attributes are the mode
            let attributes = (UInt32(0o040000) | mode) << 16 | 0x10
            for i in 0..<4 { data[start + 38 + i] = UInt8((attributes >> (8 * UInt32(i))) & 0xFF) }
            changed += 1
        }
        pos = start + 46
    }
    try data.write(to: ipa)
    return changed
}

/// Leaves `count` stray bytes between the last entry and the central directory, as tools that
/// patch an app in place do: `ditto` then stops ("Couldn't read pkzip signature").
private func insertGapBeforeCentralDirectory(_ ipa: URL, count: Int) throws {
    var data = try Data(contentsOf: ipa)
    guard let eocd = data.lastRange(of: Data([0x50, 0x4B, 0x05, 0x06]))?.lowerBound else { return }
    let offsetField = eocd + 16
    let offset = (0..<4).reduce(0) { $0 | Int(data[offsetField + $1]) << (8 * $1) }
    data.insert(contentsOf: Data(repeating: 0xAB, count: count), at: offset)
    let moved = offset + count
    for i in 0..<4 { data[offsetField + count + i] = UInt8((moved >> (8 * i)) & 0xFF) }
    try data.write(to: ipa)
}

private func isEmpty(_ dir: URL) -> Bool {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty
}

struct IPAImporterTests {
    @Test func readsInfoAndCleansUp() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try tempDir(); defer { try? FileManager.default.removeItem(at: scratch) }
        try FakeIPA.makeApp(at: root, bundleID: "com.example.demo",
                            plistExtras: ["CFBundleName": "Démo", "CFBundleShortVersionString": "2.0"])
        let ipa = try await zipIPA(root)

        let info = try await IPAImporter.inspect(ipa: ipa, runner: ProcessRunner(), scratchRoot: scratch)
        #expect(info == AppInfo(bundleID: "com.example.demo", name: "Démo", version: "2.0", executable: "Demo"))
        #expect(isEmpty(scratch))
    }

    /// Some tools write folders without the search bit: ditto reproduces it, and the archive was
    /// refused as unreadable (issue #1).
    @Test func acceptsFoldersWithoutSearchPermission() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try tempDir(); defer { try? FileManager.default.removeItem(at: scratch) }
        try FakeIPA.makeApp(at: root, bundleID: "com.example.demo")
        let ipa = try await zipIPA(root)
        #expect(try setFolderModes(ipa, 0o644) >= 2)

        let info = try await IPAImporter.inspect(ipa: ipa, runner: ProcessRunner(), scratchRoot: scratch)
        #expect(info.bundleID == "com.example.demo")
        #expect(isEmpty(scratch))
    }

    /// Stray bytes between entries: ditto gives up, unzip (central directory) reads it (issue #1).
    @Test func readsAnArchiveDittoCantStream() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try tempDir(); defer { try? FileManager.default.removeItem(at: scratch) }
        try FakeIPA.makeApp(at: root, bundleID: "com.example.demo")
        let ipa = try await zipIPA(root)
        try insertGapBeforeCentralDirectory(ipa, count: 3_000)
        let probe = try tempDir(); defer { try? FileManager.default.removeItem(at: probe) }
        let ditto = try await ProcessRunner().run("/usr/bin/ditto", ["-x", "-k", ipa.path, probe.path], cwd: nil)
        #expect(ditto.status != 0)

        let info = try await IPAImporter.inspect(ipa: ipa, runner: ProcessRunner(), scratchRoot: scratch)
        #expect(info.bundleID == "com.example.demo")
        #expect(isEmpty(scratch))
    }

    @Test func rejectsEncryptedAtImport() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try tempDir(); defer { try? FileManager.default.removeItem(at: scratch) }
        try FakeIPA.makeApp(at: root, encrypted: true)
        let ipa = try await zipIPA(root)

        await #expect(throws: XSideError.encryptedIPA) {
            _ = try await IPAImporter.inspect(ipa: ipa, runner: ProcessRunner(), scratchRoot: scratch)
        }
        #expect(isEmpty(scratch))
    }

    @Test func rejectsNonZip() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let ipa = root.appendingPathComponent("Broken.ipa")
        try Data("not a zip".utf8).write(to: ipa)

        do {
            _ = try await IPAImporter.inspect(ipa: ipa, runner: ProcessRunner(), scratchRoot: root)
            Issue.record("expected invalidIPA")
        } catch let error as XSideError {
            #expect(error.key == "invalidIPA")
        }
    }

    @Test func rejectsSymlinkedExecutable() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try FakeIPA.makeApp(at: root)
        let exe = app.appendingPathComponent("Demo")
        try FileManager.default.removeItem(at: exe)
        try FileManager.default.createSymbolicLink(atPath: exe.path, withDestinationPath: "/bin/ls")
        let ipa = try await zipIPA(root)

        do {
            _ = try await IPAImporter.inspect(ipa: ipa, runner: ProcessRunner(), scratchRoot: root)
            Issue.record("expected invalidIPA")
        } catch let error as XSideError {
            #expect(error.key == "invalidIPA")
        }
    }
}
