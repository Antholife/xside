import Testing
import Foundation
@testable import XSideCore

private func plist(team: String, bundle: String, uuid: String = UUID().uuidString,
                   created: Date, expires: Date? = nil, devices: [String] = ["U1"]) -> Data {
    let dict: [String: Any] = [
        "UUID": uuid,
        "TeamIdentifier": [team],
        "CreationDate": created,
        "ExpirationDate": expires ?? created.addingTimeInterval(7 * 86_400),
        "ProvisionedDevices": devices,
        "Entitlements": [
            "application-identifier": "\(team).\(bundle)",
            "get-task-allow": true,
        ] as [String: Any],
    ]
    return try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
}

private func profile(_ team: String, _ bundle: String, daysAgo: Double, now: Date) throws -> ProvisioningProfile {
    try ProvisioningProfile.parse(plist: plist(team: team, bundle: bundle,
                                               created: now.addingTimeInterval(-daysAgo * 86_400)))
}

@Suite struct ProfileTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func parsesProfilePlist() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let expires = Date(timeIntervalSince1970: 1_700_600_000)
        let p = try ProvisioningProfile.parse(plist: plist(team: "T1", bundle: "com.a.b", uuid: "U-1",
                                                           created: created, expires: expires, devices: ["D1", "D2"]))
        #expect(p.uuid == "U-1")
        #expect(p.teamID == "T1")
        #expect(p.bundleID == "com.a.b")
        #expect(p.creationDate == created)
        #expect(p.expirationDate == expires)
        #expect(p.deviceUDIDs == ["D1", "D2"])
        let ents = try PropertyListSerialization.propertyList(from: p.entitlements, format: nil) as? [String: Any]
        #expect(ents?["application-identifier"] as? String == "T1.com.a.b")
        #expect(String(decoding: p.entitlements, as: UTF8.self).contains("<?xml"))
    }

    @Test func parseRejectsGarbage() {
        #expect(throws: (any Error).self) { try ProvisioningProfile.parse(plist: Data("nope".utf8)) }
    }

    @Test func countsDistinctRecentAppIDs() throws {
        let ps = [
            try profile("T1", "com.a", daysAgo: 1, now: now),
            try profile("T1", "com.a", daysAgo: 2, now: now),
            try profile("T1", "com.b", daysAgo: 3, now: now),
            try profile("T1", "com.old", daysAgo: 8, now: now),
            try profile("T2", "com.c", daysAgo: 1, now: now),
        ]
        #expect(AppIDCounter.remaining(ps, teamID: "T1", now: now) == 8)
    }

    @Test func remainingNeverNegative() throws {
        let ps = try (0..<12).map { try profile("T1", "com.app\($0)", daysAgo: 1, now: now) }
        #expect(AppIDCounter.remaining(ps, teamID: "T1", now: now) == 0)
    }

    @Test func firstCreationCounts() throws {
        let ps = [
            try profile("T1", "com.a", daysAgo: 8, now: now),
            try profile("T1", "com.a", daysAgo: 1, now: now),
        ]
        #expect(AppIDCounter.remaining(ps, teamID: "T1", now: now) == 10)
    }

    @Test func wildcardsExcluded() throws {
        let ps = [try profile("T1", "*", daysAgo: 1, now: now)]
        #expect(ps[0].bundleID == "*")
        #expect(AppIDCounter.remaining(ps, teamID: "T1", now: now) == 10)
    }

    @Test func longKnownXSideAppIDsExcluded() throws {
        let ps = [
            // Re-provisioned yesterday after the cache purge, but XSide first used it 10 days ago.
            try profile("T1", "com.renewed.T1", daysAgo: 1, now: now),
            // XSide app first installed 2 days ago: its App ID is still within the week.
            try profile("T1", "com.recent.T1", daysAgo: 1, now: now),
            // Not an XSide app: counted on its profile date as before.
            try profile("T1", "com.other", daysAgo: 1, now: now),
        ]
        let firstUse: [String: Date] = [
            "com.renewed.T1": now.addingTimeInterval(-10 * 86_400),
            "com.recent.T1": now.addingTimeInterval(-2 * 86_400),
            "com.not-cached.T1": now.addingTimeInterval(-1 * 86_400),
        ]
        #expect(AppIDCounter.remaining(ps, teamID: "T1", now: now) == 7)
        #expect(AppIDCounter.remaining(ps, teamID: "T1", now: now, firstUse: firstUse) == 8)
    }

    @Test func firstUsesMergesRecords() {
        func record(_ signed: String, firstUse: [String: Date]?, installedDaysAgo: [Double]) -> AppRecord {
            var r = AppRecord(id: UUID(), displayName: "X", originalBundleID: "com.x", signedBundleID: signed,
                              ipaPath: "a", options: InstallOptions(), installations: [], teamID: "T1")
            r.installations = installedDaysAgo.enumerated().map { i, d in
                Installation(deviceID: "d\(i)", installedAt: now.addingTimeInterval(-d * 86_400), expiresAt: now)
            }
            r.appIDFirstUse = firstUse
            return r
        }
        let uses = AppIDCounter.firstUses([
            record("com.a.T1", firstUse: ["com.a.T1": now.addingTimeInterval(-9 * 86_400),
                                          "com.old.T1": now.addingTimeInterval(-20 * 86_400)],
                   installedDaysAgo: [0]),
            // Legacy record (no first-use dates): earliest installation.
            record("com.legacy.T1", firstUse: nil, installedDaysAgo: [3, 5]),
            record("com.none.T1", firstUse: nil, installedDaysAgo: []),
        ])
        #expect(uses == [
            "com.a.T1": now.addingTimeInterval(-9 * 86_400),
            "com.old.T1": now.addingTimeInterval(-20 * 86_400),
            "com.legacy.T1": now.addingTimeInterval(-5 * 86_400),
        ])
    }

    @Test func readerRunsSecurityCMS() async throws {
        let runner = FakeRunner()
        let data = plist(team: "T1", bundle: "com.a.b", created: now)
        runner.stub("/usr/bin/security", firstArg: "cms", result: CommandResult(status: 0, stdout: data, stderr: ""))
        let url = URL(fileURLWithPath: "/x/p.mobileprovision")
        let p = try await ProfileReader(runner: runner).read(url)
        #expect(p.bundleID == "com.a.b")
        #expect(runner.calls == [["/usr/bin/security", "cms", "-D", "-i", "/x/p.mobileprovision"]])
    }

    @Test func scanToleratesMissingDirsAndBadFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xside-prof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.mobileprovision"))
        try Data().write(to: dir.appendingPathComponent("b.mobileprovision"))
        try Data().write(to: dir.appendingPathComponent("c.txt"))
        let good = plist(team: "T1", bundle: "com.a.b", created: now)
        let runner = FakeRunner()
        runner.stub("/usr/bin/security", firstArg: "cms", result: CommandResult(status: 0, stdout: good, stderr: ""))
        let missing = dir.appendingPathComponent("nope")
        let found = await ProfileReader(runner: runner).scan([missing, dir])
        #expect(found.count == 2)
        #expect(runner.calls.count == 2)
    }
}

struct AppIDReleaseTests {
    @Test func eachUsedAppIDFreesUpAWeekAfterItsFirstUse() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func profile(_ id: String, daysAgo: Double) -> ProvisioningProfile {
            ProvisioningProfile(uuid: UUID().uuidString, teamID: "T1", bundleID: id,
                                creationDate: now.addingTimeInterval(-daysAgo * 86_400),
                                expirationDate: now.addingTimeInterval(7 * 86_400), deviceUDIDs: [], entitlements: Data())
        }
        let profiles = [profile("a", daysAgo: 1), profile("a", daysAgo: 6), profile("b", daysAgo: 3), profile("c", daysAgo: 8)]
        let releases = AppIDCounter.releases(profiles, teamID: "T1", now: now)
        // "a" counts from its oldest profile (6 days ago); "c" is already free.
        #expect(releases == [now.addingTimeInterval(86_400), now.addingTimeInterval(4 * 86_400)])
        #expect(AppIDCounter.remaining(profiles, teamID: "T1", now: now) == 8)
    }
}
