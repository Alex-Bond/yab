import SwiftUI

// The join sheet's look: Settings' sizes and colors (screens-settings.md),
// the app's field for the Recovery Key. What sync puts in the column ("Mac"
// on a row, the quiet line under the today line) is drawn by the column
// itself (Column/ColumnPage), from what the bridge says.

extension Metrics {
    enum Sync {
        // The join sheet, Settings' look (screens-settings.md).
        static let sheetTop: CGFloat = Sheet.fullTop
        static let headTop: CGFloat = 6
        static let headLeading: CGFloat = Edge.content
        static let headTrailing: CGFloat = Edge.gutter
        static let titleFont: CGFloat = 28
        static let titleTracking: CGFloat = -0.84 // -.03em
        static let close: CGFloat = 44
        static let closeIcon: CGFloat = 22
        static let bodyInset: CGFloat = Edge.gutter
        static let bodyTop: CGFloat = 4
        static let sectionGap: CGFloat = 22
        static let groupRadius: CGFloat = 16
        static let rowHeight: CGFloat = 44
        static let rowPadding: CGFloat = 12
        static let rowGap: CGFloat = 12
        static let rowFont: CGFloat = 16
        static let iconBox: CGFloat = 28
        static let iconBoxRadius: CGFloat = 8
        static let icon: CGFloat = 20
        static let chevron: CGFloat = 16
        static let footFont: CGFloat = 13
        static let footInset: CGFloat = 8
        static let footTop: CGFloat = 6
        /// 13 pt at a line height of 1.4.
        static let footLineSpacing: CGFloat = 2.7
        /// The code: big, its eight characters spaced like a passcode.
        static let codeFont: CGFloat = 34
        static let codeTracking: CGFloat = 3
        static let codeTop: CGFloat = 26
        static let codeBottom: CGFloat = 22
        static let codeWords: CGFloat = 13
        static let codeWordsGap: CGFloat = 10
        /// The Recovery Key's field: the app's field, glass, one line high
        /// and growing to three as the key is typed.
        static let fieldHeight: CGFloat = Field.height
        static let fieldFont: CGFloat = 17
        /// The words' inset above and below inside the field: one line sits
        /// in the middle of the field's height.
        static let fieldTextInset: CGFloat = 14
        static let fieldLeading: CGFloat = 16
        static let fieldTrailing: CGFloat = 5
        static let fieldButton: CGFloat = 40
        static let fieldButtonIcon: CGFloat = 20
        /// Join Again: a capsule of glass.
        static let button: CGFloat = 50
        static let buttonFont: CGFloat = 17
        /// Pulled down by its head: past this, or flicked faster (pt/s), it
        /// goes (motion.md).
        static let pullCloses: CGFloat = 120
        static let flickCloses: CGFloat = 600
    }
}

extension Motion {
    /// The code and the Recovery Key's field taking each other's place in
    /// the join sheet: the way Move to Space swaps a menu's contents.
    static let joinSwap = easeOut("joinSwap", 0.2)
}

extension Ink {
    /// Settings' grouped ground, rgba(242, 242, 247, .98).
    static let grouped = AppearanceColors.color(0xF2F2F7, 0x1C1C1E, alpha: 0.98)
    /// A settings group's icon box, rgba(118, 118, 128, .12).
    static let iconBox = AppearanceColors.fill(0.12)
    /// A section's title, .55; a footer, .6; a chevron, .35.
    static let sectionTitle = AppearanceColors.gray(0.55)
    static let chevron = AppearanceColors.gray(0.35)
}
