import SwiftUI

/// Explainer 1: what sideloading is, and why apps need refreshing (free account: 7 days).
struct HowItWorksStepView: View {
    var body: some View {
        JourneyPage(symbol: "lightbulb.fill", title: L("journey.how.title"), subtitle: L("journey.how.subtitle")) {
            VStack(spacing: 10) {
                ConceptCard(symbol: "shippingbox.fill", title: L("journey.how.sideload.title"),
                            text: L("journey.how.sideload.text"))
                ConceptCard(symbol: "clock.arrow.2.circlepath", title: L("journey.how.refresh.title"),
                            text: L("journey.how.refresh.text"))
                ConceptCard(symbol: "cable.connector", title: L("journey.how.pairing.title"),
                            text: L("journey.how.pairing.text"))
            }
        }
    }
}
