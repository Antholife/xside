import Foundation
import Testing
@testable import XSideCore

// Paid developer team: the app keeps iCloud, its identifiers moved to the team (mega review G2).
// Nothing here talks to Apple: what Xcode and the profile answer is faked.

private let team = "PAID123456"
private let original = "com.vendor.app"
private let signed = "com.vendor.app.PAID123456"

private func plist(_ data: Data) -> [String: Any] {
    (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
}

private func profile(_ ents: [String: Any]) -> ProvisioningProfile {
    var all = ents
    all["application-identifier"] = "\(team).\(signed)"
    let data = try! PropertyListSerialization.data(fromPropertyList: all, format: .xml, options: 0)
    return ProvisioningProfile(uuid: "U-1", teamID: team, bundleID: signed, creationDate: Date(),
                               expirationDate: Date().addingTimeInterval(1000), deviceUDIDs: ["UDID-1"], entitlements: data)
}

/// What a paid team's development profile grants an App ID with iCloud (CloudKit, Documents, KVS).
private var paidGrant: [String: Any] { [
    "com.apple.developer.icloud-container-identifiers": ["iCloud.\(signed)", "iCloud.\(signed).com.vendor.shared"],
    "com.apple.developer.icloud-container-development-container-identifiers": ["iCloud.\(signed)"],
    "com.apple.developer.icloud-container-environment": ["Development", "Production"],
    "com.apple.developer.icloud-services": "*",
    "com.apple.developer.ubiquity-container-identifiers": ["iCloud.\(signed)"],
    "com.apple.developer.ubiquity-kvstore-identifier": "\(team).*",
    "keychain-access-groups": ["\(team).*"],
] }

private let appInfo = ICloudAppInfo(declaresICloud: true, linksCloudKit: true,
                                    containers: ["iCloud.\(original)", "iCloud.com.vendor.shared"],
                                    services: ["CloudKit", "CloudDocuments"],
                                    ubiquityContainers: ["iCloud.\(original)"], keyValueStore: true)

@Suite struct ICloudPaidTeamTests {
    // MARK: Paid team

    @Test func aPaidTeamIsOneXcodeSaysIsntFree() {
        let teams: [String: Any] = ["acct": [["teamID": "FREE000001", "isFreeProvisioningTeam": true],
                                             ["teamID": team, "isFreeProvisioningTeam": false]]]
        #expect(EnvironmentProbe.isPaidTeam(teams, teamID: team))
        #expect(!EnvironmentProbe.isPaidTeam(teams, teamID: "FREE000001"))
        // Unknown means free: the behaviour stays the free account's.
        #expect(!EnvironmentProbe.isPaidTeam(teams, teamID: "OTHER00001"))
        #expect(!EnvironmentProbe.isPaidTeam(["acct": [["teamID": team]]], teamID: team))
        #expect(!EnvironmentProbe.isPaidTeam(["acct": [["teamID": team, "isFreeProvisioningTeam": "no"]]], teamID: team))
        #expect(!EnvironmentProbe.isPaidTeam(nil, teamID: team))
        #expect(!EnvironmentProbe.isPaidTeam("garbage", teamID: team))
        // Listed twice (two accounts), once as free: free wins.
        let both: [String: Any] = ["a": [["teamID": team, "isFreeProvisioningTeam": false]],
                                   "b": [["teamID": team, "isFreeProvisioningTeam": true]]]
        #expect(!EnvironmentProbe.isPaidTeam(both, teamID: team))
    }

    @Test func theEnvironmentSaysWhetherItsTeamIsPaid() async {
        func probe(_ free: Bool?) async -> SigningEnvironment? {
            let r = FakeRunner()
            r.stub("/usr/bin/xcode-select", result: CommandResult(status: 0, stdout: Data("/X\n".utf8), stderr: ""))
            r.stub("/usr/bin/security", result: CommandResult(status: 0, stdout: Data(
                "  1) 3F2A9C0B7D1E4F5A6B8C9D0E1F2A3B4C5D6E7F80 \"Apple Development: x@y.z (LL6YVU88MW)\"\n".utf8), stderr: ""))
            r.stub("/bin/sh", firstArg: "-c", result: CommandResult(status: 0, stdout: Data("subject=OU=\(team), O=Me\n".utf8), stderr: ""))
            let result = await EnvironmentProbe(runner: r, fileExists: { _ in true },
                                                xcodeAccounts: { ["IDE.Identifiers.Prod": [["identifier": "x"]]] },
                                                xcodeTeams: {
                                                    free.map { ["acct": [["teamID": team, "isFreeProvisioningTeam": $0]]] }
                                                }).detect()
            return try? result.get()
        }
        #expect(await probe(false)?.isPaidTeam == true)
        #expect(await probe(true)?.isPaidTeam == false)
        #expect(await probe(nil)?.isPaidTeam == false)
    }

    // MARK: What is asked for

    @Test func theAppsIdentifiersMoveToTheTeam() throws {
        let r = try #require(ICloudPaidTeam.request(app: appInfo, originalBundleID: original, bundleID: signed, teamID: team))
        #expect(r.containers == ["iCloud.\(signed)", "iCloud.\(signed).com.vendor.shared"])
        #expect(r.ubiquityContainers == ["iCloud.\(signed)"])
        #expect(r.services == ["CloudKit", "CloudDocuments"])
        #expect(r.keyValueStore == "\(team).\(signed)")
        let ents = r.templateEntitlements
        #expect(ents["com.apple.developer.icloud-container-identifiers"] as? [String] == r.containers)
        #expect(ents["com.apple.developer.icloud-services"] as? [String] == ["CloudKit", "CloudDocuments"])
        #expect(ents["com.apple.developer.ubiquity-container-identifiers"] as? [String] == r.ubiquityContainers)
        #expect(ents["com.apple.developer.ubiquity-kvstore-identifier"] as? String == r.keyValueStore)
        // A container of the original's own namespace stays in the app's own.
        let sub = ICloudAppInfo(declaresICloud: true, containers: ["iCloud.\(original).beta"], services: ["CloudKit"])
        #expect(ICloudPaidTeam.request(app: sub, originalBundleID: original, bundleID: signed, teamID: team)?.containers
                == ["iCloud.\(signed).beta"])
    }

    @Test func nothingIsAskedForAnAppWithoutICloud() {
        #expect(ICloudPaidTeam.request(app: nil, originalBundleID: original, bundleID: signed, teamID: team) == nil)
        #expect(ICloudPaidTeam.request(app: ICloudAppInfo(declaresICloud: false, linksCloudKit: true),
                                       originalBundleID: original, bundleID: signed, teamID: team) == nil)
        // Declared, but nothing usable (a record from an older XSide, or stripped values).
        #expect(ICloudPaidTeam.request(app: ICloudAppInfo(declaresICloud: true),
                                       originalBundleID: original, bundleID: signed, teamID: team) == nil)
    }

    @Test func servicesFollowWhatIsKept() throws {
        // A record imported before the services were read: CloudKit when it has containers.
        let older = ICloudAppInfo(declaresICloud: true, containers: ["iCloud.\(original)"])
        let r = try #require(ICloudPaidTeam.request(app: older, originalBundleID: original, bundleID: signed, teamID: team))
        #expect(r.services == ["CloudKit"] && r.keyValueStore == nil && r.ubiquityContainers.isEmpty)
        // Documents without a ubiquity container, unknown services: dropped.
        let odd = ICloudAppInfo(declaresICloud: true, containers: ["iCloud.\(original)"],
                                services: ["CloudDocuments", "Bogus", "CloudKit", "CloudKit"])
        #expect(ICloudPaidTeam.request(app: odd, originalBundleID: original, bundleID: signed, teamID: team)?.services == ["CloudKit"])
        // Key-value store only.
        let kvs = ICloudAppInfo(declaresICloud: true, keyValueStore: true)
        let k = try #require(ICloudPaidTeam.request(app: kvs, originalBundleID: original, bundleID: signed, teamID: team))
        #expect(k.containers.isEmpty && k.services.isEmpty && k.keyValueStore == "\(team).\(signed)")
    }

    @Test func neverAnotherAppsContainer() {
        // A crafted .ipa naming another XSide app's container, or one shaped like a future one's.
        let hostile = ICloudAppInfo(declaresICloud: true,
                                    containers: ["iCloud.\(original)", "iCloud.evil.\(team)", "iCloud.x.\(team).y",
                                                 "iCloud.*", "iCloud.$(CFBundleIdentifier)", "iCloud.",
                                                 "iCloud." + String(repeating: "a", count: 250)],
                                    services: ["CloudKit"])
        let r = ICloudPaidTeam.request(app: hostile, originalBundleID: original, bundleID: signed, teamID: team,
                                       otherBundleIDs: ["\(signed).other"])
        #expect(r?.containers == ["iCloud.\(signed)"])
        // The app's own container is taken by another XSide app: not granted.
        let clash = ICloudAppInfo(declaresICloud: true, containers: ["iCloud.\(original)", "iCloud.other"], services: ["CloudKit"])
        let c = ICloudPaidTeam.request(app: clash, originalBundleID: original, bundleID: signed, teamID: team,
                                       otherBundleIDs: [signed, "\(signed).other"])
        #expect(c?.containers == nil)
    }

    // MARK: What is signed

    @Test func signingKeepsWhatTheProfileGrants() throws {
        let r = try #require(ICloudPaidTeam.request(app: appInfo, originalBundleID: original, bundleID: signed, teamID: team))
        let ents = plist(try Resigner.signingEntitlements(profile: profile(paidGrant), bundleID: signed, iCloud: r))
        #expect(ents["com.apple.developer.icloud-container-identifiers"] as? [String] == r.containers)
        #expect(ents["com.apple.developer.icloud-services"] as? [String] == ["CloudKit", "CloudDocuments"])
        #expect(ents["com.apple.developer.ubiquity-container-identifiers"] as? [String] == ["iCloud.\(signed)"])
        #expect(ents["com.apple.developer.ubiquity-kvstore-identifier"] as? String == "\(team).\(signed)")
        #expect(ents["com.apple.developer.icloud-container-environment"] as? String == "Development")
        // Profile-only keys never reach the app.
        #expect(ents["com.apple.developer.icloud-container-development-container-identifiers"] == nil)
        // The rest as before.
        #expect(ents["keychain-access-groups"] as? [String] == ["\(team).\(signed)"])
        #expect(ents["application-identifier"] as? String == "\(team).\(signed)")
    }

    @Test func whatTheProfileDoesntGrantIsLeftOut() throws {
        let r = try #require(ICloudPaidTeam.request(app: appInfo, originalBundleID: original, bundleID: signed, teamID: team))
        // Only the main container, CloudKit only, no key-value store.
        let partial: [String: Any] = [
            "com.apple.developer.icloud-container-identifiers": ["iCloud.\(signed)"],
            "com.apple.developer.icloud-services": ["CloudKit"],
        ]
        let ents = plist(try Resigner.signingEntitlements(profile: profile(partial), bundleID: signed, iCloud: r))
        #expect(ents["com.apple.developer.icloud-container-identifiers"] as? [String] == ["iCloud.\(signed)"])
        #expect(ents["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"])
        #expect(ents["com.apple.developer.ubiquity-container-identifiers"] == nil)
        #expect(ents["com.apple.developer.ubiquity-kvstore-identifier"] == nil)
        // Nothing granted (Xcode couldn't add the capability): signed without iCloud.
        let none = plist(try Resigner.signingEntitlements(profile: profile([:]), bundleID: signed, iCloud: r))
        for key in ICloudSignedOut.entitlementKeys + ["com.apple.developer.icloud-container-environment"] {
            #expect(none[key] == nil)
        }
        // Hostile profile values (wrong types) grant nothing.
        let wrong: [String: Any] = ["com.apple.developer.icloud-container-identifiers": "iCloud.\(signed)",
                                    "com.apple.developer.icloud-services": 3,
                                    "com.apple.developer.ubiquity-kvstore-identifier": ["\(team).*"]]
        let w = plist(try Resigner.signingEntitlements(profile: profile(wrong), bundleID: signed, iCloud: r))
        for key in ICloudSignedOut.entitlementKeys { #expect(w[key] == nil) }
    }

    @Test func withoutARequestICloudKeysNeverPassThrough() throws {
        // A paid App ID that had iCloud before, signing an app that no longer asks for it.
        let ents = plist(try Resigner.signingEntitlements(profile: profile(paidGrant), bundleID: signed))
        for key in ICloudSignedOut.entitlementKeys + ["com.apple.developer.icloud-container-environment",
                                                      "com.apple.developer.icloud-container-development-container-identifiers"] {
            #expect(ents[key] == nil)
        }
    }

    @Test func theAppInfoReadsServicesAndStores() throws {
        let ents: [String: Any] = [
            "com.apple.developer.icloud-container-identifiers": ["iCloud.\(original)"],
            "com.apple.developer.icloud-services": ["CloudKit", 4, "CloudDocuments"],
            "com.apple.developer.ubiquity-container-identifiers": ["iCloud.\(original)", "*"],
            "com.apple.developer.ubiquity-kvstore-identifier": "$(TeamIdentifierPrefix)\(original)",
        ]
        let info = ICloudAppInfo.read(executable: URL(fileURLWithPath: "/nonexistent"), entitlements: ents)
        #expect(info.services == ["CloudKit", "CloudDocuments"])
        #expect(info.ubiquityContainers == ["iCloud.\(original)"])
        #expect(info.keyValueStore == true)
        let star = ICloudAppInfo.read(executable: URL(fileURLWithPath: "/nonexistent"),
                                      entitlements: ["com.apple.developer.icloud-services": "*"])
        #expect(star.services == ["CloudKit", "CloudDocuments"] && star.keyValueStore == false)
        // A record written before these fields: they decode as unknown.
        let old = try JSONDecoder().decode(ICloudAppInfo.self, from: Data(
            #"{"declaresICloud":true,"linksCloudKit":false,"containers":["iCloud.a"]}"#.utf8))
        #expect(old.services == nil && old.ubiquityContainers == nil && old.keyValueStore == nil)
    }

    // MARK: Provisioning

    @Test func theTemplateAsksForICloud() async throws {
        let fm = FileManager.default
        let root = TestTemp.root.appendingPathComponent("xside-paid-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let template = root.appendingPathComponent("template"), work = root.appendingPathComponent("work")
        try fm.createDirectory(at: template.appendingPathComponent("XSideTemplate.xcodeproj"), withIntermediateDirectories: true)
        let runner = TemplateRunner(profile: profile(paidGrant), failFirst: false)
        let r = try #require(ICloudPaidTeam.request(app: appInfo, originalBundleID: original, bundleID: signed, teamID: team))
        let p = Provisioner(runner: runner, templateDir: template, workDir: work, cacheDirs: [])
        let env = SigningEnvironment(developerDir: URL(fileURLWithPath: "/X"), identitySHA1: "A", identityName: "N",
                                     teamID: team, isPaidTeam: true)
        _ = try await p.profile(bundleID: signed, env: env, deviceUDIDs: ["UDID-1"], iCloud: r)
        let builds = runner.builds
        #expect(builds.count == 1)
        let setting = try #require(builds.first?.args.first { $0.hasPrefix("CODE_SIGN_ENTITLEMENTS=") })
        #expect(setting.hasSuffix(".entitlements"))
        let written = try #require(builds.first?.entitlements)
        #expect(written["com.apple.developer.icloud-container-identifiers"] as? [String] == r.containers)
        #expect(written["com.apple.developer.ubiquity-kvstore-identifier"] as? String == "\(team).\(signed)")
        // Without a request: the arguments as always.
        _ = try await p.profile(bundleID: signed, env: env, deviceUDIDs: ["UDID-1"], iCloud: nil)
        #expect(runner.builds.count == 2)
        #expect(runner.builds[1].args.allSatisfy { !$0.hasPrefix("CODE_SIGN_ENTITLEMENTS=") })
    }

    @Test func aRefusedICloudBuildIsRetriedWithout() async throws {
        let fm = FileManager.default
        let root = TestTemp.root.appendingPathComponent("xside-paid-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let template = root.appendingPathComponent("template"), work = root.appendingPathComponent("work")
        try fm.createDirectory(at: template.appendingPathComponent("XSideTemplate.xcodeproj"), withIntermediateDirectories: true)
        let runner = TemplateRunner(profile: profile([:]), failFirst: true)
        let r = try #require(ICloudPaidTeam.request(app: appInfo, originalBundleID: original, bundleID: signed, teamID: team))
        let p = Provisioner(runner: runner, templateDir: template, workDir: work, cacheDirs: [])
        let env = SigningEnvironment(developerDir: URL(fileURLWithPath: "/X"), identitySHA1: "A", identityName: "N",
                                     teamID: team, isPaidTeam: true)
        let result = try await p.profile(bundleID: signed, env: env, deviceUDIDs: ["UDID-1"], iCloud: r)
        #expect(result.profile.uuid == "U-1")
        #expect(runner.builds.count == 2)
        #expect(runner.builds[0].args.contains { $0.hasPrefix("CODE_SIGN_ENTITLEMENTS=") })
        #expect(runner.builds[1].args.allSatisfy { !$0.hasPrefix("CODE_SIGN_ENTITLEMENTS=") })
    }
}

/// xcodebuild writes `profile` as the produced profile (and records the entitlements file it was
/// given); `security cms` returns the file's bytes. `failFirst`: the first build fails as Xcode
/// does when the team can't have a capability.
private final class TemplateRunner: CommandRunning, @unchecked Sendable {
    struct Build { let args: [String]; let entitlements: [String: Any]? }
    private let lock = NSLock()
    private var log: [Build] = []
    private var failNext: Bool
    let profileData: Data

    init(profile: ProvisioningProfile, failFirst: Bool) {
        var root: [String: Any] = ["UUID": profile.uuid, "TeamIdentifier": [profile.teamID],
                                   "CreationDate": profile.creationDate, "ExpirationDate": profile.expirationDate,
                                   "ProvisionedDevices": profile.deviceUDIDs]
        root["Entitlements"] = plist(profile.entitlements)
        profileData = try! PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        failNext = failFirst
    }

    var builds: [Build] { lock.withLock { log } }

    func run(_ executable: String, _ arguments: [String], cwd: URL?, timeout: Duration) async throws -> CommandResult {
        if executable == "/usr/bin/security", let path = arguments.last {
            return CommandResult(status: 0, stdout: FileManager.default.contents(atPath: path) ?? Data(), stderr: "")
        }
        guard arguments.first == "xcodebuild", let i = arguments.firstIndex(of: "-derivedDataPath") else {
            throw FakeRunnerError(command: [executable] + arguments)
        }
        let ents = arguments.first { $0.hasPrefix("CODE_SIGN_ENTITLEMENTS=") }
            .flatMap { FileManager.default.contents(atPath: String($0.dropFirst("CODE_SIGN_ENTITLEMENTS=".count))) }
            .map(plist)
        let fail: Bool = lock.withLock {
            log.append(Build(args: arguments, entitlements: ents))
            defer { failNext = false }
            return failNext
        }
        if fail {
            return CommandResult(status: 65, stdout: Data(
                "error: Personal development teams do not support the iCloud capability. (in target 'XSideTemplate')\n".utf8), stderr: "")
        }
        let app = URL(fileURLWithPath: arguments[i + 1]).appendingPathComponent("Build/Products/Debug-iphoneos/XSideTemplate.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try profileData.write(to: app.appendingPathComponent("embedded.mobileprovision"))
        return CommandResult(status: 0, stdout: Data(), stderr: "")
    }
}
