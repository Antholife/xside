import AppKit
import SwiftUI
import XSideCore

/// Step 2 (blocking): Xcode must be installed. Updated live by the model's poller.
struct XcodeStepView: View {
    let model: AppModel

    private var status: JourneyStatus {
        guard model.environment != nil else { return .checking }
        return model.firstBlockingStep == .xcode ? .todo : .done
    }

    /// "Xcode 27.2 (27B48) is installed", or "Xcode 27.0 beta (27A5241e) is installed".
    private var doneTitle: String {
        guard case .success(let env)? = model.environment,
              let xcode = XcodeCompat.xcodeVersion(developerDir: env.developerDir) else { return L("journey.xcode.done") }
        return L(xcode.isBeta ? "journey.xcode.done.beta" : "journey.xcode.done.version", xcode.version, xcode.build)
    }

    /// How to get a working Xcode: install it (beta on a macOS beta), open it once, come back.
    private var installSteps: some View {
        VStack(spacing: 8) {
            NumberedRow(number: 1, text: L(XcodeLauncher.macIsBeta ? "journey.xcode.step.install.beta"
                                                                  : "journey.xcode.step.install"))
            NumberedRow(number: 2, text: L("journey.xcode.step.open"))
            NumberedRow(number: 3, text: L("journey.xcode.step.back"))
        }
        .padding(.horizontal, 16)
    }

    var body: some View {
        JourneyPage(symbol: "hammer.fill", title: L("journey.xcode.title"), subtitle: L("journey.xcode.subtitle")) {
            VStack(spacing: 14) {
                switch status {
                case .checking:
                    StatusCard(status: .checking, title: L("journey.xcode.checking"))
                case .done:
                    StatusCard(status: .done, title: doneTitle)
                    if model.macBetaWithReleaseXcode {
                        MacBetaBanner()
                        installSteps
                    }
                case .todo:
                    StatusCard(status: .todo, title: L("onboarding.xcodeMissing.title"),
                               detail: XcodeLauncher.macIsBeta ? L("journey.xcode.macBeta") : nil) {
                        // On a macOS beta, Xcode beta replaces the App Store one, which may not run on it.
                        Group {
                            if XcodeLauncher.macIsBeta {
                                Button(L("journey.xcode.downloadBeta")) { NSWorkspace.shared.open(XcodeLauncher.betaURL) }
                            } else {
                                Button(L("onboarding.openAppStore")) { NSWorkspace.shared.open(XcodeLauncher.appStoreURL) }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.violet)
                    }
                    installSteps
                    AutoDetectFooter(model: model)
                }
                Label(L(XcodeLauncher.macIsBeta ? "journey.xcode.mac.beta" : "journey.xcode.mac",
                        XcodeLauncher.macVersion, XcodeLauncher.macBuild),
                      systemImage: "laptopcomputer")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
