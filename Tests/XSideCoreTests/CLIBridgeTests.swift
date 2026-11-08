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
                                           .uninstall(recordID: id, deviceIDs: ["d2"]), .report] {
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
