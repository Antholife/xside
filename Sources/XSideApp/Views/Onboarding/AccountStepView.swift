import SwiftUI
import XSideCore

/// Step 3 (blocking): an Apple account signed in to Xcode. Turns ✅ by itself through the model's
/// poller once the user has signed in.
struct AccountStepView: View {
    let model: AppModel
    /// "Open Xcode" was clicked: Xcode shows its welcome window, so say where to go next.
    @State private var xcodeOpened = false

    var body: some View {
        JourneyPage(symbol: "person.badge.key.fill", title: L("journey.account.title"),
                    subtitle: L("journey.account.subtitle")) {
            VStack(spacing: 14) {
                let blocking = model.firstBlockingStep
                if model.environment == nil {
                    StatusCard(status: .checking, title: L("journey.account.checking"))
                } else if blocking == .xcode {
                    StatusCard(status: .todo, title: L("onboarding.xcodeMissing.title"),
                               detail: L("journey.account.needsXcode"))
                } else if let error = model.environmentError, error.isSetupCheckFailure {
                    StatusCard(status: .todo, title: error.setupTitle, detail: error.environmentReason)
                    AutoDetectFooter(model: model)
                } else if blocking == .account {
                    StatusCard(status: .todo, title: L("onboarding.signIn.title")) {
                        OpenXcodeButton(model: model) { xcodeOpened = true }
                    }
                    SigningSteps(problem: .account, xcodeOpened: xcodeOpened)
                        .padding(.horizontal, 16)
                    AutoDetectFooter(model: model)
                } else {
                    StatusCard(status: .done, title: model.accountName.map { L("journey.account.done.name", $0) }
                                                    ?? L("journey.account.done"))
                }
            }
        }
    }
}
