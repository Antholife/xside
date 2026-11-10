import Testing
import Foundation
import CryptoKit
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

    /// Device feedback 5, G3: a check-in may state the phone's poll interval; older dylibs leave
    /// it out and still decode. It's only read for the status line, and only on a check-in.
    @Test func checkInPollIntervalIsOptional() throws {
        let settings = InAppSettings.defaults(reminder: true, at: now)
        let polled = ChannelRequest.checkIn(settings: settings, lastRefresh: nil, appVersion: "2", pollEvery: 45)
        let body = try JSONEncoder().encode(polled)
        #expect(String(decoding: body, as: UTF8.self).contains(#""pollEvery":45"#))
        #expect(try JSONDecoder().decode(ChannelRequest.self, from: body) == polled)
        #expect(polled.pollEvery == 45)
        let old = ChannelRequest.checkIn(settings: settings, lastRefresh: nil, appVersion: "2")
        let oldBody = try JSONEncoder().encode(old)
        #expect(!String(decoding: oldBody, as: UTF8.self).contains("pollEvery"))
        #expect(try JSONDecoder().decode(ChannelRequest.self, from: oldBody).pollEvery == nil)
        #expect(ChannelRequest.watch(settings: settings, lastRefresh: nil, appVersion: "2").pollEvery == nil)
        #expect(ChannelRequest.refresh.pollEvery == nil)
    }

    /// Mega review C3: a pause end past year 3000 (stored state, any source) is carried as year
    /// 3000 instead of making every reply to that installation fail to seal.
    @Test func aPauseEndPastTheLastDateIsClamped() throws {
        let far = Date(timeIntervalSince1970: 1e14)
        let settings = InAppSettings.defaults(reminder: true, at: Date(timeIntervalSince1970: 1_800_000_000))
        let max = Date(timeIntervalSince1970: TimeInterval(channelMaxMillis) / 1000)
        for reply in [ChannelReply.settings(settings, pausedUntil: far), .live(seq: 1, settings, pausedUntil: far)] {
            let decoded = try ChannelReply.decode(body: try reply.encodedBody())
            switch decoded {
            case let .settings(_, _, until), let .live(_, _, _, until): #expect(until == max)
            default: Issue.record("wrong reply \(decoded)")
            }
        }
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

    @Test func nonceIsKeptForTheWholeWindow() {
        var d = NonceCache()
        let first = d.insert("x", installationID: "i", at: now)
        // Still remembered 240 s later (a future-dated request stays acceptable that long).
        let again = d.insert("x", installationID: "i", at: now.addingTimeInterval(240))
        // Forgotten once it can no longer pass the window check.
        let late = d.insert("x", installationID: "i", at: now.addingTimeInterval(400))
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

    // MARK: fixtures (shared with the Objective-C dylib harness)

    static let fixtureSecretHex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
    static let fixtureSecret = Data((1...32).map { UInt8($0) })
    static let fixtureID = "rec|dev"
    static let fixtureNow = Date(timeIntervalSince1970: 1_800_000_000)
    static let fixtureSettings: InAppSettings = {
        func f<V>(_ v: V, _ ms: Double, _ by: ChangeOrigin) -> Field<V> {
            Field(value: v, changedAt: Date(timeIntervalSince1970: ms / 1000), changedBy: by)
        }
        return InAppSettings(showValidity: f(true, 1_799_999_000_456, .mac),
                             alertLate: f(false, 1_799_999_001_000, .device), refreshCard: f(true, 1_799_999_002_000, .mac),
                             reminder: f(false, 1_799_999_003_000, .mac), language: f(.fr, 1_799_999_004_000, .device),
                             autoRefresh: f(true, 1_799_999_005_007, .mac))
    }()
    /// The outcome the Mac sends back with the check-in's settings (a failure the phone missed).
    static let fixtureOutcome = RefreshOutcome(at: Date(timeIntervalSince1970: 1_799_995_000.25), succeeded: false,
                                               reasonKey: "deviceLocked")
    static let fixtureCheckIn = ChannelRequest.checkIn(
        settings: fixtureSettings,
        lastRefresh: RefreshOutcome(at: Date(timeIntervalSince1970: 1_799_990_000.5), succeeded: false, reasonKey: "refresh.reason.offline"),
        appVersion: "2.3.1", pollEvery: 45) // device feedback 5, G3: a Low Power Mode poll

    struct FixtureEntry: Codable, Equatable {
        var installationID: String
        var timestamp: Int64?
        var nonce: String
        var bodyJSON: String
        var body: String
        var signedString: String
        var mac: String
        var line: String
    }
    struct FixtureFile: Codable, Equatable {
        var secretHex: String
        var refreshRequest: FixtureEntry
        var checkInRequest: FixtureEntry
        var settingsReply: FixtureEntry
        /// Device feedback 4: a watch request and two lines the Mac writes on it (same nonce).
        var watchRequest: FixtureEntry
        var liveLine: FixtureEntry
        var aliveLine: FixtureEntry
        /// Review D–G minor 7: a reply carrying the end of a Mac pause of a while.
        var pausedReply: FixtureEntry
        /// A check-in saying the previous run stopped while in use (the module's run marker).
        var crashedRunCheckIn: FixtureEntry
        /// A watch that says goodbye, reporting a clean previous run, and its `bye`.
        var byeWatchRequest: FixtureEntry
        var byeRequest: FixtureEntry
    }
    static let fixtureCrashedRun = ChannelRequest.checkIn(
        settings: fixtureSettings, lastRefresh: nil, appVersion: "2.3.1", pollEvery: 15,
        previousRun: PreviousRun(ended: .crashed, since: Date(timeIntervalSince1970: 1_799_999_900.125)))
    static let fixtureByeWatch = ChannelRequest.watch(
        settings: fixtureSettings, lastRefresh: nil, appVersion: "2.3.1", saysBye: true,
        previousRun: PreviousRun(ended: .clean, since: Date(timeIntervalSince1970: 1_799_999_000)))
    static let fixtureWatch = ChannelRequest.watch(settings: fixtureSettings, lastRefresh: nil, appVersion: "2.3.1")
    /// What the Mac pushes: the fixture settings with the reminder turned back on from the Mac.
    static let fixtureLive = ChannelReply.live(
        seq: 1, fixtureSettings.setting(\.reminder, to: true, at: Date(timeIntervalSince1970: 1_800_000_010), by: .mac),
        lastRefresh: fixtureOutcome)

    /// Paused from the Mac for 2 hours: automatic refresh off, and when it comes back.
    static let fixturePaused = ChannelReply.settings(
        fixtureSettings.setting(\.autoRefresh, to: false, at: Date(timeIntervalSince1970: 1_800_000_020), by: .mac),
        pausedUntil: Date(timeIntervalSince1970: 1_800_007_220))

    static func requestEntry(_ r: ChannelRequest, nonce: String) throws -> FixtureEntry {
        let ts: Int64 = 1_800_000_000_000
        let e = try ChannelEnvelope.seal(r, installationID: fixtureID, secret: fixtureSecret, timestampMillis: ts, nonce: nonce)
        return FixtureEntry(installationID: fixtureID, timestamp: ts, nonce: nonce,
                            bodyJSON: String(decoding: e.body, as: UTF8.self), body: e.body.base64EncodedString(),
                            signedString: String(decoding: ChannelEnvelope.signedString(installationID: fixtureID, timestamp: ts, nonce: nonce, body: e.body), as: UTF8.self),
                            mac: e.mac.base64EncodedString(),
                            line: String(decoding: try e.encodedLine().dropLast(), as: UTF8.self))
    }
    static func replyEntry(_ r: ChannelReply, nonce: String) throws -> FixtureEntry {
        let e = try ChannelReplyEnvelope.seal(r, installationID: fixtureID, requestNonce: nonce, secret: fixtureSecret)
        return FixtureEntry(installationID: fixtureID, timestamp: nil, nonce: nonce,
                            bodyJSON: String(decoding: e.body, as: UTF8.self), body: e.body.base64EncodedString(),
                            signedString: String(decoding: ReplySigned.string(e), as: UTF8.self),
                            mac: e.mac.base64EncodedString(),
                            line: String(decoding: try e.encodedLine().dropLast(), as: UTF8.self))
    }
    enum ReplySigned {
        static func string(_ e: ChannelReplyEnvelope) -> Data {
            ChannelReplyEnvelope.signedString(installationID: e.installationID, nonce: e.nonce, body: e.body)
        }
    }
    static func currentFixture() throws -> FixtureFile {
        FixtureFile(secretHex: fixtureSecretHex,
                    refreshRequest: try requestEntry(.refresh, nonce: "n1"),
                    checkInRequest: try requestEntry(fixtureCheckIn, nonce: "n2-checkin"),
                    settingsReply: try replyEntry(.settings(fixtureSettings, lastRefresh: fixtureOutcome), nonce: "n2-checkin"),
                    watchRequest: try requestEntry(fixtureWatch, nonce: "n3-watch"),
                    liveLine: try replyEntry(fixtureLive, nonce: "n3-watch"),
                    aliveLine: try replyEntry(.alive(seq: 2), nonce: "n3-watch"),
                    pausedReply: try replyEntry(fixturePaused, nonce: "n2-checkin"),
                    crashedRunCheckIn: try requestEntry(fixtureCrashedRun, nonce: "n4-run"),
                    byeWatchRequest: try requestEntry(fixtureByeWatch, nonce: "n5-watch"),
                    byeRequest: try requestEntry(.bye, nonce: "n6-bye"))
    }
    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/channel-fixture.json")
    }

    @Test func knownFixtureMatchesTheDylibFormat() throws {
        // Hand-checked literals for the simplest case (also verified with openssl).
        let r = try Self.requestEntry(.refresh, nonce: "n1")
        #expect(r.bodyJSON == #"{"type":"refresh"}"#)
        #expect(r.signedString == "rec|dev|1800000000000|n1|eyJ0eXBlIjoicmVmcmVzaCJ9")
        #expect(r.mac == "4McQUiU/zGGdkAvFuzmmVje88inM1VhBlOgAMVt8ypM=")
        var seen = NonceCache()
        let wire = try ChannelEnvelope.decode(line: Data(r.line.utf8))
        #expect(wire.open(secret: Self.fixtureSecret, now: Self.fixtureNow, seen: &seen) == .refresh)
    }

    @Test func fixtureFileMatchesTheCode() throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        let onDisk = try JSONDecoder().decode(FixtureFile.self, from: data)
        // The key the MACs are computed with is exactly the one the file documents.
        #expect(onDisk.secretHex == Self.fixtureSecret.map { String(format: "%02x", $0) }.joined())
        #expect(onDisk == (try Self.currentFixture()))
        // The file's own lines must open / parse the way the dylib will see them.
        var seen = NonceCache()
        let secret = Self.fixtureSecret
        let c = try ChannelEnvelope.decode(line: Data(onDisk.checkInRequest.line.utf8))
        #expect(c.open(secret: secret, now: Self.fixtureNow, seen: &seen) == Self.fixtureCheckIn)
        let rep = try ChannelReplyEnvelope.decode(line: Data(onDisk.settingsReply.line.utf8))
        #expect(rep.open(secret: secret, expectedInstallationID: Self.fixtureID, expectedNonce: "n2-checkin") == .settings(Self.fixtureSettings, lastRefresh: Self.fixtureOutcome))
        let w = try ChannelEnvelope.decode(line: Data(onDisk.watchRequest.line.utf8))
        #expect(w.open(secret: secret, now: Self.fixtureNow, seen: &seen) == Self.fixtureWatch)
        var reader = ChannelWatchReader(installationID: Self.fixtureID, nonce: "n3-watch", secret: secret)
        #expect(reader.open(line: Data(onDisk.liveLine.line.utf8)) == Self.fixtureLive)
        #expect(reader.open(line: Data(onDisk.aliveLine.line.utf8)) == .alive(seq: 2))
        let paused = try ChannelReplyEnvelope.decode(line: Data(onDisk.pausedReply.line.utf8))
        #expect(paused.open(secret: secret, expectedInstallationID: Self.fixtureID, expectedNonce: "n2-checkin") == Self.fixturePaused)
        let run = try ChannelEnvelope.decode(line: Data(onDisk.crashedRunCheckIn.line.utf8))
        #expect(run.open(secret: secret, now: Self.fixtureNow, seen: &seen) == Self.fixtureCrashedRun)
        let bw = try ChannelEnvelope.decode(line: Data(onDisk.byeWatchRequest.line.utf8))
        #expect(bw.open(secret: secret, now: Self.fixtureNow, seen: &seen) == Self.fixtureByeWatch)
        let bye = try ChannelEnvelope.decode(line: Data(onDisk.byeRequest.line.utf8))
        #expect(bye.open(secret: secret, now: Self.fixtureNow, seen: &seen) == .bye)
    }

    /// The module's run marker: how the previous run ended, two optional fields of a check-in or a
    /// watch, inside the signed body. Older dylibs leave them out; one alone or an unknown ending is
    /// ignored; a malformed date fails like any field.
    @Test func previousRunIsOptionalAndTolerant() throws {
        let settings = InAppSettings.defaults(reminder: true, at: now)
        let since = now.addingTimeInterval(-300)
        let crashed = ChannelRequest.checkIn(settings: settings, lastRefresh: nil, appVersion: "2",
                                             previousRun: PreviousRun(ended: .crashed, since: since))
        let body = try JSONEncoder.channel.encode(crashed)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains(#""previousRunEnded":"crashed""#) && text.contains(#""previousRunSince":1799999700000"#))
        #expect(try JSONDecoder.channel.decode(ChannelRequest.self, from: body) == crashed)
        #expect(crashed.previousRun == PreviousRun(ended: .crashed, since: since))
        let old = ChannelRequest.checkIn(settings: settings, lastRefresh: nil, appVersion: "2")
        #expect(!String(decoding: try JSONEncoder.channel.encode(old), as: UTF8.self).contains("previousRun"))
        #expect(old.previousRun == nil && ChannelRequest.refresh.previousRun == nil && ChannelRequest.bye.previousRun == nil)

        func decoded(_ extra: String) throws -> ChannelRequest {
            let settingsJSON = String(decoding: try JSONEncoder.channel.encode(settings), as: UTF8.self)
            return try JSONDecoder.channel.decode(ChannelRequest.self, from: Data(#"{"type":"checkIn","settings":\#(settingsJSON)\#(extra)}"#.utf8))
        }
        #expect(try decoded(#","previousRunEnded":"crashed""#).previousRun == nil) // no date
        #expect(try decoded(#","previousRunSince":1799999700000"#).previousRun == nil) // no ending
        #expect(try decoded(#","previousRunEnded":"exploded","previousRunSince":1799999700000"#).previousRun == nil)
        #expect(try decoded(#","previousRunEnded":"clean","previousRunSince":1799999700000"#).previousRun
                == PreviousRun(ended: .clean, since: since))
        #expect(throws: (any Error).self) { try decoded(#","previousRunEnded":"crashed","previousRunSince":"soon""#) }
        #expect(throws: (any Error).self) { try decoded(#","previousRunEnded":"crashed","previousRunSince":-5"#) }
        #expect(throws: (any Error).self) { try decoded(#","previousRunEnded":7,"previousRunSince":1799999700000"#) }

        // A watch: the same fields, and whether it says goodbye (false when left out).
        let watch = ChannelRequest.watch(settings: settings, lastRefresh: nil, appVersion: "2", saysBye: true,
                                         previousRun: PreviousRun(ended: .clean, since: since))
        let wb = try JSONEncoder.channel.encode(watch)
        #expect(String(decoding: wb, as: UTF8.self).contains(#""saysBye":true"#))
        #expect(try JSONDecoder.channel.decode(ChannelRequest.self, from: wb) == watch)
        #expect(watch.saysBye && watch.previousRun?.ended == .clean)
        let oldWatch = ChannelRequest.watch(settings: settings, lastRefresh: nil, appVersion: "2")
        #expect(!String(decoding: try JSONEncoder.channel.encode(oldWatch), as: UTF8.self).contains("saysBye"))
        #expect(!oldWatch.saysBye && !crashed.saysBye)
        #expect(String(decoding: try JSONEncoder.channel.encode(ChannelRequest.bye), as: UTF8.self) == #"{"type":"bye"}"#)
    }

    /// Changing a field of the run report breaks the MAC: it is part of the signed body.
    @Test func previousRunIsSigned() throws {
        var seen = NonceCache()
        let settings = InAppSettings.defaults(reminder: true, at: now)
        let clean = ChannelRequest.checkIn(settings: settings, lastRefresh: nil, appVersion: "2",
                                           previousRun: PreviousRun(ended: .clean, since: now))
        var env = try seal(clean)
        env.body = try ChannelEnvelope.encodeBody(.checkIn(settings: settings, lastRefresh: nil, appVersion: "2",
                                                           previousRun: PreviousRun(ended: .crashed, since: now)))
        #expect(env.open(secret: secret, now: now, seen: &seen) == nil)
    }

    @Test func regenerateFixtureOnDemand() throws {
        guard ProcessInfo.processInfo.environment["XSIDE_WRITE_CHANNEL_FIXTURE"] != nil else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(try Self.currentFixture()).write(to: Self.fixtureURL)
    }

    // MARK: replies

    @Test func authenticatedReplyRoundTrips() throws {
        let env = try ChannelReplyEnvelope.seal(.accepted, installationID: "rec|dev", requestNonce: "n1", secret: secret)
        let back = try ChannelReplyEnvelope.decode(line: env.encodedLine())
        #expect(back.open(secret: secret, expectedInstallationID: "rec|dev", expectedNonce: "n1") == .accepted)
    }

    @Test func replyWithWrongSecretOrBindingIsRejected() throws {
        let env = try ChannelReplyEnvelope.seal(.settings(.defaults(reminder: true, at: now)), installationID: "rec|dev", requestNonce: "n1", secret: secret)
        #expect(env.open(secret: Data(repeating: 9, count: 32), expectedInstallationID: "rec|dev", expectedNonce: "n1") == nil)
        #expect(env.open(secret: secret, expectedInstallationID: "rec|dev", expectedNonce: "n2") == nil)
        #expect(env.open(secret: secret, expectedInstallationID: "rec|other", expectedNonce: "n1") == nil)
        var moved = env
        moved.nonce = "n2"
        #expect(moved.open(secret: secret, expectedInstallationID: "rec|dev", expectedNonce: "n2") == nil)
        var swapped = env
        swapped.body = try ChannelReply.rejected.encodedBody()
        #expect(swapped.open(secret: secret, expectedInstallationID: "rec|dev", expectedNonce: "n1") == nil)
    }

    @Test func replyMACWithoutTheDomainPrefixIsRejected() throws {
        let body = try ChannelReply.accepted.encodedBody()
        // Same key, same fields, but signed as `id|nonce|base64(body)`: only the "reply|" prefix differs.
        let unprefixed = Data("rec|dev|n1|\(body.base64EncodedString())".utf8)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: unprefixed, using: SymmetricKey(data: secret)))
        let forged = ChannelReplyEnvelope(installationID: "rec|dev", nonce: "n1", body: body, mac: mac)
        #expect(forged.open(secret: secret, expectedInstallationID: "rec|dev", expectedNonce: "n1") == nil)
        // Sanity: the same fields with the prefix are accepted.
        let good = try ChannelReplyEnvelope.seal(.accepted, installationID: "rec|dev", requestNonce: "n1", secret: secret)
        #expect(good.open(secret: secret, expectedInstallationID: "rec|dev", expectedNonce: "n1") == .accepted)
        // And a request MAC is not a reply MAC either.
        let req = try seal(.refresh)
        let forged2 = ChannelReplyEnvelope(installationID: "rec|dev", nonce: "n1", body: body, mac: req.mac)
        #expect(forged2.open(secret: secret, expectedInstallationID: "rec|dev", expectedNonce: "n1") == nil)
    }

    @Test func hugeOrNonFiniteDatesNeitherTrapNorRoundTrip() throws {
        for ms in ["9223372036854775807", "-9223372036854775808", "-1", "32503680000001"] {
            let json = Data(#"{"at":\#(ms),"succeeded":true}"#.utf8)
            #expect(throws: DecodingError.self) { try JSONDecoder.channel.decode(RefreshOutcome.self, from: json) }
        }
        let edge = Data(#"{"at":32503680000000,"succeeded":true}"#.utf8)
        #expect((try? JSONDecoder.channel.decode(RefreshOutcome.self, from: edge)) != nil)
        for d in [Date.distantFuture, Date.distantPast, Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: -.infinity),
                  Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: 1e300)] {
            #expect(throws: EncodingError.self) { try JSONEncoder.channel.encode(RefreshOutcome(at: d, succeeded: true)) }
        }
        #expect(throws: ChannelError.self) { try ChannelEnvelope.seal(.refresh, installationID: "i", secret: secret, now: .distantFuture, nonce: "n") }
        var seen = NonceCache()
        let env = try seal()
        #expect(env.open(secret: secret, now: Date(timeIntervalSince1970: .infinity), seen: &seen) == nil)
    }

    // MARK: hardening

    @Test func fullCacheFailsClosedInsteadOfEvicting() {
        var c = NonceCache(capacity: 2)
        let a = c.insert("a", installationID: "i", at: now)
        let b = c.insert("b", installationID: "i", at: now)
        let full = c.insert("c", installationID: "i", at: now)
        let replay = c.insert("a", installationID: "i", at: now)
        #expect(a && b && !full && !replay)
        // Room again once the live entries have expired.
        let later = c.insert("c", installationID: "i", at: now.addingTimeInterval(400))
        #expect(later)
    }

    @Test func nonceIsScopedPerInstallation() {
        var c = NonceCache()
        let a = c.insert("same", installationID: "i1", at: now)
        let b = c.insert("same", installationID: "i2", at: now)
        let again = c.insert("same", installationID: "i1", at: now)
        #expect(a && b && !again)
    }

    @Test func extremeTimestampsAreRejectedWithoutTrapping() throws {
        var seen = NonceCache()
        for ts in [Int64.min, Int64.max, Int64.min + 1, Int64.max - 1] {
            let env = try ChannelEnvelope.seal(.refresh, installationID: "rec|dev", secret: secret, timestampMillis: ts, nonce: "x\(ts)".filter { $0.isLetter || $0.isNumber })
            #expect(env.open(secret: secret, now: now, seen: &seen) == nil)
            #expect(env.open(secret: secret, now: Date(timeIntervalSince1970: 1e15), seen: &seen) == nil)
        }
    }

    @Test func invalidNoncesAreRejected() throws {
        for bad in ["", String(repeating: "a", count: 65), "a b", "a|b", "é", "a\nb"] {
            #expect(throws: ChannelError.self) { try seal(nonce: bad) }
            // A correctly MACed envelope with a bad nonce is still refused on open.
            let body = try ChannelEnvelope.encodeBody(.refresh)
            let mac = ChannelEnvelope.computeMAC(secret: secret, installationID: "rec|dev", timestamp: 1_800_000_000_000, nonce: bad, body: body)
            let env = ChannelEnvelope(installationID: "rec|dev", timestamp: 1_800_000_000_000, nonce: bad, body: body, mac: mac)
            var seen = NonceCache()
            #expect(env.open(secret: secret, now: now, seen: &seen) == nil)
        }
        #expect((try? seal(nonce: String(repeating: "A_-9", count: 16))) != nil)
    }

    @Test func datesTravelAsEpochMilliseconds() throws {
        let o = RefreshOutcome(at: Date(timeIntervalSince1970: 1_800_000_000.123), succeeded: true)
        let json = String(decoding: try JSONEncoder.channel.encode(o), as: UTF8.self)
        #expect(json == #"{"at":1800000000123,"succeeded":true}"#)
        #expect(try JSONDecoder.channel.decode(RefreshOutcome.self, from: Data(json.utf8)) == o)
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
        let all: [ChannelReply] = [.settings(s), .settings(s, lastRefresh: RefreshOutcome(at: now, succeeded: false, reasonKey: "k")),
                                   .accepted, .refreshed, .failed(reasonKey: "r"), .busy,
                                   .deviceUnreachable, .paused(by: .mac), .paused(by: .device), .rejected]
        for r in all {
            #expect(try ChannelReply.decode(body: r.encodedBody()) == r)
        }
        #expect(String(decoding: try ChannelReply.paused(by: .mac).encodedBody(), as: UTF8.self) == #"{"by":"mac","type":"paused"}"#)
        // The outcome is optional: absent from the JSON when nil, and older replies still decode.
        let plain = String(decoding: try ChannelReply.settings(s).encodedBody(), as: UTF8.self)
        #expect(!plain.contains("lastRefresh"))
        let withOutcome = String(decoding: try ChannelReply.settings(s, lastRefresh: RefreshOutcome(at: now, succeeded: true)).encodedBody(), as: UTF8.self)
        #expect(withOutcome.contains(#""lastRefresh":{"at":1800000000000,"succeeded":true}"#))
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
