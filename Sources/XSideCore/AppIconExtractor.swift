import CoreGraphics
import Foundation
import ImageIO
import ObjectiveC
import UniformTypeIdentifiers

/// Pulls the app's own icon out of an unzipped `.app`, as a PNG. Modern apps keep it only in the
/// compiled asset catalog (`Assets.car`), read with CoreUI's `CUICatalog`, the reader macOS itself
/// uses (private, loaded at runtime: on failure there's simply no icon). Older apps ship
/// `AppIcon60x60@3x.png`-style files, used as a fallback. Best effort: nil when nothing is found.
/// The `.ipa` is untrusted: files and images past sane sizes are skipped, and the icon is decoded
/// and written at most `maxIconSize` pixels wide.
public enum AppIconExtractor {
    /// Largest side of the written icon (an app icon is 1024 px at most).
    static let maxIconSize = 1024
    /// Images declaring a larger side are skipped, never decoded.
    static let maxSourceSize = 4096
    static let maxPNGBytes = 20 * 1024 * 1024
    static let maxCatalogBytes = 200 * 1024 * 1024

    /// Icon names from `Info.plist`: `CFBundleIconName`, then `CFBundleIconFiles` (iPhone and iPad).
    public static func iconNames(_ plist: [String: Any]) -> [String] {
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = plist[key] as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] else { continue }
            if let name = primary["CFBundleIconName"] as? String { names.append(name) }
            names += primary["CFBundleIconFiles"] as? [String] ?? []
        }
        names += plist["CFBundleIconFiles"] as? [String] ?? []
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Writes the largest icon found in `app` to `destination` (PNG). True on success.
    @discardableResult
    public static func extract(from app: URL, plist: [String: Any], to destination: URL) -> Bool {
        let names = iconNames(plist)
        guard !names.isEmpty else { return false }
        let image = catalogImage(app.appendingPathComponent("Assets.car"), names: names)
            ?? fileImage(in: app, names: names)
        guard let image, let icon = downscaled(image) else { return false }
        return writePNG(icon, to: destination)
    }

    /// The largest rendition named like the icon in the asset catalog.
    private static func catalogImage(_ car: URL, names: [String]) -> CGImage? {
        guard isRegularFile(car), fileSize(car) <= maxCatalogBytes,
              dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW) != nil,
              let catalogClass = NSClassFromString("CUICatalog") as? NSObject.Type else { return nil }
        // `alloc` hands back a +1 object, which `init` consumes and replaces by its +1 result (or
        // releases, returning nil). `Unmanaged` on both ends keeps ARC out of that exchange.
        typealias InitWithURL = @convention(c) (Unmanaged<AnyObject>, Selector, NSURL,
                                                UnsafeMutablePointer<NSError?>?) -> Unmanaged<AnyObject>?
        let initSelector = NSSelectorFromString("initWithURL:error:")
        guard catalogClass.instancesRespond(to: initSelector) else { return nil }
        let initialize = unsafeBitCast(catalogClass.instanceMethod(for: initSelector), to: InitWithURL.self)
        guard let allocated = catalogClass.perform(NSSelectorFromString("alloc")),
              let catalog = initialize(allocated, initSelector, car as NSURL, nil)?.takeRetainedValue() as? NSObject
        else { return nil }

        let imagesSelector = NSSelectorFromString("imagesWithName:"), imageSelector = NSSelectorFromString("image")
        guard catalog.responds(to: imagesSelector) else { return nil }
        return autoreleasepool {
            var best: CGImage?
            for name in names {
                let renditions = catalog.perform(imagesSelector, with: name)?.takeUnretainedValue() as? [NSObject] ?? []
                for rendition in renditions where rendition.responds(to: imageSelector) {
                    guard let object = rendition.perform(imageSelector)?.takeUnretainedValue(),
                          CFGetTypeID(object) == CGImage.typeID else { continue }
                    let image = object as! CGImage
                    guard image.width <= maxSourceSize, image.height <= maxSourceSize else { continue }
                    if image.width > best?.width ?? 0 { best = image }
                }
                if best != nil { return best }
            }
            return nil
        }
    }

    /// The largest `<name>*.png` at the top of the bundle (regular files only, never links).
    private static func fileImage(in app: URL, names: [String]) -> CGImage? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil) else {
            return nil
        }
        let candidates = files.filter { file in
            file.pathExtension.lowercased() == "png" && isRegularFile(file) && fileSize(file) <= maxPNGBytes
                && names.contains { file.lastPathComponent.hasPrefix($0) }
        }
        // Sizes come from the header; only the largest acceptable one is decoded, as a thumbnail.
        let sized = candidates.compactMap { url -> (source: CGImageSource, width: Int)? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= maxSourceSize, height <= maxSourceSize else { return nil }
            return (source, width)
        }
        guard let largest = sized.max(by: { $0.width < $1.width }) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxIconSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(largest.source, 0, options as CFDictionary)
    }

    /// `image` itself when it fits in `maxIconSize`, else redrawn to fit.
    private static func downscaled(_ image: CGImage) -> CGImage? {
        let side = max(image.width, image.height)
        guard side > maxIconSize else { return image }
        let scale = Double(maxIconSize) / Double(side)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func writePNG(_ image: CGImage, to destination: URL) -> Bool {
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let out = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(out, image, nil)
        return CGImageDestinationFinalize(out)
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? .max
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }
}
