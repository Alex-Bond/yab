import SwiftUI
import UIKit

/// The field's sizes beyond the skeleton's (Design/Metrics.swift), the
/// prototype's numbers ("Sizes", system.css: .fv-in, .fv-card, .fv-list,
/// .fv-sheet, .fo-eyes, .a-menu, .a-pk): kept here, beside what draws them,
/// so the field branch never edits the shared table.
extension Metrics.Field {
    /// The plate's field: favicon 16 while the address shows, else the magnifier 18.
    static let favicon: CGFloat = 16
    static let magnifier: CGFloat = 18
    /// The ✕ plate's glyph, and its touch area around the 32 to see.
    static let clearGlyph: CGFloat = 17
    static let clearOutset: CGFloat = 6
    /// The ✕ stands 2 in from the field's padding.
    static let clearInset: CGFloat = 2
    /// New Tab's field: 8 from the screen as its rows' card is, its
    /// magnifier 18 in so it stands on the rows' icons (35 from the screen).
    static let newTabLeading: CGFloat = 18
    /// New Tab's field: 8 over the keyboard, as from the screen's sides.
    static let newTabRadius: CGFloat = newTabHeight / 2
    static let newTabAboveKeyboard: CGFloat = 8
    /// Magnifier to words in New Tab's field: the words line up with the rows' titles.
    static let newTabGap: CGFloat = 14
    /// While the field is up the page behind is frosted: rgba(242,242,245,.66).
    static let backdrop = AppearanceColors.color(0xF2F2F5, 0x121214, alpha: 0.66)
    /// Selection and caret, as the prototype draws them.
    static let caret = AppearanceColors.ui(0x0A7AFF, 0x70B5FF)
    static let selection = AppearanceColors.ui(0xBBD8FF, 0x244D6C)
    /// The field's words (#000) and the placeholder (rgba(60,60,67,.45)).
    static let placeholder = AppearanceColors.ui(0x3C3C43, 0xEBEBF5, alpha: 0.45, darkAlpha: 0.65)
    /// Where the field's rows and cards sit while dragged down: 60 % of the finger.
    static let dragFollow: CGFloat = 0.6
    /// Dragged down this far, or this fast, the field closes.
    static let closeDistance: CGFloat = 60
    static let closeVelocity: CGFloat = 500
    /// Rows and the card rise this much as they come, and drop as they go.
    static let rowsRise: CGFloat = 10
    static let rowsDrop: CGFloat = 8
}

extension Metrics.FieldCard {
    /// The page card's actions: glyph over word, 6 apart; padding 11 over, 12 under.
    static let actionGap: CGFloat = 6
    static let actionTop: CGFloat = 11
    static let actionBottom: CGFloat = 12
    static let headGap: CGFloat = 12
    /// The title's and the line's line heights (16 × 1.25, 13 × 1.3) and the step between.
    static let headTitleLine: CGFloat = 20
    static let headSubtitleLine: CGFloat = 16.9
    static let headLineGap: CGFloat = 2
    /// Rows for typed words: icon 20 in a 22 column, title 16 (19.2), line 13 (15.6), 3 apart.
    static let rowIcon: CGFloat = 20
    static let rowFavicon: CGFloat = 22
    static let rowGap: CGFloat = 12
    static let rowTitle: CGFloat = 16
    static let rowTitleLine: CGFloat = 19.2
    static let rowSubtitle: CGFloat = 13
    static let rowSubtitleLine: CGFloat = 15.6
    static let rowLineGap: CGFloat = 3
    static let hairline: CGFloat = 0.5
    /// Rows on one line: 46 high, 10 at the sides, rounded 14
    /// on a card 8 around them and rounded 22.
    static let line: CGFloat = 46
    static let linePadding = EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
    static let lineRadius: CGFloat = 14
    static let linesPadding: CGFloat = 8
    static let linesRadius: CGFloat = lineRadius + linesPadding
    /// The rows' card stands this far over the field, as from the screen's sides.
    static let linesOverField: CGFloat = 8
}

extension Metrics.NewTab {
    /// The highest the card's top goes: 2 under the status bar, when the
    /// keyboard leaves less than its rows need under the prototype's 64.
    static let highest: CGFloat = Metrics.statusBar + 2
    /// With no keyboard (the plate swiped up), the keyboard's place is this
    /// much of the screen's foot: the field lands about where the plate was.
    /// (32 + the field's 8 over it: 40, clear of the home indicator.)
    static let restingFoot: CGFloat = 32
    /// The space's color under the keyboard, past the card's foot: taller
    /// than any keyboard.
    static let underKeyboard: CGFloat = 600
    /// The card's padding: 4 over the rows, 8 at the sides, 66 under them for the field.
    static let cardPadding = EdgeInsets(top: 4, leading: 8, bottom: 66, trailing: 8)
    /// Frequent's grid: five a row, 6 apart, padding 2 6 6; a tile 4 over and under.
    static let tileColumns = 5
    static let tileGap: CGFloat = 6
    static let gridPadding = EdgeInsets(top: 2, leading: 6, bottom: 6, trailing: 6)
    static let tilePadding: CGFloat = 4
    static let tileRadius: CGFloat = 14
    static let tileIcon: CGFloat = 26
    static let tileNameGap: CGFloat = 5
    static let sectionTracking: CGFloat = 0.36 // .03em of 12
    /// The eyes: 26 × 20, padding 6, the word Incognito 8 from them.
    static let eyes = CGSize(width: 26, height: 20)
    static let eyesPadding: CGFloat = 6
    static let eyesGap: CGFloat = 8
    static let incognitoFont: CGFloat = 15
    /// The word opens to its own width (15 medium), at most 90.
    static let incognitoMax: CGFloat = 90
    static let incognitoWidth: CGFloat = min(incognitoMax, ceil(("Incognito" as NSString).size(withAttributes: [
        .font: UIFont.systemFont(ofSize: incognitoFont, weight: .medium),
    ]).width))
    /// Private: the Incognito glyph over its words, 46 % down the screen.
    static let privateGlyph: CGFloat = 40
    static let privateFont: CGFloat = 20
    static let privateGap: CGFloat = 12
    static let privateAt: CGFloat = 0.46
    static let privateLift: CGFloat = 30
    /// Private rows card: 378 from the screen's foot over the prototype's keyboard (16 over the field).
    static let privateRowsAboveField: CGFloat = 10
}

extension Metrics.Menu.Plate {
    /// The header: favicon 18 and the page's short name, 10 12 8, a hairline under, 4 before the items.
    static let headPadding = EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 12)
    static let headGap: CGFloat = 8
    static let headAfter: CGFloat = 4
    static let itemPadding: CGFloat = 12
}
