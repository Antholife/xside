#!/usr/bin/env swift
// Generates App/Resources/MenuBarIcon.pdf and App/Resources/AppIcon.icns ("Z21" design).
// Usage: swift scripts/make-icons.swift   (run from anywhere)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("App/Resources")
let cs = CGColorSpaceCreateDeviceRGB()

func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}
let swoosh: CGPath = {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 40, y: 150))
    p.addCurve(to: CGPoint(x: 164, y: 112), control1: CGPoint(x: 78, y: 186), control2: CGPoint(x: 150, y: 176))
    return p
}()
let arrow: CGPath = {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 168, y: 96)); p.addLine(to: CGPoint(x: 182.3, y: 122.9))
    p.addLine(to: CGPoint(x: 145.4, y: 116.4)); p.closeSubpath()
    return p
}()

/// Draws the glyph in the 200x200 design space (y down, origin top-left).
func drawGlyph(_ c: CGContext, phone: CGColor, accent: CGColor, island: Bool, swooshWidth: CGFloat, arrowStroke: CGFloat) {
    c.setFillColor(phone)
    c.addPath(rr(70, 34, 60, 112, 18)); c.fillPath()
    if island {
        c.setFillColor(accent.copy(alpha: 0.85)!)
        c.addPath(rr(89, 42, 22, 7, 3.5)); c.fillPath()
    }
    c.setStrokeColor(accent); c.setLineCap(.round); c.setLineJoin(.round)
    c.setLineWidth(swooshWidth); c.addPath(swoosh); c.strokePath()
    c.setFillColor(accent); c.setLineWidth(arrowStroke)
    c.addPath(arrow); c.drawPath(using: .fillStroke)
}

// MARK: Menu-bar template PDF (18x18 pt, black on transparent)
func makeMenuBarPDF() {
    var box = CGRect(x: 0, y: 0, width: 18, height: 18)
    let url = resources.appendingPathComponent("MenuBarIcon.pdf")
    let c = CGContext(url as CFURL, mediaBox: &box, nil)!
    c.beginPDFPage(nil)
    c.translateBy(x: 0, y: 18); c.scaleBy(x: 18.0 / 200, y: -18.0 / 200)
    let black = CGColor(gray: 0, alpha: 1)
    drawGlyph(c, phone: black, accent: black, island: false, swooshWidth: 16, arrowStroke: 8)
    c.endPDFPage(); c.closePDF()
}

// MARK: Colour app icon
func drawAppIcon(_ c: CGContext, px: Int) {
    let s = CGFloat(px) / 1024
    c.scaleBy(x: s, y: s)
    c.translateBy(x: 0, y: 1024); c.scaleBy(x: 1, y: -1) // y down, 1024 space
    let k: CGFloat = 824.0 / 200
    let sq = rr(100, 100, 824, 824, 45 * k)
    // soft drop shadow
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: CGColor(gray: 0, alpha: 0.30))
    c.setFillColor(CGColor(gray: 0, alpha: 1)); c.addPath(sq); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(sq); c.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0x5b/255.0, green: 0x4c/255.0, blue: 0xf0/255.0, alpha: 1),
        CGColor(red: 0x8b/255.0, green: 0x3d/255.0, blue: 0xf2/255.0, alpha: 1)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(grad, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 924, y: 924), options: [])
    let sheen = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1, alpha: 0.18), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 0.55])!
    c.drawLinearGradient(sheen, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    c.translateBy(x: 100, y: 100); c.scaleBy(x: k, y: k)
    drawGlyph(c, phone: CGColor(gray: 1, alpha: 1), accent: CGColor(red: 1, green: 0xe1/255.0, blue: 0x4d/255.0, alpha: 1),
              island: true, swooshWidth: 13, arrowStroke: 7)
    c.restoreGState()
}

func writePNG(px: Int, to url: URL) {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    drawAppIcon(c, px: px)
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, c.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(d))
}

func makeICNS() throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("xside-icons-\(UUID().uuidString)")
    let set = tmp.appendingPathComponent("AppIcon.iconset")
    try fm.createDirectory(at: set, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    for base in [16, 32, 128, 256, 512] {
        writePNG(px: base, to: set.appendingPathComponent("icon_\(base)x\(base).png"))
        writePNG(px: base * 2, to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", set.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
    try p.run(); p.waitUntilExit()
    precondition(p.terminationStatus == 0, "iconutil failed")
}

makeMenuBarPDF()
try makeICNS()
print("Wrote MenuBarIcon.pdf and AppIcon.icns in \(resources.path)")
