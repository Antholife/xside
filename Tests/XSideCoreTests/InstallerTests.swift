import Testing
import Foundation
@testable import XSideCore

private let unreachable = """
ERROR: The device is not able to fulfill the requested usage assertion requirements. (com.apple.dt.CoreDeviceError error 4016 (0xFB0))
  CurrentlyAssertableStates = [unavailable]
  RequestedDeviceStates = [connected]
"""

@Suite struct InstallerTests {
    @Test func installCommand() async throws {
        let runner = FakeRunner()
        runner.stub("/usr/bin/xcrun", result: CommandResult(status: 0, stdout: Data("App installed:\n".utf8), stderr: ""))
        try await Installer(runner: runner).install(app: URL(fileURLWithPath: "/tmp/Fake.app"), deviceID: "FAKE-DEVICE")
        #expect(runner.calls == [["/usr/bin/xcrun", "devicectl", "device", "install", "app",
                                  "--device", "FAKE-DEVICE", "/tmp/Fake.app"]])
    }

    @Test func mapsKnownErrors() {
        #expect(Installer.mapError(unreachable) == .deviceUnavailable)
        #expect(Installer.mapError("ERROR: Unable to install: the device is locked.") == .deviceLocked)
        #expect(Installer.mapError("ERROR: Please enter the passcode on the device") == .deviceLocked)
        #expect(Installer.mapError("ERROR: The device rejected the install.\n  Developer Mode is disabled on this device.")
                == .developerModeDisabled)
        #expect(Installer.mapError("ERROR: Maximum number of apps for free development profiles has been reached") == .maxAppsReached)
        #expect(Installer.mapError("ERROR: You cannot install more than 3 apps") == .maxAppsReached)
        #expect(Installer.mapError("ERROR: Boom happened\n  detail") == .installFailed("Boom happened"))
        #expect(Installer.mapError("nothing useful") == .commandFailed(tool: "devicectl", status: -1))
    }

    @Test func ignoresCauseWordsOutsideErrorLines() {
        // App names and progress lines aren't causes.
        #expect(Installer.mapError("Installing Locked Notes.app\nERROR: Not enough storage")
                == .installFailed("Not enough storage"))
        #expect(Installer.mapError("ERROR: Failed to install “Passcode Locked Vault”: storage full")
                == .installFailed("Failed to install “Passcode Locked Vault”: storage full"))
        #expect(Installer.mapError("ERROR: Could not install Locked.app (bad signature)")
                == .installFailed("Could not install Locked.app (bad signature)"))
        #expect(Installer.mapError("Copying 3 apps worth of data\nthe device is locked") == .commandFailed(tool: "devicectl", status: -1))
        // Known codes count anywhere; a full-apps cause wins over a locked one.
        #expect(Installer.mapError("ERROR: Failed\n  domain: MaximumAppsReached") == .maxAppsReached)
        #expect(Installer.mapError("ERROR: The device is locked\nERROR: You cannot install more than 3 apps") == .maxAppsReached)
    }

    @Test func findsTheCauseBelowAGenericErrorLine() {
        let locked = """
        12:01:02  Acquired tunnel connection to device.
        ERROR: Failed to install the app on the device. (com.apple.dt.CoreDeviceError error 3002 (0xBBA))
               BundleIdentifier = com.example.demo.TEAM123456
               NSURL = file:///Users/me/Library/Application%20Support/XSide/work/jobs/x/Payload/Locked%20Notes.app/
            Underlying error (domain=com.apple.dt.CoreDeviceError, code=4000):
               The device is locked.
               NSLocalizedRecoverySuggestion = Unlock the device and try again.
        """
        #expect(Installer.mapError(locked) == .deviceLocked)
        let full = """
        ERROR: Failed to install the app on the device. (com.apple.dt.CoreDeviceError error 3002 (0xBBA))
        Underlying error (domain=com.apple.dt.MobileInstallation, code=-402620383):
            This device has reached the maximum number of installed apps using a free developer profile.
        """
        #expect(Installer.mapError(full) == .maxAppsReached)
        // The first ERROR line stays the message when no cause is recognized.
        let other = """
        ERROR: Failed to install the app on the device. (com.apple.dt.CoreDeviceError error 3002 (0xBBA))
            Underlying error (domain=NSPOSIXErrorDomain, code=28):
               No space left on device
        Installing “Passcode Locked Vault”…
        """
        #expect(Installer.mapError(other) == .installFailed("Failed to install the app on the device. (com.apple.dt.CoreDeviceError error 3002 (0xBBA))"))
    }

    @Test func installThrowsMappedError() async {
        let runner = FakeRunner()
        runner.stub("/usr/bin/xcrun", result: CommandResult(status: 1, stdout: Data(), stderr: unreachable))
        await #expect(throws: XSideError.deviceUnavailable) {
            try await Installer(runner: runner).install(app: URL(fileURLWithPath: "/tmp/Fake.app"), deviceID: "X")
        }
        let r2 = FakeRunner()
        r2.stub("/usr/bin/xcrun", result: CommandResult(status: 7, stdout: Data(), stderr: ""))
        await #expect(throws: XSideError.commandFailed(tool: "devicectl", status: 7)) {
            try await Installer(runner: r2).install(app: URL(fileURLWithPath: "/tmp/Fake.app"), deviceID: "X")
        }
    }
}

@Suite struct UninstallerTests {
    @Test func uninstallCommand() async throws {
        let runner = FakeRunner()
        runner.stub("/usr/bin/xcrun", result: CommandResult(status: 0, stdout: Data("App uninstalled.\n".utf8), stderr: ""))
        try await Installer(runner: runner).uninstall(bundleID: "com.example.demo.TEAM123456", deviceID: "FAKE-DEVICE")
        #expect(runner.calls == [["/usr/bin/xcrun", "devicectl", "device", "uninstall", "app",
                                  "--device", "FAKE-DEVICE", "com.example.demo.TEAM123456"]])
        #expect(runner.timeouts == [CommandTimeout.deviceInstall])
    }

    @Test func appAlreadyGoneIsASuccess() async throws {
        let samples = [
            """
            ERROR: Failed to uninstall the app. (com.apple.dt.CoreDeviceError error 1005 (0x3ED))
                   BundleIdentifier = com.example.demo.TEAM123456
                Underlying error (domain=com.apple.dt.CoreDeviceError, code=1005):
                   The app com.example.demo.TEAM123456 is not installed on the device.
            """,
            "ERROR: No such app: com.example.demo.TEAM123456",
            "ERROR: There is no app with bundle identifier com.example.demo.TEAM123456 on the device.",
        ]
        for sample in samples {
            #expect(Installer.mapUninstallError(sample) == nil)
            let runner = FakeRunner()
            runner.stub("/usr/bin/xcrun", result: CommandResult(status: 1, stdout: Data(), stderr: sample))
            try await Installer(runner: runner).uninstall(bundleID: "com.example.demo.TEAM123456", deviceID: "X")
        }
    }

    @Test func anUnreachableDeviceIsUnavailable() {
        // devicectl's answer for an unplugged iPhone (2026-11-05).
        let output = """
            ERROR: This device is not currently reachable. (com.apple.dt.CoreDeviceError error 1011 (0x3F3))
                   DeviceIdentifier = ecid_1
            """
        #expect(Installer.mapUninstallError(output) == .deviceUnavailable)
        #expect(Installer.mapError(output) == .deviceUnavailable)
    }

    @Test func mapsFailures() {
        #expect(Installer.mapUninstallError(unreachable) == .deviceUnavailable)
        #expect(Installer.mapUninstallError("ERROR: Unable to uninstall: the device is locked.") == .deviceLocked)
        #expect(Installer.mapUninstallError("ERROR: Failed to uninstall the app.\n  detail")
                == .uninstallFailed("Failed to uninstall the app."))
        #expect(Installer.mapUninstallError("nothing useful") == .commandFailed(tool: "devicectl", status: -1))
        // Names and lines outside error blocks never pass for "already gone".
        #expect(Installer.mapUninstallError("ERROR: Failed to uninstall “Is Not Installed”")
                == .uninstallFailed("Failed to uninstall “Is Not Installed”"))
        #expect(Installer.mapUninstallError("The app is not installed\nERROR: Connection lost")
                == .uninstallFailed("Connection lost"))
        // An unreachable device wins over any other line.
        #expect(Installer.mapUninstallError(unreachable + "\nERROR: The app is not installed") == .deviceUnavailable)
    }

    @Test func uninstallThrowsMappedError() async {
        let runner = FakeRunner()
        runner.stub("/usr/bin/xcrun", result: CommandResult(status: 1, stdout: Data(), stderr: unreachable))
        await #expect(throws: XSideError.deviceUnavailable) {
            try await Installer(runner: runner).uninstall(bundleID: "com.example.demo", deviceID: "X")
        }
        let r2 = FakeRunner()
        r2.stub("/usr/bin/xcrun", result: CommandResult(status: 7, stdout: Data(), stderr: ""))
        await #expect(throws: XSideError.commandFailed(tool: "devicectl", status: 7)) {
            try await Installer(runner: r2).uninstall(bundleID: "com.example.demo", deviceID: "X")
        }
    }
}

/// devicectl's `device info apps --json-output` shape (trimmed): `result.apps[].bundleIdentifier`.
private func appsJSON(_ ids: [String]) -> String {
    let apps = ids.map { #"{"bundleIdentifier":"\#($0)","name":"App","removable":true}"# }.joined(separator: ",")
    return #"{"info":{"outcome":"success"},"result":{"apps":[\#(apps)],"defaultAppsIncluded":false}}"#
}

/// Stubs `devicectl device info apps`: writes `json` to the --json-output path, exits `status`.
private func stubApps(_ runner: FakeRunner, json: String?, status: Int32 = 0) {
    runner.stub("/usr/bin/xcrun", result: CommandResult(status: status, stdout: Data(), stderr: "")) { args in
        guard let json, let i = args.firstIndex(of: "--json-output"), i + 1 < args.count else { return }
        try? Data(json.utf8).write(to: URL(fileURLWithPath: args[i + 1]))
    }
}

@Suite struct InstalledCheckTests {
    @Test func parsesTheBundleIDs() {
        #expect(Installer.installedBundleIDs(Data(appsJSON(["a.b.TEAM", "c.d"]).utf8)) == ["a.b.TEAM", "c.d"])
        #expect(Installer.installedBundleIDs(Data(appsJSON([]).utf8)) == [])
    }

    @Test func unreadableOutputIsUnknown() {
        #expect(Installer.installedBundleIDs(Data("nope".utf8)) == nil)
        #expect(Installer.installedBundleIDs(Data(#"{"result":{}}"#.utf8)) == nil)
    }

    @Test func asksDevicectlForThatApp() async throws {
        let runner = FakeRunner()
        stubApps(runner, json: appsJSON(["com.x.TEAM"]))
        #expect(await Installer(runner: runner).isInstalled(bundleID: "com.x.TEAM", deviceID: "DEV") == true)
        let call = try #require(runner.calls.first)
        #expect(Array(call.prefix(8)) == ["/usr/bin/xcrun", "devicectl", "device", "info", "apps",
                                         "--device", "DEV", "--include-all-apps"])
        #expect(call.contains("--json-output"))
    }

    @Test func missingFromTheListIsNotInstalled() async {
        let runner = FakeRunner()
        stubApps(runner, json: appsJSON(["com.apple.mobilesafari"]))
        #expect(await Installer(runner: runner).isInstalled(bundleID: "com.x.TEAM", deviceID: "DEV") == false)
    }

    /// Never a guess: a failed or unreadable query must not make XSide forget an app.
    @Test func failedQueryIsUnknown() async {
        let failing = FakeRunner()
        stubApps(failing, json: appsJSON([]), status: 1)
        #expect(await Installer(runner: failing).isInstalled(bundleID: "com.x.TEAM", deviceID: "DEV") == nil)
        let garbled = FakeRunner()
        stubApps(garbled, json: "{}")
        #expect(await Installer(runner: garbled).isInstalled(bundleID: "com.x.TEAM", deviceID: "DEV") == nil)
        let thrown = FakeRunner() // no stub: the runner throws
        #expect(await Installer(runner: thrown).isInstalled(bundleID: "com.x.TEAM", deviceID: "DEV") == nil)
    }
}

@Suite struct DeviceAppListTests {
    @Test func listsTheDevicesApps() async throws {
        let runner = FakeRunner()
        stubApps(runner, json: appsJSON(["a.T", "b.T"]))
        #expect(await Installer(runner: runner).installedBundleIDs(deviceID: "DEV") == ["a.T", "b.T"])
        let call = try #require(runner.calls.first)
        #expect(Array(call.prefix(8)) == ["/usr/bin/xcrun", "devicectl", "device", "info", "apps", "--device", "DEV",
                                         "--include-all-apps"])
    }

    /// A device always has system apps: an empty list is a bad read, not "every app deleted".
    @Test func emptyListIsUnknown() async {
        let runner = FakeRunner()
        stubApps(runner, json: appsJSON([]))
        #expect(await Installer(runner: runner).installedBundleIDs(deviceID: "DEV") == nil)
        #expect(await Installer(runner: runner).isInstalled(bundleID: "a.T", deviceID: "DEV") == nil)
    }

    @Test func failedListIsUnknown() async {
        let runner = FakeRunner()
        stubApps(runner, json: appsJSON([]), status: 1)
        #expect(await Installer(runner: runner).installedBundleIDs(deviceID: "DEV") == nil)
    }
}

@Suite struct TrustSettingsTests {
    /// Settings > General > VPN & Device Management, opened on the device itself.
    @Test func opensTheTrustPageInSettings() async throws {
        let runner = FakeRunner()
        runner.stub("/usr/bin/xcrun", result: CommandResult(status: 0, stdout: Data(), stderr: ""))
        try await Installer(runner: runner).openTrustSettings(deviceID: "DEV")
        #expect(runner.calls == [["/usr/bin/xcrun", "devicectl", "device", "process", "launch", "--device", "DEV",
                                  "--terminate-existing", "--payload-url",
                                  "prefs:root=General&path=ManagedConfigurationList", "com.apple.Preferences"]])
    }

    @Test func failureIsReported() async {
        let runner = FakeRunner()
        runner.stub("/usr/bin/xcrun", result: CommandResult(status: 1, stdout: Data(), stderr: unreachable))
        await #expect(throws: XSideError.deviceUnavailable) {
            try await Installer(runner: runner).openTrustSettings(deviceID: "DEV")
        }
    }
}

private let untrustedLaunch = """
ERROR: The application failed to launch. (com.apple.dt.CoreDeviceError error 10002 (0x2712))
       NSLocalizedRecoverySuggestion = Provide a valid bundle identifier.
       ----------------------------------------
       The request was denied by service delegate (SBMainWorkspace) for reason: Security ("Unable to launch com.x.TEAM because it has an invalid code signature, inadequate entitlements or its profile has not been explicitly trusted by the user").
"""

private let lockedLaunch = """
ERROR: The application failed to launch. (com.apple.dt.CoreDeviceError error 10002 (0x2712))
       The request was denied by service delegate (SBMainWorkspace) for reason: Locked ("Unable to launch com.x.TEAM because the device was not, or could not be, unlocked").
"""

@Suite struct TrustCheckTests {
    /// Started only to ask: stopped right away.
    @Test func launchedMeansTrustedAndIsStoppedAgain() async throws {
        let runner = FakeRunner()
        runner.stub("/usr/bin/xcrun", result: CommandResult(status: 0, stdout: Data("Launched application".utf8), stderr: "")) { args in
            guard let i = args.firstIndex(of: "--json-output") else { return }
            try? Data(#"{"result":{"process":{"processIdentifier":4321}}}"#.utf8).write(to: URL(fileURLWithPath: args[i + 1]))
        }
        #expect(await Installer(runner: runner).trustState(bundleID: "com.x.TEAM", deviceID: "DEV") == .trusted)
        let calls = runner.calls
        #expect(calls.count == 2)
        #expect(Array(calls[0].prefix(7)) == ["/usr/bin/xcrun", "devicectl", "device", "process", "launch", "--device", "DEV"])
        #expect(calls[0].contains("--no-activate"))
        #expect(calls[0].last == "com.x.TEAM")
        #expect(calls[1] == ["/usr/bin/xcrun", "devicectl", "device", "process", "terminate", "--device", "DEV",
                             "--pid", "4321"])
    }

    @Test func launchedWithoutAProcessIDIsStillTrusted() async {
        let runner = FakeRunner()
        runner.stub("/usr/bin/xcrun", result: CommandResult(status: 0, stdout: Data(), stderr: ""))
        #expect(await Installer(runner: runner).trustState(bundleID: "com.x.TEAM", deviceID: "DEV") == .trusted)
        #expect(runner.calls.count == 1) // nothing to stop
    }

    @Test func securityRefusalMeansNotTrusted() async {
        let runner = FakeRunner()
        runner.stub("/usr/bin/xcrun", result: CommandResult(status: 1, stdout: Data(), stderr: untrustedLaunch))
        #expect(await Installer(runner: runner).trustState(bundleID: "com.x.TEAM", deviceID: "DEV") == .untrusted)
    }

    /// Anything else says nothing about trust.
    @Test func otherFailuresAreUnknown() async {
        for output in [lockedLaunch, unreachable, "garbage"] {
            let runner = FakeRunner()
            runner.stub("/usr/bin/xcrun", result: CommandResult(status: 1, stdout: Data(), stderr: output))
            #expect(await Installer(runner: runner).trustState(bundleID: "com.x.TEAM", deviceID: "DEV") == .unknown)
        }
        #expect(await Installer(runner: FakeRunner()).trustState(bundleID: "com.x.TEAM", deviceID: "DEV") == .unknown)
    }
}
