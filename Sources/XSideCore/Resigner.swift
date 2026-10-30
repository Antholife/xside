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

    public init(displayName: String? = nil, customBundleID: String? = nil, version: String? = nil,
                iconPath: String? = nil, fileSharing: Bool = false, iPadFullScreen: Bool = false,
                proMotion: Bool = false, minimumOSVersion: String? = nil, shareKeychain: Bool = false) {
        self.displayName = displayName
        self.customBundleID = customBundleID
        self.version = version
        self.iconPath = iconPath
        self.fileSharing = fileSharing
        self.iPadFullScreen = iPadFullScreen
        self.proMotion = proMotion
        self.minimumOSVersion = minimumOSVersion
        self.shareKeychain = shareKeychain
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
    }
}

public struct Resigner: Sendable {
    private let runner: CommandRunning
    private static let codesign = "/usr/bin/codesign"

    public init(runner: CommandRunning) { self.runner = runner }

    /// Unpacks `ipa` into `workDir`, rewrites it and signs it inside-out. Returns the signed `.app`.
    public func resign(ipa: URL, workDir: URL, bundleID: String, options: InstallOptions,
                       iconURL: URL?, profileURL: URL, profile: ProvisioningProfile,
                       identitySHA1: String, otherBundleIDs: Set<String> = []) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        try cleanPreviousRun(in: workDir)
        let unzip = try await ZipLimits.extract(ipa, to: workDir, runner: runner)
        guard unzip.status == 0 else {
            throw XSideError.invalidIPA("Impossible de décompresser l'IPA")
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

        try editInfoPlist(app: app, bundleID: bundleID, options: options)
        if let iconURL { try await applyIcon(iconURL, to: app, workDir: workDir) }

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

        for target in signTargets(in: app) {
            try requireType(target.pathExtension == "dylib" ? .typeRegular : .typeDirectory, target)
            try await sign(target, identity: identitySHA1, entitlements: nil)
        }
        try await sign(app, identity: identitySHA1, entitlements: entitlements)
        return app
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
            throw XSideError.invalidIPA("IPA invalide : \(url.lastPathComponent) n'est pas du type attendu")
        }
    }

    /// Removes what a previous run left in `workDir` so extraction starts from a clean state.
    private func cleanPreviousRun(in workDir: URL) throws {
        let fm = FileManager.default
        let payload = workDir.appendingPathComponent("Payload")
        if exists(payload) { try fm.removeItem(at: payload) }
        for item in (try? fm.contentsOfDirectory(atPath: workDir.path)) ?? []
        where (item.hasPrefix("entitlements-") && item.hasSuffix(".plist"))
            || (item.hasPrefix("xside-icon-") && item.hasSuffix(".png")) {
            try? fm.removeItem(at: workDir.appendingPathComponent(item))
        }
    }

    private func validateExtraction(in workDir: URL) throws {
        if isSymlink(workDir.appendingPathComponent("Payload")) {
            throw XSideError.invalidIPA("IPA invalide : lien symbolique suspect (Payload)")
        }
    }

    /// Rejects archives whose entries escape the bundle (symlinks pointing outside it).
    private func validateBundle(_ app: URL, in workDir: URL) throws {
        func bad(_ what: String) -> XSideError { .invalidIPA("IPA invalide : lien symbolique suspect (\(what))") }
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

    // MARK: - Info.plist

    private func editInfoPlist(app: URL, bundleID: String, options: InstallOptions) throws {
        let url = app.appendingPathComponent("Info.plist")
        let data = try IPAInspector.infoPlistData(of: app)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: &format) as? [String: Any] else {
            throw XSideError.invalidIPA("Info.plist illisible")
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
        try write(plist, format: format, to: url)
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
            throw XSideError.invalidIPA("Info.plist illisible")
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
