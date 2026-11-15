import SwiftUI
import UIKit

/// Settings' sizes, beside the skeleton's Metrics.Settings: the prototype's
/// .set-* rules (Phone/Reference/digest/screens-settings.md), in points.
/// Text takes the system's text styles whose sizes are the prototype's at
/// the default Dynamic Type size (title 28, row 16, value 15, footer 13,
/// section 12), so all of it grows with the person's text size.
extension Metrics.Settings {
    /// The grabber, 7 under the sheet's top.
    static let grabTop: CGFloat = 7
    static let grab = CGSize(width: 38, height: 5)
    /// Joining's head: × 12 from the left, 6 above and below it.
    static let headHeight: CGFloat = 56
    /// The prototype tightens "Settings" by .03 em, drawn in SF Pro Text
    /// (the browser's system font has no optical sizes). iOS draws 28 in SF
    /// Pro Display, already that much tighter: with no more, the word is as
    /// wide as the prototype's.
    static let titleTracking: CGFloat = 0
    /// The round ✕ and ‹ in the head: 44 to see and to hit, their glyph 22.
    static let headButton: CGFloat = 44
    static let headIcon: CGFloat = 22
    /// At least this between the title and ✕ when big text brings them close.
    static let headGap: CGFloat = 8
    /// The body: 12 from the sides, the first section 26 under the head
    /// (4 of padding and the 22 between sections), 40 free at the end.
    static let bodySide: CGFloat = 16
    static let bodyTop: CGFloat = 26
    static let bodyBottom: CGFloat = 40
    /// A section's title: 12 high, 8 in, 6 over its group; .03 em apart.
    static let sectionTitle: CGFloat = 12
    static let sectionFont: CGFloat = 12
    static let sectionInset: CGFloat = 8
    static let sectionTitleGap: CGFloat = 6
    static let sectionTracking: CGFloat = 0.03
    /// The words under a group, 6 under it, their lines 18.2 apart (13 x
    /// 1.4): the system's footnote lines and this much more.
    static let footerGap: CGFloat = 6
    static let footerLeading: CGFloat = 2.5
    /// The browser sets 13 a hair tighter than iOS: this keeps its lines
    /// breaking where the prototype's do.
    static let footerTracking: CGFloat = -0.12
    /// A row: 12 in, 12 between its icon, title, value and chevron.
    static let rowPadding: CGFloat = 12
    static let rowGap: CGFloat = 12
    /// Big text, the value under the title: 2 between them, 10 above and below.
    static let stackGap: CGFloat = 2
    static let stackPadding: CGFloat = 10
    static let rowIcon: CGFloat = 20
    static let chevron: CGFloat = 16
    static let check: CGFloat = 18
    /// The line between rows starts after the icon.
    static let hairlineInset: CGFloat = 46
    /// A space's tile in the Spaces list: a row's icon with a little more room for its emoji.
    static let spaceTile: CGFloat = 36
    static let hairline: CGFloat = 0.5
    /// About Yab's mark in its row, rounded 6.
    static let markRadius: CGFloat = 6
    /// The soft edge over scrolled content: there once scrolled 2.
    static let edgeAfter: CGFloat = 2
    /// The sheet's shadow above it: 0 -10 40 at .18.
    static let shadowRadius: CGFloat = 20
    static let shadowY: CGFloat = -10
    static let shadowOpacity: Double = 0.18
    /// Swiped down past this, or this fast, it closes; pulled
    /// down past the top of its list this far, too.
    static let closeDistance: CGFloat = 120
    static let closeVelocity: CGFloat = 600
    static let pullToClose: CGFloat = 90
    /// A row's page grows out of the row: the row's radius at the start
    /// (a settings row, r 16), and the clip's on its way to the sheet (the
    /// code and yes sheets' 34) before the sheet's own 38 takes over.
    static let originRadius: CGFloat = 16
    static let growRadius: CGFloat = 34
    /// Rising with nowhere to grow from: from 105 % of its height; going
    /// away down: 60 % of it.
    static let riseFrom: CGFloat = 1.05
    static let dropTo: CGFloat = 0.6
    /// What a sheet holds comes in from 8 lower.
    static let contentsRise: CGFloat = 8
    /// A page's edge swipe back: from 24 of the left edge, 80 across.
    static let backEdge: CGFloat = 24
    static let backDistance: CGFloat = 80
}

/// The first launch's welcome, in the prototype's language: Yab's mark,
/// a few words, one action on glass near the bottom, Not Now under it.
extension Metrics {
    enum Welcome {
        /// The mark at its picture's own size (192 px at 3x).
        static let mark: CGFloat = 64
        static let markGap: CGFloat = 22
        static let lineGap: CGFloat = 10
        static let textWidth: CGFloat = 350
        /// Join Your Mac: the plate's height, 20 from the sides.
        static let button: CGFloat = Chrome.height
        static let buttonInset: CGFloat = Edge.content
        /// Not Now, plain words under the glass, 44 high and as wide as its
        /// words and 16 either side.
        static let buttonGap: CGFloat = 16
        static let notNow: CGFloat = Metrics.touch
        static let notNowPadding: CGFloat = 16
        /// The pair ends 22 over the bottom: Not Now's words at the height of
        /// the plate's.
        static let bottom: CGFloat = 22
        /// Offline, the words in Join Your Mac's place: 16 in from its ends.
        static let notePadding: CGFloat = 16
        static let titleTracking: CGFloat = 0
    }
}

/// Settings' and the welcome's colors: the prototype's light ones as drawn,
/// and iOS's own in dark (grouped backgrounds as a sheet wears them, labels).
enum SettingsInk {
    /// The sheet: rgba(242, 242, 247, .98); dark, the elevated grouped background.
    static let sheet = dynamic(UIColor(red: 242 / 255, green: 242 / 255, blue: 247 / 255, alpha: 0.98),
                               UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.98))
    /// A row's page over the sheet: the same ground, opaque.
    static let pageGround = dynamic(UIColor(red: 242 / 255, green: 242 / 255, blue: 247 / 255, alpha: 1),
                                    UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1))
    /// A group of rows: white; dark, the elevated secondary grouped background.
    static let group = dynamic(.white, UIColor(red: 44 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1))
    /// Words and glyphs: #1c1c1e.
    static let text = dynamic(UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1), .white)
    /// Section titles and the words under a group: the prototype's .55 and
    /// .6 over the sheet's ground, darkened so they read at 4.5:1 and more.
    /// Keep the thinner footnotes opaque: their readability must not depend
    /// on the translucent sheet or the page behind it.
    static let section = secondary(0.76)
    static let footer = secondary(1)
    /// A row's value over its white group: the prototype's .6, at .72 for
    /// the same 4.5:1.
    static let value = secondary(0.72)
    /// Quieter words that are still a button (Not Now), .72.
    static let quiet = secondary(0.72)
    /// The chevron, .35.
    static let chevron = dynamic(UIColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.35),
                                 UIColor(red: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: 0.3))
    /// The icon's box: rgba(118, 118, 128, .12); dark, tertiary fill.
    static let iconBox = dynamic(UIColor(red: 118 / 255, green: 118 / 255, blue: 128 / 255, alpha: 0.12),
                                 UIColor(red: 118 / 255, green: 118 / 255, blue: 128 / 255, alpha: 0.24))
    /// A segmented control's knob: white; dark, iOS's selected segment.
    static let knob = dynamic(.white, UIColor(red: 99 / 255, green: 99 / 255, blue: 102 / 255, alpha: 1))
    /// A row under the finger.
    static let pressed = dynamic(UIColor(red: 118 / 255, green: 118 / 255, blue: 128 / 255, alpha: 0.12),
                                 UIColor(red: 118 / 255, green: 118 / 255, blue: 128 / 255, alpha: 0.24))
    static let hairline = dynamic(UIColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.16),
                                  UIColor(red: 84 / 255, green: 84 / 255, blue: 88 / 255, alpha: 0.45))
    static let grab = dynamic(UIColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.3),
                              UIColor(red: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: 0.3))
    /// The soft edge's color at its top: rgba(242, 242, 247, .95).
    static let edge = dynamic(UIColor(red: 242 / 255, green: 242 / 255, blue: 247 / 255, alpha: 0.95),
                              UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.95))
    /// The welcome's ground: the system's background.
    static let ground = Ink.ground
    /// Ink buttons (#161615, white words); dark, the label with the ground's words.
    static let ink = dynamic(UIColor(red: 22 / 255, green: 22 / 255, blue: 21 / 255, alpha: 1), .white)
    static let onInk = dynamic(.white, .black)
    /// The welcome uses the same neutral primary ink as unread.
    static let logoStop = Ink.newAnswer

    /// The prototype's gray words, iOS's own secondary ink. With Increase
    /// Contrast on, they darken to 4.5:1 or more over the sheet, as iOS's do.
    private static func secondary(_ alpha: CGFloat) -> Color {
        // Opaque footnotes expose the same resolved ink to native accessibility.
        return Color(uiColor: UIColor { traits in
            let high = traits.accessibilityContrast == .high
            let a = high ? max(alpha, highContrastAlpha) : alpha
            return AppAppearance.drawsDark && traits.userInterfaceStyle == .dark
                ? UIColor(red: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: high ? max(a, 0.86) : a)
                : UIColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: a)
        })
    }

    static let highContrastAlpha: CGFloat = 0.8

    static func dynamic(_ light: UIColor, _ dark: UIColor) -> Color {
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// Settings' movements beside the skeleton's: a sheet let go of under the
/// finger, and what a sheet holds leaving first. Opening and closing are
/// the code and yes sheets' own (sheetGrow, sheetRise, sheetBack, sheetDrop,
/// sheetContents), as the prototype's motion table says for Settings.
extension Motion {
    /// Let go past the close line: on down (.32 / 1).
    static let sheetFlick = spring("sheetFlick", response: 0.32)
    /// Let go short of it: back in place (.32 / .9).
    static let sheetSnap = spring("sheetSnap", response: 0.32, damping: 0.9)
    /// Going back into its origin, a sheet's words go first: 120 ms.
    static let sheetContentsOut = linear("sheetContentsOut", 0.12)
    /// The welcome steps aside for the empty browser: leaving, quick.
    static let welcomeOut = easeIn("welcomeOut", 0.18)
}

/// The selected revision's Mac-style index and page heroes.
extension Metrics.Settings {
    static let tileRadiusFraction: CGFloat = 0.26
    static let wellGlyphFraction: CGFloat = 0.58
    static let featureGlyphFraction: CGFloat = 0.5
    static let tileRim: CGFloat = 0.5
    static let indexTile: CGFloat = 30
    static let indexRow: CGFloat = 50
    static let indexRowPadding: CGFloat = 5
    static let indexGap: CGFloat = 20
    static let indexTop: CGFloat = 8
    static let indexCardPadding: CGFloat = 4
    static let indexCardRadius: CGFloat = 18
    static let searchHeight: CGFloat = 44
    static let searchInset: CGFloat = 14
    static let searchIcon: CGFloat = 18
    static let searchGap: CGFloat = 16
    static let heroTile: CGFloat = 56
    static let heroGap: CGFloat = 12
    static let heroTop: CGFloat = 4
    static let heroBottom: CGFloat = 18
    static let heroSide: CGFloat = 24
    /// The sheet's one head: 52 high, its round button 12 from the left
    /// and 4 under the top; ×'s glyph 18, ‹'s 22.
    static let headBar: CGFloat = 52
    static let headSide: CGFloat = 12
    static let crossIcon: CGFloat = 18
    /// Bodies changing in place overlap 8 apart.
    static let swapOffset: CGFloat = 8
    /// The page behind dims this much under the sheet.
    static let dim: Double = 0.18
}

/// Settings' own movements (the review of R49 and P1), on the
/// prototype's cubic curves: ease-out 1 - (1 - t)^3, ease-in t^3.
extension Motion {
    /// The whole screen up from below as Settings opens, as iOS presents a
    /// screen (its curve, half a second), and down as it closes, quicker.
    static let settingsOpen = curve("settingsOpen", 0.32, 0.72, 0, 1, 0.5)
    static let settingsClose = curve("settingsClose", 0.4, 0, 0.8, 0.2, 0.3)
    /// A page in from the right as iOS pushes one, and back out to it (by
    /// ‹ or a finger let go), on iOS's navigation curve.
    static let settingsPush = curve("settingsPush", 0.32, 0.72, 0, 1, 0.42)
    static let settingsBack = curve("settingsBack", 0.32, 0.72, 0, 1, 0.35)
}
