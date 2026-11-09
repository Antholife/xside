import Foundation

/// What XSide changes so a tweak works without a jailbreak (🔧).
public enum TweakConversion: Codable, Equatable, Sendable {
    /// Substrate / Substitute / libhooker replaced by the embedded ElleKit.
    case hookingLibrary
    /// Files the tweak looks for in the jailbreak's folders are copied into the app and redirected.
    case jailbreakPaths
    /// A library from another package the person added (its display name).
    case dependency(String)
    /// XSide's embedded copy of a known library (its display name).
    case dependencyAdded(String)

    /// The `Localizable.strings` key of its explanation; `%@` (when any) is `argument`.
    public var stringKey: String {
        switch self {
        case .hookingLibrary: "tweaks.conversion.hookingLibrary"
        case .jailbreakPaths: "tweaks.conversion.jailbreakPaths"
        case .dependency: "tweaks.conversion.dependency"
        case .dependencyAdded: "tweaks.conversion.dependencyAdded"
        }
    }

    public var argument: String? {
        switch self {
        case .hookingLibrary, .jailbreakPaths: nil
        case .dependency(let n), .dependencyAdded(let n): n
        }
    }
}

/// Why a tweak can't be injected (❌).
public enum TweakProblem: Codable, Equatable, Sendable {
    /// It loads into an Apple process or needs a library only a jailbreak has (the target or library).
    case needsJailbreak(String)
    /// Its filter names other apps (bundle ids, executables or classes); can be overridden.
    case madeForAnotherApp([String])
    /// No `arm64` slice (the slices it has).
    case wrongArchitecture([String])
    case notForIOS
    /// `required` is a version ("18.0") or a range ("≥ 15.0, < 17.0", "< 17.0", "> 17.5").
    case iOSVersion(required: String, device: String)
    /// A display name ("Cephei", "ElleKit", "XSideTweakSupport", "Foo.framework", a package id).
    case missingDependency(String)
    case nothingToInject
    /// Its filter plist has no `Filter`: it doesn't say which apps it loads into; can be overridden.
    case noFilter
    /// A version constraint (on iOS, or on a dependency) can't be read: never treated as satisfied.
    case unreadableRequirement(String)

    /// The `Localizable.strings` key of the reason. Arguments: `arguments`, except `iOSVersion`
    /// whose text takes (required, device name, device iOS): the app inserts the device's name.
    public var stringKey: String {
        switch self {
        case .needsJailbreak: "tweaks.problem.needsJailbreak"
        case .madeForAnotherApp: "tweaks.problem.madeForAnotherApp"
        case .wrongArchitecture: "tweaks.problem.wrongArchitecture"
        case .notForIOS: "tweaks.problem.notForIOS"
        case .iOSVersion: "tweaks.problem.iOSVersion"
        case .missingDependency: "tweaks.problem.missingDependency"
        case .nothingToInject: "tweaks.problem.nothingToInject"
        case .noFilter: "tweaks.problem.noFilter"
        case .unreadableRequirement: "tweaks.problem.unreadableRequirement"
        }
    }

    public var arguments: [String] {
        switch self {
        case .needsJailbreak(let s), .missingDependency(let s), .unreadableRequirement(let s): [s]
        case .madeForAnotherApp(let list), .wrongArchitecture(let list): [list.joined(separator: ", ")]
        case .iOSVersion(let required, let device): [required, device]
        case .notForIOS, .nothingToInject, .noFilter: []
        }
    }
}

public enum TweakVerdict: Codable, Equatable, Sendable {
    case compatible
    case converted([TweakConversion])
    case incompatible(TweakProblem)

    /// « Injecter quand même »: only when the problem is about which app the tweak is for, never
    /// for a jailbreak, an architecture, an iOS version or a missing library.
    public var canOverride: Bool {
        switch self {
        case .incompatible(.madeForAnotherApp), .incompatible(.noFilter): true
        default: false
        }
    }

    /// The `Localizable.strings` key of the override button.
    public static let overrideKey = "tweaks.force"
}

/// One `Depends` entry as the dependencies screen shows it.
public enum DependencyStatus: Equatable, Sendable {
    /// XSide's embedded copy (display name).
    case providedByXSide(String)
    /// A package the person added or downloaded (its name).
    case addedByYou(String)
    case missing(DebDependency)
    case jailbreakOnly(String)
    /// Hooking (ElleKit), settings or nothing to install.
    case notNeeded
}

/// What the classifier knows about the app, the device and the libraries at hand. Unknown app
/// facts (nil) match: they are checked again at signing.
public struct TweakContext: Sendable {
    public var originalBundleID: String
    public var executableName: String?
    public var appClassNames: Set<String>?
    /// Framework names the app links ("WebKit").
    public var appLinkedFrameworks: Set<String>?
    /// Whether a file exists in the app, by its path relative to the `.app`
    /// (`@rpath/X` is asked as `Frameworks/X`).
    public var appFiles: (@Sendable (String) -> Bool)?
    public var deviceOS: String?
    public var elleKitAvailable: Bool
    public var supportAvailable: Bool
    public var elleKitHasLibhooker: Bool
    public var isSystemLibrary: @Sendable (String) -> Bool
    /// The other enabled packages the person added or downloaded, in list order.
    public var others: [TweakPackage]
    /// XSide's embedded dependencies.
    public var embedded: [TweakPackage]

    public init(originalBundleID: String, executableName: String? = nil, appClassNames: Set<String>? = nil,
                appLinkedFrameworks: Set<String>? = nil, appFiles: (@Sendable (String) -> Bool)? = nil,
                deviceOS: String? = nil, elleKitAvailable: Bool = true, supportAvailable: Bool = true,
                elleKitHasLibhooker: Bool = false,
                isSystemLibrary: @escaping @Sendable (String) -> Bool = TweakClassifier.systemLibraries(sdk: nil),
                others: [TweakPackage] = [], embedded: [TweakPackage] = []) {
        self.originalBundleID = originalBundleID
        self.executableName = executableName
        self.appClassNames = appClassNames
        self.appLinkedFrameworks = appLinkedFrameworks
        self.appFiles = appFiles
        self.deviceOS = deviceOS
        self.elleKitAvailable = elleKitAvailable
        self.supportAvailable = supportAvailable
        self.elleKitHasLibhooker = elleKitHasLibhooker
        self.isSystemLibrary = isSystemLibrary
        self.others = others
        self.embedded = embedded
    }
}

/// Classifies a stored tweak for one app on one device: ✅, 🔧 (what changes) or ❌ (why), and
/// says how its libraries are found. Every input is data from an untrusted package: nothing here
/// touches the disk except `systemLibraries(sdk:)` checking the SDK's own files.
public enum TweakClassifier {
    public static let systemProcesses: Set<String> = [
        "springboard", "backboardd", "mediaserverd", "assertiond", "locationd", "installd", "lsd", "imagent",
        "nsurlsessiond", "preferences", "mobilesafari", "mobilesms", "mobilephone", "commcenter", "runningboardd",
        "searchd", "sharingd", "mediaremoted", "healthd", "powerd", "wifid", "bluetoothd",
    ]
    /// `com.apple.<x>` ids that are processes or Apple's own apps, never a framework an app links
    /// (with the app's frameworks unknown, other `com.apple.<x>` ids are given the benefit of the doubt).
    static let appleProcessIDs: Set<String> = systemProcesses.union([
        "mobilemail", "mobilenotes", "camera", "music", "mobileslideshow", "mobiletimer", "maps", "weather",
        "findmy", "appstore", "mobilecal", "facetime", "reminders", "news", "tv", "podcasts", "shortcuts",
    ])
    /// Bundle filters every app loads.
    static let everyAppBundles: Set<String> = ["com.apple.uikit", "com.apple.foundation", "com.apple.corefoundation"]

    public static func verdict(_ package: TweakPackage, _ context: TweakContext) -> TweakVerdict {
        analyze(package, context).verdict
    }

    /// Each `Depends` group's satisfied alternative, or its first one.
    public static func dependencies(_ package: TweakPackage, _ context: TweakContext) -> [(DebDependency, DependencyStatus)] {
        let others = context.others.filter { $0.id != package.id }
        return package.depends.compactMap { group in
            guard let first = group.first else { return nil }
            let statuses = group.map { alt -> (DebDependency, DependencyStatus) in (alt, status(alt, others, context.embedded)) }
            return statuses.first { s in
                switch s.1 {
                case .addedByYou, .providedByXSide, .notNeeded: true
                default: false
                }
            } ?? (first, statuses[0].1)
        }
    }

    /// Old install name → new load path, for every library name XSide rewrites.
    public static func resolution(_ package: TweakPackage, _ context: TweakContext) -> [String: String] {
        analyze(package, context).resolution
    }

    /// The embedded packages the signing must copy for this tweak, in `embedded` order.
    public static func providers(_ package: TweakPackage, _ context: TweakContext) -> [TweakPackage] {
        let used = analyze(package, context).embeddedUsed
        return context.embedded.filter { used.contains($0.id) }
    }

    public static func isHookingLibrary(_ path: String, libhooker: Bool) -> Bool {
        let lower = path.lowercased()
        if lower.hasSuffix("cydiasubstrate.framework/cydiasubstrate") { return true }
        let last = lower.split(separator: "/").last.map(String.init) ?? lower
        if ["libsubstrate.dylib", "libsubstitute.dylib", "libsubstitute.0.dylib", "libellekit.dylib"].contains(last) { return true }
        if libhooker, last == "libhooker.dylib" || lower.hasSuffix("libhooker.framework/libhooker") { return true }
        return false
    }

    /// Whether an install name is part of iOS. With an SDK: `/System/…`, `/usr/lib/swift/…`, and any
    /// other `/usr/lib/<x>` only when `<sdk>/usr/lib/<x minus .dylib>.tbd` exists. Without one:
    /// any absolute path that is neither a hooking library nor a jailbreak's.
    public static func systemLibraries(sdk: URL?) -> @Sendable (String) -> Bool {
        @Sendable func plain(_ p: String) -> Bool {
            p.hasPrefix("/") && p.utf8.count <= 1024 && !p.utf8.contains(0)
                && !p.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." }
        }
        guard let sdk else {
            return { p in plain(p) && !isHookingLibrary(p, libhooker: true) && !CrashClassifier.isJailbreakPath(p) }
        }
        let root = sdk.standardizedFileURL.path
        return { p in
            guard plain(p) else { return false }
            if p.hasPrefix("/System/") || p.hasPrefix("/usr/lib/swift/") { return true }
            guard p.hasPrefix("/usr/lib/") else { return false }
            var x = String(p.dropFirst("/usr/lib/".count))
            guard !x.isEmpty, !x.hasSuffix("/"), !x.contains("//") else { return false }
            if x.hasSuffix(".dylib") { x.removeLast(".dylib".count) }
            return FileManager.default.fileExists(atPath: root + "/usr/lib/" + x + ".tbd")
        }
    }

    // MARK: analysis

    private struct Analysis {
        var problem: TweakProblem?
        var conversions: [TweakConversion] = []
        var resolution: [String: String] = [:]
        var embeddedUsed: Set<String> = []
        var early: TweakVerdict?

        mutating func fail(_ p: TweakProblem) { if problem == nil { problem = p } }
        mutating func convert(_ c: TweakConversion) { if !conversions.contains(c) { conversions.append(c) } }

        var verdict: TweakVerdict {
            if let early { return early }
            if let problem { return .incompatible(problem) }
            return conversions.isEmpty ? .compatible : .converted(conversions)
        }
    }

    private enum Source { case own, other, embedded }

    private static func analyze(_ package: TweakPackage, _ context: TweakContext) -> Analysis {
        var a = Analysis()
        let entries = package.entries
        // 1. No entry.
        if entries.isEmpty {
            a.early = !package.binaries.isEmpty || package.kind == .bundle ? .compatible : .incompatible(.nothingToInject)
        }
        // 2. Slices and iOS.
        for e in entries { checkSlices(e, context, &a) }
        if !entries.isEmpty {
            let fw = DebControl.firmwareBounds(package.depends)
            if fw.unparseable { a.fail(.unreadableRequirement("iOS")) }
            else if let device = context.deviceOS, !fw.allows(device) {
                a.fail(.iOSVersion(required: describe(fw), device: device))
            }
        }
        // 3. Filter.
        for e in entries { if let p = filterProblem(e.filter, context) { a.fail(p) } }

        // 4. Depends: the person's packages come before XSide's.
        var others = context.others.filter { $0.id != package.id }
        var embedded = context.embedded.filter { $0.id != package.id }
        var chosen: Set<String> = [], rejected: Set<String> = []
        for group in package.depends {
            dependsGroup(group, others, embedded, &a, &chosen, &rejected)
        }
        rejected.subtract(chosen)
        others.removeAll { rejected.contains($0.id) }
        embedded.removeAll { rejected.contains($0.id) }

        // 5. Linked names.
        for binary in package.binaries {
            for name in binary.linked { link(name, package, others, embedded, context, &a) }
        }

        // 6. Files the tweak reads from the jailbreak's folders.
        if needsPaths(package) {
            if context.supportAvailable { a.convert(.jailbreakPaths) } else { a.fail(.missingDependency("XSideTweakSupport")) }
        }
        return a
    }

    private static func checkSlices(_ e: TweakBinary, _ context: TweakContext, _ a: inout Analysis) {
        guard let s = e.slices.first(where: { $0.arch == "arm64" }) else {
            var archs: [String] = []
            for s in e.slices where !archs.contains(s.arch) { archs.append(s.arch) }
            a.fail(.wrongArchitecture(archs))
            return
        }
        if let p = s.platform, p != 2 { a.fail(.notForIOS) }
        if let min = s.minOS, let device = context.deviceOS, InstallPreflight.compare(min, device) == .orderedDescending {
            a.fail(.iOSVersion(required: min, device: device))
        }
    }

    private static func describe(_ b: DebControl.FirmwareBounds) -> String {
        var parts: [String] = []
        if let m = b.min { parts.append(b.minExclusive ? "> \(m)" : b.belowMax == nil ? m : "≥ \(m)") }
        if let x = b.belowMax { parts.append(b.maxInclusive ? "≤ \(x)" : "< \(x)") }
        return parts.joined(separator: ", ")
    }

    private static func filterProblem(_ filter: TweakFilter?, _ context: TweakContext) -> TweakProblem? {
        guard let f = filter else { return nil }    // a dropped dylib or framework: made for this app
        var kinds: [(targets: [String], matches: Bool)] = []
        if !f.bundles.isEmpty {
            let app = context.originalBundleID.lowercased()
            let linked = context.appLinkedFrameworks.map { Set($0.map { $0.lowercased() }) }
            kinds.append((f.bundles, f.bundles.contains { raw in
                let id = raw.lowercased()
                if id == app || everyAppBundles.contains(id) { return true }
                guard id.hasPrefix("com.apple.") else { return false }
                let x = String(id.dropFirst("com.apple.".count))
                guard let linked else { return !appleProcessIDs.contains(x) }
                return linked.contains(x)
            }))
        }
        if !f.executables.isEmpty {
            let exe = context.executableName
            kinds.append((f.executables, exe.map { e in f.executables.contains { $0 == e } } ?? true))
        }
        if !f.classes.isEmpty {
            kinds.append((f.classes, context.appClassNames.map { names in f.classes.contains { names.contains($0) } } ?? true))
        }
        guard !kinds.isEmpty else { return .noFilter }
        let ok = f.anyMode ? kinds.contains { $0.matches } : kinds.allSatisfy { $0.matches }
        if ok { return nil }
        let targets = kinds.filter { !$0.matches }.flatMap(\.targets)
        let system = targets.allSatisfy { t in
            t.lowercased().hasPrefix("com.apple.") || systemProcesses.contains(t.lowercased())
        }
        return system ? .needsJailbreak(targets[0]) : .madeForAnotherApp(targets)
    }

    // MARK: dependencies

    private static func knownName(_ packageID: String) -> String? {
        switch KnownDependency.role(of: packageID) {
        case .library(let n), .jailbreakOnly(let n): n
        default: nil
        }
    }

    private static func displayName(_ p: TweakPackage) -> String {
        knownName(p.packageID) ?? p.provides.lazy.compactMap { knownName($0) }.first ?? p.name
    }

    private static func idMatches(_ p: TweakPackage, _ dep: DebDependency) -> Bool {
        p.packageID == dep.package || p.provides.contains(dep.package)
    }

    /// Debian's rule: the package itself is checked against the version; an (unversioned)
    /// `Provides` only satisfies a dependency without a version. An unreadable one never is.
    private static func satisfies(_ p: TweakPackage, _ dep: DebDependency) -> Bool {
        if dep.unparseable { return false }
        if p.packageID == dep.package {
            if dep.relation == nil { return true }
            return p.version.map { dep.isSatisfied(by: $0) } ?? false
        }
        return p.provides.contains(dep.package) && dep.relation == nil
    }

    private static func isNotNeeded(_ dep: DebDependency) -> Bool {
        switch KnownDependency.role(of: dep.package) {
        case .hooking, .settings, .ignored: true
        default: false
        }
    }

    private static func status(_ dep: DebDependency, _ others: [TweakPackage], _ embedded: [TweakPackage]) -> DependencyStatus {
        if isNotNeeded(dep) { return .notNeeded }
        if let p = others.first(where: { satisfies($0, dep) }) { return .addedByYou(p.name) }
        if let p = embedded.first(where: { satisfies($0, dep) }) { return .providedByXSide(displayName(p)) }
        if case .jailbreakOnly(let n) = KnownDependency.role(of: dep.package) { return .jailbreakOnly(n) }
        return .missing(dep)
    }

    private enum Outcome { case satisfied(TweakConversion?), unknown, problem(TweakProblem) }

    private static func dependsGroup(_ group: [DebDependency], _ others: [TweakPackage], _ embedded: [TweakPackage],
                                     _ a: inout Analysis, _ chosen: inout Set<String>, _ rejected: inout Set<String>) {
        var outcomes: [Outcome] = []
        for dep in group {
            // Hooking frameworks are always ElleKit; `firmware` was checked with the slices.
            if isNotNeeded(dep) { outcomes.append(.satisfied(nil)); break }
            let matching = (others + embedded).filter { idMatches($0, dep) }
            let theirs = others.first { satisfies($0, dep) }
            let ours = theirs == nil ? embedded.first { satisfies($0, dep) } : nil
            let pick = theirs ?? ours
            for p in matching where p.id != pick?.id { rejected.insert(p.id) }
            if let theirs {
                chosen.insert(theirs.id)
                outcomes.append(.satisfied(.dependency(displayName(theirs))))
                break
            }
            if let ours {
                chosen.insert(ours.id)
                a.embeddedUsed.insert(ours.id)
                outcomes.append(.satisfied(.dependencyAdded(displayName(ours))))
                break
            }
            let name = knownName(dep.package) ?? dep.package
            if dep.unparseable { outcomes.append(.problem(.unreadableRequirement(name))); continue }
            switch KnownDependency.role(of: dep.package) {
            case .jailbreakOnly(let n): outcomes.append(.problem(.needsJailbreak(n)))
            case .library(let n): outcomes.append(.problem(.missingDependency(n)))
            default:
                // Unknown: a package that matched but in the wrong version is missing; otherwise its
                // libraries are checked by name below.
                outcomes.append(matching.isEmpty ? .unknown : .problem(.missingDependency(name)))
            }
        }
        if case .satisfied(let c)? = outcomes.last {
            if let c { a.convert(c) }
        } else if outcomes.contains(where: { if case .unknown = $0 { true } else { false } }) {
            return
        } else if case .problem(let p)? = outcomes.first {
            a.fail(p)
        }
    }

    // MARK: linked names

    private static func loadPath(_ p: TweakPackage, _ file: String) -> String {
        TweakLayout.loadPrefix + TweakLayout.directory(p) + "/" + file
    }

    /// Known libraries by file name, so an undeclared one is still named.
    private static func knownLibrary(_ path: String) -> String? {
        switch CrashClassifier.libraryName(path).lowercased() {
        case "cephei.framework", "cepheiprefs.framework", "cepheiui.framework": "Cephei"
        case "altlist.framework": "AltList"
        case "libroot.dylib": "libroot"
        case "libgcuniversal.dylib", "libgcuniversal.framework": "libGCUniversal"
        default: nil
        }
    }

    private static func use(_ source: Source, _ p: TweakPackage, file: String, for name: String,
                            conversion: TweakConversion?, _ a: inout Analysis) {
        a.resolution[name] = loadPath(p, file)
        if source == .embedded { a.embeddedUsed.insert(p.id) }
        if let conversion { a.convert(conversion) }
    }

    private static func link(_ name: String, _ package: TweakPackage, _ others: [TweakPackage], _ embedded: [TweakPackage],
                             _ context: TweakContext, _ a: inout Analysis) {
        if isHookingLibrary(name, libhooker: context.elleKitHasLibhooker) {
            if context.elleKitAvailable {
                a.convert(.hookingLibrary)
                a.resolution[name] = TweakLayout.elleKitLoadPath
            } else {
                a.fail(.missingDependency("ElleKit"))
            }
            return
        }
        if name.hasPrefix("/System/") && !name.contains("/..") && !name.contains("/./") { return }
        let display = knownLibrary(name) ?? CrashClassifier.libraryName(name)

        // An absolute path one of the packages ships (with `/var/jb` stripped) is theirs, even under
        // /usr/lib: iOS has no such file there, and without an SDK `isSystemLibrary` can only guess.
        let stripped = name.hasPrefix("/var/jb/") ? String(name.dropFirst("/var/jb".count)) : name
        if name.hasPrefix("/") {
            let rel = String(stripped.dropFirst())
            let safe = !rel.isEmpty && !rel.utf8.contains(0)
                && !rel.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." || $0.isEmpty }
            if safe {
                if package.files.contains(rel) { use(.own, package, file: rel, for: name, conversion: .jailbreakPaths, &a); return }
                for p in others where p.files.contains(rel) {
                    use(.other, p, file: rel, for: name, conversion: .dependency(displayName(p)), &a); return
                }
                for p in embedded where p.files.contains(rel) {
                    use(.embedded, p, file: rel, for: name, conversion: .dependencyAdded(displayName(p)), &a); return
                }
            }
        }
        if context.isSystemLibrary(name) { return }

        for prefix in ["@rpath/", "@executable_path/", "@loader_path/"] where name.hasPrefix(prefix) {
            var parts = name.dropFirst(prefix.count).split(separator: "/").map(String.init)
            while parts.first == ".." || parts.first == "." { parts.removeFirst() }
            let x = parts.joined(separator: "/")
            guard !x.isEmpty, !parts.contains(".."), !x.utf8.contains(0) else { a.fail(.missingDependency(display)); return }
            if let f = package.files.first(where: { $0 == x || $0.hasSuffix("/" + x) }) {
                use(.own, package, file: f, for: name, conversion: nil, &a); return
            }
            func libraryFile(_ p: TweakPackage) -> String? {
                p.files.first { ($0.hasPrefix("Library/Frameworks/") || $0.hasPrefix("usr/lib/")) && $0.hasSuffix("/" + x) }
            }
            for p in others { if let f = libraryFile(p) { use(.other, p, file: f, for: name, conversion: .dependency(displayName(p)), &a); return } }
            for p in embedded { if let f = libraryFile(p) { use(.embedded, p, file: f, for: name, conversion: .dependencyAdded(displayName(p)), &a); return } }
            guard let appFiles = context.appFiles else { return }
            let inApp = prefix == "@rpath/" ? "Frameworks/" + x : x
            if !appFiles(inApp) { a.fail(.missingDependency(display)) }
            return
        }

        guard name.hasPrefix("/") else { a.fail(.missingDependency(display)); return }
        if let known = knownLibrary(name) { a.fail(.missingDependency(known)); return }
        // Not part of iOS (checked above): under /usr/lib or anywhere else, only a jailbreak has it.
        if CrashClassifier.isJailbreakPath(name) || stripped.hasPrefix("/usr/lib/") {
            a.fail(.needsJailbreak(display))
        } else {
            a.fail(.missingDependency(display))
        }
    }

    // MARK: files

    private static func needsPaths(_ package: TweakPackage) -> Bool {
        if package.binaries.contains(where: \.mentionsJailbreakPaths) { return true }
        guard package.kind == .deb else { return false }    // a dropped framework or bundle keeps its files beside it
        let binaries = Set(package.binaries.map(\.path))
        let plists = Set(package.entries.map { e in
            (e.path.hasSuffix(".dylib") ? String(e.path.dropLast(".dylib".count)) : e.path) + ".plist"
        })
        return package.files.contains { f in
            !binaries.contains(f) && !plists.contains(f)
                && !f.split(separator: "/").dropLast().contains { $0.hasSuffix(".framework") }
        }
    }
}
