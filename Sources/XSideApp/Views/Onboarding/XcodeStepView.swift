import AppKit
import SwiftUI

/// Step 2 (blocking): Xcode must be installed. Updated live by the model's poller.
struct XcodeStepView: View {
    let model: AppModel

    private var status: JourneyStatus {
        guard model.environment != nil else { return .checking }
        return model.firstBlockingStep == .xcode ? .todo : .done
    }

    var body: some View {
        JourneyPage(symbol: "hammer.fill", title: L("journey.xcode.title"), subtitle: L("journey.xcode.subtitle")) {
            VStack(spacing: 14) {
                switch status {
                case .checking:
                    StatusCard(status: .checking, title: L("journey.xcode.checking"))
                case .done:
                    StatusCard(status: .done, title: L("journey.xcode.done"))
                case .todo:
                    StatusCard(status: .todo, title: L("onboarding.xcodeMissing.title"),
                               detail: L("journey.xcode.missing")) {
                        Button(L("onboarding.openAppStore")) { NSWorkspace.shared.open(XcodeLauncher.appStoreURL) }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.violet)
                    }
                    AutoDetectFooter(model: model)
                }
            }
        }
    }
}
