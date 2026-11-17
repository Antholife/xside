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

    func testEffectiveInterval_nilIsGlobalDefault() {
        XCTAssertEqual(UpdateSchedule.effectiveInterval(nil, default: 86_400), 86_400)
    }

    func testEffectiveInterval_zeroOrNegativeIsNever() {
        XCTAssertEqual(UpdateSchedule.effectiveInterval(0, default: 86_400), 0)
        XCTAssertEqual(UpdateSchedule.effectiveInterval(-5, default: 86_400), 0)
    }

    func testEffectiveInterval_nilFollowsGlobalNever() {
        // Global default « never »: an app with no override also never checks.
        XCTAssertEqual(UpdateSchedule.effectiveInterval(nil, default: 0), 0)
    }

    func testEffectiveInterval_clampsToTheFloor() {
        XCTAssertEqual(UpdateSchedule.effectiveInterval(60, default: 86_400), UpdateSchedule.minimumInterval)
        XCTAssertEqual(UpdateSchedule.effectiveInterval(nil, default: 60), UpdateSchedule.minimumInterval)
        XCTAssertEqual(UpdateSchedule.effectiveInterval(7_200, default: 86_400), 7_200)
    }

    func testPerSourceNeverIsNotDue() {
        XCTAssertFalse(UpdateSchedule.isDue(lastChecked: nil, interval: 0, now: now))
        XCTAssertFalse(UpdateSchedule.isDue(lastChecked: now.addingTimeInterval(-1_000_000), interval: 0, now: now))
    }

    func testPerSourceCustomInterval() {
        let hour: TimeInterval = 3_600
        XCTAssertTrue(UpdateSchedule.isDue(lastChecked: now.addingTimeInterval(-hour), interval: hour, now: now))
        XCTAssertFalse(UpdateSchedule.isDue(lastChecked: now.addingTimeInterval(-hour + 1), interval: hour, now: now))
        XCTAssertTrue(UpdateSchedule.isDue(lastChecked: nil, interval: hour, now: now))
    }
}

extension UpdateScheduleTests {
    private var t0: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    func testFailureBacksOffForAMoment() {
        // Total failure just now (never succeeded): not due a few minutes later.
        XCTAssertFalse(UpdateSchedule.isDue(lastChecked: nil, lastFailure: t0, now: t0.addingTimeInterval(300)))
    }

    func testFailureIsRetriedAfterTheFailureInterval() {
        XCTAssertTrue(UpdateSchedule.isDue(lastChecked: nil, lastFailure: t0, now: t0.addingTimeInterval(UpdateSchedule.failureInterval)))
        XCTAssertLessThan(UpdateSchedule.failureInterval, UpdateSchedule.interval)
    }

    func testFailureDoesNotShortenTheSuccessCadence() {
        // Checked 2h ago: the success cadence still holds, whatever the failure interval.
        let checked = t0.addingTimeInterval(-7_200)
        XCTAssertFalse(UpdateSchedule.isDue(lastChecked: checked, lastFailure: checked, now: t0))
        XCTAssertFalse(UpdateSchedule.isDue(lastChecked: t0, lastFailure: nil, now: t0.addingTimeInterval(UpdateSchedule.interval - 1)))
        XCTAssertTrue(UpdateSchedule.isDue(lastChecked: t0, lastFailure: nil, now: t0.addingTimeInterval(UpdateSchedule.interval)))
    }

    func testFailureClockGoneBackIsDue() {
        XCTAssertTrue(UpdateSchedule.isDue(lastChecked: nil, lastFailure: t0.addingTimeInterval(60), now: t0))
    }
}
