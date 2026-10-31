import AppKit
import Observation
import os
import UserNotifications
import XSideCore

/// Posts XSide's own notifications (refresh failures and successes); deduplication
/// is the engine's job (`NotificationGate`).
@MainActor
final class Notifier: NSObject {
    private nonisolated static let logger = Log("engine")
    private nonisolated static let xcodeCategory = "refreshFailed.xcode"
    /// Causes fixed by installing another Xcode (App Store update, beta): no "Open Xcode", a tap
    /// opens Settings, which links to the download.
    private nonisolated static let settingsCategory = "refreshFailed.settings"
    private nonisolated static let openXcodeAction = "openXcode"
    /// An app's refresh failed or is about to be due: "Refresh now" and "Open XSide" buttons.
    private nonisolated static let appCategory = "app"
    private nonisolated static let refreshAction = "refreshNow"
    private nonisolated static let openPanelAction = "openPanel"
    /// Keys of an app notification's `userInfo`.
    private nonisolated static let recordKey = "recordID", deviceKey = "deviceID"

    /// When a notification was last clicked (or one of its buttons): the reopen it causes is not
    /// a click on the Dock icon (see `AppDelegate.applicationShouldHandleReopen`).
    static var lastResponse = Date.distantPast

    /// Installed by the app: refreshes one app (a notification's "Refresh now").
    static var refreshHandler: (@MainActor (RefreshJob) -> Void)?
    /// Installed by the app: opens the menu-bar panel, on the notification's app if it has one.
    static var openPanelHandler: (@MainActor (RefreshJob?) -> Void)?
    /// Causes the user fixes in Xcode itself (its account settings): their notification has
    /// "Open Xcode", and a tap opens Settings.
    static let xcodeErrorKeys: Set<String> = ["xcodeNotSignedIn", "noSigningIdentity", "provisioningFailed", "xcodeMissing"]
    /// Causes fixed with a newer or beta Xcode: a tap opens Settings.
    static let newXcodeErrorKeys: Set<String> = ["xcodeTooOld", "xcodeNeedsBetaForMac"]

    /// Developer dir of the detected environment, used when Xcode isn't found by bundle identifier.
    private let developerDir: @MainActor () -> URL?
    /// `UNUserNotificationCenter` needs a real app bundle: `swift run` gets log lines instead.
    private let center: UNUserNotificationCenter?

    init(developerDir: @escaping @MainActor () -> URL?) {
        self.developerDir = developerDir
        center = Self.isBundled ? UNUserNotificationCenter.current() : nil
        super.init()
    }

    /// True when running from an app bundle (`UNUserNotificationCenter` crashes otherwise).
    nonisolated static var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Installs the delegate and category. Permission is asked by the welcome journey (or from
    /// Settings), never at launch, so the system prompt comes with its explanation.
    func start() {
        guard let center else {
            Self.logger.notice("not running from an app bundle: notifications disabled")
            return
        }
        center.delegate = self
        let open = UNNotificationAction(identifier: Self.openXcodeAction, title: L("notification.openXcode"),
                                        options: [.foreground])
        // Foreground: the panel opens on the app, to follow the refresh.
        let refresh = UNNotificationAction(identifier: Self.refreshAction, title: L("notification.action.refresh"),
                                           options: [.foreground])
        let panel = UNNotificationAction(identifier: Self.openPanelAction, title: L("notification.action.open"),
                                         options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.xcodeCategory, actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.appCategory, actions: [refresh, panel], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.settingsCategory, actions: [], intentIdentifiers: []),
        ])
    }

    /// True when a notification posted now would be shown: authorized (or provisional) with an
    /// alert style other than "None". Without a bundle (`swift run`) the failure is only logged,
    /// which counts as delivered.
    func canDeliver() async -> Bool {
        guard let center else { return true }
        return Self.isDeliverable(await center.notificationSettings())
    }

    /// Authorized, with banners or alerts: with alert style "None" nothing pops up (at most a
    /// silent entry in Notification Center), so a cause notified then would go unseen.
    nonisolated static func isDeliverable(_ settings: UNNotificationSettings) -> Bool {
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return false }
        return settings.alertSetting != .disabled
    }

    /// One refresh failure: title names the app, body is the friendly error message.
    /// Returns false when the system refused the notification.
    func refreshFailed(appName: String, errorKey: String, message: String, job: RefreshJob, id: String) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = L("notification.refreshFailed.title", appName)
        content.body = message
        content.sound = .default
        if Self.xcodeErrorKeys.contains(errorKey) {
            content.categoryIdentifier = Self.xcodeCategory
        } else if Self.newXcodeErrorKeys.contains(errorKey) {
            content.categoryIdentifier = Self.settingsCategory
        } else {
            // Nothing to fix in Xcode: trying again may just work (device back, unlocked).
            Self.tag(content, with: job)
        }
        guard let center else {
            Self.logger.notice("would notify: \(content.title) — \(errorKey)")
            return true
        }
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            Self.logger.notice("notified \(errorKey)")
            return true
        } catch {
            Self.logger.error("notification failed: \(String(describing: error))")
            return false
        }
    }

    /// A due app that can't be refreshed because the device is on Wi-Fi only and Wi-Fi refresh is off.
    func needsUSB(appName: String, deviceName: String, date: String, id: String) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = L("notification.needsUSB.title", appName)
        content.body = L("notification.needsUSB.body", deviceName, appName, date)
        content.sound = .default
        guard let center else {
            Self.logger.notice("would notify: \(content.title)")
            return true
        }
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            return true
        } catch {
            Self.logger.error("notification failed: \(String(describing: error))")
            return false
        }
    }

    nonisolated static let environmentNotificationID = "environment"

    /// The signing environment broke after setup; a tap opens Settings, where the fix is.
    /// `checkFailed`: the check itself failed, Settings only offers to check again.
    func environmentBroken(key: String, title: String, message: String, checkFailed: Bool = false) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = L(checkFailed ? "environment.notification.body.check" : "environment.notification.body", message)
        content.sound = .default
        guard let center else {
            Self.logger.notice("would notify: \(content.title)")
            return true
        }
        do {
            try await center.add(UNNotificationRequest(identifier: "\(Self.environmentNotificationID).\(key)",
                                                       content: content, trigger: nil))
            return true
        } catch {
            Self.logger.error("notification failed: \(String(describing: error))")
            return false
        }
    }

    /// The Mac runs a macOS beta with a release Xcode (posted once per macOS build).
    func macBetaWithReleaseXcode() async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = L("macBeta.banner.title")
        content.body = L("macBeta.notification.body")
        content.sound = .default
        guard let center else {
            Self.logger.notice("would notify: \(content.title)")
            return true
        }
        do {
            try await center.add(UNNotificationRequest(identifier: Self.macBetaNotificationID, content: content, trigger: nil))
            return true
        } catch {
            Self.logger.error("notification failed: \(String(describing: error))")
            return false
        }
    }

    /// UserDefaults key of the "notify successful refreshes" setting (default on).
    nonisolated static let notifyRefreshSuccessKey = "notifyRefreshSuccess"

    /// A successful refresh: plain notification (no "Open Xcode" action). False when refused.
    func refreshSucceeded(appName: String, deviceName: String, date: String, id: String) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = L("notification.refreshed.title", appName)
        content.body = L("notification.refreshed.body", deviceName, date)
        guard let center else {
            Self.logger.notice("would notify: \(content.title)")
            return true
        }
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            return true
        } catch {
            Self.logger.error("notification failed: \(String(describing: error))")
            return false
        }
    }

    // MARK: Expiry reminders

    /// Schedules (or replaces) the reminder of one installation: delivered by macOS 24 h before
    /// it expires, even if XSide isn't running. A refresh reschedules it, so it only shows when
    /// no refresh happened in time. Nothing is scheduled when that moment is already past.
    func scheduleExpiryReminder(recordID: UUID, deviceID: String, appName: String, deviceName: String,
                                expiresAt: Date) async {
        let id = ExpiryWatch.reminderID(recordID: recordID, deviceID: deviceID)
        guard let date = ExpiryWatch.reminderDate(expiresAt: expiresAt, now: Date()) else {
            center?.removePendingNotificationRequests(withIdentifiers: [id])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = L("notification.expiry.title", appName)
        content.body = L("notification.expiry.body", deviceName)
        content.sound = .default
        Self.tag(content, with: RefreshJob(recordID: recordID, deviceID: deviceID))
        guard let center else {
            Self.logger.notice("would schedule: \(content.title) at \(date)")
            return
        }
        // Not allowed (yet): nothing to schedule; the next reconciliation adds it once allowed.
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        // An interval, not a calendar date: unaffected by time zone changes.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, date.timeIntervalSinceNow), repeats: false)
        // A reminder shown for the previous expiry no longer applies.
        center.removeDeliveredNotifications(withIdentifiers: [id])
        do {
            // Same identifier: replaces the pending one.
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        } catch {
            Self.logger.error("scheduling reminder failed: \(String(describing: error))")
        }
    }

    /// Removes the pending and shown reminder of one installation (uninstalled, no longer refreshed).
    func removeExpiryReminder(recordID: UUID, deviceID: String) async {
        guard let center else { return }
        let id = ExpiryWatch.reminderID(recordID: recordID, deviceID: deviceID)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// Removes the pending and shown reminders of one device (removed from XSide).
    func removeExpiryReminders(forDevice deviceID: String) async {
        guard let center else { return }
        let suffix = ".\(deviceID)"
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let ids = Array(Set(pending + delivered).filter { $0.hasPrefix(ExpiryWatch.reminderPrefix) && $0.hasSuffix(suffix) })
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// Removes the pending reminders whose installation is gone (`keeping`: the current ids).
    func removeExpiryReminders(keeping ids: Set<String>) async {
        guard let center else { return }
        let stale = await center.pendingNotificationRequests().map(\.identifier)
            .filter { $0.hasPrefix(ExpiryWatch.reminderPrefix) && !ids.contains($0) }
        guard !stale.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        center.removeDeliveredNotifications(withIdentifiers: stale)
    }

    func openXcode() {
        XcodeLauncher.open(developerDir: developerDir())
    }

    /// Opens the SwiftUI Settings window. Installed by the menu-bar label, since only a view can
    /// reach `openSettings` (the `showSettingsWindow:` action no longer opens it).
    static var openSettingsHandler: (@MainActor () -> Void)?

    static func openSettings() {
        NSApp.activate()
        openSettingsHandler?()
    }

    /// Notifications whose tap opens Settings, where the fix is: environment ("environment.<key>")
    /// and macOS beta.
    nonisolated static func opensSettings(_ identifier: String) -> Bool {
        identifier == macBetaNotificationID || identifier.hasPrefix(environmentNotificationID + ".")
    }
    nonisolated static let macBetaNotificationID = "macBeta"

    /// Gives an app notification its "Refresh now" / "Open XSide" buttons and the app it is about.
    private static func tag(_ content: UNMutableNotificationContent, with job: RefreshJob) {
        content.categoryIdentifier = appCategory
        content.userInfo = [recordKey: job.recordID.uuidString, deviceKey: job.deviceID]
    }

    nonisolated private static func job(of notification: UNNotification) -> RefreshJob? {
        let info = notification.request.content.userInfo
        guard let record = (info[recordKey] as? String).flatMap(UUID.init(uuidString:)),
              let device = info[deviceKey] as? String else { return nil }
        return RefreshJob(recordID: record, deviceID: device)
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// XSide is a menu-bar app, often "frontmost" while the popover is open: show banners anyway.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let request = response.notification.request
        await MainActor.run { Self.lastResponse = Date() }
        if response.actionIdentifier == Self.openXcodeAction {
            await openXcode()
        } else if response.actionIdentifier == Self.refreshAction, let job = Self.job(of: response.notification) {
            await MainActor.run { Self.refreshHandler?(job) }
        } else if response.actionIdentifier == Self.openPanelAction
                    || (response.actionIdentifier == UNNotificationDefaultActionIdentifier
                        && request.content.categoryIdentifier == Self.appCategory) {
            // About one app: the panel shows it, with its menu.
            let job = Self.job(of: response.notification)
            await MainActor.run {
                NSApp.activate()
                Self.openPanelHandler?(job)
            }
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                  Self.opensSettings(request.identifier)
                    || [Self.xcodeCategory, Self.settingsCategory].contains(request.content.categoryIdentifier) {
            // Environment, macOS beta and Xcode-caused refresh failures: the fix is in Settings.
            await Self.openSettings()
        } else if request.identifier.hasPrefix(ExpiryWatch.reminderPrefix) {
            // An app about to expire: Settings is the window XSide can open (not the popover).
            await Self.openSettings()
        }
    }
}

/// The real notification authorization, for the welcome journey and Settings.
@MainActor @Observable
final class NotificationPermission {
    private static let logger = Log("app")
    /// System Settings > Notifications, opened straight on XSide's own page (`?id=<bundle id>`).
    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id="
                                       + (Bundle.main.bundleIdentifier ?? "io.github.xside.XSide"))!

    enum State { case checking, unavailable, notDetermined, denied, authorized }

    private(set) var state: State
    private let center: UNUserNotificationCenter?

    init() {
        center = Notifier.isBundled ? UNUserNotificationCenter.current() : nil
        state = center == nil ? .unavailable : .checking
    }

    /// Called when notifications become allowed (journey, Settings): reminders can be scheduled.
    static var onBecameAuthorized: (@MainActor () -> Void)?

    func refresh() async {
        guard let center else { return }
        let before = state
        defer {
            if state == .authorized, before == .notDetermined || before == .denied { Self.onBecameAuthorized?() }
        }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: state = .notDetermined
        case .denied: state = .denied
        // Allowed, but with alert style "None" and out of Notification Center: nothing would
        // show, so it reads (and is fixed) like "off".
        default: state = Notifier.isDeliverable(settings) ? .authorized : .denied
        }
    }

    /// Shows the one-time system prompt (does nothing once the user has answered it).
    func request() async {
        guard let center else { return }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            Self.logger.notice("notification authorization granted=\(granted)")
        } catch {
            Self.logger.error("notification authorization failed: \(String(describing: error))")
        }
        await refresh()
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(Self.systemSettingsURL)
    }
}
