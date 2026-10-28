import Testing
import Foundation
@testable import XSideCore

@Suite struct SuccessNotificationGateTests {
    private let rec = UUID()
    private let d1 = Date(timeIntervalSince1970: 1_800_000_000)
    private let d2 = Date(timeIntervalSince1970: 1_800_600_000)

    @Test func firstInstallIsNotNotified() {
        var g = SuccessNotificationGate()
        let r1 = g.shouldNotify(recordID: rec, deviceID: "a", expiresAt: d1, wasRefresh: false)
        #expect(!r1)
    }

    @Test func sameExpiryNotifiedOnce() {
        var g = SuccessNotificationGate()
        let r2 = g.shouldNotify(recordID: rec, deviceID: "a", expiresAt: d1, wasRefresh: true)
        #expect(r2)
        let r3 = g.shouldNotify(recordID: rec, deviceID: "a", expiresAt: d1, wasRefresh: true)
        #expect(!r3)
    }

    @Test func newExpiryOrOtherPairNotifies() {
        var g = SuccessNotificationGate()
        let r4 = g.shouldNotify(recordID: rec, deviceID: "a", expiresAt: d1, wasRefresh: true)
        #expect(r4)
        let r5 = g.shouldNotify(recordID: rec, deviceID: "a", expiresAt: d2, wasRefresh: true)
        #expect(r5)
        let r6 = g.shouldNotify(recordID: rec, deviceID: "b", expiresAt: d2, wasRefresh: true)
        #expect(r6)
        let r7 = g.shouldNotify(recordID: UUID(), deviceID: "a", expiresAt: d2, wasRefresh: true)
        #expect(r7)
    }

    @Test func forgetAllowsRetry() {
        var g = SuccessNotificationGate()
        let r8 = g.shouldNotify(recordID: rec, deviceID: "a", expiresAt: d1, wasRefresh: true)
        #expect(r8)
        g.forget(recordID: rec, deviceID: "a")
        let r9 = g.shouldNotify(recordID: rec, deviceID: "a", expiresAt: d1, wasRefresh: true)
        #expect(r9)
    }
}
