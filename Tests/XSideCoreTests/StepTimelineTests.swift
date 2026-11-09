import Testing
@testable import XSideCore

@Suite struct StepTimelineTests {
    let run = ProgressStep.list(includingWifiCheck: false)
    let firstRun = ProgressStep.list(includingWifiCheck: true)

    @Test func listsDependOnWifiCheck() {
        #expect(run == [.preparing, .profile, .welcome, .signing, .installing])
        #expect(firstRun.last == .wifiCheck)
    }

    /// Its own step when the Duo option is on: done once passed, skipped (with its reason in the
    /// app) when it couldn't be added.
    @Test func theDuoStepIsListedOnlyWhenAskedFor() {
        let duoRun = ProgressStep.list(includingWifiCheck: false, includingDuo: true)
        #expect(duoRun == [.preparing, .profile, .welcome, .duo, .signing, .installing])
        let t = StepTimeline(steps: duoRun, stage: .step(.duo))
        #expect(t.status(of: .welcome) == .done)
        #expect(t.status(of: .duo) == .active)
        #expect(t.status(of: .signing) == .pending)
        let skipped = StepTimeline(steps: duoRun, stage: .step(.signing), skipped: [.duo])
        #expect(skipped.status(of: .duo) == .skipped)
        #expect(StepTimeline(steps: duoRun, stage: .step(.signing)).status(of: .duo) == .done)
        // Not listed: a .duo stage resolves to the step after it.
        #expect(StepTimeline(steps: run, stage: .step(.duo)).status(of: .signing) == .active)
    }

    /// Listed only for a run on a device with an enabled tweak: after iCloud, before the signature.
    @Test func tweakStepOnlyWhenAsked() {
        #expect(!run.contains(.tweaks))
        let all = ProgressStep.list(includingWifiCheck: false, includingICloud: true, includingTweaks: true)
        #expect(all == [.preparing, .profile, .welcome, .icloud, .tweaks, .signing, .installing])
        #expect(ProgressStep(InstallStep.tweaks) == .tweaks)
        let t = StepTimeline(steps: all, stage: .step(.tweaks))
        #expect(t.status(of: .icloud) == .done && t.status(of: .tweaks) == .active && t.status(of: .signing) == .pending)
        // Not listed: a .tweaks stage resolves to the signature.
        #expect(StepTimeline(steps: run, stage: .step(.tweaks)).status(of: .signing) == .active)
    }

    @Test func midRunStatuses() {
        let t = StepTimeline(steps: firstRun, stage: .step(.signing))
        #expect(t.status(of: .preparing) == .done)
        #expect(t.status(of: .profile) == .done)
        #expect(t.status(of: .welcome) == .done)
        #expect(t.status(of: .signing) == .active)
        #expect(t.status(of: .installing) == .pending)
        #expect(t.status(of: .wifiCheck) == .pending)
        #expect(t.completedCount == 3)
        #expect(t.position == 4)
        #expect(t.total == 6)
    }

    @Test func waitingMarksTheUpcomingProfileStep() {
        let t = StepTimeline(steps: run, stage: .waiting)
        #expect(t.status(of: .preparing) == .done)
        #expect(t.status(of: .profile) == .waiting)
        #expect(t.completedCount == 1)
    }

    @Test func preparingIsFirst() {
        let t = StepTimeline(steps: run, stage: .preparing)
        #expect(t.status(of: .preparing) == .active)
        #expect(t.completedCount == 0)
    }

    @Test func failureMarksOnlyTheCurrentStep() {
        let t = StepTimeline(steps: run, stage: .step(.installing), failed: true)
        #expect(t.status(of: .signing) == .done)
        #expect(t.status(of: .installing) == .failed)
        #expect(t.completedCount == 4)
        // A failure while waiting is a failure of the step, not a wait.
        let w = StepTimeline(steps: run, stage: .waiting, failed: true)
        #expect(w.status(of: .profile) == .failed)
    }

    @Test func nilStageMeansAllDone() {
        let t = StepTimeline(steps: run, stage: nil, failed: true)
        #expect(run.allSatisfy { t.status(of: $0) == .done })
        #expect(t.completedCount == 5)
        #expect(t.position == 5)
        #expect(!t.isFailed)
    }

    @Test func wifiCheckIsTheLastActiveStepAfterInstall() {
        let t = StepTimeline(steps: firstRun, current: .wifiCheck)
        #expect(t.status(of: .installing) == .done)
        #expect(t.status(of: .wifiCheck) == .active)
        #expect(t.completedCount == 5)
    }

    @Test func skippedStepKeepsTheTotalAndCountsAsPassed() {
        let t = StepTimeline(steps: firstRun, current: nil, skipped: [.wifiCheck])
        #expect(t.status(of: .wifiCheck) == .skipped)
        #expect(t.status(of: .installing) == .done)
        #expect(t.total == 6)
        #expect(t.completedCount == 6)
    }

    /// Device feedback round 2, M4: an app installed without XSide's features shows the module
    /// step as skipped once passed (it was a green tick), during the run and on failure too.
    @Test func moduleStepSkippedWithoutFeatures() {
        let running = StepTimeline(steps: firstRun, stage: .step(.signing), skipped: [.welcome])
        #expect(running.status(of: .welcome) == .skipped)
        #expect(running.status(of: .profile) == .done && running.status(of: .signing) == .active)
        #expect(running.completedCount == 3)
        let atIt = StepTimeline(steps: firstRun, stage: .step(.welcome), skipped: [.welcome])
        #expect(atIt.status(of: .welcome) == .active)
        let failed = StepTimeline(steps: firstRun, stage: .step(.installing), failed: true, skipped: [.welcome])
        #expect(failed.status(of: .welcome) == .skipped && failed.status(of: .installing) == .failed)
        #expect(StepTimeline(steps: firstRun, stage: nil, skipped: [.welcome]).status(of: .welcome) == .skipped)
    }

    @Test func missingCurrentStepSkipsForward() {
        let t = StepTimeline(steps: run, current: .wifiCheck)
        #expect(t.current == nil)
        #expect(t.completedCount == 5)
    }
}
