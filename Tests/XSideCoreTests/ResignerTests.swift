import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import XSideCore

private let team = "TEAM123456"
private let ok = CommandResult(status: 0, stdout: Data(), stderr: "")

private func tempDir(_ name: String) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("xside-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func makeProfile() -> ProvisioningProfile {
    let ents: [String: Any] = ["application-identifier": "\(team).com.example.new",
                               "com.apple.security.application-groups": ["group.x"]]
    let data = try! PropertyListSerialization.data(fromPropertyList: ents, format: .xml, options: 0)
    return ProvisioningProfile(uuid: "U-1", teamID: team, bundleID: "com.example.new",
                               creationDate: Date(), expirationDate: Date().addingTimeInterval(1000),
                               deviceUDIDs: [], entitlements: data)
}

private struct Fixture {
    let work: URL, ipa: URL, profileURL: URL
    let fake: FakeRunner
    var welcomeDylib: URL?
    var settings: (@Sendable (ProvisioningProfile, InstallationFacts?) -> SettingsSection)?
    var payload: WelcomePayload?
    var resigner: Resigner {
        let payload = payload
        return Resigner(runner: RoutingRunner(fake: fake), welcomeDylib: welcomeDylib, settingsSection: settings,
                        welcome: { _ in payload })
    }
}

/// A stand-in for XSideWelcome.dylib (its content isn't read, only copied).
private func welcomeDylib() throws -> URL {
    let url = try tempDir("welcome").appendingPathComponent("XSideWelcome.dylib")
    try Data("WELCOME".utf8).write(to: url)
    return url
}

private let welcomePath = "@executable_path/Frameworks/XSideWelcome.dylib"

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int?
    func set(_ v: Int) { lock.lock(); count = v; lock.unlock() }
    var value: Int? { lock.lock(); defer { lock.unlock() }; return count }
}

private func fixture(encrypted: Bool = false, extensions: [String] = ["PlugIns", "Extensions", "Watch"],
                     withIcons: Bool = false, appName: String = "Demo", work: URL? = nil,
                     executable: Data? = nil,
                     prepare: (URL) throws -> Void = { _ in }) async throws -> Fixture {
    let src = try tempDir("src")
    let app = try FakeIPA.makeApp(at: src, name: appName, extensions: extensions, encrypted: encrypted,
                                  executableData: executable)
    try prepare(app)
    if withIcons { try addAssetCatalogIcons(app) }
    // stale signatures
    for dir in [app, app.appendingPathComponent("Frameworks/X.framework")] {
        let cs = dir.appendingPathComponent("_CodeSignature")
        try FileManager.default.createDirectory(at: cs, withIntermediateDirectories: true)
        try Data("sig".utf8).write(to: cs.appendingPathComponent("CodeResources"))
    }
    try Data("dylib".utf8).write(to: app.appendingPathComponent("Frameworks/X.framework/inner.dylib"))
    try Data("dylib".utf8).write(to: app.appendingPathComponent("libtop.dylib"))
    let out = try tempDir("ipa")
    let ipa = out.appendingPathComponent("Demo.ipa")
    let r = try await ProcessRunner().run("/usr/bin/ditto",
        ["-c", "-k", "--sequesterRsrc", "--keepParent", src.appendingPathComponent("Payload").path, ipa.path], cwd: nil)
    #expect(r.status == 0)
    let profileURL = out.appendingPathComponent("p.mobileprovision")
    try Data("PROFILE-BYTES".utf8).write(to: profileURL)
    let fake = FakeRunner()
    fake.stub("/usr/bin/codesign", result: ok)
    return Fixture(work: try work ?? tempDir("work"), ipa: ipa, profileURL: profileURL, fake: fake)
}

private func run(_ f: Fixture, options: InstallOptions = InstallOptions(), iconURL: URL? = nil,
                 facts: InstallationFacts? = nil) async throws -> URL {
    try await f.resigner.resign(ipa: f.ipa, workDir: f.work, bundleID: "com.example.new", options: options,
                                iconURL: iconURL, profileURL: f.profileURL, profile: makeProfile(), identitySHA1: "FAKESHA1",
                                facts: facts)
}

private func plist(_ app: URL) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(
        from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil) as! [String: Any]
}

@Suite struct ResignerTests {
    @Test func injectsWelcomeDylibWhenOn() async throws {
        var f = try await fixture(executable: FakeIPA.paddedMachO(padding: 256))
        f.welcomeDylib = try welcomeDylib()
        let app = try await run(f)
        let copied = app.appendingPathComponent("Frameworks/XSideWelcome.dylib")
        #expect(try Data(contentsOf: copied) == Data("WELCOME".utf8))
        let executable = try Data(contentsOf: app.appendingPathComponent("Demo"))
        #expect(executable.range(of: Data(welcomePath.utf8)) != nil)
        let targets = f.fake.calls.map { $0.last! }
        #expect(targets.firstIndex(of: copied.path)! < targets.firstIndex(of: app.path)!)
    }

    @Test func addsTheXSideSectionToTheSettingsPage() async throws {
        var f = try await fixture(executable: FakeIPA.paddedMachO(padding: 256))
        f.welcomeDylib = try welcomeDylib()
        f.settings = { profile, _ in
            SettingsSection(titleKey: "t", footerKey: nil,
                            rows: [.value(titleKey: "v", key: "validUntil", defaultValue: profile.uuid)],
                            strings: ["fr": ["t": "Installée avec XSide", "v": "Valable jusqu'au"]])
        }
        let app = try await run(f)
        let data = try Data(contentsOf: app.appendingPathComponent("Settings.bundle/Root.plist"))
        let root = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let items = try #require(root["PreferenceSpecifiers"] as? [[String: Any]])
        #expect(items.map { $0["Title"] as? String } == [nil, "v"]) // XSide's own page: iOS titles it

        #expect(items[1]["DefaultValue"] as? String == "U-1") // built from the profile it's signed with
    }

    /// "YouTube +" as CFBundleName: iOS refuses the app notifications. The shown name stays.
    @Test func specialCharactersLeaveTheBundleName() async throws {
        let f = try await fixture { app in
            let url = app.appendingPathComponent("Info.plist")
            var plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
            plist["CFBundleName"] = "Demo +"
            plist["CFBundleDisplayName"] = nil
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
            let fr = app.appendingPathComponent("fr.lproj")
            try FileManager.default.createDirectory(at: fr, withIntermediateDirectories: true)
            let text = [#""CFBundleName" = "Démo +";"#, #""NSCameraUsageDescription" = "Caméra";"#].joined(separator: "\n")
            try Data(text.utf8)
                .write(to: fr.appendingPathComponent("InfoPlist.strings"))
        }
        let app = try await run(f)
        let info = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil) as? [String: Any])
        #expect(info["CFBundleName"] as? String == "Demo")
        #expect(info["CFBundleDisplayName"] as? String == "Demo +")
        let strings = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: app.appendingPathComponent("fr.lproj/InfoPlist.strings")), format: nil) as? [String: String])
        #expect(strings["CFBundleName"] == "Demo")
        #expect(strings["CFBundleDisplayName"] == "Démo +")
        #expect(strings["NSCameraUsageDescription"] == "Caméra")
    }

    private static let when = Date(timeIntervalSince1970: 1_800_000_000)
    private static func payload() -> WelcomePayload {
        let inApp = InAppSettings.defaults(reminder: false, at: when)
            .setting(\.language, to: .fr, at: when.addingTimeInterval(60), by: .device)
        return WelcomePayload(thresholdHours: 72, reminderLeadHours: 12, inApp: inApp,
                              installationID: "rec-1|dev-1", channelSecret: Data(repeating: 7, count: 32),
                              installedAt: when.addingTimeInterval(-86_400))
    }

    /// What the dylib reads at launch (keys documented on `WelcomePayload`).
    @Test func payloadIsWrittenForTheDylib() async throws {
        var f = try await fixture(executable: FakeIPA.paddedMachO(padding: 256))
        f.welcomeDylib = try welcomeDylib()
        f.payload = Self.payload()
        let app = try await run(f)
        let info = try plist(app)
        let welcome = try #require(info["XSideWelcome"] as? [String: Any])
        #expect(welcome["thresholdHours"] as? Int == 72)
        #expect(welcome["reminderLeadHours"] as? Int == 12)
        #expect(welcome["reminder"] as? Int == 0)
        #expect(welcome["installationID"] as? String == "rec-1|dev-1")
        #expect(welcome["channelSecret"] as? Data == Data(repeating: 7, count: 32))
        #expect(welcome["installedAt"] as? Date == Self.when.addingTimeInterval(-86_400))
        let settings = try #require(welcome["settings"] as? [String: [String: Any]])
        #expect(Set(settings.keys) == ["level", "showValidity", "alertLate", "refreshCard", "reminder", "language", "autoRefresh"])
        #expect(settings["level"]?["value"] as? String == "all")
        #expect(settings["reminder"]?["value"] as? Bool == false)
        #expect(settings["showValidity"]?["changedBy"] as? String == "mac")
        #expect(settings["language"]?["value"] as? String == "fr")
        #expect(settings["language"]?["changedBy"] as? String == "device")
        #expect(settings["language"]?["changedAt"] as? Date == Self.when.addingTimeInterval(60))
    }

    /// The installation's own values replace whatever the Mac-wide payload carried, so the secret
    /// in the app is always the one the pipeline stores.
    @Test func installationFactsGoIntoThePayloadAndTheSection() async throws {
        var f = try await fixture(executable: FakeIPA.paddedMachO(padding: 256))
        f.welcomeDylib = try welcomeDylib()
        f.payload = WelcomePayload(thresholdHours: 72, reminderLeadHours: 12,
                                   inApp: InAppSettings.defaults(reminder: true, at: Self.when))
        let inApp = InAppSettings.defaults(reminder: false, at: Self.when)
        let facts = InstallationFacts(installationID: "rec-9|dev-9", channelSecret: Data(repeating: 9, count: 32),
                                      inApp: inApp, firstInstalledAt: Self.when.addingTimeInterval(-500),
                                      appVersion: "4.2", lastRefreshOutcome: nil, lastCheckIn: nil,
                                      signedAt: Self.when.addingTimeInterval(30))
        f.settings = { _, facts in
            SettingsSection(titleKey: "t", footerKey: nil,
                            rows: [.value(titleKey: "v", key: "version", defaultValue: facts?.appVersion ?? "none")],
                            strings: [:])
        }
        let app = try await run(f, facts: facts)
        let welcome = try #require(try plist(app)["XSideWelcome"] as? [String: Any])
        #expect(welcome["thresholdHours"] as? Int == 72)
        #expect(welcome["installationID"] as? String == "rec-9|dev-9")
        #expect(welcome["channelSecret"] as? Data == Data(repeating: 9, count: 32))
        #expect(welcome["installedAt"] as? Date == Self.when.addingTimeInterval(-500))
        #expect(welcome["signedAt"] as? Date == Self.when.addingTimeInterval(30)) // "Rafraîchie le" on the phone
        #expect(welcome["reminder"] as? Int == 0)
        let data = try Data(contentsOf: app.appendingPathComponent("Settings.bundle/Root.plist"))
        let root = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let items = try #require(root["PreferenceSpecifiers"] as? [[String: Any]])
        #expect(items.last?["DefaultValue"] as? String == "4.2")
    }

    /// The section's switches mean nothing without the library that reads them.
    @Test func noSettingsSectionWithoutTheDylib() async throws {
        var f = try await fixture()
        f.settings = { _, _ in SettingsSection.xside(validUntil: "a", refreshedOn: "b", version: "1", installedOn: "c") }
        let app = try await run(f)
        #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Settings.bundle").path))
    }

    @Test func noPayloadMeansNoXSideWelcomeKey() async throws {
        let f = try await fixture()
        let info = try plist(try await run(f))
        #expect(info["XSideWelcome"] == nil)
    }

    @Test func infoPlistGetsBonjourUsageAndShortcutsWithTheDylib() async throws {
        var f = try await fixture(executable: FakeIPA.paddedMachO(padding: 256))
        f.welcomeDylib = try welcomeDylib()
        let app = try await run(f)
        let info = try plist(app)
        #expect(info["NSBonjourServices"] as? [String] == ["_xside._tcp"])
        #expect(info["NSLocalNetworkUsageDescription"] as? String == "XSide asks your Mac to refresh this app.")
        #expect((info["UIApplicationShortcutItems"] as? [[String: Any]])?.count == 3)
        let fr = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: app.appendingPathComponent("fr.lproj/InfoPlist.strings")), format: nil) as? [String: String])
        #expect(fr["NSLocalNetworkUsageDescription"] == "XSide demande à ton Mac de rafraîchir cette app.")
    }

    /// Quick actions nothing handles would be a regression: no library, no additions at all.
    @Test func nothingIsAddedWithoutTheDylib() async throws {
        var noLibrary = try await fixture()
        noLibrary.payload = Self.payload()
        var failedCopy = try await fixture(executable: FakeIPA.paddedMachO(padding: 8)) // load command doesn't fit
        failedCopy.welcomeDylib = try welcomeDylib()
        failedCopy.payload = Self.payload()
        for f in [noLibrary, failedCopy] {
            let app = try await run(f)
            let info = try plist(app)
            for key in ["XSideWelcome", "NSBonjourServices", "NSLocalNetworkUsageDescription", "UIApplicationShortcutItems"] {
                #expect(info[key] == nil)
            }
            #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent("fr.lproj/InfoPlist.strings").path))
        }
    }

    @Test func withoutFeaturesTheAppIsLeftAsItCame() async throws {
        let original = FakeIPA.paddedMachO(padding: 256)
        var f = try await fixture(executable: original)
        f.welcomeDylib = try welcomeDylib()
        f.payload = Self.payload()
        f.settings = { _, _ in SettingsSection.xside(validUntil: "a", refreshedOn: "b", version: "1", installedOn: "c") }
        let app = try await run(f, options: InstallOptions(withoutXSideFeatures: true))
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: app.appendingPathComponent("Frameworks/XSideWelcome.dylib").path))
        #expect(!fm.fileExists(atPath: app.appendingPathComponent("Settings.bundle").path))
        #expect(!fm.fileExists(atPath: app.appendingPathComponent("fr.lproj/InfoPlist.strings").path))
        #expect(try Data(contentsOf: app.appendingPathComponent("Demo")) == original)
        let info = try plist(app)
        for key in ["XSideWelcome", "NSBonjourServices", "NSLocalNetworkUsageDescription", "UIApplicationShortcutItems"] {
            #expect(info[key] == nil)
        }
        #expect(info["CFBundleIdentifier"] as? String == "com.example.new") // still re-signed for the new id
        #expect(f.fake.calls.last?.last == app.path)
    }

    @Test func withoutFeaturesDecodesFromOldOptions() throws {
        let old = try JSONDecoder().decode(InstallOptions.self, from: Data(#"{"fileSharing":true}"#.utf8))
        #expect(old.withoutXSideFeatures == false)
        let on = try JSONDecoder().decode(InstallOptions.self, from: Data(#"{"withoutXSideFeatures":true}"#.utf8))
        #expect(on.withoutXSideFeatures)
    }

    @Test func settingsPageProblemsDontFailTheInstall() async throws {
        var f = try await fixture(executable: FakeIPA.paddedMachO(padding: 256)) { app in
            try Data("x".utf8).write(to: app.appendingPathComponent("Settings.bundle"))
        }
        f.welcomeDylib = try welcomeDylib()
        f.settings = { _, _ in SettingsSection(titleKey: "T", footerKey: nil, rows: [], strings: [:]) }
        let app = try await run(f)
        #expect(try Data(contentsOf: app.appendingPathComponent("Settings.bundle")) == Data("x".utf8))
    }

    @Test func announcesSigningAfterTheWelcomeStep() async throws {
        var f = try await fixture(executable: FakeIPA.paddedMachO(padding: 256))
        f.welcomeDylib = try welcomeDylib()
        let calls = f.fake
        let codesignCallsAtSigning = LockedCount()
        _ = try await f.resigner.resign(ipa: f.ipa, workDir: f.work, bundleID: "com.example.new", options: InstallOptions(),
                                        iconURL: nil, profileURL: f.profileURL, profile: makeProfile(),
                                        identitySHA1: "FAKESHA1", onSigning: { codesignCallsAtSigning.set(calls.calls.count) })
        #expect(codesignCallsAtSigning.value == 0) // announced before the first codesign
    }

    @Test func resignWithoutDylibInstallsNormally() async throws {
        let original = FakeIPA.paddedMachO(padding: 256)
        let f = try await fixture(executable: original)
        let app = try await run(f)
        #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Frameworks/XSideWelcome.dylib").path))
        #expect(try Data(contentsOf: app.appendingPathComponent("Demo")) == original)
    }

    @Test func resignSkipsPopupWhenPatchFails() async throws {
        let original = FakeIPA.paddedMachO(padding: 8)
        var f = try await fixture(executable: original)
        f.welcomeDylib = try welcomeDylib()
        let app = try await run(f)
        #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Frameworks/XSideWelcome.dylib").path))
        #expect(try Data(contentsOf: app.appendingPathComponent("Demo")) == original)
        #expect(f.fake.calls.last?.last == app.path) // signed and returned as usual
    }

    @Test func stripsExtensions() async throws {
        let f = try await fixture()
        let app = try await run(f)
        for d in ["PlugIns", "Extensions", "Watch"] {
            #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent(d).path))
        }
    }

    @Test func rewritesBundleID() async throws {
        let app = try await run(try await fixture())
        #expect(try plist(app)["CFBundleIdentifier"] as? String == "com.example.new")
    }

    @Test func keepsBinaryPlistFormat() async throws {
        let app = try await run(try await fixture())
        let head = try Data(contentsOf: app.appendingPathComponent("Info.plist")).prefix(6)
        #expect(String(decoding: head, as: UTF8.self) == "bplist")
    }

    @Test func embedsProfile() async throws {
        let f = try await fixture()
        let app = try await run(f)
        #expect(try Data(contentsOf: app.appendingPathComponent("embedded.mobileprovision"))
                == Data(contentsOf: f.profileURL))
    }

    @Test func removesOldSignatures() async throws {
        let app = try await run(try await fixture())
        let en = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)!
        let left = en.compactMap { ($0 as! URL).lastPathComponent }.filter { $0 == "_CodeSignature" }
        #expect(left.isEmpty)
    }

    @Test func signsInsideOut() async throws {
        let f = try await fixture()
        let app = try await run(f)
        let calls = f.fake.calls
        #expect(calls.count == 4)
        let targets = calls.map { $0.last! }
        let fw = app.appendingPathComponent("Frameworks/X.framework").path
        let inner = app.appendingPathComponent("Frameworks/X.framework/inner.dylib").path
        #expect(targets.last == app.path)
        #expect(targets.firstIndex(of: inner)! < targets.firstIndex(of: fw)!)
        #expect(targets.firstIndex(of: fw)! < targets.count - 1)
        for c in calls {
            #expect(c.starts(with: ["/usr/bin/codesign", "-f", "-s", "FAKESHA1", "--timestamp=none"]))
        }
        #expect(calls.dropLast().allSatisfy { !$0.contains("--entitlements") })
        #expect(calls.last!.contains("--entitlements"))
    }

    @Test func entitlementsComeFromProfile() async throws {
        let f = try await fixture()
        let captured = Captured()
        f.fake.stub("/usr/bin/codesign", result: ok) { args in
            if let i = args.firstIndex(of: "--entitlements") {
                captured.value = try? Data(contentsOf: URL(fileURLWithPath: args[i + 1]))
            }
        }
        _ = try await run(f)
        let d = try #require(captured.value)
        let ents = try #require(try PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any])
        #expect(ents["application-identifier"] as? String == "\(team).com.example.new")
        #expect(ents["com.apple.security.application-groups"] != nil)
    }

    @Test func narrowsWildcardEntitlements() throws {
        let granted: [String: Any] = [
            "application-identifier": "\(team).*",
            "com.apple.developer.team-identifier": team,
            "keychain-access-groups": ["\(team).*"],
            "get-task-allow": true,
            "aps-environment": "development",
            "com.apple.developer.associated-domains": "*",
            "com.apple.developer.icloud-container-identifiers": ["iCloud.*", "iCloud.x"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: granted, format: .xml, options: 0)
        let profile = ProvisioningProfile(uuid: "U", teamID: team, bundleID: "*", creationDate: Date(),
                                          expirationDate: Date(), deviceUDIDs: [], entitlements: data)
        let signed = try #require(try PropertyListSerialization.propertyList(
            from: Resigner.signingEntitlements(profile: profile, bundleID: "com.example.bundle"), format: nil) as? [String: Any])
        #expect(signed["keychain-access-groups"] as? [String] == ["\(team).com.example.bundle"])
        #expect(signed["application-identifier"] as? String == "\(team).com.example.bundle")
        #expect(signed["com.apple.developer.team-identifier"] as? String == team)
        #expect(signed["get-task-allow"] as? Bool == true)
        #expect(signed["aps-environment"] as? String == "development")
        #expect(signed["com.apple.developer.associated-domains"] == nil)
        #expect(signed["com.apple.developer.icloud-container-identifiers"] == nil)
        #expect(signed.count == 5)
    }

    @Test func keepsProfileGetTaskAllowAndDefaultsIt() throws {
        func signed(_ granted: [String: Any]) throws -> [String: Any] {
            let data = try PropertyListSerialization.data(fromPropertyList: granted, format: .xml, options: 0)
            let profile = ProvisioningProfile(uuid: "U", teamID: team, bundleID: "b", creationDate: Date(),
                                              expirationDate: Date(), deviceUDIDs: [], entitlements: data)
            return try PropertyListSerialization.propertyList(
                from: Resigner.signingEntitlements(profile: profile, bundleID: "b"), format: nil) as! [String: Any]
        }
        #expect(try signed(["get-task-allow": false])["get-task-allow"] as? Bool == false)
        #expect(try signed([:])["get-task-allow"] as? Bool == true)
    }

    @Test func appliesOptions() async throws {
        let opts = InstallOptions(displayName: "Tube", version: "9.9", fileSharing: true,
                                  iPadFullScreen: true, proMotion: true, minimumOSVersion: "15.0")
        let p = try plist(try await run(try await fixture(), options: opts))
        #expect(p["CFBundleDisplayName"] as? String == "Tube")
        #expect(p["CFBundleName"] as? String == "Tube")
        #expect(p["CFBundleShortVersionString"] as? String == "9.9")
        #expect(p["UIFileSharingEnabled"] as? Bool == true)
        #expect(p["LSSupportsOpeningDocumentsInPlace"] as? Bool == true)
        #expect(p["UIRequiresFullScreen"] as? Bool == true)
        #expect(p["CADisableMinimumFrameDurationOnPhone"] as? Bool == true)
        #expect(p["MinimumOSVersion"] as? String == "15.0")
    }

    @Test func defaultOptionsLeaveKeysAlone() async throws {
        let p = try plist(try await run(try await fixture()))
        for k in ["CFBundleDisplayName", "CFBundleShortVersionString", "UIFileSharingEnabled",
                  "LSSupportsOpeningDocumentsInPlace", "UIRequiresFullScreen",
                  "CADisableMinimumFrameDurationOnPhone", "MinimumOSVersion", "CFBundleIcons"] {
            #expect(p[k] == nil)
        }
        #expect(p["CFBundleName"] as? String == "Demo")
    }

    @Test func appliesCustomIcon() async throws {
        let f = try await fixture(withIcons: true)
        let png = try tempDir("icon").appendingPathComponent("big.png")
        try writePNG(size: 1024, to: png)
        let app = try await run(f, iconURL: png)
        #expect(try pixelWidth(app.appendingPathComponent("XSideIcon60x60@2x.png")) == 120)
        #expect(try pixelWidth(app.appendingPathComponent("XSideIcon76x76@2x~ipad.png")) == 152)
        let p = try plist(app)
        let icons = try #require(p["CFBundleIcons"] as? [String: Any])
        let primary = try #require(icons["CFBundlePrimaryIcon"] as? [String: Any])
        #expect(primary["CFBundleIconFiles"] as? [String] == ["XSideIcon60x60"])
        #expect(primary["CFBundleIconName"] == nil)
        let ipad = try #require(p["CFBundleIcons~ipad"] as? [String: Any])
        let ipadPrimary = try #require(ipad["CFBundlePrimaryIcon"] as? [String: Any])
        #expect(ipadPrimary["CFBundleIconFiles"] as? [String] == ["XSideIcon60x60", "XSideIcon76x76"])
    }

    @Test func reusedWorkDirStartsClean() async throws {
        let first = try await fixture(appName: "Old") { app in
            try Data("x".utf8).write(to: app.appendingPathComponent("stale.txt"))
        }
        let a1 = try await run(first)
        #expect(a1.lastPathComponent == "Old.app")
        let second = try await fixture(appName: "New", work: first.work)
        let a2 = try await run(second)
        #expect(a2.lastPathComponent == "New.app")
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: first.work.appendingPathComponent("Payload/Old.app").path))
        #expect(!fm.fileExists(atPath: a2.appendingPathComponent("stale.txt").path))
        let leftovers = try fm.contentsOfDirectory(atPath: first.work.path).filter { $0.hasPrefix("entitlements-") }
        #expect(leftovers.count == 1)
    }

    @Test func sameAppNameDropsFilesMissingFromNewIPA() async throws {
        let first = try await fixture { app in
            try Data("x".utf8).write(to: app.appendingPathComponent("stale.txt"))
        }
        _ = try await run(first)
        let second = try await fixture(work: first.work)
        let app = try await run(second)
        #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent("stale.txt").path))
    }

    @Test func rejectsInfoPlistSymlinkOutsideWorkDir() async throws {
        let outside = try tempDir("outside").appendingPathComponent("victim.plist")
        let original = Data("precious".utf8)
        try original.write(to: outside)
        let f = try await fixture { app in
            let info = app.appendingPathComponent("Info.plist")
            try FileManager.default.removeItem(at: info)
            try FileManager.default.createSymbolicLink(at: info, withDestinationURL: outside)
        }
        await #expect(throws: (any Error).self) { _ = try await run(f) }
        do { _ = try await run(f) } catch let e as XSideError {
            guard case .invalidIPA = e else { Issue.record("wrong error \(e)"); return }
        }
        #expect(try Data(contentsOf: outside) == original)
        #expect(f.fake.calls.isEmpty)
    }

    @Test func rejectsDirectorySymlinkOutsideBundle() async throws {
        let outsideDir = try tempDir("outsidedir")
        let f = try await fixture(extensions: []) { app in
            try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("PlugIns"),
                                                       withDestinationURL: outsideDir)
        }
        do { _ = try await run(f); Issue.record("expected failure") } catch let e as XSideError {
            guard case .invalidIPA = e else { Issue.record("wrong error \(e)"); return }
        }
        #expect(FileManager.default.fileExists(atPath: outsideDir.path))
    }

    @Test func allowsInBundleFrameworkSymlinks() async throws {
        let f = try await fixture { app in
            let fm = FileManager.default
            let fw = app.appendingPathComponent("Frameworks/Y.framework")
            try fm.createDirectory(at: fw.appendingPathComponent("Versions/A"), withIntermediateDirectories: true)
            try FakeIPA.thinMachO(cryptid: 0).write(to: fw.appendingPathComponent("Versions/A/Y"))
            try fm.createSymbolicLink(atPath: fw.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
            try fm.createSymbolicLink(atPath: fw.appendingPathComponent("Y").path, withDestinationPath: "Versions/Current/Y")
        }
        let app = try await run(f)
        let targets = f.fake.calls.map { $0.last! }
        #expect(targets.contains(app.appendingPathComponent("Frameworks/Y.framework").path))
        #expect(targets.last == app.path)
    }

    @Test func iconOutputSymlinkDoesNotWriteThrough() async throws {
        let outside = try tempDir("outside").appendingPathComponent("victim.png")
        let original = Data("precious".utf8)
        try original.write(to: outside)
        let f = try await fixture { app in
            // In-bundle link (an outside link is rejected earlier): sips must not write through it.
            try Data("inbundle".utf8).write(to: app.appendingPathComponent("target.bin"))
            try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("XSideIcon60x60@2x.png").path,
                                                       withDestinationPath: "target.bin")
        }
        let png = try tempDir("icon").appendingPathComponent("big.png")
        try writePNG(size: 1024, to: png)
        let app = try await run(f, iconURL: png)
        let icon = app.appendingPathComponent("XSideIcon60x60@2x.png")
        #expect(!isLink(icon))
        #expect(try pixelWidth(icon) == 120)
        #expect(try Data(contentsOf: app.appendingPathComponent("target.bin")) == Data("inbundle".utf8))
        #expect(try Data(contentsOf: outside) == original)
    }

    @Test func rejectsSymlinkedMainExecutable() async throws {
        let f = try await fixture { app in
            let fm = FileManager.default
            try fm.moveItem(at: app.appendingPathComponent("Demo"), to: app.appendingPathComponent("real.bin"))
            try fm.createSymbolicLink(atPath: app.appendingPathComponent("Demo").path, withDestinationPath: "real.bin")
        }
        do { _ = try await run(f); Issue.record("expected failure") } catch let e as XSideError {
            guard case .invalidIPA = e else { Issue.record("wrong error \(e)"); return }
        }
        #expect(f.fake.calls.isEmpty)
    }

    @Test func rejectsEncryptedBinary() async throws {
        let f = try await fixture(encrypted: true)
        await #expect(throws: XSideError.encryptedIPA) { _ = try await run(f) }
        #expect(f.fake.calls.isEmpty)
    }

    @Test func codesignFailureIsReported() async throws {
        let f = try await fixture()
        f.fake.stub("/usr/bin/codesign", result: CommandResult(status: 1, stdout: Data(), stderr: "boom"))
        await #expect(throws: XSideError.commandFailed(tool: "codesign", status: 1)) { _ = try await run(f) }
    }

    @Test func unzippableIPAIsInvalid() async throws {
        let f = try await fixture()
        try Data("not a zip".utf8).write(to: f.ipa)
        await #expect(throws: XSideError.self) { _ = try await run(f) }
    }
}

private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: Data?
    var value: Data? { get { lock.withLock { _v } } set { lock.withLock { _v = newValue } } }
}

private func writePNG(size: Int, to url: URL) throws {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
}

private func pixelWidth(_ url: URL) throws -> Int {
    let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
    return props[kCGImagePropertyPixelWidth] as? Int ?? 0
}

/// Simulates an asset-catalog icon declaration (CFBundleIconName) that the Resigner must drop.
private func addAssetCatalogIcons(_ app: URL) throws {
    let url = app.appendingPathComponent("Info.plist")
    var p = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
    let icons: [String: Any] = ["CFBundlePrimaryIcon": ["CFBundleIconName": "AppIcon", "CFBundleIconFiles": ["Old"]]]
    p["CFBundleIcons"] = icons
    p["CFBundleIcons~ipad"] = icons
    try PropertyListSerialization.data(fromPropertyList: p, format: .binary, options: 0).write(to: url)
}

private func isLink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
}
