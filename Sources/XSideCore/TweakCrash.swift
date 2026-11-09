import Foundation

// Tweaks in a crash: what the installation's last signing injected (its history, kept until the
// next signing even when the version was replaced since), the crash context they give, the
// « Désactiver ce tweak » / « Désactiver les tweaks convertis » fixes, and the report lines.

extension Installation {
    /// The tweaks the app on the device has: what its last signing recorded, else (older state)
    /// what its results and the pool still say.
    public func injectedTweakHistory(pool: [TweakPackage]) -> [InjectedTweak] {
        if let injectedTweaks { return injectedTweaks }
        let results = tweakResults ?? [:]
        return pool.compactMap { p in
            guard case .injected(let converted)? = results[p.id] else { return nil }
            return InjectedTweak(p, conversions: converted ? [] : nil)
        }
    }

    /// What XSide added for converted tweaks, as crash logs name the images: what the last
    /// signing recorded (ElleKit, the support library, the embedded dependencies' images). Older
    /// state recorded none: ElleKit and the support library when a tweak there was converted.
    public var tweakSupportImageNames: Set<String> {
        if let tweakSupportImages { return Set(tweakSupportImages) }
        guard injectedTweaks == nil, hasConvertedTweak else { return [] }
        return [TweakLayout.elleKitName, TweakLayout.supportName]
    }
}

extension CrashContext {
    /// The installation's tweaks, for the classifier: their images, their names, what supports them,
    /// which import C function hooks (from the pool's package; `scan` reads a binary analysed
    /// before XSide looked).
    public mutating func addTweaks(of installation: Installation, pool: [TweakPackage],
                                   scan: ((TweakPackage, TweakBinary) -> [String])? = nil) {
        let history = installation.injectedTweakHistory(pool: pool)
        tweakSupportNames.formUnion(installation.tweakSupportImageNames)
        for t in history {
            tweakIDs.insert(t.id)
            for image in t.imageNames {
                tweakNames.insert(image)
                tweakLabels[image] = TweakCrashFix.label(t)
            }
            // The version injected, else the pool's current one of the same package.
            guard let package = pool.first(where: { $0.id == t.id })
                ?? pool.first(where: { $0.origin != .embedded && $0.packageID == t.packageID }) else { continue }
            for b in package.binaries where t.imageNames.contains(b.imageName) {
                if !(b.cFunctionHooks ?? scan?(package, b) ?? []).isEmpty { cFunctionHookImages.insert(b.imageName) }
            }
        }
    }
}

public enum TweakCrashFix {
    /// Longest tweak name kept in a label or a report.
    static let maxNameLength = 60

    /// "Alpha 1.2": one line, no control characters, capped (the name comes from a .deb).
    public static func label(_ t: InjectedTweak) -> String {
        [clean(t.name, max: maxNameLength), t.version.map { clean($0, max: 30) }].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func clean(_ text: String, max: Int) -> String {
        let one = text.components(separatedBy: .newlines).joined(separator: " ")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespaces)
        return one.count > max ? String(one.prefix(max)) + "…" : one
    }

    /// The report's line for one tweak: "Alpha 1.2 (converted: ElleKit, paths, dependency added: Cephei)".
    public static func reportLine(_ t: InjectedTweak) -> String {
        let name = label(t).isEmpty ? "?" : label(t)
        guard let conversions = t.conversions else { return name }
        let parts = conversions.map { c -> String in
            switch c {
            case .hookingLibrary: "ElleKit"
            case .jailbreakPaths: "paths"
            case .dependency(let n): "dependency: \(clean(n, max: maxNameLength))"
            case .dependencyAdded(let n): "dependency added: \(clean(n, max: maxNameLength))"
            }
        }
        return parts.isEmpty ? "\(name) (converted)" : "\(name) (converted: \(parts.joined(separator: ", ")))"
    }

    /// The installation's tweaks named by `history` (by id, and the pool's current version of the
    /// same package: a replaced version is renamed in the device's list).
    static func ids(of history: [InjectedTweak], pool: [TweakPackage]) -> Set<String> {
        let packages = Set(history.map(\.packageID))
        return Set(history.map(\.id)).union(pool.filter { $0.origin != .embedded && packages.contains($0.packageID) }.map(\.id))
    }

    /// The injected tweak the crash is in (`subject`: its image name).
    public static func tweak(image: String, in installation: Installation, pool: [TweakPackage]) -> InjectedTweak? {
        installation.injectedTweakHistory(pool: pool).first { $0.imageNames.contains(image) }
    }

    /// `uses` with the tweaks of `history` disabled; nil when none of them is listed enabled.
    static func disabling(_ history: [InjectedTweak], in uses: [TweakUse], pool: [TweakPackage]) -> [TweakUse]? {
        let ids = ids(of: history, pool: pool)
        guard uses.contains(where: { $0.enabled && ids.contains($0.id) }) else { return nil }
        return uses.map { ids.contains($0.id) ? TweakUse(id: $0.id, enabled: false, force: $0.force) : $0 }
    }

    /// « Désactiver ce tweak »: `installation`'s list with the tweak whose image is `image`
    /// disabled (kept in the list, to turn back on). nil: nothing to change.
    public static func disablingTweak(image: String, crashed: Installation, in installation: Installation,
                                      pool: [TweakPackage]) -> [TweakUse]? {
        guard let t = tweak(image: image, in: crashed, pool: pool) else { return nil }
        return disabling([t], in: installation.tweaks ?? [], pool: pool)
    }

    /// « Désactiver les tweaks convertis »: `installation`'s list with every tweak converted in
    /// `crashed`'s last signing disabled. nil: nothing to change.
    public static func disablingConverted(crashed: Installation, in installation: Installation,
                                          pool: [TweakPackage]) -> [TweakUse]? {
        let converted = crashed.injectedTweakHistory(pool: pool).filter(\.converted)
        guard !converted.isEmpty else { return nil }
        return disabling(converted, in: installation.tweaks ?? [], pool: pool)
    }

    /// The installations (of the app) the fix would change: more than one → ask where.
    public static func affected(_ action: CrashAction, subject: String?, crashed: Installation,
                                record: AppRecord) -> [Installation] {
        let pool = record.tweaks ?? []
        return record.installations.filter { i in
            switch action {
            case .disableTweak: subject.flatMap { disablingTweak(image: $0, crashed: crashed, in: i, pool: pool) } != nil
            case .disableConvertedTweaks: disablingConverted(crashed: crashed, in: i, pool: pool) != nil
            default: false
            }
        }
    }

    /// The fix to offer for `d`: `CrashAction.suggested`, except a tweak fix that would change
    /// no installation (already off, or no subject): no button then.
    public static func action(for d: CrashDiagnosis, crashed: Installation, record: AppRecord) -> CrashAction? {
        guard let action = CrashAction.suggested(for: d) else { return nil }
        guard action == .disableTweak || action == .disableConvertedTweaks else { return action }
        return affected(action, subject: d.subject, crashed: crashed, record: record).isEmpty ? nil : action
    }

    /// "N tweaks (M converted)" for the diagnostic summary; nil: none.
    public static func summary(_ installation: Installation, pool: [TweakPackage]) -> String? {
        let history = installation.injectedTweakHistory(pool: pool)
        guard !history.isEmpty else { return nil }
        let converted = history.filter(\.converted).count
        return "\(history.count) tweak\(history.count == 1 ? "" : "s") (\(converted) converted)"
    }
}

extension AppLibrary {
    /// « Désactiver ce tweak » / « Désactiver les tweaks convertis » after a crash on `deviceID`:
    /// the tweak (`diagnosis.subject`, its image) or the converted tweaks of that device's last
    /// signing are disabled there, or on every installation listing them (`allDevices`), in one
    /// save. True when the crashed device's list changed (its refresh is worth starting); false
    /// when there was nothing to change there. Throws when the save failed (nothing changed).
    public func disableTweaksAfterCrash(_ action: CrashAction, diagnosis: CrashDiagnosis?, recordID: UUID, deviceID: String,
                                        allDevices: Bool) throws -> Bool {
        guard action == .disableTweak || action == .disableConvertedTweaks,
              let record = records().first(where: { $0.id == recordID }),
              let crashed = record.installations.first(where: { $0.deviceID == deviceID }) else { return false }
        let subject = diagnosis?.subject
        if action == .disableTweak, subject == nil { return false }
        let pool = record.tweaks ?? []
        var changes: [String: [TweakUse]] = [:]
        for i in record.installations where allDevices || i.deviceID == deviceID {
            let uses = action == .disableTweak
                ? TweakCrashFix.disablingTweak(image: subject!, crashed: crashed, in: i, pool: pool)
                : TweakCrashFix.disablingConverted(crashed: crashed, in: i, pool: pool)
            if let uses { changes[i.deviceID] = uses }
        }
        guard !changes.isEmpty else { return false }
        try changeInstallationTweaks(changes, recordID: recordID)
        return changes[deviceID] != nil
    }
}
