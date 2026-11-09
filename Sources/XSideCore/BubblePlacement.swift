import CoreGraphics

/// Where a hover bubble goes in the menu-bar panel (device round 2, items 11 and 14): lined up
/// with its control as asked, but always inside the panel, with a margin. The panel's own
/// tooltips are drawn by XSide (system ones don't show in a popover), so nothing else keeps them in.
public enum BubblePlacement {
    public enum Alignment: Sendable { case leading, center, trailing }

    /// The horizontal shift to apply to a bubble `bubbleWidth` wide, laid out against a control
    /// at `anchorMinX` (panel coordinates) `anchorWidth` wide with `alignment`, so that it stays
    /// within `margin` of a panel `panelWidth` wide. A bubble wider than the panel starts at the margin.
    public static func shift(anchorMinX: CGFloat, anchorWidth: CGFloat, bubbleWidth: CGFloat, alignment: Alignment,
                             panelWidth: CGFloat, margin: CGFloat = 6) -> CGFloat {
        let desired: CGFloat = switch alignment {
        case .leading: anchorMinX
        case .trailing: anchorMinX + anchorWidth - bubbleWidth
        case .center: anchorMinX + (anchorWidth - bubbleWidth) / 2
        }
        let clamped = max(margin, min(desired, panelWidth - margin - bubbleWidth))
        return clamped - desired
    }

    /// The text's width in the bubble: its natural width up to `maxWidth` (it wraps beyond), so a
    /// bubble over a narrow control doesn't wrap word by word.
    public static func textWidth(natural: CGFloat, maxWidth: CGFloat = 240) -> CGFloat {
        min(maxWidth, max(1, natural.rounded(.up) + 1))
    }
}
