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
