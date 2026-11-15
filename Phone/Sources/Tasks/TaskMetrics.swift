import CoreGraphics
import SwiftUI

/// The sizes of a task's screens, the prototype's (Phone/Reference/digest/
/// sizes.md, measured with proto-measure on chat.9, yes.1...yes.5, out.*).
/// Kept beside Metrics' own sheets for the code and the yes (Metrics.Code,
/// Metrics.Consent), in this folder so the tasks branch never edits the
/// skeleton's file.
extension Metrics {
    /// A task's chat, at full height (chat.9).
    enum TaskChat {
        static let top: CGFloat = Sheet.fullTop
        static let grabTop: CGFloat = 7
        static let headTop: CGFloat = 12
        static let head: CGFloat = 92
        /// History and ⋯: 44 round, 16 from the sheet's sides, 24 into the head.
        static let roundButton: CGFloat = 44
        static let roundInset: CGFloat = 16
        static let roundTop: CGFloat = 24
        /// Who: the face in its 30 circle, 6 under the head's top; title 15, line 12.
        static let whoTop: CGFloat = 16.8
        static let face: CGFloat = 30
        static let faceGlyph: CGFloat = 20
        static let whoGap: CGFloat = 2
        static let title: CGFloat = 15
        static let line: CGFloat = 12
        /// The body: 20 from the screen, 4 under the head, turns 12 apart.
        static let bodyTop: CGFloat = 4
        static let bodySide: CGFloat = 20
        static let turnGap: CGFloat = 12
        /// The field at the foot: 46 high, 20 from the sides, 30 over the bottom.
        static let field: CGFloat = 46
        static let fieldSide: CGFloat = 20
        static let fieldBottom: CGFloat = 30
        static let fieldLeading: CGFloat = 16
        static let fieldTrailing: CGFloat = 6
        static let fieldFont: CGFloat = 16
        static let send: CGFloat = 34
        static let mic: CGFloat = 19
        /// Over the keyboard, the field stands 10 above it.
        static let fieldOverKeyboard: CGFloat = 12
        /// The page behind a full sheet: the scrim from .18 to .32.
        static let scrimFrom: Double = 0.18
        static let scrimTo: Double = 0.32
        /// A swipe down past this, or this fast, folds it into the Now line:
        /// the AI sheet's 90 and 600 (screens-chats.md).
        static let foldDistance: CGFloat = 90
        static let foldVelocity: CGFloat = 600
        static let bodyBottom: CGFloat = 10
        /// The field: white .9, a .08 hairline, a .18 shadow 7 soft 4 down.
        static let fieldWhite: Double = 0.9
        static let fieldStroke: Double = 0.08
        static let fieldShadow: Double = 0.18
        static let fieldShadowRadius: CGFloat = 7
        static let fieldShadowY: CGFloat = 4
        static let hairline: CGFloat = 0.5
    }

    /// The steps in words (.b-st): rows 36 high, 2 apart; favicon 18, 10 to the words.
    enum Steps {
        static let row: CGFloat = 36
        static let gap: CGFloat = 2
        static let icon: CGFloat = 18
        static let iconGap: CGFloat = 10
        static let font: CGFloat = 15
        static let check: CGFloat = 16
        static let dot: CGFloat = 8
        static let dotTrailing: CGFloat = 4
        /// Retry in a failed step: an ink capsule 30 high, 44 to hit.
        static let retry: CGFloat = 30
        static let retryPadding: CGFloat = 12
        static let retryFont: CGFloat = 13.5
    }

    /// Its tabs in a folder on the Mac, as small sketches (.b-th).
    enum Thumbs {
        static let width: CGFloat = 112
        static let sketch: CGFloat = 72
        static let radius: CGFloat = 10
        static let gap: CGFloat = 8
        static let labelGap: CGFloat = 5
        static let padding: CGFloat = 8
        static let line: CGFloat = 8
        static let lineGap: CGFloat = 5
        static let seat: CGFloat = 30
        static let icon: CGFloat = 14
        static let font: CGFloat = 11.5
        static let headFont: CGFloat = 13
        static let headInset: CGFloat = 6
        static let headGap: CGFloat = 6
    }

    /// Done: the result in a block (.b-done).
    enum Done {
        static let radius: CGFloat = 18
        static let padding: CGFloat = 14
        static let gap: CGFloat = 8
        static let font: CGFloat = 15
        static let lineHeight: CGFloat = 1.45
    }

    /// The code's sheet (yes.1): what Metrics.Code doesn't say.
    enum CodeSheet {
        static let side: CGFloat = Edge.sheet
        static let padding: CGFloat = 12
        static let bottomPadding: CGFloat = 16
        static let gap: CGFloat = 14
        static let grabTop: CGFloat = 7
        static let grabBottom: CGFloat = 2
        /// White .98 on a .15 shadow, 15 soft, 6 up.
        static let white: Double = 0.98
        static let shadow: Double = 0.15
        static let shadowRadius: CGFloat = 15
        static let shadowY: CGFloat = -6
        static let hairline: CGFloat = 0.5
        /// The page under a sheet for the person: .2 dark.
        static let scrim: Double = 0.2
        /// With no origin it comes up from 105 % of its height below, and
        /// goes down 60 % fading (motion.md, "Code, yes").
        static let riseDistance: CGFloat = 1.05
        static let dropDistance: CGFloat = 0.6
        /// The head's text column: 12 past the 30 icon.
        static let headGap: CGFloat = 12
        static let titleGap: CGFloat = 3
        static let noteIcon: CGFloat = 15
        static let noteGap: CGFloat = 8
        static let noteFont: CGFloat = 13
        /// The number pad the prototype draws, for pictures only (see CodeSheet).
        static let padSide: CGFloat = 6
        static let padTop: CGFloat = 7
        static let quickTypeLabel: CGFloat = 11.5
        static let quickTypeCode: CGFloat = 17
        static let keyLetters: CGFloat = 9.5
        /// The code back in the line after the boxes fill.
        static let settles: TimeInterval = 0.45
    }

    /// The yes's sheet (yes.3).
    enum ConsentSheet {
        static let side: CGFloat = Edge.sheet
        static let bottom: CGFloat = Edge.sheet
        static let radius: CGFloat = Sheet.radius
        /// White .97 over the blur, a .18 shadow 20 soft, 10 up.
        static let white: Double = 0.97
        static let shadow: Double = 0.18
        static let shadowRadius: CGFloat = 20
        static let shadowY: CGFloat = -10
        static let hairline: CGFloat = 0.5
        static let padding: CGFloat = 12
        static let bottomPadding: CGFloat = 20
        static let gap: CGFloat = 12
        static let grabTop: CGFloat = 7
        static let grabBottom: CGFloat = 2
        static let factFont: CGFloat = 14.5
        static let factPadding = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        static let factGap: CGFloat = 10
        static let payIcon: CGFloat = 20
        static let payFont: CGFloat = 17
        static let payGap: CGFloat = 8
        static let notNowFont: CGFloat = 16
    }

    /// The Face ID panel: 150 square, dark, the glyph 66 over the word.
    enum FaceIDPanel {
        static let gap: CGFloat = 12
        static let word: CGFloat = 15
        /// How long it looks, and how long "Signed" stays.
        static let looks: TimeInterval = 0.65
        static let signed: TimeInterval = 0.42
        static let fromScale: CGFloat = 0.9
    }
}

/// The tasks' colors, the prototype's.
enum TaskInk {
    /// The grabber: rgba(60, 60, 67, .3).
    static let grabber = AppearanceColors.gray(0.3)
    /// A quiet note's glyph: #6E6E73.
    static let quiet = AppearanceColors.color(0x6E6E73, 0xB8B8C2)
    /// What needs the person: #C2410C.
    static let needs = ChatInk.needs
    /// The ink of a primary button: #161615.
    static let ink = AppearanceColors.color(0x161615, 0x3A3A3C)
    /// The code's boxes and the facts' ground: rgba(118, 118, 128, .1 / .08).
    static let box = AppearanceColors.fill(0.1)
    static let facts = AppearanceColors.fill(0.08)
    /// A hairline between facts: rgba(60, 60, 67, .14).
    static let hairline = AppearanceColors.gray(0.14)
    /// The number pad the prototype draws: rgba(209, 212, 219, .98).
    static let pad = AppearanceColors.color(0xD1D4DB, 0x121214, alpha: 0.98)
    /// A done step's tick: #24764A.
    static let tick = ChatInk.tick
    /// A block's small head ("Done", "Its tabs…"): rgba(60, 60, 67, .62); a
    /// tab sketch's title .75.
    static let label = AppearanceColors.gray(0.62)
    static let thumbLabel = AppearanceColors.gray(0.75)
    /// The result's block: #F6F6F3; a tab's sketch: #F4F6F8 with #DDE3EA lines.
    static let doneGround = AppearanceColors.color(0xF6F6F3, 0x2C2C2E)
    static let thumbGround = AppearanceColors.color(0xF4F6F8, 0x2C2C2E)
    static let thumbInk = AppearanceColors.color(0xDDE3EA, 0x54545B)
    /// Face ID's square: rgba(28, 28, 30, .84); signed, #34C759.
    static let faceID = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.84)
    static let signed = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)
}
