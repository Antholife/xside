import Testing
import Foundation
@testable import XSideCore

@Suite struct ChannelHandlerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let secret = Data(repeating: 7, count: 32)
    let recordID = UUID(uuidString: "ABCDEF12-2222-3333-4444-555555555555")!
    var installationID: String { ChannelEnvelope.installationID(recordID: recordID, deviceID: "dev-1") }

    func installation(inApp: InAppSettings? = nil, paused: Bool = false, pausedBy: ChangeOrigin? = nil,
                      outcome: RefreshOutcome? = nil) -> Installation {
        Installation(deviceID: "dev-1", installedAt: now.addingTimeInterval(-86_400),
                     expiresAt: now.addingTimeInterval(6 * 86_400), refreshPaused: paused,
                     inApp: inApp ?? InAppSettings.defaults(reminder: true, at: now.addingTimeInterval(-3600)),
                     pausedBy: pausedBy, lastRefreshOutcome: outcome, channelSecret: secret)
    }

    // MARK: handle

    @Test func checkInMergesAndReturnsTheMergedSettings() {
        let mac = InAppSettings.defaults(reminder: true, at: now.addingTimeInterval(-3600))
            .setting(\.refreshCard, to: false, at: now.addingTimeInterval(-60), by: .mac)
        let phone = InAppSettings.defaults(reminder: true, at: now.addingTimeInterval(-3600))
            .setting(\.language, to: .fr, at: now.addingTimeInterval(-30), by: .device)
        let phoneOutcome = RefreshOutcome(at: now.addingTimeInterval(-10), succeeded: false, reasonKey: "error.x")
        let (reply, update) = ChannelHandler.handle(.checkIn(settings: phone, lastRefresh: phoneOutcome, appVersion: "2"),
                                                    installation: installation(inApp: mac), now: now, reminder: true)
        let merged = InAppSettings.merge(mac, phone)
        #expect(merged.refreshCard.value == false && merged.language.value == .fr)
        #expect(reply == .settings(merged, lastRefresh: phoneOutcome))
        #expect(update == .merged(merged, checkIn: now, outcome: phoneOutcome))
    }

    /// Review D–G minor 7: a pause of a while made on the Mac reaches the phone with its end, and
    /// only while the reply still has automatic refresh off.
    @Test func checkInSaysWhenAMacPauseEnds() {
        let end = now.addingTimeInterval(2 * 3600)
        let off = InAppSettings.defaults(reminder: true, at: now.addingTimeInterval(-3600))
            .setting(\.autoRefresh, to: false, at: now.addingTimeInterval(-60), by: .mac)
        var paused = installation(inApp: off, paused: true, pausedBy: .mac)
        paused.pausedUntil = end
        let phone = InAppSettings.defaults(reminder: true, at: now.addingTimeInterval(-3600))
        let (reply, _) = ChannelHandler.handle(.checkIn(settings: phone, lastRefresh: nil, appVersion: "2"),
                                               installation: paused, now: now, reminder: true)
        guard case let .settings(_, _, until) = reply else { Issue.record("no settings"); return }
        #expect(until == end)
        #expect(ChannelWatchState(paused)?.pausedUntil == end)
        // The phone turned it back on meanwhile (newer): no end to tell.
        let resumed = phone.setting(\.autoRefresh, to: true, at: now.addingTimeInterval(-10), by: .device)
        let (back, _) = ChannelHandler.handle(.checkIn(settings: resumed, lastRefresh: nil, appVersion: "2"),
                                              installation: paused, now: now, reminder: true)
        guard case let .settings(_, _, none) = back else { Issue.record("no settings"); return }
        #expect(none == nil)
        // Until resumed: none either.
        paused.pausedUntil = nil
        #expect(ChannelWatchState(paused)?.pausedUntil == nil)
        // On the wire: an epoch-milliseconds date, omitted when nil.
        let body = String(decoding: (try? ChannelReply.settings(off, pausedUntil: end).encodedBody()) ?? Data(), as: UTF8.self)
        #expect(body.contains("\"pausedUntil\":1800007200000"))
        #expect(!String(decoding: (try? ChannelReply.settings(off).encodedBody()) ?? Data(), as: UTF8.self).contains("pausedUntil"))
    }

    /// The phone learns how a refresh it asked for ended, even if it was suspended meanwhile:
    /// the check-in answer carries the newest outcome the Mac knows (its own or the phone's).
    @Test func checkInReplyCarriesTheNewestRefreshOutcome() {
        let s = InAppSettings.defaults(reminder: true, at: now.addingTimeInterval(-3600))
        let failed = RefreshOutcome(at: now.addingTimeInterval(-120), succeeded: false, reasonKey: "deviceLocked")
        func reply(_ phone: RefreshOutcome?) -> ChannelReply {
            ChannelHandler.handle(.checkIn(settings: s, lastRefresh: phone, appVersion: nil),
                                  installation: installation(inApp: s, outcome: failed), now: now, reminder: true).reply
        }
        #expect(reply(nil) == .settings(s, lastRefresh: failed))
        #expect(reply(RefreshOutcome(at: now.addingTimeInterval(-500), succeeded: true)) == .settings(s, lastRefresh: failed))
        let newer = RefreshOutcome(at: now.addingTimeInterval(-5), succeeded: true)
        #expect(reply(newer) == .settings(s, lastRefresh: newer))
        // Nothing known on either side: no outcome in the answer.
        let (none, _) = ChannelHandler.handle(.checkIn(settings: s, lastRefresh: nil, appVersion: nil),
                                              installation: installation(inApp: s), now: now, reminder: true)
        #expect(none == .settings(s))
    }

    /// A phone whose clock runs far ahead must not pin its values forever.
    @Test func checkInClampsFarFutureDates() {
        let mac = InAppSettings.defaults(reminder: true, at: now.addingTimeInterval(-3600))
        let phone = mac.setting(\.reminder, to: false, at: now.addingTimeInterval(86_400 * 365), by: .device)
            .setting(\.refreshCard, to: false, at: now.addingTimeInterval(100), by: .device) // within the window: kept
        let future = RefreshOutcome(at: now.addingTimeInterval(86_400), succeeded: true)
        let (reply, update) = ChannelHandler.handle(.checkIn(settings: phone, lastRefresh: future, appVersion: nil),
                                                    installation: installation(inApp: mac), now: now, reminder: true)
        guard case let .settings(merged, _, _) = reply else { Issue.record("no settings"); return }
        #expect(merged.reminder == Field(value: false, changedAt: now, changedBy: .device))
        #expect(merged.refreshCard.changedAt == now.addingTimeInterval(100))
        #expect(update == .merged(merged, checkIn: now, outcome: RefreshOutcome(at: now, succeeded: true)))
        // A later Mac change wins over the clamped one.
        let later = merged.setting(\.reminder, to: true, at: now.addingTimeInterval(1), by: .mac)
        #expect(InAppSettings.merge(later, merged).reminder.value == true)
    }

    @Test func checkInKeepsTheNewerRefreshOutcome() {
        let stored = RefreshOutcome(at: now.addingTimeInterval(-60), succeeded: true)
        let older = RefreshOutcome(at: now.addingTimeInterval(-120), succeeded: false, reasonKey: "k")
        let settings = InAppSettings.defaults(reminder: true, at: now)
        let (_, kept) = ChannelHandler.handle(.checkIn(settings: settings, lastRefresh: older, appVersion: nil),
                                              installation: installation(outcome: stored), now: now, reminder: true)
        guard case let .merged(_, _, outcome) = kept else { Issue.record("not merged"); return }
        #expect(outcome == nil) // nothing newer to store
        let (_, none) = ChannelHandler.handle(.checkIn(settings: settings, lastRefresh: nil, appVersion: nil),
                                              installation: installation(outcome: stored), now: now, reminder: true)
        guard case let .merged(_, _, noOutcome) = none else { Issue.record("not merged"); return }
        #expect(noOutcome == nil)
    }

    /// Older state without stored settings: the phone's (clamped) values are taken as they are.
    @Test func checkInWithoutStoredSettingsAdoptsThePhones() {
        var old = installation()
        old.inApp = nil
        let phone = InAppSettings.defaults(reminder: false, at: now.addingTimeInterval(-86_400))
        let (reply, _) = ChannelHandler.handle(.checkIn(settings: phone, lastRefresh: nil, appVersion: nil),
                                               installation: old, now: now, reminder: true)
        #expect(reply == .settings(phone))
    }

    @Test func refreshOfAPausedInstallationIsRefusedWithWhoPausedIt() {
        for by in [ChangeOrigin.mac, .device] {
            let (reply, update) = ChannelHandler.handle(.refresh, installation: installation(paused: true, pausedBy: by), now: now, reminder: true)
            #expect(reply == .paused(by: by))
            #expect(update == .none)
        }
        // Paused before XSide recorded who did it: only the Mac could.
        let (reply, _) = ChannelHandler.handle(.refresh, installation: installation(paused: true), now: now, reminder: true)
        #expect(reply == .paused(by: .mac))
    }

    @Test func refreshIsAcceptedAndRequested() {
        let (reply, update) = ChannelHandler.handle(.refresh, installation: installation(), now: now, reminder: true)
        #expect(reply == .accepted)
        #expect(update == .refreshRequested)
    }

    @Test func setAutoRefreshFromTheDeviceRecordsTheOrigin() {
        let (offReply, off) = ChannelHandler.handle(.setAutoRefresh(false), installation: installation(), now: now, reminder: true)
        #expect(off == .paused(true, by: .device))
        guard case let .settings(s, _, _) = offReply else { Issue.record("no settings"); return }
        #expect(s.autoRefresh == Field(value: false, changedAt: now, changedBy: .device))
        let (_, on) = ChannelHandler.handle(.setAutoRefresh(true),
                                            installation: installation(paused: true, pausedBy: .mac), now: now, reminder: true)
        #expect(on == .paused(false, by: .device))
    }

    /// Mega review C1: the pause is stamped with when the phone asked (never later than now), not
    /// when the Mac read it, so a late request can't win a merge it would have lost.
    @Test func setAutoRefreshIsStampedWithTheRequestTime() {
        let (early, _) = ChannelHandler.handle(.setAutoRefresh(false), installation: installation(), now: now,
                                               reminder: true, requestedAt: now.addingTimeInterval(-30))
        guard case let .settings(s, _, _) = early else { Issue.record("no settings"); return }
        #expect(s.autoRefresh == Field(value: false, changedAt: now.addingTimeInterval(-30), changedBy: .device))
        let (ahead, _) = ChannelHandler.handle(.setAutoRefresh(false), installation: installation(), now: now,
                                               reminder: true, requestedAt: now.addingTimeInterval(90))
        guard case let .settings(a, _, _) = ahead else { Issue.record("no settings"); return }
        #expect(a.autoRefresh.changedAt == now)
        #expect(ChannelHandler.requestDate(timestampMillis: 1_799_999_970_000, now: now) == now.addingTimeInterval(-30))
        #expect(ChannelHandler.requestDate(timestampMillis: 1_800_000_090_000, now: now) == now)
    }

    /// A phone can't make the Mac re-sign its app in a loop: counted from its own last request only.
    @Test func phoneRefreshesAreLimitedByThePhonesOwnRequests() {
        // XSide's own bookkeeping (an unreachable attempt 2 min ago) doesn't block the phone.
        var i = installation()
        i.lastAttempt = now.addingTimeInterval(-2 * 60)
        i.lastErrorKey = XSideError.deviceUnavailable.key
        #expect(ChannelHandler.handle(.refresh, installation: i, now: now, reminder: true) == (.accepted, .refreshRequested))
        i.lastDeviceRefreshRequest = now.addingTimeInterval(-5 * 60)
        #expect(ChannelHandler.handle(.refresh, installation: i, now: now, reminder: true) == (.busy, .none))
        i.lastDeviceRefreshRequest = now.addingTimeInterval(-11 * 60)
        #expect(ChannelHandler.handle(.refresh, installation: i, now: now, reminder: true) == (.accepted, .refreshRequested))
    }

    /// Mega review C4: the refresh the phone asked for failed, so the phone may ask once more at
    /// once; that retry counts like a request, and a success or a stop on the Mac gives none.
    @Test func aFailedPhoneRefreshAllowsOneRetry() {
        var i = installation()
        i.lastDeviceRefreshRequest = now.addingTimeInterval(-5 * 60)
        i.lastRefreshOutcome = RefreshOutcome(at: now.addingTimeInterval(-4 * 60), succeeded: false, reasonKey: "k")
        #expect(ChannelHandler.handle(.refresh, installation: i, now: now, reminder: true) == (.accepted, .refreshRequested))
        #expect(ChannelHandler.isPhoneRetry(i, now: now))
        var retried = i
        retried.lastDeviceRefreshWasRetry = true
        #expect(ChannelHandler.handle(.refresh, installation: retried, now: now, reminder: true) == (.busy, .none))
        var succeeded = i
        succeeded.lastRefreshOutcome = RefreshOutcome(at: now.addingTimeInterval(-4 * 60), succeeded: true)
        #expect(ChannelHandler.handle(.refresh, installation: succeeded, now: now, reminder: true) == (.busy, .none))
        var stopped = i
        stopped.lastRefreshOutcome = RefreshOutcome(at: now.addingTimeInterval(-4 * 60), succeeded: false, reasonKey: "cancelled")
        #expect(ChannelHandler.handle(.refresh, installation: stopped, now: now, reminder: true) == (.busy, .none))
        // A failure from before the request isn't its outcome.
        var older = i
        older.lastRefreshOutcome = RefreshOutcome(at: now.addingTimeInterval(-6 * 60), succeeded: false, reasonKey: "k")
        #expect(ChannelHandler.handle(.refresh, installation: older, now: now, reminder: true) == (.busy, .none))
        // Past the interval, a request is no retry.
        i.lastDeviceRefreshRequest = now.addingTimeInterval(-11 * 60)
        #expect(!ChannelHandler.isPhoneRetry(i, now: now))
    }

    /// Settings seeded for older state follow the Mac's global reminder setting.
    @Test func setAutoRefreshSeedsWithTheGlobalReminder() {
        var old = installation()
        old.inApp = nil
        let (reply, _) = ChannelHandler.handle(.setAutoRefresh(false), installation: old, now: now, reminder: false)
        guard case let .settings(s, _, _) = reply else { Issue.record("no settings"); return }
        #expect(s.reminder.value == false)
    }

    // MARK: receive (authentication)

    func line(_ request: ChannelRequest = .refresh, id: String? = nil, secret: Data? = nil,
              at: Date? = nil, nonce: String = "n1") throws -> Data {
        try ChannelEnvelope.seal(request, installationID: id ?? installationID, secret: secret ?? self.secret,
                                 now: at ?? now, nonce: nonce).encodedLine()
    }

    func lookup(_ id: String) -> Data? { id == installationID ? secret : nil }

    @Test func unknownInstallationIsRejected() throws {
        var nonces = ChannelNonces()
        let other = ChannelEnvelope.installationID(recordID: UUID(), deviceID: "dev-1")
        #expect(ChannelHandler.receive(line: try line(id: other), now: now, nonces: &nonces, secret: lookup) == .rejected)
        // Exact match only: a prefix or a case change is another installation.
        let upper = installationID.lowercased()
        #expect(ChannelHandler.receive(line: try line(id: upper), now: now, nonces: &nonces, secret: lookup) == .rejected)
        #expect(nonces.count(for: other) == 0 && nonces.count(for: upper) == 0)
    }

    @Test func authenticRequestIsOpened() throws {
        var nonces = ChannelNonces()
        let received = ChannelHandler.receive(line: try line(.setAutoRefresh(true)), now: now, nonces: &nonces, secret: lookup)
        #expect(received == .request(installationID: installationID, nonce: "n1", .setAutoRefresh(true)))
    }

    @Test func forgedStaleOrReplayedRequestsAreRejected() throws {
        var nonces = ChannelNonces()
        let wrong = try line(secret: Data(repeating: 8, count: 32), nonce: "a")
        #expect(ChannelHandler.receive(line: wrong, now: now, nonces: &nonces, secret: lookup) == .rejected)
        let stale = try line(at: now.addingTimeInterval(-600), nonce: "b")
        #expect(ChannelHandler.receive(line: stale, now: now, nonces: &nonces, secret: lookup) == .rejected)
        let good = try line(nonce: "c")
        #expect(ChannelHandler.receive(line: good, now: now, nonces: &nonces, secret: lookup) != .rejected)
        #expect(ChannelHandler.receive(line: good, now: now, nonces: &nonces, secret: lookup) == .rejected)
    }

    /// Mega review C1: the replay caches live in memory, so after XSide restarts a request sealed
    /// before it started (still inside the 120 s window) is refused rather than run a second time.
    @Test func requestsSealedBeforeTheChannelStartedAreRejected() throws {
        var nonces = ChannelNonces(notBefore: now)
        let before = try line(.setAutoRefresh(false), at: now.addingTimeInterval(-30), nonce: "old")
        #expect(ChannelHandler.receive(line: before, now: now.addingTimeInterval(5), nonces: &nonces, secret: lookup) == .rejected)
        #expect(nonces.count(for: installationID) == 0)
        let after = try line(.setAutoRefresh(false), at: now.addingTimeInterval(1), nonce: "new")
        #expect(ChannelHandler.receive(line: after, now: now.addingTimeInterval(5), nonces: &nonces, secret: lookup)
                == .request(installationID: installationID, nonce: "new", .setAutoRefresh(false)))
    }

    /// Final review minor 9: the window's edges (120 s either way, inclusive), past and future.
    @Test func timeWindowEdgesArePinned() throws {
        var nonces = ChannelNonces()
        for (offset, nonce) in [(-120.0, "e1"), (120.0, "e2")] {
            let edge = try line(at: now.addingTimeInterval(offset), nonce: nonce)
            #expect(ChannelHandler.receive(line: edge, now: now, nonces: &nonces, secret: lookup) != .rejected)
        }
        for (offset, nonce) in [(-120.001, "o1"), (120.001, "o2"), (-180.0, "o3"), (180.0, "o4")] {
            let outside = try line(at: now.addingTimeInterval(offset), nonce: nonce)
            #expect(ChannelHandler.receive(line: outside, now: now, nonces: &nonces, secret: lookup) == .rejected)
        }
    }

    /// Final review minor 9: a request MACed with installation A's secret but naming B is refused,
    /// and leaves B's nonces untouched.
    @Test func oneInstallationsMacUnderAnothersIDIsRejected() throws {
        let otherID = ChannelEnvelope.installationID(recordID: UUID(), deviceID: "dev-2")
        let otherSecret = Data(repeating: 3, count: 32)
        let both: (String) -> Data? = { $0 == installationID ? secret : $0 == otherID ? otherSecret : nil }
        var nonces = ChannelNonces()
        let forged = try line(id: otherID, secret: secret, nonce: "x")
        #expect(ChannelHandler.receive(line: forged, now: now, nonces: &nonces, secret: both) == .rejected)
        #expect(nonces.count(for: otherID) == 0)
        // The same nonce, properly signed by B, still goes through.
        let real = try line(id: otherID, secret: otherSecret, nonce: "x")
        #expect(ChannelHandler.receive(line: real, now: now, nonces: &nonces, secret: both)
                == .request(installationID: otherID, nonce: "x", .refresh))
    }

    /// One installation filling its nonce cache can't lock the others out.
    @Test func noncesAreKeptPerInstallation() throws {
        let otherID = ChannelEnvelope.installationID(recordID: UUID(), deviceID: "dev-2")
        let otherSecret = Data(repeating: 3, count: 32)
        var nonces = ChannelNonces(capacityPerInstallation: 2)
        let both: (String) -> Data? = { $0 == installationID ? secret : $0 == otherID ? otherSecret : nil }
        for n in ["a", "b"] {
            #expect(ChannelHandler.receive(line: try line(nonce: n), now: now, nonces: &nonces, secret: both) != .rejected)
        }
        #expect(ChannelHandler.receive(line: try line(nonce: "c"), now: now, nonces: &nonces, secret: both) == .rejected) // full
        let other = try line(id: otherID, secret: otherSecret, nonce: "d")
        #expect(ChannelHandler.receive(line: other, now: now, nonces: &nonces, secret: both)
                == .request(installationID: otherID, nonce: "d", .refresh))
        #expect(nonces.count(for: installationID) == 2 && nonces.count(for: otherID) == 1)
    }

    @Test func garbageIsMalformed() {
        var nonces = ChannelNonces()
        for junk in ["", "hello", "{}", "[1,2]", #"{"installationID":5}"#, String(repeating: "{", count: 10_000)] {
            #expect(ChannelHandler.receive(line: Data(junk.utf8), now: now, nonces: &nonces, secret: lookup) == .malformed)
        }
    }

    /// The unauthenticated refusal is a bare reply object (not an envelope): nothing is signed for
    /// a request that didn't authenticate.
    @Test func rejectedLineIsAnUnsignedReply() throws {
        let line = ChannelHandler.rejectedLine
        #expect(line.last == 0x0A)
        #expect(try ChannelReply.decode(body: line.dropLast()) == .rejected)
        #expect((try? ChannelReplyEnvelope.decode(line: line.dropLast())) == nil)
    }

    @Test func sealedReplyOpensOnThePhone() throws {
        let data = try ChannelHandler.replyLine(.refreshed, installationID: installationID, requestNonce: "n1", secret: secret, version: .v1)
        #expect(data.last == 0x0A)
        let envelope = try ChannelReplyEnvelope.decode(line: data.dropLast())
        #expect(envelope.open(secret: secret, expectedInstallationID: installationID, expectedNonce: "n1") == .refreshed)
    }

    // MARK: line framing

    @Test func lineReaderReturnsTheFirstLine() {
        var reader = ChannelLineReader(maxLength: 16)
        #expect(reader.append(Data("abc".utf8)) == .needMore)
        #expect(reader.append(Data("de\nrest".utf8)) == .line(Data("abcde".utf8)))
    }

    @Test func lineReaderRefusesOversizedInput() {
        var reader = ChannelLineReader(maxLength: 8)
        #expect(reader.append(Data("12345".utf8)) == .needMore)
        #expect(reader.append(Data("6789".utf8)) == .tooLong)
        var exact = ChannelLineReader(maxLength: 4)
        #expect(exact.append(Data("1234\n".utf8)) == .line(Data("1234".utf8)))
        var long = ChannelLineReader(maxLength: 4)
        #expect(long.append(Data("12345\n".utf8)) == .tooLong)
    }

    // MARK: installation state

    @Test func seedingFollowsThePauseAndTheGlobalReminder() {
        var paused = installation(paused: true)
        paused.inApp = nil
        let seeded = paused.seededInApp(reminder: false, at: now)
        #expect(seeded.reminder.value == false)
        #expect(seeded.autoRefresh.value == false) // already paused from the Mac
        #expect(seeded.alertLate == Field(value: true, changedAt: now, changedBy: .mac))
        let kept = installation().seededInApp(reminder: false, at: now)
        #expect(kept == installation().inApp) // already there: unchanged
    }

    /// What arrived through the channel while the app was being signed is kept by the result.
    @Test func signingKeepsWhatArrivedMeanwhile() {
        let signedAt = now
        let signed = InAppSettings.defaults(reminder: true, at: signedAt.addingTimeInterval(-3600))
        var result = installation(inApp: signed)
        result.lastCheckIn = nil
        var current = installation(inApp: signed.setting(\.autoRefresh, to: false, at: signedAt.addingTimeInterval(30), by: .device),
                                   paused: true, pausedBy: .device,
                                   outcome: RefreshOutcome(at: signedAt.addingTimeInterval(5), succeeded: false, reasonKey: "k"))
        current.lastCheckIn = signedAt.addingTimeInterval(20)
        result.lastRefreshOutcome = RefreshOutcome(at: signedAt, succeeded: true)
        let merged = result.keepingChannelState(of: current)
        #expect(merged.inApp?.autoRefresh.value == false)
        #expect(merged.refreshPaused && merged.pausedBy == .device)
        #expect(merged.lastCheckIn == signedAt.addingTimeInterval(20))
        #expect(merged.lastRefreshOutcome?.at == signedAt.addingTimeInterval(5))
        #expect(merged.channelSecret == result.channelSecret)
        current.lastDeviceRefreshRequest = signedAt.addingTimeInterval(-60)
        #expect(result.keepingChannelState(of: current).lastDeviceRefreshRequest == signedAt.addingTimeInterval(-60))
        // Nothing new meanwhile: the signing result stands, not paused.
        let plain = result.keepingChannelState(of: installation(inApp: signed))
        #expect(!plain.refreshPaused && plain.pausedBy == nil && plain.inApp == signed)
    }
}

@Suite struct ChannelLibraryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func library() async throws -> (AppLibrary, AppRecord, URL) {
        let tmp = TestTemp.root.appendingPathComponent(UUID().uuidString)
        let lib = AppLibrary(root: tmp)
        let src = tmp.appendingPathComponent("src.ipa")
        try Data("ipa".utf8).write(to: src)
        let rec = try await lib.importIPA(src, info: AppInfo(bundleID: "com.example.a", name: "A", version: "1", executable: "A"),
                                          teamID: "TEAM123456")
        try await lib.upsert(Installation(deviceID: "a", installedAt: now, expiresAt: now.addingTimeInterval(86_400),
                                          inApp: InAppSettings.defaults(reminder: true, at: now.addingTimeInterval(-60))),
                             for: rec.id)
        return (lib, rec, tmp)
    }

    func stored(_ lib: AppLibrary, _ id: UUID) async -> Installation? {
        await lib.records().first { $0.id == id }?.installations.first
    }

    @Test func pausingRecordsWhoAndStampsTheSetting() async throws {
        let (lib, rec, tmp) = try await library(); defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(try await lib.setRefreshPaused(true, recordID: rec.id, deviceID: "a", by: .device, at: now))
        var i = await stored(lib, rec.id)
        #expect(i?.refreshPaused == true && i?.pausedBy == .device)
        #expect(i?.inApp?.autoRefresh == Field(value: false, changedAt: now, changedBy: .device))
        #expect(i?.lastMacEdit == nil) // the phone's change, not the Mac's
        #expect(try await lib.setRefreshPaused(false, recordID: rec.id, deviceID: "a", by: .mac, at: now.addingTimeInterval(1)))
        i = await stored(lib, rec.id)
        #expect(i?.refreshPaused == false && i?.pausedBy == nil)
        #expect(i?.inApp?.autoRefresh == Field(value: true, changedAt: now.addingTimeInterval(1), changedBy: .mac))
        #expect(i?.lastMacEdit == now.addingTimeInterval(1))
    }

    /// Mega review C8: the phone pausing an app the Mac paused for a while makes it the phone's
    /// pause, until resumed: the Mac's end no longer resumes it.
    @Test func aPhonePauseOverATimedMacPauseBecomesThePhones() async throws {
        let (lib, rec, tmp) = try await library(); defer { try? FileManager.default.removeItem(at: tmp) }
        let end = now.addingTimeInterval(2 * 3600)
        #expect(try await lib.setRefreshPaused(true, recordID: rec.id, deviceID: "a", by: .mac, at: now, until: end))
        #expect(try await lib.setRefreshPaused(true, recordID: rec.id, deviceID: "a", by: .device, at: now.addingTimeInterval(5)))
        let i = await stored(lib, rec.id)
        #expect(i?.refreshPaused == true && i?.pausedBy == .device && i?.pausedUntil == nil)
        #expect(i?.inApp?.autoRefresh == Field(value: false, changedAt: now.addingTimeInterval(5), changedBy: .device))
        #expect(try await lib.resumeEndedPauses(at: end.addingTimeInterval(1)).isEmpty)
        // The same choice again changes nothing.
        #expect(try await lib.setRefreshPaused(true, recordID: rec.id, deviceID: "a", by: .device, at: now.addingTimeInterval(9)) == false)
    }

    /// Device feedback 3, E5: a pause of one app for a while (2 h, a day): paused like "Arrêter de
    /// rafraîchir" (the app is told), with an end; once over, it resumes by itself; a resume from
    /// anywhere, or a pause until resumed, drops the end.
    @Test func aTimedPauseOfOneAppEndsByItself() async throws {
        let (lib, rec, tmp) = try await library(); defer { try? FileManager.default.removeItem(at: tmp) }
        let end = now.addingTimeInterval(2 * 3600)
        #expect(try await lib.setRefreshPaused(true, recordID: rec.id, deviceID: "a", by: .mac, at: now, until: end))
        var i = await stored(lib, rec.id)
        #expect(i?.refreshPaused == true && i?.pausedUntil == end && i?.inApp?.autoRefresh.value == false)
        #expect(try await lib.resumeEndedPauses(at: now.addingTimeInterval(3600)).isEmpty)
        let resumed = try await lib.resumeEndedPauses(at: end)
        #expect(resumed == [RefreshJob(recordID: rec.id, deviceID: "a")])
        i = await stored(lib, rec.id)
        #expect(i?.refreshPaused == false && i?.pausedUntil == nil)
        #expect(i?.inApp?.autoRefresh == Field(value: true, changedAt: end, changedBy: .mac))
        // Paused again until resumed: no end; resumed by hand: none either.
        #expect(try await lib.setRefreshPaused(true, recordID: rec.id, deviceID: "a", by: .mac, at: end, until: end.addingTimeInterval(60)))
        #expect(try await lib.setRefreshPaused(false, recordID: rec.id, deviceID: "a", by: .device, at: end))
        #expect(await stored(lib, rec.id)?.pausedUntil == nil)
        #expect(try await lib.setRefreshPaused(true, recordID: rec.id, deviceID: "a", by: .mac, at: end))
        #expect(await stored(lib, rec.id)?.pausedUntil == nil)
        #expect(try await lib.resumeEndedPauses(at: end.addingTimeInterval(86_400 * 30)).isEmpty)
        // Review D–G minor 10: an installation XSide is working on (an uninstall) is left for later.
        #expect(try await lib.setRefreshPaused(false, recordID: rec.id, deviceID: "a", by: .mac, at: end))
        let later = end.addingTimeInterval(60)
        #expect(try await lib.setRefreshPaused(true, recordID: rec.id, deviceID: "a", by: .mac, at: end, until: later))
        let busy: Set<RefreshJob> = [RefreshJob(recordID: rec.id, deviceID: "a")]
        #expect(try await lib.resumeEndedPauses(at: later, skipping: busy).isEmpty)
        #expect(await stored(lib, rec.id)?.refreshPaused == true)
        #expect(try await lib.resumeEndedPauses(at: later, skipping: []) == [RefreshJob(recordID: rec.id, deviceID: "a")])
        // Older state has none.
        let old = try JSONDecoder().decode(Installation.self, from: Data(
            #"{"deviceID":"a","installedAt":0,"expiresAt":0,"refreshPaused":true}"#.utf8))
        #expect(old.pausedUntil == nil)
    }

    @Test func macEditIsStampedAndKeepsThePause() async throws {
        let (lib, rec, tmp) = try await library(); defer { try? FileManager.default.removeItem(at: tmp) }
        try await lib.editInApp(recordID: rec.id, deviceID: "a", reminder: true, at: now) {
            $0.setting(\.reminder, to: false, at: now, by: .mac)
        }
        let i = await stored(lib, rec.id)
        #expect(i?.inApp?.reminder == Field(value: false, changedAt: now, changedBy: .mac))
        #expect(i?.refreshPaused == false)
        #expect(i?.lastMacEdit == now)
        // An "edit" that changes nothing isn't one.
        try await lib.editInApp(recordID: rec.id, deviceID: "a", reminder: true, at: now.addingTimeInterval(5)) {
            $0.setting(\.reminder, to: false, at: now.addingTimeInterval(5), by: .mac)
        }
        #expect(await stored(lib, rec.id)?.lastMacEdit == now)
        await #expect(throws: XSideError.recordNotFound) {
            try await lib.editInApp(recordID: rec.id, deviceID: "zz", reminder: true, at: now) { $0 }
        }
    }

    /// Device round 2, item 2: the app checked in on this device, then was deleted there (or its
    /// record removed) and installed again: the new installation has no check-in of its own, but
    /// the library remembers that this app on this device was connected (local network allowed),
    /// across a restart, so step ④ says « Déjà connectée » instead of « Pas encore connecté ».
    @Test func aConnectionIsRememberedAcrossAReinstall() async throws {
        let (lib, rec, tmp) = try await library(); defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(await lib.lastConnection(bundleID: "com.example.a", deviceID: "a") == nil)
        let merged = InAppSettings.defaults(reminder: true, at: now.addingTimeInterval(-60))
        _ = try await lib.applyCheckIn(merged, checkIn: now, outcome: nil, recordID: rec.id, deviceID: "a")
        #expect(await lib.lastConnection(bundleID: "com.example.a", deviceID: "a") == now)
        _ = try await lib.removeInstallation(recordID: rec.id, deviceID: "a")
        try await lib.remove(rec.id)
        let again = AppLibrary(root: tmp)
        #expect(await again.lastConnection(bundleID: "com.example.a", deviceID: "a") == now)
        #expect(await again.lastConnection(bundleID: "com.example.a", deviceID: "b") == nil)
        let fresh = Installation(deviceID: "a", installedAt: now.addingTimeInterval(600), expiresAt: now.addingTimeInterval(86_400),
                                 channelSecret: Data([1]))
        #expect(ReachabilityStatus.of(installation: fresh, now: now.addingTimeInterval(700),
                                      connectedBefore: await again.lastConnection(bundleID: "com.example.a", deviceID: "a"))
                == .connectedBefore(now))
        #expect(ReachabilityStatus.of(installation: fresh, now: now.addingTimeInterval(700)) == .neverConnected)
        // Its own check-in wins once it comes.
        var seen = fresh
        seen.lastCheckIn = now.addingTimeInterval(650)
        #expect(ReachabilityStatus.of(installation: seen, now: now.addingTimeInterval(700), connectedBefore: now)
                == .joinable(lastSeen: now.addingTimeInterval(650)))
    }

    /// A library written before the history existed: its installations' check-ins seed it.
    @Test func olderInstallationsSeedTheConnectionHistory() async throws {
        let (lib, rec, tmp) = try await library(); defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try await lib.applyCheckIn(InAppSettings.defaults(reminder: true, at: now.addingTimeInterval(-60)), checkIn: now,
                                       outcome: nil, recordID: rec.id, deviceID: "a")
        try FileManager.default.removeItem(at: tmp.appendingPathComponent(AppLibrary.connectionsFile))
        #expect(await AppLibrary(root: tmp).lastConnection(bundleID: "com.example.a", deviceID: "a") == now)
    }

    @Test func checkInIsStoredAndItsAutoRefreshApplies() async throws {
        let (lib, rec, tmp) = try await library(); defer { try? FileManager.default.removeItem(at: tmp) }
        let merged = InAppSettings.defaults(reminder: true, at: now.addingTimeInterval(-60))
            .setting(\.autoRefresh, to: false, at: now, by: .device)
        let outcome = RefreshOutcome(at: now, succeeded: false, reasonKey: "k")
        let change = try await lib.applyCheckIn(merged, checkIn: now, outcome: outcome, recordID: rec.id, deviceID: "a")
        #expect(change == true) // now paused
        let i = await stored(lib, rec.id)
        #expect(i?.inApp == merged && i?.lastCheckIn == now && i?.lastRefreshOutcome == outcome)
        #expect(i?.refreshPaused == true && i?.pausedBy == .device)
        let again = try await lib.applyCheckIn(merged, checkIn: now, outcome: nil, recordID: rec.id, deviceID: "a")
        #expect(again == nil) // no pause change
        #expect(await stored(lib, rec.id)?.lastRefreshOutcome == outcome) // nil keeps the stored one
    }

    /// Device feedback 3, E2, the whole sequence: the app is open and polling; the Mac edits a
    /// setting of that installation; the next poll's signed reply carries the Mac's newer field,
    /// and the fields it changes for the phone are those the Mac's log names; the check-in stored
    /// after it keeps the edit, which the Mac then calls confirmed.
    @Test func aMacEditReachesThePollingPhone() async throws {
        let (lib, rec, tmp) = try await library(); defer { try? FileManager.default.removeItem(at: tmp) }
        let secret = Data(repeating: 7, count: 32)
        let channelID = ChannelEnvelope.installationID(recordID: rec.id, deviceID: "a")
        // What the phone holds: the settings written at signing (60 s ago).
        let phone = InAppSettings.defaults(reminder: true, at: now.addingTimeInterval(-60))
        _ = try await lib.applyCheckIn(phone, checkIn: now.addingTimeInterval(-30), outcome: nil, recordID: rec.id, deviceID: "a")
        let edit = now.addingTimeInterval(-5)
        try await lib.editInApp(recordID: rec.id, deviceID: "a", reminder: true, at: edit) {
            $0.setting(\.refreshCard, to: false, at: edit, by: .mac)
        }
        // The poll: the installation the channel id names is the one edited.
        let found = try #require(await lib.installation(channelID: channelID))
        #expect(found.recordID == rec.id && found.installation.deviceID == "a")
        let (reply, update) = ChannelHandler.handle(.checkIn(settings: phone, lastRefresh: nil, appVersion: "1"),
                                                    installation: found.installation, now: now, reminder: true)
        guard case let .settings(sent, _, _) = reply else { Issue.record("no settings reply"); return }
        #expect(sent.refreshCard == Field(value: false, changedAt: edit, changedBy: .mac))
        #expect(ChannelHandler.fieldsChanged(for: phone, by: sent) == [.refreshCard])
        // Over the wire, as the phone opens it.
        let line = try ChannelHandler.replyLine(reply, installationID: channelID, requestNonce: "n1", secret: secret, version: .v1)
        let opened = try ChannelReplyEnvelope.decode(line: line.dropLast())
            .open(secret: secret, expectedInstallationID: channelID, expectedNonce: "n1")
        guard case let .settings(received, _, _)? = opened else { Issue.record("reply not opened"); return }
        #expect(received.refreshCard.value == false && received.refreshCard.changedBy == .mac)
        #expect(abs(received.refreshCard.changedAt.timeIntervalSince(edit)) < 0.001)
        // Stored, the edit stays the Mac's and is confirmed by this check-in.
        guard case let .merged(merged, checkIn, outcome) = update else { Issue.record("no merge"); return }
        _ = try await lib.applyCheckIn(merged, checkIn: checkIn, outcome: outcome, recordID: rec.id, deviceID: "a")
        let stored = try #require(await stored(lib, rec.id))
        #expect(stored.inApp?.refreshCard.value == false)
        #expect(SettingsDelivery.of(installation: stored) == .confirmed(lastCheckIn: now))
        // The next poll, from a phone that adopted it, changes nothing.
        #expect(ChannelHandler.fieldsChanged(for: received, by: merged).isEmpty)
    }

    /// The phone checks in every 15 s while the app is in front (device feedback round 2, P3): a
    /// check-in that changes nothing, within a minute of the stored one, writes nothing.
    @Test func aCheckInThatChangesNothingSoonAfterAnotherIsNotWritten() async throws {
        let (lib, rec, tmp) = try await library(); defer { try? FileManager.default.removeItem(at: tmp) }
        let merged = InAppSettings.defaults(reminder: true, at: now.addingTimeInterval(-60))
        _ = try await lib.applyCheckIn(merged, checkIn: now, outcome: nil, recordID: rec.id, deviceID: "a")
        _ = try await lib.applyCheckIn(merged, checkIn: now.addingTimeInterval(20), outcome: nil, recordID: rec.id, deviceID: "a")
        #expect(await stored(lib, rec.id)?.lastCheckIn == now)
        #expect(try await AppLibrary(root: tmp).records().first?.installations.first?.lastCheckIn == now)
        _ = try await lib.applyCheckIn(merged, checkIn: now.addingTimeInterval(61), outcome: nil, recordID: rec.id, deviceID: "a")
        #expect(await stored(lib, rec.id)?.lastCheckIn == now.addingTimeInterval(61))
        // A change is stored at once, with its check-in date.
        let changed = merged.setting(\.reminder, to: false, at: now.addingTimeInterval(70), by: .device)
        _ = try await lib.applyCheckIn(changed, checkIn: now.addingTimeInterval(70), outcome: nil, recordID: rec.id, deviceID: "a")
        let i = await stored(lib, rec.id)
        #expect(i?.inApp == changed && i?.lastCheckIn == now.addingTimeInterval(70))
        // So is a newer refresh outcome.
        let outcome = RefreshOutcome(at: now.addingTimeInterval(75), succeeded: true, reasonKey: nil)
        _ = try await lib.applyCheckIn(changed, checkIn: now.addingTimeInterval(80), outcome: outcome, recordID: rec.id, deviceID: "a")
        #expect(await stored(lib, rec.id)?.lastRefreshOutcome == outcome)
    }

    /// A signing stored between the handler's snapshot and the check-in is merged, not overwritten.
    @Test func checkInMergesIntoWhatIsStoredNow() async throws {
        let (lib, rec, tmp) = try await library(); defer { try? FileManager.default.removeItem(at: tmp) }
        var i = try #require(await stored(lib, rec.id))
        i.inApp = i.inApp?.setting(\.autoRefresh, to: true, at: now.addingTimeInterval(10), by: .mac)
        try await lib.upsert(i, for: rec.id)
        let snapshot = InAppSettings.defaults(reminder: true, at: now.addingTimeInterval(-60))
            .setting(\.autoRefresh, to: false, at: now, by: .device)
            .setting(\.language, to: .fr, at: now, by: .device)
        let change = try await lib.applyCheckIn(snapshot, checkIn: now, outcome: nil, recordID: rec.id, deviceID: "a")
        #expect(change == nil)
        let after = await stored(lib, rec.id)
        #expect(after?.inApp?.autoRefresh == Field(value: true, changedAt: now.addingTimeInterval(10), changedBy: .mac))
        #expect(after?.inApp?.language.value == .fr)
        #expect(after?.refreshPaused == false)
    }

    @Test func failureIsRecordedOnTheCurrentInstallation() async throws {
        let (lib, rec, tmp) = try await library(); defer { try? FileManager.default.removeItem(at: tmp) }
        try await lib.setRefreshPaused(true, recordID: rec.id, deviceID: "a", by: .device, at: now)
        try await lib.recordFailure(errorKey: "k", at: now.addingTimeInterval(5), recordID: rec.id, deviceID: "a")
        let after = await stored(lib, rec.id)
        #expect(after?.refreshPaused == true && after?.pausedBy == .device)
        #expect(after?.lastErrorKey == "k" && after?.lastAttempt == now.addingTimeInterval(5))
        #expect(after?.lastRefreshOutcome == RefreshOutcome(at: now.addingTimeInterval(5), succeeded: false, reasonKey: "k"))
        await #expect(throws: XSideError.recordNotFound) {
            try await lib.recordFailure(errorKey: "k", at: now, recordID: rec.id, deviceID: "gone")
        }
    }

    /// Nothing the phone sends (pause, resume, check-in) resets its last refresh request.
    @Test func thePhonesLastRefreshRequestSurvivesItsOtherMessages() async throws {
        let (lib, rec, tmp) = try await library(); defer { try? FileManager.default.removeItem(at: tmp) }
        try await lib.markDeviceRefreshRequest(at: now, recordID: rec.id, deviceID: "a")
        try await lib.setRefreshPaused(true, recordID: rec.id, deviceID: "a", by: .device, at: now.addingTimeInterval(60))
        try await lib.applyCheckIn(InAppSettings.defaults(reminder: true, at: now), checkIn: now.addingTimeInterval(90),
                                   outcome: nil, recordID: rec.id, deviceID: "a")
        try await lib.setRefreshPaused(false, recordID: rec.id, deviceID: "a", by: .device, at: now.addingTimeInterval(120))
        let reloaded = try #require(await AppLibrary(root: tmp).records().first?.installations.first) // persisted
        #expect(reloaded.lastDeviceRefreshRequest == now)
        #expect(!reloaded.refreshPaused)
        #expect(ChannelHandler.handle(.refresh, installation: reloaded, now: now.addingTimeInterval(5 * 60), reminder: true)
                == (.busy, .none))
    }

    /// Mega review C4: whether the phone's last request was its retry is kept (and a new request
    /// that isn't one clears it), across a signing too.
    @Test func thePhonesRetryIsRemembered() async throws {
        let (lib, rec, tmp) = try await library(); defer { try? FileManager.default.removeItem(at: tmp) }
        try await lib.markDeviceRefreshRequest(at: now, recordID: rec.id, deviceID: "a", retry: true)
        var reloaded = try #require(await AppLibrary(root: tmp).records().first?.installations.first)
        #expect(reloaded.lastDeviceRefreshWasRetry == true)
        var signed = reloaded
        signed.lastDeviceRefreshRequest = nil
        signed.lastDeviceRefreshWasRetry = nil
        #expect(signed.keepingChannelState(of: reloaded).lastDeviceRefreshWasRetry == true)
        try await lib.markDeviceRefreshRequest(at: now.addingTimeInterval(700), recordID: rec.id, deviceID: "a")
        reloaded = try #require(await AppLibrary(root: tmp).records().first?.installations.first)
        #expect(reloaded.lastDeviceRefreshWasRetry == nil)
    }

    @Test func missingSettingsAreSeeded() async throws {
        let (lib, rec, tmp) = try await library(); defer { try? FileManager.default.removeItem(at: tmp) }
        try await lib.upsert(Installation(deviceID: "b", installedAt: now, expiresAt: now, refreshPaused: true), for: rec.id)
        #expect(try await lib.seedInAppSettings(reminder: false, at: now) == 1)
        let b = await lib.records().first?.installations.first { $0.deviceID == "b" }
        #expect(b?.inApp?.reminder.value == false && b?.inApp?.autoRefresh.value == false)
        #expect(try await lib.seedInAppSettings(reminder: false, at: now) == 0)
    }

    @Test func secretLookupIsExact() async throws {
        let (lib, rec, tmp) = try await library(); defer { try? FileManager.default.removeItem(at: tmp) }
        var i = try #require(await stored(lib, rec.id))
        i.channelSecret = Data(repeating: 1, count: 32)
        try await lib.upsert(i, for: rec.id)
        let id = ChannelEnvelope.installationID(recordID: rec.id, deviceID: "a")
        let found = await lib.installation(channelID: id)
        #expect(found?.recordID == rec.id && found?.installation.deviceID == "a")
        #expect(await lib.installation(channelID: id + "x") == nil)
        #expect(await lib.installation(channelID: id.lowercased()) == nil)
    }

    /// Device feedback 2026-11-08: automatic refresh turned off on the phone (reported at t1), turned
    /// back on from the Mac panel (t2 > t1), then the app opens: the check-in carries the phone's
    /// old "off" and the reply must carry the Mac's newer "on", the pause staying lifted.
    @Test func macResumeWinsOverAnOlderPhoneOff() async throws {
        let (lib, rec, tmp) = try await library(); defer { try? FileManager.default.removeItem(at: tmp) }
        let t1 = now, t2 = now.addingTimeInterval(30), t3 = now.addingTimeInterval(60)
        // 1. The phone reports "off" (changed there at t1): XSide pauses.
        let phone = InAppSettings.defaults(reminder: true, at: now.addingTimeInterval(-60))
            .setting(\.autoRefresh, to: false, at: t1, by: .device)
        var i = try #require(await stored(lib, rec.id))
        var (reply, update) = ChannelHandler.handle(.checkIn(settings: phone, lastRefresh: nil, appVersion: "1"),
                                                    installation: i, now: t1, reminder: true)
        guard case let .merged(m1, c1, o1) = update else { Issue.record("not merged"); return }
        #expect(try await lib.applyCheckIn(m1, checkIn: c1, outcome: o1, recordID: rec.id, deviceID: "a") == true)
        #expect(await stored(lib, rec.id)?.pausedBy == .device)
        // 2. The Mac resumes at t2: stamped as the Mac's change, dated t2.
        #expect(try await lib.setRefreshPaused(false, recordID: rec.id, deviceID: "a", by: .mac, at: t2))
        i = try #require(await stored(lib, rec.id))
        #expect(i.inApp?.autoRefresh == Field(value: true, changedAt: t2, changedBy: .mac))
        // 3. The app opens and checks in with what it still holds (off, device, t1).
        (reply, update) = ChannelHandler.handle(.checkIn(settings: phone, lastRefresh: nil, appVersion: "1"),
                                                installation: i, now: t3, reminder: true)
        guard case let .settings(sent, _, _) = reply, case let .merged(m3, c3, o3) = update else {
            Issue.record("unexpected reply \(reply)"); return
        }
        #expect(sent.autoRefresh == Field(value: true, changedAt: t2, changedBy: .mac))
        #expect(try await lib.applyCheckIn(m3, checkIn: c3, outcome: o3, recordID: rec.id, deviceID: "a") == nil)
        let after = try #require(await stored(lib, rec.id))
        #expect(!after.refreshPaused && after.inApp?.autoRefresh.value == true)
    }
}
