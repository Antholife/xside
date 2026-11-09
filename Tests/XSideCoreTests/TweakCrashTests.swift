import Testing
import Foundation
@testable import XSideCore

private let date = Date(timeIntervalSince1970: 1_800_000_000)

private func package(_ id: String, name: String, packageID: String, version: String = "1.0",
                     origin: TweakOrigin = .added) -> TweakPackage {
    TweakPackage(id: id, kind: .deb, origin: origin, packageID: packageID, name: name, version: version,
                 binaries: [TweakBinary(path: "Library/MobileSubstrate/DynamicLibraries/\(name).dylib", isEntry: true,
                                        filter: nil, slices: [], linked: [], mentionsJailbreakPaths: false,
                                        imageName: "\(name).dylib")],
                 addedAt: date)
}

private let alpha = package("aaaaaaaaaaaaaaaa", name: "Alpha", packageID: "com.example.alpha", version: "1.2")
private let alpha2 = package("aaaaaaaaaaaaaaa2", name: "Alpha", packageID: "com.example.alpha", version: "1.3")
private let beta = package("bbbbbbbbbbbbbbbb", name: "Beta", packageID: "com.example.beta")

private func installation(_ device: String, uses: [TweakUse], injected: [InjectedTweak]? = nil,
                          results: [String: TweakResult]? = nil, support: [String]? = nil) -> Installation {
    Installation(deviceID: device, installedAt: date, expiresAt: date.addingTimeInterval(7 * 86_400), tweaks: uses,
                 tweakResults: results, injectedTweaks: injected, tweakSupportImages: support)
}

struct TweakCrashTests {
    @Test func historyIsWhatTheLastSigningRecordedElseTheResults() {
        let recorded = installation("d1", uses: [], injected: [InjectedTweak(alpha, conversions: [.hookingLibrary])],
                                    results: [beta.id: .injected(converted: false)])
        // The recorded history wins, even when the pool no longer has that version.
        #expect(recorded.injectedTweakHistory(pool: [alpha2, beta]).map(\.id) == [alpha.id])
        let older = installation("d1", uses: [], results: [alpha.id: .injected(converted: true), beta.id: .skipped(.noRoom)])
        let h = older.injectedTweakHistory(pool: [alpha, beta])
        #expect(h.map(\.id) == [alpha.id] && h.first?.converted == true)
    }

    @Test func historyAndSupportImagesSurviveCoding() throws {
        let i = installation("d1", uses: [TweakUse(id: alpha.id)],
                             injected: [InjectedTweak(alpha, conversions: [.jailbreakPaths, .dependencyAdded("Cephei")])],
                             support: ["XSideTweakSupport.dylib", "Cephei"])
        let back = try JSONDecoder().decode(Installation.self, from: JSONEncoder().encode(i))
        #expect(back == i)
        // A damaged history is dropped, not the installation.
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(i)) as? [String: Any])
        json["injectedTweaks"] = "nope"
        let damaged = try JSONDecoder().decode(Installation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(damaged.injectedTweaks == nil && damaged.deviceID == "d1")
    }

    @Test func contextNamesTheTweaksAndWhatSupportsThem() {
        var c = CrashContext(moduleName: "XSideWelcome.dylib")
        c.addTweaks(of: installation("d1", uses: [], injected: [InjectedTweak(alpha, conversions: nil)], support: ["Cephei"]),
                    pool: [])
        #expect(c.tweakNames == ["Alpha.dylib"])
        #expect(c.tweakLabels == ["Alpha.dylib": "Alpha 1.2"])
        #expect(c.tweakSupportNames == [TweakLayout.elleKitName, TweakLayout.supportName, "Cephei"])
    }

    @Test func disableThisTweakKeepsItListedAndFindsTheReplacedVersion() {
        let crashed = installation("d1", uses: [TweakUse(id: alpha2.id), TweakUse(id: beta.id)],
                                   injected: [InjectedTweak(alpha, conversions: nil), InjectedTweak(beta, conversions: nil)])
        // Alpha 1.2 crashed; the person replaced it with 1.3 since: the device's list has 1.3.
        let uses = TweakCrashFix.disablingTweak(image: "Alpha.dylib", crashed: crashed, in: crashed, pool: [alpha2, beta])
        #expect(uses == [TweakUse(id: alpha2.id, enabled: false), TweakUse(id: beta.id)])
        // Already off, or an image that isn't a tweak: nothing to do.
        let off = installation("d1", uses: [TweakUse(id: alpha2.id, enabled: false)], injected: crashed.injectedTweaks)
        #expect(TweakCrashFix.disablingTweak(image: "Alpha.dylib", crashed: off, in: off, pool: [alpha2]) == nil)
        #expect(TweakCrashFix.disablingTweak(image: "UIKitCore", crashed: crashed, in: crashed, pool: [alpha2, beta]) == nil)
    }

    @Test func disableTheConvertedTweaksOnly() {
        let crashed = installation("d1", uses: [TweakUse(id: alpha.id, force: true), TweakUse(id: beta.id)],
                                   injected: [InjectedTweak(alpha, conversions: [.hookingLibrary]),
                                              InjectedTweak(beta, conversions: nil)])
        #expect(TweakCrashFix.disablingConverted(crashed: crashed, in: crashed, pool: [alpha, beta])
                == [TweakUse(id: alpha.id, enabled: false, force: true), TweakUse(id: beta.id)])
        let none = installation("d1", uses: [TweakUse(id: beta.id)], injected: [InjectedTweak(beta, conversions: nil)])
        #expect(TweakCrashFix.disablingConverted(crashed: none, in: none, pool: [beta]) == nil)
    }

    @Test func theScopeIsAskedOnlyWhenAnotherDeviceHasTheTweak() {
        let crashed = installation("d1", uses: [TweakUse(id: alpha.id)], injected: [InjectedTweak(alpha, conversions: [.jailbreakPaths])])
        let other = installation("d2", uses: [TweakUse(id: alpha.id)])
        let without = installation("d3", uses: [TweakUse(id: beta.id)])
        var record = AppRecord(id: UUID(), displayName: "Demo", originalBundleID: "com.example.demo",
                               signedBundleID: "com.example.demo.T", ipaPath: "x.ipa", options: InstallOptions(),
                               installations: [crashed, other, without], teamID: "T")
        record.tweaks = [alpha, beta]
        #expect(TweakCrashFix.affected(.disableTweak, subject: "Alpha.dylib", crashed: crashed, record: record)
            .map(\.deviceID) == ["d1", "d2"])
        #expect(TweakCrashFix.affected(.disableConvertedTweaks, subject: nil, crashed: crashed, record: record)
            .map(\.deviceID) == ["d1", "d2"])
        #expect(TweakCrashFix.affected(.refresh, subject: nil, crashed: crashed, record: record).isEmpty)
    }

    @Test func reportLinesAndSummary() {
        let hostile = InjectedTweak(id: "x", name: "Evil\n\u{7}Name" + String(repeating: "z", count: 200), packageID: "p",
                                    version: "2", imageNames: [], conversions: [])
        let line = TweakCrashFix.reportLine(hostile)
        #expect(!line.contains("\n") && !line.contains("\u{7}") && line.count < 120 && line.hasSuffix("(converted)"))
        #expect(TweakCrashFix.reportLine(InjectedTweak(alpha, conversions: [.dependency("AltList")]))
                == "Alpha 1.2 (converted: dependency: AltList)")
        let i = installation("d1", uses: [], injected: [InjectedTweak(alpha, conversions: [.hookingLibrary]),
                                                        InjectedTweak(beta, conversions: nil)])
        #expect(TweakCrashFix.summary(i, pool: []) == "2 tweaks (1 converted)")
        #expect(TweakCrashFix.summary(installation("d1", uses: []), pool: []) == nil)
    }
}
