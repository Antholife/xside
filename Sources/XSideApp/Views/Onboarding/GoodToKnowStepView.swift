import SwiftUI

/// Explainer 2: the free-account limits, and why the Apple account stays safe.
struct GoodToKnowStepView: View {
    var body: some View {
        JourneyPage(symbol: "info.circle.fill", title: L("journey.know.title"), subtitle: L("journey.know.subtitle")) {
            VStack(spacing: 10) {
                ConceptCard(symbol: "gauge.with.dots.needle.33percent", title: L("journey.know.limits.title"),
                            text: L("journey.know.limits.text"))
                ConceptCard(symbol: "lock.shield.fill", title: L("journey.know.safe.title"),
                            text: L("journey.know.safe.text"))
            }
        }
    }
}
