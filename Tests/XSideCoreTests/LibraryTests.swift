import Testing
import Foundation
import CryptoKit
@testable import XSideCore

private func tempDir() throws -> URL {
    let d = TestTemp.root.appendingPathComponent(UUID().uuidString)
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

    /// The import scan's 32-bit finding is kept (the Compatibility fixes row says Applied / Not
    /// applied), updated by a new import, and unknown in older state.
    @Test func keepsTheLegacy32Finding() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("lib")
        let lib = AppLibrary(root: root)
        let fat = AppInfo(bundleID: "com.example.demo", name: "Demo", version: "1.0", executable: "Demo", hasLegacy32: true)
        #expect(try await lib.importIPA(try makeIPA(in: tmp), info: fat, teamID: "TEAM123456").legacy32 == true)
        #expect(await AppLibrary(root: root).records().first?.legacy32 == true)
        #expect(try await lib.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456").legacy32 == false)
        let old = Data(#"[{"id":"\#(UUID().uuidString)","originalBundleID":"com.x","ipaPath":"apps/x/original.ipa"}]"#.utf8)
        #expect(try JSONDecoder().decode([AppRecord].self, from: old).first?.legacy32 == nil)
    }

    /// The process name crash logs go by: kept at import, persisted, filled in later for older
    /// records (at a signing), and absent from older state without harm.
    @Test func keepsTheExecutable() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("lib")
        let lib = AppLibrary(root: root)
        let rec = try await lib.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456")
        #expect(rec.executable == "Demo")
        #expect(await AppLibrary(root: root).records().first?.executable == "Demo")
        #expect(try await lib.setExecutable("Demo", recordID: rec.id) == false) // unchanged: not written
        #expect(try await lib.setExecutable("Demo2", recordID: rec.id))
        #expect(await AppLibrary(root: root).records().first?.executable == "Demo2")
        let old = Data(#"[{"id":"\#(UUID().uuidString)","originalBundleID":"com.x","ipaPath":"apps/x/original.ipa"}]"#.utf8)
        let decoded = try JSONDecoder().decode([AppRecord].self, from: old)
        #expect(decoded.first?.executable == nil)
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
        #expect(first.version == "1.0")
        #expect(second.version == "2.0") // the new .ipa's version
        #expect(try String(contentsOf: root.appendingPathComponent(second.ipaPath), encoding: .utf8) == "two")
        #expect(await lib.records().count == 1)
    }

    /// Written before versions were kept: no version, nothing else lost.
    @Test func recordsWithoutVersionStillLoad() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","originalBundleID":"com.x","ipaPath":"a.ipa","installations":[{"deviceID":"D","installedAt":0,"expiresAt":0}]}"#
        let record = try JSONDecoder().decode(AppRecord.self, from: Data(json.utf8))
        #expect(record.version == nil)
        #expect(record.installations.first?.appVersion == nil)
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

// MARK: Tweaks

private let tweakNow = Date(timeIntervalSince1970: 1_800_000_000)

private func tweakDeb(in dir: URL, version: String, payload: String = "", compression: String = "gz") async throws -> URL {
    let control = "Package: com.example.tweak\nName: Example\nVersion: \(version)\nArchitecture: iphoneos-arm64\n"
    let dylib = FakeIPA.dylibMachO(linking: [], padding: 64, strings: payload.isEmpty ? [] : [payload])
    let url = dir.appendingPathComponent("tweak-\(UUID().uuidString).deb")
    try await FakeDeb.deb(control: control, files: [.file("./Library/MobileSubstrate/DynamicLibraries/Example.dylib", dylib)],
                          compression: compression).write(to: url)
    return url
}

private func tweakDylib(in dir: URL, _ name: String = "Hello.dylib", payload: String? = nil) throws -> URL {
    let folder = dir.appendingPathComponent("drop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try FakeIPA.dylibMachO(linking: [], padding: 64, strings: [payload ?? name]).write(to: url)
    return url
}

/// A successful signing of `device` that asked for (and injected) `signed`, now listing `uses`.
private func signing(_ device: String, uses: [TweakUse], signed: [String]) -> Installation {
    var i = inst(device)
    i.tweaks = uses
    i.signedChoices = SigningChoices(withoutXSideFeatures: false, duoCompatibility: false, iCloudSignedOut: false, tweaks: signed)
    i.tweakResults = Dictionary(uniqueKeysWithValues: signed.map { ($0, TweakResult.injected(converted: false)) })
    return i
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

struct LibraryTweakTests {
    private func library(_ tmp: URL, devices: [String]) async throws -> (AppLibrary, AppRecord) {
        let lib = AppLibrary(root: tmp.appendingPathComponent("lib"))
        let rec = try await lib.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456")
        for d in devices { try await lib.upsert(inst(d), for: rec.id) }
        return (lib, rec)
    }

    private func record(_ lib: AppLibrary) async throws -> AppRecord { try #require(await lib.records().first) }
    private func uses(_ lib: AppLibrary, _ device: String) async throws -> [TweakUse]? {
        try await record(lib).installations.first { $0.deviceID == device }?.tweaks
    }

    @Test func addingATweakStoresItOnceAndEnablesItOnTheGivenDevicesOnly() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec) = try await library(tmp, devices: ["A", "B"])
        let src = try tweakDylib(in: tmp)
        let (package, replacing) = try await lib.addTweak(src, recordID: rec.id, deviceIDs: ["A"], runner: ProcessRunner(), now: tweakNow)
        #expect(replacing == nil)
        #expect(try await record(lib).tweaks == [package])
        #expect(try await uses(lib, "A") == [TweakUse(id: package.id, enabled: true)])
        #expect(try await uses(lib, "B")?.isEmpty ?? true)
        let folder = lib.tweakDirectory(recordID: rec.id, id: package.id)
        #expect(folder.path.hasSuffix("apps/\(rec.id.uuidString)/tweaks/\(package.id)"))
        #expect(exists(folder.appendingPathComponent("Hello.dylib")))

        // The same bytes again, for B: stored once, now on B too.
        let again = try await lib.addTweak(src, recordID: rec.id, deviceIDs: ["B"], runner: ProcessRunner(), now: tweakNow)
        #expect(again.package.id == package.id && again.replacing == nil)
        #expect(try await record(lib).tweaks?.count == 1)
        #expect(try await uses(lib, "A") == [TweakUse(id: package.id, enabled: true)])
        #expect(try await uses(lib, "B") == [TweakUse(id: package.id, enabled: true)])
        let tweaksFolder = folder.deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: tweaksFolder.path) == [package.id])
        // Persisted.
        #expect(await AppLibrary(root: lib.root).records() == (await lib.records()))
    }

    @Test func setTweaksIsPerDeviceAndKeepsThePoolOrder() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec) = try await library(tmp, devices: ["A", "B"])
        let one = try await lib.addTweak(try tweakDylib(in: tmp, "One.dylib"), recordID: rec.id, deviceIDs: ["A"],
                                         runner: ProcessRunner(), now: tweakNow).package
        let two = try await lib.addTweak(try tweakDylib(in: tmp, "Two.dylib"), recordID: rec.id, deviceIDs: ["A"],
                                         runner: ProcessRunner(), now: tweakNow).package
        #expect(try await uses(lib, "A")?.map(\.id) == [one.id, two.id])
        // Given out of order, with an unknown id and a duplicate: pool order, known ids, once.
        let changed = try await lib.setTweaks([TweakUse(id: two.id, enabled: false, force: true), TweakUse(id: "ffffffffffffffff", enabled: true),
                                               TweakUse(id: one.id, enabled: true), TweakUse(id: two.id, enabled: true)],
                                              recordID: rec.id, deviceID: "B")
        #expect(changed)
        #expect(try await uses(lib, "B") == [TweakUse(id: one.id, enabled: true), TweakUse(id: two.id, enabled: false, force: true)])
        #expect(try await uses(lib, "A")?.map(\.id) == [one.id, two.id]) // A untouched
        #expect(try await lib.setTweaks([TweakUse(id: one.id, enabled: true), TweakUse(id: two.id, enabled: false, force: true)],
                                        recordID: rec.id, deviceID: "B") == false)
    }

    @Test func aNewerVersionOfTheSamePackageIsOfferedNotApplied() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec) = try await library(tmp, devices: ["A", "B"])
        let v1 = try await lib.addTweak(try await tweakDeb(in: tmp, version: "1.0"), recordID: rec.id, deviceIDs: ["A", "B"],
                                        runner: ProcessRunner(), now: tweakNow).package
        #expect(try await lib.setTweaks([TweakUse(id: v1.id, enabled: false, force: true)], recordID: rec.id, deviceID: "B"))
        _ = try await lib.recordSigning(signing("A", uses: [TweakUse(id: v1.id, enabled: true)], signed: [v1.id]), for: rec.id, requireExisting: true)
        _ = try await lib.recordSigning(signing("B", uses: [TweakUse(id: v1.id, enabled: false, force: true)], signed: [v1.id]),
                                        for: rec.id, requireExisting: true)

        let (offered, replacing) = try await lib.addTweak(try await tweakDeb(in: tmp, version: "2.0", payload: "new"), recordID: rec.id,
                                                     deviceIDs: ["A"], runner: ProcessRunner(), now: tweakNow)
        #expect(replacing?.version == "1.0" && replacing?.id == v1.id)
        #expect(offered.version == "2.0" && offered.id != v1.id)
        #expect(try await record(lib).tweaks == [v1]) // offered, not applied
        #expect(try await uses(lib, "A") == [TweakUse(id: v1.id, enabled: true)])
        // A signing while the person decides keeps the offered version's files.
        _ = try await lib.recordSigning(signing("A", uses: [TweakUse(id: v1.id, enabled: true)], signed: [v1.id]), for: rec.id, requireExisting: true)
        #expect(exists(lib.tweakDirectory(recordID: rec.id, id: offered.id)))
        // Not confirmed before XSide quits: gone at the next launch's first collection.
        let relaunched = AppLibrary(root: lib.root)
        _ = try await relaunched.recordSigning(signing("A", uses: [TweakUse(id: v1.id, enabled: true)], signed: [v1.id]), for: rec.id, requireExisting: true)
        #expect(!exists(lib.tweakDirectory(recordID: rec.id, id: offered.id)))
        await #expect(throws: (any Error).self) { try await lib.replaceTweak(v1.id, with: offered, recordID: rec.id) }
        // Offered again, then confirmed.
        let v2 = try await lib.addTweak(try await tweakDeb(in: tmp, version: "2.0", payload: "new"), recordID: rec.id,
                                        deviceIDs: ["A"], runner: ProcessRunner(), now: tweakNow).package

        try await lib.replaceTweak(v1.id, with: v2, recordID: rec.id)
        #expect(try await record(lib).tweaks == [v2])
        #expect(try await uses(lib, "A") == [TweakUse(id: v2.id, enabled: true)])
        #expect(try await uses(lib, "B") == [TweakUse(id: v2.id, enabled: false, force: true)])
        let old = lib.tweakDirectory(recordID: rec.id, id: v1.id)
        #expect(exists(old)) // both devices still run 1.0

        _ = try await lib.recordSigning(signing("A", uses: [TweakUse(id: v2.id, enabled: true)], signed: [v2.id]), for: rec.id, requireExisting: true)
        #expect(exists(old)) // B's last signing had it
        _ = try await lib.recordSigning(signing("B", uses: [TweakUse(id: v2.id, enabled: false, force: true)], signed: []),
                                        for: rec.id, requireExisting: true)
        #expect(!exists(old))
        #expect(exists(lib.tweakDirectory(recordID: rec.id, id: v2.id)))
        // Unknown ids are refused.
        await #expect(throws: XSideError.recordNotFound) { try await lib.replaceTweak(v1.id, with: v2, recordID: rec.id) }
    }

    @Test func removedTweakFilesGoAfterTheNextSigning() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec) = try await library(tmp, devices: ["A", "B"])
        let p = try await lib.addTweak(try tweakDylib(in: tmp), recordID: rec.id, deviceIDs: ["A"], runner: ProcessRunner(), now: tweakNow).package
        _ = try await lib.recordSigning(signing("A", uses: [TweakUse(id: p.id, enabled: true)], signed: [p.id]), for: rec.id, requireExisting: true)
        let folder = lib.tweakDirectory(recordID: rec.id, id: p.id)

        #expect(try await lib.setTweaks([], recordID: rec.id, deviceID: "A"))
        #expect(exists(folder)) // still on the device
        #expect(try await record(lib).tweaks == [p])
        // Another device's signing doesn't count it as gone: A's copy still has it.
        _ = try await lib.recordSigning(signing("B", uses: [], signed: []), for: rec.id, requireExisting: true)
        #expect(exists(folder))

        _ = try await lib.recordSigning(signing("A", uses: [], signed: []), for: rec.id, requireExisting: true)
        #expect(!exists(folder))
        #expect(try await record(lib).tweaks?.isEmpty ?? true)
    }

    @Test func removingTheLastInstallationThatHadATweakDeletesIt() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec) = try await library(tmp, devices: ["A", "B"])
        let p = try await lib.addTweak(try tweakDylib(in: tmp), recordID: rec.id, deviceIDs: ["A"], runner: ProcessRunner(), now: tweakNow).package
        _ = try await lib.recordSigning(signing("A", uses: [TweakUse(id: p.id, enabled: true)], signed: [p.id]), for: rec.id, requireExisting: true)
        let folder = lib.tweakDirectory(recordID: rec.id, id: p.id)
        try await lib.removeInstallation(recordID: rec.id, deviceID: "A")
        #expect(!exists(folder))
        #expect(try await record(lib).tweaks?.isEmpty ?? true)
    }

    @Test func aTweakChosenForADeviceNotYetInstalledIsKept() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec) = try await library(tmp, devices: ["A"])
        let p = try await lib.addTweak(try tweakDylib(in: tmp), recordID: rec.id, deviceIDs: ["C"], runner: ProcessRunner(), now: tweakNow).package
        #expect(try await record(lib).pendingTweakUses?["C"] == [TweakUse(id: p.id, enabled: true)])
        // A signs without it: C's choice keeps it.
        _ = try await lib.recordSigning(signing("A", uses: [], signed: []), for: rec.id, requireExisting: true)
        #expect(exists(lib.tweakDirectory(recordID: rec.id, id: p.id)))
        // C installed: its installation carries the choice from now on.
        _ = try await lib.recordSigning(signing("C", uses: [TweakUse(id: p.id, enabled: true)], signed: [p.id]), for: rec.id, requireExisting: false)
        #expect(try await record(lib).pendingTweakUses?["C"] == nil)
        #expect(try await uses(lib, "C") == [TweakUse(id: p.id, enabled: true)])
    }

    @Test func resultsCountInjectedAndConvertedTweaks() throws {
        var i = inst("A")
        #expect(i.injectedTweakCount == 0 && !i.hasConvertedTweak)
        i.tweakResults = ["a": .injected(converted: false), "b": .injected(converted: true),
                          "c": .skipped(.noRoom), "d": .skipped(.failed), "e": .skipped(.incompatible(.needsJailbreak("x")))]
        i.embeddedDependencies = ["com.opa334.altlist"]
        #expect(i.injectedTweakCount == 2 && i.hasConvertedTweak)
        let back = try JSONDecoder().decode(Installation.self, from: JSONEncoder().encode(i))
        #expect(back == i)
    }

    @Test func oldStateWithoutTweaksLoads() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try libraryRoot(state: Data(contentsOf: fixtures.appendingPathComponent("state-v1.json")), in: tmp)
        let lib = AppLibrary(root: root)
        #expect(lib.loadIssue == nil)
        let records = await lib.records()
        #expect(records.count == 2)
        for r in records {
            #expect(r.tweaks == nil && r.pendingTweakUses == nil)
            for i in r.installations {
                #expect(i.tweaks == nil && i.tweakResults == nil && i.embeddedDependencies == nil)
                #expect(i.injectedTweakCount == 0 && !i.hasConvertedTweak)
            }
        }
        let choices = try JSONDecoder().decode(SigningChoices.self, from: Data(
            #"{"withoutXSideFeatures":false,"duoCompatibility":false,"iCloudSignedOut":false}"#.utf8))
        #expect(choices.tweaks == nil)
    }

    @Test func aDamagedTweakEntryDoesNotCostTheOthers() throws {
        let good = #"{"id":"0123456789abcdef","kind":"dylib","origin":{"added":{}},"packageID":"hello","provides":[],"name":"Hello","depends":[],"files":["Hello.dylib"],"binaries":[],"notes":[],"addedAt":0}"#
        let json = #"[{"id":"\#(UUID().uuidString)","originalBundleID":"com.x","ipaPath":"a","tweaks":[\#(good),{"id":3},\#(good.replacingOccurrences(of: "dylib\"", with: "future\""))]}]"#
        let r = try #require(try JSONDecoder().decode([AppRecord].self, from: Data(json.utf8)).first)
        #expect(r.tweaks?.map(\.id) == ["0123456789abcdef"])
    }

    // MARK: Edits made while a job runs

    @Test func aTweakAddedWhileAJobRunsSurvivesItsSigning() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec) = try await library(tmp, devices: ["A"])
        let atStart = try await record(lib)
        // The jobs start (A refreshes, C is a first install), then the person adds a tweak to both.
        let startA = atStart.signingSnapshot(deviceID: "A"), startC = atStart.signingSnapshot(deviceID: "C")
        let p = try await lib.addTweak(try tweakDylib(in: tmp), recordID: rec.id, deviceIDs: ["A", "C"],
                                       runner: ProcessRunner(), now: tweakNow).package
        _ = try await lib.recordSigning(signing("A", uses: [], signed: []), for: rec.id, requireExisting: true, startedFrom: startA)
        _ = try await lib.recordSigning(signing("C", uses: [], signed: []), for: rec.id, requireExisting: false, startedFrom: startC)
        #expect(try await uses(lib, "A") == [TweakUse(id: p.id, enabled: true)])
        #expect(try await uses(lib, "C") == [TweakUse(id: p.id, enabled: true)])
        #expect(try await record(lib).pendingTweakUses == nil)
        #expect(try await record(lib).tweaks == [p])
        #expect(exists(lib.tweakDirectory(recordID: rec.id, id: p.id)))
        // Not signed yet: pending on both.
        let a = try #require(try await record(lib).installations.first { $0.deviceID == "A" })
        #expect(a.pendingSigningChanges(wantsWithoutXSideFeatures: false) == [.tweaks])
    }

    /// Device round 2, item 10: in Mes apps, turning a tweak back on (after a signing without it)
    /// is pending as much as turning it off, and so is « Injecter quand même ».
    @Test func turningATweakOnOrOffOrForcedIsPendingUntilSigned() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec) = try await library(tmp, devices: ["A"])
        let p = try await lib.addTweak(try tweakDylib(in: tmp), recordID: rec.id, deviceIDs: ["A"], runner: ProcessRunner(),
                                       now: tweakNow).package
        func pending() async throws -> Set<SigningTimeSetting> {
            try #require(try await record(lib).installations.first).pendingSigningChanges(wantsWithoutXSideFeatures: false)
        }
        func sign() async throws {
            let i = try #require(try await record(lib).installations.first)
            let start = try await record(lib).signingSnapshot(deviceID: "A")
            var job = signing("A", uses: i.tweaks ?? [], signed: i.enabledTweakIDs)
            job.signedChoices?.forcedTweaks = i.forcedTweakIDs.isEmpty ? nil : i.forcedTweakIDs
            _ = try await lib.recordSigning(job, for: rec.id, requireExisting: true, startedFrom: start)
        }
        try await sign()
        #expect(try await pending().isEmpty)
        // Off: pending; signed without it: nothing pending, it stays listed off.
        _ = try await lib.setTweaks([TweakUse(id: p.id, enabled: false)], recordID: rec.id, deviceID: "A")
        #expect(try await pending() == [.tweaks])
        try await sign()
        #expect(try await pending().isEmpty)
        #expect(try await uses(lib, "A") == [TweakUse(id: p.id, enabled: false)])
        // On again: pending.
        _ = try await lib.setTweaks([TweakUse(id: p.id, enabled: true)], recordID: rec.id, deviceID: "A")
        #expect(try await pending() == [.tweaks])
        try await sign()
        #expect(try await pending().isEmpty)
        // Forced: pending; unforced again before signing: nothing.
        _ = try await lib.setTweaks([TweakUse(id: p.id, enabled: true, force: true)], recordID: rec.id, deviceID: "A")
        #expect(try await pending() == [.tweaks])
        _ = try await lib.setTweaks([TweakUse(id: p.id, enabled: true)], recordID: rec.id, deviceID: "A")
        #expect(try await pending().isEmpty)
    }

    @Test func theJobsOwnChoiceWinsWhenNothingChangedMeanwhile() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec) = try await library(tmp, devices: ["A"])
        let p = try await lib.addTweak(try tweakDylib(in: tmp), recordID: rec.id, deviceIDs: [], runner: ProcessRunner(), now: tweakNow).package
        _ = try await lib.setTweaks([TweakUse(id: p.id, enabled: true)], recordID: rec.id, deviceID: "A")
        let start = try await record(lib).signingSnapshot(deviceID: "A")
        // The install window turned it off and Duo on for this device, through the job.
        var job = signing("A", uses: [TweakUse(id: p.id, enabled: false)], signed: [])
        job.duoCompatibility = true
        job.signedChoices?.duoCompatibility = true
        let stored = try await lib.recordSigning(job, for: rec.id, requireExisting: true, startedFrom: start)
        #expect(stored.tweaks == [TweakUse(id: p.id, enabled: false)] && stored.duoCompatibility == true)
    }

    @Test func compatibilityChoicesMadeWhileAJobRunsWin() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec) = try await library(tmp, devices: ["A"])
        #expect(try await lib.setICloudSignedOut(true, recordID: rec.id, deviceID: "A"))
        let start = try await record(lib).signingSnapshot(deviceID: "A")
        // During the job: Duo on, iCloud off.
        #expect(try await lib.setDuoCompatibility(true, recordID: rec.id, deviceID: "A"))
        #expect(try await lib.setICloudSignedOut(false, recordID: rec.id, deviceID: "A"))
        var job = signing("A", uses: [], signed: [])
        job.iCloudSignedOut = true
        job.iCloudSignedOutMissing = true
        job.signedChoices?.iCloudSignedOut = true
        let stored = try await lib.recordSigning(job, for: rec.id, requireExisting: true, startedFrom: start)
        #expect(stored.duoCompatibility == true && !stored.hasDuoCompatibility) // asked, not signed yet
        #expect(stored.iCloudSignedOut == nil && stored.iCloudSignedOutMissing == nil)
        #expect(stored.pendingSigningChanges(wantsWithoutXSideFeatures: false) == [.duoCompatibility, .iCloudSignedOut])
    }

    @Test func tweaksHeldByARunningJobAreNotCollected() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec) = try await library(tmp, devices: ["A", "B", "C"])
        let p = try await lib.addTweak(try tweakDylib(in: tmp), recordID: rec.id, deviceIDs: ["A"], runner: ProcessRunner(), now: tweakNow).package
        let folder = lib.tweakDirectory(recordID: rec.id, id: p.id)
        // A's job holds it; meanwhile the person turns it off and another device's job ends.
        await lib.reserveTweaks([p.id], recordID: rec.id)
        _ = try await lib.setTweaks([], recordID: rec.id, deviceID: "A")
        _ = try await lib.recordSigning(signing("B", uses: [], signed: []), for: rec.id, requireExisting: true)
        try await lib.removeInstallation(recordID: rec.id, deviceID: "C")
        #expect(exists(folder))
        // A caller's own reservation (`keepingTweaks`) works the same way.
        await lib.releaseTweaks([p.id], recordID: rec.id)
        _ = try await lib.recordSigning(signing("B", uses: [], signed: []), for: rec.id, requireExisting: true, keepingTweaks: [p.id])
        #expect(exists(folder))
        _ = try await lib.recordSigning(signing("B", uses: [], signed: []), for: rec.id, requireExisting: true)
        #expect(!exists(folder))
    }

    @Test func aTweakAddedAgainWhileItIsCollectedIsKept() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec) = try await library(tmp, devices: ["A", "B"])
        // bzip2 goes through the runner: the gate can hold it.
        let src = try await tweakDeb(in: tmp, version: "1.0", compression: "bz2")
        let p = try await lib.addTweak(src, recordID: rec.id, deviceIDs: ["A"], runner: ProcessRunner(), now: tweakNow).package
        _ = try await lib.setTweaks([], recordID: rec.id, deviceID: "A")
        // The same .deb again, its analysis held in the middle while a collection drops it.
        let gate = GateRunner()
        async let again = lib.addTweak(src, recordID: rec.id, deviceIDs: ["A"], runner: gate, now: tweakNow)
        await gate.waitUntilHeld()
        _ = try await lib.recordSigning(signing("B", uses: [], signed: []), for: rec.id, requireExisting: true)
        await gate.release()
        let added = try await again
        #expect(added.package.id == p.id)
        #expect(try await record(lib).tweaks == [p])
        #expect(exists(lib.tweakDirectory(recordID: rec.id, id: p.id)))
        // No folder is deleted while any analysis runs (it may be keeping one it found stored):
        // the dropped one waits for the next collection. (Taking it off the list collects at
        // once since device round 3: done while the analysis is held.)
        let other = GateRunner()
        async let q = lib.addTweak(try await tweakDeb(in: tmp, version: "1.0", payload: "q", compression: "bz2"),
                                   recordID: rec.id, deviceIDs: ["B"], runner: other, now: tweakNow)
        await other.waitUntilHeld()
        _ = try await lib.setTweaks([], recordID: rec.id, deviceID: "A")
        _ = try await lib.recordSigning(signing("B", uses: [], signed: []), for: rec.id, requireExisting: true)
        #expect(try await record(lib).tweaks?.contains(p) == false)
        #expect(exists(lib.tweakDirectory(recordID: rec.id, id: p.id)))
        await other.release()
        _ = try await q
        _ = try await lib.recordSigning(signing("A", uses: [], signed: []), for: rec.id, requireExisting: true)
        #expect(!exists(lib.tweakDirectory(recordID: rec.id, id: p.id)))
    }

    @Test func forcingATweakIsPendingUntilSigned() {
        let signed = SigningChoices(withoutXSideFeatures: false, duoCompatibility: false, iCloudSignedOut: false,
                                    tweaks: ["a"], forcedTweaks: [])
        var i = inst("A")
        i.signedChoices = signed
        i.tweaks = [TweakUse(id: "a", enabled: true)]
        #expect(i.pendingSigningChanges(wantsWithoutXSideFeatures: false).isEmpty)
        i.tweaks = [TweakUse(id: "a", enabled: true, force: true)]
        #expect(i.pendingSigningChanges(wantsWithoutXSideFeatures: false) == [.tweaks])
        i.signedChoices?.forcedTweaks = ["a"]
        #expect(i.pendingSigningChanges(wantsWithoutXSideFeatures: false).isEmpty)
        // Forcing a disabled tweak changes nothing on the device.
        i.tweaks = [TweakUse(id: "a", enabled: true, force: true), TweakUse(id: "b", enabled: false, force: true)]
        #expect(i.pendingSigningChanges(wantsWithoutXSideFeatures: false).isEmpty)
        #expect(i.forcedTweakIDs == ["a"])
    }

    // MARK: Download cache

    @Test func aDownloadIsCachedAndFoundAgain() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = AppLibrary(root: tmp.appendingPathComponent("lib"))
        let bytes = Data("a deb, really".utf8)
        let src = tmp.appendingPathComponent("dl.deb")
        try bytes.write(to: src)
        let sha = sha256(bytes)
        let stored = try await lib.storeDownload(src, sha256: sha, packageID: "com.opa334.altlist", version: "1.2",
                                                 repo: "https://repo.example", url: "https://repo.example/altlist.deb", now: tweakNow)
        #expect(stored == lib.root.appendingPathComponent("downloads/\(sha).deb"))
        #expect(try Data(contentsOf: stored) == bytes)
        let indexData = try Data(contentsOf: lib.root.appendingPathComponent("downloads/index.json"))
        let indexDecoder = JSONDecoder()
        indexDecoder.dateDecodingStrategy = .iso8601
        #expect(try indexDecoder.decode([DownloadCacheEntry].self, from: indexData)
                == [DownloadCacheEntry(sha256: sha, packageID: "com.opa334.altlist", version: "1.2", repo: "https://repo.example",
                                       url: "https://repo.example/altlist.deb", downloadedAt: tweakNow)])
        let atLeast1 = DebDependency(package: "com.opa334.altlist", relation: ">=", version: "1.0")
        #expect(await lib.cachedDownload(packageID: "com.opa334.altlist", satisfying: atLeast1) == stored)
        #expect(await lib.cachedDownload(packageID: "com.opa334.altlist",
                                         satisfying: DebDependency(package: "com.opa334.altlist", relation: ">=", version: "3.0")) == nil)
        #expect(await lib.cachedDownload(packageID: "com.other", satisfying: DebDependency(package: "com.other")) == nil)
        // Found again by a new library (the next launch).
        #expect(await AppLibrary(root: lib.root).cachedDownload(packageID: "com.opa334.altlist", satisfying: atLeast1) == stored)
        // Bytes that don't match the given hash are refused.
        await #expect(throws: (any Error).self) {
            try await lib.storeDownload(src, sha256: String(repeating: "0", count: 64), packageID: "x", version: "1", repo: "r", url: "u")
        }
        await #expect(throws: (any Error).self) {
            try await lib.storeDownload(src, sha256: "../../evil", packageID: "x", version: "1", repo: "r", url: "u")
        }
    }

    @Test func aCorruptedCacheEntryIsIgnored() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = AppLibrary(root: tmp.appendingPathComponent("lib"))
        let dep = DebDependency(package: "com.example.dep", relation: ">=", version: "1.0")
        var urls: [URL] = []
        for content in ["one", "two"] {
            let src = tmp.appendingPathComponent("\(content).deb")
            try Data(content.utf8).write(to: src)
            urls.append(try await lib.storeDownload(src, sha256: sha256(Data(content.utf8)), packageID: "com.example.dep",
                                                    version: content == "one" ? "1.0" : "2.0", repo: "r", url: "u"))
        }
        #expect(await lib.cachedDownload(packageID: "com.example.dep", satisfying: dep) == urls[1]) // the newest
        try Data("changed".utf8).write(to: urls[1])
        #expect(await lib.cachedDownload(packageID: "com.example.dep", satisfying: dep) == urls[0])
        try FileManager.default.removeItem(at: urls[0])
        #expect(await lib.cachedDownload(packageID: "com.example.dep", satisfying: dep) == nil)
        let index = try Data(contentsOf: lib.root.appendingPathComponent("downloads/index.json"))
        #expect(try (JSONSerialization.jsonObject(with: index) as? [Any])?.isEmpty == true)
        #expect(!exists(urls[1])) // a damaged file goes too
        // A garbage index reads as empty.
        try Data("{nope".utf8).write(to: lib.root.appendingPathComponent("downloads/index.json"))
        #expect(await lib.cachedDownload(packageID: "com.example.dep", satisfying: dep) == nil)
    }

    // MARK: Leftovers

    @Test func leftoversAreSweptAtLoad() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let fm = FileManager.default
        let root = tmp.appendingPathComponent("lib")
        let temp = tmp.appendingPathComponent("tmp")
        let tweaks = root.appendingPathComponent("apps/\(UUID().uuidString)/tweaks")
        let downloads = root.appendingPathComponent("downloads")
        let old = Date().addingTimeInterval(-2 * 3600)
        func make(_ url: URL, dir: Bool = true, date: Date = old) throws {
            if dir { try fm.createDirectory(at: url, withIntermediateDirectories: true) } else {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url)
            }
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        let u = UUID().uuidString
        let gone = [tweaks.appendingPathComponent(".incoming-\(u)"), tweaks.appendingPathComponent(".stale-\(u)"),
                    downloads.appendingPathComponent(".incoming-\(u)"),
                    temp.appendingPathComponent("deb-\(u)"), temp.appendingPathComponent("bzip2-\(u)"),
                    temp.appendingPathComponent("tweak-src-\(u).deb"),
                    root.appendingPathComponent("\(AppLibrary.stagingFolder)/\(u)")]
        var kept = [tweaks.appendingPathComponent("0123456789abcdef"), temp.appendingPathComponent("deb-notauuid"),
                    root.appendingPathComponent("\(AppLibrary.stagingFolder)/notauuid"),
                    temp.appendingPathComponent("other-\(u)"), temp.appendingPathComponent("deb-\(UUID().uuidString)-recent")]
        for url in gone { try make(url, dir: !url.lastPathComponent.hasSuffix(".deb")) }
        for url in kept { try make(url) }
        let recent = [tweaks.appendingPathComponent(".incoming-\(UUID().uuidString)"), temp.appendingPathComponent("deb-\(UUID().uuidString)"),
                      root.appendingPathComponent("\(AppLibrary.stagingFolder)/\(UUID().uuidString)")]
        for url in recent { try make(url, date: Date()) }

        // A `tweaks` folder that is a link is never followed.
        let elsewhere = tmp.appendingPathComponent("elsewhere")
        let linkedApp = root.appendingPathComponent("apps/\(UUID().uuidString)")
        try fm.createDirectory(at: linkedApp, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedApp.appendingPathComponent("tweaks"), withDestinationURL: elsewhere)
        let outside = elsewhere.appendingPathComponent(".incoming-\(UUID().uuidString)")
        try make(outside)
        kept.append(outside)

        _ = AppLibrary(root: root, temporaryDirectory: temp)
        for url in gone { #expect(!exists(url), "\(url.lastPathComponent)") }
        for url in kept + recent { #expect(exists(url), "\(url.lastPathComponent)") }
    }
}

/// Holds the first command until released (an analysis caught in the middle), then runs it for real.
private actor GateRunnerState {
    var held = false, open = false
    var waiters: [CheckedContinuation<Void, Never>] = [], heldWaiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        held = true
        heldWaiters.forEach { $0.resume() }; heldWaiters = []
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitUntilHeld() async { if held { return }; await withCheckedContinuation { heldWaiters.append($0) } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

private struct GateRunner: CommandRunning {
    let state = GateRunnerState()
    func waitUntilHeld() async { await state.waitUntilHeld() }
    func release() async { await state.release() }
    func run(_ executable: String, _ arguments: [String], cwd: URL?, timeout: Duration) async throws -> CommandResult {
        await state.hold()
        return try await ProcessRunner().run(executable, arguments, cwd: cwd, timeout: timeout)
    }
}

/// The install window analyses a tweak into its own staging folder (the app may not be in the
/// library yet) and hands it to the library when Install is pressed.
struct LibraryStagedTweakTests {
    private func library(_ tmp: URL, devices: [String]) async throws -> (AppLibrary, AppRecord) {
        let lib = AppLibrary(root: tmp.appendingPathComponent("lib"))
        let rec = try await lib.importIPA(try makeIPA(in: tmp), info: info, teamID: "TEAM123456")
        for d in devices { try await lib.upsert(inst(d), for: rec.id) }
        return (lib, rec)
    }

    private func record(_ lib: AppLibrary) async throws -> AppRecord { try #require(await lib.records().first) }

    private func stage(_ source: URL, in tmp: URL) async throws -> StagedTweak {
        let staging = tmp.appendingPathComponent("staging", isDirectory: true)
        let p = try await TweakAnalyzer.analyze(source, into: staging, runner: ProcessRunner(), now: tweakNow)
        return StagedTweak(package: p, directory: staging.appendingPathComponent(p.id))
    }

    /// The files go into the pool, held for the job; no device's list changes (the job writes it
    /// when the install succeeds).
    @Test func adoptingCopiesTheStagedFolderAndHoldsItForTheJob() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec) = try await library(tmp, devices: ["A"])
        let one = try await stage(try tweakDylib(in: tmp, "One.dylib"), in: tmp)
        let two = try await stage(try tweakDylib(in: tmp, "Two.dylib"), in: tmp)
        let held = try await lib.adoptTweaks([one, two], recordID: rec.id)
        #expect(held == [one.package.id, two.package.id])
        let r = try await record(lib)
        #expect(r.tweaks == [one.package, two.package])
        #expect(r.installations.first?.tweaks == nil && r.pendingTweakUses == nil)
        #expect(exists(lib.tweakDirectory(recordID: rec.id, id: one.package.id).appendingPathComponent("One.dylib")))
        #expect(exists(one.directory)) // copied: the window keeps its own until it closes
        // Held: a collection meanwhile keeps them.
        await lib.collectUnusedTweaks(recordID: rec.id)
        #expect(try await record(lib).tweaks == [one.package, two.package])
        // Again (a second run of the same window): nothing doubles.
        _ = try await lib.adoptTweaks([one, two], recordID: rec.id)
        #expect(try await record(lib).tweaks == [one.package, two.package])
        #expect(await AppLibrary(root: lib.root).records() == (await lib.records()))
        // Released by both runs, with no device listing them: collected.
        await lib.releaseTweaks(held, recordID: rec.id)
        await lib.releaseTweaks(held, recordID: rec.id)
        await lib.collectUnusedTweaks(recordID: rec.id)
        #expect(try await record(lib).tweaks?.isEmpty ?? true)
        #expect(!exists(lib.tweakDirectory(recordID: rec.id, id: one.package.id)))
    }

    @Test func adoptingAReplacementTakesTheOldOnesPlaceOnEveryDevice() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec) = try await library(tmp, devices: ["A", "B"])
        let v1 = try await lib.addTweak(try await tweakDeb(in: tmp, version: "1.0"), recordID: rec.id, deviceIDs: ["A", "B"],
                                        runner: ProcessRunner(), now: tweakNow).package
        var v2 = try await stage(try await tweakDeb(in: tmp, version: "2.0", payload: "new"), in: tmp)
        v2.replacing = v1.id
        _ = try await lib.adoptTweaks([v2], recordID: rec.id)
        let r = try await record(lib)
        #expect(r.tweaks == [v2.package])
        #expect(r.installations.first { $0.deviceID == "A" }?.tweaks == [TweakUse(id: v2.package.id)])
        #expect(r.installations.first { $0.deviceID == "B" }?.tweaks == [TweakUse(id: v2.package.id)])
        // The same package id without `replacing` still never leaves two versions in the pool.
        let v3 = try await stage(try await tweakDeb(in: tmp, version: "3.0", payload: "newer"), in: tmp)
        _ = try await lib.adoptTweaks([v3], recordID: rec.id)
        #expect(try await record(lib).tweaks == [v3.package])
    }

    /// A tweak off because its dependency was uninstalled keeps saying so in its new version.
    @Test func aReplacementKeepsWhyTheTweakIsOff() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec) = try await library(tmp, devices: ["A", "B"])
        let v1 = try await lib.addTweak(try await tweakDeb(in: tmp, version: "1.0"), recordID: rec.id, deviceIDs: ["A", "B"],
                                        runner: ProcessRunner(), now: tweakNow).package
        let off = TweakUse(id: v1.id, enabled: false, removedDependency: "Cephei")
        #expect(try await lib.setTweaks([off], recordID: rec.id, deviceID: "B"))
        let v2 = try await lib.addTweak(try await tweakDeb(in: tmp, version: "2.0", payload: "new"), recordID: rec.id,
                                        deviceIDs: ["A"], runner: ProcessRunner(), now: tweakNow).package
        try await lib.replaceTweak(v1.id, with: v2, recordID: rec.id)
        #expect(try await record(lib).installations.first { $0.deviceID == "B" }?.tweaks == [TweakUse(id: v2.id, enabled: false, removedDependency: "Cephei")])
        var v3 = try await stage(try await tweakDeb(in: tmp, version: "3.0", payload: "newer"), in: tmp)
        v3.replacing = v2.id
        _ = try await lib.adoptTweaks([v3], recordID: rec.id)
        #expect(try await record(lib).installations.first { $0.deviceID == "B" }?.tweaks == [TweakUse(id: v3.package.id, enabled: false, removedDependency: "Cephei")])
    }

    @Test func aStagedTweakThatIsNotAPackageFolderIsRefused() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec) = try await library(tmp, devices: ["A"])
        let good = try await stage(try tweakDylib(in: tmp), in: tmp)
        var badID = good
        badID.package = TweakPackage(id: "../../escape", kind: .dylib, origin: .added, packageID: good.package.packageID,
                                     name: "Escape", files: good.package.files, binaries: good.package.binaries, addedAt: tweakNow)
        await #expect(throws: (any Error).self) { _ = try await lib.adoptTweaks([badID], recordID: rec.id) }
        var missing = good
        missing.directory = tmp.appendingPathComponent("nothing-here")
        await #expect(throws: (any Error).self) { _ = try await lib.adoptTweaks([missing], recordID: rec.id) }
        // A link instead of a folder.
        let link = tmp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: good.directory)
        var linked = good
        linked.directory = link
        await #expect(throws: (any Error).self) { _ = try await lib.adoptTweaks([linked], recordID: rec.id) }
        let r = try await record(lib)
        #expect(r.tweaks?.isEmpty ?? true)
        #expect(r.installations.first?.tweaks == nil)
        #expect(!exists(lib.tweakDirectory(recordID: rec.id, id: good.package.id)))
        await #expect(throws: XSideError.recordNotFound) { _ = try await lib.adoptTweaks([good], recordID: UUID()) }
    }
}
