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
    /// « Mettre à jour »: the trusted repo is asked (only on the click), and its best version that
    /// still satisfies `dependency` is returned when it is newer than `installed`; nil when up to date.
    public func update(_ dependency: DebDependency, installed: String,
                       preferredArchitecture: String?) async throws -> RepoOffer? {
        guard !TrustedRepos.offering(dependency.package).isEmpty else { throw RepoError.notAllowlisted }
        let offer = try await client.offer(for: dependency, preferredArchitecture: preferredArchitecture)
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

    public var id: String { sha256 }
    public var isUsed: Bool { !apps.isEmpty }
}
