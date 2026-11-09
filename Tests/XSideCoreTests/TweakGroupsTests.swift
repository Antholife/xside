import Foundation
import Testing
@testable import XSideCore

/// Device round 2, items 3, 4, 6, 7: step ③ and Mes apps sort the tweaks into « À régler » (blocks
/// « Suivant »), « Prêts » and « Pas compatibles »; an unknown dependency gets a web search.
struct TweakGroupsTests {
    typealias S = TweakGroups.DeviceState

    private func s(_ v: TweakVerdict?, on: Bool = true, forced: Bool = false, signedAnyway: Bool = false,
                   missing: [String] = []) -> S {
        S(verdict: v, isOn: on, isForced: forced, signedAnyway: signedAnyway, missingDependencies: missing)
    }

    @Test func readyWhenItWillBeInjectedSomewhere() {
        #expect(TweakGroups.group([s(.compatible)]) == .ready)
        #expect(TweakGroups.group([s(.converted([.hookingLibrary])), s(.compatible, on: false)]) == .ready)
        // ✅ on one device, an iOS version ❌ on the other: it goes where it can.
        #expect(TweakGroups.group([s(.compatible), s(.incompatible(.iOSVersion(required: "≥ 17.0", device: "16.0")), on: false)])
                == .ready)
        // Not judged yet, or no device chosen: nothing to settle.
        #expect(TweakGroups.group([s(nil)]) == .ready)
        #expect(TweakGroups.group([]) == .ready)
    }

    @Test func toSettleWhileSomethingTheyCanFixIsOpen() {
        // A dependency missing on one device.
        #expect(TweakGroups.group([s(.compatible), s(.compatible, missing: ["com.opa334.altlist"])]) == .toSettle)
        // A known library missing (Cephei), two versions asked at once.
        #expect(TweakGroups.group([s(.incompatible(.missingDependency("Cephei")), on: false)]) == .toSettle)
        #expect(TweakGroups.group([s(.incompatible(.dependencyConflict("Cephei", ["≥ 2.0", "< 2.0"])), on: false)]) == .toSettle)
        // Made for another app, not forced: settle (force it) or remove it.
        let other = TweakVerdict.incompatible(.madeForAnotherApp(["com.burbn.instagram"]))
        #expect(TweakGroups.group([s(other, on: false)]) == .toSettle)
        // Per device: forced (on) on one, left off on the other: the person's choice there.
        #expect(TweakGroups.group([s(other, on: false), s(other, on: true, forced: true)]) == .ready)
        // Ready on one device; on the other a library is missing and it is off there: ready.
        #expect(TweakGroups.group([s(.compatible), s(.incompatible(.missingDependency("Cephei")), on: false)]) == .ready)
        // A missing dependency on a device where it was turned off by the person: not blocking.
        #expect(TweakGroups.group([s(.compatible), s(.compatible, on: false, missing: ["com.x"])]) == .ready)
        // Forced everywhere: settled.
        #expect(TweakGroups.group([s(other, on: true, forced: true)]) == .ready)
        // Injected anyway by the last signing (a ❌ from the check here only): not blocking.
        #expect(TweakGroups.group([s(.incompatible(.missingDependency("Foo.framework")), signedAnyway: true)]) == .ready)
        #expect(TweakGroups.blocks(.toSettle) && !TweakGroups.blocks(.ready) && !TweakGroups.blocks(.incompatible))
    }

    @Test func incompatibleWhenNoDeviceCanEverRunIt() {
        #expect(TweakGroups.group([s(.incompatible(.needsJailbreak("SpringBoard")), on: false)]) == .incompatible)
        #expect(TweakGroups.group([s(.incompatible(.wrongArchitecture(["arm64e"])), on: false),
                                   s(.incompatible(.iOSVersion(required: "≥ 17.0", device: "16.0")), on: false)]) == .incompatible)
        #expect(TweakGroups.group([s(.incompatible(.notForIOS), on: false)]) == .incompatible)
        // One device can be settled: to settle, not given up.
        #expect(TweakGroups.group([s(.incompatible(.needsJailbreak("SpringBoard")), on: false),
                                   s(.incompatible(.noFilter), on: false)]) == .toSettle)
    }

    @Test func aWebSearchForAnUnknownDependency() {
        let url = DependencyDirectory.webSearchURL(packageID: "com.example.helper", name: "Helper Lib")
        #expect(url?.absoluteString == "https://duckduckgo.com/?q=com.example.helper+Helper+Lib+deb")
        // The name is the id: once. Odd characters are encoded, never raw.
        #expect(DependencyDirectory.webSearchURL(packageID: "com.x", name: "com.x")?.absoluteString
                == "https://duckduckgo.com/?q=com.x+deb")
        #expect(DependencyDirectory.webSearchURL(packageID: "a+b", name: "A&B #1")?.absoluteString
                == "https://duckduckgo.com/?q=a%2Bb+A%26B+%231+deb")
        #expect(DependencyDirectory.webSearchURL(packageID: "com.x", name: "Préférences")?.absoluteString
                == "https://duckduckgo.com/?q=com.x+Pr%C3%A9f%C3%A9rences+deb")
        #expect(DependencyDirectory.webSearchURL(packageID: "", name: "") == nil)
        #expect(DependencyDirectory.webSearchURL(packageID: String(repeating: "x", count: 300), name: "y") == nil)
    }
}

extension TweakGroupsTests {
    private static func pkg(_ id: String, _ packageID: String, depends: [String] = []) -> TweakPackage {
        TweakPackage(id: id, kind: .deb, origin: .added, packageID: packageID, name: packageID,
                     depends: depends.map { [DebDependency(package: $0)] }, addedAt: Date(timeIntervalSince1970: 0))
    }

    /// Mockup v2: the dependencies are nested under their tweak (↳), a dependency's own
    /// dependency under the same tweak; a library nobody needs is its own card; a cycle too.
    @Test func dependenciesNestUnderTheTweakAtTheTop() {
        let cephei = Self.pkg("c", "ws.hbang.common"), altlist = Self.pkg("a", "com.opa334.altlist")
        let u = Self.pkg("u", "uyouplus", depends: ["com.opa334.altlist", "ws.hbang.common"])
        let y = Self.pkg("y", "youpip", depends: ["ws.hbang.common"])
        let lib = Self.pkg("l", "lib", depends: ["ws.hbang.common"])
        let t = Self.pkg("t", "t", depends: ["lib"])
        let orphan = Self.pkg("o", "com.example.alone")
        #expect(TweakNesting.parents([cephei, altlist, u, y, orphan]) == ["c": "u", "a": "u"])
        #expect(TweakNesting.parents([t, lib, cephei]) == ["l": "t", "c": "t"])
        let a = Self.pkg("x", "com.a", depends: ["com.b"]), b = Self.pkg("z", "com.b", depends: ["com.a"])
        #expect(TweakNesting.parents([a, b]).isEmpty)
        #expect(TweakNesting.parents([]).isEmpty)
    }
}
