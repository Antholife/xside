import AppKit
import Observation
import os
import UserNotifications
import XSideCore

/// Posts XSide's own notifications (refresh failures and successes); deduplication
/// is the engine's job (`NotificationGate`).
@MainActor
final class Notifier: NSObject {
    private nonisolated static let logger = Logger(subsystem: "io.github.xside.XSide", category: "engine")
    private nonisolated static let xcodeCategory = "refreshFailed.xcode"
    private nonisolated static let openXcodeAction = "openXcode"
    /// Causes the user fixes in Xcode (its account settings, or a newer or beta Xcode): their
    /// notification has "Open Xcode", and a tap opens Settings.
    static let xcodeErrorKeys: Set<String> = ["xcodeNotSignedIn", "noSigningIdentity", "provisioningFailed",
                                              "xcodeMissing", "xcodeTooOld", "xcodeNeedsBetaForMac"]

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
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.xcodeCategory, actions: [open], intentIdentifiers: []),
        ])
    }

    /// True when a notification posted now would be shown (authorized or provisional). Without a
    /// bundle (`swift run`) the failure is only logged, which counts as delivered.
    func canDeliver() async -> Bool {
        guard let center else { return true }
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    /// One refresh failure: title names the app, body is the friendly error message.
    /// Returns false when the system refused the notification.
    func refreshFailed(appName: String, errorKey: String, message: String, id: String) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = L("notification.refreshFailed.title", appName)
        content.body = message
        content.sound = .default
        if Self.xcodeErrorKeys.contains(errorKey) { content.categoryIdentifier = Self.xcodeCategory }
        guard let center else {
            Self.logger.notice("would notify: \(content.title, privacy: .public) — \(errorKey, privacy: .public)")
            return true
        }
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            Self.logger.notice("notified \(errorKey, privacy: .public)")
            return true
        } catch {
            Self.logger.error("notification failed: \(String(describing: error), privacy: .public)")
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
            Self.logger.notice("would notify: \(content.title, privacy: .public)")
            return true
        }
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            return true
        } catch {
            Self.logger.error("notification failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    nonisolated static let environmentNotificationID = "environment"

    /// The signing environment broke after setup; a tap opens Settings, where the fix is.
    func environmentBroken(key: String, title: String, message: String) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = L("environment.notification.body", message)
        content.sound = .default
        guard let center else {
            Self.logger.notice("would notify: \(content.title, privacy: .public)")
            return true
        }
        do {
            try await center.add(UNNotificationRequest(identifier: "\(Self.environmentNotificationID).\(key)",
                                                       content: content, trigger: nil))
            return true
        } catch {
            Self.logger.error("notification failed: \(String(describing: error), privacy: .public)")
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
            Self.logger.notice("would notify: \(content.title, privacy: .public)")
            return true
        }
        do {
            try await center.add(UNNotificationRequest(identifier: Self.macBetaNotificationID, content: content, trigger: nil))
            return true
        } catch {
            Self.logger.error("notification failed: \(String(describing: error), privacy: .public)")
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
            Self.logger.notice("would notify: \(content.title, privacy: .public)")
            return true
        }
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            return true
        } catch {
            Self.logger.error("notification failed: \(String(describing: error), privacy: .public)")
            return false
        }
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
        if response.actionIdentifier == Self.openXcodeAction {
            await openXcode()
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                  Self.opensSettings(response.notification.request.identifier)
                    || response.notification.request.content.categoryIdentifier == Self.xcodeCategory {
            // Environment, macOS beta and Xcode-caused refresh failures: the fix is in Settings.
            await Self.openSettings()
        }
    }
}

/// The real notification authorization, for the welcome journey and Settings.
@MainActor @Observable
final class NotificationPermission {
    private static let logger = Logger(subsystem: "io.github.xside.XSide", category: "app")
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

    func refresh() async {
        guard let center else { return }
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: state = .notDetermined
        case .denied: state = .denied
        default: state = .authorized // authorized, provisional, ephemeral
        }
    }

    /// Shows the one-time system prompt (does nothing once the user has answered it).
    func request() async {
        guard let center else { return }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            Self.logger.notice("notification authorization granted=\(granted, privacy: .public)")
        } catch {
            Self.logger.error("notification authorization failed: \(String(describing: error), privacy: .public)")
        }
        await refresh()
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(Self.systemSettingsURL)
    }
}
