import Testing
import Foundation
@testable import XSideCore

/// Synthetic `.ips` files, built here: no real crash log of a third-party app is committed.
enum IPS {
    static let appPath = "/private/var/containers/Bundle/Application/11111111-2222-3333-4444-555555555555/Demo.app"

    static func image(_ name: String, path: String? = nil, source: String = "P") -> [String: Any] {
        ["name": name, "path": path ?? "\(appPath)/\(name)", "source": source, "arch": "arm64"]
    }

    static var systemImages: [[String: Any]] { [
        image("UIKitCore", path: "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore"),
        image("CoreFoundation", path: "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"),
        image("libobjc.A.dylib", path: "/usr/lib/libobjc.A.dylib"),
        image("CloudKit", path: "/System/Library/Frameworks/CloudKit.framework/CloudKit"),
    ] }

    /// Images: 0 the app, 1 XSide's module, 2 a tweak dylib, 3 an app framework, then `systemImages` (4…).
    static var images: [[String: Any]] { [
        image("Demo", path: "\(appPath)/Demo"),
        image("XSideWelcome.dylib", path: "\(appPath)/Frameworks/XSideWelcome.dylib"),
        image("uTweak.dylib", path: "\(appPath)/Frameworks/uTweak.dylib"),
        image("Kit", path: "\(appPath)/Frameworks/Kit.framework/Kit"),
    ] + systemImages }

    static let uikit = 4, coreFoundation = 5, objc = 6, cloudKit = 7

    static func frame(_ image: Int, _ symbol: String? = nil) -> [String: Any] {
        var f: [String: Any] = ["imageIndex": image, "imageOffset": 1234]
        if let symbol { f["symbol"] = symbol }
        return f
    }

    static func crash(name: String = "Demo", bundleID: String? = "com.example.demo.TEAM1",
                      timestamp: String = "2026-11-09 10:00:00.00 +0100",
                      exception: [String: Any]? = ["type": "EXC_CRASH", "signal": "SIGABRT", "codes": "0x0, 0x0"],
                      termination: [String: Any]? = ["namespace": "SIGNAL", "code": 6, "indicator": "Abort trap: 6"],
                      frames: [[String: Any]] = [frame(0, "main")],
                      lastException: [[String: Any]]? = nil, asi: [String: Any]? = nil,
                      images: [[String: Any]] = images, extra: [String: Any] = [:]) -> Data {
        var header: [String: Any] = ["app_name": name, "name": name, "timestamp": timestamp, "bug_type": "309",
                                     "os_version": "iPhone OS 27.3 (24C5037i)"]
        if let bundleID { header["bundleID"] = bundleID }
        var body: [String: Any] = ["procName": name, "captureTime": timestamp.replacingOccurrences(of: ".00 ", with: ".1234 "),
                                   "faultingThread": 0,
                                   "threads": [["triggered": true, "frames": frames]],
                                   "usedImages": images,
                                   "crashReporterKey": String(repeating: "ab", count: 20)]
        if let bundleID { body["bundleInfo"] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": "1.0"] }
        if let exception { body["exception"] = exception }
        if let termination { body["termination"] = termination }
        if let lastException { body["lastExceptionBacktrace"] = lastException }
        if let asi { body["asi"] = asi }
        body.merge(extra) { $1 }
        return join(header, body)
    }

    static func jetsam(timestamp: String = "2026-11-09 10:00:00.00 +0100", processes: [[String: Any]],
                       extra: [String: Any] = [:]) -> Data {
        join(["bug_type": "298", "timestamp": timestamp, "os_version": "iPhone OS 27.3"],
             ["date": timestamp, "processes": processes, "crashReporterKey": String(repeating: "cd", count: 20)]
                .merging(extra) { $1 })
    }

    static func join(_ header: [String: Any], _ body: [String: Any]) -> Data {
        let h = try! JSONSerialization.data(withJSONObject: header)
        let b = try! JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted])
        return h + Data("\n".utf8) + b
    }
}

private let context = CrashContext(moduleName: "XSideWelcome.dylib")

private func diagnose(_ data: Data, _ ctx: CrashContext = context) throws -> CrashDiagnosis {
    let log = try #require(CrashLogParser.parse(data))
    return CrashClassifier.classify(log, context: ctx)
}

@Suite struct CrashLogParserTests {
    @Test func readsTheHeaderAndBody() throws {
        let log = try #require(CrashLogParser.parse(IPS.crash(
            exception: ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "codes": "0x1, 0x8"],
            frames: [IPS.frame(IPS.uikit, "-[UIView layout]"), IPS.frame(0)])))
        #expect(log.kind == .crash)
        #expect(log.processName == "Demo")
        #expect(log.bundleID == "com.example.demo.TEAM1")
        #expect(log.appVersion == "1.0")
        #expect(log.exceptionType == "EXC_BAD_ACCESS")
        #expect(log.signal == "SIGSEGV")
        #expect(log.terminationNamespace == "SIGNAL")
        #expect(log.faultingFrames.first == CrashFrame(image: "UIKitCore", symbol: "-[UIView layout]", inApp: false))
        #expect(log.faultingFrames.last == CrashFrame(image: "Demo", symbol: nil, inApp: true))
        // 10:00:00.1234 +01:00
        let date = try #require(log.date)
        #expect(abs(date.timeIntervalSince1970 - 1_794_214_800.1234) < 0.001)
    }

    @Test func readsJetsamEvents() throws {
        let log = try #require(CrashLogParser.parse(IPS.jetsam(processes: [
            ["name": "healthappd", "reason": "per-process-limit"], ["name": "Demo", "reason": "highwater"], ["name": "idle"],
        ])))
        #expect(log.kind == .jetsam)
        #expect(log.jetsamKills == [JetsamKill(name: "healthappd", reason: "per-process-limit"),
                                    JetsamKill(name: "Demo", reason: "highwater")])
        #expect(log.date != nil)
    }

    @Test func refusesWhatIsTooBig() {
        var data = IPS.crash()
        data.append(Data(repeating: 0x20, count: CrashLogParser.maxBytes))
        #expect(CrashLogParser.parse(data) == nil)
    }

    @Test func aTruncatedBodyKeepsTheHeader() throws {
        let full = IPS.crash()
        let cut = full.prefix(full.firstIndex(of: 0x0A)! + 40)
        let log = try #require(CrashLogParser.parse(Data(cut)))
        #expect(log.processName == "Demo")
        #expect(log.bundleID == "com.example.demo.TEAM1")
        #expect(log.exceptionType == nil)
        #expect(CrashClassifier.classify(log, context: context).cause == .other)
    }

    @Test func survivesHostileInput() {
        let hostile: [Data] = [
            Data(), Data("\n".utf8), Data("not json\n{}".utf8), Data("[1,2]\n{}".utf8),
            Data([0xFF, 0xFE, 0x00, 0x0A, 0xC3, 0x28]),
            Data((String(repeating: "[", count: 100_000) + "\n").utf8),
            IPS.join(["bug_type": "309"], ["exception": 5, "termination": "x", "threads": "nope", "usedImages": 3,
                                          "faultingThread": 99_999, "asi": [1, 2]]),
            IPS.join(["bug_type": "309", "name": 42], ["faultingThread": -1, "threads": [["frames": [
                ["imageIndex": -1], ["imageIndex": Int.max], ["imageIndex": 1e300], ["imageIndex": "0"], "frame", NSNull(),
            ]]], "usedImages": [NSNull(), ["name": 7]]]),
            IPS.join(["bug_type": "309"], ["termination": ["code": 1e300, "reasons": [1, ["x"], "ok"]],
                                          "lastExceptionBacktrace": [["imageIndex": 0]], "usedImages": []]),
            IPS.join(["bug_type": "298"], ["processes": [["name": NSNull(), "reason": 3], 5, "x"]]),
            // Dates whose clock part is only dots, empty or odd: once a trap (review Critical 1).
            IPS.join(["bug_type": "309", "timestamp": "2026-11-08 . +0100"], ["captureTime": "2026-11-08 . +0100"]),
            IPS.join(["bug_type": "309", "timestamp": "2026-11-08 .5 +0100"], ["captureTime": "2026-11-08 ... +0100"]),
            IPS.join(["bug_type": "298", "timestamp": ". . ."], ["date": "  . "]),
        ]
        for data in hostile {
            if let log = CrashLogParser.parse(data) { _ = CrashClassifier.classify(log, context: context) }
        }
    }

    @Test func datesNeverTrap() {
        for text in ["2026-11-08 . +0100", "2026-11-08 .. +0100", "2026-11-08 .5 +0100", "2026-11-08 10:00:00. +0100",
                     ". . .", "  ", "a b c", "2026-11-08 10:00:00.x +0100", "2026-11-08 10:00:00.\u{0663} +0100"] {
            _ = CrashLogParser.date(text)
        }
        #expect(CrashLogParser.date("2026-11-08 . +0100") == nil)
        #expect(CrashLogParser.date("2026-11-08 10:00:00. +0100") != nil)
        var rng = SeededGenerator(seed: 7)
        let alphabet = Array("0123456789 .:+-Z")
        for _ in 0..<3_000 {
            let length = Int.random(in: 0...30, using: &rng)
            _ = CrashLogParser.date(String((0..<length).map { _ in alphabet.randomElement(using: &rng)! }))
        }
    }

    /// Cut and mutated copies of every kind of synthetic log: the parser and the classifier may
    /// refuse them, never trap.
    @Test func fuzzedLogsNeverTrap() {
        let seeds: [Data] = [
            IPS.crash(frames: [IPS.frame(IPS.uikit, "x"), IPS.frame(0), IPS.frame(1)], lastException: [IPS.frame(2), IPS.frame(99)],
                      asi: ["libdyld": ["Library not loaded: /var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"]]),
            IPS.crash(termination: ["namespace": "DYLD", "code": 1, "indicator": "Symbol missing",
                                    "details": ["Symbol not found: _x", "Expected in: <UUID> /usr/lib/libz.dylib"]]),
            IPS.crash(exception: ["type": "EXC_CRASH", "signal": "SIGKILL"],
                      termination: ["namespace": "FRONTBOARD", "code": 2_343_432_205, "reasons": ["scene-create watchdog"]]),
            IPS.jetsam(processes: [["name": "Demo", "reason": "per-process-limit", "states": ["active", "frontmost"]],
                                   ["name": "Other", "states": ["suspended"]]]),
        ]
        var rng = SeededGenerator(seed: 42)
        let noise = Array("{}[]\":,.0123456789 -+ex\n\\".utf8)
        for seed in seeds {
            let bytes = [UInt8](seed)
            // Every cut, from 1 byte to the whole file.
            for length in stride(from: 0, through: bytes.count, by: 3) {
                if let log = CrashLogParser.parse(Data(bytes.prefix(length))) { _ = CrashClassifier.classify(log, context: context) }
            }
            for _ in 0..<400 {
                var mutated = bytes
                for _ in 0..<Int.random(in: 1...8, using: &rng) where !mutated.isEmpty {
                    let at = Int.random(in: 0..<mutated.count, using: &rng)
                    switch Int.random(in: 0..<3, using: &rng) {
                    case 0: mutated[at] = noise.randomElement(using: &rng)!
                    case 1: mutated.removeSubrange(at..<min(mutated.count, at + Int.random(in: 1...40, using: &rng)))
                    default: mutated.insert(noise.randomElement(using: &rng)!, at: at)
                    }
                }
                if let log = CrashLogParser.parse(Data(mutated)) { _ = CrashClassifier.classify(log, context: context) }
            }
        }
    }

    @Test func capsLongStringsAndLists() throws {
        let long = String(repeating: "x", count: 2_000)
        let frames = (0..<1_000).map { _ in IPS.frame(0, long) }
        let log = try #require(CrashLogParser.parse(IPS.crash(termination: ["namespace": long, "reasons": Array(repeating: long, count: 500)],
                                                             frames: frames)))
        #expect(log.faultingFrames.count <= CrashLogParser.maxFrames)
        #expect(log.faultingFrames.allSatisfy { ($0.symbol?.count ?? 0) <= CrashLogParser.maxString + 1 })
        #expect(log.terminationReasons.count <= CrashLogParser.maxList)
        #expect((log.terminationNamespace?.count ?? 0) <= CrashLogParser.maxString + 1)
    }

    @Test func ignoresOtherReports() {
        #expect(CrashLogParser.parse(IPS.join(["bug_type": "145"], ["foo": 1])) == nil)
    }
}

@Suite struct CrashClassifierTests {
    @Test func sceneTrap() throws {
        let data = IPS.crash(exception: ["type": "EXC_BREAKPOINT", "signal": "SIGTRAP"],
                             frames: [IPS.frame(IPS.uikit, "___UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption_block_invoke"),
                                      IPS.frame(IPS.uikit, "-[UIApplication workspace:didCreateScene:]")])
        let plain = try diagnose(data)
        #expect(plain.cause == .noSceneSupport)
        #expect(plain.duoCompatibilityOn == false)
        let duo = try diagnose(data, CrashContext(moduleName: "XSideWelcome.dylib", duoCompatibilityOn: true))
        #expect(duo.cause == .noSceneSupport)
        #expect(duo.duoCompatibilityOn)
    }

    @Test func missingLibraryOfTheApp() throws {
        let d = try diagnose(IPS.crash(exception: ["type": "EXC_CRASH", "signal": "SIGABRT"],
                                       termination: ["namespace": "DYLD", "code": 1, "indicator": "Library missing",
                                                     "reasons": ["Library not loaded: @rpath/Sparkle.framework/Sparkle",
                                                                 "Referenced from: <UUID> /private/var/.../Demo.app/Demo",
                                                                 "Reason: tried: '/x/Sparkle' (no such file)"]],
                                       frames: []))
        #expect(d.cause == .missingLibrary)
        #expect(d.subject == "Sparkle.framework")
        #expect(d.inApp == true)
    }

    @Test func missingLibraryOfIOS() throws {
        let d = try diagnose(IPS.crash(termination: ["namespace": "DYLD", "indicator": "Library missing",
                                                     "details": ["Library not loaded: /System/Library/Frameworks/FooKit.framework/FooKit"]],
                                       frames: []))
        #expect(d.cause == .missingLibrary)
        #expect(d.subject == "FooKit.framework")
        #expect(d.inApp == false)
    }

    /// A library only jailbroken devices have (a tweak's hooking library): never "update iOS".
    @Test func jailbreakLibraries() throws {
        let cases: [(String, String)] = [
            ("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", "CydiaSubstrate.framework"),
            ("/Library/MobileSubstrate/DynamicLibraries/Foo.dylib", "Foo.dylib"),
            ("/usr/lib/libsubstrate.dylib", "libsubstrate.dylib"),
            ("/usr/lib/libellekit.dylib", "libellekit.dylib"),
            ("/var/jb/usr/lib/libellekit.dylib", "libellekit.dylib"),
            ("/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", "CydiaSubstrate.framework"),
            ("/usr/lib/TweakInject/Foo.dylib", "Foo.dylib"),
            ("/usr/lib/libsubstitute.dylib", "libsubstitute.dylib"),
            ("/usr/lib/libhooker.dylib", "libhooker.dylib"),
            ("/Library/Frameworks/Cephei.framework/Cephei", "Cephei.framework"),
        ]
        for (path, name) in cases {
            let d = try diagnose(IPS.crash(termination: ["namespace": "DYLD", "indicator": "Library missing",
                                                         "details": ["Library not loaded: \(path)",
                                                                     "Referenced from: <UUID> /x/Demo.app/Frameworks/uTweak.dylib"]],
                                           frames: []))
            #expect(d.cause == .jailbreakLibrary, "\(path)")
            #expect(d.subject == name, "\(path)")
        }
        // A symbol expected in one: the same.
        let symbol = try diagnose(IPS.crash(termination: ["namespace": "DYLD", "indicator": "Symbol missing",
                                                          "details": ["Symbol not found: _MSHookFunction",
                                                                      "Expected in: <UUID> /usr/lib/libsubstrate.dylib"]],
                                            frames: []))
        #expect(symbol.cause == .jailbreakLibrary)
        #expect(symbol.subject == "libsubstrate.dylib")
        // iOS's own /usr/lib stays iOS's.
        let ios = try diagnose(IPS.crash(termination: ["namespace": "DYLD", "details": ["Library not loaded: /usr/lib/libswiftFoo.dylib"]],
                                         frames: []))
        #expect(ios.cause == .missingLibrary)
        #expect(ios.inApp == false)
    }

    /// dyld stopped the app but says neither which library nor which symbol: nothing is named.
    @Test func dyldWithoutDetails() throws {
        let d = try diagnose(IPS.crash(termination: ["namespace": "DYLD", "code": 1, "indicator": "Library missing"], frames: []))
        #expect(d.cause == .missingLibrary)
        #expect(d.subject == nil)
        #expect(d.inApp == nil)
    }

    @Test func missingSymbol() throws {
        let d = try diagnose(IPS.crash(termination: ["namespace": "DYLD", "indicator": "Symbol missing",
                                                     "reasons": ["Symbol not found: _OBJC_CLASS_$_UIFancyView",
                                                                 "Referenced from: <UUID> /x/Demo.app/Demo",
                                                                 "Expected in: <UUID> /System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore"]],
                                       frames: []))
        #expect(d.cause == .missingSymbol)
        #expect(d.subject == "_OBJC_CLASS_$_UIFancyView")
        #expect(d.library == "UIKitCore")
        #expect(d.inApp == false)
    }

    @Test func codeSigning() throws {
        let d = try diagnose(IPS.crash(exception: ["type": "EXC_BAD_ACCESS", "signal": "SIGKILL", "subtype": "UNKNOWN_0x32 at 0x1"],
                                       termination: ["namespace": "CODESIGNING", "code": 2, "indicator": "Invalid Page"]))
        #expect(d.cause == .codeSignature)
    }

    @Test func xsideModuleUnderAnException() throws {
        let d = try diagnose(IPS.crash(frames: [IPS.frame(IPS.objc, "__abort_with_payload")],
                                       lastException: [IPS.frame(IPS.coreFoundation, "__exceptionPreprocess"),
                                                       IPS.frame(IPS.objc, "objc_exception_throw"),
                                                       IPS.frame(1), IPS.frame(0, "main")]))
        #expect(d.cause == .xsideModule)
        #expect(d.subject == "XSideWelcome.dylib")
    }

    /// A crash in the iPhone Duo option's module (apps without scenes): named, and the fix is
    /// reinstalling without the option.
    @Test func duoCompatibilityModule() throws {
        let images = IPS.images + [IPS.image("XSideDuoLegacy.dylib", path: "\(IPS.appPath)/Frameworks/XSideDuoLegacy.dylib")]
        let legacy = IPS.images.count
        let d = try diagnose(IPS.crash(exception: ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "codes": "0x1, 0x0"],
                                       termination: ["namespace": "SIGNAL", "code": 11, "indicator": "Segmentation fault: 11"],
                                       frames: [IPS.frame(legacy, "XSAttach"), IPS.frame(IPS.uikit), IPS.frame(0, "main")],
                                       images: images),
                             CrashContext(moduleName: "XSideWelcome.dylib", duoCompatibilityOn: true))
        #expect(d.cause == .duoLegacyModule)
        #expect(d.subject == "XSideDuoLegacy.dylib")
        #expect(CrashAction.suggested(for: d) == .turnOffDuo)
    }

    /// A crash in "Simulate signed-out iCloud"'s library: XSide's, not the .ipa's (morning review
    /// I1), and the fix is reinstalling without the option.
    @Test func iCloudSignedOutLibrary() throws {
        let images = IPS.images + [IPS.image("XSideICloud.dylib", path: "\(IPS.appPath)/Frameworks/XSideICloud.dylib")]
        let shim = IPS.images.count
        let d = try diagnose(IPS.crash(exception: ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "codes": "0x1, 0x0"],
                                       termination: ["namespace": "SIGNAL", "code": 11, "indicator": "Segmentation fault: 11"],
                                       frames: [IPS.frame(shim, "XSStubContainer"), IPS.frame(IPS.uikit), IPS.frame(0, "main")],
                                       images: images),
                             CrashContext(moduleName: "XSideWelcome.dylib", iCloudSignedOutOn: true))
        #expect(d.cause == .iCloudShim)
        #expect(d.subject == "XSideICloud.dylib")
        #expect(d.iCloudSignedOutOn == true)
        #expect(CrashAction.suggested(for: d) == .turnOffICloudSignedOut)
    }

    @Test func aKnownTweak() throws {
        let frames = [IPS.frame(IPS.uikit), IPS.frame(2), IPS.frame(0)]
        let known = try diagnose(IPS.crash(frames: frames), CrashContext(moduleName: "XSideWelcome.dylib", tweakNames: ["uTweak.dylib"]))
        #expect(known.cause == .tweak)
        #expect(known.subject == "uTweak.dylib")
        // A dylib the app came with: named, but not claimed to be a tweak XSide added.
        let bundled = try diagnose(IPS.crash(frames: frames))
        #expect(bundled.cause == .bundledLibrary)
        #expect(bundled.subject == "uTweak.dylib")
    }

    private static let tweakFolder = "\(IPS.appPath)/Frameworks/XSideTweaks"
    private static let tweakContext = CrashContext(moduleName: "XSideWelcome.dylib", tweakNames: ["Alpha.dylib"],
                                                   tweakSupportNames: [TweakLayout.elleKitName, TweakLayout.supportName, "Cephei"],
                                                   tweakLabels: ["Alpha.dylib": "Alpha 1.2"])

    @Test func aCrashInElleKitIsTheTweakSupport() throws {
        let images = IPS.images + [IPS.image("ElleKit.dylib", path: "\(Self.tweakFolder)/ElleKit.dylib"),
                                   IPS.image("Alpha.dylib", path: "\(Self.tweakFolder)/0123456789abcdef/Alpha.dylib")]
        let elle = IPS.images.count, alpha = elle + 1
        let d = try diagnose(IPS.crash(frames: [IPS.frame(elle, "MSHookMessageEx"), IPS.frame(alpha), IPS.frame(0, "main")],
                                       images: images), Self.tweakContext)
        #expect(d.cause == .tweakSupport)
        #expect(d.subject == "ElleKit.dylib")
        #expect(d.shellCommand == nil)
        #expect(CrashAction.suggested(for: d) == .disableConvertedTweaks)
        // The tweak itself, named for people.
        let t = try diagnose(IPS.crash(frames: [IPS.frame(IPS.uikit), IPS.frame(alpha), IPS.frame(elle)], images: images),
                             Self.tweakContext)
        #expect(t.cause == .tweak && t.subject == "Alpha.dylib" && t.tweakName == "Alpha 1.2")
        #expect(CrashAction.suggested(for: t) == .disableTweak)
    }

    @Test func aCrashInEmbeddedCepheiIsTheTweakSupport() throws {
        let path = "\(Self.tweakFolder)/deps/ws.hbang.common/Library/Frameworks/Cephei.framework/Cephei"
        let images = IPS.images + [IPS.image("Cephei", path: path)]
        let cephei = IPS.images.count
        let d = try diagnose(IPS.crash(frames: [IPS.frame(IPS.objc), IPS.frame(cephei, "HBOutputForShellCommand"), IPS.frame(0)],
                                       images: images), Self.tweakContext)
        #expect(d.cause == .tweakSupport)
        #expect(d.subject == "Cephei")
        // Cephei runs /var/jb/bin/sh: said plainly.
        #expect(d.shellCommand == true)
        // Without XSide having added it, the same image is just an app framework.
        let plain = try diagnose(IPS.crash(frames: [IPS.frame(cephei, "HBOutputForShellCommand")], images: images))
        #expect(plain.cause == .other && plain.shellCommand == nil)
    }

    @Test func iCloudWithoutTheEntitlement() throws {
        let d = try diagnose(IPS.crash(exception: ["type": "EXC_BREAKPOINT", "signal": "SIGTRAP"],
                                       frames: [IPS.frame(IPS.cloudKit), IPS.frame(IPS.cloudKit), IPS.frame(1), IPS.frame(0)]))
        #expect(d.cause == .iCloud)
    }

    @Test func outOfMemory() throws {
        let d = try diagnose(IPS.jetsam(processes: [["name": "Demo", "reason": "per-process-limit", "states": ["active", "frontmost"]]]))
        #expect(d.cause == .outOfMemory)
        #expect(d.subject == "per-process-limit")
    }

    /// Only a foreground app hitting its own memory limit is "out of memory"; a suspended or
    /// background app iOS evicts to free memory is routine, not a crash (review Important 4).
    @Test func onlyAForegroundLimitIsOutOfMemory() throws {
        let since = Date(timeIntervalSince1970: 0)
        let target = CrashTarget(signedBundleID: "com.example.demo.TEAM1", executable: "Demo")
        func log(_ reason: String, _ states: [String]?) throws -> CrashLog {
            var entry: [String: Any] = ["name": "Demo", "reason": reason]
            if let states { entry["states"] = states }
            return try #require(CrashLogParser.parse(IPS.jetsam(processes: [entry])))
        }
        #expect(try log("per-process-limit", ["active", "frontmost"]).matches(target, since: since))
        #expect(try log("per-process-limit", ["suspended", "active", "frontmost"]).matches(target, since: since))
        #expect(try log("highwater", ["frontmost"]).matches(target, since: since))
        #expect(try log("per-process-limit", ["suspended"]).matches(target, since: since) == false)
        #expect(try log("highwater", ["suspended"]).matches(target, since: since) == false)
        for reason in ["vm-pageshortage", "fc-thrashing", "idle-exit", "vnode-limit", "zone-map-exhaustion", "jettisoned"] {
            #expect(try log(reason, ["active", "frontmost"]).matches(target, since: since) == false, "\(reason)")
        }
        #expect(try log("per-process-limit", nil).matches(target, since: since) == false)
        #expect(try log("per-process-limit", ["frontmost"]).jetsamKills.first?.states == ["frontmost"])
    }

    @Test func watchdogAtLaunch() throws {
        let d = try diagnose(IPS.crash(exception: ["type": "EXC_CRASH", "signal": "SIGKILL"],
                                       termination: ["namespace": "FRONTBOARD", "code": 2_343_432_205,
                                                     "reasons": ["<RBSTerminateContext| domain:10 code:0x8BADF00D explanation:scene-create watchdog transgression",
                                                                 "WatchdogEvent: scene-create"]],
                                       frames: [IPS.frame(1), IPS.frame(0)]))
        #expect(d.cause == .launchTimeout)
    }

    @Test func watchdogLater() throws {
        let d = try diagnose(IPS.crash(exception: ["type": "EXC_CRASH", "signal": "SIGKILL"],
                                       termination: ["namespace": "FRONTBOARD", "code": 2_343_432_205,
                                                     "reasons": ["code:0x8BADF00D explanation: Failed to terminate gracefully after 5.0s",
                                                                 "WatchdogEvent: process-exit"]]))
        #expect(d.cause == .hang)
    }

    @Test func anythingElseIsHonest() throws {
        let d = try diagnose(IPS.crash(exception: ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"],
                                       frames: [IPS.frame(IPS.uikit, "-[UIView x]"), IPS.frame(3), IPS.frame(0)]))
        #expect(d.cause == .other)
        #expect(d.exceptionType == "EXC_BAD_ACCESS")
        #expect(d.subject == "Kit") // the first frame of the app's own code
        #expect(d.topFrames.first == "UIKitCore  -[UIView x]")
    }

    @Test func otherWithOnlySystemFrames() throws {
        let d = try diagnose(IPS.crash(frames: [IPS.frame(IPS.uikit), IPS.frame(IPS.coreFoundation)]))
        #expect(d.cause == .other)
        #expect(d.subject == "UIKitCore")
    }
}

@Suite struct CrashLogFilterTests {
    private func listing(_ files: [(String, Int, String)], directories: [String] = []) -> Data {
        let entries: [[String: Any]] = files.map { path, size, date in
            ["relativePath": path, "name": path,
             "metadata": ["size": size, "lastModDate": date],
             "resources": ["isDirectory": false]]
        } + directories.map { ["relativePath": $0, "resources": ["isDirectory": true], "metadata": [:]] }
        return try! JSONSerialization.data(withJSONObject: ["result": ["files": entries]])
    }

    private let since = ISO8601DateFormatter().date(from: "2026-11-09T08:00:00Z")!

    @Test func keepsTheAppsRecentLogs() throws {
        let entries = try #require(CrashLogListing.parse(listing([
            ("Demo-2026-11-09-091941.ips", 28_000, "2026-11-09T08:19:41.000Z"),
            ("Retired/Demo-2026-11-09-092042.ips", 28_000, "2026-11-09T08:20:42.000Z"),
            ("Retired/Demo-2026-11-08-092042.ips", 28_000, "2026-11-08T08:20:42.000Z"),       // too old
            ("Demo.diskwrites_resource-2026-11-09-091941.ips", 9_000, "2026-11-09T08:19:41.000Z"),
            ("DemoPro-2026-11-09-091941.ips", 9_000, "2026-11-09T08:19:41.000Z"),             // another app
            ("ProxiedDevice-abc/Demo-2026-11-09-091941.ips", 9_000, "2026-11-09T08:19:41.000Z"), // the Watch
            ("Demo-2026-11-09-091950.ips", 50_000_000, "2026-11-09T08:19:50.000Z"),          // too big
            ("JetsamEvent-2026-11-09-092841.ips", 295_000, "2026-11-09T08:28:41.000Z"),
            ("Retired/JetsamEvent-2026-11-08-092841.ips", 295_000, "2026-11-08T08:28:41.000Z"),
            ("Demo-2026-11-09-091941.txt", 1_000, "2026-11-09T08:19:41.000Z"),
        ], directories: ["Retired"])))
        let picked = CrashLogListing.candidates(entries, executable: "Demo", since: since)
        #expect(picked.crashes.map(\.relativePath) == ["Retired/Demo-2026-11-09-092042.ips", "Demo-2026-11-09-091941.ips"])
        #expect(picked.jetsam.map(\.relativePath) == ["JetsamEvent-2026-11-09-092841.ips"])
    }

    @Test func namesWithAccentsAndSpaces() throws {
        let entries = try #require(CrashLogListing.parse(listing([
            ("PokmonTCGPocket-2026-11-09-091941.ips", 28_000, "2026-11-09T08:19:41.000Z"),
            ("My-App-2026-11-09-091941.000.ips", 28_000, "2026-11-09T08:19:41.000Z"),
        ])))
        #expect(CrashLogListing.candidates(entries, executable: "PokémonTCGPocket", since: since).crashes.count == 1)
        #expect(CrashLogListing.candidates(entries, executable: "My-App", since: since).crashes.count == 1)
    }

    @Test func withoutTheExecutableOnlyLikelyAppCrashes() throws {
        let entries = try #require(CrashLogListing.parse(listing([
            ("Demo-2026-11-09-091941.ips", 28_000, "2026-11-09T08:19:41.000Z"),
            ("SiriSearchFeedback-2026-11-09-091941.ips", 600, "2026-11-09T08:19:41.000Z"),
            ("cloudd.diskwrites_resource-2026-11-09-091941.ips", 600, "2026-11-09T08:19:41.000Z"),
            ("ExcUserFault_Preferences-2026-11-09-091941.ips", 600, "2026-11-09T08:19:41.000Z"),
        ])))
        let picked = CrashLogListing.candidates(entries, executable: nil, since: since)
        #expect(picked.crashes.map(\.relativePath) == ["Demo-2026-11-09-091941.ips"])
        #expect(picked.jetsam.isEmpty)
    }

    /// An entry whose size isn't listed isn't copied (its size couldn't be checked before).
    @Test func skipsEntriesWithoutASize() throws {
        let json = try JSONSerialization.data(withJSONObject: ["result": ["files": [
            ["relativePath": "Demo-2026-11-09-095800.ips", "metadata": ["lastModDate": "2026-11-09T09:00:00.000Z"]],
            ["relativePath": "Demo-2026-11-09-095700.ips", "metadata": ["size": 10, "lastModDate": "2026-11-09T09:00:00.000Z"]],
        ]]])
        let entries = try #require(CrashLogListing.parse(json))
        let picked = CrashLogListing.candidates(entries, executable: "Demo", since: Date(timeIntervalSince1970: 0))
        #expect(picked.crashes.map(\.relativePath) == ["Demo-2026-11-09-095700.ips"])
    }

    @Test func limitsHowManyAreCopied() throws {
        let files = (10..<40).map { ("Demo-2026-11-09-0919\($0).ips", 1_000, "2026-11-09T08:19:\($0).000Z") }
        let entries = try #require(CrashLogListing.parse(listing(files)))
        let picked = CrashLogListing.candidates(entries, executable: "Demo", since: since)
        #expect(picked.crashes.count == CrashLogListing.maxCrashFiles)
        #expect(picked.crashes.first?.relativePath == "Demo-2026-11-09-091939.ips")
    }

    @Test func unreadableListing() {
        #expect(CrashLogListing.parse(Data("nope".utf8)) == nil)
        #expect(CrashLogListing.parse(Data("{\"result\":{\"files\":5}}".utf8)) == nil)
    }

    @Test func matchesTheInstallation() throws {
        let target = CrashTarget(signedBundleID: "com.example.demo.TEAM1", executable: "Demo")
        let mine = try #require(CrashLogParser.parse(IPS.crash()))
        #expect(mine.matches(target, since: since))
        #expect(!mine.matches(target, since: Date(timeIntervalSince1970: 1_894_000_000)))
        let other = try #require(CrashLogParser.parse(IPS.crash(bundleID: "com.example.demo")))
        #expect(!other.matches(target, since: since)) // the App Store copy, not XSide's
        let noID = try #require(CrashLogParser.parse(IPS.crash(bundleID: nil)))
        #expect(noID.matches(target, since: since))
        #expect(!noID.matches(CrashTarget(signedBundleID: "com.example.demo.TEAM1", executable: nil), since: since))
        let jetsam = try #require(CrashLogParser.parse(IPS.jetsam(processes: [["name": "Demo", "reason": "highwater", "states": ["frontmost"]]])))
        #expect(jetsam.matches(target, since: since))
        #expect(!jetsam.matches(CrashTarget(signedBundleID: "x", executable: "Other"), since: since))
    }
}

@Suite struct CrashLogSanitizerTests {
    @Test func masksWhatIdentifiesThePerson() {
        let text = """
            {"crashReporterKey" : "8bab4cc6c76d39d9b04256823e44b842c26b356b",
             "deviceIdentifierForVendor" : "FAEADC79-7D12-4249-AA35-40515185CAB3",
             "codeSigningTeamID" : "AB12CD34EF", "codeSigningID" : "com.example.demo.AB12CD34EF",
             "procPath" : "/private/var/containers/Bundle/Application/C514880A-9749-48AE-A295-B4076597C222/Demo.app/Demo",
             "udid" : "00008160-0006422C1E30000A", "owner" : "anthony@example.com",
             "path" : "/Users/anthony/Library/Thing", "userID" : 501,
             "exception" : {"type" : "EXC_BREAKPOINT"}}
            """
        let clean = CrashLogSanitizer.sanitize(text, secrets: ["AB12CD34EF"])
        for secret in ["8bab4cc6c76d39d9b04256823e44b842c26b356b", "FAEADC79-7D12-4249-AA35-40515185CAB3", "AB12CD34EF",
                       "C514880A-9749-48AE-A295-B4076597C222", "00008160-0006422C1E30000A", "anthony@example.com",
                       "/Users/anthony", "501"] {
            #expect(!clean.contains(secret), "\(secret) left in")
        }
        #expect(clean.contains("EXC_BREAKPOINT"))
        #expect(clean.contains("Demo.app/Demo"))
        #expect(clean.contains("com.example.demo."))
    }

    /// The binary images' UUIDs are what symbolication needs: kept. The device's and the person's
    /// are masked, as are ECIDs written as numbers (review Minor 11).
    @Test func keepsBinaryImageUUIDs() {
        let text = """
            {"slice_uuid":"0b5a1c2d-3e4f-5061-7283-94a5b6c7d8e9","bootSessionUUID":"11112222-3333-4444-5555-666677778888"}
            {"usedImages" : [{"uuid" : "aabbccdd-eeff-0011-2233-445566778899", "path" : "/private/var/containers/Bundle/Application/C514880A-9749-48AE-A295-B4076597C222/Demo.app/Demo"}],
             "UUID": "99998888-7777-6666-5555-444433332222",
             "deviceIdentifierForVendor" : "FAEADC79-7D12-4249-AA35-40515185CAB3",
             "ecid" : 1234567890123, "uniqueChipID": 9876543210987, "note": "AAAABBBB-CCCC-DDDD-EEEE-FFFF00001111"}
            """
        let clean = CrashLogSanitizer.sanitize(text)
        for kept in ["0b5a1c2d-3e4f-5061-7283-94a5b6c7d8e9", "aabbccdd-eeff-0011-2233-445566778899",
                     "99998888-7777-6666-5555-444433332222"] {
            #expect(clean.contains(kept), "\(kept) masked")
        }
        for secret in ["11112222-3333-4444-5555-666677778888", "C514880A-9749-48AE-A295-B4076597C222",
                       "FAEADC79-7D12-4249-AA35-40515185CAB3", "1234567890123", "9876543210987",
                       "AAAABBBB-CCCC-DDDD-EEEE-FFFF00001111"] {
            #expect(!clean.contains(secret), "\(secret) left in")
        }
    }
}

/// Plays devicectl: the listing, then each copy writes the file it was asked for.
private final class CrashDeviceRunner: CommandRunning, @unchecked Sendable {
    let listing: Data
    var files: [String: Data]
    var listStatus: Int32 = 0
    enum CopyMode { case file, folder, symlink }
    var copyMode = CopyMode.file
    private let lock = NSLock()
    private(set) var calls: [[String]] = []

    init(listing: Data, files: [String: Data]) {
        self.listing = listing
        self.files = files
    }

    func run(_ executable: String, _ arguments: [String], cwd: URL?, timeout: Duration) async throws -> CommandResult {
        lock.withLock { calls.append(arguments) }
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        if arguments.starts(with: ["devicectl", "device", "info", "files"]) {
            guard listStatus == 0 else { return CommandResult(status: 1, stdout: Data(), stderr: "ERROR: The device is not currently reachable") }
            try listing.write(to: URL(fileURLWithPath: value("--json-output")!))
            return CommandResult(status: 0, stdout: Data(), stderr: "")
        }
        if arguments.starts(with: ["devicectl", "device", "copy", "from"]) {
            guard let source = value("--source"), let data = files[source] else {
                return CommandResult(status: 1, stdout: Data(), stderr: "ERROR: no such file")
            }
            // As devicectl does (checked on a device): the file at `--destination`, its folder made.
            let destination = URL(fileURLWithPath: value("--destination")!)
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch copyMode {
            case .file:
                try data.write(to: destination)
            case .folder:
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                try data.write(to: destination.appendingPathComponent((source as NSString).lastPathComponent))
            case .symlink:
                let real = destination.deletingLastPathComponent().appendingPathComponent("real-\(UUID().uuidString)")
                try data.write(to: real)
                try fm.createSymbolicLink(at: destination, withDestinationURL: real)
            }
            return CommandResult(status: 0, stdout: Data("File received from Device\n\(destination.path)\n".utf8), stderr: "")
        }
        if arguments.starts(with: ["devicectl", "device", "info", "processes"]) {
            let json = ["result": ["runningProcesses": [
                ["executable": "file:///private/var/containers/Bundle/Application/X/Demo%20App.app/Demo%20App", "processIdentifier": 4],
                ["executable": "file:///private/var/containers/Bundle/Application/Y/Other.app/PlugIns/W.appex/Demo", "processIdentifier": 5],
            ]]]
            try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: value("--json-output")!))
            return CommandResult(status: 0, stdout: Data(), stderr: "")
        }
        return CommandResult(status: 1, stdout: Data(), stderr: "unexpected")
    }
}

@Suite struct CrashLogFetcherTests {
    private func listing(_ names: [String]) -> Data {
        let entries: [[String: Any]] = names.map {
            ["relativePath": $0, "metadata": ["size": 30_000, "lastModDate": "2026-11-09T09:00:00.000Z"], "resources": ["isDirectory": false]]
        }
        return try! JSONSerialization.data(withJSONObject: ["result": ["files": entries]])
    }

    private func scratch() throws -> URL {
        let url = TestTemp.root.appendingPathComponent("crash-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let since = ISO8601DateFormatter().date(from: "2026-11-09T08:00:00Z")!
    private let target = CrashTarget(signedBundleID: "com.example.demo.TEAM1", executable: "Demo")

    @Test func findsTheNewestMatchAndCleansUp() async throws {
        let runner = CrashDeviceRunner(listing: listing([
            "Demo-2026-11-09-095900.ips", "Retired/Demo-2026-11-09-095800.ips", "JetsamEvent-2026-11-09-095700.ips",
        ]), files: [
            // The newest file is the App Store copy's: skipped.
            "Demo-2026-11-09-095900.ips": IPS.crash(bundleID: "com.example.demo", timestamp: "2026-11-09 09:59:00.00 +0000"),
            "Retired/Demo-2026-11-09-095800.ips": IPS.crash(timestamp: "2026-11-09 09:58:00.00 +0000",
                                                            exception: ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"]),
            "JetsamEvent-2026-11-09-095700.ips": IPS.jetsam(timestamp: "2026-11-09 09:57:00.00 +0000",
                                                            processes: [["name": "Demo", "reason": "highwater"]]),
        ])
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let found = try #require(try await CrashLogFetcher(runner: runner, scratchRoot: root)
            .latest(target, deviceID: "DEV", since: since))
        #expect(found.log.exceptionType == "EXC_BAD_ACCESS")
        #expect(found.text.contains("EXC_BAD_ACCESS"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(runner.calls.first?.contains("systemCrashLogs") == true)
        #expect(runner.calls.allSatisfy { $0.contains("DEV") })
    }

    @Test func aJetsamNewerThanTheCrashWins() async throws {
        let runner = CrashDeviceRunner(listing: listing(["Demo-2026-11-09-095800.ips", "JetsamEvent-2026-11-09-095900.ips"]), files: [
            "Demo-2026-11-09-095800.ips": IPS.crash(timestamp: "2026-11-09 09:58:00.00 +0000"),
            "JetsamEvent-2026-11-09-095900.ips": IPS.jetsam(timestamp: "2026-11-09 09:59:00.00 +0000",
                                                            processes: [["name": "SecretApp", "reason": "vm-pageshortage"],
                                                                        ["name": "Demo", "reason": "highwater", "states": ["frontmost"]],
                                                                        ["name": "OtherApp"]],
                                                            extra: ["largestProcess": "SecretApp",
                                                                    "memoryStatus": ["pageSize": 16384, "largestZone": "APFS",
                                                                                     "largestProcess": "OtherApp",
                                                                                     "nested": ["topProcess": "SecretApp", "pages": 3]]]),
        ])
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let found = try #require(try await CrashLogFetcher(runner: runner, scratchRoot: root).latest(target, deviceID: "DEV", since: since))
        #expect(found.log.kind == .jetsam)
        // Only the app's own entry: the event lists every process the person runs.
        #expect(found.log.jetsamKills == [JetsamKill(name: "Demo", reason: "highwater", states: ["frontmost"])])
        #expect(found.text.contains("highwater"))
        // Nor another process's name anywhere else (largestProcess, memoryStatus).
        #expect(!found.text.contains("SecretApp") && !found.text.contains("OtherApp"))
        #expect(found.text.contains("pageSize"))
    }

    /// A suspended app iOS evicted to free memory, newer than a real crash: the crash is the answer.
    @Test func aBackgroundEvictionNeverHidesACrash() async throws {
        let runner = CrashDeviceRunner(listing: listing(["Demo-2026-11-09-095800.ips", "JetsamEvent-2026-11-09-095900.ips"]), files: [
            "Demo-2026-11-09-095800.ips": IPS.crash(timestamp: "2026-11-09 09:58:00.00 +0000"),
            "JetsamEvent-2026-11-09-095900.ips": IPS.jetsam(timestamp: "2026-11-09 09:59:00.00 +0000",
                                                            processes: [["name": "Demo", "reason": "per-process-limit", "states": ["suspended"]]]),
        ])
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let found = try #require(try await CrashLogFetcher(runner: runner, scratchRoot: root).latest(target, deviceID: "DEV", since: since))
        #expect(found.log.kind == .crash)
    }

    /// Another app's name, as a key or a value at any depth, never survives the cut (allowlist).
    @Test func noOtherProcessNameSurvivesTheCut() throws {
        let secret = "SecretBankApp"
        let header: [String: Any] = ["bug_type": "298", "timestamp": "2026-11-09 10:00:00.00 +0100", "os_version": "iPhone OS 27.3",
                                     "incident_id": secret, secret: 1]
        let body: [String: Any] = [
            "date": "2026-11-09 10:00:00.00 +0100", "build": "iPhone OS 27.3", "product": "iPhone19,4", "bug_type": "298",
            "largestProcess": secret, secret: ["x": 1], "extra": [secret, ["k": secret]],
            "memoryStatus": ["pageSize": 16384, "largestZone": secret, secret: 5, "compressorSize": secret,
                             "memoryPages": ["active": 1, secret: 2, "free": ["deep": secret]],
                             "nested": [secret: [secret: secret]]],
            "processes": [
                ["name": "Demo", "reason": "per-process-limit", "states": ["frontmost", secret], secret: secret,
                 "coalition": secret, "uuid": "aabbccdd-eeff-0011-2233-445566778899"],
                ["name": secret, "reason": "vm-pageshortage", "states": ["suspended"]],
            ],
        ]
        let text = String(decoding: IPS.join(header, body), as: UTF8.self)
        let log = try #require(CrashLogParser.parse(Data(text.utf8)))
        let cut = CrashLogFetcher.jetsamOnly(.init(log: log, text: text, fileName: "J.ips"), executable: "Demo")
        #expect(!cut.text.contains(secret))
        #expect(cut.text.contains("per-process-limit") && cut.text.contains("frontmost") && cut.text.contains("16384"))
        // What's left still reads as the app's foreground memory-limit kill.
        let reread = try #require(CrashLogParser.parse(Data(cut.text.utf8)))
        #expect(reread.jetsamKills == [JetsamKill(name: "Demo", reason: "per-process-limit", states: ["frontmost"])])
        #expect(reread.date != nil)
    }

    /// The largest process is kept only when it is the app itself.
    @Test func keepsTheLargestProcessOnlyWhenItIsTheApp() {
        let text = String(decoding: IPS.jetsam(processes: [["name": "Demo", "reason": "per-process-limit", "states": ["frontmost"]]],
                                               extra: ["largestProcess": "Demo"]), as: UTF8.self)
        let log = CrashLogParser.parse(Data(text.utf8))!
        let cut = CrashLogFetcher.jetsamOnly(.init(log: log, text: text, fileName: "J.ips"), executable: "Demo")
        #expect(cut.text.contains("\"largestProcess\" : \"Demo\""))
    }

    /// devicectl writes the file at `--destination` itself (checked on a device); a folder holding
    /// it, should a version do that, is read too. A symbolic link is never followed.
    @Test func readsWhateverTheCopyMade() async throws {
        let files = ["Demo-2026-11-09-095800.ips": IPS.crash(timestamp: "2026-11-09 09:58:00.00 +0000")]
        for mode in [CrashDeviceRunner.CopyMode.file, .folder] {
            let runner = CrashDeviceRunner(listing: listing(["Demo-2026-11-09-095800.ips"]), files: files)
            runner.copyMode = mode
            let root = try scratch()
            defer { try? FileManager.default.removeItem(at: root) }
            let found = try await CrashLogFetcher(runner: runner, scratchRoot: root).latest(target, deviceID: "DEV", since: since)
            #expect(found != nil, "\(mode)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
        let runner = CrashDeviceRunner(listing: listing(["Demo-2026-11-09-095800.ips"]), files: files)
        runner.copyMode = .symlink
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await CrashLogFetcher(runner: runner, scratchRoot: root).latest(target, deviceID: "DEV", since: since) == nil)
    }

    /// Folders left by a fetch XSide was killed in the middle of go at the next launch, once old
    /// enough not to be another XSide's fetch in progress.
    @Test func sweepsLeftovers() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let old = root.appendingPathComponent("xside-crash-OLD"), fresh = root.appendingPathComponent("xside-crash-NEW")
        let oldList = root.appendingPathComponent("xside-processes-OLD.json"), other = root.appendingPathComponent("keep-me")
        for url in [old, fresh, other] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data("{}".utf8).write(to: oldList)
        let hourAgo = Date().addingTimeInterval(-3600)
        for url in [old, oldList, other] { try fm.setAttributes([.modificationDate: hourAgo], ofItemAtPath: url.path) }
        CrashLogFetcher.sweepLeftovers(in: root)
        #expect(Set(try fm.contentsOfDirectory(atPath: root.path)) == ["xside-crash-NEW", "keep-me"])
    }

    /// The quiet look copies only what it picked from the listing, and leaves nothing behind.
    @Test func theQuietLookCopiesOnlyItsPicks() async throws {
        let runner = CrashDeviceRunner(listing: listing(["Demo-2026-11-09-095800.ips", "Stranger-2026-11-09-095900.ips"]), files: [
            "Demo-2026-11-09-095800.ips": IPS.crash(timestamp: "2026-11-09 09:58:00.00 +0000"),
            "Stranger-2026-11-09-095900.ips": IPS.crash(name: "Stranger", bundleID: "com.example.stranger"),
        ])
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let found = try await CrashLogFetcher(runner: runner, scratchRoot: root).newCrashes(deviceID: "DEV") { entries in
            CrashLogListing.newCrashFiles(entries, executables: ["Demo"], since: since, seen: [])
        }
        #expect(found.map(\.fileName) == ["Demo-2026-11-09-095800.ips"])
        let copies = runner.calls.filter { $0.starts(with: ["devicectl", "device", "copy", "from"]) }
        #expect(copies.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func nothingFound() async throws {
        let runner = CrashDeviceRunner(listing: listing(["Demo-2026-11-09-095800.ips"]), files: [:]) // the copy fails
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await CrashLogFetcher(runner: runner, scratchRoot: root).latest(target, deviceID: "DEV", since: since) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func anUnreachableDeviceIsAnError() async throws {
        let runner = CrashDeviceRunner(listing: Data(), files: [:])
        runner.listStatus = 1
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: XSideError.deviceUnavailable) {
            try await CrashLogFetcher(runner: runner, scratchRoot: root).latest(target, deviceID: "DEV", since: since)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func tellsWhetherTheAppRuns() async throws {
        let runner = CrashDeviceRunner(listing: Data(), files: [:])
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = CrashLogFetcher(runner: runner, scratchRoot: root)
        #expect(await fetcher.isRunning(executable: "Demo App", deviceID: "DEV") == true)
        #expect(await fetcher.isRunning(executable: "Demo", deviceID: "DEV") == false) // an extension is not the app
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}

/// A reproducible random source for the fuzz tests (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
