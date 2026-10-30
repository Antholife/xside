import Foundation

/// One Xcode app found on this Mac.
public struct XcodeInstall: Equatable, Sendable, Identifiable {
    /// `/Applications/Xcode-beta.app`.
    public let appURL: URL
    public let version: String
    public let build: String
    public let isBeta: Bool

    public init(appURL: URL, version: String, build: String, isBeta: Bool) {
        self.appURL = appURL
        self.version = version
        self.build = build
        self.isBeta = isBeta
    }

    public var id: String { appURL.path }
    /// `/Applications/Xcode-beta.app/Contents/Developer`, what `DEVELOPER_DIR` names.
    public var developerDir: URL { appURL.appendingPathComponent("Contents/Developer", isDirectory: true) }
}

/// Which Xcode XSide runs its tools with: chosen by XSide ("auto") or a developer directory picked
/// in Settings. Stored as its `rawValue` under `storageKey`.
public enum XcodeSelection: Equatable, Sendable {
    case automatic
    /// A developer directory (`…/Xcode.app/Contents/Developer`).
    case path(String)

    public static let storageKey = "xcodeSelection"

    public init(rawValue: String?) {
        guard let rawValue, rawValue != "auto", !rawValue.isEmpty else { self = .automatic; return }
        self = .path(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .automatic: "auto"
        case .path(let path): path
        }
    }
}

/// Finds the Xcode apps installed in /Applications and ~/Applications, and picks the one to use.
public enum XcodeLocator {
    public static let bundleID = "com.apple.dt.Xcode"

    /// Where Xcode apps are looked for.
    public static func searchDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         home.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// The Xcode apps directly inside `directories` (bundle id `com.apple.dt.Xcode`, with a
    /// readable version), newest first. The same app reached twice (symlink) is listed once.
    public static func find(in directories: [URL] = searchDirectories()) -> [XcodeInstall] {
        let fm = FileManager.default
        var seen: Set<String> = []
        var found: [XcodeInstall] = []
        for directory in directories {
            guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { continue }
            // Real apps before symlinks to them, so the app keeps its own name.
            let apps = names.filter { $0.hasSuffix(".app") }.map { directory.appendingPathComponent($0, isDirectory: true) }
            let isLink = { (url: URL) in (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
            for app in apps.filter({ !isLink($0) }).sorted(by: { $0.path < $1.path })
                + apps.filter(isLink).sorted(by: { $0.path < $1.path }) {
                guard bundleIdentifier(of: app) == bundleID else { continue }
                let resolved = app.resolvingSymlinksInPath().path
                guard seen.insert(resolved).inserted else { continue }
                let developerDir = app.appendingPathComponent("Contents/Developer", isDirectory: true)
                guard let version = XcodeCompat.xcodeVersion(developerDir: developerDir) else { continue }
                found.append(XcodeInstall(appURL: app, version: version.version, build: version.build,
                                          isBeta: version.isBeta))
            }
        }
        return found.sorted { isNewer($0, than: $1) }
    }

    /// `CFBundleIdentifier` of an app's `Contents/Info.plist`.
    static func bundleIdentifier(of app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    /// Newer version first ("27.10" > "27.9"), then the higher build ("27B48" > "27B12").
    public static func isNewer(_ a: XcodeInstall, than b: XcodeInstall) -> Bool {
        let va = a.version.split(separator: ".").map { Int($0) ?? 0 }
        let vb = b.version.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(va.count, vb.count) {
            let x = i < va.count ? va[i] : 0, y = i < vb.count ? vb[i] : 0
            if x != y { return x > y }
        }
        if a.build != b.build { return a.build.compare(b.build, options: .numeric) == .orderedDescending }
        return a.appURL.path < b.appURL.path
    }

    /// The Xcode `xcode-select -p` points to, as XSide sees it.
    public struct Selected: Equatable, Sendable {
        public let developerDir: URL
        /// It has `usr/bin/xcodebuild` (Command Line Tools alone don't).
        public let isXcode: Bool
        public let isBeta: Bool

        public init(developerDir: URL, isXcode: Bool, isBeta: Bool) {
            self.developerDir = developerDir
            self.isXcode = isXcode
            self.isBeta = isBeta
        }
    }

    /// The automatic choice: on a macOS beta, a beta Xcode (the selected one if it is a beta, else
    /// the newest beta found); otherwise the Xcode `xcode-select` points to, else the newest
    /// release Xcode found, else the newest Xcode found; else the `xcode-select` result as is (it
    /// fails the probe with "Xcode missing"). Nil when there is nothing at all.
    /// `unready`: developer directories of beta Xcode apps not usable yet (license not accepted,
    /// first launch not done, see `firstLaunchArguments`): never switched to.
    public static func automatic(selected: Selected?, installs: [XcodeInstall], macIsBeta: Bool,
                                 unready: Set<String> = []) -> URL? {
        if let selected, selected.isXcode, !macIsBeta || selected.isBeta { return selected.developerDir }
        if macIsBeta, let beta = installs.filter({ $0.isBeta && !unready.contains($0.developerDir.path) })
            .sorted(by: isNewer).first { return beta.developerDir }
        if let selected, selected.isXcode { return selected.developerDir }
        if let release = installs.filter({ !$0.isBeta }).sorted(by: isNewer).first { return release.developerDir }
        if let any = installs.sorted(by: isNewer).first { return any.developerDir }
        return selected?.developerDir
    }

    /// The developer directory to run the tools with: the one picked in Settings while it still
    /// holds an Xcode, else the automatic choice.
    public static func resolve(_ selection: XcodeSelection, selected: Selected?, installs: [XcodeInstall],
                               macIsBeta: Bool, unready: Set<String> = [], hasXcodebuild: (URL) -> Bool) -> URL? {
        if case .path(let path) = selection {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            if hasXcodebuild(dir) { return dir }
        }
        return automatic(selected: selected, installs: installs, macIsBeta: macIsBeta, unready: unready)
    }

    /// The beta Xcode apps to check before the automatic choice may switch to one (newest
    /// first): only on a macOS beta, when `xcode-select` doesn't already point to a beta Xcode.
    public static func betasToCheck(selected: Selected?, installs: [XcodeInstall], macIsBeta: Bool) -> [XcodeInstall] {
        guard macIsBeta, !(selected?.isXcode == true && selected?.isBeta == true) else { return [] }
        return installs.filter(\.isBeta).sorted(by: isNewer)
    }

    /// `xcodebuild -checkFirstLaunchStatus` (exit 0: license accepted and first launch done), run
    /// with the developer directory's own xcodebuild. A read-only status check.
    public static func firstLaunchCheck(_ developerDir: URL) -> (executable: String, arguments: [String]) {
        (developerDir.appendingPathComponent("usr/bin/xcodebuild").path, ["-checkFirstLaunchStatus"])
    }

    /// True when `developerDir` holds `usr/bin/xcodebuild`.
    public static func hasXcodebuild(_ developerDir: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: developerDir.appendingPathComponent("usr/bin/xcodebuild").path)
    }
}
