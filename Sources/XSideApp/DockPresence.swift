import AppKit
import SwiftUI
import XSideCore

/// Shows XSide in the Dock while one of its windows (journey, install, settings) is open, and goes
/// back to menu-bar only when the last one closes; always, while XSide is kept in the Dock (the
/// Dock's own "Keep in Dock", also set from Settings: `KeepInDockToggle`). The first time, a short alert explains that XSide keeps running in the menu bar.
@MainActor
final class DockPresence {
    static let hintShownKey = "backgroundHintShown"
    private static let log = Log("app")
    private var observers: [NSObjectProtocol] = []

    private static var always: Bool { isPinnedInDock }

    /// Adds XSide to the Dock's kept apps, or removes it, then restarts the Dock (it reads its
    /// preferences only at launch; it blinks for a moment).
    static func setPinnedInDock(_ pinned: Bool) {
        guard pinned != isPinnedInDock, let bundleID = Bundle.main.bundleIdentifier else { return }
        let dock = "com.apple.dock" as CFString, key = "persistent-apps" as CFString
        var apps = CFPreferencesCopyAppValue(key, dock) as? [[String: Any]] ?? []
        if pinned {
            apps.append([
                "tile-type": "file-tile",
                "tile-data": [
                    "bundle-identifier": bundleID,
                    "file-label": "XSide",
                    "file-data": ["_CFURLString": Bundle.main.bundleURL.absoluteString, "_CFURLStringType": 15],
                ] as [String: Any],
            ])
        } else {
            apps.removeAll { (($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String) == bundleID }
        }
        CFPreferencesSetAppValue(key, apps as CFArray, dock)
        CFPreferencesAppSynchronize(dock)
        log.notice(pinned ? "pinned in the Dock" : "unpinned from the Dock")
        NotificationCenter.default.post(name: pinChanged, object: nil)
        Task { _ = try? await ProcessRunner().run("/usr/bin/killall", ["Dock"], cwd: nil) }
    }

    static let pinChanged = Notification.Name("XSideDockPinChanged")

    /// XSide is among the Dock's kept apps (`com.apple.dock` `persistent-apps`).
    static var isPinnedInDock: Bool {
        let dock = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(dock)
        guard let apps = CFPreferencesCopyAppValue("persistent-apps" as CFString, dock) as? [[String: Any]],
              let bundleID = Bundle.main.bundleIdentifier else { return false }
        return apps.contains { (($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String) == bundleID }
    }

    func start() {
        let center = NotificationCenter.default
        // Pinning sends nothing: looked at again each time XSide comes forward, and when Settings
        // pins or unpins it (`pinChanged`).
        for name in [NSApplication.didBecomeActiveNotification, Self.pinChanged] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update(closing: nil) }
            })
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update(closing: nil) }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.update(closing: window) }
        })
        update(closing: nil) // "Keep in the Dock" applies from launch
    }

    /// A regular app window, shown or minimized (a minimized window must stay restorable from the
    /// Dock): titled and at normal level, which excludes the menu-bar popover and alerts.
    private static func isAppWindow(_ window: NSWindow) -> Bool {
        (window.isVisible || window.isMiniaturized) && window.styleMask.contains(.titled) && window.level == .normal && !(window is NSPanel)
    }

    private func update(closing: NSWindow?) {
        if Self.always {
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            return
        }
        let open = NSApp.windows.contains { $0 !== closing && Self.isAppWindow($0) }
        if open {
            guard NSApp.activationPolicy() != .regular else { return }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            return
        }
        guard NSApp.activationPolicy() == .regular else { return }
        // "Keep in the Dock" was just turned off with no window open: back to the menu bar only.
        guard let closing, Self.isAppWindow(closing) else {
            NSApp.setActivationPolicy(.accessory)
            return
        }
        // Let the window finish closing before the alert or the policy switch.
        DispatchQueue.main.async {
            if !UserDefaults.standard.bool(forKey: Self.hintShownKey) {
                UserDefaults.standard.set(true, forKey: Self.hintShownKey)
                let alert = NSAlert()
                alert.messageText = L("background.hint.title")
                alert.informativeText = L("background.hint.text")
                alert.addButton(withTitle: L("background.hint.ok"))
                NSApp.activate()
                alert.runModal()
            }
            if !NSApp.windows.contains(where: Self.isAppWindow) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

/// "Keep in the Dock", in Settings and in the welcome journey: the Dock's own pin, both ways (it
/// shows what the Dock says, and pins or unpins XSide there).
struct KeepInDockToggle: View {
    @State private var isOn = DockPresence.isPinnedInDock

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { on in
            isOn = on
            DockPresence.setPinnedInDock(on)
        })) {
            Text(L("settings.keepInDock"))
            Text(L("settings.keepInDock.detail"))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isOn = DockPresence.isPinnedInDock
        }
    }
}
