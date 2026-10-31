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
