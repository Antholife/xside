import AppKit
import os
import UserNotifications
import XSideCore

/// Posts XSide's own notifications (refresh failures). Only failures are notified; deduplication
/// is the engine's job (`NotificationGate`).
@MainActor
final class Notifier: NSObject {
    private nonisolated static let logger = Logger(subsystem: "io.github.xside.XSide", category: "engine")
    private static let xcodeCategory = "refreshFailed.xcode"
    private nonisolated static let openXcodeAction = "openXcode"
    /// Causes the user fixes in Xcode (Settings > Accounts): their notification has "Open Xcode".
    static let xcodeErrorKeys: Set<String> = ["xcodeNotSignedIn", "noSigningIdentity", "provisioningFailed",
                                              "xcodeMissing"]

    /// Developer dir of the detected environment, used when Xcode isn't found by bundle identifier.
    private let developerDir: @MainActor () -> URL?
    /// `UNUserNotificationCenter` needs a real app bundle: `swift run` gets log lines instead.
    private let center: UNUserNotificationCenter?

    init(developerDir: @escaping @MainActor () -> URL?) {
        self.developerDir = developerDir
        let bundled = Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
        center = bundled ? UNUserNotificationCenter.current() : nil
        super.init()
    }

    /// Installs the delegate and category, then asks for permission (the system prompts only once).
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
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Self.logger.error("notification authorization failed: \(String(describing: error), privacy: .public)")
            } else {
                Self.logger.notice("notification authorization granted=\(granted, privacy: .public)")
            }
        }
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

    func openXcode() {
        XcodeLauncher.open(developerDir: developerDir())
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
        guard response.actionIdentifier == Self.openXcodeAction else { return }
        await openXcode()
    }
}
