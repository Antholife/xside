import Foundation

/// The menu-bar dot (device round 2, item 13): whether something needs a look with the panel
/// closed, and why (the icon's accessibility description names each reason). Everything here
/// clears by itself once resolved: the reasons are read again from the current state.
public enum MenuBarAttention {
    public enum Level: Equatable, Sendable { case warning, critical }

    /// What the signing setup says.
    public enum Environment: Equatable, Sendable {
        case ok
        /// The certificate or the account no longer works (after setup).
        case certificate
        /// The check itself failed (a system tool erred): nothing is known to be missing.
        case checkFailed
    }

    /// In the order the description lists them.
    public enum Reason: String, Equatable, Sendable, CaseIterable {
        case expired, certificate, crash, expiringSoon, refreshFailed, tweakProblem, setupCheck, libraryIssue

        /// The `Localizable.strings` key of its words.
        public var stringKey: String { "menuBar.attention.\(rawValue)" }
    }

    /// Paused installations don't count (the person chose to let them go).
    /// `threshold`: how close to expiry a failed refresh becomes urgent.
    /// `flaggedCrashes`: the crashes shown on rows (not dismissed).
    public static func reasons(records: [AppRecord], now: Date, threshold: TimeInterval, flaggedCrashes: Int,
                               environment: Environment, libraryIssue: Bool) -> [Reason] {
        let active = records.flatMap(\.installations).filter { !$0.refreshPaused }
        var found: Set<Reason> = []
        if active.contains(where: { $0.expiresAt <= now }) { found.insert(.expired) }
        if environment == .certificate { found.insert(.certificate) }
        if flaggedCrashes > 0 { found.insert(.crash) }
        for i in active where i.expiresAt > now && i.lastErrorKey != nil {
            found.insert(.refreshFailed)
            if i.expiresAt.timeIntervalSince(now) <= threshold { found.insert(.expiringSoon) }
        }
        // An enabled tweak the last signing left out (a missing dependency, a conflict, no room…).
        if active.contains(where: { ($0.tweakResults ?? [:]).values.contains { if case .skipped = $0 { true } else { false } } }) {
            found.insert(.tweakProblem)
        }
        if environment == .checkFailed { found.insert(.setupCheck) }
        if libraryIssue { found.insert(.libraryIssue) }
        return Reason.allCases.filter(found.contains)
    }

    /// Critical when an app expired or signing no longer works; nil when nothing is wrong.
    public static func level(of reasons: [Reason]) -> Level? {
        if reasons.isEmpty { return nil }
        return reasons.contains(.expired) || reasons.contains(.certificate) ? .critical : .warning
    }
}
