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
    /// Two tweaks on this device need versions of one dependency no single copy satisfies (its
    /// display name, this tweak's constraint first): an app loads only one copy.
    case dependencyConflict(String, [String])

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
        case .dependencyConflict: "tweaks.problem.dependencyConflict"
        }
    }

    /// `stringKey`, worded for this package: a `needsJailbreak` that isn't one of its filter's
    /// targets (where it loads) is a library it uses, which has its own text.
    public func stringKey(for package: TweakPackage) -> String {
        if case .needsJailbreak(let name) = self, !package.filterNames(name) { return "tweaks.problem.needsJailbreakLibrary" }
        return stringKey
    }

    public var arguments: [String] {
        switch self {
        case .needsJailbreak(let s), .missingDependency(let s), .unreadableRequirement(let s): [s]
        case .madeForAnotherApp(let list), .wrongArchitecture(let list): [list.joined(separator: ", ")]
        case .iOSVersion(let required, let device): [required, device]
        case .notForIOS, .nothingToInject, .noFilter: []
        case .dependencyConflict(let name, let c): [name, c.first ?? "?", c.dropFirst().first ?? "?"]
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
    /// Already inside the tweak, its work done by XSide (« fourni par XSide (intégré au tweak) »): libroot.
    case builtIntoTweak(String)
    /// Hooking (ElleKit), settings or nothing to install.
    case notNeeded
}

/// Something to know about a tweak whatever its verdict, shown on its card.
public enum TweakWarning: Equatable, Sendable {
    /// It imports C function hooks (`MSHookFunction`…): stock iOS kills the app when they run
    /// (code pages can't be written without a jailbreak). Its Objective-C hooks still work, so it
    /// stays 🔧.
    case cFunctionHooks([String])

    public var stringKey: String {
        switch self {
        case .cFunctionHooks: "tweaks.warning.cFunctionHooks"
        }
    }
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
        "kbd", "lockdownd", "configd", "usereventagent",
    ]
    /// The verdict. With `overridingFilter` (« Injecter quand même »), a filter problem
    /// (`madeForAnotherApp`, `noFilter`) is ignored and the verdict that then applies is returned,
    /// with its 🔧 list; every other problem still stands.
    public static func verdict(_ package: TweakPackage, _ context: TweakContext, overridingFilter: Bool = false) -> TweakVerdict {
        analyze(package, context).verdict(overridingFilter: overridingFilter)
    }

    /// What the card warns about, on every device.
    public static func warnings(_ package: TweakPackage) -> [TweakWarning] {
        let hooks = package.cFunctionHooks
        return hooks.isEmpty ? [] : [.cFunctionHooks(hooks)]
    }

    /// Everything the signing needs about one tweak, computed once.
    public static func classify(_ package: TweakPackage, _ context: TweakContext) -> TweakClassification {
        let a = analyze(package, context)
        return TweakClassification(verdict: a.verdict(overridingFilter: false),
                                   verdictOverridingFilter: a.verdict(overridingFilter: true),
                                   resolution: a.resolution,
                                   providers: context.embedded.filter { a.embeddedUsed.contains($0.id) })
    }

    /// Each `Depends` group's satisfied alternative, or its first one.
    public static func dependencies(_ package: TweakPackage, _ context: TweakContext) -> [(DebDependency, DependencyStatus)] {
        // The same providers the verdict may use.
        let usable = { (p: TweakPackage) in p.id != package.id && !isJailbreakOnlyPackage(p) }
        let others = context.others.filter(usable), embedded = context.embedded.filter(usable)
        let wanted = demands(of: context.others, besides: package)
        return package.depends.compactMap { group in
            guard let first = group.first else { return nil }
            let statuses = group.map { alt -> (DebDependency, DependencyStatus) in (alt, status(alt, others, embedded, wanted, context)) }
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

    /// The person's packages (not XSide's) this tweak relies on, with their own providers'.
    public static func reliedOn(_ package: TweakPackage, _ context: TweakContext) -> [TweakPackage] {
        let a = analyze(package, context)
        var out: [TweakPackage] = []
        var queue = a.providers.filter { $0.origin != .embedded }
        while let p = queue.first {
            queue.removeFirst()
            guard !out.contains(where: { $0.id == p.id }), p.id != package.id, out.count < 64 else { continue }
            out.append(p)
            queue += analyze(p, context).providers.filter { $0.origin != .embedded }
        }
        return out
    }

    /// The embedded packages the signing must copy for this tweak (also those its providers
    /// need), in `embedded` order.
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
    /// `/System/…`, `/usr/lib/swift/…`, `/usr/lib/system/…` and the `/usr/lib` names in
    /// `iOSUsrLibNames` (a jailbreak's libraries live in /usr/lib too, so "anything there" won't do).
    public static func systemLibraries(sdk: URL?) -> @Sendable (String) -> Bool {
        @Sendable func plain(_ p: String) -> Bool {
            p.hasPrefix("/") && p.utf8.count <= 1024 && !p.utf8.contains(0)
                && !p.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." }
        }
        guard let sdk else {
            return { p in
                guard plain(p) else { return false }
                if p.hasPrefix("/System/") || p.hasPrefix("/usr/lib/swift/") || p.hasPrefix("/usr/lib/system/") { return true }
                guard p.hasPrefix("/usr/lib/") else { return false }
                let file = p.dropFirst("/usr/lib/".count)
                guard !file.contains("/"), let base = file.split(separator: ".").first else { return false }
                return iOSUsrLibNames.contains(base.lowercased())
            }
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

    // MARK: known names

    /// First component (before the first `.`) of the file names iOS ships directly in /usr/lib.
    static let iOSUsrLibNames: Set<String> = [
        "libsystem", "libobjc", "libobjc-trampolines", "libc++", "libc++abi", "libz", "libsqlite3", "libxml2", "libxslt",
        "libexslt", "libicucore", "libiconv", "libcharset", "libbz2", "liblzma", "libresolv", "libcompression",
        "libmobilegestalt", "libnetwork", "libc", "libm", "libdl", "libpthread", "libinfo", "libarchive", "libutil",
        "libbsm", "libpcap", "libboringssl", "libcoretls", "libcoretls_cfhelpers", "libapple_nghttp2", "libaccessibility",
        "libmecab", "libcmph", "libenergytrace", "liblangid", "libgcc_s", "libstdc++", "libextension", "libsandbox",
        "libfosl_dynamic", "libpam", "libmis", "libprequelite", "libcupolicy", "libtailspin", "libate",
    ]

    /// Libraries only a jailbreak has, by the first component of their file name: their display
    /// name, or nil to show the file name.
    static let jailbreakOnlyImages: [String: String?] = [
        "librocketbootstrap": "RocketBootstrap", "libactivator": "Activator", "libapplist": "AppList",
        "libmryipc": "libMRYIPC", "libsandy": "libSandy", "libcolorpicker": nil, "libcscolorpicker": nil,
        "libsparkcolourpicker": nil, "libsparkapplist": nil, "libhooker": nil, "libblackjack": nil, "libpddokdo": nil,
    ]

    /// By file name, or by framework folder (`RocketBootstrap.framework` matches `librocketbootstrap`).
    private static func jailbreakOnlyImage(_ path: String) -> String?? {
        let parts = path.split(separator: "/")
        if let file = parts.last, let base = file.split(separator: ".").first,
           let hit = jailbreakOnlyImages[base.lowercased()] { return hit }
        for folder in parts.dropLast() where folder.lowercased().hasSuffix(".framework") {
            let base = folder.dropLast(".framework".count).lowercased()
            if let hit = jailbreakOnlyImages[base] ?? jailbreakOnlyImages["lib" + base] {
                return hit ?? String(folder)
            }
        }
        return nil
    }

    /// `com.apple.<x>` ids that are processes or Apple's own apps, never a framework an app links
    /// (with the app's frameworks unknown, other `com.apple.<x>` ids are given the benefit of the doubt).
    static let appleProcessIDs: Set<String> = systemProcesses.union([
        "mobilemail", "mobilenotes", "camera", "music", "mobileslideshow", "mobiletimer", "maps", "weather",
        "findmy", "appstore", "mobilecal", "facetime", "reminders", "news", "tv", "podcasts", "shortcuts",
        "calculator", "compass", "health", "passbook", "mobilestore", "bridge", "voicememos", "stocks", "tips",
        "mobileaddressbook", "ibooks", "home", "translate", "measure", "magnifier", "fitness", "freeform",
    ])
    /// Bundle filters every app loads.
    static let everyAppBundles: Set<String> = ["com.apple.uikit", "com.apple.foundation", "com.apple.corefoundation"]

    /// SpringBoard's classes (`SBIconController`…): `SB` and a capital.
    static func isSpringBoardClass(_ name: String) -> Bool {
        let u = Array(name.unicodeScalars)
        return u.count > 2 && u[0] == "S" && u[1] == "B" && ("A"..."Z").contains(u[2])
    }

    // MARK: analysis

    private struct Analysis {
        /// The first problem that isn't about the filter.
        var problem: TweakProblem?
        /// `madeForAnotherApp` / `noFilter`: overridable, and only reported when nothing else is wrong.
        var filterProblem: TweakProblem?
        var conversions: [TweakConversion] = []
        var resolution: [String: String] = [:]
        var embeddedUsed: Set<String> = []
        /// Providers (others or embedded) this tweak relies on, in the order first used.
        var providers: [TweakPackage] = []

        mutating func fail(_ p: TweakProblem) { if problem == nil { problem = p } }
        mutating func failFilter(_ p: TweakProblem) { if filterProblem == nil { filterProblem = p } }
        mutating func convert(_ c: TweakConversion) { if !conversions.contains(c) { conversions.append(c) } }
        mutating func rely(on p: TweakPackage, embedded: Bool) {
            if embedded { embeddedUsed.insert(p.id) }
            if !providers.contains(where: { $0.id == p.id }) { providers.append(p) }
        }

        func verdict(overridingFilter: Bool) -> TweakVerdict {
            if let problem { return .incompatible(problem) }
            if !overridingFilter, let filterProblem { return .incompatible(filterProblem) }
            return conversions.isEmpty ? .compatible : .converted(conversions)
        }
    }

    private enum Source { case own, other, embedded }

    /// How deep providers' own providers are checked.
    private static let maxProviderDepth = 4

    private static func analyze(_ package: TweakPackage, _ context: TweakContext,
                                visited: Set<String> = [], depth: Int = 0) -> Analysis {
        var a = Analysis()
        let entries = package.entries
        // 1. Nothing to load at all. A library or `.bundle` package goes on with its own binaries.
        if package.binaries.isEmpty, package.kind != .bundle {
            a.fail(.nothingToInject)
            return a
        }
        // 2. Slices and iOS, for every binary (libraries get loaded too).
        for b in package.binaries { checkSlices(b, context, &a) }
        if !package.binaries.isEmpty {
            let fw = DebControl.firmwareBounds(package.depends)
            if fw.unparseable { a.fail(.unreadableRequirement("iOS")) }
            else if let device = context.deviceOS, !fw.allows(device) {
                a.fail(.iOSVersion(required: describe(fw), device: device))
            }
        }
        // 3. Filter.
        for e in entries { checkFilter(e.filter, context, &a) }

        // 4. Depends: the person's packages come before XSide's.
        let usable = { (p: TweakPackage) in p.id != package.id && !isJailbreakOnlyPackage(p) }
        let others = context.others.filter(usable)
        var embedded = context.embedded.filter(usable)
        var chosen: [TweakPackage] = [], rejected: Set<String> = []
        // What the other tweaks on this device ask for: one copy of a package serves them all.
        let wanted = depth == 0 ? demands(of: context.others, besides: package) : []
        for group in package.depends {
            dependsGroup(group, others, embedded, wanted, context, &a, &chosen, &rejected)
        }
        rejected.subtract(chosen.map(\.id))
        // Only packages a Depends entry chose are searched for the person's files.
        let chosenOthers = others.filter { p in chosen.contains { $0.id == p.id } }
        embedded.removeAll { rejected.contains($0.id) }

        // 5. Linked names.
        for binary in package.binaries {
            for name in binary.linked { link(name, package, chosenOthers, embedded, context, &a) }
        }

        // 6. Files the tweak reads from the jailbreak's folders.
        if needsPaths(package) {
            if context.supportAvailable { a.convert(.jailbreakPaths) } else { a.fail(.missingDependency("XSideTweakSupport")) }
        }

        // 7. The providers it relies on must load too.
        let seen = visited.union([package.id])
        for p in a.providers where !seen.contains(p.id) && depth < maxProviderDepth {
            let sub = analyze(p, context, visited: seen.union(a.providers.map(\.id)), depth: depth + 1)
            if let problem = sub.problem, problem != .nothingToInject { a.fail(problem) }
            a.embeddedUsed.formUnion(sub.embeddedUsed)
        }
        return a
    }

    private static func isJailbreakOnlyPackage(_ p: TweakPackage) -> Bool {
        ([p.packageID] + p.provides).contains { id in
            if case .jailbreakOnly = KnownDependency.role(of: id) { true } else { false }
        }
    }

    private static func checkSlices(_ b: TweakBinary, _ context: TweakContext, _ a: inout Analysis) {
        guard let s = b.slices.first(where: { $0.arch == "arm64" }) else {
            var archs: [String] = []
            for s in b.slices where !archs.contains(s.arch) { archs.append(s.arch) }
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

    private static func isSystemTarget(_ t: String) -> Bool {
        let l = t.lowercased()
        return l.hasPrefix("com.apple.") || systemProcesses.contains(l) || isSpringBoardClass(t)
    }

    private static func checkFilter(_ filter: TweakFilter?, _ context: TweakContext, _ a: inout Analysis) {
        guard let f = filter else { return }    // a dropped dylib or framework: made for this app
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
            // Unknown executable: any non-system one is given the benefit of the doubt.
            let matches = context.executableName.map { e in f.executables.contains { $0 == e } }
                ?? f.executables.contains { !systemProcesses.contains($0.lowercased()) }
            kinds.append((f.executables, matches))
        }
        if !f.classes.isEmpty {
            let matches = context.appClassNames.map { names in f.classes.contains { names.contains($0) } }
                ?? f.classes.contains { !isSpringBoardClass($0) }
            kinds.append((f.classes, matches))
        }
        guard !kinds.isEmpty else { a.failFilter(.noFilter); return }
        let ok = f.anyMode ? kinds.contains { $0.matches } : kinds.allSatisfy { $0.matches }
        if ok { return }
        let targets = kinds.filter { !$0.matches }.flatMap(\.targets)
        if targets.allSatisfy(isSystemTarget) { a.fail(.needsJailbreak(targets[0])) } else { a.failFilter(.madeForAnotherApp(targets)) }
    }

    // MARK: dependencies

    private static func knownName(_ packageID: String) -> String? {
        switch KnownDependency.role(of: packageID) {
        case .library(let n), .jailbreakOnly(let n), .builtIntoTweak(let n): n
        default: nil
        }
    }

    private static func displayName(_ p: TweakPackage) -> String {
        let name = knownName(p.packageID) ?? p.provides.lazy.compactMap { knownName($0) }.first ?? p.name
        // XSide's own copy says which version it embeds (its package.json, from
        // scripts/tweak-deps.env): « Cephei 2.0 · fournie par XSide » (retest, G2).
        guard p.origin == .embedded, let v = p.version, !v.isEmpty, v.utf8.count <= 32 else { return name }
        return name + " " + v
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

    /// `KnownDependency.role`, except libhooker, which only ElleKit with its libhooker layer replaces.
    private static func role(_ dep: DebDependency, _ context: TweakContext) -> KnownDependency? {
        if dep.package == "org.coolstar.libhooker", !context.elleKitHasLibhooker { return .jailbreakOnly("libhooker") }
        return KnownDependency.role(of: dep.package)
    }

    private static func isNotNeeded(_ role: KnownDependency?) -> Bool {
        switch role {
        case .hooking, .settings, .ignored, .builtIntoTweak: true
        default: false
        }
    }

    /// A `firmware` alternative inside a group of several (a lone one is checked with the slices).
    private static func firmwareProblem(_ dep: DebDependency, _ context: TweakContext) -> TweakProblem? {
        let b = DebControl.firmwareBounds([[dep]])
        if b.unparseable { return .unreadableRequirement("iOS") }
        if let device = context.deviceOS, !b.allows(device) { return .iOSVersion(required: describe(b), device: device) }
        return nil
    }

    private static func status(_ dep: DebDependency, _ others: [TweakPackage], _ embedded: [TweakPackage],
                               _ wanted: [DebDependency], _ context: TweakContext) -> DependencyStatus {
        let r = role(dep, context)
        if case .builtIntoTweak(let n) = r { return .builtIntoTweak(n) }
        if isNotNeeded(r) { return .notNeeded }
        // Nobody's copy of a jailbreak-only library makes it work without a jailbreak.
        if case .jailbreakOnly(let n) = r { return .jailbreakOnly(n) }
        guard let pick = provider(for: dep, others, embedded, wanted) else { return .missing(dep) }
        return pick.embedded ? .providedByXSide(displayName(pick.package)) : .addedByYou(pick.package.name)
    }

    /// Every alternative the other tweaks of the device ask for (not `package`'s, not iOS).
    private static func demands(of others: [TweakPackage], besides package: TweakPackage) -> [DebDependency] {
        others.filter { $0.id != package.id && !isJailbreakOnlyPackage($0) }
            .flatMap { $0.depends.joined() }
            .filter { $0.package != "firmware" && !$0.unparseable }
    }

    /// The copy that serves `dep` on this device: a .deb the person added (« Ajouter son .deb… »)
    /// first, then XSide's own, then a copy downloaded (or reused from the kept downloads) for a
    /// tweak XSide's can't serve (device round 3, F2: once that tweak is gone, XSide's serves
    /// again). Among those, the first that also satisfies what the device's other tweaks ask of
    /// the same package (an app loads only one copy). `conflict`: what another tweak asks that
    /// the copy doesn't satisfy while another copy at hand would (two versions needed at once).
    private static func provider(for dep: DebDependency, _ others: [TweakPackage], _ embedded: [TweakPackage],
                                 _ wanted: [DebDependency])
        -> (package: TweakPackage, embedded: Bool, conflict: DebDependency?)? {
        let isDownload = { (p: TweakPackage) -> Bool in if case .downloaded = p.origin { true } else { false } }
        let candidates = others.filter { !isDownload($0) }.map { ($0, false) } + embedded.map { ($0, true) }
            + others.filter(isDownload).map { ($0, false) }
        let fitting = candidates.filter { satisfies($0.0, dep) }
        guard let first = fitting.first else { return nil }
        let names = { (p: TweakPackage) in Set([p.packageID] + p.provides) }
        let relevant = { (p: TweakPackage) in wanted.filter { names(p).contains($0.package) } }
        if let agreeing = fitting.first(where: { c in relevant(c.0).allSatisfy { satisfies(c.0, $0) } }) {
            return (agreeing.0, agreeing.1, nil)
        }
        let conflict = relevant(first.0).first { w in
            !satisfies(first.0, w) && candidates.contains { satisfies($0.0, w) }
        }
        return (first.0, first.1, conflict)
    }

    private enum Outcome { case satisfied(TweakConversion?), unknown, problem(TweakProblem) }

    private static func dependsGroup(_ group: [DebDependency], _ others: [TweakPackage], _ embedded: [TweakPackage],
                                     _ wanted: [DebDependency], _ context: TweakContext, _ a: inout Analysis,
                                     _ chosen: inout [TweakPackage], _ rejected: inout Set<String>) {
        var outcomes: [Outcome] = []
        for dep in group {
            let r = role(dep, context)
            if dep.package == "firmware", group.count > 1 {
                if let p = firmwareProblem(dep, context) { outcomes.append(.problem(p)); continue }
                outcomes.append(.satisfied(nil)); break
            }
            // Hooking frameworks are always ElleKit; a lone `firmware` was checked with the slices;
            // libroot is inside the tweak (a copy the person added is never needed).
            if isNotNeeded(r) { outcomes.append(.satisfied(nil)); break }
            if case .jailbreakOnly(let n) = r { outcomes.append(.problem(.needsJailbreak(n))); continue }
            let matching = (others + embedded).filter { idMatches($0, dep) }
            let found = provider(for: dep, others, embedded, wanted)
            for p in matching where p.id != found?.package.id { rejected.insert(p.id) }
            if let found {
                let pick = found.package
                if !chosen.contains(where: { $0.id == pick.id }) { chosen.append(pick) }
                a.rely(on: pick, embedded: found.embedded)
                if let other = found.conflict {
                    a.fail(.dependencyConflict(displayName(pick), [DependencyDirectory.constraint(dep) ?? "*",
                                                                   DependencyDirectory.constraint(other) ?? "*"]))
                }
                outcomes.append(.satisfied(found.embedded ? .dependencyAdded(displayName(pick)) : .dependency(displayName(pick))))
                break
            }
            let name = knownName(dep.package) ?? dep.package
            if dep.unparseable { outcomes.append(.problem(.unreadableRequirement(name))); continue }
            if case .library(let n) = r { outcomes.append(.problem(.missingDependency(n))); continue }
            // Unknown: a package that matched but in the wrong version is missing; otherwise its
            // libraries are checked by name below.
            outcomes.append(matching.isEmpty ? .unknown : .problem(.missingDependency(name)))
        }
        if case .satisfied(let c)? = outcomes.last {
            if let c { a.convert(c) }
        } else if let jb = outcomes.lazy.compactMap({ o -> TweakProblem? in
            if case .problem(.needsJailbreak(let n)) = o { .needsJailbreak(n) } else { nil }
        }).first {
            // Nothing satisfied and one way needs a jailbreak: an unknown alternative doesn't hide it.
            a.fail(jb)
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
        if source != .own { a.rely(on: p, embedded: source == .embedded) }
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
        let display = knownLibrary(name) ?? CrashClassifier.libraryName(name)
        // A library only a jailbreak has, wherever it's looked for (rootful, rootless, @rpath).
        if let known = jailbreakOnlyImage(name) { a.fail(.needsJailbreak(known ?? display)); return }
        // iOS's own libraries are never replaced by a package's file.
        if name.hasPrefix("/System/") && !name.contains("/..") && !name.contains("/./") { return }
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
            if let known = knownLibrary(name) { a.fail(.missingDependency(known)); return }
            guard let appFiles = context.appFiles else { return }
            let inApp = prefix == "@rpath/" ? "Frameworks/" + x : x
            if !appFiles(inApp) { a.fail(.missingDependency(display)) }
            return
        }

        guard name.hasPrefix("/") else { a.fail(.missingDependency(display)); return }
        // An absolute path a package ships (with `/var/jb` stripped) is found in its copy.
        let stripped = name.hasPrefix("/var/jb/") ? String(name.dropFirst("/var/jb".count)) : name
        let rel = String(stripped.dropFirst())
        let safe = !rel.isEmpty && !rel.utf8.contains(0)
            && !rel.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." || $0.isEmpty }
        if safe {
            // A rootful package keeps its frameworks in usr/lib, /Library/Frameworks being a
            // symlink to them (Cephei 1.x): either path finds the same file.
            let paths = [rel] + frameworkAlias(rel)
            func file(_ p: TweakPackage) -> String? { paths.first { p.files.contains($0) } }
            if let f = file(package) { use(.own, package, file: f, for: name, conversion: .jailbreakPaths, &a); return }
            for p in others { if let f = file(p) { use(.other, p, file: f, for: name, conversion: .dependency(displayName(p)), &a); return } }
            for p in embedded {
                if let f = file(p) { use(.embedded, p, file: f, for: name, conversion: .dependencyAdded(displayName(p)), &a); return }
            }
        }
        if let known = knownLibrary(name) { a.fail(.missingDependency(known)); return }
        // Outside /usr/lib and /System: a jailbreak's folder. An unknown /usr/lib name: missing.
        if CrashClassifier.isJailbreakPath(name) {
            a.fail(.needsJailbreak(display))
        } else {
            a.fail(.missingDependency(display))
        }
    }

    /// `Library/Frameworks/X.framework/…` ↔ `usr/lib/X.framework/…` (empty for anything else).
    static func frameworkAlias(_ rel: String) -> [String] {
        for (from, to) in [("Library/Frameworks/", "usr/lib/"), ("usr/lib/", "Library/Frameworks/")] where rel.hasPrefix(from) {
            let rest = rel.dropFirst(from.count)
            guard let folder = rest.split(separator: "/").first, folder.hasSuffix(".framework"), rest.contains("/") else { return [] }
            return [to + rest]
        }
        return []
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

/// One tweak's classification for one app and device, computed once.
public struct TweakClassification: Sendable {
    public var verdict: TweakVerdict
    /// What applies once « Injecter quand même » is chosen (filter problem ignored).
    public var verdictOverridingFilter: TweakVerdict
    public var resolution: [String: String]
    /// The embedded packages to copy, in `embedded` order.
    public var providers: [TweakPackage]
}
