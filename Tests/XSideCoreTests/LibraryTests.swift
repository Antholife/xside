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
        #expect(fresh.loadIssue == .unreadable) // no backup yet: a single save so far
        // A new timestamped copy; an earlier corrupt file is never overwritten.
        #expect(try String(contentsOf: root.appendingPathComponent("state.json.corrupt"), encoding: .utf8) == "old")
        let corrupt = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("state.json.corrupt-") }
        #expect(corrupt.count == 1)
        #expect(try String(contentsOf: root.appendingPathComponent(corrupt[0]), encoding: .utf8) == "{ not json")
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

    @Test func removeDeviceDropsInstallationsAndEmptyRecords() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("lib")
        let lib = AppLibrary(root: root)
        let both = try await lib.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456")
        try await lib.upsert(inst("a"), for: both.id)
        try await lib.upsert(inst("b"), for: both.id)
        let other = AppInfo(bundleID: "com.example.other", name: "Other", version: "1", executable: "O")
        let onlyA = try await lib.importIPA(try makeIPA(in: tmp), info: other, teamID: "TEAM123456")
        try await lib.upsert(inst("a"), for: onlyA.id)

        let changed = try await lib.removeDevice("a")
        #expect(changed == 2)
        let left = await lib.records()
        #expect(left.count == 1)
        #expect(left[0].id == both.id)
        #expect(left[0].installations == [inst("b")])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/\(onlyA.id.uuidString)").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/\(both.id.uuidString)").path))
        #expect(await AppLibrary(root: root).records() == left) // persisted
        #expect(try await lib.removeDevice("a") == 0)
    }

    @Test func removeInstallationKeepsTheRecordAndItsFiles() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("lib")
        let lib = AppLibrary(root: root)
        let rec = try await lib.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456")
        try await lib.upsert(inst("a"), for: rec.id)
        try await lib.upsert(inst("b"), for: rec.id)

        #expect(try await lib.removeInstallation(recordID: rec.id, deviceID: "a"))
        #expect(try #require(await lib.records().first).installations == [inst("b")])
        #expect(try await lib.removeInstallation(recordID: rec.id, deviceID: "a") == false)
        #expect(try await lib.removeInstallation(recordID: rec.id, deviceID: "b"))
        let left = await lib.records()
        #expect(left.count == 1 && left[0].installations.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(rec.ipaPath).path))
        #expect(await AppLibrary(root: root).records() == left) // persisted
        // Deleted, files included, once the caller finds it unused.
        #expect(try await lib.removeIfEmpty(rec.id))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/\(rec.id.uuidString)").path))
        await #expect(throws: XSideError.recordNotFound) {
            try await lib.removeInstallation(recordID: rec.id, deviceID: "a")
        }
    }

    @Test func removedInstallationIsNotRevivedByARefresh() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = AppLibrary(root: tmp.appendingPathComponent("lib"))
        let rec = try await lib.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456")
        try await lib.upsert(inst("a"), for: rec.id)
        try await lib.removeInstallation(recordID: rec.id, deviceID: "a")
        await #expect(throws: XSideError.recordNotFound) {
            try await lib.upsert(inst("a", 14), for: rec.id, requireExisting: true)
        }
    }

    @Test func requireExistingUpsertDoesNotRevive() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = AppLibrary(root: tmp.appendingPathComponent("lib"))
        let rec = try await lib.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456")
        try await lib.upsert(inst("a"), for: rec.id)
        try await lib.upsert(inst("a", 3), for: rec.id, requireExisting: true)
        try await lib.upsert(inst("b"), for: rec.id) // another device's installation keeps the record alive
        try await lib.removeDevice("a")
        await #expect(throws: XSideError.recordNotFound) {
            try await lib.upsert(inst("a"), for: rec.id, requireExisting: true)
        }
        #expect(try #require(await lib.records().first).installations == [inst("b")])
    }
}

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

private func libraryRoot(state: Data, in tmp: URL) throws -> URL {
    let root = tmp.appendingPathComponent("lib")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try state.write(to: root.appendingPathComponent("state.json"))
    return root
}

struct LibraryResilienceTests {
    @Test func decodesStateWrittenBeforeNewKeys() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try libraryRoot(state: Data(contentsOf: fixtures.appendingPathComponent("state-v1.json")), in: tmp)
        let lib = AppLibrary(root: root)
        #expect(lib.loadIssue == nil)
        let records = await lib.records()
        #expect(records.count == 2)
        let demo = try #require(records.first { $0.originalBundleID == "com.example.demo" })
        #expect(demo.options == InstallOptions(customBundleID: "com.custom.demo", fileSharing: true))
        #expect(demo.appIDFirstUse == nil)
        let installation = try #require(demo.installations.first)
        #expect(installation.lastErrorKey == nil)
        #expect(installation.signedBundleID == nil && installation.signingIdentitySHA1 == nil && installation.teamID == nil)
        // Missing display name, options and team: defaults, the team read back from the signed id.
        let old = try #require(records.first { $0.originalBundleID == "com.example.old" })
        #expect(old.displayName == "com.example.old")
        #expect(old.teamID == "TEAM123456")
        #expect(old.options == InstallOptions())
    }

    @Test func skipsUnreadableRecordAndKeepsTheFile() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        var json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixtures.appendingPathComponent("state-v1.json"))) as! [[String: Any]]
        json.append(["displayName": "No id"]) // unreadable: no id, bundle id or archive
        let original = try JSONSerialization.data(withJSONObject: json)
        let root = try libraryRoot(state: original, in: tmp)
        let lib = AppLibrary(root: root)
        #expect(lib.loadIssue == .recordsSkipped(1))
        #expect(await lib.records().count == 2)
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("state.json.corrupt-") }
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: root.appendingPathComponent(kept[0])) == original)
    }

    @Test func restoresFromRollingBackup() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("lib")
        let lib = AppLibrary(root: root)
        let rec = try await lib.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json.bak").path))
        try await lib.upsert(inst("dev1"), for: rec.id) // second save: the first state is backed up
        let backup = try #require(try? Data(contentsOf: root.appendingPathComponent("state.json.bak")))
        #expect(try JSONSerialization.jsonObject(with: backup) is [Any])

        try Data("garbage".utf8).write(to: root.appendingPathComponent("state.json"))
        let restored = AppLibrary(root: root)
        #expect(restored.loadIssue == .restoredFromBackup)
        #expect(await restored.records().map(\.id) == [rec.id])
        #expect(await restored.records().first?.installations.isEmpty == true) // the state before the last save
    }

    @Test func corruptCopiesNeverOverwriteEachOther() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = AppLibrary.corruptURL(root: tmp, now: date)
        #expect(first.lastPathComponent == "state.json.corrupt-20270115-080000")
        try Data().write(to: first)
        let second = AppLibrary.corruptURL(root: tmp, now: date)
        #expect(second.lastPathComponent == "state.json.corrupt-20270115-080000-2")
    }

    @Test func removeDeviceKeepsRecordsWithActiveJobs() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("lib")
        let lib = AppLibrary(root: root)
        let busy = try await lib.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456")
        try await lib.upsert(inst("a"), for: busy.id)
        let other = AppInfo(bundleID: "com.example.other", name: "Other", version: "1", executable: "O")
        let idle = try await lib.importIPA(try makeIPA(in: tmp), info: other, teamID: "TEAM123456")
        try await lib.upsert(inst("a"), for: idle.id)

        // `busy` is being installed on device b: removing a must not delete it.
        #expect(try await lib.removeDevice("a", keeping: [busy.id]) == 2)
        let left = await lib.records()
        #expect(left.map(\.id) == [busy.id])
        #expect(left[0].installations.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(busy.ipaPath).path))
        try await lib.upsert(inst("b"), for: busy.id) // the job on b can still record its result
        #expect(await lib.records().first?.installations == [inst("b")])
    }

    @Test func newCustomIDDoesNotChangeOtherDevicesBundle() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = AppLibrary(root: tmp.appendingPathComponent("lib"))
        let rec = try await lib.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456")
        try await lib.upsert(inst("a"), for: rec.id) // older data: no per-installation bundle id
        try await lib.setOptions(InstallOptions(customBundleID: "com.custom.demo"), for: rec.id)
        let updated = try #require(await lib.records().first)
        #expect(updated.signedBundleID == "com.custom.demo")
        #expect(updated.installations.first?.signedBundleID == "com.example.demo.TEAM123456")
    }

    @Test func refusesInvalidCustomBundleID() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = AppLibrary(root: tmp.appendingPathComponent("lib"))
        let rec = try await lib.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456")
        await #expect(throws: XSideError.invalidBundleID("com.bad id")) {
            try await lib.setOptions(InstallOptions(customBundleID: "com.bad id"), for: rec.id)
        }
        #expect(await lib.records().first?.signedBundleID == "com.example.demo.TEAM123456")
    }

    @Test func debugBundleHasItsOwnFolder() {
        #expect(LibraryLocation.folderName(bundleID: "io.github.xside.XSide") == "XSide")
        #expect(LibraryLocation.folderName(bundleID: "io.github.xside.XSide.debug") == "XSide-debug")
        #expect(LibraryLocation.folderName(bundleID: nil) == "XSide") // `swift run`
    }

    @Test func removeIfEmptyKeepsRecordsWithInstallations() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("lib")
        let lib = AppLibrary(root: root)
        let rec = try await lib.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456")
        try await lib.upsert(inst("b"), for: rec.id)
        #expect(try await lib.removeIfEmpty(rec.id) == false)
        try await lib.removeDevice("b", keeping: [rec.id])
        #expect(try await lib.removeIfEmpty(rec.id))
        #expect(await lib.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/\(rec.id.uuidString)").path))
        #expect(try await lib.removeIfEmpty(UUID()) == false)
    }
}
