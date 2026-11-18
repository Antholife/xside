import Testing
import Foundation
@testable import XSideCore

struct UpdateFrequencyTests {
    @Test func standardIntervalsRoundTrip() {
        for f in UpdateFrequency.choices {
            // Each standard choice maps to an interval and back to itself.
            #expect(UpdateFrequency.from(f.checkInterval(current: nil)) == f)
        }
        #expect(UpdateFrequency.from(nil) == .global)
        #expect(UpdateFrequency.from(0) == .never)
        #expect(UpdateFrequency.from(UpdateSchedule.atRefresh) == .atRefresh)
        #expect(UpdateFrequency.from(86_400) == .daily)
    }

    @Test func anUnlistedIntervalIsCustomAndIsKept() {
        // 90 minutes is not one of the phone's presets.
        #expect(UpdateFrequency.from(5_400) == .custom)
        // custom keeps whatever the Mac set, so a phone that never named it never changes it.
        #expect(UpdateFrequency.custom.checkInterval(current: 5_400) == 5_400)
        #expect(UpdateFrequency.custom.checkInterval(current: nil) == nil)
    }
}
