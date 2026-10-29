import Testing
@testable import XSideCore

@Suite struct StepTimelineTests {
    let four = ProgressStep.list(includingWifiCheck: false)
    let five = ProgressStep.list(includingWifiCheck: true)

    @Test func listsDependOnWifiCheck() {
        #expect(four == [.preparing, .profile, .signing, .installing])
        #expect(five.last == .wifiCheck)
    }

    @Test func midRunStatuses() {
        let t = StepTimeline(steps: five, stage: .step(.signing))
        #expect(t.status(of: .preparing) == .done)
        #expect(t.status(of: .profile) == .done)
        #expect(t.status(of: .signing) == .active)
        #expect(t.status(of: .installing) == .pending)
        #expect(t.status(of: .wifiCheck) == .pending)
        #expect(t.completedCount == 2)
        #expect(t.position == 3)
        #expect(t.total == 5)
    }

    @Test func waitingMarksTheUpcomingProfileStep() {
        let t = StepTimeline(steps: four, stage: .waiting)
        #expect(t.status(of: .preparing) == .done)
        #expect(t.status(of: .profile) == .waiting)
        #expect(t.completedCount == 1)
    }

    @Test func preparingIsFirst() {
        let t = StepTimeline(steps: four, stage: .preparing)
        #expect(t.status(of: .preparing) == .active)
        #expect(t.completedCount == 0)
    }

    @Test func failureMarksOnlyTheCurrentStep() {
        let t = StepTimeline(steps: four, stage: .step(.installing), failed: true)
        #expect(t.status(of: .signing) == .done)
        #expect(t.status(of: .installing) == .failed)
        #expect(t.completedCount == 3)
        // A failure while waiting is a failure of the step, not a wait.
        let w = StepTimeline(steps: four, stage: .waiting, failed: true)
        #expect(w.status(of: .profile) == .failed)
    }

    @Test func nilStageMeansAllDone() {
        let t = StepTimeline(steps: four, stage: nil, failed: true)
        #expect(four.allSatisfy { t.status(of: $0) == .done })
        #expect(t.completedCount == 4)
        #expect(t.position == 4)
        #expect(!t.isFailed)
    }

    @Test func wifiCheckIsTheLastActiveStepAfterInstall() {
        let t = StepTimeline(steps: five, current: .wifiCheck)
        #expect(t.status(of: .installing) == .done)
        #expect(t.status(of: .wifiCheck) == .active)
        #expect(t.completedCount == 4)
    }

    @Test func skippedStepKeepsTheTotalAndCountsAsPassed() {
        let t = StepTimeline(steps: five, current: nil, skipped: [.wifiCheck])
        #expect(t.status(of: .wifiCheck) == .skipped)
        #expect(t.status(of: .installing) == .done)
        #expect(t.total == 5)
        #expect(t.completedCount == 5)
    }

    @Test func missingCurrentStepSkipsForward() {
        let t = StepTimeline(steps: four, current: .wifiCheck)
        #expect(t.current == nil)
        #expect(t.completedCount == 4)
    }
}
