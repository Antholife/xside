import Testing
import Foundation
@testable import XSideCore

struct CLIBridgeTests {
    @Test func pauseAndResumeTravel() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        for command: CLIBridge.Command in [.pause(seconds: 3600), .pause(seconds: nil), .resume, .refreshAll,
                                           .refresh(app: "yt", device: "Duo"),
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

    /// Review 1.0.6 #4: an unreadable duration is no request, never "until resumed".
    @Test func unreadablePauseIsRefused() {
        #expect(CLIBridge.Request(userInfo: ["id": "1", "command": "pause", "seconds": "abc"]) == nil)
        #expect(CLIBridge.Request(userInfo: ["id": "1", "command": "pause"])?.command == .pause(seconds: nil))
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
