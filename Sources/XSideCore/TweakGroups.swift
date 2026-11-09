import Foundation

/// Step ③ and Settings > Mes apps sort the tweaks in three groups (device round 2, items 3, 4 and
/// 6, mockup tweaks-step-v2): « À régler » (something the person can settle is open: a missing
/// dependency, a ❌ that « Injecter quand même » or a dependency would settle; it blocks
/// « Suivant »), « Prêts » (what will be injected, per device) and « Pas compatibles » (no device
/// can ever run it: a jailbreak, an architecture, an iOS version; never injected, never blocking).
/// A tweak moves from one group to the other by itself once its problem is settled.
public enum TweakGroups {
    public enum Group: Equatable, Sendable { case toSettle, ready, incompatible }

    /// One device's view of a tweak.
    public struct DeviceState: Equatable, Sendable {
        /// As is (nil: not judged yet).
        public var verdict: TweakVerdict?
        public var isOn: Bool
        public var isForced: Bool
        /// Its last signing there injected it (a ❌ from the check made here doesn't count).
        public var signedAnyway: Bool
        /// The `Depends` packages missing there.
        public var missingDependencies: [String]

        public init(verdict: TweakVerdict?, isOn: Bool, isForced: Bool, signedAnyway: Bool = false,
                    missingDependencies: [String] = []) {
            self.verdict = verdict
            self.isOn = isOn
            self.isForced = isForced
            self.signedAnyway = signedAnyway
            self.missingDependencies = missingDependencies
        }
    }

    /// A ❌ the person can settle here (a dependency, « Injecter quand même »).
    static func canBeSettled(_ problem: TweakProblem) -> Bool {
        switch problem {
        case .missingDependency, .dependencyConflict, .madeForAnotherApp, .noFilter: true
        case .needsJailbreak, .wrongArchitecture, .notForIOS, .iOSVersion, .nothingToInject, .unreadableRequirement: false
        }
    }

    /// Per device: a dependency missing where the tweak is on blocks; a ❌ the person can settle
    /// blocks only while the tweak goes nowhere (on one device and off because of it on another
    /// is that device's choice); nothing usable anywhere and nothing to settle: not compatible.
    public static func group(_ devices: [DeviceState]) -> Group {
        var missingWhereOn = false, settleable = false, usable = false, usableOn = false
        for d in devices {
            if !d.missingDependencies.isEmpty && d.isOn { missingWhereOn = true }
            let works: Bool
            switch d.verdict {
            case nil: works = true
            case .incompatible(let problem)?:
                if d.signedAnyway || (d.verdict?.canOverride == true && d.isForced) {
                    works = true
                } else {
                    works = false
                    if canBeSettled(problem) { settleable = true }
                }
            default: works = true
            }
            if works {
                usable = true
                if d.isOn { usableOn = true }
            }
        }
        if missingWhereOn || (settleable && !usableOn) { return .toSettle }
        if devices.isEmpty || usable { return .ready }
        return .incompatible
    }

    /// « Suivant » waits while one is « À régler ».
    public static func blocks(_ group: Group) -> Bool { group == .toSettle }
}

extension DependencyDirectory {
    /// « Rechercher sur le web » for a dependency XSide knows nothing about: a DuckDuckGo search
    /// for its id, its name (when it differs) and « deb ». Only opened in the browser.
    public static func webSearchURL(packageID: String, name: String) -> URL? {
        let id = packageID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, id.utf8.count <= 128, name.utf8.count <= 200 else { return nil }
        var words = [id]
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty, n != id { words.append(n) }
        words.append("deb")
        // ASCII only: anything else (« é », « & », « + ») is percent-encoded.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let terms = words.joined(separator: " ").split(separator: " ").map {
            String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        return URL(string: "https://duckduckgo.com/?q=" + terms.joined(separator: "+"))
    }
}

/// Which card a dependency sits under (↳): the tweak that needs it, or, for a dependency of a
/// dependency, the tweak at the top. A package no other one needs is a card of its own.
public enum TweakNesting {
    /// By package id: the id of the card it is nested under (absent: its own card). `packages` in
    /// load order; the first package that needs it wins.
    public static func parents(_ packages: [TweakPackage]) -> [String: String] {
        var direct: [String: String] = [:]
        for p in packages {
            if let first = DependencyRows.dependents(of: p, among: packages).first { direct[p.id] = first.id }
        }
        var out: [String: String] = [:]
        for (id, parent) in direct {
            var top = parent, seen: Set<String> = [id]
            while let up = direct[top], !seen.contains(top) {
                seen.insert(top)
                top = up
            }
            // A cycle (two packages needing each other, nothing above): each stays its own card.
            if direct[top] != nil, seen.contains(top) { continue }
            out[id] = top
        }
        return out
    }
}
