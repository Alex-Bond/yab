import SwiftUI

/// Attach glass to the content it surrounds, so its words stay in front
/// of the system's refraction instead of being sampled as a backdrop.
struct ChatGlass<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S
    var enabled = true

    func body(content: Content) -> some View {
        content
            .background(reduceTransparency && enabled ? Ink.surface : .clear, in: shape)
            .glassEffect(enabled && !reduceTransparency ? .regular : .identity, in: shape)
    }
}

extension View {
    func chatGlass<S: Shape>(in shape: S, enabled: Bool = true) -> some View {
        modifier(ChatGlass(shape: shape, enabled: enabled))
    }
}

/// The same system glyphs used by the Mac's Cmd+J and Mail.
struct ChatGlyph: View {
    let glyph: GlyphName?
    /// A menu's mark: the Mac's drawing for the same action.
    var menu: MacGlyph? = nil
    var size: CGFloat = 20
    var color: Color = Ink.primary

    init(_ glyph: GlyphName, size: CGFloat = 20, color: Color = Ink.primary) {
        self.glyph = glyph
        self.size = size
        self.color = color
    }

    init(mac: MacGlyph, size: CGFloat = 20, color: Color = Ink.primary) {
        self.glyph = nil
        self.menu = mac
        self.size = size
        self.color = color
    }

    var body: some View {
        Group {
            if let mac {
                // The Mac's own drawings where the prototype's differ.
                Image(mac)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: size * 1.2, height: size * 1.2)
                    .foregroundStyle(color)
                    .frame(width: size, height: size)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .medium))
                    .frame(width: size, height: size)
                    .foregroundStyle(color)
            } else if let glyph {
                Glyph(glyph, size: size, color: color)
            }
        }
        .accessibilityHidden(true)
    }

    private var mac: String? {
        if let menu { return menu.rawValue }
        return switch glyph {
        case .thumbtack: "MacPin"
        case .editBig: "MacSquareAndPencil"
        case .textSize: "MacPencil"
        case .chatBubble7: "MacBubble"
        case .squareBehindSquare1: "MacDocOnDoc"
        case .archive: "MacArchivebox"
        case .agent: "MacInfoCircle"
        default: nil
        }
    }

    private var symbol: String? {
        switch glyph {
        case .crossSmall, .crossMedium, .crossLarge: "xmark"
        case .history, .clock: "clock"
        case .chevronLeft: "chevron.left"
        case .chevronRight: "chevron.right"
        case .dotGrid1x3Horizontal: "ellipsis"
        case .thumbtack: "pin"
        case .textSize: "pencil"
        case .squareBehindSquare1: "doc.on.doc"
        case .agent: "info.circle"
        default: nil
        }
    }
}
