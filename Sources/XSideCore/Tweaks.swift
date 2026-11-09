import Foundation

public enum TweakKind: String, Codable, Sendable { case deb, dylib, framework, bundle }

public enum TweakOrigin: Codable, Equatable, Sendable {
    /// Dropped or chosen by the person.
    case added
    /// Fetched from a trusted repo after the person confirmed.
    case downloaded(repo: String, url: String, sha256: String)
    /// XSide's own dependency.
    case embedded
}

public struct TweakSlice: Codable, Equatable, Sendable {
    public var arch: String
    public var platform: UInt32?
    public var minOS: String?

    public init(arch: String, platform: UInt32?, minOS: String?) {
        self.arch = arch
        self.platform = platform
        self.minOS = minOS
    }
}

/// One Mach-O file of a stored package.
public struct TweakBinary: Codable, Equatable, Sendable {
    /// Relative to the package's folder.
    public var path: String
    /// Loaded into the app by a load command (otherwise a library others link).
    public var isEntry: Bool
    /// The `.deb`'s filter plist; nil for a dropped `.dylib` or `.framework` (made for this app)
    /// and for libraries. An empty filter targets nothing.
    public var filter: TweakFilter?
    public var slices: [TweakSlice]
    public var linked: [String]
    /// Its bytes contain a jailbreak path (`/var/jb/`, `/Library/MobileSubstrate/`, ...).
    public var mentionsJailbreakPaths: Bool
    /// The file name, as crash logs name the image.
    public var imageName: String

    public init(path: String, isEntry: Bool, filter: TweakFilter?, slices: [TweakSlice], linked: [String],
                mentionsJailbreakPaths: Bool, imageName: String) {
        self.path = path
        self.isEntry = isEntry
        self.filter = filter
        self.slices = slices
        self.linked = linked
        self.mentionsJailbreakPaths = mentionsJailbreakPaths
        self.imageName = imageName
    }
}

public enum TweakNote: String, Codable, Sendable {
    /// PreferenceBundles / PreferenceLoader files were left out.
    case settingsNotConverted
    /// Files outside the copied folders (or unusable Mach-O files) were left out.
    case filesIgnored
    /// Symbolic or hard links in the archive were skipped.
    case linksSkipped
}

/// A tweak analysed and stored under `<storage>/<id>/`.
public struct TweakPackage: Codable, Equatable, Sendable, Identifiable {
    /// 16 lowercase hex digits of the SHA-256 of a kind tag (`deb-`, `dylib-`, `fw-`, `bundle-`)
    /// followed by the source (folders: by their sorted `"path\0sha256\n"` lines, Finder files left out).
    public let id: String
    public var kind: TweakKind
    public var origin: TweakOrigin
    public var packageID: String
    public var provides: [String]
    public var name: String
    public var version: String?
    public var author: String?
    public var architecture: String?
    public var depends: [[DebDependency]]
    /// Every stored file, relative to the package's folder, sorted.
    public var files: [String]
    public var binaries: [TweakBinary]
    public var notes: [TweakNote]
    public var addedAt: Date

    public var entries: [TweakBinary] { binaries.filter(\.isEntry) }

    public init(id: String, kind: TweakKind, origin: TweakOrigin, packageID: String, provides: [String] = [],
                name: String, version: String? = nil, author: String? = nil, architecture: String? = nil,
                depends: [[DebDependency]] = [], files: [String] = [], binaries: [TweakBinary] = [],
                notes: [TweakNote] = [], addedAt: Date) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.packageID = packageID
        self.provides = provides
        self.name = name
        self.version = version
        self.author = author
        self.architecture = architecture
        self.depends = depends
        self.files = files
        self.binaries = binaries
        self.notes = notes
        self.addedAt = addedAt
    }
}

extension TweakPackage {
    /// One of its entries' filters names `target` (a bundle id, executable or class).
    public func filterNames(_ target: String) -> Bool {
        entries.contains { b in
            guard let f = b.filter else { return false }
            return f.bundles.contains(target) || f.executables.contains(target) || f.classes.contains(target)
        }
    }

    /// The app it says it's for: its first entry's first filter bundle id (nil: none named).
    public var targetBundleID: String? { entries.lazy.compactMap { $0.filter?.bundles.first }.first }
}

/// Where tweaks go inside a signed app.
public enum TweakLayout {
    /// Relative to the `.app`.
    public static let folder = "Frameworks/XSideTweaks"
    public static let loadPrefix = "@executable_path/Frameworks/XSideTweaks/"
    /// Inside `folder`: XSide's embedded dependencies, one folder per package id.
    public static let depsFolder = "deps"

    public static let elleKitName = "ElleKit.dylib"
    public static let elleKitLoadPath = loadPrefix + elleKitName
    public static let elleKitLicenseName = "ElleKit-LICENSE.txt"

    public static let supportName = "XSideTweakSupport.dylib"
    public static let supportLoadPath = loadPrefix + supportName

    public static let bundlesKey = "XSideTweakBundles"
    public static let pathsKey = "XSideTweakPaths"

    /// The package's folder inside `folder`: its `id`, or `deps/<packageID>` for XSide's own.
    public static func directory(_ package: TweakPackage) -> String {
        package.origin == .embedded ? depsFolder + "/" + package.packageID : package.id
    }

    public static func loadPath(_ package: TweakPackage, _ binary: TweakBinary) -> String {
        loadPrefix + directory(package) + "/" + binary.path
    }
}

/// XSide's own tweak dependencies, built from source by `scripts/build-tweak-deps.sh` into
/// `XSide.app/Contents/Resources/TweakDependencies/<packageID>/`: a `package.json` (a `TweakPackage`,
/// `origin: .embedded`) next to its files, laid out as on a jailbreak.
public enum TweakDependencyCatalog {
    public static let fileName = "package.json"
    static let maxPackageJSONBytes = 1024 * 1024
    static let maxPackages = 64

    /// Every usable package, by folder name. A folder whose `package.json` is unreadable, isn't
    /// XSide's own package for that folder, names a file outside it, or misses a file is left out.
    public static func load(from folder: URL?) -> [TweakPackage] {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [TweakPackage] = []
        for name in names.sorted().prefix(maxPackages) where !name.hasPrefix(".") && DebControl.isValidPackageID(name) {
            let dir = folder.appendingPathComponent(name, isDirectory: true)
            guard let data = readRegular(dir.appendingPathComponent(fileName), max: maxPackageJSONBytes),
                  let p = try? decoder.decode(TweakPackage.self, from: data),
                  p.origin == .embedded, p.packageID == name, p.id == name, !p.binaries.isEmpty,
                  p.files.allSatisfy({ isSafe($0) && isRegular($0, in: dir) }),
                  p.binaries.allSatisfy({ p.files.contains($0.path) }) else { continue }
            out.append(p)
        }
        return out
    }

    private static func isSafe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.utf8.contains(0)
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// `path` under `dir` is a regular file and every folder on the way a real folder (no link anywhere).
    private static func isRegular(_ path: String, in dir: URL) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        var url = dir
        for (i, part) in parts.enumerated() {
            url.appendPathComponent(part)
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return false }
            guard st.st_mode & S_IFMT == (i == parts.count - 1 ? S_IFREG : S_IFDIR) else { return false }
        }
        return true
    }

    private static func isRegular(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG
    }

    private static func readRegular(_ url: URL, max: Int) -> Data? {
        guard isRegular(url), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: max + 1), data.count <= max else { return nil }
        return data
    }
}
