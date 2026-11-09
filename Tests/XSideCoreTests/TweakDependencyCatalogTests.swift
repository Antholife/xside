import Testing
import Foundation
@testable import XSideCore

/// XSide's own dependencies, shipped in `XSide.app/Contents/Resources/TweakDependencies/<packageID>/`
/// (`scripts/build-tweak-deps.sh`).
@Suite struct TweakDependencyCatalogTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static func cephei(files: [String] = ["Library/Frameworks/Cephei.framework/Cephei",
                                          "Library/Frameworks/Cephei.framework/Info.plist"]) -> TweakPackage {
        let bin = TweakBinary(path: "Library/Frameworks/Cephei.framework/Cephei", isEntry: false, filter: nil,
                              slices: [TweakSlice(arch: "arm64", platform: 2, minOS: "15.0"),
                                       TweakSlice(arch: "arm64e", platform: 2, minOS: "15.0")],
                              linked: ["/System/Library/Frameworks/Foundation.framework/Foundation"],
                              mentionsJailbreakPaths: true, imageName: "Cephei")
        return TweakPackage(id: "ws.hbang.common", kind: .deb, origin: .embedded, packageID: "ws.hbang.common",
                            name: "Cephei Tweak Support", version: "2.0", author: "HASHBANG Productions",
                            architecture: "iphoneos-arm64",
                            depends: [[DebDependency(package: "firmware", relation: ">=", version: "15.0")]],
                            files: files, binaries: [bin], addedAt: now)
    }

    static func lib(_ id: String) -> TweakPackage {
        let bin = TweakBinary(path: "usr/lib/\(id).dylib", isEntry: false, filter: nil,
                              slices: [TweakSlice(arch: "arm64", platform: 2, minOS: "15.0")], linked: [],
                              mentionsJailbreakPaths: false, imageName: "\(id).dylib")
        return TweakPackage(id: id, kind: .deb, origin: .embedded, packageID: id, name: id, version: "1.0",
                            files: [bin.path], binaries: [bin], addedAt: now)
    }

    /// Writes `package` under `root/<folder>/` with its files (unless left out).
    static func write(_ package: TweakPackage, in root: URL, folder: String? = nil, without: Set<String> = []) throws {
        let dir = root.appendingPathComponent(folder ?? package.packageID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(package).write(to: dir.appendingPathComponent("package.json"))
        for f in package.files where !without.contains(f) {
            let url = dir.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    @Test func loadsEachPackageJson() async throws {
        try await withTemporaryDirectory { root in
            try Self.write(Self.cephei(), in: root)
            try Self.write(Self.lib("libroot"), in: root)
            try Data().write(to: root.appendingPathComponent(".DS_Store"))
            let got = TweakDependencyCatalog.load(from: root)
            #expect(got == [Self.lib("libroot"), Self.cephei()])
        }
    }

    @Test func skipsAPackageWhoseFileIsMissing() async throws {
        try await withTemporaryDirectory { root in
            try Self.write(Self.cephei(), in: root, without: ["Library/Frameworks/Cephei.framework/Info.plist"])
            try Self.write(Self.lib("libroot"), in: root)
            #expect(TweakDependencyCatalog.load(from: root) == [Self.lib("libroot")])
        }
    }

    @Test func emptyWithoutFolder() async throws {
        #expect(TweakDependencyCatalog.load(from: nil).isEmpty)
        try await withTemporaryDirectory { root in
            #expect(TweakDependencyCatalog.load(from: root.appendingPathComponent("missing")).isEmpty)
            let file = root.appendingPathComponent("file")
            try Data().write(to: file)
            #expect(TweakDependencyCatalog.load(from: file).isEmpty)
        }
    }

    @Test func skipsUnreadableAndInconsistentPackages() async throws {
        try await withTemporaryDirectory { root in
            try Self.write(Self.lib("libroot"), in: root)
            // Not JSON, not a package, too large.
            for (name, data) in [("garbage", Data("{not json".utf8)), ("other", Data("{\"a\":1}".utf8)),
                                 ("huge", Data(repeating: 0x20, count: TweakDependencyCatalog.maxPackageJSONBytes + 1))] {
                let dir = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: dir.appendingPathComponent("package.json"))
            }
            // A folder without package.json.
            try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
            // Folder name and package id disagree.
            try Self.write(Self.lib("a.b"), in: root, folder: "c.d")
            // Not XSide's own.
            var added = Self.lib("added.one")
            added.origin = .added
            try Self.write(added, in: root)
            // A file outside its folder, an absolute path, a binary not among the files.
            var escape = Self.lib("escape.one")
            escape.files.append("../libroot/package.json")
            try Self.write(escape, in: root, without: ["../libroot/package.json"])
            var absolute = Self.lib("absolute.one")
            absolute.files.append("/etc/hosts")
            try Self.write(absolute, in: root, without: ["/etc/hosts"])
            var stray = Self.lib("stray.one")
            stray.binaries[0].path = "usr/lib/other.dylib"
            try Self.write(stray, in: root)
            // A file that is a link.
            var linked = Self.lib("linked.one")
            linked.files.append("usr/lib/link.dylib")
            try Self.write(linked, in: root, without: ["usr/lib/link.dylib"])
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("linked.one/usr/lib/link.dylib").path,
                                                       withDestinationPath: "/etc/hosts")
            // A folder on the way that is a link.
            var viaLink = Self.lib("vialink.one")
            viaLink.files.append("lib/x.dylib")
            try Self.write(viaLink, in: root, without: ["lib/x.dylib"])
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("vialink.one/lib").path,
                                                       withDestinationPath: root.appendingPathComponent("vialink.one/usr/lib").path)
            try Data().write(to: root.appendingPathComponent("vialink.one/usr/lib/x.dylib"))
            // No binary at all.
            var empty = Self.lib("nobinary.one")
            empty.binaries = []
            try Self.write(empty, in: root)

            #expect(TweakDependencyCatalog.load(from: root) == [Self.lib("libroot")])
        }
    }

    /// The catalog `scripts/bundle.sh` put in a built app, when there is one: every package loads,
    /// and what its `package.json` says about each binary is what XSide reads from the file itself.
    @Test func builtCatalogMatchesItsFiles() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for app in ["build/XSide-debug.app", "build/XSide.app"] {
            let folder = repo.appendingPathComponent(app).appendingPathComponent("Contents/Resources/TweakDependencies")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            let packages = TweakDependencyCatalog.load(from: folder)
            #expect(packages.map(\.packageID).sorted() == names.filter { !$0.hasPrefix(".") }.sorted(), "\(app)")
            for p in packages {
                for b in p.binaries {
                    let url = folder.appendingPathComponent(p.packageID).appendingPathComponent(b.path)
                    let slices = try MachOBuildInfo.slices(of: url)
                    #expect(b.slices == slices.map { TweakSlice(arch: TweakAnalyzer.archName($0), platform: $0.platform, minOS: $0.minOS) },
                            "\(app) \(b.path)")
                    #expect(b.linked == (try MachOPatcher.linkedDylibs(in: url)), "\(app) \(b.path)")
                    #expect(b.mentionsJailbreakPaths == MachOPatcher.containsAny(TweakAnalyzer.jailbreakPathNeedles, in: url),
                            "\(app) \(b.path)")
                    #expect(b.imageName == url.lastPathComponent)
                }
            }
        }
    }
}
