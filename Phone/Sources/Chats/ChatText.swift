import SwiftUI
import UIKit

/// The chats' colors, the prototype's own (screens.md "Colors").
enum ChatInk {
    /// Question bubbles, send, ink capsules: #161615.
    static let ink = AppearanceColors.color(0x161615, 0x3A3A3C)
    /// rgba(60, 60, 67, a): the system's gray at the prototype's strengths.
    static func gray(_ a: Double) -> Color { AppearanceColors.gray(a) }
    /// rgba(118, 118, 128, a): fills of fields, pills, capsules.
    static func fill(_ a: Double) -> Color { AppearanceColors.fill(a) }
    /// The chats' sheet: rgba(250, 250, 252, .98); in dark, Messages' black.
    static let list = AppearanceColors.color(0xFAFAFC, 0x000000)
    /// Unread uses the same system primary ink as the column count.
    static let newAnswer = Ink.newAnswer
    /// A task that needs you, in a row: #C2410C.
    static let needs = AppearanceColors.color(0xC2410C, 0xFFAE83)
    /// A done step's tick: #24764A.
    static let tick = AppearanceColors.color(0x24764A, 0x79D99B)
    /// Swipe capsules: Pin, Unread, Archive.
    static let pin = Color(red: 1, green: 0x9F / 255, blue: 0x0A / 255)
    static let unread = Ink.unread
    static let archive = Ink.archive
    /// Steps' words: #3a3a3c.
    static let step = Ink.rowGlyph
    /// The Mac's ink, a near black and a near white (its Palette.ink, 0.09
    /// and 0.93): the agent's bubbles and its typing dots are drawn in it at
    /// a strength, so they read on dark as on the Mac.
    static let agentUI = AppearanceColors.ui(0x171717, 0xEDEDED)
    static let agent = Color(uiColor: agentUI)
    /// The agent's bubbles, Messages' gray (on the black ground in dark);
    /// code in an answer, fainter.
    static let agentBubble = AppearanceColors.color(0xE9E9EB, 0x262628)
    static let agentCode = AppearanceColors.color(0xF2F2F4, 0x1C1C1E)
    /// The typing bubble's dots.
    static let typingDots: CGFloat = 0.55
    /// Words still coming (FreshWords): the newest at a third, the stretch
    /// before at two thirds.
    static let freshest = Ink.primary.opacity(0.33)
    static let fresher = Ink.primary.opacity(0.66)
}

extension View {
    /// CSS's line-height on SwiftUI text: the leading between lines, and half
    /// of it above the first line and below the last, so blocks stand as tall
    /// as the prototype's.
    func cssLineHeight(_ multiple: CGFloat, size: CGFloat, weight: UIFont.Weight = .regular) -> some View {
        let natural = UIFont.systemFont(ofSize: size, weight: weight).lineHeight
        let leading = max(0, size * multiple - natural)
        return lineSpacing(leading).padding(.vertical, leading / 2)
    }

    /// Letter spacing in em, as the prototype writes it.
    func em(_ em: CGFloat, size: CGFloat) -> some View { tracking(em * size) }
}

enum Markup {
    /// An answer's words with their <b>bold</b> runs, everything else plain.
    static func attributed(_ text: String, size: CGFloat, bold: Font.Weight = .semibold) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(text)
        while let open = rest.range(of: "<b>") {
            out += AttributedString(clean(rest[..<open.lowerBound]))
            rest = rest[open.upperBound...]
            let close = rest.range(of: "</b>") ?? (rest.endIndex..<rest.endIndex)
            var run = AttributedString(clean(rest[..<close.lowerBound]))
            run.font = .system(size: size, weight: bold)
            out += run
            rest = rest[close.upperBound...]
        }
        out += AttributedString(clean(rest))
        return out
    }

    private static func clean(_ text: Substring) -> String {
        String(text).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    /// A string's width in the system font, for laying out tables as CSS does.
    static func width(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: weight)]).width
    }
}
