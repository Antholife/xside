import Testing
import Foundation
@testable import XSideCore

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func makeIPA(in dir: URL, _ content: String = "ipa") throws -> URL {
    let u = dir.appendingPathComponent("src-\(UUID().uuidString).ipa")
    try Data(content.utf8).write(to: u)
    return u
}

private let info = AppInfo(bundleID: "com.example.demo", name: "Demo", version: "1.0", executable: "Demo")
private func inst(_ device: String, _ days: Double = 7) -> Installation {
    Installation(deviceID: device, installedAt: Date(timeIntervalSince1970: 1_000_000),
                 expiresAt: Date(timeIntervalSince1970: 1_000_000 + days * 86400), lastAttempt: nil, lastErrorKey: nil)
}

struct LibraryTests {
    @Test func persistsAcrossInstances() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("lib")
        let lib = AppLibrary(root: root)
        let rec = try await lib.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456")
        try await lib.upsert(inst("dev1"), for: rec.id)
        let expected = await lib.records()
        let again = AppLibrary(root: root)
        #expect(await again.records() == expected)
        #expect(expected.first?.installations == [inst("dev1")])
    }

    @Test func signedBundleIDUsesTeam() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = AppLibrary(root: tmp.appendingPathComponent("lib"))
        let src = try makeIPA(in: tmp)
        let rec = try await lib.importIPA(src, info: info, teamID: "TEAM123456")
        #expect(rec.signedBundleID == "com.example.demo.TEAM123456")
        #expect(rec.ipaPath == "apps/\(rec.id.uuidString)/original.ipa")
        #expect(FileManager.default.fileExists(atPath: src.path))
    }

    @Test func optionsPersist() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("lib")
        let lib = AppLibrary(root: root)
        let rec = try await lib.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456")
        let icon = tmp.appendingPathComponent("pick.png"); try Data("png".utf8).write(to: icon)
        try await lib.setOptions(InstallOptions(customBundleID: "com.custom.id", iconPath: icon.path, fileSharing: true), for: rec.id)
        var r = try #require(await lib.records().first)
        #expect(r.signedBundleID == "com.custom.id")
        #expect(r.options.iconPath == "apps/\(rec.id.uuidString)/icon.png")
        #expect(r.options.fileSharing)
        #expect(try Data(contentsOf: root.appendingPathComponent(r.options.iconPath!)) == Data("png".utf8))
        // Relative path kept.
        try await lib.setOptions(r.options, for: rec.id)
        #expect(try #require(await lib.records().first).options.iconPath == r.options.iconPath)
        // Empty custom id falls back; nil icon removes file.
        try await lib.setOptions(InstallOptions(customBundleID: ""), for: rec.id)
        r = try #require(await lib.records().first)
        #expect(r.signedBundleID == "com.example.demo.TEAM123456")
        #expect(r.options.iconPath == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/\(rec.id.uuidString)/icon.png").path))
        await #expect(throws: XSideError.recordNotFound) { try await lib.setOptions(InstallOptions(), for: UUID()) }
    }

    @Test func reimportReusesRecord() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("lib")
        let lib = AppLibrary(root: root)
        let first = try await lib.importIPA(try makeIPA(in: tmp, "one"), info: info, teamID: "TEAM123456")
        try await lib.setOptions(InstallOptions(customBundleID: "com.custom.id"), for: first.id)
        try await lib.upsert(inst("dev1"), for: first.id)
        let renamed = AppInfo(bundleID: info.bundleID, name: "Demo 2", version: "2.0", executable: "Demo")
        let second = try await lib.importIPA(try makeIPA(in: tmp, "two"), info: renamed, teamID: "OTHERTEAM1")
        #expect(second.id == first.id)
        #expect(second.signedBundleID == "com.custom.id")
        #expect(second.installations == [inst("dev1")])
        #expect(second.options.customBundleID == "com.custom.id")
        #expect(second.displayName == "Demo 2")
        #expect(try String(contentsOf: root.appendingPathComponent(second.ipaPath), encoding: .utf8) == "two")
        #expect(await lib.records().count == 1)
    }

    @Test func upsertReplacesAndRemoveDeletes() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("lib")
        let lib = AppLibrary(root: root)
        let rec = try await lib.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456")
        try await lib.upsert(inst("a", 7), for: rec.id)
        try await lib.upsert(inst("b"), for: rec.id)
        try await lib.upsert(inst("a", 3), for: rec.id)
        let got = try #require(await lib.records().first).installations
        #expect(got == [inst("a", 3), inst("b")])
        await #expect(throws: XSideError.recordNotFound) { try await lib.upsert(inst("a"), for: UUID()) }
        try await lib.remove(rec.id)
        #expect(await lib.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/\(rec.id.uuidString)").path))
    }

    @Test func recordsSortedByName() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = AppLibrary(root: tmp.appendingPathComponent("lib"))
        for (id, n) in [("a.b", "zeta"), ("c.d", "Alpha"), ("e.f", "beta")] {
            _ = try await lib.importIPA(try makeIPA(in: tmp), info: AppInfo(bundleID: id, name: n, version: nil, executable: "x"), teamID: "T")
        }
        #expect(await lib.records().map(\.displayName) == ["Alpha", "beta", "zeta"])
    }

    @Test func atomicWrite() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("lib")
        let lib = AppLibrary(root: root)
        _ = try await lib.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(names == ["apps", "state.json"])  // no temp leftovers

        try Data("{ not json".utf8).write(to: root.appendingPathComponent("state.json"))
        try Data("old".utf8).write(to: root.appendingPathComponent("state.json.corrupt"))
        let fresh = AppLibrary(root: root)
        #expect(await fresh.records().isEmpty)
        #expect(try String(contentsOf: root.appendingPathComponent("state.json.corrupt"), encoding: .utf8) == "{ not json")
        _ = try await fresh.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456")
        #expect(await AppLibrary(root: root).records().count == 1)
    }

    @Test func recordsFirstSuccessfulUsePerSignedID() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("lib")
        let lib = AppLibrary(root: root)
        let rec = try await lib.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456")
        let t0 = Date(timeIntervalSince1970: 2_000_000), t1 = t0.addingTimeInterval(86_400)
        let t2 = t1.addingTimeInterval(86_400)
        func ok(_ at: Date) -> Installation { Installation(deviceID: "dev1", installedAt: at, expiresAt: at) }

        try await lib.upsert(ok(t0), for: rec.id)
        try await lib.upsert(ok(t1), for: rec.id) // a refresh doesn't move the first use
        var failed = ok(t0); failed.lastErrorKey = "deviceUnavailable"; failed.lastAttempt = t2
        try await lib.upsert(failed, for: rec.id)
        #expect(await lib.records().first?.appIDFirstUse == ["com.example.demo.TEAM123456": t0])

        // A new signed id is a new App ID: tracked from its own first successful install.
        try await lib.setOptions(InstallOptions(customBundleID: "com.custom.demo"), for: rec.id)
        var failedNew = ok(t1); failedNew.lastErrorKey = "provisioningFailed"
        try await lib.upsert(failedNew, for: rec.id)
        #expect(await lib.records().first?.appIDFirstUse?["com.custom.demo"] == nil)
        try await lib.upsert(ok(t2), for: rec.id)
        let expected: [String: Date] = ["com.example.demo.TEAM123456": t0, "com.custom.demo": t2]
        #expect(await lib.records().first?.appIDFirstUse == expected)
        #expect(await AppLibrary(root: root).records().first?.appIDFirstUse == expected)
    }

    @Test func legacyRecordFirstUseStartsAtEarliestInstallation() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = AppLibrary(root: tmp.appendingPathComponent("lib"))
        let rec = try await lib.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456")
        let old = Date(timeIntervalSince1970: 1_000_000), now = Date(timeIntervalSince1970: 3_000_000)
        // Simulates state written before first-use tracking: an installation but no dates.
        var failed = Installation(deviceID: "dev1", installedAt: old, expiresAt: old)
        failed.lastErrorKey = "deviceLocked"
        try await lib.upsert(failed, for: rec.id)
        #expect(await lib.records().first?.appIDFirstUse == nil)
        try await lib.upsert(Installation(deviceID: "dev2", installedAt: now, expiresAt: now), for: rec.id)
        #expect(await lib.records().first?.appIDFirstUse == ["com.example.demo.TEAM123456": old])
    }
}
