import AppKit
import SwiftUI
import XSideCore

enum WelcomeWindow {
    static let id = "welcome"
}

/// The steps of the first-launch journey, in order: the concepts first, then the checks.
enum JourneyStep: Int, CaseIterable, Comparable {
    case language, welcome, howItWorks, goodToKnow, xcode, account, certificate, notifications, launchAtLogin, device, ready

    /// `@AppStorage` key: true once "Finish" was pressed.
    static let completedKey = "onboardingCompleted"
    /// Saved step, by stable name (the order of the cases may change).
    static let savedStepKey = "onboardingStepID"
    /// Legacy key: the index in the order before `language` was added.
    private static let legacyStepKey = "onboardingStep"
    private static let legacyOrder: [JourneyStep] = [
        .welcome, .howItWorks, .goodToKnow, .xcode, .account, .notifications, .launchAtLogin, .device, .ready]

    var id: String { String(describing: self) }

    /// The saved step; falls back to the legacy index, then to the first step.
    static func saved(in defaults: UserDefaults = .standard) -> JourneyStep {
        if let id = defaults.string(forKey: savedStepKey), let step = allCases.first(where: { $0.id == id }) {
            return step
        }
        let old = defaults.integer(forKey: legacyStepKey)
        return legacyOrder.indices.contains(old) && defaults.object(forKey: legacyStepKey) != nil
            ? legacyOrder[old] : .language
    }

    /// The environment must be OK before going further: no "Skip", "Continue" waits for it.
    var isBlocking: Bool { self == .xcode || self == .account || self == .certificate }

    /// The concept explainers: "Skip" jumps straight to the checks.
    var isExplainer: Bool { self == .howItWorks || self == .goodToKnow }

    var next: JourneyStep? { JourneyStep(rawValue: rawValue + 1) }
    var previous: JourneyStep? { JourneyStep(rawValue: rawValue - 1) }

    static func < (a: JourneyStep, b: JourneyStep) -> Bool { a.rawValue < b.rawValue }
}

extension XSideError {
    /// Why an environment problem stops refreshes (popover banner, notification).
    var environmentReason: String {
        switch self {
        case .xcodeMissing: L("environment.reason.xcode")
        case .noSigningIdentity: L("environment.reason.certificate")
        case .xcodeNotSignedIn: L("environment.reason.account")
        default: L("environment.reason.checkFailed")
        }
    }

    /// Short title of an environment failure ("Xcode missing", "Apple account not signed in"…).
    var setupTitle: String {
        switch self {
        case .xcodeMissing: L("onboarding.xcodeMissing.title")
        case .noSigningIdentity: L("onboarding.noIdentity.title")
        case .xcodeNotSignedIn: L("onboarding.signIn.title")
        default: L("onboarding.checkFailed.title")
        }
    }

    /// The probe itself failed (a tool like `security` errored): nothing is known to be missing.
    var isSetupCheckFailure: Bool {
        switch self {
        case .xcodeMissing, .noSigningIdentity, .xcodeNotSignedIn: false
        default: true
        }
    }
}

extension OpenWindowAction {
    /// Shows the welcome window, at `step` or where the journey should resume.
    @MainActor func presentJourney(_ model: AppModel, at step: JourneyStep? = nil) {
        if let step { model.journeyStep = step } else { model.prepareJourney() }
        self(id: WelcomeWindow.id)
        NSApp.activate()
    }
}
