import SwiftUI
import XSideCore

/// Step 3 (blocking): an Apple account signed in to Xcode, with a signing certificate. Turns ✅
/// by itself through the model's poller once the user has signed in.
struct AccountStepView: View {
    let model: AppModel

    var body: some View {
        JourneyPage(symbol: "person.badge.key.fill", title: L("journey.account.title"),
                    subtitle: L("journey.account.subtitle")) {
            VStack(spacing: 14) {
                switch model.environment {
                case nil:
                    StatusCard(status: .checking, title: L("journey.account.checking"))
                case .success(let env)?:
                    StatusCard(status: .done, title: L("journey.account.done"), detail: env.identityName)
                case .failure(.xcodeMissing)?:
                    StatusCard(status: .todo, title: L("onboarding.xcodeMissing.title"),
                               detail: L("journey.account.needsXcode"))
                case .failure(let error)?:
                    StatusCard(status: .todo, title: error.setupTitle) {
                        Button(L("onboarding.openXcode")) {
                            XcodeLauncher.open(developerDir: model.lastKnownDeveloperDir)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.violet)
                    }
                    VStack(spacing: 8) {
                        NumberedRow(number: 1, text: L("journey.account.step1"))
                        NumberedRow(number: 2, text: L("journey.account.step2"))
                        NumberedRow(number: 3, text: L("journey.account.step3"))
                    }
                    .padding(.horizontal, 16)
                    AutoDetectFooter(model: model)
                }
            }
        }
    }
}
