import CoreGraphics
import Testing
@testable import XSideCore

/// Device round 2, items 11 and 14: the panel's hover bubbles keep their width and stay inside it.
struct BubblePlacementTests {
    @Test func aBubbleThatFitsIsNotMoved() {
        #expect(BubblePlacement.shift(anchorMinX: 100, anchorWidth: 32, bubbleWidth: 80, alignment: .center, panelWidth: 340) == 0)
    }

    @Test func aBubbleOverTheLeftEdgeIsPushedIn() {
        // « Tout rafraîchir » (second tile, its bubble 240 wide lined up on its trailing edge).
        let shift = BubblePlacement.shift(anchorMinX: 96, anchorWidth: 76, bubbleWidth: 240, alignment: .trailing, panelWidth: 340)
        #expect(96 + 76 - 240 + shift == 6)
        // A centered footer tile near the left edge.
        let centered = BubblePlacement.shift(anchorMinX: 12, anchorWidth: 32, bubbleWidth: 150, alignment: .center, panelWidth: 340)
        #expect(centered == 53, "\(centered)")
    }

    @Test func aBubbleOverTheRightEdgeIsPushedIn() {
        let shift = BubblePlacement.shift(anchorMinX: 296, anchorWidth: 32, bubbleWidth: 120, alignment: .leading, panelWidth: 340)
        #expect(296 + shift + 120 == 334)
        // Wider than the panel: from the left margin.
        #expect(BubblePlacement.shift(anchorMinX: 0, anchorWidth: 32, bubbleWidth: 400, alignment: .leading, panelWidth: 340) == 6)
    }

    @Test func theTextKeepsItsWidthUpToTheMaximum() {
        #expect(BubblePlacement.textWidth(natural: 87.2) == 89)
        #expect(BubblePlacement.textWidth(natural: 900) == 240)
        #expect(BubblePlacement.textWidth(natural: 0) == 1)
    }
}
