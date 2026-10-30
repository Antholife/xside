import Foundation

/// When the "What's new" window opens by itself: once per version that has notes, after an update.
public enum WhatsNew {
    /// Last version whose notes were shown (or skipped, for a fresh install).
    public static let lastSeenKey = "whatsNewLastSeenVersion"

    public enum Decision: Equatable, Sendable {
        /// Open the window, then remember `current`.
        case show
        /// Remember `current` without showing anything (fresh install: nothing is "new" yet).
        case markSeen
        case nothing
    }

    /// `setupDone`: the welcome journey was finished, i.e. XSide was already in use.
    public static func decide(current: String, lastSeen: String?, setupDone: Bool, hasNotes: Bool) -> Decision {
        guard lastSeen != current else { return .nothing }
        guard setupDone else { return .markSeen }
        return hasNotes ? .show : .markSeen
    }
}
