import AppKit
import SwiftUI

/// Shows XSide in the Dock while one of its windows (journey, install, settings) is open, and goes
/// back to menu-bar only when the last one closes; always, when "Keep in the Dock" is on
/// (`alwaysKey`). The first time, a short alert explains that XSide keeps running in the menu bar.
@MainActor
final class DockPresence {
    static let hintShownKey = "backgroundHintShown"
    /// Settings > General: the Dock icon stays even with no window open.
    static let alwaysKey = "keepInDock"
    private var observers: [NSObjectProtocol] = []

    /// The setting, or XSide pinned in the Dock (the Dock's own "Keep in Dock"): the Dock is the
    /// reference, XSide can't unpin itself.
    private static var always: Bool { UserDefaults.standard.bool(forKey: alwaysKey) || isPinnedInDock }

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
        // The setting changed (or anything else in the defaults): applied at once. Pinning in the
        // Dock sends nothing: looked at again each time XSide comes forward.
        for name in [UserDefaults.didChangeNotification, NSApplication.didBecomeActiveNotification] {
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

/// "Keep in the Dock", in Settings and in the welcome journey. On and locked while XSide is pinned
/// in the Dock: only the Dock can unpin it.
struct KeepInDockToggle: View {
    @AppStorage(DockPresence.alwaysKey) private var keepInDock = false
    @State private var pinned = DockPresence.isPinnedInDock

    var body: some View {
        Toggle(isOn: Binding(get: { keepInDock || pinned }, set: { keepInDock = $0 })) {
            Text(L("settings.keepInDock"))
            Text(L(pinned ? "settings.keepInDock.pinned" : "settings.keepInDock.detail"))
        }
        .disabled(pinned)
        .onAppear { pinned = DockPresence.isPinnedInDock }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            pinned = DockPresence.isPinnedInDock
        }
    }
}
