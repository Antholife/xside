import SwiftUI
import XSideCore

/// Step 4 (blocking): an "Apple Development" signing certificate for the signed-in account. Turns ✅
/// by itself through the model's poller once Xcode has created it.
struct CertificateStepView: View {
    let model: AppModel

    var body: some View {
        JourneyPage(symbol: "checkmark.seal.fill", title: L("journey.certificate.title"),
                    subtitle: L("journey.certificate.subtitle")) {
            VStack(spacing: 14) {
                let blocking = model.firstBlockingStep
                if model.environment == nil {
                    StatusCard(status: .checking, title: L("journey.certificate.checking"))
                } else if let blocking, blocking < .certificate {
                    StatusCard(status: .todo, title: L("onboarding.signIn.title"),
                               detail: L("journey.certificate.needsAccount"))
                } else if blocking == .certificate {
                    StatusCard(status: .todo, title: L("onboarding.noIdentity.title"),
                               detail: model.certificateCreationError ?? L("certificate.create.detail")) {
                        CreateCertificateButton(model: model)
                    }
                    ManualCertificateSteps(model: model)
                        .padding(.horizontal, 16)
                    AutoDetectFooter(model: model)
                } else {
                    StatusCard(status: .done, title: L("journey.certificate.done"),
                               detail: model.signingEnvironment?.identityName)
                }
            }
        }
    }
}
