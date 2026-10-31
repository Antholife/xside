import Foundation
import Testing
@testable import XSideCore

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ v: Double) { lock.withLock { values.append(v) } }
    var all: [Double] { lock.withLock { values } }
}

struct StepProgressTests {
    @Test func readsTheLastPercentage() {
        #expect(StepProgress.lastPercent(in: "Installing app… 12%\rInstalling app… 42 %") == 0.42)
        #expect(StepProgress.lastPercent(in: "Progress 99.5%") == 0.995)
        #expect(StepProgress.lastPercent(in: "no number here") == nil)
        #expect(StepProgress.lastPercent(in: "250%") == nil)
    }

    @Test func mapsAPartIntoItsRange() async {
        let box = Box()
        await StepProgress.$report.withValue({ box.add($0) }) {
            await StepProgress.within(0.5...1) {
                StepProgress.report?(0)
                StepProgress.report?(0.5)
                StepProgress.report?(2) // clamped
            }
        }
        #expect(box.all == [0.5, 0.75, 1])
    }

    @Test func nothingIsReportedWithoutAListener() async {
        await StepProgress.within(0...0.5) { StepProgress.report?(0.3) } // no crash, no effect
        #expect(StepProgress.report == nil)
    }
}
