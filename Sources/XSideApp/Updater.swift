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
        case hourly = 3_600
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
    /// Set by the app: true while an install or a refresh runs (an update then waits).
    @ObservationIgnored var isBusy: () -> Bool = { false }
    /// Sparkle is replacing XSide: the quit confirmation must not hold it up.
    static var isInstallingUpdate = false
    /// A downloaded automatic update waiting for XSide to be idle.
    @ObservationIgnored private var pendingInstall: (() -> Void)?

    /// Installs the downloaded automatic update now (Sparkle replaces XSide and relaunches it),
    /// unless a job runs: called again when jobs end.
    func installIfIdle() {
        guard let install = pendingInstall, !isBusy() else { return }
        pendingInstall = nil
        Self.log.notice("installing the downloaded update and relaunching")
        Self.isInstallingUpdate = true // the quit it causes isn't questioned
        install()
    }
    @ObservationIgnored private var observation: NSKeyValueObservation?

    #if DEBUG
    /// Debug-only: XSIDE_TEST_FEED=<url> starts Sparkle on that feed (the debug app has none) and
    /// runs a background check a few seconds after launch, to try the gentle reminders.
    static let testFeed = ProcessInfo.processInfo.environment["XSIDE_TEST_FEED"]
    #endif

    init() {
        var hasFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        #if DEBUG
        if Self.testFeed != nil { hasFeed = true }
        #endif
        guard hasFeed else {
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
            // Found again by an extra check after "Remind me later": the panel says so, the
            // notification waits a day.
            let key = "updateNotified.\(version)"
            if let last = UserDefaults.standard.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 86_400 { return }
            UserDefaults.standard.set(Date(), forKey: key)
            self.onAvailable?(version)
        }
        reminders.onDone = { [weak self] in self?.availableVersion = nil }
        channels.onReadyToInstall = { [weak self] version, install in
            Self.log.notice("update \(version) downloaded: installing once idle")
            self?.pendingInstall = install
            self?.installIfIdle()
        }
        #if DEBUG
        if Self.testFeed != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { controller.updater.checkForUpdatesInBackground() }
        }
        #endif
        Self.log.notice("updater started, automatic checks \(controller.updater.automaticallyChecksForUpdates), every \(Int(controller.updater.updateCheckInterval)) s, channel \(Self.channel.rawValue)")
    }

    /// Least time between two checks started by `checkSoon`.
    private static let soonThrottle: TimeInterval = 10 * 60

    /// A background check now, besides Sparkle's schedule: at launch and after an app refresh
    /// (the Mac is awake and online then). Only with automatic checks on, at most every 10 min.
    func checkSoon(_ reason: String) {
        guard let updater = controller?.updater, updater.automaticallyChecksForUpdates, !updater.sessionInProgress else { return }
        if let last = updater.lastUpdateCheckDate, Date().timeIntervalSince(last) < Self.soonThrottle { return }
        Self.log.notice("checking for updates (\(reason))")
        updater.checkForUpdatesInBackground()
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

    /// Downloads and installs updates by itself (Sparkle's "Automatically download and install
    /// updates" box): the update is applied when XSide quits or relaunches.
    var automaticallyInstalls: Bool {
        get {
            #if DEBUG
            if AppModel.isDemo { return false }
            #endif
            return controller?.updater.automaticallyDownloadsUpdates ?? false
        }
        set {
            controller?.updater.automaticallyDownloadsUpdates = newValue
            Self.log.notice("automatic install \(newValue)")
        }
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

    /// Set by the updater: an automatic update is downloaded and waits for XSide to quit. XSide
    /// rarely quits (menu-bar app): the handler installs it right away (and relaunches) once
    /// nothing runs.
    var onReadyToInstall: (@MainActor (String, @escaping () -> Void) -> Void)?

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        return MainActor.assumeIsolated {
            guard let onReadyToInstall else { return false }
            onReadyToInstall(version, immediateInstallHandler)
            return true
        }
    }

    /// Any update about to relaunch XSide (installed by hand from Sparkle's window too): the quit
    /// it causes isn't questioned.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { Updater.isInstallingUpdate = true }
    }

    #if DEBUG
    func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated { Updater.testFeed }
    }
    #endif
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
