import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import XSideCore

struct AppIconExtractorTests {
    @Test func readsIconNamesFromInfoPlist() {
        let plist: [String: Any] = [
            "CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconName": "AppIcon", "CFBundleIconFiles": ["AppIcon60x60"]]],
            "CFBundleIcons~ipad": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60", "AppIcon76x76"]]],
        ]
        #expect(AppIconExtractor.iconNames(plist) == ["AppIcon", "AppIcon60x60", "AppIcon76x76"])
        #expect(AppIconExtractor.iconNames([:]).isEmpty)
    }

    @Test func fallsBackToLargestPNGFile() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString)/X.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try writePNG(width: 120, to: app.appendingPathComponent("AppIcon60x60@2x.png"))
        try writePNG(width: 180, to: app.appendingPathComponent("AppIcon60x60@3x.png"))
        try writePNG(width: 512, to: app.appendingPathComponent("Other.png"))
        let out = app.deletingLastPathComponent().appendingPathComponent("icon.png")
        let plist: [String: Any] = ["CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60"]]]]
        #expect(AppIconExtractor.extract(from: app, plist: plist, to: out))
        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 180)
    }

    @Test func downscalesLargeIconAndSkipsHugeOnes() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString)/X.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60"]]]]
        let out = app.deletingLastPathComponent().appendingPathComponent("icon.png")

        // Wider than 4096 px: never decoded, so no icon at all.
        try writePNG(width: 4100, height: 1, to: app.appendingPathComponent("AppIcon60x60@3x.png"))
        #expect(!AppIconExtractor.extract(from: app, plist: plist, to: out))

        try writePNG(width: 2000, to: app.appendingPathComponent("AppIcon60x60@2x.png"))
        #expect(AppIconExtractor.extract(from: app, plist: plist, to: out))
        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 1024 && image.height == 1024)
    }

    @Test func noIconNamesMeansNoIcon() {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString).png")
        #expect(!AppIconExtractor.extract(from: URL(fileURLWithPath: "/nonexistent.app"), plist: [:], to: out))
    }

    private func writePNG(width: Int, height: Int? = nil, to url: URL) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height ?? width, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let out = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(out, image, nil)
        #expect(CGImageDestinationFinalize(out))
    }
}
