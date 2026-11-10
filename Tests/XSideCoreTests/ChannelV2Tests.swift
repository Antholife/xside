import Testing
import Foundation
import CryptoKit
@testable import XSideCore

/// Channel v2 (mega review C2): bodies encrypted (AES-256-CTR, random IV), an opaque token instead
/// of the installation id, encrypt-then-MAC with keys derived from the secret (HKDF-SHA256). See
/// the wire format at the top of Channel.swift.
@Suite struct ChannelV2Tests {
    let secret = Data(repeating: 7, count: 32)
    let id = "rec|dev"
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let iv = Data((0..<16).map { UInt8(0xA0 + $0) })

    func seal(_ r: ChannelRequest = .refresh, secret: Data? = nil, at: Date? = nil, nonce: String = "n1",
              iv: Data? = nil) throws -> ChannelEnvelopeV2 {
        try ChannelEnvelopeV2.seal(r, secret: secret ?? self.secret, timestampMillis: channelMillis(at ?? now)!,
                                   nonce: nonce, iv: iv ?? self.iv)
    }

    func open(_ e: ChannelEnvelopeV2, secret: Data? = nil, at: Date? = nil, seen: inout NonceCache) -> ChannelRequest? {
        e.open(keys: ChannelKeys(secret: secret ?? self.secret), installationID: id, now: at ?? now, seen: &seen)
    }

    /// The JSON object of a sealed line, to tamper with one field.
    func object(_ e: ChannelEnvelopeV2) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try e.encodedLine().dropLast()) as! [String: Any]
    }

    func lineData(_ o: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: keys

    @Test func keysAreDerivedWithHKDFAndSeparate() {
        let k = ChannelKeys(secret: secret)
        let salt = Data("XSide channel v2".utf8)
        func hkdf(_ info: String, _ n: Int) -> Data {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt, info: Data(info.utf8),
                                   outputByteCount: n).withUnsafeBytes { Data($0) }
        }
        #expect(k.encryption == hkdf("enc", 32) && k.authentication == hkdf("mac", 32) && k.token == hkdf("token", 16))
        #expect(k.encryption != k.authentication && k.encryption.prefix(16) != k.token && k.encryption != secret)
        // HKDF's first block by hand (what the dylib computes with CCHmac): HMAC(PRK, info | 0x01).
        let prk = Data(HMAC<SHA256>.authenticationCode(for: secret, using: SymmetricKey(data: salt)))
        let t1 = Data(HMAC<SHA256>.authenticationCode(for: Data("token".utf8) + Data([1]), using: SymmetricKey(data: prk)))
        #expect(k.token == t1.prefix(16))
        // Another secret (a new signing): every key changes.
        let other = ChannelKeys(secret: Data(repeating: 8, count: 32))
        #expect(other.token != k.token && other.encryption != k.encryption && other.authentication != k.authentication)
    }

    // MARK: requests

    @Test func sealedRequestOpensAndHidesTheBody() throws {
        var seen = NonceCache()
        let settings = InAppSettings.defaults(reminder: true, at: now)
        let req = ChannelRequest.checkIn(settings: settings, lastRefresh: RefreshOutcome(at: now, succeeded: false, reasonKey: "refresh.reason.offline"),
                                         appVersion: "2.0", previousRun: PreviousRun(ended: .crashed, since: now))
        let e = try ChannelEnvelopeV2.seal(req, secret: secret, now: now, nonce: "n1")
        #expect(e.iv.count == 16 && e.token == ChannelKeys(secret: secret).token && e.mac.count == 32)
        let line = String(decoding: try e.encodedLine(), as: UTF8.self)
        // Nothing of the installation, the settings or the report on the wire.
        for leak in ["rec|dev", "rec", "checkIn", "settings", "autoRefresh", "crashed", "2.0", "offline", "installationID"] {
            #expect(!line.contains(leak), "\(leak) on the wire")
        }
        #expect(line.hasPrefix(#"{"body":"#) && line.contains(#""v":2"#) && line.hasSuffix("\n"))
        let decoded = try ChannelEnvelopeV2.decode(line: Data(line.utf8).dropLast())
        #expect(open(decoded, seen: &seen) == req)
    }

    @Test func eachSealHasItsOwnRandomIV() throws {
        let a = try ChannelEnvelopeV2.seal(.refresh, secret: secret, now: now, nonce: "a")
        let b = try ChannelEnvelopeV2.seal(.refresh, secret: secret, now: now, nonce: "a")
        #expect(a.iv != b.iv && a.body != b.body)
    }

    @Test func wrongSecretTokenOrTimeIsRejected() throws {
        var seen = NonceCache()
        #expect(open(try seal(), secret: Data(repeating: 8, count: 32), seen: &seen) == nil)
        #expect(open(try seal(at: now.addingTimeInterval(-121), nonce: "s"), seen: &seen) == nil)
        #expect(open(try seal(at: now.addingTimeInterval(121), nonce: "f"), seen: &seen) == nil)
        #expect(open(try seal(at: now.addingTimeInterval(-120), nonce: "e1"), seen: &seen) == .refresh)
        #expect(open(try seal(at: now.addingTimeInterval(120), nonce: "e2"), seen: &seen) == .refresh)
        // Sealed by another installation (its own token and keys) but presented with ours.
        var other = try seal(secret: Data(repeating: 8, count: 32), nonce: "o")
        other.token = ChannelKeys(secret: secret).token
        #expect(open(other, seen: &seen) == nil)
    }

    @Test func replayedNonceIsRejectedAndRejectionsDontBurnIt() throws {
        var seen = NonceCache()
        var bad = try seal(nonce: "r")
        bad.mac[0] ^= 1
        #expect(open(bad, seen: &seen) == nil)
        #expect(seen.count == 0)
        let good = try seal(nonce: "r")
        #expect(open(good, seen: &seen) == .refresh)
        #expect(open(good, seen: &seen) == nil)
        // The same nonce under a fresh IV is still a replay.
        #expect(open(try seal(nonce: "r", iv: Data(repeating: 1, count: 16)), seen: &seen) == nil)
    }

    @Test func tamperingWithAnyFieldIsRejected() throws {
        var seen = NonceCache()
        let e = try seal(.setAutoRefresh(true), nonce: "t")
        var flipped = e; flipped.body[0] ^= 0x01 // CTR: would flip one plaintext bit, if decrypted
        var ivFlip = e; ivFlip.iv[15] ^= 0x01
        var tokenFlip = e; tokenFlip.token[0] ^= 0x01
        var timeFlip = e; timeFlip.timestamp += 1
        var nonceFlip = e; nonceFlip.nonce = "u"
        var macFlip = e; macFlip.mac[31] ^= 0x80
        var shorter = e; shorter.body = e.body.dropLast()
        var longer = e; longer.body = e.body + Data([0])
        for t in [flipped, ivFlip, tokenFlip, timeFlip, nonceFlip, macFlip, shorter, longer] {
            #expect(open(t, seen: &seen) == nil)
        }
        #expect(seen.count == 0)
        #expect(open(e, seen: &seen) == .setAutoRefresh(true))
    }

    /// A valid MAC over a ciphertext that isn't a request: refused, nonce not burned.
    @Test func authenticGarbageIsRejected() throws {
        var seen = NonceCache()
        let keys = ChannelKeys(secret: secret)
        for plain in [Data("not json".utf8), Data(#"{"type":"format"}"#.utf8), Data()] {
            let ct = try ChannelCrypto.aesCTR(key: keys.encryption, iv: iv, plain)
            let ts = channelMillis(now)!
            let mac = ChannelEnvelopeV2.computeMAC(keys: keys, timestamp: ts, nonce: "g", iv: iv, body: ct)
            let e = ChannelEnvelopeV2(token: keys.token, timestamp: ts, nonce: "g", iv: iv, body: ct, mac: mac)
            #expect(open(e, seen: &seen) == nil)
        }
        #expect(seen.count == 0)
    }

    @Test func aesCTRMatchesItsDefinition() throws {
        // NIST SP 800-38A F.5.5 (CTR-AES256.Encrypt), first block.
        func hex(_ s: String) -> Data { Data(stride(from: 0, to: s.count, by: 2).map {
            UInt8(s[s.index(s.startIndex, offsetBy: $0)..<s.index(s.startIndex, offsetBy: $0 + 2)], radix: 16)! }) }
        let key = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        let ctr = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let plain = hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")
        let cipher = hex("601ec313775789a5b7a7f504bbf3d228f443e3ca4d62b59aca84e990cacaf5c5")
        #expect(try ChannelCrypto.aesCTR(key: key, iv: ctr, plain) == cipher)
        #expect(try ChannelCrypto.aesCTR(key: key, iv: ctr, cipher) == plain)
        #expect(throws: (any Error).self) { try ChannelCrypto.aesCTR(key: key, iv: ctr.dropLast(), plain) }
        #expect(throws: (any Error).self) { try ChannelCrypto.aesCTR(key: key.dropLast(), iv: ctr, plain) }
    }

    // MARK: hostile lines (through the handler, as XSide reads them)

    func lookup(_ ref: ChannelKeyRef) -> (installationID: String, secret: Data)? {
        switch ref {
        case .installationID(let i): i == id ? (id, secret) : nil
        case .token(let t): t == ChannelKeys(secret: secret).token ? (id, secret) : nil
        }
    }

    func receive(_ line: Data, nonces: inout ChannelNonces) -> ChannelReceived {
        ChannelHandler.receive(line: line, now: now, nonces: &nonces, installation: lookup)
    }

    @Test func handlerOpensV2AndSaysSo() throws {
        var nonces = ChannelNonces()
        let line = try seal(.refresh, nonce: "h").encodedLine().dropLast()
        #expect(receive(Data(line), nonces: &nonces) == .request(installationID: id, nonce: "h", .refresh, version: .v2))
        #expect(ChannelHandler.head(of: Data(line)) == ChannelLineHead(ref: .token(ChannelKeys(secret: secret).token),
                                                                    version: .v2, timestamp: 1_800_000_000_000))
        // And v1, still accepted from the dylibs already installed, says v1.
        let v1 = try ChannelEnvelope.seal(.refresh, installationID: id, secret: secret, now: now, nonce: "h1").encodedLine().dropLast()
        #expect(receive(Data(v1), nonces: &nonces) == .request(installationID: id, nonce: "h1", .refresh, version: .v1))
        #expect(ChannelHandler.head(of: Data(v1)) == ChannelLineHead(ref: .installationID(id), version: .v1, timestamp: 1_800_000_000_000))
    }

    @Test func malformedV2LinesAreRefused() throws {
        var nonces = ChannelNonces()
        let good = try object(seal(nonce: "m"))
        func with(_ key: String, _ value: Any?) throws -> Data {
            var o = good; o[key] = value; return try lineData(o)
        }
        let full = try lineData(good)
        // Truncated anywhere: not JSON, not an envelope.
        for cut in [1, 10, full.count / 2, full.count - 1] {
            #expect(receive(full.prefix(cut), nonces: &nonces) == .malformed)
        }
        let b64 = { (d: Data) in d.base64EncodedString() }
        let cases: [Data] = [
            try with("iv", b64(Data(repeating: 1, count: 15))),    // IV too short
            try with("iv", b64(Data(repeating: 1, count: 17))),    // too long
            try with("iv", ""),
            try with("iv", nil),
            try with("token", b64(Data(repeating: 1, count: 15))),
            try with("token", b64(ChannelKeys(secret: secret).token + Data([0]))),
            try with("mac", b64(Data(repeating: 1, count: 31))),
            try with("body", ""),                                   // empty ciphertext
            try with("body", b64(Data(repeating: 1, count: ChannelHandler.maxLineLength + 1))),
            try with("nonce", "bad nonce"),
            try with("nonce", String(repeating: "a", count: 65)),
            try with("timestamp", -1),
            try with("v", 3),
            try with("v", "2"),
            try with("v", 1),
            try with("v", true),
            try with("installationID", id),                         // a v1 field in a v2 line
            try with("iv", "not base64!"),
        ]
        for (i, c) in cases.enumerated() {
            let r = receive(c, nonces: &nonces)
            #expect(r == .malformed || r == .rejected, "case \(i)")
        }
        #expect(nonces.count(for: id) == 0)
        // The good one still opens: nothing above burned its nonce.
        #expect(receive(full, nonces: &nonces) == .request(installationID: id, nonce: "m", .refresh, version: .v2))
    }

    @Test func unknownTokenIsRejectedWithoutACache() throws {
        var nonces = ChannelNonces()
        let stranger = try seal(secret: Data(repeating: 9, count: 32), nonce: "x").encodedLine().dropLast()
        #expect(receive(Data(stranger), nonces: &nonces) == .rejected)
        #expect(nonces.count(for: id) == 0)
    }

    /// v1/v2 confusion: a line is opened only as the version it says, never the other.
    @Test func versionsAreNeverMixed() throws {
        var nonces = ChannelNonces()
        let keys = ChannelKeys(secret: secret)
        // A v2 line without its "v": not a v1 envelope (no installation id), refused.
        var noV = try object(seal(nonce: "c1")); noV["v"] = nil
        #expect(receive(try lineData(noV), nonces: &nonces) == .malformed)
        // A v1 line with "v":2 added: not a v2 envelope.
        let v1 = try ChannelEnvelope.seal(.refresh, installationID: id, secret: secret, now: now, nonce: "c2")
        var v1Obj = try JSONSerialization.jsonObject(with: try v1.encodedLine().dropLast()) as! [String: Any]
        v1Obj["v"] = 2
        #expect(receive(try lineData(v1Obj), nonces: &nonces) == .malformed)
        // A v2 line whose MAC is made with the raw secret (the v1 key) or the v1 signing string.
        let e = try seal(nonce: "c3")
        var rawKey = e
        rawKey.mac = Data(HMAC<SHA256>.authenticationCode(for: ChannelEnvelopeV2.signedString(token: e.token, timestamp: e.timestamp,
                                                                                               nonce: e.nonce, iv: e.iv, body: e.body),
                                                          using: SymmetricKey(data: secret)))
        var v1String = e
        v1String.mac = Data(HMAC<SHA256>.authenticationCode(
            for: ChannelEnvelope.signedString(installationID: id, timestamp: e.timestamp, nonce: e.nonce, body: e.body),
            using: SymmetricKey(data: keys.authentication)))
        // A reply MAC (other domain) on a request.
        var replyMAC = e
        replyMAC.mac = ChannelReplyEnvelopeV2.computeMAC(keys: keys, nonce: e.nonce, iv: e.iv, body: e.body)
        for bad in [rawKey, v1String, replyMAC] {
            #expect(receive(try bad.encodedLine().dropLast(), nonces: &nonces) == .rejected)
        }
        // The plain-text body of a v2 request, sealed as v1: opens as v1, and says so.
        #expect(receive(try v1.encodedLine().dropLast(), nonces: &nonces) == .request(installationID: id, nonce: "c2", .refresh, version: .v1))
        #expect(nonces.count(for: id) == 1)
    }

    // MARK: replies and watch lines

    @Test func replyIsSealedInTheRequestsVersion() throws {
        let v2 = try ChannelHandler.replyLine(.refreshed, installationID: id, requestNonce: "n1", secret: secret, version: .v2)
        let text = String(decoding: v2, as: UTF8.self)
        #expect(text.contains(#""v":2"#) && !text.contains("rec|dev") && !text.contains("refreshed") && text.hasSuffix("\n"))
        let env = try ChannelReplyEnvelopeV2.decode(line: v2.dropLast())
        #expect(env.open(secret: secret, expectedNonce: "n1") == .refreshed)
        // Not a v1 reply: the v1 opener doesn't take it, and a v1 reply isn't a v2 one.
        #expect((try? ChannelReplyEnvelope.decode(line: v2.dropLast()))?
            .open(secret: secret, expectedInstallationID: id, expectedNonce: "n1") == nil)
        let v1 = try ChannelHandler.replyLine(.refreshed, installationID: id, requestNonce: "n1", secret: secret, version: .v1)
        #expect(String(decoding: v1, as: UTF8.self).contains("installationID"))
        #expect((try? ChannelReplyEnvelopeV2.decode(line: v1.dropLast()))?.open(secret: secret, expectedNonce: "n1") == nil)
    }

    @Test func replyChecksSecretNonceAndEveryField() throws {
        let e = try ChannelReplyEnvelopeV2.seal(.busy, requestNonce: "n1", secret: secret, iv: iv)
        #expect(e.open(secret: secret, expectedNonce: "n1") == .busy)
        #expect(e.open(secret: secret, expectedNonce: "n2") == nil)
        #expect(e.open(secret: Data(repeating: 8, count: 32), expectedNonce: "n1") == nil)
        var t = e; t.token[0] ^= 1
        var b = e; b.body[0] ^= 1
        var i = e; i.iv[0] ^= 1
        var short = e; short.iv = e.iv.dropLast()
        var m = e; m.mac[0] ^= 1
        for bad in [t, b, i, short, m] { #expect(bad.open(secret: secret, expectedNonce: "n1") == nil) }
        // A request MAC (other domain) on a reply.
        var asRequest = e
        asRequest.mac = ChannelEnvelopeV2.computeMAC(keys: ChannelKeys(secret: secret), timestamp: 0, nonce: "n1", iv: e.iv, body: e.body)
        #expect(asRequest.open(secret: secret, expectedNonce: "n1") == nil)
    }

    @Test func v2WatchWritesV2LinesTheReaderChecks() throws {
        final class Sink { var lines: [Data] = [] }
        let sink = Sink()
        let settings = InAppSettings.defaults(reminder: true, at: now)
        let hub = ChannelWatches<Int>()
        try hub.open(1, installationID: id, nonce: "w1", secret: secret, version: .v2,
                     first: ChannelWatchState(settings: settings, lastRefresh: nil), now: now) { sink.lines.append($0) }
        hub.update(id, to: ChannelWatchState(settings: settings.setting(\.reminder, to: false, at: now, by: .mac), lastRefresh: nil), now: now)
        hub.keepAlive(now: now.addingTimeInterval(30))
        #expect(sink.lines.count == 3)
        for l in sink.lines { #expect(String(decoding: l, as: UTF8.self).contains(#""v":2"#)) }
        let first = try ChannelReplyEnvelopeV2.decode(line: sink.lines[0].dropLast())
        #expect(first.open(secret: secret, expectedNonce: "w1") == .settings(settings))
        var reader = ChannelWatchReader(installationID: id, nonce: "w1", secret: secret, version: .v2)
        guard case .live(1, _, _, _)? = reader.open(line: sink.lines[1].dropLast()) else { Issue.record("live refused"); return }
        #expect(reader.open(line: sink.lines[1].dropLast()) == nil) // replayed
        #expect(reader.open(line: sink.lines[2].dropLast()) == .alive(seq: 2))
        // A v1 reader (or a v1 line on a v2 watch) takes none of it.
        var v1Reader = ChannelWatchReader(installationID: id, nonce: "w1", secret: secret, version: .v1)
        #expect(v1Reader.open(line: sink.lines[1].dropLast()) == nil)
        let v1Live = try ChannelHandler.replyLine(.alive(seq: 3), installationID: id, requestNonce: "w1", secret: secret, version: .v1)
        #expect(reader.open(line: v1Live.dropLast()) == nil)
    }

    /// A v2 watch's goodbye is a v2 `bye`; a v1 one (even well signed) doesn't count (no fallback).
    @Test func aV2WatchTakesOnlyAV2Bye() throws {
        func abrupt(_ farewell: Data, version: ChannelVersion, nonces: inout ChannelNonces) -> Bool {
            ChannelHandler.watchEndedAbruptly(.byPhone(farewell: farewell), saysBye: true, installationID: id, now: now,
                                              nonces: &nonces, secret: secret, version: version)
        }
        var n = ChannelNonces()
        let v2Bye = Data(try seal(.bye, nonce: "b2").encodedLine().dropLast())
        let v1Bye = Data(try ChannelEnvelope.seal(.bye, installationID: id, secret: secret, now: now, nonce: "b1").encodedLine().dropLast())
        #expect(abrupt(v1Bye, version: .v2, nonces: &n))
        #expect(abrupt(v2Bye, version: .v1, nonces: &n))
        var fresh = ChannelNonces()
        #expect(!abrupt(v2Bye, version: .v2, nonces: &fresh))
        #expect(!abrupt(v1Bye, version: .v1, nonces: &fresh))
        #expect(abrupt(v2Bye, version: .v2, nonces: &fresh)) // replayed
        // Another installation's v2 bye.
        let strangers = Data(try seal(.bye, secret: Data(repeating: 9, count: 32), nonce: "b3").encodedLine().dropLast())
        #expect(abrupt(strangers, version: .v2, nonces: &fresh))
    }

    // MARK: the Mac's lookup

    /// The 16-byte token can be derived on its own with a single HKDF (no enc/mac keys), for the
    /// installation lookup (review 2, K2-1); it equals the token of the full key schedule.
    @Test func tokenCanBeDerivedOnItsOwn() {
        #expect(ChannelKeys.token(secret: secret) == ChannelKeys(secret: secret).token)
        let other = Data(repeating: 9, count: 32)
        #expect(ChannelKeys.token(secret: other) == ChannelKeys(secret: other).token)
        #expect(ChannelKeys.token(secret: other) != ChannelKeys.token(secret: secret))
    }

    @Test func libraryFindsTheInstallationByToken() async throws {
        let tmp = TestTemp.root.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = AppLibrary(root: tmp)
        let src = tmp.appendingPathComponent("src.ipa")
        try Data("ipa".utf8).write(to: src)
        let rec = try await lib.importIPA(src, info: AppInfo(bundleID: "com.example.a", name: "A", version: "1", executable: "A"),
                                          teamID: "TEAM123456")
        let a = Data(repeating: 1, count: 32), b = Data(repeating: 2, count: 32)
        try await lib.upsert(Installation(deviceID: "a", installedAt: now, expiresAt: now, channelSecret: a), for: rec.id)
        try await lib.upsert(Installation(deviceID: "b", installedAt: now, expiresAt: now, channelSecret: b), for: rec.id)
        try await lib.upsert(Installation(deviceID: "c", installedAt: now, expiresAt: now), for: rec.id) // no secret yet
        let found = await lib.installation(channelRef: .token(ChannelKeys(secret: b).token))
        #expect(found?.recordID == rec.id && found?.installation.deviceID == "b")
        #expect(await lib.installation(channelRef: .token(Data(repeating: 0, count: 16))) == nil)
        let byID = await lib.installation(channelRef: .installationID(ChannelEnvelope.installationID(recordID: rec.id, deviceID: "a")))
        #expect(byID?.installation.deviceID == "a")
    }
}
