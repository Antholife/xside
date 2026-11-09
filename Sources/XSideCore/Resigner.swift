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
    /// The tweaks to inject into this signing. Per device, like `duoCompatibility`: the pipeline
    /// sets it for each job (the app's options themselves leave it nil).
    public var tweaks: TweakJob?
    public init(displayName: String? = nil, customBundleID: String? = nil, version: String? = nil,
                iconPath: String? = nil, fileSharing: Bool = false, iPadFullScreen: Bool = false,
                proMotion: Bool = false, minimumOSVersion: String? = nil, shareKeychain: Bool = false,
                withoutXSideFeatures: Bool? = nil, duoCompatibility: Bool? = nil, iCloudSignedOut: Bool? = nil,
                tweaks: TweakJob? = nil) {
        self.tweaks = tweaks
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
        tweaks = (try? c.decodeIfPresent(TweakJob.self, forKey: .tweaks)) ?? nil
    }
}

/// One enabled tweak of a signing: the stored package, its folder in the library, and whether the
/// person chose « Injecter quand même ».
public struct TweakSigningItem: Codable, Equatable, Sendable {
    public var package: TweakPackage
    /// The stored package's folder (absolute path).
    public var directory: String
    public var force: Bool

    public init(package: TweakPackage, directory: String, force: Bool = false) {
        self.package = package
        self.directory = directory
        self.force = force
    }
}

/// The tweaks one signing injects, in list order, for one device.
public struct TweakJob: Codable, Equatable, Sendable {
    public var items: [TweakSigningItem]
    public var deviceOS: String?

    public init(items: [TweakSigningItem], deviceOS: String? = nil) {
        self.items = items
        self.deviceOS = deviceOS
    }
}

/// What the tweak step did: a result per item (`TweakPackage.id`), and the package ids of XSide's
/// embedded dependencies copied into the app (`Frameworks/XSideTweaks/deps/`).
public struct TweakSigningReport: Equatable, Sendable {
    public var results: [String: TweakResult]
    public var embedded: [String]

    public init(results: [String: TweakResult], embedded: [String]) {
        self.results = results
        self.embedded = embedded
    }
}

/// How adding "Simulate signed-out iCloud"'s library went.
public enum ICloudOutcome: String, Codable, Sendable, Equatable {
    case added
    /// Not added: no library in this build, or a problem (the logs say which).
    case failed
    /// Not added: the app's header had room for one more library only, and XSide's module got it.
    case noRoomBesideModule
}

public struct Resigner: Sendable {
    private let runner: CommandRunning
    /// The welcome popup's iOS library (XSide.app's resource), nil when this build has none.
    private let welcomeDylib: URL?
    /// The signed-out iCloud library (`XSideICloud.dylib`, XSide.app's resource), nil when this
    /// build has none: the option then adds nothing (see `hasICloudSignedOut`).
    private let iCloudLibrary: URL?
    /// The iPhone Duo compatibility module for apps without scene support (`XSideDuoLegacy.dylib`,
    /// XSide.app's resource), nil when this build has none: such apps then get nothing (`notPossible`).
    private let duoLegacyLibrary: URL?
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
    /// ElleKit (`ElleKit.dylib`) and its licence, which goes next to it in every app that gets it;
    /// the support library (`XSideTweakSupport.dylib`); XSide's embedded dependencies
    /// (`TweakDependencies/`, see `TweakDependencyCatalog`). All XSide.app resources, nil when this
    /// build has none: the tweaks needing them are then skipped.
    private let elleKitLibrary: URL?
    private let elleKitLicense: URL?
    private let tweakSupportLibrary: URL?
    private let tweakDependencies: URL?
    /// This build's ElleKit also answers for libhooker.
    private let elleKitHasLibhooker: Bool
    private static let codesign = "/usr/bin/codesign"
    private static let logger = Log("resign")
    public static let welcomeName = "XSideWelcome.dylib"
    static let welcomeLoadPath = "@executable_path/Frameworks/\(welcomeName)"

    public init(runner: CommandRunning, welcomeDylib: URL? = nil,
                settingsSection: (@Sendable (ProvisioningProfile, InstallationFacts?) -> SettingsSection)? = nil,
                welcome: @escaping @Sendable (ProvisioningProfile) -> WelcomePayload? = { _ in nil },
                textLanguage: @escaping @Sendable (InstallationFacts?) -> String = { _ in "en" },
                iCloudLibrary: URL? = nil, duoLegacyLibrary: URL? = nil,
                elleKitLibrary: URL? = nil, elleKitLicense: URL? = nil, tweakSupportLibrary: URL? = nil,
                tweakDependencies: URL? = nil, elleKitHasLibhooker: Bool = false) {
        self.runner = runner
        self.elleKitLibrary = elleKitLibrary
        self.elleKitLicense = elleKitLicense
        self.tweakSupportLibrary = tweakSupportLibrary
        self.tweakDependencies = tweakDependencies
        self.elleKitHasLibhooker = elleKitHasLibhooker
        self.iCloudLibrary = iCloudLibrary
        self.duoLegacyLibrary = duoLegacyLibrary
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
                       onICloudSkipped: @Sendable (ICloudOutcome) async -> Void = { _ in },
                       onThinning: @Sendable () async -> Void = {},
                       onSigning: @Sendable () async -> Void = {},
                       onTweaks: @Sendable (TweakSigningReport?) async -> Void = { _ in }) async throws -> URL {
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
        // An .ipa XSide signed before carries its libraries: those this signing doesn't add again
        // go, with their load commands (a stray iCloud library would stay active with the option off).
        removeStaleLibraries(app: app, executable: executableURL, keepWelcome: library, keepICloud: shim)
        // Read-only: which tweaks go in and the load commands they need (the Duo copy carries them).
        let tweakItems = options.tweaks?.items ?? []
        let tweakPlan = tweakItems.isEmpty ? nil
            : planTweaks(tweakItems, deviceOS: options.tweaks?.deviceOS, app: app, executable: executableURL, info: info)
        // Asked for this device: patched on a copy that replaces the executable only once it
        // declares the new SDK (XSide's load command included, when the features are on, so
        // both get the room); the Info.plist keys follow. Any problem leaves the executable
        // exactly as it was, and the library is then added as without the option.
        // An app without scene support gets the compatibility module too: its load command comes
        // first in the copy, and its file is in Frameworks/ before the copy replaces the executable
        // (an SDK 27.1 app without scenes is stopped at launch).
        var duoApplied: DuoPlan?
        if options.duoCompatibility == true {
            await onDuo(nil)
            let outcome: DuoOutcome
            switch duoPlan(app: app, executable: executableURL) {
            case .plan(let plan):
                let loading = (library ? [Self.welcomeLoadPath] : []) + (shim ? [ICloudSignedOut.loadPath] : [])
                let module = plan.legacyModule ? copyDuoLegacyLibrary(to: app) : nil
                if plan.legacyModule, module == nil {
                    outcome = .failed
                } else if await applyDuo(to: executableURL, growth: plan.growth, loading: loading,
                                         optional: tweakPlan?.loadPaths ?? [],
                                         required: plan.legacyModule ? DuoCompatibility.legacyLoadPath : nil, workDir: workDir) {
                    duoApplied = plan
                    outcome = plan.legacyModule ? .addedWithModule : .added
                } else {
                    if let module { try? FileManager.default.removeItem(at: module) }
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
            let outcome = shim ? addICloudLibrary(to: app, executable: executableURL,
                                                  alsoLoading: library ? Self.welcomeLoadPath : nil) : .failed
            iCloudApplied = outcome == .added
            if outcome != .added { await onICloudSkipped(outcome) }
        }
        // After iCloud, before XSide's module: tweaks get what header room is left once the
        // module's command is set aside. Never fails the install.
        var tweakPaths = false
        if let tweakPlan {
            await onTweaks(nil)
            // An .ipa XSide signed before already loads its module: that command goes, and comes
            // back after the tweaks' (the module stays last). The Duo copy has its own order.
            if library, duoApplied == nil, !tweakPlan.planned.isEmpty,
               MachOPatcher.loadsAnySlice(Self.welcomeLoadPath, in: executableURL) {
                _ = try? MachOPatcher.removeDylibs(where: { $0 == Self.welcomeLoadPath }, from: executableURL,
                                                   movable: Self.isXSideLoadPath)
            }
            let reserve = library && !MachOPatcher.loadsDylib(Self.welcomeLoadPath, in: executableURL)
                ? MachOPatcher.dylibCommand(Self.welcomeLoadPath).count : 0
            let applied = await applyTweaks(tweakPlan, app: app, executable: executableURL, reserve: reserve,
                                            identity: identitySHA1)
            tweakPaths = applied.supportAdded
            await onTweaks(applied.report)
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
                          language: textLanguage(facts), duo: duoApplied, iCloud: iCloudKeys, tweakPaths: tweakPaths)
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
        // A tweak's bundles too: their seals went with the sweep above.
        let targets = signTargets(in: app, bundlesUnder: app.appendingPathComponent(TweakLayout.folder))
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

    // MARK: - Libraries from an earlier signing

    /// Removes from `Frameworks/` the XSide libraries an earlier XSide signing put there and this
    /// one won't add again (`keepWelcome`, `keepICloud`: it will, replacing them), and their load
    /// commands. The Duo compatibility module stays while the Info.plist names its scene delegate
    /// (the raised SDK needs it; the Duo step replaces it when the option is on); otherwise it is
    /// inert, and goes too. A load command that can't be removed without moving the app's own
    /// libraries stays: it is weak, and the file is gone. Never fails the install.
    private func removeStaleLibraries(app: URL, executable: URL, keepWelcome: Bool, keepICloud: Bool) {
        let fm = FileManager.default
        var stale: [(name: String, loadPath: String)] = []
        if !keepWelcome { stale.append((Self.welcomeName, Self.welcomeLoadPath)) }
        if !keepICloud { stale.append((ICloudSignedOut.dylibName, ICloudSignedOut.loadPath)) }
        if !namesDuoLegacyDelegate(app) { stale.append((DuoCompatibility.legacyDylibName, DuoCompatibility.legacyLoadPath)) }
        var paths = Set<String>()
        // Tweaks an earlier signing injected: all go (this signing copies its own again).
        let tweaks = app.appendingPathComponent(TweakLayout.folder)
        if exists(tweaks) {
            do {
                try fm.removeItem(at: tweaks)
                Self.logger.info("removed the tweaks of an earlier signing")
            } catch {
                Self.logger.notice("tweaks from an earlier signing not removed: \(String(describing: error))")
            }
        }
        let tweakLoads = ((try? MachOPatcher.linkedDylibs(in: executable)) ?? []).filter { $0.hasPrefix(TweakLayout.loadPrefix) }
        paths.formUnion(tweakLoads)
        for library in stale {
            let file = app.appendingPathComponent("Frameworks/\(library.name)")
            let present = (try? fm.attributesOfItem(atPath: file.path)) != nil
            if present {
                do { try fm.removeItem(at: file) } catch {
                    Self.logger.notice("\(library.name) from an earlier signing not removed: \(String(describing: error))")
                }
            }
            if present || MachOPatcher.loadsAnySlice(library.loadPath, in: executable) { paths.insert(library.loadPath) }
            if present { Self.logger.info("removed \(library.name) from an earlier signing") }
        }
        guard !paths.isEmpty else { return }
        do {
            let removed = try MachOPatcher.removeDylibs(where: paths.contains, from: executable, movable: Self.isXSideLoadPath)
            if !removed.isEmpty { Self.logger.info("removed \(removed.count) load command(s) from an earlier signing") }
        } catch {
            Self.logger.notice("load commands from an earlier signing kept: \(String(describing: error))")
        }
    }

    /// A library XSide adds (its module, signed-out iCloud, the Duo module, tweaks): nothing in
    /// the app binds to it, so its load command may move.
    static func isXSideLoadPath(_ path: String) -> Bool {
        [welcomeLoadPath, ICloudSignedOut.loadPath, DuoCompatibility.legacyLoadPath].contains(path)
            || path.hasPrefix(TweakLayout.loadPrefix)
    }

    // MARK: - Tweaks

    /// One tweak that goes in, as planned before Duo.
    struct PlannedTweak {
        let item: TweakSigningItem
        let classification: TweakClassification
        /// The verdict that applies (« Injecter quand même »: the filter's problem ignored).
        let verdict: TweakVerdict
        var id: String { item.package.id }
        var converted: Bool { if case .converted = verdict { true } else { false } }
        var needsSupport: Bool { if case .converted(let c) = verdict { c.contains(.jailbreakPaths) } else { false } }
        var loadPaths: [String] { item.package.entries.map { TweakLayout.loadPath(item.package, $0) } }
    }

    struct TweakPlan {
        var planned: [PlannedTweak]
        /// Items left out by the plan (incompatible, or their stored folder is missing).
        var results: [String: TweakResult]
        /// Every item's id, in list order (each once).
        var order: [String]
        /// Each embedded provider's own name rewrites, by package id.
        var providerResolutions: [String: [String: String]]

        func needsElleKit(_ t: PlannedTweak) -> Bool {
            t.classification.resolution.values.contains(TweakLayout.elleKitLoadPath)
                || t.classification.providers.contains { providerResolutions[$0.id]?.values.contains(TweakLayout.elleKitLoadPath) == true }
        }

        /// What the executable loads for the planned tweaks, in order: ElleKit, the support
        /// library, then each tweak's entries (what the Duo copy carries).
        var loadPaths: [String] {
            (planned.contains(where: needsElleKit) ? [TweakLayout.elleKitLoadPath] : [])
                + (planned.contains(where: \.needsSupport) ? [TweakLayout.supportLoadPath] : [])
                + planned.flatMap(\.loadPaths)
        }
    }

    /// Classifies each item for this app and device, once (again only when a package another
    /// one could rely on is left out). Reads only. A missing stored folder → `.failed`; an
    /// incompatible tweak (unless forced and overridable) → `.incompatible`.
    private func planTweaks(_ items: [TweakSigningItem], deviceOS: String?, app: URL, executable: URL,
                            info: AppInfo) -> TweakPlan {
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.package.id).inserted }
        var results: [String: TweakResult] = [:]
        // A person's package only, by its id's form (never a path, never `deps`).
        for item in unique where !AppLibrary.isTweakID(item.package.id) || item.package.origin == .embedded {
            Self.logger.notice("tweak \(item.package.name) skipped: not a package of the library (id or origin)")
            results[item.package.id] = .skipped(.failed)
        }
        for item in unique where results[item.package.id] == nil && !Self.isRealDirectory(URL(fileURLWithPath: item.directory)) {
            Self.logger.notice("tweak \(item.package.name) (\(item.package.id)) skipped: its stored folder is missing")
            results[item.package.id] = .skipped(.failed)
        }
        let linked = try? MachOPatcher.linkedDylibs(in: executable)
        let frameworks = linked.map { names in
            Set(names.compactMap { name -> String? in
                let prefix = "/System/Library/Frameworks/"
                guard name.hasPrefix(prefix), let folder = name.dropFirst(prefix.count).split(separator: "/").first,
                      folder.hasSuffix(".framework") else { return nil }
                return String(folder.dropLast(".framework".count))
            })
        }
        let appPath = app.path
        var context = TweakContext(
            originalBundleID: info.bundleID, executableName: info.executable,
            appClassNames: (try? ObjCClassScanner.classes(in: executable)).map { Set($0.map(\.name)) },
            appLinkedFrameworks: frameworks,
            appFiles: { rel in
                guard !rel.isEmpty, !rel.hasPrefix("/"),
                      !rel.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." }) else { return false }
                var st = stat()
                return lstat(appPath + "/" + rel, &st) == 0
            },
            deviceOS: deviceOS,
            elleKitAvailable: Self.isRegularFile(elleKitLibrary) && Self.isRegularFile(elleKitLicense),
            supportAvailable: Self.isRegularFile(tweakSupportLibrary),
            elleKitHasLibhooker: elleKitHasLibhooker,
            isSystemLibrary: TweakClassifier.systemLibraries(sdk: Self.iOSSDK()),
            embedded: TweakDependencyCatalog.load(from: tweakDependencies))
        // Packages left out can't provide for others: classified again without them (XSide's own
        // copy may then do), until nothing more is left out.
        var planned: [PlannedTweak] = []
        for _ in 0...unique.count {
            let usable = unique.filter { results[$0.package.id] == nil }
            var excluded = false
            planned = []
            for item in usable {
                context.others = usable.filter { $0.package.id != item.package.id }.map(\.package)
                let c = TweakClassifier.classify(item.package, context)
                let verdict = item.force && c.verdict.canOverride ? c.verdictOverridingFilter : c.verdict
                if case .incompatible(let problem) = verdict {
                    Self.logger.notice("tweak \(item.package.name) (\(item.package.id)) skipped: \(String(describing: problem))")
                    results[item.package.id] = .skipped(.incompatible(problem))
                    excluded = true
                    continue
                }
                planned.append(PlannedTweak(item: item, classification: c, verdict: verdict))
            }
            if !excluded { break }
        }
        var providerResolutions: [String: [String: String]] = [:]
        for p in planned.flatMap(\.classification.providers) where providerResolutions[p.id] == nil {
            providerResolutions[p.id] = TweakClassifier.classify(p, context).resolution
        }
        return TweakPlan(planned: planned, results: results, order: unique.map(\.package.id),
                         providerResolutions: providerResolutions)
    }

    /// Copies, rewrites and signs the planned tweaks and what they need into
    /// `Frameworks/XSideTweaks/`, then adds their weak load commands: lowest priority, `reserve`
    /// bytes kept for XSide's module. A tweak that can't go in is left out with what it brought
    /// (files, load commands) and the reason; the others go on. Returns the report and whether the
    /// support library is in.
    private func applyTweaks(_ plan: TweakPlan, app: URL, executable: URL, reserve: Int,
                             identity: String) async -> (report: TweakSigningReport, supportAdded: Bool) {
        let fm = FileManager.default
        let root = app.appendingPathComponent(TweakLayout.folder)
        var results = plan.results
        var chosen: [PlannedTweak] = []
        func skip(_ t: PlannedTweak, _ why: TweakSkip, _ reason: String) {
            Self.logger.notice("tweak \(t.item.package.name) (\(t.id)) skipped: \(reason)")
            results[t.id] = .skipped(why)
            // Only ever a tweak's own folder, a direct child of `root`.
            if AppLibrary.isTweakID(t.id) { try? fm.removeItem(at: root.appendingPathComponent(t.id)) }
        }
        // The other items a tweak's rewritten names lead to.
        func reliesOn(_ t: PlannedTweak) -> [String] {
            plan.planned.map(\.id).filter { other in
                other != t.id && t.classification.resolution.values.contains { $0.hasPrefix(TweakLayout.loadPrefix + other + "/") }
            }
        }
        // A tweak whose provider (another item) is left out goes too, for the same reason.
        func cascade() {
            var changed = true
            while changed {
                changed = false
                for t in chosen {
                    guard let missing = reliesOn(t).first(where: { id in !chosen.contains { $0.id == id } }) else { continue }
                    let why: TweakSkip = if case .skipped(let s)? = results[missing], s == .noRoom { .noRoom } else { .failed }
                    skip(t, why, "the package it relies on (\(missing)) isn't in")
                    chosen.removeAll { $0.id == t.id }
                    changed = true
                }
            }
        }

        // 1. Files: each tweak's folder, then XSide's dependencies it needs (once each).
        if exists(root) {
            for t in plan.planned { skip(t, .failed, "the earlier signing's tweaks couldn't be removed") }
        } else {
            var providers: [String: Bool] = [:]
            for t in plan.planned {
                let dest = root.appendingPathComponent(TweakLayout.directory(t.item.package))
                if exists(dest) { skip(t, .failed, "its folder name is taken"); continue }
                do {
                    try copyPackage(t.item.package, from: URL(fileURLWithPath: t.item.directory), to: dest)
                    try prepareBinaries(of: t.item.package, at: dest, resolution: t.classification.resolution)
                    try await signTweakFiles(of: t.item.package, at: dest, identity: identity)
                } catch {
                    skip(t, .failed, String(describing: error))
                    continue
                }
                var ready = true
                for p in t.classification.providers {
                    if providers[p.id] == nil {
                        providers[p.id] = await copyProvider(p, into: root, resolution: plan.providerResolutions[p.id] ?? [:],
                                                             identity: identity)
                    }
                    if providers[p.id] != true { ready = false }
                }
                if !ready { skip(t, .failed, "an embedded dependency couldn't be copied"); continue }
                chosen.append(t)
            }
            cascade()
        }
        // ElleKit with its licence, and the support library, when a tweak still needs them.
        if chosen.contains(where: plan.needsElleKit), !copyLibrary(elleKitLibrary, as: TweakLayout.elleKitName, into: root)
            || !copyLibrary(elleKitLicense, as: TweakLayout.elleKitLicenseName, into: root) {
            for t in chosen where plan.needsElleKit(t) { skip(t, .failed, "ElleKit couldn't be copied") }
            chosen.removeAll(where: plan.needsElleKit)
            cascade()
        }
        if chosen.contains(where: \.needsSupport), !copyLibrary(tweakSupportLibrary, as: TweakLayout.supportName, into: root) {
            for t in chosen where t.needsSupport { skip(t, .failed, "the support library couldn't be copied") }
            chosen.removeAll(where: \.needsSupport)
            cascade()
        }

        // 2. Load commands, lowest priority: in list order, each tweak only if its commands (and
        // ElleKit's or the support library's, the first time) fit beside XSide's module.
        func cost(_ path: String) -> Int {
            MachOPatcher.loadsDylib(path, in: executable) ? 0 : MachOPatcher.dylibCommand(path).count
        }
        let all = (chosen.contains(where: plan.needsElleKit) ? [TweakLayout.elleKitLoadPath] : [])
            + (chosen.contains(where: \.needsSupport) ? [TweakLayout.supportLoadPath] : []) + chosen.flatMap(\.loadPaths)
        makeRoom(in: executable, needing: all.reduce(reserve) { $0 + cost($1) })
        var free = ((try? MachOPatcher.freeSpace(in: executable)) ?? 0) - reserve
        var withElleKit = false, withSupport = false
        for t in chosen {
            let elle = plan.needsElleKit(t) && !withElleKit, support = t.needsSupport && !withSupport
            let needed = t.loadPaths.reduce(0) { $0 + cost($1) }
                + (elle ? cost(TweakLayout.elleKitLoadPath) : 0) + (support ? cost(TweakLayout.supportLoadPath) : 0)
            guard needed == 0 || needed <= free else {
                skip(t, .noRoom, "no room left in the app's header (\(max(free, 0)) bytes for \(needed))")
                chosen.removeAll { $0.id == t.id }
                continue
            }
            free -= needed
            if elle { withElleKit = true }
            if support { withSupport = true }
        }
        cascade()
        // Written in their order: ElleKit, the support library (before any tweak), the tweaks.
        func add(_ path: String) -> Bool {
            do { _ = try MachOPatcher.addWeakDylib(path, to: executable); return true } catch {
                Self.logger.notice("tweaks: \(path) not loaded: \(String(describing: error))")
                return false
            }
        }
        if chosen.contains(where: plan.needsElleKit), !add(TweakLayout.elleKitLoadPath) {
            for t in chosen where plan.needsElleKit(t) { skip(t, .failed, "ElleKit's load command couldn't be added") }
            chosen.removeAll(where: plan.needsElleKit)
        }
        if chosen.contains(where: \.needsSupport), !add(TweakLayout.supportLoadPath) {
            for t in chosen where t.needsSupport { skip(t, .failed, "the support library's load command couldn't be added") }
            chosen.removeAll(where: \.needsSupport)
        }
        for t in chosen where !t.loadPaths.allSatisfy(add) {
            skip(t, .failed, "its load command couldn't be added")
            chosen.removeAll { $0.id == t.id }
        }
        cascade()

        // A library package (no entries) that no tweak still in relies on is not part of the app.
        var used = Set(chosen.filter { !$0.item.package.entries.isEmpty || $0.item.package.kind != .deb }.map(\.id))
        var grew = true
        while grew {
            grew = false
            for t in chosen where used.contains(t.id) {
                for id in reliesOn(t) where used.insert(id).inserted { grew = true }
            }
        }
        for t in chosen where !used.contains(t.id) {
            Self.logger.info("tweak \(t.item.package.name) (\(t.id)) left out: a library no tweak here uses")
            if AppLibrary.isTweakID(t.id) { try? fm.removeItem(at: root.appendingPathComponent(t.id)) }
            results[t.id] = nil
        }
        chosen.removeAll { !used.contains($0.id) }

        // 3. What the left-out tweaks brought goes: load commands (the Duo copy's too), files.
        let needElleKit = chosen.contains(where: plan.needsElleKit), needSupport = chosen.contains(where: \.needsSupport)
        let kept = Set((needElleKit ? [TweakLayout.elleKitLoadPath] : []) + (needSupport ? [TweakLayout.supportLoadPath] : [])
                       + chosen.flatMap(\.loadPaths))
        let stale = Set(plan.loadPaths + [TweakLayout.elleKitLoadPath, TweakLayout.supportLoadPath])
            .filter { !kept.contains($0) && MachOPatcher.loadsAnySlice($0, in: executable) }
        if !stale.isEmpty {
            do { _ = try MachOPatcher.removeDylibs(where: stale.contains, from: executable, movable: Self.isXSideLoadPath) } catch {
                Self.logger.notice("tweaks: load commands of left-out tweaks kept (weak, files gone): \(String(describing: error))")
            }
        }
        if !needElleKit {
            try? fm.removeItem(at: root.appendingPathComponent(TweakLayout.elleKitName))
            try? fm.removeItem(at: root.appendingPathComponent(TweakLayout.elleKitLicenseName))
        }
        if !needSupport { try? fm.removeItem(at: root.appendingPathComponent(TweakLayout.supportName)) }
        let neededDeps = Set(chosen.flatMap(\.classification.providers).map(\.id))
        var embedded: [String] = []
        var depsSeen = Set<String>()
        for p in plan.planned.flatMap(\.classification.providers) where depsSeen.insert(p.id).inserted {
            if neededDeps.contains(p.id) { embedded.append(p.packageID) } else {
                try? fm.removeItem(at: root.appendingPathComponent(TweakLayout.directory(p)))
            }
        }
        let deps = root.appendingPathComponent(TweakLayout.depsFolder)
        if (try? fm.contentsOfDirectory(atPath: deps.path))?.isEmpty == true { try? fm.removeItem(at: deps) }
        if (try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty == true { try? fm.removeItem(at: root) }

        for t in chosen { results[t.id] = .injected(converted: t.converted) }
        if !chosen.isEmpty {
            Self.logger.info("tweaks: \(chosen.count) injected\(embedded.isEmpty ? "" : ", with \(embedded.joined(separator: ", "))")")
        }
        return (TweakSigningReport(results: results.filter { id, _ in plan.order.contains(id) }, embedded: embedded),
                needSupport)
    }

    /// Copies the files `package` lists from its stored folder `source` into `dest`: only real
    /// files under real folders (no link anywhere, nothing outside), every binary among them.
    private func copyPackage(_ package: TweakPackage, from source: URL, to dest: URL) throws {
        struct Refused: Error, CustomStringConvertible { let description: String }
        guard Self.isRealDirectory(source) else { throw Refused(description: "its stored folder is missing") }
        let files = Set(package.files)
        guard package.binaries.allSatisfy({ files.contains($0.path) }) else { throw Refused(description: "a binary isn't among its files") }
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for path in package.files {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.utf8.contains(0), parts.count <= DebLimits.maxPathDepth,
                  !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw Refused(description: "unsafe file path")
            }
            var url = source
            for (i, part) in parts.enumerated() {
                url.appendPathComponent(String(part))
                var st = stat()
                guard lstat(url.path, &st) == 0,
                      st.st_mode & S_IFMT == (i == parts.count - 1 ? S_IFREG : S_IFDIR) else {
                    throw Refused(description: "\(path) is missing or not a plain file")
                }
            }
            let to = dest.appendingPathComponent(path)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: to)
        }
    }

    /// Keeps only the arm64 slices of each binary (no 32-bit ARM, i386 or x86_64) and gives its library names their new paths
    /// (throws `MachOPatcher.Failure.noRoom` when one doesn't fit).
    private func prepareBinaries(of package: TweakPackage, at dest: URL, resolution: [String: String]) throws {
        for binary in package.binaries {
            let url = dest.appendingPathComponent(binary.path)
            let data = try Data(contentsOf: url)
            if let thinned = MachOThinner.keepingARM64(from: data) { try thinned.write(to: url, options: .atomic) }
            _ = try MachOPatcher.rewriteDylibNames(resolution, in: url)
        }
    }

    /// Signs the package's binaries, then its `.framework` / `.dylib` items, as the signing step
    /// will: one that can't be signed leaves the tweak out instead of failing the install.
    private func signTweakFiles(of package: TweakPackage, at dest: URL, identity: String) async throws {
        let targets = signTargets(in: dest, bundlesUnder: dest)
        for target in targets {
            try requireType(target.pathExtension == "dylib" ? .typeRegular : .typeDirectory, target)
        }
        let covered = Set(targets.map(\.standardizedFileURL.path))
        for binary in package.binaries {
            let url = dest.appendingPathComponent(binary.path)
            if !covered.contains(url.standardizedFileURL.path) { try await sign(url, identity: identity, entitlements: nil) }
        }
        for target in targets { try await sign(target, identity: identity, entitlements: nil) }
    }

    /// XSide's embedded package `p` into `deps/<packageID>/`, thinned, rewritten and signed.
    private func copyProvider(_ p: TweakPackage, into root: URL, resolution: [String: String], identity: String) async -> Bool {
        let dest = root.appendingPathComponent(TweakLayout.directory(p))
        do {
            guard let catalog = tweakDependencies else { throw XSideError.invalidIPA("no embedded dependencies") }
            try copyPackage(p, from: catalog.appendingPathComponent(p.packageID), to: dest)
            try prepareBinaries(of: p, at: dest, resolution: resolution)
            try await signTweakFiles(of: p, at: dest, identity: identity)
            return true
        } catch {
            try? FileManager.default.removeItem(at: dest)
            Self.logger.notice("tweaks: \(p.packageID) not copied: \(String(describing: error))")
            return false
        }
    }

    /// Copies one of XSide's files (ElleKit, its licence, the support library) into `root`.
    private func copyLibrary(_ source: URL?, as name: String, into root: URL) -> Bool {
        guard let source, Self.isRegularFile(source) else { return false }
        let target = root.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if exists(target) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: source, to: target)
            return true
        } catch {
            try? FileManager.default.removeItem(at: target)
            Self.logger.notice("tweaks: \(name) not copied: \(String(describing: error))")
            return false
        }
    }

    /// The iOS SDK of the job's Xcode (`DEVELOPER_DIR`), for which `/usr/lib` names iOS ships.
    private static func iOSSDK() -> URL? {
        guard let dir = CommandEnvironment.overrides["DEVELOPER_DIR"] ?? ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
              !dir.isEmpty else { return nil }
        let sdk = URL(fileURLWithPath: dir).appendingPathComponent("Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk")
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: sdk.path, isDirectory: &isDir) && isDir.boolValue ? sdk : nil
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    private static func isRegularFile(_ url: URL?) -> Bool {
        guard let url else { return false }
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG
    }

    // MARK: - Signed-out iCloud

    /// Copies `XSideICloud.dylib` into `Frameworks/` and makes the executable load it (weakly: a
    /// missing library never stops the app, it then behaves as without the option). When the
    /// header lacks room for it (and for `alsoLoading`, XSide's module, added next), the build
    /// Mac's toolchain run paths go first. Never fails the install: on any problem the library is
    /// removed. The executable may still name it when the iPhone Duo patch already added the load
    /// command (its copy carries both): harmless, the command is weak and the app runs as without
    /// the option. When the header has room for only one of the two (even without those run paths),
    /// XSide's module keeps it: `.noRoomBesideModule`, nothing of the library left.
    private func addICloudLibrary(to app: URL, executable: URL, alsoLoading other: String?) -> ICloudOutcome {
        guard let iCloudLibrary else { return .failed }
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
            // Room for one of the two only: XSide's module keeps it (the person turned the
            // module off otherwise), and the install says signed-out iCloud wasn't added for that.
            if let other, !MachOPatcher.loadsDylib(ICloudSignedOut.loadPath, in: executable),
               !MachOPatcher.loadsDylib(other, in: executable),
               let free = try? MachOPatcher.freeSpace(in: executable), free < needed {
                try? fm.removeItem(at: target)
                Self.logger.notice("signed-out iCloud skipped: room for one load command only (\(free) bytes for \(needed)), kept for XSide's module")
                return .noRoomBesideModule
            }
            let outcome = try MachOPatcher.addWeakDylib(ICloudSignedOut.loadPath, to: executable)
            Self.logger.info("signed-out iCloud added (\(outcome == .added ? "new load command" : "already loaded"))")
            return .added
        } catch {
            try? fm.removeItem(at: target)
            Self.logger.notice("signed-out iCloud skipped: \(String(describing: error))")
            return .failed
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
        /// The app has no scene support: XSide's compatibility module goes in, its delegate named.
        var legacyModule = false
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
        guard let support = DuoCompatibility.sceneSupport(for: info) else {
            Self.logger.info("duo compatibility: built with SDK \(info.sdkVersion ?? "?"), nothing to do")
            return .skip(.alreadySupported)
        }
        let legacy = support == .legacyModule
        if legacy, duoLegacyLibrary.map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
            Self.logger.notice("duo compatibility skipped: no scene support and no compatibility module in this build")
            return .skip(.notPossible)
        }
        guard let growth = try? MachOBuildInfo.versionCommandGrowth(of: executable) else {
            Self.logger.notice("duo compatibility skipped: unreadable executable")
            return .skip(.failed)
        }
        let delegate = DuoCompatibility.manifestDelegate(for: support)
        Self.logger.info("duo compatibility: SDK \(info.sdkVersion ?? "?"), scene delegate \(delegate ?? "(own manifest)")\(legacy ? " (compatibility module)" : "")")
        return .plan(DuoPlan(growth: growth, sceneDelegate: delegate, legacyModule: legacy))
    }

    /// Copies `XSideDuoLegacy.dylib` into the app's `Frameworks/`. Returns where, nil on failure
    /// (nothing left behind).
    private func copyDuoLegacyLibrary(to app: URL) -> URL? {
        guard let duoLegacyLibrary else { return nil }
        let fm = FileManager.default
        let target = app.appendingPathComponent("Frameworks/\(DuoCompatibility.legacyDylibName)")
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if exists(target) { try fm.removeItem(at: target) }
            try fm.copyItem(at: duoLegacyLibrary, to: target)
            return target
        } catch {
            try? fm.removeItem(at: target)
            Self.logger.notice("duo compatibility module not copied: \(String(describing: error))")
            return nil
        }
    }

    /// Gives every slice of the executable SDK 27.1 with `xcrun vtool` (the job's Xcode),
    /// keeping its minimum iOS. Done on a copy: when the header lacks room for the bigger
    /// version command (and XSide's), the copy loses the build Mac's toolchain run paths first; the copy
    /// replaces the executable only once every slice declares 27.1. Never fails the install: on
    /// any problem the executable stays exactly as it was (run paths included). Returns whether
    /// it now declares 27.1.
    /// `loading`: XSide's libraries (its module, the signed-out iCloud one), whose load commands go
    /// in the copy first (they take room too). `required`: the Duo compatibility module, whose load
    /// command goes in before them and must fit (the patch is abandoned otherwise).
    /// `optional`: the tweaks' load commands, lowest priority: each goes in only while the room
    /// the version command needs stays free.
    private func applyDuo(to executable: URL, growth: Int, loading dylibPaths: [String], optional: [String] = [],
                          required: String? = nil, workDir: URL) async -> Bool {
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
            let all = (required.map { [$0] } ?? []) + dylibPaths + optional
            let commands = all.filter { !MachOPatcher.loadsDylib($0, in: input) }
                .reduce(0) { $0 + MachOPatcher.dylibCommand($1).count }
            makeRoom(in: input, needing: growth + commands)
            if let required {
                do { _ = try MachOPatcher.addWeakDylib(required, to: input) } catch {
                    Self.logger.notice("duo compatibility skipped: no room for the compatibility module: \(String(describing: error))")
                    return false
                }
            }
            for dylibPath in dylibPaths {
                // Its own failure (no room) is the library's, found again when it's added for real.
                do { _ = try MachOPatcher.addWeakDylib(dylibPath, to: input) } catch {
                    Self.logger.notice("duo compatibility: \(dylibPath) didn't fit: \(String(describing: error))")
                }
            }
            for dylibPath in optional where !MachOPatcher.loadsDylib(dylibPath, in: input) {
                let free = (try? MachOPatcher.freeSpace(in: input)) ?? 0
                guard free - growth >= MachOPatcher.dylibCommand(dylibPath).count else {
                    Self.logger.info("duo compatibility: \(dylibPath) left for later (Duo's room first)")
                    continue
                }
                _ = try? MachOPatcher.addWeakDylib(dylibPath, to: input)
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
    /// later (patched, or built so), and holds the compatibility module when its manifest names it.
    public func hasDuoCompatibility(_ app: URL) -> Bool {
        guard let info = try? IPAInspector.info(of: app),
              DuoCompatibility.supportsDuo(sdk: MachOBuildInfo.sdkVersion(of: app.appendingPathComponent(info.executable)))
        else { return false }
        return !namesDuoLegacyDelegate(app) || hasDuoLegacyModule(app)
    }

    /// Whether the signed `app` holds the Duo compatibility module (apps without scene support).
    public func hasDuoLegacyModule(_ app: URL) -> Bool {
        let url = app.appendingPathComponent("Frameworks/\(DuoCompatibility.legacyDylibName)")
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
            && MachOPatcher.loadsDylib(DuoCompatibility.legacyLoadPath,
                                       in: app.appendingPathComponent((try? IPAInspector.info(of: app))?.executable ?? ""))
    }

    private func namesDuoLegacyDelegate(_ app: URL) -> Bool {
        guard let data = try? IPAInspector.infoPlistData(of: app),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let manifest = plist["UIApplicationSceneManifest"] as? [String: Any],
              let configs = manifest["UISceneConfigurations"] as? [String: Any],
              let roles = configs["UIWindowSceneSessionRoleApplication"] as? [[String: Any]] else { return false }
        return roles.first?["UISceneDelegateClassName"] as? String == DuoCompatibility.legacySceneDelegateClass
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
                               iCloud: (originalBundleID: String, containers: [String])?, tweakPaths: Bool) throws {
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
        // Cleared first too; read by the tweak support library, written only when it was added.
        plist[TweakLayout.pathsKey] = nil
        plist[TweakLayout.bundlesKey] = nil
        if tweakPaths { plist[TweakLayout.pathsKey] = true }
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

    /// Every `.framework` / `.dylib` below the app (not the app itself), and every `.bundle` below
    /// `bundlesUnder` (a tweak's: signed as a bundle, after what it holds), deepest first, deduplicated.
    private func signTargets(in app: URL, bundlesUnder: URL? = nil) -> [URL] {
        var seen = Set<String>()
        let bundleRoot = bundlesUnder.map { $0.standardizedFileURL.path + "/" }
        let found = allFiles(under: app).filter {
            (["framework", "dylib"].contains($0.pathExtension)
                || ($0.pathExtension == "bundle" && bundleRoot.map($0.standardizedFileURL.path.hasPrefix) == true))
                && !isSymlink($0)
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
