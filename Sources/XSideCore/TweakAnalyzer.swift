import Foundation
import CryptoKit
import Darwin

public enum TweakError: Error, Equatable {
    /// Not a `.deb`, `.dylib`, `.framework` folder or `.bundle` folder.
    case unsupportedFile
    /// Nothing XSide can use: no Mach-O in the `.deb`, no executable in the framework.
    case nothingUsable
    case symlinkInFolder
    case tooLarge
    /// The reason, in English, for the log (the app shows its own text).
    case unreadable(String)
}

/// Turns a `.deb`, `.dylib`, `.framework` or `.bundle` the person added (or XSide downloaded)
/// into a `TweakPackage` stored under `<storage>/<id>/`. Every source is untrusted: sizes and
/// counts are capped, links are never created or followed, and a failure leaves nothing behind.
public enum TweakAnalyzer {
    /// The `.deb` folders XSide copies; everything else is left out.
    public static let copiedPrefixes = ["Library/MobileSubstrate/DynamicLibraries/", "usr/lib/TweakInject/",
                                        "Library/Application Support/", "Library/Frameworks/", "usr/lib/"]
    static let settingsPrefixes = ["Library/PreferenceBundles/", "Library/PreferenceLoader/"]
    static let entryFolders = ["Library/MobileSubstrate/DynamicLibraries/", "usr/lib/TweakInject/"]
    /// Strings in a binary that show it looks for files where a jailbreak puts them.
    public static let jailbreakPathNeedles = ["/var/jb/", "/Library/MobileSubstrate/", "/Library/Application Support/",
                                              "/Library/PreferenceBundles/"]

    /// Caps for dropped files and folders (`.deb`s use `DebLimits`).
    struct Limits {
        var maxFolderFiles = DebLimits.maxEntries
        var maxFileBytes = DebLimits.maxFileBytes
        var maxFolderBytes = DebLimits.maxDataTarBytes
        var maxInfoPlistBytes = 1024 * 1024
    }

    /// A file or folder the analyzer takes (`.deb`/`.dylib` file, `.framework`/`.bundle` folder):
    /// what a drop on an app row accepts. Cheap: one `lstat`.
    public static func looksLikeTweak(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        switch (url.pathExtension.lowercased(), st.st_mode & S_IFMT) {
        case ("deb", S_IFREG), ("dylib", S_IFREG), ("framework", S_IFDIR), ("bundle", S_IFDIR): return true
        default: return false
        }
    }

    public static func analyze(_ source: URL, into storage: URL, origin: TweakOrigin = .added,
                               runner: CommandRunning, now: Date) async throws -> TweakPackage {
        try await analyze(source, into: storage, origin: origin, runner: runner, now: now, limits: Limits())
    }

    static func analyze(_ source: URL, into storage: URL, origin: TweakOrigin = .added,
                        runner: CommandRunning, now: Date, limits: Limits) async throws -> TweakPackage {
        let fm = FileManager.default
        var st = stat()
        guard lstat(source.path, &st) == 0 else { throw TweakError.unreadable("cannot read the source") }
        let type = st.st_mode & S_IFMT
        let kind: TweakKind
        switch (source.pathExtension.lowercased(), type) {
        case ("deb", S_IFREG): kind = .deb
        case ("dylib", S_IFREG): kind = .dylib
        case ("framework", S_IFDIR): kind = .framework
        case ("bundle", S_IFDIR): kind = .bundle
        default: throw TweakError.unsupportedFile
        }
        let name = source.lastPathComponent
        guard isSafeComponent(name) else { throw TweakError.unsupportedFile }

        do { try fm.createDirectory(at: storage, withIntermediateDirectories: true) } catch {
            throw TweakError.unreadable("cannot create the storage folder")
        }
        let incoming = storage.appendingPathComponent(".incoming-\(UUID().uuidString)")
        do {
            let package: TweakPackage
            switch kind {
            case .deb: package = try await analyzeDeb(source, into: incoming, origin: origin, runner: runner, now: now)
            case .dylib: package = try analyzeDylib(source, name: name, into: incoming, origin: origin, now: now, limits: limits)
            case .framework, .bundle:
                package = try analyzeFolder(source, name: name, kind: kind, into: incoming, origin: origin, now: now, limits: limits)
            }
            try install(incoming, at: storage.appendingPathComponent(package.id))
            return package
        } catch {
            try? fm.removeItem(at: incoming)
            // A cancel or a helper timeout is not a bad file: callers see it as it is.
            if error is CancellationError { throw error }
            if case XSideError.timedOut = error { throw error }
            throw mapped(error)
        }
    }

    // MARK: .deb

    /// What the `keep` filter saw and left out (it runs on DebReader's side).
    private final class Skipped: @unchecked Sendable {
        private let lock = NSLock()
        private var _settings = false, _other = false
        func note(_ path: String) {
            let settings = settingsPrefixes.contains { (path + "/").hasPrefix($0) }
            // The folders on the way to a copied prefix (`Library`, `usr`, a rootless `.deb`'s `var`
            // before `var/jb`) are not files left out.
            let onTheWay = path == "var" || copiedPrefixes.contains { $0.hasPrefix(path + "/") }
            lock.withLock {
                if settings { _settings = true } else if !onTheWay { _other = true }
            }
        }
        var flags: (settings: Bool, other: Bool) { lock.withLock { (_settings, _other) } }
    }

    private static func analyzeDeb(_ source: URL, into incoming: URL, origin: TweakOrigin, runner: CommandRunning,
                                   now: Date) async throws -> TweakPackage {
        let fm = FileManager.default
        // Hash and read the same bytes: a private copy, so the file can't change in between.
        let copy = fm.temporaryDirectory.appendingPathComponent("tweak-src-\(UUID().uuidString).deb")
        defer { try? fm.removeItem(at: copy) }
        let digest = try copyHashing(source, to: copy, maxBytes: DebLimits.maxDebBytes, domain: idDomain(.deb))

        let skipped = Skipped()
        let contents = try await DebReader.read(copy, into: incoming, runner: runner, keep: { path in
            let keep = copiedPrefixes.contains { path.hasPrefix($0) }
            if !keep { skipped.note(path) }
            return keep
        })
        let control: DebControl
        do { control = try DebControl.parse(contents.control) } catch DebError.malformed(let reason) {
            if let raw = try? DebControl.stanzas(contents.control, maxStanzas: 1).first?["package"],
               !raw.isEmpty, !DebControl.isValidPackageID(raw.lowercased()) {
                throw TweakError.unreadable("invalid package id \u{201C}\(raw.prefix(64))\u{201D}: only letters, digits, + - . are allowed")
            }
            throw TweakError.unreadable(reason)
        }

        var notes = Set<TweakNote>()
        let flags = skipped.flags
        if flags.settings { notes.insert(.settingsNotConverted) }
        if flags.other || contents.extraction.skippedOther > 0 { notes.insert(.filesIgnored) }
        if contents.extraction.skippedLinks > 0 { notes.insert(.linksSkipped) }

        let extracted = Set(contents.extraction.files)
        var files: [String] = []
        var binaries: [TweakBinary] = []
        for path in contents.extraction.files.sorted() {
            try Task.checkCancellation()
            let url = incoming.appendingPathComponent(path)
            guard isMachO(url) else { files.append(path); continue }
            let parts = path.split(separator: "/").map(String.init)
            let fileName = parts.last ?? path
            var filter: TweakFilter?
            if let folder = entryFolders.first(where: { path.hasPrefix($0) }), !path.dropFirst(folder.count).contains("/") {
                let base = fileName.hasSuffix(".dylib") ? String(fileName.dropLast(6)) : fileName
                let plist = folder + base + ".plist"
                // A filter plist that can't be read (or is too big) still makes an entry: one that
                // doesn't say where it loads (`noFilter`, overridable), never a silent library.
                if extracted.contains(plist) {
                    filter = readSmall(incoming.appendingPathComponent(plist), DebLimits.maxPlistBytes)
                        .flatMap(TweakFilter.parse) ?? TweakFilter()
                }
            }
            let inFramework = parts.dropLast().contains { $0.hasSuffix(".framework") }
            guard filter != nil || fileName.hasSuffix(".dylib") || inFramework,
                  let binary = store(url, path: path, isEntry: filter != nil, filter: filter) else {
                try? fm.removeItem(at: url)
                notes.insert(.filesIgnored)
                continue
            }
            files.append(path)
            binaries.append(binary)
        }
        guard !binaries.isEmpty else { throw TweakError.nothingUsable }
        pruneEmptyFolders(incoming)

        return TweakPackage(id: shortID(digest), kind: .deb, origin: origin, packageID: control.package,
                            provides: control.provides, name: control.name ?? control.package, version: control.version,
                            author: control.author, architecture: control.architecture, depends: control.depends,
                            files: files.sorted(), binaries: binaries,
                            notes: [TweakNote.settingsNotConverted, .filesIgnored, .linksSkipped].filter(notes.contains),
                            addedAt: now)
    }

    // MARK: dropped .dylib

    private static func analyzeDylib(_ source: URL, name: String, into incoming: URL, origin: TweakOrigin, now: Date,
                                     limits: Limits) throws -> TweakPackage {
        var data = Data()
        let digest = try readHashing(source, maxBytes: limits.maxFileBytes, domain: idDomain(.dylib)) {
            data.append(contentsOf: $0)
        }
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: false)
        let url = incoming.appendingPathComponent(name)
        try writeNew(data, to: url)
        guard isMachO(url), let binary = store(url, path: name, isEntry: true, filter: nil) else {
            throw TweakError.unreadable("not a Mach-O library")
        }
        let base = (name as NSString).deletingPathExtension
        return TweakPackage(id: shortID(digest), kind: .dylib, origin: origin, packageID: derivedPackageID(base),
                            name: base, files: [name], binaries: [binary], addedAt: now)
    }

    // MARK: dropped .framework / .bundle

    private struct FolderItem { let relative: String; let isDirectory: Bool }

    private static func analyzeFolder(_ source: URL, name: String, kind: TweakKind, into incoming: URL, origin: TweakOrigin,
                                      now: Date, limits: Limits) throws -> TweakPackage {
        let fm = FileManager.default
        let items = try listFolder(source, limits: limits)
        let top = incoming.appendingPathComponent(name)
        try fm.createDirectory(at: top, withIntermediateDirectories: true)
        var lines: [String] = []
        var files: [String] = []
        var total = 0
        for item in items {
            try Task.checkCancellation()
            let to = top.appendingPathComponent(item.relative)
            if item.isDirectory { try fm.createDirectory(at: to, withIntermediateDirectories: true); continue }
            var data = Data()
            let digest = try readHashing(source.appendingPathComponent(item.relative), maxBytes: limits.maxFileBytes) {
                data.append(contentsOf: $0)
            }
            let (sum, overflow) = total.addingReportingOverflow(data.count)
            guard !overflow, sum <= limits.maxFolderBytes else { throw TweakError.tooLarge }
            total = sum
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeNew(data, to: to)
            let path = name + "/" + item.relative
            lines.append(path + "\0" + hex(digest))
            files.append(path)
        }
        let id = shortID(Data(SHA256.hash(data: Data((idDomain(kind) + lines.sorted().map { $0 + "\n" }.joined()).utf8))))

        let info = readSmall(top.appendingPathComponent("Info.plist"), limits.maxInfoPlistBytes)
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any] } ?? [:]
        let executable = (kind == .framework ? info["CFBundleExecutable"] as? String : nil)
            .flatMap { isSafeComponent($0) ? name + "/" + $0 : nil }
        var binaries: [TweakBinary] = []
        var kept: [String] = []
        var notes: [TweakNote] = []
        for path in files.sorted() {
            try Task.checkCancellation()
            let url = incoming.appendingPathComponent(path)
            guard isMachO(url) else { kept.append(path); continue }
            guard let binary = store(url, path: path, isEntry: path == executable, filter: nil) else {
                // Mach-O magic that doesn't parse (a truncated file, a Java class): never copied into an app.
                try? fm.removeItem(at: url)
                if notes.isEmpty { notes.append(.filesIgnored) }
                continue
            }
            kept.append(path)
            binaries.append(binary)
        }
        if kind == .framework, !binaries.contains(where: \.isEntry) { throw TweakError.nothingUsable }

        let base = (name as NSString).deletingPathExtension
        let bundleID = (info["CFBundleIdentifier"] as? String)?.lowercased()
        let packageID = bundleID.flatMap { DebControl.isValidPackageID($0) ? $0 : nil } ?? derivedPackageID(base)
        let displayName = (info["CFBundleName"] as? String).flatMap { clean($0) } ?? base
        let version = ((info["CFBundleShortVersionString"] ?? info["CFBundleVersion"]) as? String).flatMap { clean($0) }
        return TweakPackage(id: id, kind: kind, origin: origin, packageID: packageID, name: displayName, version: version,
                            files: kept, binaries: binaries, notes: notes, addedAt: now)
    }

    /// Every file and folder under `root`, parents first. Links anywhere refuse the folder.
    private static func listFolder(_ root: URL, limits: Limits) throws -> [FolderItem] {
        var out: [FolderItem] = []
        var count = 0, total = 0
        func walk(_ relative: String, depth: Int) throws {
            guard depth <= DebLimits.maxPathDepth else { throw TweakError.tooLarge }
            let dir = relative.isEmpty ? root : root.appendingPathComponent(relative)
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: dir.path) } catch {
                throw TweakError.unreadable("cannot list a folder")
            }
            for name in names.sorted() where !isFinderJunk(name) {
                count += 1
                guard count <= limits.maxFolderFiles else { throw TweakError.tooLarge }
                guard isSafeComponent(name) else { throw TweakError.unreadable("unusable file name") }
                let path = relative.isEmpty ? name : relative + "/" + name
                guard path.utf8.count <= DebLimits.maxPathBytes else { throw TweakError.tooLarge }
                var st = stat()
                guard lstat(root.appendingPathComponent(path).path, &st) == 0 else { throw TweakError.unreadable("cannot read a file") }
                switch st.st_mode & S_IFMT {
                case S_IFLNK: throw TweakError.symlinkInFolder
                case S_IFDIR:
                    out.append(FolderItem(relative: path, isDirectory: true))
                    try walk(path, depth: depth + 1)
                case S_IFREG:
                    guard st.st_size <= off_t(limits.maxFileBytes) else { throw TweakError.tooLarge }
                    let (sum, overflow) = total.addingReportingOverflow(Int(st.st_size))
                    guard !overflow, sum <= limits.maxFolderBytes else { throw TweakError.tooLarge }
                    total = sum
                    out.append(FolderItem(relative: path, isDirectory: false))
                default:
                    throw TweakError.unreadable("not a regular file")
                }
            }
        }
        try walk("", depth: 1)
        return out
    }

    // MARK: Mach-O

    /// Thins the stored file of its 32-bit ARM slices and reads its facts; nil when it isn't a
    /// readable Mach-O.
    private static func store(_ url: URL, path: String, isEntry: Bool, filter: TweakFilter?) -> TweakBinary? {
        if let data = try? Data(contentsOf: url), let thinned = MachOThinner.removingARM32(from: data) {
            guard (try? thinned.write(to: url, options: .atomic)) != nil else { return nil }
        }
        guard let slices = try? MachOBuildInfo.slices(of: url), !slices.isEmpty,
              let linked = try? MachOPatcher.linkedDylibs(in: url) else { return nil }
        _ = chmod(url.path, 0o755)
        return TweakBinary(path: path, isEntry: isEntry, filter: filter,
                           slices: slices.map { TweakSlice(arch: archName($0), platform: $0.platform, minOS: $0.minOS) },
                           linked: linked,
                           mentionsJailbreakPaths: MachOPatcher.containsAny(jailbreakPathNeedles, in: url),
                           imageName: url.lastPathComponent,
                           cFunctionHooks: MachOImports.cFunctionHooks(in: url))
    }

    static func archName(_ s: MachOBuildInfo.Slice) -> String {
        if let name = s.archName { return name }
        switch (s.cpuType, s.cpuSubtype & 0xFF) {
        case (12, 9): return "armv7"
        case (12, 11): return "armv7s"
        case (12, _): return "arm"
        case (0x0200_000C, _): return "arm64_32"
        case (7, _): return "i386"
        default: return "cpu\(s.cpuType)"
        }
    }

    private static func isMachO(_ url: URL) -> Bool {
        guard let head = readSmall(url, 4, prefixOnly: true), head.count == 4 else { return false }
        let v = head.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return [0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE, 0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA].contains(v)
    }

    // MARK: files

    /// Reads a regular file (never following a link, never blocking on a FIFO), at most
    /// `maxBytes`, handing each chunk to `sink`; returns its SHA-256.
    private static func readHashing(_ url: URL, maxBytes: Int, domain: String = "",
                                    _ sink: (UnsafeRawBufferPointer) throws -> Void) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP { throw TweakError.symlinkInFolder }
            throw TweakError.unreadable("cannot open a file")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw TweakError.unreadable("not a regular file") }
        guard st.st_size <= off_t(maxBytes) else { throw TweakError.tooLarge }
        var hasher = SHA256()
        hasher.update(data: Data(domain.utf8))
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var total = 0
        while true {
            try Task.checkCancellation()                                  // per MiB read
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { throw TweakError.unreadable("cannot read a file") }
            if n == 0 { break }
            total += n
            guard total <= maxBytes else { throw TweakError.tooLarge }      // it grew while read
            try buffer.withUnsafeBytes { raw in
                let chunk = UnsafeRawBufferPointer(rebasing: raw[0..<n])
                hasher.update(bufferPointer: chunk)
                try sink(chunk)
            }
        }
        return Data(hasher.finalize())
    }

    private static func copyHashing(_ source: URL, to destination: URL, maxBytes: Int, domain: String) throws -> Data {
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TweakError.unreadable("cannot create a temporary file") }
        defer { close(fd) }
        return try readHashing(source, maxBytes: maxBytes, domain: domain) { chunk in
            var done = 0
            while done < chunk.count {
                let n = write(fd, chunk.baseAddress! + done, chunk.count - done)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw TweakError.unreadable("cannot write a temporary file") }
                done += n
            }
        }
    }

    /// A file of XSide's own staging folder, at most `max` bytes (nil when bigger, unless
    /// `prefixOnly`, which reads the first `max`).
    private static func readSmall(_ url: URL, _ max: Int, prefixOnly: Bool = false) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: prefixOnly ? max : max + 1) else { return Data() }
        return prefixOnly || data.count <= max ? data : nil
    }

    private static func writeNew(_ data: Data, to url: URL) throws {
        do { try data.write(to: url, options: .withoutOverwriting) } catch {
            throw TweakError.unreadable("cannot store a file")
        }
    }

    private static func pruneEmptyFolders(_ root: URL) {
        let fm = FileManager.default
        func prune(_ dir: URL) -> Bool {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
            var empty = true
            for name in names {
                let url = dir.appendingPathComponent(name)
                var st = stat()
                if lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, prune(url) {
                    try? fm.removeItem(at: url)
                } else {
                    empty = false
                }
            }
            return empty
        }
        _ = prune(root)
    }

    /// Renames the finished folder into place. The id comes from the content, so a folder already
    /// stored under it with the same files is kept as is (no window where it is missing) and the
    /// new copy goes; a damaged one (files removed or changed) is replaced.
    private static func install(_ incoming: URL, at destination: URL) throws {
        let fm = FileManager.default
        var st = stat()
        if lstat(destination.path, &st) == 0 {
            if sameTree(incoming, destination) { try? fm.removeItem(at: incoming); return }
            let stale = destination.deletingLastPathComponent().appendingPathComponent(".stale-\(UUID().uuidString)")
            do { try fm.moveItem(at: destination, to: stale) } catch { throw TweakError.unreadable("cannot replace the stored package") }
            defer { try? fm.removeItem(at: stale) }
            do { try fm.moveItem(at: incoming, to: destination) } catch {
                if lstat(destination.path, &st) != 0 { try? fm.moveItem(at: stale, to: destination) }
                throw TweakError.unreadable("cannot store the package")
            }
            return
        }
        do { try fm.moveItem(at: incoming, to: destination) } catch {
            // Another analysis of the same bytes got there first.
            if sameTree(incoming, destination) { try? fm.removeItem(at: incoming); return }
            throw TweakError.unreadable("cannot store the package")
        }
    }

    /// Same relative paths, kinds and bytes, links never followed (a link anywhere: not the same).
    static func sameTree(_ a: URL, _ b: URL) -> Bool {
        func list(_ root: URL) -> [String: (isDir: Bool, size: off_t)]? {
            var out: [String: (isDir: Bool, size: off_t)] = [:]
            func walk(_ rel: String, depth: Int) -> Bool {
                guard depth <= DebLimits.maxPathDepth + 2, out.count <= DebLimits.maxEntries + 1,
                      let names = try? FileManager.default.contentsOfDirectory(atPath: (rel.isEmpty ? root : root.appendingPathComponent(rel)).path)
                else { return false }
                for name in names {
                    let path = rel.isEmpty ? name : rel + "/" + name
                    var st = stat()
                    guard lstat(root.appendingPathComponent(path).path, &st) == 0 else { return false }
                    switch st.st_mode & S_IFMT {
                    case S_IFDIR: out[path] = (true, 0); if !walk(path, depth: depth + 1) { return false }
                    case S_IFREG: out[path] = (false, st.st_size)
                    default: return false
                    }
                }
                return true
            }
            return walk("", depth: 0) ? out : nil
        }
        guard let left = list(a), let right = list(b), left.count == right.count else { return false }
        for (path, l) in left {
            guard let r = right[path], r.isDir == l.isDir, r.size == l.size else { return false }
            if l.isDir { continue }
            guard let x = FileHandle(forReadingAtPath: a.appendingPathComponent(path).path),
                  let y = FileHandle(forReadingAtPath: b.appendingPathComponent(path).path) else { return false }
            defer { try? x.close(); try? y.close() }
            while true {
                let cx = (try? x.read(upToCount: 1 << 20)) ?? Data(), cy = (try? y.read(upToCount: 1 << 20)) ?? Data()
                guard cx == cy else { return false }
                if cx.isEmpty { break }
            }
        }
        return true
    }

    // MARK: names

    /// Files Finder and other macOS tools add to folders: never hashed, never copied.
    static func isFinderJunk(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == "__MACOSX" || name == "Icon\r" || name == ".localized"
    }

    /// Hashed before the content, so two kinds never share an id.
    private static func idDomain(_ kind: TweakKind) -> String {
        switch kind {
        case .deb: "deb-"
        case .dylib: "dylib-"
        case .framework: "fw-"
        case .bundle: "bundle-"
        }
    }

    private static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
            && name.utf8.count <= 255
    }

    /// A Debian-style package id from a file name: lowercase, other characters become `-`.
    static func derivedPackageID(_ base: String) -> String {
        var out = ""
        for u in base.lowercased().unicodeScalars {
            if out.utf8.count >= ControlLimits.maxPackageIDBytes { break }
            let ok = (u >= "a" && u <= "z") || (u >= "0" && u <= "9") || u == "+" || u == "-" || u == "."
            out.unicodeScalars.append(ok ? u : "-")
        }
        while let first = out.first, !(first.isASCII && (first.isLetter || first.isNumber)) { out.removeFirst() }
        return DebControl.isValidPackageID(out) ? out : "tweak"
    }

    /// Control and format characters removed, capped; nil when nothing is left.
    private static func clean(_ s: String) -> String? {
        let kept = String(String.UnicodeScalarView(s.unicodeScalars.filter {
            !$0.properties.generalCategory.isControlOrFormat
        }).prefix(256)).trimmingCharacters(in: .whitespaces)
        return kept.isEmpty ? nil : kept
    }

    private static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    private static func shortID(_ digest: Data) -> String { String(hex(digest).prefix(16)) }

    private static func mapped(_ error: Error) -> TweakError {
        if let e = error as? TweakError { return e }
        if let e = error as? DebError {
            switch e {
            case .tooLarge: return .tooLarge
            case .notADeb: return .unreadable("not a .deb archive")
            case .malformed(let m): return .unreadable(String(m.prefix(200)))
            case .unsupportedCompression(let c): return .unreadable("unsupported compression: \(c.prefix(32))")
            }
        }
        return .unreadable(String(String(describing: error).prefix(200)))
    }
}

private extension Unicode.GeneralCategory {
    var isControlOrFormat: Bool {
        switch self {
        case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: true
        default: false
        }
    }
}
