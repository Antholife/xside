import Foundation

// Why an app XSide installed crashed, read from the device's crash logs (`.ips`): parsed, matched
// to the installation, classified into a plain cause, and sanitized before anyone sees it.
// The files come from the device: untrusted input. Size-capped, decoded tolerantly (any field may
// be missing or of another type), never trapping.

/// One frame: the image it is in (nil when unknown) and its symbol, if the log has one. `inApp`:
/// the image is inside the app's bundle (the app, its frameworks, an added dylib), not iOS.
public struct CrashFrame: Equatable, Sendable, Codable {
    public var image: String?
    public var symbol: String?
    public var inApp: Bool
    /// Where the image is inside the app's `Frameworks/XSideTweaks/` ("<id>/Alpha.dylib",
    /// "deps/<package id>/…", "ElleKit.dylib"): what XSide put there. nil: elsewhere.
    public var tweakPath: String?

    public init(image: String?, symbol: String?, inApp: Bool, tweakPath: String? = nil) {
        self.image = image
        self.symbol = symbol
        self.inApp = inApp
        self.tweakPath = tweakPath
    }

    /// "UIKitCore  -[UIView layout]".
    public var line: String {
        [image ?? "?", symbol].compactMap { $0 }.joined(separator: "  ")
    }
}

/// A process the memory pressure killed (a `JetsamEvent` report), iOS's reason, and the states
/// the process was in ("frontmost", "suspended", "daemon"…).
public struct JetsamKill: Equatable, Sendable {
    public let name: String
    public let reason: String
    public let states: [String]

    public init(name: String, reason: String, states: [String] = []) {
        self.name = name
        self.reason = reason
        self.states = states
    }

    /// Reasons that mean the process itself went over its own memory limit (not iOS freeing
    /// memory for others: "vm-pageshortage", "fc-thrashing", "idle-exit"…).
    static let ownLimitReasons: Set<String> = ["per-process-limit", "highwater", "memory-limit"]
    /// Reasons iOS writes in a JetsamEvent (anything else is left out of a shared copy).
    static let knownReasons: Set<String> = ownLimitReasons.union(["vm-pageshortage", "vm-thrashing", "fc-thrashing", "idle-exit",
                                                                  "vnode-limit", "zone-map-exhaustion", "jettisoned",
                                                                  "diagnostic", "disk-space-shortage", "swap-shortage",
                                                                  "long-idle-exit", "sustained-memory-pressure"])

    /// The app, in front of the person, went over its memory limit: a real "out of memory" crash.
    /// A suspended or background app evicted to free memory is routine iOS behaviour, not a crash.
    public var isForegroundMemoryLimit: Bool {
        Self.ownLimitReasons.contains(reason) && states.contains("frontmost")
    }
}

/// What XSide reads of a crash log.
public struct CrashLog: Equatable, Sendable {
    public enum Kind: String, Sendable, Codable { case crash, jetsam }
    public var kind: Kind
    public var processName: String?
    public var bundleID: String?
    public var appVersion: String?
    public var date: Date?
    public var exceptionType: String?
    public var exceptionCodes: String?
    public var signal: String?
    public var terminationNamespace: String?
    public var terminationCode: Int64?
    public var terminationIndicator: String?
    public var terminationReasons: [String] = []
    /// The `asi` (application specific information) texts.
    public var asi: [String] = []
    /// The faulting (triggered) thread's top frames.
    public var faultingFrames: [CrashFrame] = []
    /// `lastExceptionBacktrace`: where an uncaught exception was thrown.
    public var exceptionBacktrace: [CrashFrame] = []
    /// JetsamEvent only.
    public var jetsamKills: [JetsamKill] = []
    /// The crash happened while UIKit ran the app delegate's launch methods (didFinishLaunching…),
    /// seen anywhere in the whole backtrace, not only in the top frames kept.
    public var duringLaunch = false

    public init(kind: Kind) { self.kind = kind }
}

/// The installation whose crashes are looked for: its signed bundle id (the App Store copy of the
/// same app has another one) and its `CFBundleExecutable` (the process name; nil when unknown).
public struct CrashTarget: Equatable, Sendable {
    public let signedBundleID: String
    public let executable: String?

    public init(signedBundleID: String, executable: String?) {
        self.signedBundleID = signedBundleID
        self.executable = executable
    }
}

extension CrashLog {
    /// The log is about `target` and dated at or after `since`. A crash goes by its bundle id
    /// (the process name only when it has none); a JetsamEvent by the process name, which it alone
    /// gives. Undated logs never match: "since" couldn't be told.
    public func matches(_ target: CrashTarget, since: Date) -> Bool {
        guard let date, date >= since else { return false }
        switch kind {
        case .crash:
            if let bundleID { return bundleID == target.signedBundleID }
            return target.executable != nil && processName == target.executable
        case .jetsam:
            guard let executable = target.executable else { return false }
            return jetsamKills.contains { $0.name == executable && $0.isForegroundMemoryLimit }
        }
    }
}

public enum CrashLogParser {
    /// Larger files are refused unread (real ones are 30–300 KB).
    public static let maxBytes = 5 * 1024 * 1024
    public static let maxFrames = 12
    public static let maxList = 20
    public static let maxString = 500

    /// The log, or nil when `data` isn't a crash or JetsamEvent report XSide can read. A report
    /// whose body can't be read (cut short) keeps what its header says.
    public static func parse(_ data: Data) -> CrashLog? {
        guard !data.isEmpty, data.count <= maxBytes else { return nil }
        let newline = data.firstIndex(of: 0x0A) ?? data.endIndex
        guard let header = object(data[data.startIndex..<newline]) else { return nil }
        let body = newline < data.endIndex ? object(data[data.index(after: newline)...]) ?? [:] : [:]
        switch string(header["bug_type"]) {
        case "309": return crash(header: header, body: body)
        case "298": return jetsam(header: header, body: body)
        default: return nil
        }
    }

    private static func object(_ data: Data.SubSequence) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(data), options: [])) as? [String: Any]
    }

    private static func crash(header: [String: Any], body: [String: Any]) -> CrashLog {
        var log = CrashLog(kind: .crash)
        let bundleInfo = body["bundleInfo"] as? [String: Any] ?? [:]
        log.processName = string(body["procName"]) ?? string(header["name"]) ?? string(header["app_name"])
        log.bundleID = string(header["bundleID"]) ?? string(bundleInfo["CFBundleIdentifier"])
        log.appVersion = string(bundleInfo["CFBundleShortVersionString"]) ?? string(header["app_version"])
        log.date = date(string(body["captureTime"])) ?? date(string(header["timestamp"]))
        let exception = body["exception"] as? [String: Any] ?? [:]
        log.exceptionType = string(exception["type"])
        log.exceptionCodes = string(exception["codes"])
        log.signal = string(exception["signal"])
        let termination = body["termination"] as? [String: Any] ?? [:]
        log.terminationNamespace = string(termination["namespace"])
        log.terminationCode = integer(termination["code"])
        log.terminationIndicator = string(termination["indicator"])
        log.terminationReasons = strings(termination["reasons"]) + strings(termination["details"])
        log.terminationReasons = Array(log.terminationReasons.prefix(maxList))
        if let asi = body["asi"] as? [String: Any] {
            log.asi = Array(asi.keys.sorted().flatMap { strings(asi[$0]) + [string(asi[$0])].compactMap { $0 } }.prefix(maxList))
        }
        let images = (body["usedImages"] as? [Any] ?? []).map { $0 as? [String: Any] ?? [:] }
        var faulting: Any?
        if let threads = body["threads"] as? [Any] {
            var thread: [String: Any]?
            if let index = integer(body["faultingThread"]), index >= 0, index < threads.count {
                thread = threads[Int(index)] as? [String: Any]
            }
            thread = thread ?? threads.lazy.compactMap { $0 as? [String: Any] }.first { $0["triggered"] as? Bool == true }
            log.faultingFrames = frames(thread?["frames"], images: images)
            faulting = thread?["frames"]
        }
        log.exceptionBacktrace = frames(body["lastExceptionBacktrace"], images: images)
        log.duringLaunch = [body["lastExceptionBacktrace"], faulting].contains { isLaunch($0) }
        return log
    }

    private static func jetsam(header: [String: Any], body: [String: Any]) -> CrashLog {
        var log = CrashLog(kind: .jetsam)
        log.date = date(string(body["date"])) ?? date(string(header["timestamp"]))
        // Every process is listed: only the killed ones (a reason) are kept.
        log.jetsamKills = (body["processes"] as? [Any] ?? []).compactMap { item in
            guard let p = item as? [String: Any], let name = string(p["name"]), let reason = string(p["reason"]) else { return nil }
            return JetsamKill(name: name, reason: reason, states: strings(p["states"]))
        }
        return log
    }

    /// Frames looked at for UIKit's launch methods: deep enough for any real backtrace.
    static let launchScanFrames = 512

    /// UIKit is calling the app delegate's launch methods somewhere in these frames.
    private static func isLaunch(_ value: Any?) -> Bool {
        guard let list = value as? [Any] else { return false }
        let markers = ["-[UIApplication _handleDelegateCallbacksWithOptions:", "-[UIApplication _callInitializationDelegatesWithActions:"]
        return list.prefix(launchScanFrames).contains { item in
            guard let symbol = (item as? [String: Any])?["symbol"] as? String else { return false }
            return markers.contains { symbol.hasPrefix($0) }
        }
    }

    private static func frames(_ value: Any?, images: [[String: Any]]) -> [CrashFrame] {
        guard let list = value as? [Any] else { return [] }
        return list.prefix(maxFrames).map { item in
            let f = item as? [String: Any] ?? [:]
            var image: [String: Any]?
            if let index = integer(f["imageIndex"]), index >= 0, index < images.count { image = images[Int(index)] }
            let path = string(image?["path"])
            let name = string(image?["name"]) ?? path.map { ($0 as NSString).lastPathComponent }
            return CrashFrame(image: name, symbol: string(f["symbol"]), inApp: path.map(isInAppBundle) ?? false,
                              tweakPath: path.flatMap(tweakPath))
        }
    }

    /// The part of `path` under the app's `Frameworks/XSideTweaks/` ("<id>/Alpha.dylib"), when it
    /// is there: in an installed app's bundle, or as `@executable_path/…` / `@rpath/…` says it.
    /// No `.` or `..` component, nothing empty.
    static func tweakPath(_ path: String) -> String? {
        let rest: Substring
        if path.hasPrefix(TweakLayout.loadPrefix) {
            rest = path.dropFirst(TweakLayout.loadPrefix.count)
        } else if path.hasPrefix("@rpath/XSideTweaks/") {
            rest = path.dropFirst("@rpath/XSideTweaks/".count)
        } else if path.contains("/Bundle/Application/"), let range = path.range(of: ".app/" + TweakLayout.folder + "/") {
            rest = path[range.upperBound...]
        } else {
            return nil
        }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return String(rest)
    }

    /// A path inside an installed app's bundle (not iOS's own apps nor libraries).
    static func isInAppBundle(_ path: String) -> Bool {
        path.contains("/Bundle/Application/") || path.hasPrefix("@rpath") || path.hasPrefix("@executable_path")
            || path.hasPrefix("@loader_path")
    }

    /// A string, or a number written as one; cut to `maxString`.
    static func string(_ value: Any?) -> String? {
        let text: String
        if let s = value as? String { text = s } else if let n = number(value) { text = n.stringValue } else { return nil }
        return text.count > maxString ? String(text.prefix(maxString)) + "…" : text
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).prefix(maxList).compactMap { string($0) }
    }

    /// A whole number in Int64's range (JSON numbers can be anything: 1e300, -1, 2.5).
    private static func integer(_ value: Any?) -> Int64? {
        if let s = value as? String {
            return s.lowercased().hasPrefix("0x") ? Int64(s.dropFirst(2), radix: 16) : Int64(s)
        }
        guard let n = number(value) else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), d >= -9.0e18, d <= 9.0e18 else { return nil }
        return n.int64Value
    }

    /// A JSON number, not a boolean (0 and 1 bridged from JSON also pass `is Bool`).
    private static func number(_ value: Any?) -> NSNumber? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n
    }

    /// "2026-11-08 19:34:41.00 +0100" (fraction optional, any length).
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let parts = text.split(separator: " ")
        guard parts.count == 3 else { return nil }
        // "." alone splits into nothing: no clock, no date (never `time[0]`).
        let time = parts[1].split(separator: ".", maxSplits: 1)
        guard let clock = time.first else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        guard let whole = formatter.date(from: "\(parts[0]) \(clock) \(parts[2])") else { return nil }
        guard time.count == 2, time[1].allSatisfy(\.isNumber), let fraction = Double("0." + time[1].prefix(9)) else { return whole }
        return whole.addingTimeInterval(fraction)
    }
}

/// What the classifier needs to know of the installation.
public struct CrashContext: Equatable, Sendable {
    /// XSide's module in the app (`XSideWelcome.dylib`).
    public var moduleName: String
    /// Tweaks XSide injected into it (file names).
    public var tweakNames: Set<String>
    /// Those tweaks' folders in `Frameworks/XSideTweaks/` (`TweakPackage.id`).
    public var tweakIDs: Set<String>
    /// What XSide added so that converted tweaks work: ElleKit, the support library, the image
    /// names of the embedded dependencies (Cephei…).
    public var tweakSupportNames: Set<String>
    /// The injected tweaks' names for people ("Alpha 1.2"), by image name.
    public var tweakLabels: [String: String]
    /// The installation has the iPhone Duo option: its SDK raise is what makes iOS ask for scenes.
    public var duoCompatibilityOn: Bool
    /// The installation has "Simulate signed-out iCloud": an iCloud crash is then one it doesn't cover.
    public var iCloudSignedOutOn: Bool
    /// The injected tweaks' images (of `tweakNames`) whose binaries import C function hooks.
    public var cFunctionHookImages: Set<String> = []

    public init(moduleName: String, tweakNames: Set<String> = [], tweakIDs: Set<String> = [], tweakSupportNames: Set<String> = [],
                tweakLabels: [String: String] = [:], duoCompatibilityOn: Bool = false, iCloudSignedOutOn: Bool = false) {
        self.tweakIDs = tweakIDs
        self.tweakSupportNames = tweakSupportNames
        self.tweakLabels = tweakLabels
        self.iCloudSignedOutOn = iCloudSignedOutOn
        self.moduleName = moduleName
        self.tweakNames = tweakNames
        self.duoCompatibilityOn = duoCompatibilityOn
    }
}

/// The plain cause of a crash; the app words it (`crash.cause.<rawValue>.*`).
public enum CrashCause: String, Codable, Sendable, CaseIterable {
    case noSceneSupport, missingLibrary, missingSymbol, jailbreakLibrary, codeSignature, xsideModule, duoLegacyModule, iCloudShim
    /// The app's own code crashed during launch with the iPhone Duo option on.
    case duoAppLaunch
    case tweak, tweakSupport, bundledLibrary
    /// iOS killed the app for writing into its code (CODESIGNING, invalid page), and an injected
    /// tweak imports C function hooks: that tweak (`subject`, `tweakName`).
    case tweakCFunctionHook
    /// iOS killed the app (namespace TCC) for asking for private data without the usage
    /// description its Info.plist must have: the key iOS named (`subject`, nil when unreadable).
    case missingUsageDescription
    case iCloud, outOfMemory, launchTimeout, hang, other
}

/// A crash, explained: the cause, what it names (`subject`: a library, a symbol, a tweak, the
/// image the crash is in…), and the technical summary for whoever wants it.
public struct CrashDiagnosis: Codable, Equatable, Sendable {
    public var cause: CrashCause
    public var subject: String?
    /// missingSymbol: the library expected to have it.
    public var library: String?
    /// missingLibrary/missingSymbol: the library is the app's own (a framework or a tweak), not iOS's.
    public var inApp: Bool?
    public var duoCompatibilityOn: Bool
    /// The installation had "Simulate signed-out iCloud" on (nil in older crash files: off).
    public var iCloudSignedOutOn: Bool?
    /// tweak: its name for people ("Alpha 1.2"), when XSide knows it (nil in older crash files).
    public var tweakName: String?
    /// tweak/tweakSupport: it crashed running a shell command (`/var/jb/bin/sh`…), which an app
    /// can't do without a jailbreak. nil: not seen (or older crash files).
    public var shellCommand: Bool?
    public var date: Date?
    public var appVersion: String?
    public var exceptionType: String?
    public var signal: String?
    public var termination: String?
    public var topFrames: [String]
    /// The log shows it stopped while UIKit ran the app's launch (`CrashLog.duringLaunch`). nil:
    /// not seen (or older crash files).
    public var duringLaunch: Bool?

    /// It stopped at launch: the log says so, or the cause only ever happens then (a missing
    /// library or symbol, no scene support, the launch watchdog). What lets a notice say « au
    /// lancement » (mega review K3).
    public var isLaunchCrash: Bool {
        if duringLaunch == true { return true }
        switch cause {
        case .noSceneSupport, .missingLibrary, .missingSymbol, .jailbreakLibrary, .launchTimeout, .duoAppLaunch: return true
        default: return false
        }
    }

    /// missingUsageDescription: what the key is about, for the wording (`crash.usage.<topic>`):
    /// "camera", "appleMusic"… nil: no key, or one XSide has no plain words for.
    public var usageTopic: String? {
        guard cause == .missingUsageDescription, let subject else { return nil }
        return CrashClassifier.usageTopic(subject)
    }

    /// missingUsageDescription: the key is one the iPhone Duo option adds when the app links the
    /// framework that leads to it (`DuoCompatibility.usageDescriptionsByFramework`).
    public var xsideAddsUsageDescription: Bool {
        guard cause == .missingUsageDescription, let subject else { return false }
        return DuoCompatibility.usageDescriptionsByFramework.values.contains { $0.contains(subject) }
    }

    public init(cause: CrashCause, subject: String? = nil, library: String? = nil, inApp: Bool? = nil,
                duoCompatibilityOn: Bool = false, date: Date? = nil, appVersion: String? = nil,
                exceptionType: String? = nil, signal: String? = nil, termination: String? = nil, topFrames: [String] = []) {
        self.cause = cause
        self.subject = subject
        self.library = library
        self.inApp = inApp
        self.duoCompatibilityOn = duoCompatibilityOn
        self.date = date
        self.appVersion = appVersion
        self.exceptionType = exceptionType
        self.signal = signal
        self.termination = termination
        self.topFrames = topFrames
    }

    /// One line for logs and reports: "noSceneSupport (EXC_BREAKPOINT SIGTRAP) UIKitCore".
    public var summary: String {
        var text = cause.rawValue
        let technical = [exceptionType, signal].compactMap { $0 }.joined(separator: " ")
        if !technical.isEmpty { text += " (\(technical))" }
        if let subject { text += " \(subject)" }
        return text
    }
}

public enum CrashClassifier {
    /// The most specific cause first: what the log states outright (memory, a missing library,
    /// the signature, a watchdog), then where it crashed.
    public static func classify(_ log: CrashLog, context: CrashContext) -> CrashDiagnosis {
        var d = CrashDiagnosis(cause: .other, duoCompatibilityOn: context.duoCompatibilityOn, date: log.date,
                               appVersion: log.appVersion, exceptionType: log.exceptionType, signal: log.signal,
                               termination: [log.terminationNamespace, log.terminationIndicator].compactMap { $0 }
                                   .joined(separator: ": ").nilIfEmpty,
                               topFrames: (log.exceptionBacktrace.isEmpty ? log.faultingFrames : log.exceptionBacktrace)
                                   .prefix(6).map(\.line))
        if log.duringLaunch { d.duringLaunch = true }
        if log.kind == .jetsam {
            d.cause = .outOfMemory
            d.subject = (log.jetsamKills.first(where: \.isForegroundMemoryLimit) ?? log.jetsamKills.first)?.reason
            return d
        }
        let frames = log.exceptionBacktrace + log.faultingFrames
        let texts = log.terminationReasons + log.asi + [log.terminationIndicator].compactMap { $0 }

        if frames.contains(where: { $0.symbol?.contains("_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption") == true })
            || texts.contains(where: { $0.contains("UIScene lifecycle") }) {
            d.cause = .noSceneSupport
            return d
        }
        // iOS's privacy checks (TCC) killed it: a usage description is missing. The key comes
        // from the device's text: kept only when it reads as one.
        if log.terminationNamespace?.uppercased() == "TCC" {
            d.cause = .missingUsageDescription
            d.subject = texts.lazy.compactMap(usageDescriptionKey).first
            return d
        }
        if let missing = dyldProblem(log, texts: texts) {
            d.cause = missing.cause
            d.subject = missing.subject
            d.library = missing.library
            d.inApp = missing.inApp
            return d
        }
        let namespace = log.terminationNamespace?.uppercased()
        let launchConstraint = texts.contains(where: { $0.localizedCaseInsensitiveContains("Launch Constraint Violation") })
        let invalidPage = log.terminationIndicator?.localizedCaseInsensitiveContains("Invalid Page") == true
        if namespace == "CODESIGNING" || invalidPage || launchConstraint {
            // A C function hook patches the app's code: stock iOS kills it at the patched page
            // (seen on iOS 27.3). Only that fault names the tweak; another signature kill (a
            // profile expired or revoked) is the signature (mega review K4).
            let hooking = context.cFunctionHookImages.intersection(context.tweakNames).sorted()
            if !launchConstraint, invalidPage, let image = hooking.first {
                d.cause = .tweakCFunctionHook
                d.subject = image
                d.tweakName = context.tweakLabels[image]
                return d
            }
            d.cause = .codeSignature
            return d
        }
        if log.terminationCode == 0x8BADF00D || texts.contains(where: { $0.localizedCaseInsensitiveContains("8badf00d") }) {
            let launch = texts.contains { t in ["scene-create", "scene-update", "launch"].contains { t.localizedCaseInsensitiveContains($0) } }
            d.cause = launch ? .launchTimeout : .hang
            return d
        }
        let stack = log.exceptionBacktrace.isEmpty ? log.faultingFrames : log.exceptionBacktrace
        // A trap inside CloudKit itself: the app uses iCloud, which XSide doesn't give apps.
        if stack.first?.image == "CloudKit", log.exceptionType == "EXC_BREAKPOINT" || !log.exceptionBacktrace.isEmpty {
            d.cause = .iCloud
            d.iCloudSignedOutOn = context.iCloudSignedOutOn ? true : nil
            return d
        }
        // The app's own code stopped while its delegate finished launching, with the iPhone Duo
        // option on: iOS connects no scene before that, which old apps don't expect (Plague Inc.
        // reads `windows[0]`, empty then). The option is the likely cause.
        if context.duoCompatibilityOn, log.duringLaunch, let first = stack.first(where: \.inApp),
           first.image != nil, first.image == log.processName {
            d.cause = .duoAppLaunch
            d.subject = first.image
            return d
        }
        // The app-side code closest to the crash.
        if let owner = stack.first(where: \.inApp)?.image {
            d.subject = owner
            if owner == context.moduleName {
                d.cause = .xsideModule
            } else if owner == DuoCompatibility.legacyDylibName {
                // The iPhone Duo option's module for apps without scenes.
                d.cause = .duoLegacyModule
            } else if owner == ICloudSignedOut.dylibName {
                // "Simulate signed-out iCloud"'s library: XSide added it, not the .ipa.
                d.cause = .iCloudShim
                d.iCloudSignedOutOn = true
            } else if let place = stack.first(where: \.inApp)?.tweakPath, isTweakSupport(owner, at: place, context) {
                // ElleKit, the support library or an embedded dependency, in XSide's folder and
                // recorded by the last signing: added for the converted tweaks, which call into it.
                d.cause = .tweakSupport
            } else if let place = stack.first(where: \.inApp)?.tweakPath, isTweak(owner, at: place, context) {
                d.cause = .tweak
                d.tweakName = context.tweakLabels[owner]
            } else if owner.hasSuffix(".dylib") {
                d.cause = .bundledLibrary
            }
            if d.cause == .tweak || d.cause == .tweakSupport, stack.prefix(shellFrames).contains(where: isShellCommand) {
                d.shellCommand = true
            }
            return d
        }
        d.subject = stack.first(where: { $0.image != nil })?.image
        return d
    }

    /// "…must contain an NSAppleMusicUsageDescription key…" → "NSAppleMusicUsageDescription":
    /// letters only, a capital first, at most 80 before "UsageDescription".
    static func usageDescriptionKey(_ text: String) -> String? {
        for word in text.split(whereSeparator: { !$0.isLetter || !$0.isASCII }) where word.hasSuffix("UsageDescription") {
            let stem = word.dropLast("UsageDescription".count)
            guard (2...80).contains(stem.count), stem.first?.isUppercase == true else { continue }
            return String(word)
        }
        return nil
    }

    /// The plain topic of a usage description key (`crash.usage.<topic>`).
    static let usageTopics: [String: String] = [
        "NSAppleMusicUsageDescription": "appleMusic", "NSCameraUsageDescription": "camera",
        "NSMicrophoneUsageDescription": "microphone", "NSPhotoLibraryUsageDescription": "photos",
        "NSPhotoLibraryAddUsageDescription": "photos", "NSSpeechRecognitionUsageDescription": "speech",
        "NSSiriUsageDescription": "siri", "NSHealthShareUsageDescription": "health", "NSHealthUpdateUsageDescription": "health",
        "NSFaceIDUsageDescription": "faceID", "NSLocationWhenInUseUsageDescription": "location",
        "NSLocationAlwaysAndWhenInUseUsageDescription": "location", "NSLocationAlwaysUsageDescription": "location",
        "NSLocationUsageDescription": "location", "NSContactsUsageDescription": "contacts",
        "NSCalendarsUsageDescription": "calendars", "NSCalendarsFullAccessUsageDescription": "calendars",
        "NSCalendarsWriteOnlyAccessUsageDescription": "calendars", "NSRemindersUsageDescription": "reminders",
        "NSRemindersFullAccessUsageDescription": "reminders", "NSBluetoothAlwaysUsageDescription": "bluetooth",
        "NSBluetoothPeripheralUsageDescription": "bluetooth", "NSMotionUsageDescription": "motion",
        "NSLocalNetworkUsageDescription": "localNetwork", "NSUserTrackingUsageDescription": "tracking",
        "NSHomeKitUsageDescription": "homeKit",
    ]

    static func usageTopic(_ key: String) -> String? { usageTopics[key] }

    /// Top frames of the crashing stack looked at for a shell command.
    static let shellFrames = 6

    /// Symbols of running a shell command: Cephei's `HBOutputForShellCommand` (`/var/jb/bin/sh`),
    /// NSTask's launch methods, `posix_spawn`, `system`, `popen`.
    private static func isShellCommand(_ frame: CrashFrame) -> Bool {
        guard let symbol = frame.symbol else { return false }
        if symbol.contains("HBOutputForShellCommand") { return true }
        if symbol.hasPrefix("-[NSTask launch") || symbol.hasPrefix("-[NSConcreteTask launch")
            || symbol.hasPrefix("+[NSTask launchedTask") { return true }
        return ["posix_spawn", "posix_spawnp", "system", "popen", "_system", "_popen"].contains(symbol)
    }

    /// XSide's ElleKit or support library (at the folder's top), or an embedded dependency
    /// (under `deps/`), that the last signing recorded.
    private static func isTweakSupport(_ image: String, at place: String, _ context: CrashContext) -> Bool {
        guard context.tweakSupportNames.contains(image) else { return false }
        if place == image { return image == TweakLayout.elleKitName || image == TweakLayout.supportName }
        return place.hasPrefix(TweakLayout.depsFolder + "/")
    }

    /// A tweak the last signing injected, in its own folder (`<id>/…`).
    private static func isTweak(_ image: String, at place: String, _ context: CrashContext) -> Bool {
        let parts = place.split(separator: "/")
        guard parts.count >= 2, let folder = parts.first, folder != Substring(TweakLayout.depsFolder),
              context.tweakNames.contains(image) else { return false }
        return context.tweakIDs.contains(String(folder))
    }

    /// dyld refused to start the app: a library or a symbol it needs isn't there.
    private static func dyldProblem(_ log: CrashLog, texts: [String])
        -> (cause: CrashCause, subject: String?, library: String?, inApp: Bool?)? {
        let isDyld = log.terminationNamespace?.uppercased() == "DYLD"
        if let line = texts.first(where: { $0.contains("Library not loaded:") }) {
            let path = after("Library not loaded:", in: line).components(separatedBy: " ").first ?? ""
            // A tweak's hooking library (Substrate, ElleKit…): only jailbroken devices have it.
            if isJailbreakPath(path) { return (.jailbreakLibrary, libraryName(path), nil, false) }
            return (.missingLibrary, libraryName(path), nil, CrashLogParser.isInAppBundle(path) || path.contains(".app/"))
        }
        if let line = texts.first(where: { $0.contains("Symbol not found:") }) {
            let symbol = after("Symbol not found:", in: line).components(separatedBy: " ").first ?? ""
            // "Expected in: <UUID> /path/lib" (or the older "Expected in: /path/lib").
            let expected = texts.first { $0.contains("Expected in:") }
                .map { after("Expected in:", in: $0).components(separatedBy: " ").last ?? "" }
            let library = expected.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
            let inApp = expected.map { CrashLogParser.isInAppBundle($0) || $0.contains(".app/") } ?? false
            if let expected, isJailbreakPath(expected) {
                return (.jailbreakLibrary, libraryName(expected), nil, false)
            }
            return (.missingSymbol, symbol.isEmpty ? "?" : symbol, library, inApp)
        }
        // dyld stopped it without naming what's missing ("Library missing" is the kind, not a
        // name): a generic wording, nothing named.
        if isDyld {
            return (.missingLibrary, nil, nil, nil)
        }
        return nil
    }

    /// Where jailbreaks put tweaks' libraries (Substrate, Substitute, libhooker, ElleKit,
    /// TweakInject, rootless `/var/jb`…). Stock iOS has its libraries only under /System and
    /// /usr/lib, so any other absolute path (/Library/MobileSubstrate, /Library/Frameworks…) is a
    /// jailbreak's too.
    private static let jailbreakMarkers = ["/var/jb/", "cydiasubstrate", "mobilesubstrate", "libsubstrate", "substrate.dylib",
                                           "libsubstitute", "ellekit", "tweakinject", "libhooker", "libblackjack"]

    static func isJailbreakPath(_ path: String) -> Bool {
        // The app's own files (@rpath…, its container) and iOS's are never the jailbreak's.
        if CrashLogParser.isInAppBundle(path) || path.hasPrefix("/System/") || path.hasPrefix("/Developer/") { return false }
        let lower = path.lowercased()
        if jailbreakMarkers.contains(where: { lower.contains($0) }) { return true }
        return path.hasPrefix("/") && !path.hasPrefix("/usr/lib/")
    }

    private static func after(_ marker: String, in line: String) -> String {
        guard let range = line.range(of: marker) else { return "" }
        return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    /// "@rpath/Sparkle.framework/Sparkle" → "Sparkle.framework"; "/usr/lib/libz.dylib" → "libz.dylib".
    static func libraryName(_ path: String) -> String {
        let clean = path.components(separatedBy: " ").first ?? path
        let parts = clean.split(separator: "/")
        if let framework = parts.last(where: { $0.hasSuffix(".framework") }) { return String(framework) }
        return parts.last.map(String.init) ?? (clean.isEmpty ? "?" : clean)
    }
}

/// A crash log made fit to share: what identifies the person, the device or the Apple account is
/// replaced by placeholders. The exception, frames and image names stay.
public enum CrashLogSanitizer {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Fields whose value is the device's, the person's or the account's.
    private static let fields = regex(#""(ecid|uniqueChipID|serialNumber|imei|meid|udid|crashReporterKey|deviceIdentifierForVendor|codeSigningTeamID|bootSessionUUID|userID|incident|incident_id|basebandVersion|itemID|adam_id|storeCohortMetadata|softwareVersionExternalIdentifier|parentProc|coalitionName)"(\s*):(\s*)("(?:[^"\\]|\\.)*"|-?[0-9]+)"#)
    private static let rules: [(NSRegularExpression, String)] = [
        (regex(#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#), "<email>"),
        (regex(#"/Users/[^/\s"]+"#), "/Users/<user>"),
        // A binary's UUID ("uuid", "slice_uuid", "UUID") is what symbolication needs and says
        // nothing of the person: kept. Any other UUID (containers, device, sessions) is masked.
        (regex(#"(?<!"(?:slice_)?uuid"\s{0,4}:\s{0,4}")\b[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\b"#), "<uuid>"),
        (regex(#"\b[0-9A-F]{8}-[0-9A-F]{16}\b"#), "<udid>"),
        (regex(#"\b[0-9A-F]{40}\b"#), "<id>"),
    ]

    /// `secrets`: exact values to hide as well (the team id, the device's id and name…).
    public static func sanitize(_ text: String, secrets: [String] = []) -> String {
        var out = text
        for secret in secrets.filter({ $0.count >= 4 }).sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: secret, with: "<redacted>")
        }
        out = fields.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: "\"$1\"$2:$3\"<redacted>\"")
        for (rule, placeholder) in rules {
            out = rule.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: placeholder)
        }
        return out
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
