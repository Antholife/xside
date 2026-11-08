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
        guard case let .settings(merged, _) = reply else { Issue.record("no settings"); return }
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
        guard case let .settings(s, _) = offReply else { Issue.record("no settings"); return }
        #expect(s.autoRefresh == Field(value: false, changedAt: now, changedBy: .device))
        let (_, on) = ChannelHandler.handle(.setAutoRefresh(true),
                                            installation: installation(paused: true, pausedBy: .mac), now: now, reminder: true)
        #expect(on == .paused(false, by: .device))
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

    /// Settings seeded for older state follow the Mac's global reminder setting.
    @Test func setAutoRefreshSeedsWithTheGlobalReminder() {
        var old = installation()
        old.inApp = nil
        let (reply, _) = ChannelHandler.handle(.setAutoRefresh(false), installation: old, now: now, reminder: false)
        guard case let .settings(s, _) = reply else { Issue.record("no settings"); return }
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
        let data = try ChannelHandler.replyLine(.refreshed, installationID: installationID, requestNonce: "n1", secret: secret)
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
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        guard case let .settings(sent, _) = reply, case let .merged(m3, c3, o3) = update else {
            Issue.record("unexpected reply \(reply)"); return
        }
        #expect(sent.autoRefresh == Field(value: true, changedAt: t2, changedBy: .mac))
        #expect(try await lib.applyCheckIn(m3, checkIn: c3, outcome: o3, recordID: rec.id, deviceID: "a") == nil)
        let after = try #require(await stored(lib, rec.id))
        #expect(!after.refreshPaused && after.inApp?.autoRefresh.value == true)
    }
}
