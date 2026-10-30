import AppKit
import SwiftUI

/// Keeps the hosting window inside its screen's visible area when its content grows (a
/// content-sized window grows downward and can slide under the bottom edge). Watches the
/// window's resizes.
struct KeepWindowOnScreen: NSViewRepresentable {
    func makeNSView(context: Context) -> Watcher { Watcher() }
    func updateNSView(_ view: Watcher, context: Context) {}

    final class Watcher: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { window.map(Self.fit) }
            }
        }

        private static func fit(_ window: NSWindow) {
            guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
            var frame = window.frame
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
            if frame.maxY > visible.maxY { frame.origin.y = max(visible.minY, visible.maxY - frame.height) }
            if frame != window.frame { window.setFrame(frame, display: true, animate: false) }
        }
    }
}
