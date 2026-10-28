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
