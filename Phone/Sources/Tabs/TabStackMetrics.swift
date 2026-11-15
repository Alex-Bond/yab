import SwiftUI

/// The tab stack's and All Tabs' sizes and timings. All Tabs is measured
/// frame by frame (a 60 fps screen recording at 375 x 812 points,
/// 2026-10-09); its numbers are fractions of the screen and of
/// the page's content area, so they carry to any iPhone. The stack keeps
/// our round glass under it, as the user picked in the live prototype
/// (6mGJ7hWG v3, "Glass circle"): two cards on the page, made small
/// enough to sit inside the circle, each with a faint rim inside its
/// edge and a light shadow so they read on light and dark pages alike.
extension Metrics {
    enum TabStack {
        /// A card: the top of its page, 22 x 24, rounded 4, inside the 48
        /// circle: a nearly square card (26 x 28.5, corners about a
        /// sixth of its width) made small.
        static let cardWidth: CGFloat = 22
        static let cardHeight: CGFloat = 24
        static let cardRadius: CGFloat = 4
        /// Where the two cards' middles stand from the circle's: the previous
        /// tab's card a little up and right, turned 8° clockwise, the one
        /// before it down and left, turned 12° the other way (the
        /// prototype's 354, 821 and 348, 824 around the circle's 352, 822).
        static let front = CGPoint(x: 2, y: -1)
        static let back = CGPoint(x: -4, y: 2)
        static let frontTurn: CGFloat = 8
        static let backTurn: CGFloat = -12
        /// The card behind shows a little of what is under it and is a shade
        /// darker: 87 % opaque under an 8 % dark veil.
        static let backOpacity: CGFloat = 0.87
        static let backVeil: CGFloat = 0.08
        /// The rim: a hairline 0.5 inside each card's edge, white at 22 %
        /// (a solid white 0.75 outside it read thick and bright), and under
        /// it a shadow 1 down and 3 soft at 18 %, only enough to part a
        /// white page's card from the circle on a light page (a layer's
        /// radius is half the blur).
        static let rim: CGFloat = 0.5
        static let rimAlpha: CGFloat = 0.22
        static let shadowY: CGFloat = 1
        static let shadowRadius: CGFloat = 1.5
        static let shadowAlpha: Float = 0.18
        /// A card with no picture yet: the site's icon in the middle.
        static let fallbackIcon: CGFloat = 12
        /// The top card chosen in All Tabs, nothing goes into the stack: the
        /// circle comes up from this far below with its cards as they are.
        static let rise: CGFloat = 104

        /// The flick: the front card lifts with the finger and grows by a
        /// third over its first 60 points; past them it resists.
        static let liftSpan: CGFloat = 60
        static let liftGrowth: CGFloat = 0.35
        static let liftRubber: CGFloat = 40
        /// Let go 40 up (the finger's speed carried 0.15 s) and the tab changes.
        static let flickCommit: CGFloat = 40
        static let flickProjection: CGFloat = 0.15
        /// The page left behind darkens by this much under the one growing.
        static let flickDim: Double = 0.3
        /// The growing page's shadow while it is still a card.
        static let flickShadow: CGFloat = 22
        static let flickShadowAlpha: Double = 0.35
    }

    enum TabGallery {
        /// Between the cards, and at the screen's sides, across an unfolded Duo.
        static let acrossGap: CGFloat = 16
        /// The cards by depth: 0 is the focus (the tab used before the one in
        /// front), 1 the one older behind it on the left, -1 the newer one on
        /// the right (the tab in front). Each: its left edge as a share of the
        /// screen's width, and its scale of the page's content area. Measured:
        /// left edges 291.8, 80.5, 11.3 and -9.5 of 375; heights 536.6, 530.7,
        /// 519.7 and 487.8 of the 688 between the status bar and the bar. The
        /// ends go on as the last steps do (12 points a card further left).
        static let depths: [(depth: CGFloat, left: CGFloat, scale: CGFloat)] = [
            (-1, 0.7781, 0.780), (0, 0.2147, 0.7714), (1, 0.0301, 0.755), (2, -0.0253, 0.709), (3, -0.0573, 0.663),
        ]
        /// Every card's middle stands at this share of the screen's height (418 of 812).
        static let middle: CGFloat = 0.5148
        /// The corners: 24.5 on the focus card, its height's 0.0462.
        static let radius: CGFloat = 0.0462
        /// Over each card: its site's icon, 20, 18 in from the card's left
        /// edge and 8 over its top; the title (the focus card's only),
        /// semibold 13, 6.5 after the icon, stopping 16 short of the next
        /// card's icon.
        static let labelIcon: CGFloat = 20
        static let labelInset: CGFloat = 18
        static let labelRise: CGFloat = 8
        static let labelGap: CGFloat = 6.5
        static let labelFont: CGFloat = 13
        static let labelEnd: CGFloat = 16
        /// Older cards under a dark veil, 20 % one back (their white read 201)
        /// and 35 % from two back; their icons fade from one back to 40 % two back.
        static let veilOne: Double = 0.2
        static let veilMost: Double = 0.35
        static let iconFar: Double = 0.4
        /// New Tab: + in a wide glass capsule on the bar's middle line, as
        /// wide as two of its height (76 x 38 measured).
        static let plusWidth: CGFloat = 96
        /// A card swiped up past 120 (or thrown, the speed carried 0.2 s) closes.
        static let closeDistance: CGFloat = 120
        static let closeProjection: CGFloat = 0.2
        static let minimumThrowSpeed: CGFloat = 450
        static let throwAcceleration: CGFloat = 3000
        static let pinchTravel: CGFloat = 0.4
        static let pinchCommit: CGFloat = 0.35
        /// After the capsule turns the space, its cards follow the lens home this long.
        static let pageSettle: CFTimeInterval = 0.8
        /// Pulled down or past the ends, the cards resist.
        static let rubber: CGFloat = 60
        /// Let go, the cards page on to the next card once thrown 0.15 of a
        /// card's way (the finger's speed carried as iOS projects it) or
        /// dragged a third of it; less goes back.
        static let pageThrow: CGFloat = 0.15
        static let pageDrag: CGFloat = 1.0 / 3
    }
}

/// When everything in All Tabs moves, from the recording: each movement's
/// spring fitted to its frames (response and damping as SwiftUI's
/// spring(response:dampingFraction:), so the frames' progress at each 60 fps
/// frame is within 0.01 to 0.02 of the recording's). What shrinks is quick, what
/// grows slower: the page into its card 0.235, 0.92 (90 % at 0.13 s);
/// cards back into the stack 0.22, 0.88 (90 % at 0.12 s); cards out of the
/// stack 0.29, 0.94, starting 0.02 s after the tap (90 % at 0.19 s); a
/// card growing into its page 0.305, 0.94 (90 % at 0.175 s). The bar's
/// buttons cross over on CSS's ease-out in 0.19 s.
enum TabGalleryTiming {
    static let pageToCard = SpringCurve(response: 0.235, damping: 0.92)
    static let cardToStack = SpringCurve(response: 0.22, damping: 0.88)
    static let stackToCard = SpringCurve(response: 0.29, damping: 0.94)
    static let cardToPage = SpringCurve(response: 0.305, damping: 0.94)
    /// Opening: the previous tab's card leaves the stack 0.02 s after the
    /// tap, the one before it 0.035 s, the older ones 0.06 s, coming in from
    /// nothing between 0.03 and 0.12 s; the turned cards straighten on the
    /// page's spring (their turn to 0 by 0.1 s, before they have half grown).
    static let frontDelay: Double = 0.02
    static let backDelay: Double = 0.035
    static let olderDelay: Double = 0.06
    static let olderFade: ClosedRange<Double> = 0.03...0.12
    /// A label comes in with its card, whole by 55 % of the way, and goes by 60 %.
    static let labelIn: CGFloat = 0.55
    static let labelOut: CGFloat = 0.6
    /// Closing: the cards that don't go into the circle stay where they
    /// are and are gone in 0.1 s. A stack card that lay under the chosen one
    /// appears in its place in the circle as the cards flying in land (on
    /// their spring), and with the top card chosen the circle comes up on it.
    static let othersFade: Double = 0.1
    /// The bar's buttons crossing over: cubic-bezier(0, 0, .58, 1), 0.19 s.
    static let barDuration: Double = 0.19
    /// Long enough for every spring to be within a tenth of a point.
    static let openDuration: Double = 0.5
    static let closeDuration: Double = 0.45

    static func barProgress(_ t: Double) -> CGFloat {
        easeOut(min(max(t / barDuration, 0), 1))
    }

    /// cubic-bezier(0, 0, .58, 1) at `x`: the curve's parameter for that x
    /// found by halving, then its y.
    static func easeOut(_ x: Double) -> CGFloat {
        let x1 = 0.0, x2 = 0.58, y1 = 0.0, y2 = 1.0
        func bezier(_ a: Double, _ b: Double, _ s: Double) -> Double {
            3 * (1 - s) * (1 - s) * s * a + 3 * (1 - s) * s * s * b + s * s * s
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let s = (lo + hi) / 2
            if bezier(x1, x2, s) < x { lo = s } else { hi = s }
        }
        return CGFloat(bezier(y1, y2, (lo + hi) / 2))
    }
}

/// A spring from rest, as a function of time: SwiftUI's
/// spring(response:dampingFraction:), so frames can be worked out for any
/// moment (films, held states, tests) rather than integrated.
struct SpringCurve: Equatable, Sendable {
    let response: Double
    let damping: Double

    /// How far from 0 to 1 it has come `t` seconds after it started.
    func value(_ t: Double) -> CGFloat {
        guard t > 0 else { return 0 }
        let w0 = 2 * Double.pi / response
        if damping < 1 {
            let wd = w0 * (1 - damping * damping).squareRoot()
            let e = exp(-damping * w0 * t)
            return CGFloat(1 - e * (cos(wd * t) + damping * w0 / wd * sin(wd * t)))
        }
        return CGFloat(1 - (1 + w0 * t) * exp(-w0 * t))
    }
}

extension Motion {
    /// The lifted card going back into the stack when the finger lets go
    /// short, as All Tabs' cards go back into the stack.
    static let tabFlickBack = spring("tabFlickBack", response: TabGalleryTiming.cardToStack.response, damping: TabGalleryTiming.cardToStack.damping)
    /// The previous tab growing out of the lifted card to the whole page, as
    /// a card tapped in All Tabs grows into its page.
    static let tabFlickGrow = spring("tabFlickGrow", response: TabGalleryTiming.cardToPage.response, damping: TabGalleryTiming.cardToPage.damping)
    /// All Tabs opening and a card opening, for their signposts and the
    /// meters: the slower of each one's springs (TabGalleryTiming).
    static let tabsOpen = spring("tabsOpen", response: TabGalleryTiming.stackToCard.response, damping: TabGalleryTiming.stackToCard.damping)
    static let tabsCardOpen = spring("tabsCardOpen", response: TabGalleryTiming.cardToPage.response, damping: TabGalleryTiming.cardToPage.damping)
    /// After a thrown card clears the screen, the rest close the gap.
    static let tabsReflow = spring("tabsReflow", response: TabGalleryTiming.stackToCard.response, damping: TabGalleryTiming.stackToCard.damping)
    /// A card let go short of closing, and the cards let go after a scroll.
    static let tabsCardBack = spring("tabsCardBack", response: TabGalleryTiming.cardToStack.response, damping: TabGalleryTiming.cardToStack.damping)
    static let tabsScroll = spring("tabsScroll", response: TabGalleryTiming.stackToCard.response, damping: TabGalleryTiming.stackToCard.damping)
    /// A card's page picture arriving over its icon (read from the disk, or
    /// warmed up): a quiet cross-fade.
    static let tabPictureIn = easeOut("tabPictureIn", 0.25)
}

