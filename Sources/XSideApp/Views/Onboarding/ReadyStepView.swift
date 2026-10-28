import SwiftUI

/// Step 7: how to install the first app. "Finish" marks the journey completed.
struct ReadyStepView: View {
    var body: some View {
        JourneyPage(symbol: "checkmark.seal.fill", title: L("journey.ready.title"),
                    subtitle: L("journey.ready.subtitle")) {
            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(symbol: "menubar.arrow.down.rectangle", text: L("journey.ready.drop"))
                FeatureRow(symbol: "cursorarrow.click.2", text: L("journey.ready.openWith"))
                FeatureRow(symbol: "arrow.triangle.2.circlepath", text: L("journey.ready.auto"))
            }
            .padding(.horizontal, 24)
        }
    }
}
