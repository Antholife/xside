import Foundation
import Darwin

/// Where a converted tweak's jailbreak paths lead inside the signed app. `XSideTweakSupport.dylib`
/// (App/TweakSupport) does this at runtime, in C (`xs_tweak_redirect` in `XSTweakPathsCore.c`);
/// this is its mirror, and both run `Tests/XSideCoreTests/Fixtures/tweak-paths-fixture.json`
/// (`TweakPathsTests`, `scripts/test-tweak-support.sh`). Change them together.
///
/// Rules:
/// - `path` is absolute, under `PATH_MAX`, with no empty, `.` or `..` component (a trailing `/` is fine);
/// - a leading `/var/jb` is dropped; what's left must be `/` + one of `TweakAnalyzer.copiedPrefixes`
///   plus at least one more byte;
/// - each package (16 lowercase hex, or `deps/<packageID>`; anything else is skipped), in order:
///   `<tweaksRoot>/<package><rest>` when it exists, then, for `/Library/Application Support/<X>.bundle…`,
///   `<tweaksRoot>/<package>/<X>.bundle…` (a dropped `.bundle` sits at its package's root);
/// - a library iOS ships (`isSystemLibrary`) is never redirected;
/// - nothing else is ever asked about or returned, and no result reaches `PATH_MAX`.
public enum TweakPaths {
    public static let rootlessPrefix = "/var/jb"
    static let bundlePrefix = "Library/Application Support/"

    public static func redirect(_ path: String, packages: [String], exists: (String) -> Bool,
                                tweaksRoot: String) -> String? {
        let max = Int(PATH_MAX)
        let p = Array(path.utf8), root = Array(tweaksRoot.utf8)
        guard isAbsolute(p, max: max), isCleanPath(p), isAbsolute(root, max: max) else { return nil }
        var rest = p[...]
        let rootless = Array((rootlessPrefix + "/").utf8)
        if p.starts(with: rootless) { rest = p[(rootless.count - 1)...] }
        let body = rest.dropFirst()   // without its leading "/"
        guard let prefix = TweakAnalyzer.copiedPrefixes.map({ Array($0.utf8) })
                .first(where: { body.starts(with: $0) && body.count > $0.count }) else { return nil }
        guard !isSystemLibrary(body) else { return nil }
        let afterPrefix = body.dropFirst(prefix.count)
        var bundleTail: ArraySlice<UInt8>?
        if prefix == Array(bundlePrefix.utf8) {
            let first = afterPrefix.prefix { $0 != UInt8(ascii: "/") }
            let ext = Array(".bundle".utf8)
            if first.count > ext.count, first.suffix(ext.count).elementsEqual(ext) { bundleTail = afterPrefix }
        }
        for package in packages where isPackageFolder(package) {
            let base = root + [UInt8(ascii: "/")] + Array(package.utf8)
            var candidates = [base + rest]
            if let tail = bundleTail { candidates.append(base + [UInt8(ascii: "/")] + tail) }
            for candidate in candidates where candidate.count < max {
                let s = String(decoding: candidate, as: UTF8.self)
                if exists(s) { return s }
            }
        }
        return nil
    }

    /// A library iOS ships, which a tweak's copy never answers for: anything in `/usr/lib/system/` or
    /// `/usr/lib/swift/`, or a file directly in `/usr/lib` whose name's first dot-separated part is in
    /// `TweakClassifier.iOSUsrLibNames` (any case). `body` is the path after `/` (and `/var/jb`).
    static func isSystemLibrary(_ body: ArraySlice<UInt8>) -> Bool {
        if ["usr/lib/system/", "usr/lib/swift/"].contains(where: { body.starts(with: Array($0.utf8)) }) { return true }
        let usrLib = Array("usr/lib/".utf8)
        guard body.starts(with: usrLib) else { return false }
        let file = body.dropFirst(usrLib.count)
        guard !file.contains(UInt8(ascii: "/")),
              let base = file.split(separator: UInt8(ascii: ".")).first else { return false }
        return TweakClassifier.iOSUsrLibNames.contains(String(decoding: base, as: UTF8.self).lowercased())
    }

    /// A folder under `Frameworks/XSideTweaks/`: a tweak's 16-hex id, or `deps/<packageID>`.
    public static func isPackageFolder(_ name: String) -> Bool {
        let b = Array(name.utf8)
        if b.count == 16, b.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) { return true }
        let deps = Array((TweakLayout.depsFolder + "/").utf8)
        guard b.starts(with: deps) else { return false }
        return DebControl.isValidPackageID(String(decoding: b[deps.count...], as: UTF8.self))
    }

    private static func isAbsolute(_ b: [UInt8], max: Int) -> Bool {
        b.first == UInt8(ascii: "/") && b.count < max && !b.contains(0)
    }

    /// No empty (`//`), `.` or `..` component; a trailing `/` is allowed.
    private static func isCleanPath(_ b: [UInt8]) -> Bool {
        let parts = b.dropFirst().split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        for (i, part) in parts.enumerated() {
            if part.isEmpty { if i != parts.count - 1 { return false }; continue }
            if part.elementsEqual([46]) || part.elementsEqual([46, 46]) { return false }
        }
        return true
    }
}
