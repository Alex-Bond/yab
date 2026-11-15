// design: file, a page being read, drawn in miniature at its own sizes
import SwiftUI

// Reading mode shown before an article is opened: the page at the head of
// Settings › Reading Mode, in place of the book, and the small one on
// Websites' Reading mode row, as App icon's row wears the icon. Both read
// the same prefs as the page does, so a theme, its edits, the light, the
// size and a wide page show here as they will there.

/// A short article set the way reading mode sets one, its picture the
/// theme's ink faint.
struct ReaderSample: View {
    let look: ReaderLook
    let weight: Font.Weight
    let colors: ReaderColors
    let wide: Bool
    /// The page's points to the picture's.
    var scale: CGFloat = 0.62

    var body: some View {
        let size = CGFloat(look.points) * scale
        let face = look.bold ? .bold : weight
        let spacing = size * CGFloat(look.line - 1)
        let tracking = size * CGFloat(look.letter) / 100
        GeometryReader { box in
            let share = min((wide ? 0.9 : 0.72) * (1 - CGFloat(look.margins) / 100), 0.96)
            VStack(alignment: .leading, spacing: size * 0.55) {
                Text("ENGINEERING")
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .tracking(size * 0.08)
                    .opacity(0.55)
                Text("The bridge that hums at night")
                    .font(look.font.font(size: size * 1.55, weight: .bold))
                Text("Lena Marsh \u{00B7} 6 min read")
                    .font(look.font.font(size: size * 0.7, weight: face))
                    .opacity(0.6)
                Text("Engineers in Lisbon spent two winters chasing a low note that came from the deck after midnight. The answer was the wind, but not the way anyone expected.")
                    .font(look.font.font(size: size, weight: face))
                    .lineSpacing(spacing)
                    .tracking(tracking)
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(colors.ink.opacity(0.1))
                    .frame(height: size * 5)
                Text("Above eleven meters a second, air peels off the railings in small spirals, each one pushing the steel a fraction of a millimeter. Most bridges shrug it off. This one sang.")
                    .font(look.font.font(size: size, weight: face))
                    .lineSpacing(spacing)
                    .tracking(tracking)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: box.size.width * share)
            .padding(.top, size * 1.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(colors.ink)
        .background(colors.ground)
    }
}

/// Reading Mode's head: the page in the theme in front, or in the one the
/// pointer is over among the tiles, trying it on.
struct ReaderPreviewPage: View {
    let prefs: ReaderPrefs
    let theme: ReaderThemeID
    let dark: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.surface, style: .continuous)
        ReaderSample(look: prefs.look(theme), weight: theme.spec.fontWeight,
                     colors: prefs.colors(theme, dark: dark), wide: prefs.wide)
            .frame(width: 400, height: 220)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.gray.opacity(0.25), lineWidth: 1))
            .animation(Motion.settle, value: theme)
            .animation(Motion.settle, value: prefs)
            .animation(Motion.settle, value: dark)
            .accessibilityElement()
            .accessibilityLabel("A page in \(theme.spec.name)")
    }
}

/// The theme in use, small, on Websites' Reading mode row: its ground, an
/// Aa in its face and two lines of its ink.
struct ReaderThumb: View {
    let prefs: ReaderPrefs
    let dark: Bool

    var body: some View {
        let spec = prefs.spec
        let look = prefs.look
        let colors = prefs.colors(prefs.theme, dark: dark)
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        VStack(alignment: .leading, spacing: 2) {
            Text("Aa").font(look.font.font(size: 10, weight: look.bold ? .bold : spec.fontWeight))
            Capsule().fill(colors.ink.opacity(0.35)).frame(width: 20, height: 2)
            Capsule().fill(colors.ink.opacity(0.35)).frame(width: 14, height: 2)
        }
        .foregroundStyle(colors.ink)
        .padding(.leading, 5)
        .frame(width: 34, height: 24, alignment: .leading)
        .background(colors.ground, in: shape)
        .overlay(shape.strokeBorder(Color.gray.opacity(0.25), lineWidth: 1))
        .accessibilityHidden(true)
    }
}
