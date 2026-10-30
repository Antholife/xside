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
