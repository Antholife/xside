import Testing
import Foundation
@testable import XSideCore

/// Device feedback 4: while the app is in front it holds a signed watch, and the Mac writes its
/// changes on it at once instead of waiting for the next 15 s poll.
@Suite struct ChannelWatchTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let secret = Data(repeating: 7, count: 32)
    let id = "REC|dev"
    var settings: InAppSettings { .defaults(reminder: true, at: now.addingTimeInterval(-60)) }

    /// A hub whose single watch writes into `lines`.
    final class Sink: @unchecked Sendable { var lines: [Data] = [] }

    func line(_ data: Data) -> Data { data.last == 0x0A ? data.dropLast() : data }

    // MARK: wire

    @Test func watchRequestAndLiveRepliesRoundTrip() throws {
        let watch = ChannelRequest.watch(settings: settings, lastRefresh: nil, appVersion: "1")
        let env = try ChannelEnvelope.seal(watch, installationID: id, secret: secret, now: now, nonce: "w1")
        var seen = NonceCache()
        #expect(try ChannelEnvelope.decode(line: env.encodedLine()).open(secret: secret, now: now, seen: &seen) == watch)
        #expect(String(decoding: env.body, as: UTF8.self).contains(#""type":"watch""#))
        #expect(watch.checkInReport?.settings == settings)
        for reply in [ChannelReply.live(seq: 3, settings, lastRefresh: RefreshOutcome(at: now, succeeded: true, reasonKey: nil)),
                      .alive(seq: 4)] {
            #expect(try ChannelReply.decode(body: reply.encodedBody()) == reply)
        }
        #expect(String(decoding: try ChannelReply.alive(seq: 2).encodedBody(), as: UTF8.self) == #"{"seq":2,"type":"alive"}"#)
    }

    /// A watch is a check-in first: same reply, same storage.
    @Test func watchIsHandledAsACheckIn() {
        let installation = Installation(deviceID: "dev", installedAt: now, expiresAt: now.addingTimeInterval(86_400),
                                        inApp: settings.setting(\.reminder, to: false, at: now.addingTimeInterval(-5), by: .mac),
                                        channelSecret: secret)
        let phone = settings
        #expect(ChannelHandler.handle(.watch(settings: phone, lastRefresh: nil, appVersion: "1"), installation: installation,
                                      now: now, reminder: true)
                == ChannelHandler.handle(.checkIn(settings: phone, lastRefresh: nil, appVersion: "1"), installation: installation,
                                         now: now, reminder: true))
    }

    // MARK: the phone's checks

    func openedWatch(_ sink: Sink, nonce: String = "w1") throws -> ChannelWatches<Int> {
        let hub = ChannelWatches<Int>()
        try hub.open(1, installationID: id, nonce: nonce, secret: secret,
                     first: ChannelWatchState(settings: settings, lastRefresh: nil), now: now) { sink.lines.append($0) }
        return hub
    }

    @Test func forgedPushLineIsRejectedByThePhone() throws {
        let sink = Sink()
        let hub = try openedWatch(sink)
        hub.update(id, to: ChannelWatchState(settings: settings.setting(\.reminder, to: false, at: now, by: .mac), lastRefresh: nil), now: now)
        let real = line(sink.lines[1])
        // Another key (an attacker on the LAN doesn't have the installation's secret).
        let forged = try ChannelReplyEnvelope.seal(.live(seq: 1, settings.setting(\.autoRefresh, to: false, at: now, by: .mac)),
                                                   installationID: id, requestNonce: "w1", secret: Data(repeating: 9, count: 32))
        var reader = ChannelWatchReader(installationID: id, nonce: "w1", secret: secret)
        #expect(reader.open(line: line(try forged.encodedLine())) == nil)
        // The real line with its body swapped (MAC no longer matches).
        var tampered = try ChannelReplyEnvelope.decode(line: real)
        tampered.body = try ChannelReply.live(seq: 1, settings.setting(\.autoRefresh, to: false, at: now, by: .mac)).encodedBody()
        #expect(reader.open(line: line(try tampered.encodedLine())) == nil)
        // Unsigned: a bare reply, or the bare `rejected` (only ever valid as a request's first line).
        #expect(reader.open(line: Data(#"{"seq":1,"type":"alive"}"#.utf8)) == nil)
        #expect(reader.open(line: line(ChannelHandler.rejectedLine)) == nil)
        // A signed reply that isn't a watch line (no seq) is refused too.
        let settingsReply = try ChannelReplyEnvelope.seal(.settings(settings), installationID: id, requestNonce: "w1", secret: secret)
        #expect(reader.open(line: line(try settingsReply.encodedLine())) == nil)
        #expect(reader.lastSeq == 0)
        // The real one opens.
        guard case let .live(1, received, _, _)? = reader.open(line: real) else { Issue.record("real line refused"); return }
        #expect(received.reminder.value == false)
    }

    @Test func replayedPushLineIsRejectedByThePhone() throws {
        let sink = Sink()
        let hub = try openedWatch(sink)
        let off = settings.setting(\.reminder, to: false, at: now, by: .mac)
        hub.update(id, to: ChannelWatchState(settings: off, lastRefresh: nil), now: now)
        hub.keepAlive(now: now.addingTimeInterval(30))
        hub.update(id, to: ChannelWatchState(settings: off.setting(\.reminder, to: true, at: now.addingTimeInterval(40), by: .mac),
                                             lastRefresh: nil), now: now.addingTimeInterval(40))
        #expect(sink.lines.count == 4) // settings, live 1, alive 2, live 3
        let (live1, alive2, live3) = (line(sink.lines[1]), line(sink.lines[2]), line(sink.lines[3]))
        var reader = ChannelWatchReader(installationID: id, nonce: "w1", secret: secret)
        // Skipping a line (one dropped or held back) is refused.
        #expect(reader.open(line: alive2) == nil)
        #expect(reader.open(line: live1) != nil)
        // The same line again: refused.
        #expect(reader.open(line: live1) == nil)
        #expect(reader.open(line: alive2) == .alive(seq: 2))
        #expect(reader.open(line: live1) == nil) // an older one, replayed later
        // A line from this watch carried to another watch (other nonce): refused.
        var other = ChannelWatchReader(installationID: id, nonce: "w2", secret: secret)
        #expect(other.open(line: live1) == nil)
        // To another installation: refused.
        var elsewhere = ChannelWatchReader(installationID: "REC|other", nonce: "w1", secret: secret)
        #expect(elsewhere.open(line: live1) == nil)
        guard case .live(3, _, _, _)? = reader.open(line: live3) else { Issue.record("live 3 refused"); return }
    }

    // MARK: the Mac's side

    @Test func watchWithoutAValidSignatureIsNeverAdmitted() throws {
        let watch = ChannelRequest.watch(settings: settings, lastRefresh: nil, appVersion: "1")
        var nonces = ChannelNonces()
        // Signed with another key, stale, unknown installation, or replayed: rejected, never a watch.
        let wrongKey = try ChannelEnvelope.seal(watch, installationID: id, secret: Data(repeating: 1, count: 32), now: now, nonce: "a")
        let stale = try ChannelEnvelope.seal(watch, installationID: id, secret: secret, now: now.addingTimeInterval(-121), nonce: "b")
        let good = try ChannelEnvelope.seal(watch, installationID: id, secret: secret, now: now, nonce: "c")
        let keys: (String) -> Data? = { $0 == id ? secret : nil }
        for envelope in [wrongKey, stale] {
            let received = ChannelHandler.receive(line: line(try envelope.encodedLine()), now: now, nonces: &nonces, secret: keys)
            #expect(received == .rejected)
            #expect(ChannelHandler.watchRequested(received) == nil)
        }
        let unknown = ChannelHandler.receive(line: line(try good.encodedLine()), now: now, nonces: &nonces) { _ in nil }
        #expect(ChannelHandler.watchRequested(unknown) == nil)
        let accepted = ChannelHandler.receive(line: line(try good.encodedLine()), now: now, nonces: &nonces, secret: keys)
        #expect(ChannelHandler.watchRequested(accepted) == id)
        let replayed = ChannelHandler.receive(line: line(try good.encodedLine()), now: now, nonces: &nonces, secret: keys)
        #expect(ChannelHandler.watchRequested(replayed) == nil)
        // Other authenticated requests aren't watches either.
        let checkIn = try ChannelEnvelope.seal(.checkIn(settings: settings, lastRefresh: nil, appVersion: nil),
                                               installationID: id, secret: secret, now: now, nonce: "d")
        #expect(ChannelHandler.watchRequested(ChannelHandler.receive(line: line(try checkIn.encodedLine()), now: now,
                                                                     nonces: &nonces, secret: keys)) == nil)
        // The server's slots: a connection that hasn't sent its line can't become a watch.
        var admission = ChannelAdmission<Int>()
        #expect(admission.admit(1, remote: "peer", now: now) == .accept)
        #expect(admission.watch(1, installationID: id) == .refuse)
        #expect(admission.watching(1) == nil)
    }

    @Test func aSecondWatchReplacesTheFirst() throws {
        var admission = ChannelAdmission<Int>()
        for c in [1, 2] {
            _ = admission.admit(c, remote: "phone", now: now)
            admission.gotLine(c)
        }
        #expect(admission.watch(1, installationID: id) == .watch(replacing: nil))
        #expect(admission.watch(2, installationID: id) == .watch(replacing: 1))
        #expect(admission.watching(1) == nil && admission.watching(2) == id)
        // The hub: lines go to the new connection only.
        let first = Sink(), second = Sink()
        let hub = try openedWatch(first)
        let replaced = try hub.open(2, installationID: id, nonce: "w2", secret: secret,
                                    first: ChannelWatchState(settings: settings, lastRefresh: nil), now: now) { second.lines.append($0) }
        #expect(replaced == 1)
        #expect(hub.close(1) == nil) // the old connection's end doesn't close the new watch
        hub.update(id, to: ChannelWatchState(settings: settings.setting(\.reminder, to: false, at: now, by: .mac), lastRefresh: nil), now: now)
        #expect(first.lines.count == 1 && second.lines.count == 2)
        var reader = ChannelWatchReader(installationID: id, nonce: "w2", secret: secret)
        #expect(reader.open(line: line(second.lines[1]))?.watchSeq == 1)
        #expect(hub.close(2) == id && !hub.isWatched(id))
    }

    @Test func watchSlotsAreCappedPerAddressAndInAll() {
        var admission = ChannelAdmission<Int>()
        for c in 0..<3 {
            _ = admission.admit(c, remote: "phone", now: now)
            admission.gotLine(c)
        }
        #expect(admission.watch(0, installationID: "a|1") == .watch(replacing: nil))
        #expect(admission.watch(1, installationID: "b|1") == .watch(replacing: nil))
        #expect(admission.watch(2, installationID: "c|1") == .refuse) // 2 per address
        admission.ended(0)
        #expect(admission.watch(2, installationID: "c|1") == .watch(replacing: nil))
        var all = ChannelAdmission<Int>()
        for c in 0..<9 {
            _ = all.admit(c, remote: "p\(c / 2)", now: now)
            all.gotLine(c)
        }
        for c in 0..<8 { #expect(all.watch(c, installationID: "r\(c)|d") == .watch(replacing: nil)) }
        #expect(all.watch(8, installationID: "r8|d") == .refuse) // 8 in all
        // Replacing one's own watch is always possible at the cap.
        #expect(all.watch(8, installationID: "r7|d") == .watch(replacing: 7))
    }

    /// A change stored on the Mac reaches the open watch in the same turn: no timer, no poll.
    @Test func aMacChangeIsWrittenAtOnce() async throws {
        let tmp = TestTemp.root.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = AppLibrary(root: tmp)
        let src = tmp.appendingPathComponent("src.ipa")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("ipa".utf8).write(to: src)
        let rec = try await lib.importIPA(src, info: AppInfo(bundleID: "com.example.a", name: "A", version: "1", executable: "A"),
                                          teamID: "TEAM123456")
        try await lib.upsert(Installation(deviceID: "a", installedAt: now, expiresAt: now.addingTimeInterval(86_400),
                                          inApp: settings, channelSecret: secret), for: rec.id)
        let channelID = ChannelEnvelope.installationID(recordID: rec.id, deviceID: "a")
        // The watch's check-in is stored, its first line written.
        let (reply, update) = ChannelHandler.handle(.watch(settings: settings, lastRefresh: nil, appVersion: "1"),
                                                    installation: try #require(await lib.installation(channelID: channelID)).installation,
                                                    now: now, reminder: true)
        guard case let .merged(merged, checkIn, outcome) = update, case let .settings(first, last, _) = reply else {
            Issue.record("not a check-in"); return
        }
        _ = try await lib.applyCheckIn(merged, checkIn: checkIn, outcome: outcome, recordID: rec.id, deviceID: "a")
        let sink = Sink()
        let hub = ChannelWatches<Int>()
        try hub.open(1, installationID: channelID, nonce: "w1", secret: secret,
                     first: ChannelWatchState(settings: first, lastRefresh: last), now: now) { sink.lines.append($0) }
        // Nothing changed: nothing written.
        let storedNow = try #require(await lib.installation(channelID: channelID)).installation
        #expect(!hub.update(channelID, to: try #require(ChannelWatchState(storedNow)), now: now))
        // Mac edit, then a pause from the Mac: each written by the update that sees it.
        let edit = now.addingTimeInterval(2)
        try await lib.editInApp(recordID: rec.id, deviceID: "a", reminder: true, at: edit) {
            $0.setting(\.refreshCard, to: false, at: edit, by: .mac)
        }
        var stored = try #require(await lib.installation(channelID: channelID)).installation
        #expect(hub.update(channelID, to: try #require(ChannelWatchState(stored)), now: edit))
        #expect(sink.lines.count == 2) // written synchronously, before update returned
        try await lib.setRefreshPaused(true, recordID: rec.id, deviceID: "a", by: .mac, at: now.addingTimeInterval(3))
        stored = try #require(await lib.installation(channelID: channelID)).installation
        #expect(hub.update(channelID, to: try #require(ChannelWatchState(stored)), now: now.addingTimeInterval(3)))
        #expect(sink.lines.count == 3)
        // The phone opens them in order and sees each change, stamped by the Mac.
        var reader = ChannelWatchReader(installationID: channelID, nonce: "w1", secret: secret)
        guard case let .live(1, a, _, _)? = reader.open(line: line(sink.lines[1])),
              case let .live(2, b, _, _)? = reader.open(line: line(sink.lines[2])) else { Issue.record("lines refused"); return }
        #expect(a.refreshCard.value == false && a.refreshCard.changedBy == .mac)
        #expect(b.autoRefresh.value == false && b.autoRefresh.changedBy == .mac)
        #expect(ChannelHandler.fieldsChanged(for: first, by: a) == [.refreshCard])
    }

    @Test func keepAliveOnlyAfterSilence() throws {
        let sink = Sink()
        let hub = try openedWatch(sink)
        hub.keepAlive(now: now.addingTimeInterval(10))
        #expect(sink.lines.count == 1)
        hub.keepAlive(now: now.addingTimeInterval(25))
        #expect(sink.lines.count == 2)
        hub.update(id, to: ChannelWatchState(settings: settings.setting(\.reminder, to: false, at: now, by: .mac), lastRefresh: nil),
                   now: now.addingTimeInterval(40))
        hub.keepAlive(now: now.addingTimeInterval(50))
        #expect(sink.lines.count == 3)
        var reader = ChannelWatchReader(installationID: id, nonce: "w1", secret: secret)
        #expect(reader.open(line: line(sink.lines[1])) == .alive(seq: 1))
        #expect(reader.open(line: line(sink.lines[2]))?.watchSeq == 2)
    }

    /// While a watch is open, the Mac says the app is open: changes arrive live.
    @Test func anOpenWatchIsTheAppOpen() {
        let installation = Installation(deviceID: "dev", installedAt: now, expiresAt: now.addingTimeInterval(86_400),
                                        inApp: settings, channelSecret: secret, lastCheckIn: now.addingTimeInterval(-600))
        #expect(ReachabilityStatus.of(installation: installation, now: now, watching: true) == .openNow(lastSeen: now))
        #expect(ReachabilityStatus.of(installation: installation, now: now) == .joinable(lastSeen: now.addingTimeInterval(-600)))
    }
}

/// Review D–G minor 5: watches that ended before they were registered are remembered a minute,
/// each for itself: never a wholesale clear that could drop one still pending.
@Suite struct EndedWatchTokensTests {
    @Test func remembersEachForAMinute() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var ended = EndedWatchTokens<Int>()
        ended.insert(1, at: t0)
        for n in 2...200 { ended.insert(n, at: t0.addingTimeInterval(50)) } // many, never cleared at once
        let first = ended.take(1), second = ended.take(1)
        #expect(first) // still pending: taken once
        #expect(!second)
        ended.insert(300, at: t0.addingTimeInterval(120)) // the others are over a minute old now
        #expect(ended.count == 1)
        let last = ended.take(300)
        #expect(last)
    }
}
