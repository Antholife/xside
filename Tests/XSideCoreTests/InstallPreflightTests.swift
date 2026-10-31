import Testing
@testable import XSideCore

struct InstallPreflightTests {
    private func target(_ id: String, os: String? = "18.0", apps: [String] = [], has: Bool = false) -> InstallPreflight.Target {
        .init(deviceID: id, osVersion: os, otherApps: apps, hasThisApp: has)
    }

    @Test func comparesVersionsNumerically() {
        #expect(InstallPreflight.compare("17.4", "17.10") == .orderedAscending)
        #expect(InstallPreflight.compare("18", "18.0") == .orderedSame)
        #expect(InstallPreflight.compare("26.1", "18.6.2") == .orderedDescending)
    }

    @Test func flagsAnIOSTooOld() {
        let warnings = InstallPreflight.check(minimumOS: "18.0", targets: [target("a", os: "17.5"), target("b", os: "18.2")],
                                              needsNewAppID: false, appIDsRemaining: 10)
        #expect(warnings == [.iOSTooOld(deviceID: "a", required: "18.0", actual: "17.5")])
    }

    @Test func aFullDeviceUnlessTheAppIsAlreadyThere() {
        let three = ["A", "B", "C"]
        #expect(InstallPreflight.check(minimumOS: nil, targets: [target("a", apps: three)],
                                       needsNewAppID: false, appIDsRemaining: nil)
                == [.deviceFull(deviceID: "a", apps: three)])
        #expect(InstallPreflight.check(minimumOS: nil, targets: [target("a", apps: three, has: true)],
                                       needsNewAppID: false, appIDsRemaining: nil).isEmpty)
        #expect(InstallPreflight.check(minimumOS: nil, targets: [target("a", apps: ["A", "B"])],
                                       needsNewAppID: false, appIDsRemaining: nil).isEmpty)
    }

    @Test func appIDsOnlyMatterForANewOne() {
        #expect(InstallPreflight.check(minimumOS: nil, targets: [], needsNewAppID: true, appIDsRemaining: 0) == [.noAppIDLeft])
        #expect(InstallPreflight.check(minimumOS: nil, targets: [], needsNewAppID: true, appIDsRemaining: 1) == [.lastAppID])
        #expect(InstallPreflight.check(minimumOS: nil, targets: [], needsNewAppID: true, appIDsRemaining: 5).isEmpty)
        #expect(InstallPreflight.check(minimumOS: nil, targets: [], needsNewAppID: false, appIDsRemaining: 0).isEmpty)
        #expect(InstallPreflight.check(minimumOS: nil, targets: [], needsNewAppID: true, appIDsRemaining: nil).isEmpty)
    }
}
