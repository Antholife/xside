import SwiftUI
import XSideCore

/// What's missing in Xcode: the Apple account, or the signing certificate.
enum SigningProblem {
    case account, certificate

    var stepKeys: [String] {
        switch self {
        case .account: ["journey.account.step1", "journey.account.step2", "journey.account.step3"]
        case .certificate: ["journey.account.step1", "journey.account.cert.step2", "journey.account.cert.step3",
                            "journey.account.cert.step4"]
        }
    }
}

/// "Open Xcode", with its Settings preset to the Apple Account pane.
struct OpenXcodeButton: View {
    let model: AppModel
    var onOpen: () -> Void = {}

    var body: some View {
        Button(L("onboarding.openXcode")) {
            XcodeLauncher.openAccounts(developerDir: model.lastKnownDeveloperDir)
            onOpen()
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.violet)
    }
}

/// The numbered steps to fix `problem` in Xcode, after "Xcode is open: press ⌘ ," once opened.
struct SigningSteps: View {
    let problem: SigningProblem
    let xcodeOpened: Bool

    var body: some View {
        VStack(spacing: 8) {
            if xcodeOpened {
                Label(L("journey.account.opened"), systemImage: "keyboard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.violet)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            ForEach(Array(problem.stepKeys.enumerated()), id: \.offset) { index, key in
                NumberedRow(number: index + 1, text: L(key))
            }
        }
    }
}

/// "Create the certificate": XSide has Xcode create it (a spinner while it runs).
struct CreateCertificateButton: View {
    let model: AppModel

    var body: some View {
        if model.isCreatingCertificate {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("certificate.creating")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else {
            Button(L("certificate.create"), action: model.createCertificate)
                .buttonStyle(.borderedProminent)
                .tint(Theme.violet)
        }
    }
}

/// The manual fallback for the certificate: "Otherwise, by hand in Xcode:" with "Open Xcode" as
/// a link, then the steps.
struct ManualCertificateSteps: View {
    let model: AppModel
    @State private var xcodeOpened = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(L("certificate.manual")).font(.system(size: 12)).foregroundStyle(.secondary)
                Button(L("onboarding.openXcode")) {
                    XcodeLauncher.openAccounts(developerDir: model.lastKnownDeveloperDir)
                    xcodeOpened = true
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            SigningSteps(problem: .certificate, xcodeOpened: xcodeOpened)
        }
    }
}

/// Button then steps, stacked (Settings).
struct SigningFixView: View {
    let problem: SigningProblem
    let model: AppModel
    @State private var xcodeOpened = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch problem {
            case .account:
                OpenXcodeButton(model: model) { xcodeOpened = true }
                SigningSteps(problem: problem, xcodeOpened: xcodeOpened)
            case .certificate:
                CreateCertificateButton(model: model)
                if let error = model.certificateCreationError {
                    ErrorText(error)
                }
                ManualCertificateSteps(model: model)
            }
        }
    }
}
