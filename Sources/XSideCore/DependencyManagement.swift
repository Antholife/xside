import Foundation

/// Where a dependency the person downloads or adds for a tweak goes, device by device.
///
/// A tweak that is ❌ only because a known library (Cephei…) is missing starts off on that
/// device: its switch can't be on. « Where the tweak is on » alone would then put the
/// dependency nowhere, and nothing would change on screen (device test 2026-11-09). So the
/// dependency also goes where it unblocks the tweak, and the tweak is turned on there; a tweak
/// the person turned off (no ❌) stays off and gets nothing there.
public enum DependencyPlacement {
    public struct Device: Sendable {
        public let id: String
        /// That device's context without the new dependency.
        public let context: TweakContext
        /// The tweak's switch there.
        public let tweakOn: Bool

        public init(id: String, context: TweakContext, tweakOn: Bool) {
            self.id = id
            self.context = context
            self.tweakOn = tweakOn
        }
    }

    public struct Plan: Equatable, Sendable {
        /// The devices the dependency is turned on for.
        public var dependencyOn: Set<String>
        /// The devices where the tweak goes from off (❌) to on, thanks to it.
        public var tweakTurnedOn: Set<String>
    }

    /// Where the tweak is on, and where the dependency unblocks it (the tweak is turned on there).
    /// When that is nowhere, the devices where the tweak misses it, so the person sees it added.
    public static func plan(tweak: TweakPackage, adding dependency: TweakPackage, devices: [Device]) -> Plan {
        var on = Set<String>(), turnedOn = Set<String>(), missingOn = Set<String>()
        let names = Set([dependency.packageID] + dependency.provides)
        for d in devices {
            if !names.isDisjoint(with: DependencyRows.missing(tweak, d.context)) { missingOn.insert(d.id) }
            if d.tweakOn { on.insert(d.id); continue }
            guard case .incompatible = TweakClassifier.verdict(tweak, d.context) else { continue }
            var with = d.context
            with.others.append(dependency)
            if case .incompatible = TweakClassifier.verdict(tweak, with) { continue }
            on.insert(d.id)
            turnedOn.insert(d.id)
        }
        return Plan(dependencyOn: on.isEmpty ? missingOn : on, tweakTurnedOn: turnedOn)
    }
}

extension DependencyRows {
    /// The packages of `packages` that ask for `dependency` (by its package id or what it
    /// provides), in their order: « Dépendance de … ». Other versions of it aren't.
    public static func dependents(of dependency: TweakPackage, among packages: [TweakPackage]) -> [TweakPackage] {
        let names = Set([dependency.packageID] + dependency.provides)
        return packages.filter { p in
            p.id != dependency.id && p.packageID != dependency.packageID
                && p.depends.contains { group in group.contains { names.contains($0.package) } }
        }
    }

    /// The tweaks of `enabled` (one device's enabled packages, `dependency` among them) that
    /// become ❌ once `dependency` is gone. `context`: that device's, its `others` replaced.
    public static func brokenByRemoving(_ dependency: TweakPackage, enabled: [TweakPackage],
                                        context: TweakContext) -> [TweakPackage] {
        dependents(of: dependency, among: enabled).filter { p in
            var before = context, after = context
            before.others = enabled.filter { $0.id != p.id }
            after.others = before.others.filter { $0.id != dependency.id }
            if case .incompatible = TweakClassifier.verdict(p, before) { return false }
            if case .incompatible = TweakClassifier.verdict(p, after) { return true }
            return false
        }
    }
}

extension DependencyDownloader {
    /// « Mettre à jour »: the trusted repo (or the author's pinned releases) is asked, only on the
    /// click, and its best version that still satisfies `dependency` is returned when it is newer
    /// than `installed`; nil when up to date.
    public func update(_ dependency: DebDependency, installed: String,
                       preferredArchitecture: String?) async throws -> DependencySource? {
        guard DependencySources.canDownload(dependency.package) else { throw RepoError.notAllowlisted }
        let offer = try await offer(dependency, preferredArchitecture: preferredArchitecture)
        return DebVersion.compare(offer.version, installed) == .orderedDescending ? offer : nil
    }
}

/// One kept download (Settings: « Dépendances téléchargées ») and the apps whose pool uses it.
public struct DownloadUsage: Equatable, Sendable, Identifiable {
    public let sha256: String
    public let packageID: String
    public let version: String
    /// The trusted repo's id, and its name (the id when no longer trusted).
    public let repo: String
    public let repoName: String
    public let size: Int64
    public let downloadedAt: Date
    /// Display names of the apps whose tweak pool has a package from this file, sorted.
    public let apps: [String]
    /// Per app (same order), the tweaks that need it and where each is on.
    public var users: [DownloadUser] = []

    /// Each app × device whose list has it, by device then app: the uninstall sheet's lines.
    public var installations: [DownloadInstallation] = []

    public var id: String { sha256 }
    public var isUsed: Bool { !apps.isEmpty }

    public init(sha256: String, packageID: String, version: String, repo: String, repoName: String, size: Int64,
                downloadedAt: Date, apps: [String], users: [DownloadUser] = [], installations: [DownloadInstallation] = []) {
        self.installations = installations
        self.sha256 = sha256
        self.packageID = packageID
        self.version = version
        self.repo = repo
        self.repoName = repoName
        self.size = size
        self.downloadedAt = downloadedAt
        self.apps = apps
        self.users = users
    }
}

/// A device's name short enough for a chip: « iPhone Duo de Anthony » → « iPhone Duo »,
/// « Anthony's iPad Air 5 » → « iPad Air 5 ». The full name stays in the switch's description.
public enum DeviceShortName {
    static let maxLength = 20

    public static func short(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // « Anthony's iPad », « Anthony’s iPhone »
        for mark in ["'s ", "’s "] {
            if let r = s.range(of: mark), !s[r.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty {
                s = String(s[r.upperBound...])
                break
            }
        }
        // « iPhone de Anthony », « iPad d'Émilie »
        for mark in [" de ", " d'", " d’"] {
            if let r = s.range(of: mark, options: .backwards), r.lowerBound > s.startIndex {
                s = String(s[..<r.lowerBound])
                break
            }
        }
        s = s.trimmingCharacters(in: .whitespaces)
        guard s.count > maxLength else { return s }
        return String(s.prefix(maxLength - 1)) + "…"
    }
}

extension DependencyRows {
    /// Which card shows a dependency's progress and result lines (by package id: the line key),
    /// `cards` in card order: the first that misses it on some device, else the first that lists
    /// it. The others say « voir … ».
    public static func lineCards(_ cards: [(id: String, rows: [DependencyRow])]) -> [String: String] {
        var missing: [String: String] = [:], listed: [String: String] = [:]
        for card in cards {
            for row in card.rows {
                let key = (row.missingDependency ?? row.dependency).package
                if listed[key] == nil { listed[key] = card.id }
                if row.isMissingAnywhere, missing[key] == nil { missing[key] = card.id }
            }
        }
        return listed.merging(missing) { _, firstMissing in firstMissing }
    }

    /// The cards' order: the tweaks in load order, each followed by the dependencies it is the
    /// first to need (and theirs), each with who needs it (« Dépendance de … »). A package no
    /// other one needs is a tweak of its own.
    public static func cardOrder(_ packages: [TweakPackage]) -> [(package: TweakPackage, dependencyOf: [String])] {
        let dependentsOf = Dictionary(uniqueKeysWithValues: packages.map { p in
            (p.id, dependents(of: p, among: packages))
        })
        var placed = Set<String>()
        var out: [(package: TweakPackage, dependencyOf: [String])] = []
        func place(_ p: TweakPackage) {
            guard placed.insert(p.id).inserted else { return }
            out.append((p, (dependentsOf[p.id] ?? []).map(\.name)))
            // Its own dependencies right after it.
            for d in packages where !placed.contains(d.id) && (dependentsOf[d.id] ?? []).contains(where: { $0.id == p.id }) {
                place(d)
            }
        }
        for p in packages where (dependentsOf[p.id] ?? []).isEmpty { place(p) }
        for p in packages { place(p) } // a cycle: in load order
        return out
    }
}

/// An app whose pool uses a kept download, and its tweaks that need it, with the devices where
/// each is on (« uYouPlus (iPhone Duo, iPad Air 5) »).
public struct DownloadUser: Equatable, Sendable {
    public struct Tweak: Equatable, Sendable {
        public let name: String
        public let deviceIDs: [String]

        public init(name: String, deviceIDs: [String]) {
            self.name = name
            self.deviceIDs = deviceIDs
        }
    }

    public let app: String
    public let tweaks: [Tweak]

    public init(app: String, tweaks: [Tweak]) {
        self.app = app
        self.tweaks = tweaks
    }
}

extension DownloadUsage {
    /// « 3 tweaks » of « … dans 2 apps ».
    public var tweakCount: Int { users.reduce(0) { $0 + $1.tweaks.count } }
}

/// One app × device whose list has a kept download (« Désinstaller… »), with the tweaks enabled
/// there that need it.
public struct DownloadInstallation: Equatable, Hashable, Sendable {
    public struct Key: Hashable, Sendable {
        public let recordID: UUID
        public let deviceID: String

        public init(recordID: UUID, deviceID: String) {
            self.recordID = recordID
            self.deviceID = deviceID
        }
    }

    public let recordID: UUID
    public let app: String
    public let deviceID: String
    public let tweaks: [String]

    public var key: Key { Key(recordID: recordID, deviceID: deviceID) }

    public init(recordID: UUID, app: String, deviceID: String, tweaks: [String]) {
        self.recordID = recordID
        self.app = app
        self.deviceID = deviceID
        self.tweaks = tweaks
    }
}

extension DependencyRows {
    /// On one device, the tweaks of `enabled` that `removed` (packages of one download, among
    /// `enabled`) leaves without what they need: ❌ or missing it once they're gone. Those are
    /// turned off there by « Désinstaller… ». One another version or package still satisfies
    /// stays on. `context`: that device's, its `others` replaced.
    public static func disabledByUninstalling(_ removed: [TweakPackage], enabled: [TweakPackage],
                                              context: TweakContext) -> [TweakPackage] {
        let gone = Set(removed.map(\.id))
        let names = Set(removed.flatMap { [$0.packageID] + $0.provides })
        let left = enabled.filter { !gone.contains($0.id) }
        let needing = Set(removed.flatMap { dependents(of: $0, among: left) }.map(\.id))
        return left.filter { p in
            guard needing.contains(p.id) else { return false }
            var after = context
            after.others = left.filter { $0.id != p.id }
            if case .incompatible = TweakClassifier.verdict(p, after) { return true }
            return !names.isDisjoint(with: missing(p, after))
        }
    }
}
