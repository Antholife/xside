import Testing
import Foundation
@testable import XSideCore

struct CLIBridgeTests {
    @Test func pauseAndResumeTravel() {
        for command: CLIBridge.Command in [.pause(seconds: 3600), .pause(seconds: nil), .resume, .refreshAll,
                                           .refresh(app: "yt", device: "Duo")] {
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
    }
}
