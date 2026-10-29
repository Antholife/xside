import Foundation

/// Where a running install or refresh is, as the app shows it. `preparing` (inspect + import) and
/// `waiting` (job queued behind the provisioning lock or another job on the same device, before the
/// pipeline reported anything) are derived by the app; `step` comes from the pipeline.
public enum JobStage: Equatable, Sendable {
    case preparing
    case waiting
    case step(InstallStep)
}

/// A step of the progress list shown to the user.
public enum ProgressStep: Int, CaseIterable, Sendable {
    case preparing, profile, signing, installing, wifiCheck

    public init(_ step: InstallStep) {
        switch step {
        case .profile: self = .profile
        case .signing: self = .signing
        case .installing: self = .installing
        }
    }

    /// The list for a run; Wi-Fi verification only exists after a first install.
    public static func list(includingWifiCheck: Bool) -> [ProgressStep] {
        includingWifiCheck ? allCases : allCases.filter { $0 != .wifiCheck }
    }
}

public enum StepStatus: Equatable, Sendable {
    case done, active, waiting, failed, pending
}

/// Per-step status of an ordered list, given the current step. Pure: no I/O, no localization.
public struct StepTimeline: Equatable, Sendable {
    public let steps: [ProgressStep]
    /// First step not done; nil when every step is done.
    public let current: ProgressStep?
    public let isFailed: Bool
    /// The current step hasn't started yet (queued): shown as "waiting" instead of "active".
    public let isWaiting: Bool

    /// `current` not in `steps` (a skipped optional step) resolves to the first later step, or to
    /// "everything done" when none is left.
    public init(steps: [ProgressStep], current: ProgressStep?, failed: Bool = false, waiting: Bool = false) {
        self.steps = steps
        self.current = current.flatMap { c in steps.first { $0.rawValue >= c.rawValue } }
        self.isFailed = failed && self.current != nil
        self.isWaiting = waiting && !self.isFailed && self.current != nil
    }

    /// Timeline for a job stage. `waiting` points at the first pipeline step, marked as waiting.
    public init(steps: [ProgressStep], stage: JobStage?, failed: Bool = false) {
        switch stage {
        case nil: self.init(steps: steps, current: nil)
        case .preparing?: self.init(steps: steps, current: .preparing, failed: failed)
        case .waiting?: self.init(steps: steps, current: .profile, failed: failed, waiting: true)
        case .step(let s)?: self.init(steps: steps, current: ProgressStep(s), failed: failed)
        }
    }

    public func status(of step: ProgressStep) -> StepStatus {
        guard let current else { return .done }
        if step.rawValue < current.rawValue { return .done }
        if step != current { return .pending }
        return isFailed ? .failed : (isWaiting ? .waiting : .active)
    }

    /// Steps fully done: what the overall bar shows (one segment per step, no fake percentage).
    public var completedCount: Int {
        guard let current else { return steps.count }
        return steps.firstIndex(of: current) ?? steps.count
    }

    public var total: Int { steps.count }

    /// 1-based position of the current step (the last one when all are done).
    public var position: Int { min(completedCount + 1, max(total, 1)) }
}
