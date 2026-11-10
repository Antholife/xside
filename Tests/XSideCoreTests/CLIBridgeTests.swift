import Testing
import Foundation
@testable import XSideCore

struct CLIBridgeTests {
    @Test func pauseAndResumeTravel() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        for command: CLIBridge.Command in [.pause(seconds: 3600), .pause(seconds: nil), .resume, .refreshAll,
                                           // Mega review C5: found by the tool, like the others.
                                           .refreshApp(recordID: id, deviceIDs: ["d1", "d2"]),
                                           // Device feedback 3, E7: aimed at installations the tool found.
                                           .editSettings(recordID: id, deviceIDs: ["d1", "d2"], changes: [.reminder(false), .language(.automatic), .level(.all)]),
                                           .pauseApp(recordID: id, deviceIDs: ["d1"], seconds: 7200),
                                           .pauseApp(recordID: id, deviceIDs: ["d1"], seconds: nil),
                                           .resumeApp(recordID: id, deviceIDs: ["d1", "d2"]),
                                           .uninstall(recordID: id, deviceIDs: ["d2"]), .report,
                                           .crash(recordID: id, deviceIDs: ["d1"], json: false),
                                           .crash(recordID: id, deviceIDs: ["d1", "d2"], json: true)] {
            let request = CLIBridge.Request(id: "1", command: command)
            #expect(CLIBridge.Request(userInfo: request.userInfo) == request)
        }
    }

    /// `xside pause 2h`, `30m`, `1d`; nothing: until resumed.
    @Test func readsDurations() {
        #expect(CLIBridge.duration("2h") == 7200)
        #expect(CLIBridge.duration("30m") == 1800)
        #expect(CLIBridge.duration("1d") == 86_400)
        #expect(CLIBridge.duration("90") == 90 * 60) // minutes when no unit
        #expect(CLIBridge.duration("soon") == nil)
        #expect(CLIBridge.duration("0h") == nil)
        #expect(CLIBridge.duration("-1h") == nil)
        // Review 1.0.6 #3: never an overflow (a crash), and no pause past a year.
        #expect(CLIBridge.duration("999999999999999999m") == nil)
        #expect(CLIBridge.duration("400d") == nil)
        #expect(CLIBridge.duration("365d") == 365 * 86_400)
    }

    /// A request naming no installation, or an unreadable change, is no request.
    @Test func incompleteAppRequestsAreRefused() {
        #expect(CLIBridge.Request(userInfo: ["id": "1", "command": "pause-app", "record": "nope", "devices": "d1"]) == nil)
        #expect(CLIBridge.Request(userInfo: ["id": "1", "command": "uninstall", "record": "00000000-0000-0000-0000-000000000001", "devices": ""]) == nil)
        #expect(CLIBridge.Request(userInfo: ["id": "1", "command": "settings", "record": "00000000-0000-0000-0000-000000000001",
                                             "devices": "d1", "changes": "colour=red"]) == nil)
    }

    /// Mega review C5: the app's own loose matching of a name is gone; a refresh names installations.
    @Test func aRefreshByNameIsNoLongerARequest() {
        #expect(CLIBridge.Request(userInfo: ["id": "1", "command": "refresh", "app": "yt"]) == nil)
        #expect(CLIBridge.Request(userInfo: ["id": "1", "command": "refresh-app", "record": "nope", "devices": "d1"]) == nil)
    }

    /// Review 1.0.6 #4: an unreadable duration is no request, never "until resumed".
    @Test func unreadablePauseIsRefused() {
        #expect(CLIBridge.Request(userInfo: ["id": "1", "command": "pause", "seconds": "abc"]) == nil)
        #expect(CLIBridge.Request(userInfo: ["id": "1", "command": "pause"])?.command == .pause(seconds: nil))
    }

    /// Mega review C3: a pause longer than the tool can ask for (a hand-posted request) is refused,
    /// so no pause can end past the dates the channel carries.
    @Test func aPauseLongerThanTheLongestIsRefused() {
        let record = "00000000-0000-0000-0000-000000000001"
        for seconds in [String(CLIBridge.maxPause + 1), String(Int.max)] {
            #expect(CLIBridge.Request(userInfo: ["id": "1", "command": "pause", "seconds": seconds]) == nil)
            #expect(CLIBridge.Request(userInfo: ["id": "1", "command": "pause-app", "record": record, "devices": "d1",
                                                 "seconds": seconds]) == nil)
        }
        #expect(CLIBridge.Request(userInfo: ["id": "1", "command": "pause", "seconds": String(CLIBridge.maxPause)])?.command
                == .pause(seconds: CLIBridge.maxPause))
    }
}

/// Review D–G Important 1: a long `uninstall` or `report` is waited for as long as it takes.
struct CLIBridgeWaitTests {
    let start = Date(timeIntervalSince1970: 1_000_000)
    func working(_ id: String = "r") -> CLIBridge.Reply { CLIBridge.Reply(id: id, working: true, message: "Uninstalling…") }

    @Test func workingReplyTravels() {
        let reply = working()
        #expect(CLIBridge.Reply(userInfo: reply.userInfo) == reply)
        #expect(reply.working)
        let done = CLIBridge.Reply(id: "r", ok: true, message: "done")
        #expect(CLIBridge.Reply(userInfo: done.userInfo)?.working == false)
    }

    @Test func noAnswerAtAllGivesUpAfterTheFirstDeadline() {
        let wait = CLIBridge.Wait(start: start)
        #expect(wait.outcome(at: start.addingTimeInterval(29)) == .waiting)
        #expect(wait.outcome(at: start.addingTimeInterval(31)) == .noAnswer)
    }

    @Test func aFinalReplyEndsTheWait() {
        var wait = CLIBridge.Wait(start: start)
        let done = CLIBridge.Reply(id: "r", ok: false, message: "busy")
        wait.received(done, at: start.addingTimeInterval(2))
        #expect(wait.outcome(at: start.addingTimeInterval(2)) == .finished(done))
    }

    /// Acknowledged and still answering "working": no deadline as long as XSide keeps answering.
    @Test func workingKeepsTheToolWaitingPastThirtySeconds() {
        var wait = CLIBridge.Wait(start: start)
        for second in stride(from: 1, through: 600, by: 2) {
            wait.received(working(), at: start.addingTimeInterval(TimeInterval(second)))
            #expect(wait.outcome(at: start.addingTimeInterval(TimeInterval(second) + 1)) == .waiting)
        }
        #expect(wait.acknowledged)
        let done = CLIBridge.Reply(id: "r", ok: true, message: "Uninstalled")
        wait.received(done, at: start.addingTimeInterval(601))
        #expect(wait.outcome(at: start.addingTimeInterval(601)) == .finished(done))
    }

    /// Acknowledged, then silence (XSide quit or hung): the outcome is unknown, never "failed".
    @Test func silenceAfterTheAcknowledgementIsUnknown() {
        var wait = CLIBridge.Wait(start: start)
        wait.received(working(), at: start.addingTimeInterval(1))
        #expect(wait.outcome(at: start.addingTimeInterval(30)) == .waiting)
        #expect(wait.outcome(at: start.addingTimeInterval(32)) == .stoppedAnswering)
    }

    /// Past the longest wait, the tool stops waiting and says XSide is still at it.
    @Test func theLongestWaitSaysStillWorking() {
        var wait = CLIBridge.Wait(start: start)
        let end = CLIBridge.Wait.longest
        wait.received(working(), at: start.addingTimeInterval(end - 1))
        #expect(wait.outcome(at: start.addingTimeInterval(end + 1)) == .stillWorking)
    }

    /// An empty or foreign reply never counts.
    @Test func otherRepliesAreIgnored() {
        var wait = CLIBridge.Wait(start: start)
        wait.received(CLIBridge.Reply(id: "other", ok: true, message: "x"), at: start.addingTimeInterval(1), requestID: "r")
        #expect(!wait.acknowledged)
        #expect(wait.outcome(at: start.addingTimeInterval(31)) == .noAnswer)
    }

    /// Exit codes: 0 done, 1 failed or never answered, 2 outcome unknown (still working).
    @Test func exitCodesAreTruthful() {
        #expect(CLIBridge.Wait.Outcome.finished(.init(id: "r", ok: true, message: "")).exitCode == 0)
        #expect(CLIBridge.Wait.Outcome.finished(.init(id: "r", ok: false, message: "")).exitCode == 1)
        #expect(CLIBridge.Wait.Outcome.noAnswer.exitCode == 1)
        #expect(CLIBridge.Wait.Outcome.stoppedAnswering.exitCode == 2)
        #expect(CLIBridge.Wait.Outcome.stillWorking.exitCode == 2)
    }
}

/// Review D–G minor 9: requests carry a key XSide writes at each launch to a file only the user
/// can read; a request without it, or with another, is no request.
struct CLIBridgeKeyTests {
    @Test func keyFileIsPrivateAndNewAtEachLaunch() throws {
        let folder = TestTemp.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try CLIBridge.Key.create(in: folder)
        #expect(first.count == 64)
        #expect(CLIBridge.Key.read(in: folder) == first)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(CLIBridge.Key.fileName).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let second = try CLIBridge.Key.create(in: folder)
        #expect(second != first)
        #expect(CLIBridge.Key.read(in: folder) == second)
        #expect(CLIBridge.Key.read(in: folder.appendingPathComponent("none")) == nil)
    }

    @Test func requestsWithoutTheKeyAreRefused() {
        let request = CLIBridge.Request(id: "1", command: .report, key: "k1")
        #expect(CLIBridge.Request(userInfo: request.userInfo, requiringKey: "k1") == request)
        #expect(CLIBridge.Request(userInfo: request.userInfo, requiringKey: "k2") == nil)
        #expect(CLIBridge.Request(userInfo: CLIBridge.Request(id: "1", command: .report).userInfo, requiringKey: "k1") == nil)
    }
}

/// Mega review C6: a crash diagnosis or the report's path doesn't go out as a distributed
/// notification (any program of the session hears those): it is written to a file only the user
/// can read, named after the request, and the notification says to read it.
struct CLIBridgeReplyFileTests {
    func folder() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xside-replyfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test func aReplyInAFileIsReadOnlyByTheUserAndReadOnce() throws {
        let tmp = try folder(); defer { try? FileManager.default.removeItem(at: tmp) }
        let id = UUID().uuidString
        let reply = CLIBridge.Reply(id: id, ok: true, message: "the app crashed in libFoo")
        let notified = try CLIBridge.ReplyFile.write(reply, in: tmp, now: Date())
        #expect(notified.inFile && notified.message == CLIBridge.ReplyFile.notice && notified.ok)
        #expect(CLIBridge.Reply(userInfo: notified.userInfo) == notified) // travels with its flag
        let file = CLIBridge.ReplyFile.url(id: id, in: tmp)!
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let folderMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
        #expect(CLIBridge.ReplyFile.take(notified, in: tmp) == reply)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // A reply not in a file is left as it is.
        let plain = CLIBridge.Reply(id: id, ok: false, message: "busy")
        #expect(CLIBridge.ReplyFile.take(plain, in: tmp) == plain)
    }

    @Test func onlyCrashAndReportGoToAFile() {
        let id = UUID()
        #expect(CLIBridge.ReplyFile.isFor(.crash(recordID: id, deviceIDs: ["d"], json: true)))
        #expect(CLIBridge.ReplyFile.isFor(.report))
        #expect(!CLIBridge.ReplyFile.isFor(.refreshAll))
        #expect(!CLIBridge.ReplyFile.isFor(.uninstall(recordID: id, deviceIDs: ["d"])))
    }

    /// A request id is only ever a UUID: never a path out of the folder.
    @Test func aRequestIDThatIsntAUUIDHasNoFile() throws {
        let tmp = try folder(); defer { try? FileManager.default.removeItem(at: tmp) }
        for id in ["../cli-key", "a/b", "", "x"] {
            #expect(CLIBridge.ReplyFile.url(id: id, in: tmp) == nil)
            #expect(throws: (any Error).self) {
                try CLIBridge.ReplyFile.write(CLIBridge.Reply(id: id, ok: true, message: "m"), in: tmp, now: Date())
            }
        }
    }

    /// Files nobody read (the tool was stopped) go after a while.
    @Test func unreadFilesAreRemovedLater() throws {
        let tmp = try folder(); defer { try? FileManager.default.removeItem(at: tmp) }
        let now = Date()
        let old = UUID().uuidString
        _ = try CLIBridge.ReplyFile.write(CLIBridge.Reply(id: old, ok: true, message: "m"), in: tmp, now: now)
        let oldFile = CLIBridge.ReplyFile.url(id: old, in: tmp)!
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-CLIBridge.ReplyFile.lifetime - 1)],
                                              ofItemAtPath: oldFile.path)
        _ = try CLIBridge.ReplyFile.write(CLIBridge.Reply(id: UUID().uuidString, ok: true, message: "m"), in: tmp, now: now)
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
    }
}

/// Mega review C7: the tool's request is handled once even as it re-sends it, and the app
/// remembers only so much.
struct CLIBridgeReplyCacheTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func reply(_ id: String, working: Bool = false) -> CLIBridge.Reply {
        working ? CLIBridge.Reply(id: id, working: true, message: "…") : CLIBridge.Reply(id: id, ok: true, message: "done")
    }

    @Test func aRequestIsAnsweredFromTheCacheAndKeptWhileAsked() {
        var cache = CLIBridge.ReplyCache()
        #expect(cache.reply(for: "a", at: now) == nil)
        cache.store(reply("a"), at: now)
        // Asked again every second: kept past the lifetime as long as it is asked.
        var t = now
        for _ in 0..<(Int(CLIBridge.ReplyCache.lifetime) + 60) {
            t = t.addingTimeInterval(1)
            #expect(cache.reply(for: "a", at: t) == reply("a"))
        }
        // No longer asked: gone after the lifetime.
        #expect(cache.reply(for: "a", at: t.addingTimeInterval(CLIBridge.ReplyCache.lifetime + 1)) == nil)
    }

    @Test func atMostThirtyTwoFinishedRepliesAreKept() {
        var cache = CLIBridge.ReplyCache()
        cache.store(reply("busy", working: true), at: now)
        for n in 0..<40 { cache.store(reply("r\(n)"), at: now.addingTimeInterval(TimeInterval(n))) }
        #expect(cache.count <= CLIBridge.ReplyCache.capacity + 1)
        #expect(cache.reply(for: "r0", at: now.addingTimeInterval(41)) == nil) // the oldest went
        #expect(cache.reply(for: "r39", at: now.addingTimeInterval(41)) != nil)
        // One still being worked on is never dropped for room (it would run again).
        #expect(cache.reply(for: "busy", at: now.addingTimeInterval(41))?.working == true)
    }
}

/// Mega review C7: XSide restarted after it took the request: the tool says the outcome is
/// unknown instead of sending it to the new XSide, which would do it again.
struct CLIBridgeRestartTests {
    let start = Date(timeIntervalSince1970: 1_000_000)
    func send(_ wait: inout CLIBridge.Wait, _ key: String?) -> Bool { wait.sending(key: key) }

    @Test func aNewKeyAfterTheAcknowledgementStopsTheWait() {
        var wait = CLIBridge.Wait(start: start)
        #expect(send(&wait, "k1"))
        wait.received(CLIBridge.Reply(id: "r", working: true, message: "…"), at: start.addingTimeInterval(1))
        #expect(send(&wait, "k1"))
        #expect(!send(&wait, "k2"))
        #expect(wait.outcome(at: start.addingTimeInterval(2)) == .restarted)
        #expect(CLIBridge.Wait.Outcome.restarted.exitCode == 2)
        #expect(CLIJSONOutput.message(for: .restarted)?.contains("restarted") == true)
    }

    /// Before XSide answered, a new key is only XSide starting: the request goes to it.
    @Test func aNewKeyBeforeAnyAnswerIsFine() {
        var wait = CLIBridge.Wait(start: start)
        #expect(send(&wait, nil))
        #expect(send(&wait, "k1"))
        #expect(send(&wait, "k2"))
        wait.received(CLIBridge.Reply(id: "r", working: true, message: "…"), at: start.addingTimeInterval(1))
        #expect(send(&wait, nil)) // unreadable for a moment: not a restart
        #expect(wait.outcome(at: start.addingTimeInterval(2)) == .waiting)
    }
}
