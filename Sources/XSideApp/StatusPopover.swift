import AppKit
import SwiftUI
import XSideCore

/// XSide's menu-bar item and its panel, a real `NSPopover`: it hangs right under the bar with its
/// arrow pointing at the icon. `MenuBarExtra` can't do that (its window has no arrow, and its
/// clicks never reach the app), so the item is AppKit's own. The icon is `label`, a SwiftUI view
/// drawn over the button that lets the clicks through.
@MainActor
final class StatusPopover: NSObject, NSPopoverDelegate {
    private static let log = Log("app")

    private let popover = NSPopover()
    private var item: NSStatusItem?
    private var onVisibilityChange: (Bool) -> Void = { _ in }

    func install<Label: View, Content: View>(label: Label, content: Content,
                                             onVisibilityChange: @escaping (Bool) -> Void) {
        guard item == nil else { return }
        self.onVisibilityChange = onVisibilityChange
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.behavior = []
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            let host = PassThroughHostingView(rootView: label)
            host.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(host)
            NSLayoutConstraint.activate([
                host.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                host.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        }
        self.item = item

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: content.environment(\.closePopover, ClosePopoverAction { [weak self] in
            self?.close()
        }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        Self.log.info("status item installed")
    }

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown { close() } else { show() }
    }

    func show() {
        guard let button = item?.button, !popover.isShown else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        popover.performClose(nil)
    }

    func popoverDidShow(_ notification: Notification) {
        item?.button?.highlight(true)
        onVisibilityChange(true)
    }

    func popoverDidClose(_ notification: Notification) {
        item?.button?.highlight(false)
        onVisibilityChange(false)
    }
}

/// Draws the SwiftUI icon over the status item's button without taking its clicks.
private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
