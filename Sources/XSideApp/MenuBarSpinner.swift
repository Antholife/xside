import AppKit
import QuartzCore

/// While XSide works, the icon's own arrow redraws itself: the swoosh is traced from its start,
/// then its head appears, in a loop. The label shows the phone alone meanwhile, and the arrow is
/// a pair of Core Animation shape layers laid over the status item's button. Animating the
/// SwiftUI label itself (a new image per frame) sent its host into an endless layout loop at
/// full CPU.
@MainActor
final class MenuBarSpinner {
    private var overlay: ArrowOverlay?
    private var working = false

    /// The status item's button; the state asked before it was set applies then.
    weak var button: NSView? {
        didSet { setWorking(working) }
    }

    func setWorking(_ working: Bool) {
        self.working = working
        guard let button else { return }
        if working {
            let arrow = overlay ?? ArrowOverlay(on: button)
            overlay = arrow
            arrow.start()
        } else {
            overlay?.stop()
        }
    }
}

/// The glyph's swoosh and arrow head, in the 200×200 design space of scripts/make-icons.swift
/// (y down), scaled to the 18 pt glyph.
private final class ArrowOverlay: NSView {
    private let swoosh = CAShapeLayer()
    private let head = CAShapeLayer()

    override var isFlipped: Bool { true }

    init(on button: NSView) {
        let glyph = NSRect(x: button.bounds.midX - 9, y: button.bounds.midY - 9, width: 18, height: 18)
        super.init(frame: glyph)
        autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        wantsLayer = true
        isHidden = true
        let scale = CGAffineTransform(scaleX: 18.0 / 200, y: 18.0 / 200)
        let curve = CGMutablePath()
        curve.move(to: CGPoint(x: 40, y: 150))
        curve.addCurve(to: CGPoint(x: 164, y: 112), control1: CGPoint(x: 78, y: 186), control2: CGPoint(x: 150, y: 176))
        swoosh.path = curve.copy(using: [scale])
        swoosh.fillColor = nil
        swoosh.lineWidth = 16 * 18.0 / 200
        swoosh.lineCap = .round
        let tip = CGMutablePath()
        tip.move(to: CGPoint(x: 168, y: 96)); tip.addLine(to: CGPoint(x: 182.3, y: 122.9))
        tip.addLine(to: CGPoint(x: 145.4, y: 116.4)); tip.closeSubpath()
        head.path = tip.copy(using: [scale])
        head.lineWidth = 8 * 18.0 / 200
        head.lineJoin = .round
        layer?.addSublayer(swoosh)
        layer?.addSublayer(head)
        applyColor()
        button.addSubview(self)
    }

    required init?(coder: NSCoder) { nil }

    /// The menu bar's text color, re-read when its appearance changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor.labelColor.cgColor
            swoosh.strokeColor = color
            head.strokeColor = color
            head.fillColor = color
        }
    }

    func start() {
        isHidden = false
        guard swoosh.animation(forKey: "trace") == nil else { return }
        let cycle: CFTimeInterval = 1.4
        let trace = CAKeyframeAnimation(keyPath: "strokeEnd")
        trace.values = [0, 1, 1]
        trace.keyTimes = [0, 0.6, 1]
        trace.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear)]
        trace.duration = cycle
        trace.repeatCount = .infinity
        swoosh.add(trace, forKey: "trace")
        let appear = CAKeyframeAnimation(keyPath: "opacity")
        appear.values = [0, 0, 1, 1]
        appear.keyTimes = [0, 0.55, 0.65, 1]
        appear.duration = cycle
        appear.repeatCount = .infinity
        head.add(appear, forKey: "appear")
    }

    func stop() {
        swoosh.removeAllAnimations()
        head.removeAllAnimations()
        isHidden = true
    }
}
