import Foundation

public struct InstallOptions: Codable, Equatable, Sendable {
    public var displayName: String?
    public var customBundleID: String?
    public var version: String?
    /// Path relative to the library root.
    public var iconPath: String?
    public var fileSharing: Bool = false
    public var iPadFullScreen: Bool = false
    public var proMotion: Bool = false
    public var minimumOSVersion: String?
    /// Grant the keychain groups the app shares with its vendor's other apps. Off by default: the
    /// vendor is read from the IPA itself, so a crafted IPA could claim one to read their logins.
    public var shareKeychain: Bool = false
    /// Install the app as it came: nothing of XSide inside (no library, payload, Settings section,
    /// Bonjour keys or quick actions). For apps that refuse to launch once modified. nil: the app
    /// made no choice and follows the Mac's default (see `resolvedWithoutXSideFeatures`), which
    /// the pipeline resolves before signing.
    public var withoutXSideFeatures: Bool?
    /// Add iPhone Duo compatibility (see `DuoCompatibility`) to this signing. Chosen per device:
    /// the pipeline sets it for each job from `Installation.duoCompatibility` (the app's options
    /// themselves leave it nil).
    public var duoCompatibility: Bool?
    /// Add the signed-out iCloud library (see `ICloudSignedOut`) to this signing. Chosen per
    /// device, like `duoCompatibility`: the pipeline sets it from `Installation.iCloudSignedOut`.
    public var iCloudSignedOut: Bool?
    public init(displayName: String? = nil, customBundleID: String? = nil, version: String? = nil,
                iconPath: String? = nil, fileSharing: Bool = false, iPadFullScreen: Bool = false,
                proMotion: Bool = false, minimumOSVersion: String? = nil, shareKeychain: Bool = false,
                withoutXSideFeatures: Bool? = nil, duoCompatibility: Bool? = nil, iCloudSignedOut: Bool? = nil) {
        self.duoCompatibility = duoCompatibility
        self.iCloudSignedOut = iCloudSignedOut
        self.displayName = displayName
        self.customBundleID = customBundleID
        self.version = version
        self.iconPath = iconPath
        self.fileSharing = fileSharing
        self.iPadFullScreen = iPadFullScreen
        self.proMotion = proMotion
        self.minimumOSVersion = minimumOSVersion
        self.shareKeychain = shareKeychain
        self.withoutXSideFeatures = withoutXSideFeatures
    }

    /// Every key is optional: options saved by an older version (or missing a key) still load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        customBundleID = try c.decodeIfPresent(String.self, forKey: .customBundleID)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        iconPath = try c.decodeIfPresent(String.self, forKey: .iconPath)
        fileSharing = try c.decodeIfPresent(Bool.self, forKey: .fileSharing) ?? false
        iPadFullScreen = try c.decodeIfPresent(Bool.self, forKey: .iPadFullScreen) ?? false
        proMotion = try c.decodeIfPresent(Bool.self, forKey: .proMotion) ?? false
        minimumOSVersion = try c.decodeIfPresent(String.self, forKey: .minimumOSVersion)
        shareKeychain = try c.decodeIfPresent(Bool.self, forKey: .shareKeychain) ?? false
        withoutXSideFeatures = try c.decodeIfPresent(Bool.self, forKey: .withoutXSideFeatures)
        duoCompatibility = try c.decodeIfPresent(Bool.self, forKey: .duoCompatibility)
        iCloudSignedOut = try c.decodeIfPresent(Bool.self, forKey: .iCloudSignedOut)
    }
}

public struct Resigner: Sendable {
    private let runner: CommandRunning
    /// The welcome popup's iOS library (XSide.app's resource), nil when this build has none.
    private let welcomeDylib: URL?
    /// The signed-out iCloud library (`XSideICloud.dylib`, XSide.app's resource), nil when this
    /// build has none: the option then adds nothing (see `hasICloudSignedOut`).
    private let iCloudLibrary: URL?
    /// The section added to the app's iOS Settings page, built from the profile it's signed with
    /// and the installation's facts (nil when the caller has none).
    private let settingsSection: (@Sendable (ProvisioningProfile, InstallationFacts?) -> SettingsSection)?
    /// Written as the Info.plist key `XSideWelcome`, which the library reads at launch (keys in
    /// `WelcomePayload`). Nil: no payload. The installation's own values (settings, channel
    /// credentials, first install date) come from the `facts` given to `resign`, not from here.
    private let welcome: @Sendable (ProvisioningProfile) -> WelcomePayload?
    /// "fr" or "en": the language of the plain texts XSide writes into the Info.plist (shown when
    /// the app has no localization of its own; XSide adds none).
    private let textLanguage: @Sendable (InstallationFacts?) -> String
    private static let codesign = "/usr/bin/codesign"
    private static let logger = Log("resign")
    public static let welcomeName = "XSideWelcome.dylib"
    static let welcomeLoadPath = "@executable_path/Frameworks/\(welcomeName)"

    public init(runner: CommandRunning, welcomeDylib: URL? = nil,
                settingsSection: (@Sendable (ProvisioningProfile, InstallationFacts?) -> SettingsSection)? = nil,
                welcome: @escaping @Sendable (ProvisioningProfile) -> WelcomePayload? = { _ in nil },
                textLanguage: @escaping @Sendable (InstallationFacts?) -> String = { _ in "en" },
                iCloudLibrary: URL? = nil) {
        self.runner = runner
        self.iCloudLibrary = iCloudLibrary
        self.welcomeDylib = welcomeDylib
        self.settingsSection = settingsSection
        self.welcome = welcome
        self.textLanguage = textLanguage
    }

    /// Whether the signed `app` holds XSide's library (`addWelcomePopup` copies it there only once
    /// the executable loads it).
    public func hasXSideLibrary(_ app: URL) -> Bool {
        guard welcomeDylib != nil else { return false }
        let url = app.appendingPathComponent("Frameworks/\(Self.welcomeName)")
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }

    /// Unpacks `ipa` into `workDir`, rewrites it and signs it inside-out. Returns the signed `.app`.
    /// `facts`: the installation's own values, written into the payload and the Settings section.
    public func resign(ipa: URL, workDir: URL, bundleID: String, options: InstallOptions,
                       iconURL: URL?, profileURL: URL, profile: ProvisioningProfile,
                       identitySHA1: String, otherBundleIDs: Set<String> = [], facts: InstallationFacts? = nil,
                       onDuo: @Sendable (DuoOutcome?) async -> Void = { _ in },
                       onICloud: @Sendable () async -> Void = {},
                       onThinning: @Sendable () async -> Void = {},
                       onSigning: @Sendable () async -> Void = {}) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        try cleanPreviousRun(in: workDir)
        // The welcome step's progress is the unzip; the signing step's, the signatures.
        let unzip = try await StepProgress.within(0...1) {
            try await ZipLimits.extract(ipa, to: workDir, runner: runner)
        }
        guard unzip.status == 0 else {
            throw XSideError.invalidIPA("Couldn't unzip the IPA")
        }

        try validateExtraction(in: workDir)
        let app = try IPAInspector.appBundle(in: workDir)
        try validateBundle(app, in: workDir)
        let info = try IPAInspector.info(of: app)
        let executableURL = app.appendingPathComponent(info.executable)
        try requireType(.typeRegular, executableURL)
        if try IPAInspector.isEncrypted(executableURL) {
            throw XSideError.encryptedIPA
        }
        // What the app was signed with, for the keychain groups it declares (before anything changes).
        let originalEntitlements = IPAInspector.embeddedEntitlements(executableURL)

        for dir in ["PlugIns", "Extensions", "Watch"] {
            let url = app.appendingPathComponent(dir)
            if exists(url) { try fm.removeItem(at: url) } // removes a link itself, never its target
        }

        // 32-bit ARM slices run on no supported device (and may be encrypted): dropped before
        // anything else touches the executable (the Duo patch's SDK check must not see them).
        if MachOThinner.hasARM32Slices(under: app) { await onThinning() }
        let thinned = MachOThinner.removeARM32Slices(under: app)
        if !thinned.isEmpty { Self.logger.info("removed 32-bit ARM slices from \(thinned.count) file(s)") }

        let features = options.withoutXSideFeatures != true
        let library = features && welcomeDylib.map { FileManager.default.fileExists(atPath: $0.path) } == true
        let iCloudAsked = options.iCloudSignedOut == true
        let shim = iCloudAsked && iCloudLibrary.map { FileManager.default.fileExists(atPath: $0.path) } == true
        // Asked for this device: patched on a copy that replaces the executable only once it
        // declares the new SDK (XSide's load command included, when the features are on, so
        // both get the room); the Info.plist keys follow. Any problem leaves the executable
        // exactly as it was, and the library is then added as without the option.
        var duoApplied: DuoPlan?
        if options.duoCompatibility == true {
            await onDuo(nil)
            let outcome: DuoOutcome
            switch duoPlan(app: app, executable: executableURL) {
            case .plan(let plan):
                let loading = (library ? [Self.welcomeLoadPath] : []) + (shim ? [ICloudSignedOut.loadPath] : [])
                if await applyDuo(to: executableURL, growth: plan.growth, loading: loading, workDir: workDir) {
                    duoApplied = plan
                    outcome = .added
                } else {
                    outcome = .failed
                }
            case .skip(let reason):
                outcome = reason
            }
            await onDuo(outcome)
        }
        // Its own library, independent of XSide's module: added before it, so the room the
        // module needs is counted too (the toolchain run paths go only when both don't fit).
        var iCloudApplied = false
        if iCloudAsked {
            await onICloud()
            iCloudApplied = shim && addICloudLibrary(to: app, executable: executableURL,
                                                     alsoLoading: library ? Self.welcomeLoadPath : nil)
        }
        // The library first among what follows: the payload, Bonjour keys and quick actions mean
        // nothing without it (quick actions nothing handles would be a regression), so they
        // follow its outcome. After a Duo patch its load command is already there.
        let hasLibrary = features && addWelcomePopup(to: app, executable: executableURL)
        let payload = hasLibrary ? welcome(profile).map { Self.payload($0, with: facts) } : nil
        // The default container stands for the app's own: its original id and declared containers.
        let iCloudKeys = iCloudApplied
            ? (originalBundleID: info.bundleID, containers: ICloudSignedOut.containerIdentifiers(originalEntitlements)) : nil
        try editInfoPlist(app: app, bundleID: bundleID, options: options, payload: payload, features: hasLibrary,
                          language: textLanguage(facts), duo: duoApplied, iCloud: iCloudKeys)
        if let iconURL { try await applyIcon(iconURL, to: app, workDir: workDir) }
        // The section's switches are read by the library: without it they'd do nothing.
        if hasLibrary, let settingsSection {
            // Never fails the install: the app keeps its page as it was.
            do { try SettingsBundle.add(settingsSection(profile, facts), to: app) } catch {
                Self.logger.notice("settings section skipped: \(String(describing: error))")
            }
        }

        for url in allFiles(under: app) where url.lastPathComponent == "_CodeSignature" {
            try? fm.removeItem(at: url)
        }

        let embedded = app.appendingPathComponent("embedded.mobileprovision")
        if exists(embedded) { try fm.removeItem(at: embedded) }
        try fm.copyItem(at: profileURL, to: embedded)

        let entitlements = workDir.appendingPathComponent("entitlements-\(UUID().uuidString).plist")
        try Self.signingEntitlements(profile: profile, bundleID: bundleID, original: originalEntitlements,
                                     shareKeychain: options.shareKeychain, otherBundleIDs: otherBundleIDs)
            .write(to: entitlements)

        await onSigning()
        let targets = signTargets(in: app)
        for (index, target) in targets.enumerated() {
            try requireType(target.pathExtension == "dylib" ? .typeRegular : .typeDirectory, target)
            try await sign(target, identity: identitySHA1, entitlements: nil)
            StepProgress.report?(Double(index + 1) / Double(targets.count + 1))
        }
        try await sign(app, identity: identitySHA1, entitlements: entitlements)
        StepProgress.report?(1)
        return app
    }

    /// Every app gets the welcome popup: copies the library into `Frameworks/` and makes the
    /// executable load it (weakly).
    /// Never fails the install: on any problem the app is left as it was, without the popup.
    /// Returns whether the library is in the app.
    private func addWelcomePopup(to app: URL, executable: URL) -> Bool {
        guard let welcomeDylib, FileManager.default.fileExists(atPath: welcomeDylib.path) else {
            Self.logger.notice("welcome popup unavailable (no library in this build)")
            return false
        }
        let fm = FileManager.default
        let frameworks = app.appendingPathComponent("Frameworks")
        let target = frameworks.appendingPathComponent(Self.welcomeName)
        do {
            try fm.createDirectory(at: frameworks, withIntermediateDirectories: true)
            if exists(target) { try fm.removeItem(at: target) }
            try fm.copyItem(at: welcomeDylib, to: target)
            let outcome = try MachOPatcher.addWeakDylib(Self.welcomeLoadPath, to: executable)
            Self.logger.info("welcome popup added (\(outcome == .added ? "new load command" : "already loaded"))")
            return true
        } catch {
            try? fm.removeItem(at: target)
            Self.logger.notice("welcome popup skipped: \(String(describing: error))")
            return false
        }
    }

    // MARK: - Signed-out iCloud

    /// Copies `XSideICloud.dylib` into `Frameworks/` and makes the executable load it (weakly: a
    /// missing library never stops the app, it then behaves as without the option). When the
    /// header lacks room for it (and for `alsoLoading`, XSide's module, added next), the build
    /// Mac's toolchain run paths go first. Never fails the install: on any problem the library is
    /// removed. The executable may still name it when the iPhone Duo patch already added the load
    /// command (its copy carries both): harmless, the command is weak and the app runs as without
    /// the option. Returns whether the library is in the app.
    private func addICloudLibrary(to app: URL, executable: URL, alsoLoading other: String?) -> Bool {
        guard let iCloudLibrary else { return false }
        let fm = FileManager.default
        let target = app.appendingPathComponent("Frameworks/\(ICloudSignedOut.dylibName)")
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if exists(target) { try fm.removeItem(at: target) }
            try fm.copyItem(at: iCloudLibrary, to: target)
            // Only what isn't there yet (a Duo patch already added both).
            let needed = ([ICloudSignedOut.loadPath] + (other.map { [$0] } ?? []))
                .filter { !MachOPatcher.loadsDylib($0, in: executable) }
                .reduce(0) { $0 + MachOPatcher.dylibCommand($1).count }
            makeRoom(in: executable, needing: needed)
            let outcome = try MachOPatcher.addWeakDylib(ICloudSignedOut.loadPath, to: executable)
            Self.logger.info("signed-out iCloud added (\(outcome == .added ? "new load command" : "already loaded"))")
            return true
        } catch {
            try? fm.removeItem(at: target)
            Self.logger.notice("signed-out iCloud skipped: \(String(describing: error))")
            return false
        }
    }

    /// Whether the signed `app` holds the signed-out iCloud library.
    public func hasICloudSignedOut(_ app: URL) -> Bool {
        guard iCloudLibrary != nil else { return false }
        let url = app.appendingPathComponent("Frameworks/\(ICloudSignedOut.dylibName)")
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }

    // MARK: - iPhone Duo compatibility

    /// What the Duo option does to an app: the bytes its version command grows by, and the scene
    /// delegate a new manifest names (nil when the app has a manifest of its own).
    struct DuoPlan {
        let growth: Int
        let sceneDelegate: String?
    }

    enum DuoDecision {
        case plan(DuoPlan)
        /// Nothing to do, nothing possible, or the app can't be read.
        case skip(DuoOutcome)
    }

    private func duoPlan(app: URL, executable: URL) -> DuoDecision {
        guard let data = try? IPAInspector.infoPlistData(of: app),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            Self.logger.notice("duo compatibility skipped: unreadable Info.plist")
            return .skip(.failed)
        }
        let info = DuoAppInfo.read(executable: executable, plist: plist)
        switch DuoCompatibility.optionState(isDuo: true, app: info) {
        case .alreadySupported:
            Self.logger.info("duo compatibility: built with SDK \(info.sdkVersion ?? "?"), nothing to do")
            return .skip(.alreadySupported)
        case .noSceneSupport:
            Self.logger.notice("duo compatibility skipped: no scene manifest nor scene delegate")
            return .skip(.notPossible)
        case .recommended, .notADuo, .unknown:
            guard let growth = try? MachOBuildInfo.versionCommandGrowth(of: executable) else {
                Self.logger.notice("duo compatibility skipped: unreadable executable")
                return .skip(.failed)
            }
            Self.logger.info("duo compatibility: SDK \(info.sdkVersion ?? "?"), scene delegate \(info.adoptsScenes ? "(own manifest)" : info.sceneDelegateClass ?? "?")")
            return .plan(DuoPlan(growth: growth, sceneDelegate: info.adoptsScenes ? nil : info.sceneDelegateClass))
        }
    }

    /// Gives every slice of the executable SDK 27.1 with `xcrun vtool` (the job's Xcode),
    /// keeping its minimum iOS. Done on a copy: when the header lacks room for the bigger
    /// version command (and XSide's), the copy loses the build Mac's toolchain run paths first; the copy
    /// replaces the executable only once every slice declares 27.1. Never fails the install: on
    /// any problem the executable stays exactly as it was (run paths included). Returns whether
    /// it now declares 27.1.
    /// `loading`: XSide's libraries (its module, the signed-out iCloud one), whose load commands go
    /// in the copy first (they take room too).
    private func applyDuo(to executable: URL, growth: Int, loading dylibPaths: [String], workDir: URL) async -> Bool {
        let fm = FileManager.default
        let tag = UUID().uuidString
        let input = workDir.appendingPathComponent("duo-\(tag)-in")
        let output = workDir.appendingPathComponent("duo-\(tag)")
        var temps: [URL] = []
        defer {
            try? fm.removeItem(at: input)
            try? fm.removeItem(at: output)
            for t in temps { try? fm.removeItem(at: t) }
        }
        do {
            try fm.copyItem(at: executable, to: input)
            let commands = dylibPaths.reduce(0) { $0 + MachOPatcher.dylibCommand($1).count }
            makeRoom(in: input, needing: growth + commands)
            for dylibPath in dylibPaths {
                // Its own failure (no room) is the library's, found again when it's added for real.
                do { _ = try MachOPatcher.addWeakDylib(dylibPath, to: input) } catch {
                    Self.logger.notice("duo compatibility: \(dylibPath) didn't fit: \(String(describing: error))")
                }
            }
            let slices = try MachOBuildInfo.slices(of: input)
            guard let calls = DuoCompatibility.vtoolCalls(input: input.path, output: output.path, slices: slices, temp: { i in
                let url = workDir.appendingPathComponent("duo-\(tag)-\(i)")
                temps.append(url)
                return url.path
            }) else {
                Self.logger.notice("duo compatibility skipped: not an iOS executable with a known minimum")
                return false
            }
            for call in calls {
                let r = try await runner.run("/usr/bin/xcrun", call, cwd: nil)
                guard r.status == 0 else {
                    Self.logger.notice("duo compatibility skipped: vtool failed (\(r.status)): \(r.stderr.prefix(300))")
                    return false
                }
            }
            guard (try? MachOBuildInfo.slices(of: output))?.allSatisfy({ DuoCompatibility.supportsDuo(sdk: $0.sdk) }) == true else {
                Self.logger.notice("duo compatibility skipped: vtool's output doesn't declare SDK \(DuoCompatibility.sdk)")
                return false
            }
            let mode = try fm.attributesOfItem(atPath: executable.path)[.posixPermissions]
            _ = try fm.replaceItemAt(executable, withItemAt: output)
            if let mode { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: executable.path) }
            Self.logger.info("duo compatibility: SDK \(DuoCompatibility.sdk) declared")
            return true
        } catch {
            Self.logger.notice("duo compatibility skipped: \(String(describing: error))")
            return false
        }
    }

    /// Frees header space by removing the build Mac's toolchain run paths, only when the new
    /// command wouldn't fit otherwise.
    private func makeRoom(in executable: URL, needing bytes: Int) {
        guard bytes > 0, let free = try? MachOPatcher.freeSpace(in: executable), free < bytes else { return }
        do {
            let removed = try MachOPatcher.removeRpaths(from: executable, where: DuoCompatibility.isBuildMacToolchainPath)
            Self.logger.info("load commands: \(free) bytes free for \(bytes), removed \(removed.count) toolchain rpath(s)")
        } catch {
            Self.logger.notice("load commands: couldn't make room: \(String(describing: error))")
        }
    }

    /// Whether the signed `app` fills an iPhone Duo's screens: its executable declares SDK 27.1 or
    /// later (patched, or built so).
    public func hasDuoCompatibility(_ app: URL) -> Bool {
        guard let info = try? IPAInspector.info(of: app) else { return false }
        return DuoCompatibility.supportsDuo(sdk: MachOBuildInfo.sdkVersion(of: app.appendingPathComponent(info.executable)))
    }

    // MARK: - Entitlements

    /// The entitlements the app is signed with (XML plist): the identity keys for exactly
    /// `<TEAM>.<bundleID>`, never the profile's wildcards. A free profile grants
    /// `keychain-access-groups = [TEAM.*]`, which would let the sideloaded app read every keychain
    /// item of the team's other apps. Other profile keys pass through unless a value contains `*`.
    /// `original`: the entitlements the app was signed with. The keychain groups it declares are
    /// kept, moved to the new team (see `keychainGroups`), after `<TEAM>.<bundleID>`, only when
    /// `shareKeychain` is on.
    public static func signingEntitlements(profile: ProvisioningProfile, bundleID: String,
                                           original: [String: Any]? = nil, shareKeychain: Bool = false,
                                           otherBundleIDs: Set<String> = []) throws -> Data {
        let granted = (try? PropertyListSerialization.propertyList(from: profile.entitlements, format: nil))
            as? [String: Any] ?? [:]
        let appID = "\(profile.teamID).\(bundleID)"
        var result: [String: Any] = [:]
        for (key, value) in granted where !containsWildcard(value) { result[key] = value }
        result["application-identifier"] = appID
        result["com.apple.developer.team-identifier"] = profile.teamID
        result["get-task-allow"] = granted["get-task-allow"] as? Bool ?? true
        // Only the app's own group unless the user chose to share with the vendor's other apps.
        result["keychain-access-groups"] = shareKeychain
            ? keychainGroups(original, team: profile.teamID, appID: appID, otherBundleIDs: otherBundleIDs)
            : [appID]
        return try PropertyListSerialization.data(fromPropertyList: result, format: .xml, options: 0)
    }

    /// `appID` first, then each group the original entitlements declare, remapped to `team`:
    /// `<OLDTEAM>.rest` and `$(AppIdentifierPrefix)rest` become `<team>.rest`; `com.apple.token`
    /// stays. Wildcards and groups without a team prefix are dropped (the profile can't grant them).
    /// A declared group that lands on another XSide app's own group (`<team>.<its signed id>`) is
    /// dropped: a crafted IPA could otherwise read that app's keychain items. Shared groups
    /// (`<team>.com.vendor.shared`) stay, so apps of one vendor keep sharing their logins.
    static func keychainGroups(_ original: [String: Any]?, team: String, appID: String,
                               otherBundleIDs: Set<String> = []) -> [String] {
        let reserved = Set(otherBundleIDs.map { "\(team).\($0)" })
        // Allowlist: a shared group is kept only within the app's own vendor, the first two
        // components of its original id ("com.google" for com.google.ios.youtube, which keeps
        // com.google.common.SSO). Unknown original id: nothing beyond `appID`.
        let vendor = keychainVendor(original).map { $0 + "." }
        let declared = original?["keychain-access-groups"] as? [String] ?? []
        // The original team: its own key, else the prefix of its application identifier.
        let oldTeam = original?["com.apple.developer.team-identifier"] as? String
            ?? (original?["application-identifier"] as? String)?.split(separator: ".").first.map(String.init)
        func looksLikeTeam(_ s: Substring) -> Bool {
            s.count == 10 && s.allSatisfy { ($0.isASCII && $0.isUppercase) || $0.isASCII && $0.isNumber }
        }
        var groups = [appID]
        for group in declared where !group.contains("*") {
            let mapped: String?
            if group == "com.apple.token" {
                mapped = group
            } else if group.hasPrefix("$(AppIdentifierPrefix)") {
                let rest = group.dropFirst("$(AppIdentifierPrefix)".count)
                mapped = rest.isEmpty ? nil : "\(team).\(rest)"
            } else if let dot = group.firstIndex(of: "."), group.index(after: dot) < group.endIndex,
                      group[..<dot] == oldTeam?[...] || looksLikeTeam(group[..<dot]) {
                mapped = "\(team).\(group[group.index(after: dot)...])"
            } else {
                mapped = nil
            }
            // Also never a group shaped like an XSide-signed id (`<team>.<original>.<team>`): that
            // would target an app installed later, before its id is known here.
            let sameVendor = mapped == "com.apple.token"
                || (vendor.map { mapped?.hasPrefix("\(team).\($0)") ?? false } ?? false)
            if let mapped, sameVendor, !reserved.contains(mapped), !mapped.hasSuffix(".\(team)"),
               !groups.contains(mapped) {
                groups.append(mapped)
            }
        }
        return groups
    }

    /// The vendor whose shared keychain groups an app may keep: the first two components of its
    /// original id, read from the embedded `application-identifier` ("TEAM.com.google.ios.youtube"
    /// gives "com.google"). Nil when the entitlements don't say.
    public static func keychainVendor(_ original: [String: Any]?) -> String? {
        guard let id = original?["application-identifier"] as? String, let dot = id.firstIndex(of: ".") else { return nil }
        let parts = id[id.index(after: dot)...].split(separator: ".")
        guard !parts.isEmpty else { return nil }
        return parts.prefix(2).joined(separator: ".")
    }

    /// The shared groups `keychainGroups` would grant, without their team prefix, for the install
    /// options to list ("com.google.common.SSO").
    public static func sharedGroupNames(_ original: [String: Any]?) -> [String] {
        let team = "XSIDETEAM0"
        return keychainGroups(original, team: team, appID: "\(team).\(UUID().uuidString)").dropFirst()
            .filter { $0 != "com.apple.token" }
            .map { String($0.dropFirst(team.count + 1)) }
    }

    private static func containsWildcard(_ value: Any) -> Bool {
        switch value {
        case let string as String: return string.contains("*")
        case let array as [Any]: return array.contains(where: containsWildcard)
        case let dict as [String: Any]: return dict.values.contains(where: containsWildcard)
        default: return false
        }
    }

    // MARK: - Untrusted archive handling

    /// True if something exists at `url`, including a dangling symlink (does not follow links).
    private func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// lstat-style check: the item itself (not a link target) must be of the given type.
    private func requireType(_ type: FileAttributeType, _ url: URL) throws {
        let actual = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        guard actual == type else {
            throw XSideError.invalidIPA("\(url.lastPathComponent) isn't of the expected type")
        }
    }

    /// Removes what a previous run left in `workDir` so extraction starts from a clean state.
    private func cleanPreviousRun(in workDir: URL) throws {
        let fm = FileManager.default
        let payload = workDir.appendingPathComponent("Payload")
        if exists(payload) { try fm.removeItem(at: payload) }
        for item in (try? fm.contentsOfDirectory(atPath: workDir.path)) ?? []
        where (item.hasPrefix("entitlements-") && item.hasSuffix(".plist"))
            || (item.hasPrefix("xside-icon-") && item.hasSuffix(".png")) || item.hasPrefix("duo-") {
            try? fm.removeItem(at: workDir.appendingPathComponent(item))
        }
    }

    private func validateExtraction(in workDir: URL) throws {
        if isSymlink(workDir.appendingPathComponent("Payload")) {
            throw XSideError.invalidIPA("Suspicious symbolic link (Payload)")
        }
    }

    /// Rejects archives whose entries escape the bundle (symlinks pointing outside it).
    private func validateBundle(_ app: URL, in workDir: URL) throws {
        func bad(_ what: String) -> XSideError { .invalidIPA("Suspicious symbolic link (\(what))") }
        let root = app.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let work = workDir.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        func inside(_ path: [String], _ base: [String]) -> Bool {
            path.count >= base.count && Array(path.prefix(base.count)) == base
        }
        if isSymlink(app) { throw bad(app.lastPathComponent) }
        guard inside(root, work) else { throw bad("hors du dossier de travail") }
        for name in ["Info.plist", "embedded.mobileprovision"] where isSymlink(app.appendingPathComponent(name)) {
            throw bad(name)
        }
        guard let en = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in en where isSymlink(url) {
            en.skipDescendants()
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
                throw bad(url.lastPathComponent)
            }
            let target = dest.hasPrefix("/")
                ? URL(fileURLWithPath: dest)
                : url.deletingLastPathComponent().appendingPathComponent(dest)
            // Both the lexical and the fully resolved target must stay inside the bundle.
            let lexical = target.standardizedFileURL.pathComponents
            let resolved = target.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard inside(lexical, app.standardizedFileURL.pathComponents) || inside(lexical, root),
                  inside(resolved, root) else { throw bad(url.lastPathComponent) }
        }
    }

    /// `payload` with the installation's own values: the secret the app gets is always the one
    /// the pipeline stores.
    static func payload(_ payload: WelcomePayload, with facts: InstallationFacts?) -> WelcomePayload {
        guard let facts else { return payload }
        var p = payload
        p.inApp = facts.inApp
        p.installationID = facts.installationID
        p.channelSecret = facts.channelSecret
        p.installedAt = facts.firstInstalledAt
        p.signedAt = facts.signedAt
        return p
    }

    // MARK: - Info.plist

    private func editInfoPlist(app: URL, bundleID: String, options: InstallOptions,
                               payload: WelcomePayload?, features: Bool, language: String, duo: DuoPlan?,
                               iCloud: (originalBundleID: String, containers: [String])?) throws {
        let url = app.appendingPathComponent("Info.plist")
        let data = try IPAInspector.infoPlistData(of: app)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: &format) as? [String: Any] else {
            throw XSideError.invalidIPA("Unreadable Info.plist")
        }
        plist["CFBundleIdentifier"] = bundleID
        if let name = options.displayName {
            plist["CFBundleDisplayName"] = name
            plist["CFBundleName"] = name
        }
        if let v = options.version { plist["CFBundleShortVersionString"] = v }
        if options.fileSharing {
            plist["UIFileSharingEnabled"] = true
            plist["LSSupportsOpeningDocumentsInPlace"] = true
        }
        if options.iPadFullScreen { plist["UIRequiresFullScreen"] = true }
        if options.proMotion { plist["CADisableMinimumFrameDurationOnPhone"] = true }
        if let min = options.minimumOSVersion { plist["MinimumOSVersion"] = min }
        if let duo { DuoCompatibility.applyInfoPlist(&plist, sceneDelegateClass: duo.sceneDelegate) }
        // Cleared first too (the .ipa may carry them); read by the signed-out iCloud library.
        ICloudSignedOut.clearInfoPlist(&plist)
        if let iCloud {
            ICloudSignedOut.applyInfoPlist(&plist, originalBundleID: iCloud.originalBundleID, containers: iCloud.containers)
        }
        let executable = plist["CFBundleExecutable"] as? String ?? "App"
        Self.plainBundleName(&plist, executable: executable)
        // Cleared first: an app signed by XSide before carries the previous payload.
        plist["XSideWelcome"] = nil
        if let payload { plist["XSideWelcome"] = payload.plist }
        let strings = features ? InfoPlistAdditions.apply(to: &plist, language: language) : [:]
        if !features { InfoPlistAdditions.removeShortcuts(from: &plist) }
        try write(plist, format: format, to: url)
        // Never fails the install: untranslated texts are the worst outcome. Only the app's own
        // lprojs get them (no folder created: final review Important 2).
        if !strings.isEmpty {
            LocalizedStrings.merge(strings, into: app, table: "InfoPlist", keepExisting: [InfoPlistAdditions.usageKey],
                                   developmentRegion: plist["CFBundleDevelopmentRegion"] as? String)
        }
        plainLocalizedBundleNames(app: app, executable: executable)
    }

    /// A CFBundleName with special characters gets a plain one (see `BundleName`); the name shown
    /// keeps the original, as CFBundleDisplayName when there was none.
    static func plainBundleName(_ entries: inout [String: Any], executable: String) {
        guard let name = entries["CFBundleName"] as? String,
              let plain = BundleName.safe(name, executable: executable) else { return }
        if entries["CFBundleDisplayName"] == nil { entries["CFBundleDisplayName"] = name }
        entries["CFBundleName"] = plain
    }

    /// The same in each `<lang>.lproj/InfoPlist.strings`. A file it can't read is left alone.
    private func plainLocalizedBundleNames(app: URL, executable: String) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: app, includingPropertiesForKeys: nil) else { return }
        for dir in dirs where dir.pathExtension == "lproj" {
            let url = dir.appendingPathComponent("InfoPlist.strings")
            guard (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular,
                  let data = try? Data(contentsOf: url),
                  var entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  entries["CFBundleName"] != nil else { continue }
            let before = entries["CFBundleName"] as? String
            Self.plainBundleName(&entries, executable: executable)
            guard entries["CFBundleName"] as? String != before else { continue }
            // Written as a binary plist, which iOS reads like the text format.
            if let out = try? PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0) {
                try? out.write(to: url)
            }
        }
    }

    private func write(_ plist: [String: Any], format: PropertyListSerialization.PropertyListFormat, to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0).write(to: url)
    }

    // MARK: - Icon

    private func applyIcon(_ source: URL, to app: URL, workDir: URL) async throws {
        let outputs: [(file: String, px: Int)] = [("XSideIcon60x60@2x.png", 120), ("XSideIcon76x76@2x~ipad.png", 152)]
        for (file, px) in outputs {
            let dst = app.appendingPathComponent(file)
            // sips writes outside the bundle; the result is then moved over any pre-existing item.
            let tmp = workDir.appendingPathComponent("xside-icon-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let r = try await runner.run("/usr/bin/sips", ["-z", "\(px)", "\(px)", source.path, "--out", tmp.path], cwd: nil)
            guard r.status == 0, FileManager.default.fileExists(atPath: tmp.path) else {
                throw XSideError.commandFailed(tool: "sips", status: r.status)
            }
            if exists(dst) { try FileManager.default.removeItem(at: dst) }
            try FileManager.default.moveItem(at: tmp, to: dst)
        }
        let url = app.appendingPathComponent("Info.plist")
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var plist = try PropertyListSerialization.propertyList(
            from: IPAInspector.infoPlistData(of: app), options: [], format: &format) as? [String: Any] else {
            throw XSideError.invalidIPA("Unreadable Info.plist")
        }
        plist["CFBundleIcons"] = iconDict(plist["CFBundleIcons"], files: ["XSideIcon60x60"])
        plist["CFBundleIcons~ipad"] = iconDict(plist["CFBundleIcons~ipad"], files: ["XSideIcon60x60", "XSideIcon76x76"])
        try write(plist, format: format, to: url)
    }

    /// Replaces the primary icon files and drops `CFBundleIconName`, so iOS stops using the asset catalog.
    private func iconDict(_ existing: Any?, files: [String]) -> [String: Any] {
        var icons = existing as? [String: Any] ?? [:]
        var primary = icons["CFBundlePrimaryIcon"] as? [String: Any] ?? [:]
        primary["CFBundleIconFiles"] = files
        primary.removeValue(forKey: "CFBundleIconName")
        icons["CFBundlePrimaryIcon"] = primary
        return icons
    }

    // MARK: - Signing

    private func allFiles(under root: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return en.compactMap { $0 as? URL }
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    /// Every `.framework` / `.dylib` below the app (not the app itself), deepest first, deduplicated.
    private func signTargets(in app: URL) -> [URL] {
        var seen = Set<String>()
        let found = allFiles(under: app).filter {
            ["framework", "dylib"].contains($0.pathExtension) && !isSymlink($0)
        }.filter { seen.insert($0.standardizedFileURL.path).inserted }
        return found.sorted { $0.pathComponents.count > $1.pathComponents.count }
    }

    private func sign(_ target: URL, identity: String, entitlements: URL?) async throws {
        var args = ["-f", "-s", identity, "--timestamp=none"]
        if let entitlements { args += ["--entitlements", entitlements.path] }
        args.append(target.path)
        let r = try await runner.run(Self.codesign, args, cwd: nil)
        guard r.status == 0 else { throw XSideError.commandFailed(tool: "codesign", status: r.status) }
    }
}
