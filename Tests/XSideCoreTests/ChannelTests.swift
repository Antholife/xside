import Testing
import Foundation
@testable import XSideCore

@Suite struct ChannelTests {
    let secret = Data(repeating: 7, count: 32)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func seal(_ r: ChannelRequest = .refresh, secret: Data? = nil, at: Date? = nil, nonce: String = "n1") throws -> ChannelEnvelope {
        try ChannelEnvelope.seal(r, installationID: "rec|dev", secret: secret ?? self.secret, now: at ?? now, nonce: nonce)
    }

    @Test func sealedRequestOpensWithTheSameSecret() throws {
        var seen = NonceCache()
        let settings = InAppSettings.defaults(reminder: true, at: now)
        let req = ChannelRequest.checkIn(settings: settings, lastRefresh: RefreshOutcome(at: now, succeeded: false, reasonKey: "k"), appVersion: "2.0")
        let env = try seal(req)
        #expect(env.open(secret: secret, now: now, seen: &seen) == req)
    }

    @Test func wrongSecretIsRejected() throws {
        var seen = NonceCache()
        let env = try seal()
        #expect(env.open(secret: Data(repeating: 8, count: 32), now: now, seen: &seen) == nil)
    }

    @Test func staleOrFutureTimestampIsRejected() throws {
        var seen = NonceCache()
        #expect(try seal(at: now.addingTimeInterval(-120), nonce: "a").open(secret: secret, now: now, seen: &seen) == .refresh)
        #expect(try seal(at: now.addingTimeInterval(120), nonce: "b").open(secret: secret, now: now, seen: &seen) == .refresh)
        #expect(try seal(at: now.addingTimeInterval(-121), nonce: "c").open(secret: secret, now: now, seen: &seen) == nil)
        #expect(try seal(at: now.addingTimeInterval(121), nonce: "d").open(secret: secret, now: now, seen: &seen) == nil)
    }

    @Test func replayedNonceIsRejected() throws {
        var seen = NonceCache()
        let env = try seal()
        #expect(env.open(secret: secret, now: now, seen: &seen) == .refresh)
        #expect(env.open(secret: secret, now: now.addingTimeInterval(5), seen: &seen) == nil)
    }

    @Test func rejectedRequestsDoNotBurnTheNonce() throws {
        var seen = NonceCache()
        let env = try seal()
        #expect(env.open(secret: Data(repeating: 8, count: 32), now: now, seen: &seen) == nil)
        #expect(env.open(secret: secret, now: now, seen: &seen) == .refresh)
    }

    @Test func nonceCacheIsBoundedAndKeepsNoncesForTheWholeWindow() {
        var c = NonceCache(capacity: 4)
        for i in 0..<10 { let ok = c.insert("n\(i)", at: now); #expect(ok) }
        #expect(c.count == 4)
        var d = NonceCache()
        let first = d.insert("x", at: now)
        // Still remembered 240 s later (a future-dated request stays acceptable that long).
        let again = d.insert("x", at: now.addingTimeInterval(240))
        // Forgotten once it can no longer pass the window check.
        let late = d.insert("x", at: now.addingTimeInterval(400))
        #expect(first && !again && late)
    }

    @Test func tamperedBodyIsRejected() throws {
        var seen = NonceCache()
        var env = try seal()
        env.body = try ChannelEnvelope.encodeBody(.setAutoRefresh(false))
        #expect(env.open(secret: secret, now: now, seen: &seen) == nil)
        var other = try seal(nonce: "z")
        other.installationID = "rec|other"
        #expect(other.open(secret: secret, now: now, seen: &seen) == nil)
    }

    static let fixtureSecretHex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
    static let fixtureMAC = "4McQUiU/zGGdkAvFuzmmVje88inM1VhBlOgAMVt8ypM="

    @Test func knownFixtureMatchesTheDylibFormat() throws {
        let fixtureSecret = Data((1...32).map { UInt8($0) })
        #expect(fixtureSecret.map { String(format: "%02x", $0) }.joined() == Self.fixtureSecretHex)
        let ts: Int64 = 1_800_000_000_000
        let env = try ChannelEnvelope.seal(.refresh, installationID: "rec|dev", secret: fixtureSecret,
                                           timestampMillis: ts, nonce: "n1")
        #expect(String(decoding: env.body, as: UTF8.self) == #"{"type":"refresh"}"#)
        #expect(env.mac.base64EncodedString() == Self.fixtureMAC)
        var seen = NonceCache()
        let wire = ChannelEnvelope(installationID: "rec|dev", timestamp: ts, nonce: "n1",
                                   body: Data(#"{"type":"refresh"}"#.utf8), mac: Data(base64Encoded: Self.fixtureMAC) ?? Data())
        #expect(wire.open(secret: fixtureSecret, now: Date(timeIntervalSince1970: 1_800_000_000), seen: &seen) == .refresh)
    }

    @Test func fixtureFileMatchesTheTest() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/channel-fixture.json")
        let j = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(j["secretHex"] as? String == Self.fixtureSecretHex)
        #expect(j["mac"] as? String == Self.fixtureMAC)
    }

    @Test func wireLineRoundTrips() throws {
        let env = try seal()
        let line = try env.encodedLine()
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        #expect(try ChannelEnvelope.decode(line: line) == env)
    }

    @Test func repliesRoundTrip() throws {
        let s = InAppSettings.defaults(reminder: false, at: now)
        let all: [ChannelReply] = [.settings(s), .accepted, .refreshed, .failed(reasonKey: "r"), .busy,
                                   .deviceUnreachable, .paused(by: .mac), .paused(by: .device), .rejected]
        for r in all {
            #expect(try ChannelReply.decode(line: r.encodedLine()) == r)
        }
        #expect(String(decoding: try ChannelReply.paused(by: .mac).encodedLine(), as: UTF8.self) == "{\"by\":\"mac\",\"type\":\"paused\"}\n")
    }

    @Test func requestsRoundTripAndUseFlatJSON() throws {
        for r in [ChannelRequest.refresh, .setAutoRefresh(true), .checkIn(settings: .defaults(reminder: true, at: now), lastRefresh: nil, appVersion: nil)] {
            let body = try ChannelEnvelope.encodeBody(r)
            #expect(try JSONDecoder.channel.decode(ChannelRequest.self, from: body) == r)
        }
        #expect(String(decoding: try ChannelEnvelope.encodeBody(.setAutoRefresh(true)), as: UTF8.self) == #"{"on":true,"type":"setAutoRefresh"}"#)
    }

    @Test func secretsAndIDs() {
        #expect(ChannelEnvelope.newSecret().count == 32)
        #expect(ChannelEnvelope.newSecret() != ChannelEnvelope.newSecret())
        let id = UUID()
        #expect(ChannelEnvelope.installationID(recordID: id, deviceID: "D1") == "\(id.uuidString)|D1")
    }
}
