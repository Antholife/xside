import Foundation
import Testing
@testable import XSideCore

struct TweakAnalyzerTests {
    private let arm64: UInt32 = 0x0100000C
    private let armv7: UInt32 = 12
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let control = "Package: com.example.tweak\nName: Example Tweak\nVersion: 1.2\nAuthor: Jane <j@x.y>\nArchitecture: iphoneos-arm64\nDepends: mobilesubstrate, firmware (>= 15.0)\nProvides: example-tweak\n"

    private func scratch(_ label: String) -> URL {
        TestTemp.root.appendingPathComponent("tweak-\(label)-\(UUID().uuidString)")
    }
    private func dylib(_ strings: [String] = [], linking: [String] = ["/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"]) -> Data {
        FakeIPA.dylibMachO(linking: linking, padding: 64, strings: strings)
    }
    private func filterPlist(_ bundles: [String]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["Filter": ["Bundles": bundles]], format: .xml, options: 0)
    }
    private func deb(_ files: [FakeDeb.Entry], control: String? = nil) async throws -> URL {
        let url = scratch("src").appendingPathExtension("deb")
        try await FakeDeb.deb(control: control ?? self.control, files: files, compression: "gz").write(to: url)
        return url
    }
    private func analyze(_ source: URL, into storage: URL) async throws -> TweakPackage {
        try await TweakAnalyzer.analyze(source, into: storage, runner: ProcessRunner(), now: now)
    }
    private func contents(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }
    private func cleanup(_ urls: URL...) { for u in urls { try? FileManager.default.removeItem(at: u) } }

    // MARK: .deb

    @Test func rootfulDebBecomesOneEntryWithItsFilter() async throws {
        let src = try await deb([.file("./Library/MobileSubstrate/DynamicLibraries/Example.dylib", dylib()),
                                 .file("./Library/MobileSubstrate/DynamicLibraries/Example.plist", try filterPlist(["com.example.app"]))])
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        let p = try await analyze(src, into: storage)
        #expect(p.kind == .deb && p.origin == .added)
        #expect(p.packageID == "com.example.tweak" && p.name == "Example Tweak" && p.version == "1.2" && p.author == "Jane")
        #expect(p.architecture == "iphoneos-arm64" && p.depends.count == 2 && p.addedAt == now)
        #expect(p.entries.count == 1)
        let e = try #require(p.entries.first)
        #expect(e.path == "Library/MobileSubstrate/DynamicLibraries/Example.dylib")
        #expect(e.filter == TweakFilter(bundles: ["com.example.app"]))
        #expect(e.imageName == "Example.dylib")
        #expect(e.linked == ["/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"])
        #expect(e.slices == [TweakSlice(arch: "arm64", platform: nil, minOS: nil)])
        #expect(e.mentionsJailbreakPaths == false)
        #expect(p.files == ["Library/MobileSubstrate/DynamicLibraries/Example.dylib",
                            "Library/MobileSubstrate/DynamicLibraries/Example.plist"])
        #expect(p.notes.isEmpty)
        #expect(p.id.count == 16 && p.id.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(contents(storage) == [p.id])
        #expect(try Data(contentsOf: storage.appendingPathComponent(p.id).appendingPathComponent(e.path)) == dylib())
    }

    @Test func rootlessPathsLoseVarJb() async throws {
        let src = try await deb([.file("./var/jb/usr/lib/TweakInject/Example.dylib", dylib()),
                                 .file("./var/jb/usr/lib/TweakInject/Example.plist", try filterPlist(["com.example.app"])),
                                 .file("./var/jb/Library/Application Support/Example/res.txt", Data("r".utf8))])
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        let p = try await analyze(src, into: storage)
        #expect(p.entries.map(\.path) == ["usr/lib/TweakInject/Example.dylib"])
        #expect(p.files.contains("Library/Application Support/Example/res.txt"))
        #expect(p.files.allSatisfy { !$0.hasPrefix("var/") })
    }

    @Test func preferenceBundlesAreDroppedWithANote() async throws {
        let src = try await deb([.file("./Library/MobileSubstrate/DynamicLibraries/Example.dylib", dylib()),
                                 .file("./Library/MobileSubstrate/DynamicLibraries/Example.plist", try filterPlist(["com.example.app"])),
                                 .file("./Library/PreferenceBundles/ExamplePrefs.bundle/ExamplePrefs", dylib()),
                                 .file("./Library/PreferenceLoader/Preferences/Example.plist", Data("p".utf8))])
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        let p = try await analyze(src, into: storage)
        #expect(p.notes == [.settingsNotConverted])
        #expect(p.files.allSatisfy { !$0.hasPrefix("Library/Preference") })
        #expect(!FileManager.default.fileExists(atPath: storage.appendingPathComponent("\(p.id)/Library/PreferenceBundles").path))
    }

    @Test func otherSkippedFilesAndLinksAreNoted() async throws {
        let src = try await deb([.file("./Library/MobileSubstrate/DynamicLibraries/Example.dylib", dylib()),
                                 .file("./usr/share/doc/example/README", Data("doc".utf8)),
                                 .file("./usr/bin/exampletool", dylib()),
                                 .file("./usr/lib/helper-tool", dylib()),
                                 .symlink("./usr/lib/libexample.dylib", to: "libexample.1.dylib")])
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        let p = try await analyze(src, into: storage)
        #expect(p.notes == [.filesIgnored, .linksSkipped])
        // A Mach-O under a copied prefix that is neither a .dylib nor in a framework goes too.
        #expect(p.files == ["Library/MobileSubstrate/DynamicLibraries/Example.dylib"])
        #expect(!FileManager.default.fileExists(atPath: storage.appendingPathComponent("\(p.id)/usr/lib/helper-tool").path))
    }

    @Test func aLibraryPackageHasNoEntryButKeepsItsFramework() async throws {
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Example"], format: .xml, options: 0)
        let src = try await deb([.file("./Library/Frameworks/Example.framework/Example", dylib(linking: [])),
                                 .file("./Library/Frameworks/Example.framework/Info.plist", info),
                                 .file("./usr/lib/libexample.dylib", dylib(linking: []))])
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        let p = try await analyze(src, into: storage)
        #expect(p.entries.isEmpty)
        #expect(p.binaries.map(\.path) == ["Library/Frameworks/Example.framework/Example", "usr/lib/libexample.dylib"])
        #expect(p.binaries.allSatisfy { !$0.isEntry && $0.filter == nil })
        #expect(p.binaries.map(\.imageName) == ["Example", "libexample.dylib"])
        #expect(p.files.contains("Library/Frameworks/Example.framework/Info.plist"))
    }

    @Test func aDylibWithoutPlistInDynamicLibrariesIsNotAnEntry() async throws {
        let src = try await deb([.file("./Library/MobileSubstrate/DynamicLibraries/Example.dylib", dylib()),
                                 .file("./Library/MobileSubstrate/DynamicLibraries/Broken.dylib", dylib()),
                                 .file("./Library/MobileSubstrate/DynamicLibraries/Broken.plist", Data("<not a plist".utf8)),
                                 .file("./Library/MobileSubstrate/DynamicLibraries/Sub/Deep.dylib", dylib()),
                                 .file("./Library/MobileSubstrate/DynamicLibraries/Sub/Deep.plist", try filterPlist(["com.example.app"]))])
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        let p = try await analyze(src, into: storage)
        #expect(p.entries.isEmpty)
        #expect(p.binaries.count == 3)
    }

    @Test func aFilterPlistWithoutAFilterKeyGivesAnEmptyFilter() async throws {
        let empty = try PropertyListSerialization.data(fromPropertyList: ["Other": 1], format: .xml, options: 0)
        let src = try await deb([.file("./Library/MobileSubstrate/DynamicLibraries/Example.dylib", dylib()),
                                 .file("./Library/MobileSubstrate/DynamicLibraries/Example.plist", empty)])
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        let p = try await analyze(src, into: storage)
        // Not "everywhere": an empty filter targets nothing; the classifier decides.
        #expect(p.entries.map(\.filter) == [TweakFilter()])
    }

    @Test func providesIsRead() async throws {
        let src = try await deb([.file("./usr/lib/libexample.dylib", dylib(linking: []))])
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        let p = try await analyze(src, into: storage)
        #expect(p.provides == ["example-tweak"])
    }

    @Test func aDebWithoutMachOIsNothingUsable() async throws {
        let src = try await deb([.file("./Library/Application Support/Example/res.txt", Data("r".utf8))])
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        await #expect(throws: TweakError.nothingUsable) { try await analyze(src, into: storage) }
    }

    @Test func anUppercasePackageIDIsRefusedClearly() async throws {
        let src = try await deb([.file("./usr/lib/libexample.dylib", dylib(linking: []))],
                                control: "Package: com.Example.Tweak\nVersion: 1\n")
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        do {
            _ = try await analyze(src, into: storage)
            Issue.record("expected a throw")
        } catch let TweakError.unreadable(message) {
            #expect(message.contains("com.Example.Tweak") && message.contains("package id"))
        }
        #expect(contents(storage).isEmpty)
    }

    @Test func aTraversingDebIsRefused() async throws {
        let src = try await deb([.file("./usr/lib/../../../evil.dylib", dylib())])
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        await #expect(throws: TweakError.self) { try await analyze(src, into: storage) }
        #expect(contents(storage).isEmpty)
    }

    @Test func aDebWithBadMagicIsUnreadable() async throws {
        let src = scratch("src").appendingPathExtension("deb")
        try Data("not an archive".utf8).write(to: src)
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        await #expect(throws: TweakError.self) { try await analyze(src, into: storage) }
        #expect(contents(storage).isEmpty)
    }

    // MARK: dropped files and folders

    @Test func aLoneDylibIsAnEntryWithoutFilter() async throws {
        let src = scratch("src").appendingPathComponent("MyTweak.dylib")
        try FileManager.default.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try dylib().write(to: src)
        let storage = scratch("store")
        defer { cleanup(src.deletingLastPathComponent(), storage) }
        let p = try await analyze(src, into: storage)
        #expect(p.kind == .dylib)
        #expect(p.name == "MyTweak" && p.packageID == "mytweak" && p.version == nil)
        #expect(p.files == ["MyTweak.dylib"])
        #expect(p.entries.count == 1)
        #expect(p.entries[0].path == "MyTweak.dylib" && p.entries[0].filter == nil && p.entries[0].isEntry)
        #expect(TweakLayout.loadPath(p, p.entries[0]) == "@executable_path/Frameworks/XSideTweaks/\(p.id)/MyTweak.dylib")
    }

    @Test func aLoneFileThatIsNotMachOIsRefused() async throws {
        let src = scratch("src").appendingPathExtension("dylib")
        try Data("text".utf8).write(to: src)
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        await #expect(throws: TweakError.self) { try await analyze(src, into: storage) }
        #expect(contents(storage).isEmpty)
    }

    @Test func anUnknownExtensionIsUnsupported() async throws {
        let src = scratch("src").appendingPathExtension("zip")
        try dylib().write(to: src)
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        await #expect(throws: TweakError.unsupportedFile) { try await analyze(src, into: storage) }
    }

    private func framework(_ name: String, executable: String? = nil, extras: [String: Any] = [:]) throws -> URL {
        let fw = scratch("src").appendingPathComponent("\(name).framework")
        try FileManager.default.createDirectory(at: fw.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleExecutable": executable ?? name, "CFBundleIdentifier": "com.example.\(name)",
                                   "CFBundleShortVersionString": "3.1"]
        info.merge(extras) { _, n in n }
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: fw.appendingPathComponent("Info.plist"))
        try dylib(linking: []).write(to: fw.appendingPathComponent(name))
        try Data("res".utf8).write(to: fw.appendingPathComponent("Resources/a.txt"))
        return fw
    }

    @Test func aFrameworkFolderUsesItsExecutable() async throws {
        let fw = try framework("Example")
        let storage = scratch("store")
        defer { cleanup(fw.deletingLastPathComponent(), storage) }
        let p = try await analyze(fw, into: storage)
        #expect(p.kind == .framework && p.packageID == "com.example.example" && p.version == "3.1" && p.name == "Example")
        #expect(p.entries.map(\.path) == ["Example.framework/Example"])
        #expect(p.entries[0].filter == nil)
        #expect(p.files == ["Example.framework/Example", "Example.framework/Info.plist", "Example.framework/Resources/a.txt"])
        #expect(TweakLayout.directory(p) == p.id)
    }

    @Test func aFrameworkWhoseExecutableEscapesIsNothingUsable() async throws {
        let fw = try framework("Example", executable: "../Example")
        let storage = scratch("store")
        defer { cleanup(fw.deletingLastPathComponent(), storage) }
        await #expect(throws: TweakError.nothingUsable) { try await analyze(fw, into: storage) }
        #expect(contents(storage).isEmpty)
    }

    @Test func aBundleFolderHasNoEntry() async throws {
        let b = scratch("src").appendingPathComponent("Example.bundle")
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try Data("img".utf8).write(to: b.appendingPathComponent("icon.png"))
        let storage = scratch("store")
        defer { cleanup(b.deletingLastPathComponent(), storage) }
        let p = try await analyze(b, into: storage)
        #expect(p.kind == .bundle && p.entries.isEmpty && p.binaries.isEmpty)
        #expect(p.files == ["Example.bundle/icon.png"])
        #expect(contents(storage.appendingPathComponent(p.id)) == ["Example.bundle"])
    }

    @Test func aFolderWithASymlinkIsRefused() async throws {
        let fw = try framework("Example")
        try FileManager.default.createSymbolicLink(atPath: fw.appendingPathComponent("Resources/link").path,
                                                   withDestinationPath: "/etc/passwd")
        let storage = scratch("store")
        defer { cleanup(fw.deletingLastPathComponent(), storage) }
        await #expect(throws: TweakError.symlinkInFolder) { try await analyze(fw, into: storage) }
        #expect(contents(storage).isEmpty)
    }

    @Test func aFolderOverTheFileCapIsTooLarge() async throws {
        let b = scratch("src").appendingPathComponent("Many.bundle")
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        for i in 0..<5 { try Data("\(i)".utf8).write(to: b.appendingPathComponent("\(i).txt")) }
        let storage = scratch("store")
        defer { cleanup(b.deletingLastPathComponent(), storage) }
        var limits = TweakAnalyzer.Limits()
        limits.maxFolderFiles = 4
        await #expect(throws: TweakError.tooLarge) {
            try await TweakAnalyzer.analyze(b, into: storage, runner: ProcessRunner(), now: now, limits: limits)
        }
        limits = TweakAnalyzer.Limits()
        limits.maxFolderBytes = 3
        await #expect(throws: TweakError.tooLarge) {
            try await TweakAnalyzer.analyze(b, into: storage, runner: ProcessRunner(), now: now, limits: limits)
        }
        #expect(contents(storage).isEmpty)
    }

    // MARK: storage

    @Test func idIsStableForTheSameBytes() async throws {
        let src = try await deb([.file("./usr/lib/libexample.dylib", dylib(linking: []))])
        let other = try await deb([.file("./usr/lib/libexample.dylib", dylib(["x"], linking: []))])
        let fw = try framework("Example")
        let a = scratch("store"), b = scratch("store")
        defer { cleanup(src, other, fw.deletingLastPathComponent(), a, b) }
        let p1 = try await analyze(src, into: a)
        let p2 = try await analyze(src, into: b)
        let again = try await analyze(src, into: a)        // same bytes twice in one storage: one folder
        #expect(p1.id == p2.id && again.id == p1.id)
        #expect(contents(a) == [p1.id])
        #expect(try await analyze(other, into: a).id != p1.id)
        let f1 = try await analyze(fw, into: a), f2 = try await analyze(fw, into: b)
        #expect(f1.id == f2.id)
        try Data("changed".utf8).write(to: fw.appendingPathComponent("Resources/a.txt"))
        #expect(try await analyze(fw, into: b).id != f1.id)
    }

    @Test func armv7SlicesAreRemovedAtStorage() async throws {
        let fat = FakeIPA.fat([(armv7, 9, FakeIPA.machO(cpuType: armv7, cryptid: 0)), (arm64, 0, dylib())])
        let src = try await deb([.file("./Library/MobileSubstrate/DynamicLibraries/Example.dylib", fat),
                                 .file("./Library/MobileSubstrate/DynamicLibraries/Example.plist", try filterPlist(["com.example.app"]))])
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        let p = try await analyze(src, into: storage)
        #expect(p.entries[0].slices.map(\.arch) == ["arm64"])
        let stored = try Data(contentsOf: storage.appendingPathComponent("\(p.id)/\(p.entries[0].path)"))
        #expect(stored == dylib())
    }

    @Test func aFailedAnalysisLeavesNothing() async throws {
        let storage = scratch("store")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let src = try await deb([.file("./usr/share/doc/README", Data("r".utf8))])
        let fw = try framework("Example")
        try FileManager.default.createSymbolicLink(atPath: fw.appendingPathComponent("link").path, withDestinationPath: "Example")
        defer { cleanup(src, fw.deletingLastPathComponent(), storage) }
        await #expect(throws: TweakError.nothingUsable) { try await analyze(src, into: storage) }
        await #expect(throws: TweakError.symlinkInFolder) { try await analyze(fw, into: storage) }
        #expect(contents(storage).isEmpty)
    }

    @Test func aThrowAfterExtractionLeavesNothing() async throws {
        // Files are written by the extraction, then the control is refused.
        let src = try await deb([.file("./usr/lib/libexample.dylib", dylib(linking: [])),
                                 .file("./Library/Application Support/Example/res.txt", Data("r".utf8))],
                                control: "Version: 1\n")
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        await #expect(throws: TweakError.self) { try await analyze(src, into: storage) }
        #expect(contents(storage).isEmpty)
    }

    @Test func aCancelKeepsItsTypeAndLeavesNothing() async throws {
        let src = scratch("src").appendingPathExtension("deb")
        try await FakeDeb.deb(control: control, files: [.file("./usr/lib/libexample.dylib", dylib(linking: []))],
                              compression: "bz2").write(to: src)
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        await #expect(throws: CancellationError.self) {
            try await TweakAnalyzer.analyze(src, into: storage, runner: ThrowingRunner(failure: .cancelled), now: now)
        }
        #expect(contents(storage).isEmpty)
        do {
            _ = try await TweakAnalyzer.analyze(src, into: storage, runner: ThrowingRunner(failure: .timedOut), now: now)
            Issue.record("expected a throw")
        } catch XSideError.timedOut {
        }
        #expect(contents(storage).isEmpty)
    }

    @Test func aCancelledTaskStopsDroppedFilesAndFolders() async throws {
        let fw = try framework("Example")
        let lone = fw.deletingLastPathComponent().appendingPathComponent("Lone.dylib")
        try dylib().write(to: lone)
        let storage = scratch("store")
        defer { cleanup(fw.deletingLastPathComponent(), storage) }
        for source in [fw, lone] {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await TweakAnalyzer.analyze(source, into: storage, runner: ProcessRunner(), now: now)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(contents(storage).isEmpty)
    }

    @Test func aLoneDylibOverTheReadCapIsTooLarge() async throws {
        let src = scratch("src").appendingPathExtension("dylib")
        try dylib().write(to: src)
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        var limits = TweakAnalyzer.Limits()
        limits.maxFileBytes = 16
        await #expect(throws: TweakError.tooLarge) {
            try await TweakAnalyzer.analyze(src, into: storage, runner: ProcessRunner(), now: now, limits: limits)
        }
        #expect(contents(storage).isEmpty)
    }

    @Test func aMachOWithoutDylibExtensionAndAPlistIsAnEntry() async throws {
        let src = try await deb([.file("./Library/MobileSubstrate/DynamicLibraries/Example", dylib()),
                                 .file("./Library/MobileSubstrate/DynamicLibraries/Example.plist", try filterPlist(["com.example.app"]))])
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        let p = try await analyze(src, into: storage)
        #expect(p.entries.map(\.path) == ["Library/MobileSubstrate/DynamicLibraries/Example"])
        #expect(p.entries.map(\.imageName) == ["Example"])
    }

    @Test func finderFilesChangeNeitherTheIdNorTheCopy() async throws {
        let fw = try framework("Example")
        let a = scratch("store"), b = scratch("store")
        defer { cleanup(fw.deletingLastPathComponent(), a, b) }
        let before = try await analyze(fw, into: a)
        for junk in [".DS_Store", "._Example", "Icon\r", ".localized", "Resources/._a.txt"] {
            try Data("junk".utf8).write(to: fw.appendingPathComponent(junk))
        }
        try FileManager.default.createDirectory(at: fw.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: fw.appendingPathComponent("__MACOSX/x"))
        let after = try await analyze(fw, into: b)
        #expect(after.id == before.id && after.files == before.files)
        #expect(contents(b.appendingPathComponent("\(after.id)/Example.framework")) == ["Example", "Info.plist", "Resources"])
    }

    @Test func idsOfDifferentKindsDiffer() async throws {
        let dir = scratch("src")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lone = dir.appendingPathComponent("Same.dylib")
        try dylib().write(to: lone)
        let fw = dir.appendingPathComponent("Same.framework"), bundle = dir.appendingPathComponent("Same.bundle")
        for folder in [fw, bundle] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Same"], format: .xml, options: 0)
                .write(to: folder.appendingPathComponent("Info.plist"))
            try dylib().write(to: folder.appendingPathComponent("Same"))
        }
        let storage = scratch("store")
        defer { cleanup(dir, storage) }
        let ids = [try await analyze(lone, into: storage).id, try await analyze(fw, into: storage).id,
                   try await analyze(bundle, into: storage).id]
        #expect(Set(ids).count == 3)
    }

    @Test func anUnparseableMachOInAFolderIsDropped() async throws {
        let b = scratch("src").appendingPathComponent("Example.bundle")
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 52, 1, 2]).write(to: b.appendingPathComponent("Thing.class"))
        try Data("img".utf8).write(to: b.appendingPathComponent("icon.png"))
        let storage = scratch("store")
        defer { cleanup(b.deletingLastPathComponent(), storage) }
        let p = try await analyze(b, into: storage)
        #expect(p.files == ["Example.bundle/icon.png"] && p.binaries.isEmpty && p.notes == [.filesIgnored])
        #expect(contents(storage.appendingPathComponent("\(p.id)/Example.bundle")) == ["icon.png"])
    }

    @Test func theSameBytesKeepTheStoredFolderAndADamagedOneIsReplaced() async throws {
        let src = try await deb([.file("./usr/lib/libexample.dylib", dylib(linking: [])),
                                 .file("./usr/lib/res.txt", Data("r".utf8))])
        let storage = scratch("store")
        defer { cleanup(src, storage) }
        let p = try await analyze(src, into: storage)
        let folder = storage.appendingPathComponent(p.id)
        func inode() throws -> UInt64 {
            try #require(try FileManager.default.attributesOfItem(atPath: folder.path)[.systemFileNumber] as? UInt64)
        }
        let first = try inode()
        _ = try await analyze(src, into: storage)
        #expect(try inode() == first)                               // kept, never missing
        try FileManager.default.removeItem(at: folder.appendingPathComponent("usr/lib/res.txt"))
        _ = try await analyze(src, into: storage)
        #expect(try inode() != first)                               // damaged: stored again
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("usr/lib/res.txt").path))
        #expect(contents(storage) == [p.id])
    }

    @Test func jailbreakPathStringsAreNoted() async throws {
        for needle in ["/var/jb/", "/Library/MobileSubstrate/", "/Library/Application Support/", "/Library/PreferenceBundles/"] {
            let src = try await deb([.file("./usr/lib/libexample.dylib", dylib(["\(needle)thing"], linking: [])),
                                     .file("./usr/lib/libclean.dylib", dylib(["/private/thing"], linking: []))])
            let storage = scratch("store")
            defer { cleanup(src, storage) }
            let p = try await analyze(src, into: storage)
            #expect(p.binaries.map(\.imageName) == ["libclean.dylib", "libexample.dylib"])
            #expect(p.binaries.map(\.mentionsJailbreakPaths) == [false, true], "\(needle)")
        }
    }

    // MARK: layout

    @Test func layoutPaths() {
        let bin = TweakBinary(path: "Library/Frameworks/Cephei.framework/Cephei", isEntry: false, filter: nil, slices: [],
                              linked: [], mentionsJailbreakPaths: false, imageName: "Cephei")
        let embedded = TweakPackage(id: "0123456789abcdef", kind: .deb, origin: .embedded, packageID: "ws.hbang.common",
                                    name: "Cephei", files: [bin.path], binaries: [bin], addedAt: now)
        #expect(TweakLayout.directory(embedded) == "deps/ws.hbang.common")
        #expect(TweakLayout.loadPath(embedded, bin)
                == "@executable_path/Frameworks/XSideTweaks/deps/ws.hbang.common/Library/Frameworks/Cephei.framework/Cephei")
        var downloaded = embedded
        downloaded.origin = .downloaded(repo: "r", url: "u", sha256: "s")
        #expect(TweakLayout.directory(downloaded) == "0123456789abcdef")
        #expect(TweakLayout.elleKitLoadPath == "@executable_path/Frameworks/XSideTweaks/ElleKit.dylib")
        #expect(TweakLayout.supportLoadPath == "@executable_path/Frameworks/XSideTweaks/XSideTweakSupport.dylib")
        #expect(embedded.entries.isEmpty)
    }

    @Test func packageRoundTripsThroughJSON() throws {
        let bin = TweakBinary(path: "a.dylib", isEntry: true, filter: TweakFilter(bundles: ["x"]),
                              slices: [TweakSlice(arch: "arm64", platform: 2, minOS: "15.0")],
                              linked: ["/usr/lib/libobjc.A.dylib"], mentionsJailbreakPaths: true, imageName: "a.dylib")
        let p = TweakPackage(id: "0123456789abcdef", kind: .dylib, origin: .downloaded(repo: "r", url: "u", sha256: "s"),
                             packageID: "a", provides: ["b"], name: "A", version: "1", author: "J", architecture: "iphoneos-arm64",
                             depends: [[DebDependency(package: "firmware", relation: ">=", version: "15.0")]],
                             files: ["a.dylib"], binaries: [bin], notes: [.filesIgnored], addedAt: now)
        let data = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode(TweakPackage.self, from: data) == p)
    }
}

/// A runner whose every command is cancelled or times out.
private struct ThrowingRunner: CommandRunning {
    enum Failure: Sendable { case cancelled, timedOut }
    let failure: Failure
    func run(_ executable: String, _ arguments: [String], cwd: URL?, timeout: Duration) async throws -> CommandResult {
        switch failure {
        case .cancelled: throw CancellationError()
        case .timedOut: throw XSideError.timedOut(tool: "test")
        }
    }
}
