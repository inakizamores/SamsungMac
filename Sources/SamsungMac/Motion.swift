import SwiftUI

/// One motion vocabulary for the panel, so every resize reads as the same
/// gesture: a chevron opening, a row arriving on its own, a room's controls
/// swapping. Mixing curves is most of what makes a resize feel unfinished.
extension Animation {
    /// Panel growth and shrink. Longer and softer than SwiftUI's default,
    /// which snaps hard over the short distances a menu bar panel moves.
    static let panel = Animation.smooth(duration: 0.34, extraBounce: 0)
}

extension AnyTransition {
    /// Rows fade in only once the space for them has opened, and fade out
    /// before it closes again — so text is never drawn mid-squeeze. The
    /// asymmetry matters: growing wants to feel unhurried, shrinking wants
    /// the content gone before the gap shuts.
    static let panelRow = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.1)),
        removal: .opacity.animation(.easeIn(duration: 0.12))
    )
}
