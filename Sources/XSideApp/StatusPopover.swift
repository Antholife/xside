import AppKit
import SwiftUI
import XSideCore

/// The menu-bar panel as a real `NSPopover`: it hangs right under the bar with its arrow pointing
/// at the icon. `MenuBarExtra` keeps the status item (icon, badge, animation, drops) but its own
/// window never opens: the item's button is pointed at `toggle` instead.
@MainActor
final class StatusPopover: NSObject, NSPopoverDelegate {
    private static let log = Log("app")
    private let popover = NSPopover()
    private weak var button: NSStatusBarButton?
    private var onVisibilityChange: (Bool) -> Void = { _ in }

    /// Installs the content (once) and takes over the status item's clicks. False while the item
    /// isn't there yet.
    @discardableResult
    func attach<Content: View>(content: () -> Content, onVisibilityChange: @escaping (Bool) -> Void) -> Bool {
        if button != nil { return true }
        guard let button = Self.statusButton() else { return false }
        self.onVisibilityChange = onVisibilityChange
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: content().environment(\.closePopover, ClosePopoverAction { [weak self] in
            self?.close()
        }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        button.target = self
        button.action = #selector(toggle(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        self.button = button
        return true
    }

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown { close() } else { show() }
    }

    func show() {
        guard let button, !popover.isShown else { return }
        Self.log.info("popover shown")
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        popover.performClose(nil)
    }

    func popoverDidShow(_ notification: Notification) {
        button?.highlight(true)
        onVisibilityChange(true)
    }

    func popoverDidClose(_ notification: Notification) {
        button?.highlight(false)
        onVisibilityChange(false)
    }

    /// The button of XSide's status item, in the status bar window AppKit creates for it.
    static func statusButton() -> NSStatusBarButton? {
        guard let window = NSApp.windows.first(where: { $0.className.contains("NSStatusBarWindow") }),
              let content = window.contentView else { return nil }
        return (content as? NSStatusBarButton) ?? find(in: content)
    }

    private static func find(in view: NSView) -> NSStatusBarButton? {
        for sub in view.subviews {
            if let button = sub as? NSStatusBarButton { return button }
            if let found = find(in: sub) { return found }
        }
        return nil
    }
}

/// Closes the menu-bar popover (`dismiss` doesn't reach an `NSPopover`).
struct ClosePopoverAction {
    let action: @MainActor () -> Void
    @MainActor func callAsFunction() { action() }
}

private struct ClosePopoverKey: EnvironmentKey {
    static let defaultValue = ClosePopoverAction {}
}

extension EnvironmentValues {
    var closePopover: ClosePopoverAction {
        get { self[ClosePopoverKey.self] }
        set { self[ClosePopoverKey.self] = newValue }
    }
}
