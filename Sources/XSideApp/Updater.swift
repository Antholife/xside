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
    @ObservationIgnored private let reminders = ReminderDelegate()
    private(set) var canCheck = false
    /// A version found by a background check and not dealt with yet: the panel and a
    /// notification offer it (gentle reminders), instead of an update window that a menu-bar app
    /// may open behind everything.
    private(set) var availableVersion: String?
    /// Set by the app: tells about `availableVersion` (a notification).
    @ObservationIgnored var onAvailable: ((String) -> Void)?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            controller = nil
            #if DEBUG
            canCheck = AppModel.isDemo // the demo's button looks live (it does nothing)
            #endif
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: channels,
                                                      userDriverDelegate: reminders)
        self.controller = controller
        // KVO calls back on the main thread (Sparkle's updater lives there).
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let can = change.newValue ?? false
            Task { @MainActor in self?.canCheck = can }
        }
        reminders.onFound = { [weak self] version in
            guard let self, self.availableVersion != version else { return }
            self.availableVersion = version
            Self.log.notice("update \(version) available")
            self.onAvailable?(version)
        }
        reminders.onDone = { [weak self] in self?.availableVersion = nil }
        Self.log.notice("updater started, automatic checks \(controller.updater.automaticallyChecksForUpdates), every \(Int(controller.updater.updateCheckInterval)) s, channel \(Self.channel.rawValue)")
    }

    var isAvailable: Bool {
        #if DEBUG
        if AppModel.isDemo { return true } // shown for screenshots, Sparkle never started
        #endif
        return controller != nil
    }

    /// Background checks (Sparkle shows the update when one is found).
    var automaticallyChecks: Bool {
        get {
            #if DEBUG
            if AppModel.isDemo { return true }
            #endif
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
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

    var lastCheck: Date? {
        #if DEBUG
        if AppModel.isDemo { return Date().addingTimeInterval(-2 * 3600) }
        #endif
        return controller?.updater.lastUpdateCheckDate
    }

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

/// Gentle reminders: a scheduled check that finds an update while XSide isn't in front leaves it
/// to us (panel line and notification) instead of opening Sparkle's window behind other apps.
/// Sparkle calls it on the main thread.
@MainActor
private final class ReminderDelegate: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    var onFound: (@MainActor (String) -> Void)?
    var onDone: (@MainActor () -> Void)?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus // in front (just launched, or active): Sparkle's window shows as usual
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        let version = update.displayVersionString
        onFound?(version)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        onDone?()
    }

    func standardUserDriverWillFinishUpdateSession() {
        onDone?()
    }
}
