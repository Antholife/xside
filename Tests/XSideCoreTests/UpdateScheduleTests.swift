import XCTest
@testable import XSideCore

final class UpdateScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNeverCheckedIsDue() {
        XCTAssertTrue(UpdateSchedule.isDue(lastChecked: nil, now: now))
    }

    func testExactlyTheIntervalIsDue() {
        XCTAssertTrue(UpdateSchedule.isDue(lastChecked: now.addingTimeInterval(-UpdateSchedule.interval), now: now))
    }

    func testJustUnderTheIntervalIsNotDue() {
        XCTAssertFalse(UpdateSchedule.isDue(lastChecked: now.addingTimeInterval(-UpdateSchedule.interval + 1), now: now))
    }

    func testClockGoneBackIsDue() {
        XCTAssertTrue(UpdateSchedule.isDue(lastChecked: now.addingTimeInterval(60), now: now))
    }
}
