import AppKit

/// Shows XSide in the Dock while one of its windows (journey, install, settings) is open, and goes
/// back to menu-bar only when the last one closes. The first time, a short alert explains that
/// XSide keeps running in the menu bar.
@MainActor
final class DockPresence {
    static let hintShownKey = "backgroundHintShown"
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update(closing: nil) }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.update(closing: window) }
        })
    }

    /// A regular app window, shown or minimized (a minimized window must stay restorable from the
    /// Dock): titled and at normal level, which excludes the menu-bar popover and alerts.
    private static func isAppWindow(_ window: NSWindow) -> Bool {
        (window.isVisible || window.isMiniaturized) && window.styleMask.contains(.titled) && window.level == .normal && !(window is NSPanel)
    }

    private func update(closing: NSWindow?) {
        let open = NSApp.windows.contains { $0 !== closing && Self.isAppWindow($0) }
        if open {
            guard NSApp.activationPolicy() != .regular else { return }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            return
        }
        guard NSApp.activationPolicy() == .regular, let closing, Self.isAppWindow(closing) else { return }
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
