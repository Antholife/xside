import Foundation
import Testing
@testable import XSideCore

@Suite struct WifiCheckTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func device(_ transport: Transport, available: Bool = true) -> Device {
        Device(id: "D1", udid: nil, name: "iPhone", model: "iPhone", kind: .iPhone, transport: transport, isPaired: true,
               isAvailable: available, developerModeEnabled: true)
    }

    @Test func staysWaitingWhilePluggedIn() {
        var check = WifiCheck(startedAt: t0)
        #expect(check.observe(device(.usb), at: t0.addingTimeInterval(3)) == .waitingForUnplug)
        #expect(!check.needsNudge)
    }

    @Test func nudgesAfterAMinutePluggedIn() {
        var check = WifiCheck(startedAt: t0)
        check.observe(device(.usb), at: t0.addingTimeInterval(61))
        #expect(check.status == .waitingForUnplug)
        #expect(check.needsNudge)
    }

    @Test func succeedsWhenReachableOverNetwork() {
        var check = WifiCheck(startedAt: t0)
        check.observe(device(.usb), at: t0.addingTimeInterval(3))
        check.observe(nil, at: t0.addingTimeInterval(6))
        #expect(check.status == .checking)
        #expect(check.observe(device(.network), at: t0.addingTimeInterval(9)) == .ok)
    }

    @Test func failsSixtySecondsAfterUnplugging() {
        var check = WifiCheck(startedAt: t0)
        check.observe(device(.none, available: false), at: t0.addingTimeInterval(10))
        #expect(check.status == .checking)
        #expect(check.observe(nil, at: t0.addingTimeInterval(69)) == .checking)
        #expect(check.observe(nil, at: t0.addingTimeInterval(70)) == .failed)
        // Final.
        #expect(check.observe(device(.network), at: t0.addingTimeInterval(75)) == .failed)
    }

    @Test func windowStartsAtUnplugNotAtStart() {
        var check = WifiCheck(startedAt: t0)
        check.observe(device(.usb), at: t0.addingTimeInterval(50))
        check.observe(nil, at: t0.addingTimeInterval(55))
        #expect(check.observe(nil, at: t0.addingTimeInterval(110)) == .checking)
    }

    @Test func networkButUnavailableIsNotOK() {
        var check = WifiCheck(startedAt: t0)
        #expect(check.observe(device(.network, available: false), at: t0.addingTimeInterval(3)) == .checking)
    }
}
