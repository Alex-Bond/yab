import SwiftUI

/// Going back's numbers, from its prototype (the back stack's, 2026-10-08:
/// the swipe back, a tab's first page, nothing behind, the tab's history).
/// Its timings are iOS's own: a 0.35 s spring.
extension Metrics {
    enum Back {
        /// The tab under the page at a first page: 0.92 of the screen as the
        /// finger lands, its corners 40, growing to the whole screen.
        static let cardScale: CGFloat = 0.92
        static let cardRadius: CGFloat = 40
        /// The card's dark over it, gone as it grows.
        static let cardDim: Double = 0.18
        /// The page leaving rounds its own corners to 40 in its first third.
        static let pageRadius: CGFloat = 40
        static let pageRadiusBy: CGFloat = 1 / 3
        /// Its shadow on the left edge: 12 out, 30 soft, black at 0.34, a
        /// little lighter as it goes (by 0.4) over the card.
        static let shadowX: CGFloat = -12
        static let shadowRadius: CGFloat = 15
        static let shadowOpacity: Double = 0.34
        static let shadowFade: CGFloat = 0.4
        /// How near the left edge a pull starts (the prototype's 28; UIKit's
        /// own edge is narrower still).
        static let edge: CGFloat = 28
        /// A swipe from anywhere on the page goes sideways at least 1.7 times
        /// as fast as up or down (within 30 degrees of level): a scroll a
        /// little off the vertical stays a scroll.
        static let anywhereSlope: CGFloat = 1.7
        /// Let go past half the screen, or thrown faster than 500 pt/s, it goes.
        static let commit: CGFloat = 0.5
        static let fling: CGFloat = 500
        /// 3 short of its place the page has left to the eye: the tab closes then.
        static let landed: CGFloat = 3
        /// ‹ with nowhere to go: its chevron at 0.3.
        static let dimmed: CGFloat = 0.3
        /// A site's icon in ‹'s menu (as large as a menu's glyphs): its corners 0.22 of it.
        static let menuIconRadius: CGFloat = 0.22
    }
}

extension Motion {
    /// The page let go from the edge: on to the opener or back in place,
    /// keeping the finger's speed; the same for ‹ at a first page.
    static let backPull = spring("backPull", response: 0.35)
}

extension Haptics.Reason {
    /// One soft impact as the tab closes going back to its opener: more
    /// than a Back. A plain Back by swipe is quiet, as in iOS.
    static let backToOpener = "back to opener"
}

extension Ink {
    /// Under the card while a page goes back to its opener (#151517).
    static let backGround = AppearanceColors.color(0x151517, 0x000000)
    /// Under the page pulled with nothing behind it (#dcdce1).
    static let backNothing = AppearanceColors.color(0xDCDCE1, 0x1C1C1E)
}
