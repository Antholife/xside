import AppKit
import SwiftUI
import XSideCore

enum WelcomeWindow {
    static let id = "welcome"
}

/// The steps of the first-launch journey, in order: the concepts first, then the checks.
enum JourneyStep: Int, CaseIterable, Comparable {
    case welcome, howItWorks, goodToKnow, xcode, account, notifications, launchAtLogin, device, ready

    /// `@AppStorage` key: true once "Finish" was pressed.
    static let completedKey = "onboardingCompleted"
    static let savedStepKey = "onboardingStep"

    /// The environment must be OK before going further: no "Skip", "Continue" waits for it.
    var isBlocking: Bool { self == .xcode || self == .account }

    /// The concept explainers: "Skip" jumps straight to the checks.
    var isExplainer: Bool { self == .howItWorks || self == .goodToKnow }

    var next: JourneyStep? { JourneyStep(rawValue: rawValue + 1) }
    var previous: JourneyStep? { JourneyStep(rawValue: rawValue - 1) }

    static func < (a: JourneyStep, b: JourneyStep) -> Bool { a.rawValue < b.rawValue }
}

extension XSideError {
    /// Short title of an environment failure ("Xcode missing", "Apple account not signed in"…).
    var setupTitle: String {
        switch self {
        case .xcodeMissing: L("onboarding.xcodeMissing.title")
        case .noSigningIdentity: L("onboarding.noIdentity.title")
        default: L("onboarding.signIn.title")
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
