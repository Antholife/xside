import Testing
import Foundation
@testable import XSideCore

private func fixture(_ name: String) throws -> Data {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    return try Data(contentsOf: dir.appendingPathComponent(name))
}

struct DeviceTests {
    @Test func usbDevice() throws {
        let devices = try DeviceService.parse(fixture("devices-usb.json"))
        #expect(devices.count == 1) // simulated one excluded
        let d = devices[0]
        #expect(d.kind == .iPhone)
        #expect(d.model == "iPhone 17 Pro Max")
        #expect(d.transport == .usb)
        #expect(d.isPaired)
        #expect(d.isAvailable)
        #expect(d.developerModeEnabled == true)
        #expect(d.id == "AAAAAAAA-0000-0000-0000-000000000001")
        #expect(d.udid == "00008150-000AAAAAAAAAAA01")
        #expect(d.name == "iPhone de Test")
    }

    @Test func networkDevice() throws {
        let d = try DeviceService.parse(fixture("devices-network.json"))[0]
        #expect(d.kind == .iPad)
        #expect(d.model == "iPad Air (5th generation)")
        #expect(d.transport == .network)
        #expect(d.isPaired && d.isAvailable)
    }

    @Test func discoveredUnpairedDevice() throws {
        let d = try DeviceService.parse(fixture("devices-unpaired.json"))[0]
        #expect(d.kind == .iPhone)
        #expect(d.transport == .none)
        #expect(!d.isPaired)
        #expect(!d.isAvailable)
        #expect(d.developerModeEnabled == nil)
    }

    @Test func unavailableDevices() throws {
        let devices = try DeviceService.parse(fixture("devices-unavailable.json"))
        #expect(devices.count == 2)
        #expect(Set(devices.map(\.id)).count == 2)
        #expect(devices.map(\.kind) == [.iPad, .iPhone])
        for d in devices {
            #expect(d.transport == .none)
            #expect(d.isPaired)
            #expect(!d.isAvailable)
            #expect(d.developerModeEnabled == true)
        }
    }

    @Test func listUsesJsonOutput() async throws {
        let json = try fixture("devices-usb.json")
        let runner = FakeRunner()
        runner.stub("/usr/bin/xcrun", firstArg: "devicectl",
                    result: CommandResult(status: 0, stdout: Data(), stderr: ""),
                    effect: { args in
                        if let i = args.firstIndex(of: "--json-output") {
                            try? json.write(to: URL(fileURLWithPath: args[i + 1]))
                        }
                    })
        let devices = try await DeviceService(runner: runner).list()
        #expect(devices.count == 1)
        let call = runner.calls[0]
        #expect(Array(call.prefix(5)) == ["/usr/bin/xcrun", "devicectl", "list", "devices", "--json-output"])
        #expect(call.count == 6)
    }

    @Test func pairRunsDevicectl() async throws {
        let runner = FakeRunner()
        runner.stub("/usr/bin/xcrun", result: CommandResult(status: 0, stdout: Data(), stderr: ""))
        try await DeviceService(runner: runner).pair("ID1")
        #expect(runner.calls == [["/usr/bin/xcrun", "devicectl", "manage", "pair", "--device", "ID1"]])
    }

    @Test func pairFailureMapsToDeviceUnavailable() async {
        let runner = FakeRunner()
        runner.stub("/usr/bin/xcrun", result: CommandResult(status: 1, stdout: Data(), stderr: "nope"))
        await #expect(throws: XSideError.deviceUnavailable) {
            try await DeviceService(runner: runner).pair("ID1")
        }
    }
}
