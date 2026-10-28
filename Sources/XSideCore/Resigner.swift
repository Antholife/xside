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

    public init(displayName: String? = nil, customBundleID: String? = nil, version: String? = nil,
                iconPath: String? = nil, fileSharing: Bool = false, iPadFullScreen: Bool = false,
                proMotion: Bool = false, minimumOSVersion: String? = nil) {
        self.displayName = displayName
        self.customBundleID = customBundleID
        self.version = version
        self.iconPath = iconPath
        self.fileSharing = fileSharing
        self.iPadFullScreen = iPadFullScreen
        self.proMotion = proMotion
        self.minimumOSVersion = minimumOSVersion
    }
}

public struct Resigner: Sendable {
    private let runner: CommandRunning
    private static let codesign = "/usr/bin/codesign"

    public init(runner: CommandRunning) { self.runner = runner }

    /// Unpacks `ipa` into `workDir`, rewrites it and signs it inside-out. Returns the signed `.app`.
    public func resign(ipa: URL, workDir: URL, bundleID: String, options: InstallOptions,
                       iconURL: URL?, profileURL: URL, profile: ProvisioningProfile,
                       identitySHA1: String) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        try cleanPreviousRun(in: workDir)
        let unzip = try await runner.run("/usr/bin/ditto", ["-x", "-k", ipa.path, workDir.path], cwd: nil)
        guard unzip.status == 0 else {
            throw XSideError.invalidIPA("Impossible de décompresser l'IPA")
        }

        try validateExtraction(in: workDir)
        let app = try IPAInspector.appBundle(in: workDir)
        try validateBundle(app, in: workDir)
        let info = try IPAInspector.info(of: app)
        if try IPAInspector.isEncrypted(app.appendingPathComponent(info.executable)) {
            throw XSideError.encryptedIPA
        }

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
        try profile.entitlements.write(to: entitlements)

        for target in signTargets(in: app) {
            try await sign(target, identity: identitySHA1, entitlements: nil)
        }
        try await sign(app, identity: identitySHA1, entitlements: entitlements)
        return app
    }

    // MARK: - Untrusted archive handling

    /// True if something exists at `url`, including a dangling symlink (does not follow links).
    private func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
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
        let data = try Data(contentsOf: url)
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
            from: Data(contentsOf: url), options: [], format: &format) as? [String: Any] else {
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
