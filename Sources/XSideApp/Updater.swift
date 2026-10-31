import Foundation
import Observation
import Sparkle
import XSideCore

/// XSide's self-updates through Sparkle: the feed (`SUFeedURL`) is `appcast.xml` on the
/// repository's main branch, each update is signed with the EdDSA key whose public half is
/// `SUPublicEDKey` (see scripts/release.sh). Off when the bundle has no feed (debug app, `swift run`).
@MainActor @Observable
final class Updater {
    private static let log = Log("updates")

    /// How often the background check runs.
    enum Frequency: TimeInterval, CaseIterable, Identifiable {
        case daily = 86_400
        case weekly = 604_800
        case monthly = 2_592_000
        var id: TimeInterval { rawValue }
    }

    /// Releases offered: betas are tagged `<sparkle:channel>beta</sparkle:channel>` in the feed,
    /// stable ones have no channel. There is no stable release yet.
    enum Channel: String, CaseIterable, Identifiable {
        case beta, stable
        var id: String { rawValue }
        static let storageKey = "updateChannel"
        /// Until 1.0 ships, only betas exist: the stable channel would offer nothing.
        static let stableAvailable = false
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private let channels = ChannelDelegate()
    private(set) var canCheck = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: channels,
                                                      userDriverDelegate: nil)
        self.controller = controller
        // KVO calls back on the main thread (Sparkle's updater lives there).
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let can = change.newValue ?? false
            Task { @MainActor in self?.canCheck = can }
        }
        Self.log.notice("updater started, automatic checks \(controller.updater.automaticallyChecksForUpdates), every \(Int(controller.updater.updateCheckInterval)) s, channel \(Self.channel.rawValue)")
    }

    var isAvailable: Bool { controller != nil }

    /// Background checks (Sparkle shows the update when one is found).
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var frequency: Frequency {
        get {
            let interval = controller?.updater.updateCheckInterval ?? Frequency.daily.rawValue
            return Frequency.allCases.min { abs($0.rawValue - interval) < abs($1.rawValue - interval) } ?? .daily
        }
        set {
            controller?.updater.updateCheckInterval = newValue.rawValue
            Self.log.notice("check every \(Int(newValue.rawValue)) s")
        }
    }

    static var channel: Channel {
        get {
            let stored = UserDefaults.standard.string(forKey: Channel.storageKey).flatMap(Channel.init)
            return stored == .stable && Channel.stableAvailable ? .stable : .beta
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Channel.storageKey) }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    func checkNow() {
        Self.log.notice("checking for updates")
        controller?.checkForUpdates(nil)
    }
}

/// Lets the beta channel's releases through when it's chosen (stable releases always are).
private final class ChannelDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { Updater.channel == .beta ? ["beta"] : [] }
    }
}
