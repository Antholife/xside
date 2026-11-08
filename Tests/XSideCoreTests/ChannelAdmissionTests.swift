import Foundation
import Testing
@testable import XSideCore

/// Final review minor 8: who gets one of the channel server's connection slots.
@Suite struct ChannelAdmissionTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func perPeerLimitsStay() {
        var a = ChannelAdmission<Int>()
        for i in 0..<4 { #expect(a.admit(i, remote: "a", now: t0) == .accept) }
        #expect(a.admit(4, remote: "a", now: t0) == .drop) // 4 open at once from one address
        a.ended(0)
        #expect(a.admit(5, remote: "a", now: t0) == .accept)
        var b = ChannelAdmission<Int>()
        for i in 0..<20 {
            #expect(b.admit(i, remote: "b", now: t0.addingTimeInterval(Double(i))) == .accept)
            b.ended(i)
        }
        #expect(b.admit(20, remote: "b", now: t0.addingTimeInterval(30)) == .drop) // 20 a minute
        #expect(b.admit(21, remote: "b", now: t0.addingTimeInterval(61)) == .accept)
    }

    /// Peers that connect and send nothing can't keep phones out: when every slot is taken, the
    /// oldest connection still waiting for its first line makes room.
    @Test func idleConnectionsMakeRoom() {
        var a = ChannelAdmission<Int>()
        for i in 0..<16 { #expect(a.admit(i, remote: "peer\(i / 4)", now: t0.addingTimeInterval(Double(i))) == .accept) }
        a.gotLine(0) // a phone's request, being answered
        #expect(a.admit(100, remote: "phone", now: t0.addingTimeInterval(20)) == .acceptEvicting(1))
        a.ended(1)
        #expect(a.openCount == 16)
    }

    /// Connections that sent their line (authenticated or answered at once) are never evicted.
    @Test func answeredConnectionsAreKept() {
        var a = ChannelAdmission<Int>()
        for i in 0..<16 {
            _ = a.admit(i, remote: "p\(i / 4)", now: t0)
            a.gotLine(i)
        }
        #expect(a.admit(100, remote: "phone", now: t0) == .drop)
    }
}
