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
        // Review 1.0.6 #6: leading digits of each part ("1.10a" is 1.10, not 1.0).
        #expect(InstallPreflight.compare("1.10a", "1.9") == .orderedDescending)
        #expect(InstallPreflight.compare("21.37.04", "21.37.4") == .orderedSame)
    }

    @Test func developerModeOffComesAloneForThatDevice() {
        let off = InstallPreflight.Target(deviceID: "a", osVersion: "17.0", otherApps: ["x", "y", "z"], hasThisApp: false,
                                          developerModeEnabled: false)
        let unknown = InstallPreflight.Target(deviceID: "b", osVersion: "18.2", otherApps: [], hasThisApp: false)
        let warnings = InstallPreflight.check(minimumOS: "18.0", targets: [off, unknown], needsNewAppID: false, appIDsRemaining: 10)
        #expect(warnings == [.developerModeOff(deviceID: "a")])
    }

    /// Built with an older iOS SDK than the device runs: shown in compatibility mode (seen
    /// 2026-11-06: YouTube 21.37.4, SDK 26.4, on an iPhone on iOS 27).
    @Test func flagsAnAppNotBuiltForTheDevicesIOS() {
        let warnings = InstallPreflight.check(minimumOS: nil, targets: [target("a", os: "27.3"), target("b", os: "26.2")],
                                              needsNewAppID: false, appIDsRemaining: 10, sdkVersion: "26.4")
        #expect(warnings == [.notBuiltForDevice(deviceID: "a", sdk: "26.4", deviceOS: "27.3")])
        #expect(InstallPreflight.check(minimumOS: nil, targets: [target("a", os: "27.3")], needsNewAppID: false,
                                       appIDsRemaining: 10, sdkVersion: nil).isEmpty)
    }

    /// An iPhone Duo and an app built before SDK 27.1: it won't fill the Duo's screens (the more
    /// precise note replaces "not built for this iOS" there).
    @Test func flagsAnAppNotMadeForTheDuo() {
        let duo = InstallPreflight.Target(deviceID: "duo", osVersion: "27.3", otherApps: [], hasThisApp: false, isDuo: true)
        let other = target("b", os: "27.3")
        #expect(InstallPreflight.check(minimumOS: nil, targets: [duo, other], needsNewAppID: false, appIDsRemaining: 10,
                                       sdkVersion: "26.4")
                == [.notMadeForDuo(deviceID: "duo"), .notBuiltForDevice(deviceID: "b", sdk: "26.4", deviceOS: "27.3")])
        #expect(InstallPreflight.check(minimumOS: nil, targets: [duo], needsNewAppID: false, appIDsRemaining: 10,
                                       sdkVersion: "27.0") == [.notMadeForDuo(deviceID: "duo")])
        #expect(InstallPreflight.check(minimumOS: nil, targets: [duo], needsNewAppID: false, appIDsRemaining: 10,
                                       sdkVersion: "27.1").isEmpty)
        #expect(InstallPreflight.check(minimumOS: nil, targets: [duo], needsNewAppID: false, appIDsRemaining: 10,
                                       sdkVersion: nil).isEmpty)
    }

    /// Someone picked the wrong file: an older version than the one already on the device.
    @Test func flagsAnOlderVersionThanInstalled() {
        let on = InstallPreflight.Target(deviceID: "a", osVersion: "27.3", otherApps: [], hasThisApp: true, installedVersion: "21.44.4")
        let warnings = InstallPreflight.check(minimumOS: nil, targets: [on], needsNewAppID: false, appIDsRemaining: 10,
                                              appVersion: "21.37.4")
        #expect(warnings == [.olderVersion(deviceID: "a", installing: "21.37.4", installed: "21.44.4")])
        #expect(InstallPreflight.check(minimumOS: nil, targets: [on], needsNewAppID: false, appIDsRemaining: 10,
                                       appVersion: "21.44.4").isEmpty)
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
