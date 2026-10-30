import AppKit
import QuartzCore

/// The small turning arrow shown on the menu-bar icon while XSide works. It is a layer laid over
/// the status item's button and turned by Core Animation: animating the SwiftUI `MenuBarExtra`
/// label itself (a new image per frame) sent its host into an endless layout loop at full CPU.
@MainActor
final class MenuBarSpinner {
    private var view: NSImageView?

    /// Shows or hides the spinner; finds the status item's button on first use (false while it
    /// isn't there yet).
    @discardableResult
    func setWorking(_ working: Bool) -> Bool {
        guard let button = Self.statusButton() else { return false }
        if working {
            let spinner = view ?? makeView(on: button)
            spinner.isHidden = false
            if spinner.layer?.animation(forKey: "spin") == nil { Self.spin(spinner) }
        } else if let view {
            view.layer?.removeAllAnimations()
            view.isHidden = true
        }
        return true
    }

    private func makeView(on button: NSView) -> NSImageView {
        let size: CGFloat = 9
        let symbol = NSImage(systemSymbolName: "arrow.trianglehead.2.clockwise", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "arrow.2.circlepath", accessibilityDescription: nil)
        let spinner = NSImageView(image: symbol ?? NSImage())
        spinner.symbolConfiguration = .init(pointSize: size - 1, weight: .bold)
        spinner.contentTintColor = .labelColor
        spinner.imageScaling = .scaleProportionallyUpOrDown
        // Lower right corner of the glyph (18 pt, centred in the button).
        let glyphMaxX = button.bounds.midX + 9, glyphMinY = button.bounds.midY - 9
        spinner.frame = NSRect(x: glyphMaxX - size, y: button.isFlipped ? glyphMinY + 18 - size : glyphMinY,
                               width: size, height: size)
        spinner.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        spinner.wantsLayer = true
        button.addSubview(spinner)
        view = spinner
        return spinner
    }

    /// One turn per second, forever, rotating around the view's centre.
    private static func spin(_ view: NSView) {
        guard let layer = view.layer else { return }
        let frame = layer.frame
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = 1
        turn.repeatCount = .infinity
        layer.add(turn, forKey: "spin")
    }

    /// The button of XSide's status item, in the status bar window AppKit creates for it.
    private static func statusButton() -> NSView? {
        guard let window = NSApp.windows.first(where: { $0.className.contains("NSStatusBarWindow") }),
              let content = window.contentView else { return nil }
        return content.className.contains("StatusBarButton") ? content : find(in: content)
    }

    private static func find(in view: NSView) -> NSView? {
        for sub in view.subviews {
            if sub.className.contains("StatusBarButton") { return sub }
            if let found = find(in: sub) { return found }
        }
        return nil
    }
}
