import Foundation
import Testing
@testable import XSideCore

private func install(_ name: String, _ version: String, _ build: String, beta: Bool = false) -> XcodeInstall {
    XcodeInstall(appURL: URL(fileURLWithPath: "/Applications/\(name).app"), version: version, build: build, isBeta: beta)
}

private func selected(_ name: String, isXcode: Bool = true, beta: Bool = false) -> XcodeLocator.Selected {
    XcodeLocator.Selected(developerDir: URL(fileURLWithPath: "/Applications/\(name).app/Contents/Developer"),
                          isXcode: isXcode, isBeta: beta)
}

/// Developer directories compare by path (a directory URL may end with a slash).
private func path(_ url: URL?) -> String? { url?.path }

struct XcodeLocatorTests {
    let release = install("Xcode", "27.2", "27B48")
    let olderRelease = install("Xcode-27.1", "27.1", "27A100")
    let beta = install("Xcode-beta", "27.3", "27C5012e", beta: true)

    @Test func keepsTheSelectedXcodeWhenItFits() {
        #expect(path(XcodeLocator.automatic(selected: selected("Xcode"), installs: [release, beta], macIsBeta: false)) == release.developerDir.path)
        #expect(path(XcodeLocator.automatic(selected: selected("Xcode-beta", beta: true), installs: [release, beta],
                                       macIsBeta: true)) == beta.developerDir.path)
    }

    @Test func prefersABetaXcodeOnAMacOSBeta() {
        #expect(path(XcodeLocator.automatic(selected: selected("Xcode"), installs: [release, beta], macIsBeta: true)) == beta.developerDir.path)
        // No beta installed: the selected release Xcode stays.
        #expect(path(XcodeLocator.automatic(selected: selected("Xcode-27.1"), installs: [release, olderRelease],
                                       macIsBeta: true)) == olderRelease.developerDir.path)
    }

    @Test func fallsBackWhenXcodeSelectPointsToCommandLineTools() {
        let tools = XcodeLocator.Selected(developerDir: URL(fileURLWithPath: "/Library/Developer/CommandLineTools"),
                                          isXcode: false, isBeta: false)
        #expect(path(XcodeLocator.automatic(selected: tools, installs: [olderRelease, beta, release], macIsBeta: false)) == release.developerDir.path)
        #expect(path(XcodeLocator.automatic(selected: tools, installs: [beta], macIsBeta: false)) == beta.developerDir.path)
        #expect(path(XcodeLocator.automatic(selected: tools, installs: [], macIsBeta: false)) == tools.developerDir.path)
        #expect(path(XcodeLocator.automatic(selected: nil, installs: [], macIsBeta: true)) == nil)
    }

    @Test func usesThePickedXcodeWhileItExists() {
        let picked = XcodeSelection.path(olderRelease.developerDir.path)
        #expect(path(XcodeLocator.resolve(picked, selected: selected("Xcode"), installs: [release, olderRelease],
                                     macIsBeta: false, hasXcodebuild: { _ in true })) == olderRelease.developerDir.path)
        // Gone: back to the automatic choice.
        #expect(path(XcodeLocator.resolve(picked, selected: selected("Xcode"), installs: [release],
                                     macIsBeta: false, hasXcodebuild: { _ in false })) == release.developerDir.path)
    }

    @Test func storesTheSelection() {
        #expect(XcodeSelection(rawValue: nil) == .automatic)
        #expect(XcodeSelection(rawValue: "auto") == .automatic)
        #expect(XcodeSelection(rawValue: "") == .automatic)
        #expect(XcodeSelection(rawValue: "/A/Xcode.app/Contents/Developer") == .path("/A/Xcode.app/Contents/Developer"))
        #expect(XcodeSelection.path("/x").rawValue == "/x")
        #expect(XcodeSelection.automatic.rawValue == "auto")
    }

    @Test func ordersByVersionThenBuild() {
        #expect(XcodeLocator.isNewer(install("A", "27.10", "1"), than: install("B", "27.9", "9")))
        #expect(XcodeLocator.isNewer(install("A", "27.2", "27B48"), than: install("B", "27.2", "27B12")))
        #expect(!XcodeLocator.isNewer(install("A", "27", "1"), than: install("B", "27.0.1", "1")))
    }

    @Test func findsXcodeAppsByBundleIdentifier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("Applications")
        let home = root.appendingPathComponent("home/Applications")
        func make(_ dir: URL, _ name: String, id: String, version: String?, build: String) throws {
            let contents = dir.appendingPathComponent("\(name)/Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Developer"),
                                                    withIntermediateDirectories: true)
            let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id],
                                                          format: .xml, options: 0)
            try info.write(to: contents.appendingPathComponent("Info.plist"))
            if let version {
                let plist = try PropertyListSerialization.data(
                    fromPropertyList: ["CFBundleShortVersionString": version, "ProductBuildVersion": build],
                    format: .xml, options: 0)
                try plist.write(to: contents.appendingPathComponent("version.plist"))
            }
        }
        try make(apps, "Xcode.app", id: "com.apple.dt.Xcode", version: "27.2", build: "27B48")
        try make(home, "Xcode-beta.app", id: "com.apple.dt.Xcode", version: "27.3", build: "27C5012e")
        try make(apps, "Safari.app", id: "com.apple.Safari", version: "19.0", build: "1")
        try make(apps, "Broken Xcode.app", id: "com.apple.dt.Xcode", version: nil, build: "")
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: apps.appendingPathComponent("Xcode-link.app"),
                                                   withDestinationURL: apps.appendingPathComponent("Xcode.app"))

        let found = XcodeLocator.find(in: [apps, home, root.appendingPathComponent("missing")])
        #expect(found.map(\.appURL.lastPathComponent) == ["Xcode-beta.app", "Xcode.app"])
        #expect(found.map(\.version) == ["27.3", "27.2"])
        #expect(found.map(\.isBeta) == [true, false])
        #expect(found.last?.developerDir.path.hasSuffix("Xcode.app/Contents/Developer") == true)
    }
}

struct ExpiryWatchTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(expiresIn: TimeInterval, error: String? = nil) -> AppRecord {
        AppRecord(id: UUID(), displayName: "App", originalBundleID: "com.x", signedBundleID: "com.x.t",
                  ipaPath: "a.ipa", options: InstallOptions(),
                  installations: [Installation(deviceID: "D1", installedAt: now, expiresAt: now.addingTimeInterval(expiresIn),
                                               lastErrorKey: error)],
                  teamID: "T")
    }

    @Test func schedulesTheReminderADayBeforeExpiry() {
        let expiry = now.addingTimeInterval(5 * 86_400)
        #expect(ExpiryWatch.reminderDate(expiresAt: expiry, now: now) == now.addingTimeInterval(4 * 86_400))
        #expect(ExpiryWatch.reminderDate(expiresAt: now.addingTimeInterval(3600), now: now) == nil)
        let id = UUID()
        #expect(ExpiryWatch.reminderID(recordID: id, deviceID: "D1") == "expiry.\(id.uuidString).D1")
    }

    @Test func flagsExpiredOrFailingApps() {
        let threshold: TimeInterval = 2 * 86_400
        #expect(!ExpiryWatch.needsAttention([record(expiresIn: 5 * 86_400)], now: now, threshold: threshold))
        #expect(ExpiryWatch.needsAttention([record(expiresIn: -60)], now: now, threshold: threshold))
        #expect(ExpiryWatch.needsAttention([record(expiresIn: 86_400, error: "deviceUnavailable")], now: now,
                                           threshold: threshold))
        // An error long before the threshold isn't urgent yet.
        #expect(!ExpiryWatch.needsAttention([record(expiresIn: 5 * 86_400, error: "deviceLocked")], now: now,
                                            threshold: threshold))
    }

    @Test func warnsBeforeQuittingWhileAppsAreValid() {
        #expect(ExpiryWatch.quitStopsRefreshes([record(expiresIn: 6 * 86_400)], now: now))
        #expect(!ExpiryWatch.quitStopsRefreshes([record(expiresIn: -60)], now: now))
        #expect(!ExpiryWatch.quitStopsRefreshes([record(expiresIn: 8 * 86_400)], now: now))
        #expect(!ExpiryWatch.quitStopsRefreshes([], now: now))
    }
}

struct KeychainVendorTests {
    @Test func readsTheVendorFromTheEmbeddedIdentifier() {
        #expect(Resigner.keychainVendor(["application-identifier": "EQHXZ8M8AV.com.google.ios.youtube"]) == "com.google")
        #expect(Resigner.keychainVendor(["application-identifier": "T.single"]) == "single")
        #expect(Resigner.keychainVendor(["application-identifier": "NOTEAM"]) == nil)
        #expect(Resigner.keychainVendor(["application-identifier": "T."]) == nil)
        #expect(Resigner.keychainVendor(nil) == nil)
    }
}

struct XcodeReadinessTests {
    let release = install("Xcode", "27.2", "27B48")
    let beta = install("Xcode-beta", "27.3", "27C5012e", beta: true)
    let olderBeta = install("Xcode-beta-2", "27.3", "27C5005a", beta: true)

    @Test func neverSwitchesToABetaThatIsNotReady() {
        let unready: Set = [beta.developerDir.path]
        #expect(path(XcodeLocator.automatic(selected: selected("Xcode"), installs: [release, beta], macIsBeta: true,
                                            unready: unready)) == release.developerDir.path)
        #expect(path(XcodeLocator.automatic(selected: selected("Xcode"), installs: [release, beta, olderBeta],
                                            macIsBeta: true, unready: unready)) == olderBeta.developerDir.path)
    }

    @Test func checksBetasOnlyWhenTheyMightBeUsed() {
        #expect(XcodeLocator.betasToCheck(selected: selected("Xcode"), installs: [olderBeta, release, beta],
                                          macIsBeta: true) == [beta, olderBeta])
        #expect(XcodeLocator.betasToCheck(selected: selected("Xcode"), installs: [beta], macIsBeta: false).isEmpty)
        #expect(XcodeLocator.betasToCheck(selected: selected("Xcode-beta", beta: true), installs: [beta],
                                          macIsBeta: true).isEmpty)
        let check = XcodeLocator.firstLaunchCheck(beta.developerDir)
        #expect(check.executable == "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild")
        #expect(check.arguments == ["-checkFirstLaunchStatus"])
    }
}
