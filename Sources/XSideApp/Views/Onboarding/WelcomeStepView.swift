import AppKit
import SwiftUI

/// Step 1: the app icon, what XSide does, and the three promises.
struct WelcomeStepView: View {
    var body: some View {
        JourneyPage(title: L("onboarding.window"), subtitle: L("journey.welcome.subtitle")) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                .accessibilityHidden(true)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(symbol: "arrow.down.app.fill", text: L("journey.welcome.install"))
                FeatureRow(symbol: "arrow.triangle.2.circlepath", text: L("journey.welcome.refresh"))
                FeatureRow(symbol: "lock.shield.fill", text: L("journey.welcome.account"))
            }
            .padding(.horizontal, 24)
        }
    }
}
