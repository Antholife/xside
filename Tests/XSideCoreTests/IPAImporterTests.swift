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
