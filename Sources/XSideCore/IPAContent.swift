import Foundation

/// What an IPA holds besides the app as its developer built it, read at import from the IPA as
/// given (before XSide changes anything): the libraries someone added (tweaks, their hooking
/// libraries, anything unknown), warning signs in them, and the accesses the app can ask for.
/// Heuristics, never a verdict: nothing here blocks an install.
public struct IPAContent: Codable, Equatable, Sendable {
    /// Bumped when the rules change: an older stored result is read again from the kept IPA.
    public static let currentVersion = 1

    public var version: Int
    public var additions: [IPAAddition]
    public var accesses: [AppAccess]

    public init(additions: [IPAAddition], accesses: [AppAccess], version: Int = IPAContent.currentVersion) {
        self.version = version
        self.additions = additions
        self.accesses = accesses
    }

    /// Read with the current rules.
    public var isCurrent: Bool { version == Self.currentVersion }

    /// The additions that are tweaks or unknown (the count shown), apart from the hooking libraries.
    public var counted: [IPAAddition] { additions.filter { $0.kind != .tweakLibrary } }

    enum CodingKeys: String, CodingKey { case version, additions, accesses }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 0
        additions = try c.decode([Lossy<IPAAddition>].self, forKey: .additions).compactMap(\.value)
        accesses = try c.decode([Lossy<AppAccess>].self, forKey: .accesses).compactMap(\.value)
    }
}

public struct IPAAddition: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Hooks the app (Substrate, ElleKit, a jailbreak path, runtime method swaps).
        case tweak
        /// A library tweaks use to hook the app (CydiaSubstrate, ElleKit, Cephei…).
        case tweakLibrary
        case unknown
    }

    public enum Load: String, Codable, Sendable {
        /// The main executable loads it (`LC_LOAD_DYLIB`).
        case launch
        /// The main executable loads it if present (`LC_LOAD_WEAK_DYLIB`).
        case weak
        /// Another library of the app loads it (`loadedBy`).
        case indirect
    }

    public var id: String { path }
    /// From its bundle's Info.plist, else its file name (without `.dylib` for a tweak).
    public var name: String
    /// Path inside the `.app`.
    public var path: String
    public var size: Int64
    public var load: Load
    /// The library that loads it, for `.indirect`.
    public var loadedBy: String?
    public var kind: Kind
    /// An Info.plist (its own bundle's, or a `<name>.bundle` beside it) names it.
    public var hasMetadata: Bool
    public var signs: [WarningSign]

    public init(name: String, path: String, size: Int64, load: Load, loadedBy: String? = nil, kind: Kind,
                hasMetadata: Bool, signs: [WarningSign] = []) {
        self.name = name
        self.path = path
        self.size = size
        self.load = load
        self.loadedBy = loadedBy
        self.kind = kind
        self.hasMetadata = hasMetadata
        self.signs = signs
    }

    enum CodingKeys: String, CodingKey { case name, path, size, load, loadedBy, kind, hasMetadata, signs }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        size = (try? c.decode(Int64.self, forKey: .size)) ?? 0
        load = (try? c.decode(Load.self, forKey: .load)) ?? .launch
        loadedBy = try? c.decodeIfPresent(String.self, forKey: .loadedBy)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .unknown
        hasMetadata = (try? c.decode(Bool.self, forKey: .hasMetadata)) ?? false
        signs = ((try? c.decode([Lossy<WarningSign>].self, forKey: .signs)) ?? []).compactMap(\.value)
    }
}

/// Something in an addition that deserves attention: a strong hint, never proof.
public enum WarningSign: String, Codable, Sendable, CaseIterable {
    /// A Discord webhook address (discord.com/api/webhooks, discordapp.com/api/webhooks).
    case discordWebhook
    /// A Telegram bot address (api.telegram.org/bot).
    case telegramBot
    /// A raw paste address (pastebin.com/raw, hastebin).
    case pasteSite
    /// A tunnel or request catcher (ngrok, webhook.site, requestbin).
    case tunnel
    /// A URL to a public IP address with a port.
    case rawIP
    /// Reads the keychain (SecItemCopyMatching, SecItemExport).
    case keychain
    /// Watches the pasteboard (UIPasteboard generalPasteboard + changeCount).
    case pasteboard
    /// Reads every cookie (NSHTTPCookieStorage sharedHTTPCookieStorage + cookies).
    case cookies
    /// Downloads code and loads it (dlopen or NSBundle loading, with a download and Documents).
    case remoteCode

    public var isEndpoint: Bool { [.discordWebhook, .telegramBot, .pasteSite, .tunnel, .rawIP].contains(self) }
}

/// What the app can ask iOS for, from its Info.plist and entitlements. In display order.
public enum AppAccess: String, Codable, Sendable, CaseIterable {
    case notifications, camera, microphone, photos, location, contacts, calendars, reminders, bluetooth,
         localNetwork, motion, health, homeKit, mediaLibrary, speech, faceID, tracking, nfc, siri

    /// Usage keys per access (any one with a non-empty text).
    static let usageKeys: [AppAccess: [String]] = [
        .camera: ["NSCameraUsageDescription"],
        .microphone: ["NSMicrophoneUsageDescription"],
        .photos: ["NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription"],
        .location: ["NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription",
                    "NSLocationAlwaysUsageDescription", "NSLocationUsageDescription"],
        .contacts: ["NSContactsUsageDescription"],
        .calendars: ["NSCalendarsUsageDescription", "NSCalendarsFullAccessUsageDescription",
                     "NSCalendarsWriteOnlyAccessUsageDescription"],
        .reminders: ["NSRemindersUsageDescription", "NSRemindersFullAccessUsageDescription"],
        .bluetooth: ["NSBluetoothAlwaysUsageDescription", "NSBluetoothPeripheralUsageDescription"],
        .localNetwork: ["NSLocalNetworkUsageDescription"],
        .motion: ["NSMotionUsageDescription"],
        .health: ["NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription"],
        .homeKit: ["NSHomeKitUsageDescription"],
        .mediaLibrary: ["NSAppleMusicUsageDescription"],
        .speech: ["NSSpeechRecognitionUsageDescription"],
        .faceID: ["NSFaceIDUsageDescription"],
        .tracking: ["NSUserTrackingUsageDescription"],
        .nfc: ["NFCReaderUsageDescription"],
        .siri: ["NSSiriUsageDescription"],
    ]

    public static func read(plist: [String: Any], entitlements: [String: Any]?) -> [AppAccess] {
        func text(_ key: String) -> Bool { (plist[key] as? String).map { !$0.isEmpty } ?? false }
        return allCases.filter { access in
            switch access {
            case .notifications:
                return (entitlements?["aps-environment"] as? String).map { !$0.isEmpty } ?? false
            case .localNetwork:
                if let services = plist["NSBonjourServices"] as? [Any], !services.isEmpty { return true }
                fallthrough
            default:
                return usageKeys[access, default: []].contains(where: text)
            }
        }
    }
}

/// Reads an extracted `.app` for `IPAContent`. Untrusted input: nothing outside the bundle is
/// read (paths and symlinks resolved first), every Mach-O offset is checked, and sizes, counts
/// and bytes read are capped.
public enum IPAContentScanner {
    /// Libraries visited along the load commands, at most.
    static let maxVisited = 512
    /// Additions kept, at most.
    public static let maxAdditions = 64
    /// A Mach-O larger than this isn't opened.
    static let maxMachOBytes: Int64 = 512 * 1024 * 1024
    /// Bytes searched for strings in one addition, and in all of them.
    static let maxScanBytes = 128 * 1024 * 1024
    static let maxTotalScanBytes = 512 * 1024 * 1024
    static let maxNameBytes = 1024

    public static func scan(app: URL, executable: String, plist: [String: Any], entitlements: [String: Any]?) -> IPAContent {
        IPAContent(additions: additions(app: app, executable: executable),
                   accesses: AppAccess.read(plist: plist, entitlements: entitlements))
    }

    // MARK: additions

    private struct Node {
        let url: URL
        let relative: String
        let load: IPAAddition.Load
        let loader: String?   // relative path of the library that loads it
    }

    static func additions(app: URL, executable: String) -> [IPAAddition] {
        let root = app.resolvingSymlinksInPath().standardizedFileURL.path
        guard let main = inside(root, root + "/" + executable),
              let mainData = machO(main.url) else { return [] }
        let mainTeam = IPAInspector.codeSigningTeamID(mainData)
        let mainRpaths = rpaths(mainData)

        var visited = Set<String>([main.relative])
        var queue: [(node: Node, data: Data)] = []
        var order: [(node: Node, data: Data)] = []
        func enqueue(from loader: URL, loaderRelative: String?, data: Data, rpathsOfLoader: [String]) {
            for (name, weak) in loads(data) {
                guard visited.count < maxVisited else { return }
                guard let target = resolve(name, loader: loader, rpaths: rpathsOfLoader + mainRpaths,
                                           executableDir: root, root: root),
                      !visited.contains(target.relative) else { continue }
                visited.insert(target.relative)
                guard let targetData = machO(target.url) else { continue }
                let load: IPAAddition.Load = loaderRelative != nil ? .indirect : (weak ? .weak : .launch)
                let node = Node(url: target.url, relative: target.relative, load: load, loader: loaderRelative)
                queue.append((node, targetData))
            }
        }
        enqueue(from: main.url, loaderRelative: nil, data: mainData, rpathsOfLoader: [])
        var index = 0
        while index < queue.count {
            let item = queue[index]
            index += 1
            order.append(item)
            enqueue(from: item.node.url, loaderRelative: item.node.relative, data: item.data, rpathsOfLoader: rpaths(item.data))
        }

        var found: [IPAAddition] = []
        var names: [String: String] = [:]     // relative path -> display name, for "loaded by"
        var scanned = 0
        for (node, data) in order {
            let file = node.url.lastPathComponent
            let folder = frameworkFolder(node.relative)
            let library = tweakLibraryName(node.relative)
            let looseDylib = folder == nil && file.lowercased().hasSuffix(".dylib")
            let team = IPAInspector.codeSigningTeamID(data)
            let otherTeam = mainTeam != nil && team != mainTeam
            // A tweak library, or a library signed by another team than the app, is an addition.
            // An unsigned/ad-hoc IPA (mainTeam nil) has no origin to trust, so every loose dylib is
            // listed (libswift* included — a name proves nothing). A loose dylib signed by the app's
            // own team could still be a disguised payload (a repackager re-signs it), so it isn't
            // trusted on its team alone: it is scanned, and promoted to an addition only if it shows
            // a warning sign. Additions never block, so listing one costs nothing.
            let definite = library != nil || otherTeam || (looseDylib && mainTeam == nil)
            let short = folder.map { String($0.dropLast(".framework".count)) } ?? baseName(file)
            guard definite || looseDylib, found.count < maxAdditions else { names[node.relative] = short; continue }

            let budget = min(maxScanBytes, max(0, maxTotalScanBytes - scanned))
            let text = data.prefix(budget)
            scanned += text.count
            let imports = MachOImports.importedSymbols(in: data, wanted: wantedImports)
            let kind: IPAAddition.Kind = library != nil ? .tweakLibrary
                : (hooks(data, text: text, imports: imports) ? .tweak : .unknown)
            let itsSigns = signs(text: text, imports: imports, kind: kind)
            // A same-team loose dylib with nothing suspicious is a plain bundled library, not an addition.
            guard definite || !itsSigns.isEmpty else { names[node.relative] = short; continue }

            let metadata = self.metadata(node.url, folder: folder, root: root)
            let name = library ?? metadata
                ?? (folder != nil || kind == .tweak ? short : file)
            names[node.relative] = name
            let size = (try? FileManager.default.attributesOfItem(atPath: node.url.path)[.size] as? NSNumber)?.int64Value
                ?? Int64(data.count)
            found.append(IPAAddition(name: name, path: node.relative, size: size, load: node.load,
                                     loadedBy: node.loader, kind: kind, hasMetadata: metadata != nil,
                                     signs: itsSigns))
        }
        for i in found.indices {
            if let loader = found[i].loadedBy { found[i].loadedBy = names[loader] ?? loader }
        }
        return found
    }

    /// `path` (absolute) when it is a regular file inside `root` once `..` and symlinks are
    /// resolved, with its path relative to `root`.
    static func inside(_ root: String, _ path: String) -> (url: URL, relative: String)? {
        guard path.utf8.count <= 4096, !path.utf8.contains(0) else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let resolved = url.path
        guard resolved.hasPrefix(root + "/") else { return nil }
        var st = stat()
        guard lstat(resolved, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return (url, String(resolved.dropFirst(root.count + 1)))
    }

    /// The Mach-O bytes (mapped) when the file is one and isn't too large.
    private static func machO(_ url: URL) -> Data? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
              size >= 32, size <= maxMachOBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let starts = try? IPAInspector.sliceOffsets(data),
              starts.contains(where: { (try? MachOPatcher.loadCommands(data, at: $0)) != nil }) else { return nil }
        return data
    }

    /// The libraries each 64-bit slice loads, in order, each once; weak only when no slice loads
    /// it strongly.
    private static func loads(_ data: Data) -> [(String, Bool)] {
        var result: [(String, Bool)] = []
        var position: [String: Int] = [:]
        for start in (try? IPAInspector.sliceOffsets(data)) ?? [] {
            guard let commands = try? MachOPatcher.loadCommands(data, at: start) else { continue }
            for c in commands where ICloudSignedOut.dylibCommands.contains(c.cmd) {
                guard let name = MachOPatcher.dylibName(data, c), name.utf8.count <= maxNameBytes else { continue }
                let weak = c.cmd == MachOPatcher.loadWeakDylib
                if let at = position[name] {
                    if !weak { result[at].1 = false }
                } else {
                    position[name] = result.count
                    result.append((name, weak))
                }
            }
        }
        return result
    }

    /// `LC_RPATH` entries of every 64-bit slice.
    private static func rpaths(_ data: Data) -> [String] {
        var result: [String] = []
        for start in Set((try? IPAInspector.sliceOffsets(data)) ?? []) {
            guard let commands = try? MachOPatcher.loadCommands(data, at: start) else { continue }
            for c in commands where c.cmd == MachOPatcher.rpath && c.size >= 12 {
                let offset = Int(MachOPatcher.u32(data, c.pos + 8))
                guard offset >= 12, offset < c.size else { continue }
                let bytes = data[(c.pos + offset)..<(c.pos + c.size)]
                guard let nul = bytes.firstIndex(of: 0), nul - (c.pos + offset) <= maxNameBytes else { continue }
                let path = String(decoding: bytes[..<nul], as: UTF8.self)
                if !result.contains(path) && result.count < 16 { result.append(path) }
            }
        }
        return result
    }

    /// Where dyld would find `name` inside the bundle (nil for iOS's libraries and anything outside).
    private static func resolve(_ name: String, loader: URL, rpaths: [String], executableDir: String,
                                root: String) -> (url: URL, relative: String)? {
        let loaderDir = loader.deletingLastPathComponent().path
        func expand(_ path: String) -> String? {
            if path.hasPrefix("@executable_path/") { return executableDir + "/" + path.dropFirst("@executable_path/".count) }
            if path.hasPrefix("@loader_path/") { return loaderDir + "/" + path.dropFirst("@loader_path/".count) }
            if path == "@executable_path" { return executableDir }
            if path == "@loader_path" { return loaderDir }
            return nil  // absolute paths are outside the bundle on the device
        }
        if name.hasPrefix("@rpath/") {
            let rest = name.dropFirst("@rpath/".count)
            for rpath in rpaths + ["@executable_path/Frameworks"] {
                guard let base = expand(rpath) else { continue }
                if let hit = inside(root, base + "/" + rest) { return hit }
            }
            return nil
        }
        return expand(name).flatMap { inside(root, $0) }
    }

    /// `X.framework` when `relative` is inside one.
    private static func frameworkFolder(_ relative: String) -> String? {
        relative.split(separator: "/").dropLast().last { $0.lowercased().hasSuffix(".framework") }.map(String.init)
    }

    private static func baseName(_ file: String) -> String {
        file.lowercased().hasSuffix(".dylib") ? String(file.dropLast(".dylib".count)) : file
    }

    /// Libraries tweaks use, by path inside the bundle (lowercased match): their name.
    static func tweakLibraryName(_ relative: String) -> String? {
        let lower = relative.lowercased()
        let file = lower.split(separator: "/").last.map(String.init) ?? lower
        let folder = frameworkFolder(lower).map { String($0.dropLast(".framework".count)) }
        switch folder ?? file {
        case "cydiasubstrate", "libsubstrate.dylib", "substrate": return "CydiaSubstrate"
        case "ellekit", "libellekit.dylib", "ellekit.dylib": return "ElleKit"
        case "substitute", "libsubstitute.dylib", "libsubstitute.0.dylib": return "Substitute"
        case "libhooker", "libhooker.dylib": return "libhooker"
        case "cephei", "cepheiprefs", "cepheiui": return "Cephei"
        case "orion", "liborion.dylib": return "Orion"
        case "altlist": return "AltList"
        case "libroot.dylib": return "libroot"
        case "libgcuniversal", "libgcuniversal.dylib": return "libGCUniversal"
        case "librocketbootstrap.dylib", "rocketbootstrap": return "RocketBootstrap"
        default: return nil
        }
    }

    /// The name an Info.plist gives it: its framework's, or a `<name>.bundle` beside a dylib.
    private static func metadata(_ url: URL, folder: String?, root: String) -> String? {
        let plistPath: String
        if folder != nil {
            plistPath = url.deletingLastPathComponent().appendingPathComponent("Info.plist").path
        } else {
            let base = baseName(url.lastPathComponent)
            plistPath = url.deletingLastPathComponent().appendingPathComponent("\(base).bundle/Info.plist").path
        }
        guard let file = inside(root, plistPath),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber)?.intValue,
              size <= IPAInspector.maxInfoPlistBytes, let data = try? Data(contentsOf: file.url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        for key in ["CFBundleDisplayName", "CFBundleName", "CFBundleIdentifier"] {
            if let value = plist[key] as? String {
                let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty, clean.count <= 80, !clean.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                    return clean
                }
            }
        }
        return nil
    }

    // MARK: kind and signs

    static let hookImports: Set<String> = [
        "_MSHookMessageEx", "_MSHookFunction", "_MSHookIvar", "_LHHookFunctions", "_LBHookMessage",
        "_substitute_hook_functions", "_substitute_hook_objc_message", "_method_setImplementation",
        "_method_exchangeImplementations", "_class_replaceMethod",
    ]
    static let keychainImports: Set<String> = ["_SecItemCopyMatching", "_SecItemExport"]
    static let wantedImports: Set<String> = hookImports.union(keychainImports).union([
        "_dlopen", "_OBJC_CLASS_$_UIPasteboard", "_OBJC_CLASS_$_NSHTTPCookieStorage",
    ])

    private static func contains(_ text: Data, _ needle: String) -> Bool {
        text.range(of: Data(needle.utf8)) != nil
    }

    /// `suffix` right after a host name character (`abc.ngrok.io`, not `*.ngrok.io`).
    private static func containsHost(_ text: Data, _ suffix: String) -> Bool {
        let needle = Data(suffix.utf8)
        var from = text.startIndex
        var hits = 0
        while hits < 10_000, from < text.endIndex, let r = text.range(of: needle, in: from..<text.endIndex) {
            hits += 1
            from = r.upperBound
            guard r.lowerBound > text.startIndex else { continue }
            let b = text[r.lowerBound - 1]
            if (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x2D { return true }
        }
        return false
    }

    /// A whole C string in the file (an Objective-C selector name): NUL on both sides.
    private static func containsWord(_ text: Data, _ word: String) -> Bool {
        text.range(of: Data([UInt8(0)] + Array(word.utf8) + [UInt8(0)])) != nil
    }

    private static func hooks(_ data: Data, text: Data, imports: Set<String>) -> Bool {
        if !imports.isDisjoint(with: hookImports) { return true }
        if loads(data).contains(where: { tweakLibraryName($0.0) != nil
            || TweakClassifier.isHookingLibrary($0.0, libhooker: true) || $0.0.hasPrefix("/Library/MobileSubstrate/") }) { return true }
        return contains(text, "/Library/MobileSubstrate/") || contains(text, "/var/jb/")
    }

    static func signs(text: Data, imports: Set<String>, kind: IPAAddition.Kind) -> [WarningSign] {
        var found: [WarningSign] = []
        if contains(text, "discord.com/api/webhooks") || contains(text, "discordapp.com/api/webhooks") { found.append(.discordWebhook) }
        if contains(text, "api.telegram.org/bot") { found.append(.telegramBot) }
        // A URL to a paste site (any path: /raw to read, /documents or /api to upload), by its host
        // after a scheme or a subdomain dot (so www.pastebin.com counts) or the bare raw path, not a
        // plain word in prose (a tweak linking to it).
        let pasteSite = { (host: String) in
            self.contains(text, "://" + host) || self.contains(text, "." + host) || self.contains(text, host + "/raw")
        }
        if pasteSite("pastebin.com") || pasteSite("hastebin.com") || pasteSite("hastebin.skyra.pw") { found.append(.pasteSite) }
        // A host under ngrok (a public suffix list names ngrok.io alone, or as *.ngrok.io).
        if [".ngrok.io", ".ngrok-free.app", ".ngrok.app", ".ngrok-free.dev"].contains(where: { containsHost(text, $0) })
            || contains(text, "webhook.site/") || contains(text, "requestbin.net/") || contains(text, "requestbin.com/") {
            found.append(.tunnel)
        }
        if hasPublicIPURL(text) { found.append(.rawIP) }
        // Reading data, or loading code, is ordinary (a tweak keeping its settings in the keychain,
        // a big app's plug-ins): a sign only in an unknown addition, or one that also holds an
        // address to send things to.
        let suspicious = kind == .unknown || found.contains(where: \.isEndpoint)
        if suspicious {
            if !imports.isDisjoint(with: keychainImports) { found.append(.keychain) }
            if imports.contains("_OBJC_CLASS_$_UIPasteboard"), containsWord(text, "generalPasteboard"),
               containsWord(text, "changeCount") || contains(text, "UIPasteboardChangedNotification") {
                found.append(.pasteboard)
            }
            if imports.contains("_OBJC_CLASS_$_NSHTTPCookieStorage"), containsWord(text, "sharedHTTPCookieStorage"),
               containsWord(text, "cookies") {
                found.append(.cookies)
            }
            let loadsCode = imports.contains("_dlopen") || containsWord(text, "loadAndReturnError:")
            let downloads = ["downloadTaskWithURL:", "downloadTaskWithRequest:", "dataWithContentsOfURL:"].contains { contains(text, $0) }
            if loadsCode, downloads, contains(text, "Documents") { found.append(.remoteCode) }
        }
        return found
    }

    /// `http(s)://a.b.c.d:port` with a public IPv4 address.
    static func hasPublicIPURL(_ text: Data) -> Bool {
        let end = text.endIndex
        for scheme in ["http://", "https://"] {
            let needle = Data(scheme.utf8)
            var from = text.startIndex
            var hits = 0
            while hits < 10_000, from < end, let r = text.range(of: needle, in: from..<end) {
                hits += 1
                from = r.upperBound
                var i = r.upperBound
                var octets: [Int] = []
                var current = -1
                while i < end, octets.count < 4, i - r.upperBound < 16 {
                    let b = text[i]
                    if b >= 0x30 && b <= 0x39 {
                        current = (current < 0 ? 0 : current) * 10 + Int(b - 0x30)
                        if current > 255 { break }
                    } else if b == 0x2E, current >= 0, octets.count < 3 {
                        octets.append(current); current = -1
                    } else {
                        break
                    }
                    i += 1
                }
                if current >= 0, octets.count == 3, current <= 255 { octets.append(current) }
                guard octets.count == 4, i + 1 < end, text[i] == 0x3A, text[i + 1] >= 0x30, text[i + 1] <= 0x39 else { continue }
                if isPublic(octets) { return true }
            }
        }
        return false
    }

    private static func isPublic(_ o: [Int]) -> Bool {
        switch (o[0], o[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168), (255, _): return false
        case (172, 16...31), (100, 64...127): return false
        default: return o[0] < 224
        }
    }
}
