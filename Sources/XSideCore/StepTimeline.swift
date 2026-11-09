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
    /// `duo`: adding iPhone Duo compatibility, listed only for a run that asked for it.
    /// `legacy32`: removing the old 32-bit code, listed only for an app that has some.
    /// `icloud`: adding the signed-out iCloud library, listed only for a run that asked for it.
    /// `tweaks`: injecting the device's enabled tweaks, listed only for a device that has some.
    case preparing, profile, welcome, legacy32, duo, icloud, tweaks, signing, installing, wifiCheck

    public init(_ step: InstallStep) {
        switch step {
        case .profile: self = .profile
        case .welcome: self = .welcome
        case .duo: self = .duo
        case .icloud: self = .icloud
        case .tweaks: self = .tweaks
        case .legacy32: self = .legacy32
        case .signing: self = .signing
        case .installing: self = .installing
        }
    }

    /// The list for a run; Wi-Fi verification only exists after a first install, the Duo step
    /// only when the option is on for the device, the iCloud one likewise, the tweak one only
    /// when the device has an enabled tweak.
    public static func list(includingWifiCheck: Bool, includingDuo: Bool = false,
                            includingLegacy32: Bool = false, includingICloud: Bool = false,
                            includingTweaks: Bool = false) -> [ProgressStep] {
        allCases.filter {
            ($0 != .wifiCheck || includingWifiCheck) && ($0 != .duo || includingDuo)
                && ($0 != .legacy32 || includingLegacy32) && ($0 != .icloud || includingICloud)
                && ($0 != .tweaks || includingTweaks)
        }
    }
}

public enum StepStatus: Equatable, Sendable {
    case done, active, waiting, failed, pending
    /// Passed over on purpose (e.g. the Wi-Fi check was skipped); counts as passed in the bar.
    case skipped
}

/// Per-step status of an ordered list, given the current step. Pure: no I/O, no localization.
public struct StepTimeline: Equatable, Sendable {
    public let steps: [ProgressStep]
    /// First step not done; nil when every step is done.
    public let current: ProgressStep?
    public let isFailed: Bool
    /// The current step hasn't started yet (queued): shown as "waiting" instead of "active".
    public let isWaiting: Bool
    public let skipped: Set<ProgressStep>

    /// `current` not in `steps` (a skipped optional step) resolves to the first later step, or to
    /// "everything done" when none is left.
    public init(steps: [ProgressStep], current: ProgressStep?, failed: Bool = false, waiting: Bool = false,
                skipped: Set<ProgressStep> = []) {
        self.steps = steps
        self.skipped = skipped
        self.current = current.flatMap { c in steps.first { $0.rawValue >= c.rawValue } }
        self.isFailed = failed && self.current != nil
        self.isWaiting = waiting && !self.isFailed && self.current != nil
    }

    /// Timeline for a job stage. `waiting` points at the first pipeline step, marked as waiting.
    /// `skipped`: steps passed over on purpose (the module step for an app installed without
    /// XSide's features).
    public init(steps: [ProgressStep], stage: JobStage?, failed: Bool = false, skipped: Set<ProgressStep> = []) {
        switch stage {
        case nil: self.init(steps: steps, current: nil, skipped: skipped)
        case .preparing?: self.init(steps: steps, current: .preparing, failed: failed, skipped: skipped)
        case .waiting?: self.init(steps: steps, current: .profile, failed: failed, waiting: true, skipped: skipped)
        case .step(let s)?: self.init(steps: steps, current: ProgressStep(s), failed: failed, skipped: skipped)
        }
    }

    public func status(of step: ProgressStep) -> StepStatus {
        if skipped.contains(step) && (current.map { step.rawValue < $0.rawValue } ?? true) { return .skipped }
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
