import SwiftUI
import UIKit

/// The app's ink for what its extensions draw too (the share sheet's card,
/// the widgets), which can't reach the app's Design. The values are Ink's
/// own (Design/Glyph.swift, Field/FieldLayer.swift), light and dark; the
/// app's pictures of them draw with these as well, so they can't drift apart.
enum EntranceLook {
    /// Ink.primary: words and glyphs.
    static let primary = color(0x1C1C1E, 0xF2F2F7)
    /// Ink.tertiary: a line under a title.
    static let secondary = color(0x3C3C43, 0xEBEBF5, alpha: 0.6)
    /// Ink.fieldGlyph: the field's magnifier.
    static let glyph = color(0x3C3C43, 0xEBEBF5, alpha: 0.55)
    /// The field's placeholder (Metrics.Field.placeholder).
    static let placeholder = color(0x3C3C43, 0xEBEBF5, alpha: 0.45, darkAlpha: 0.65)
    /// Ink.fill: New Tab's field, a quiet capsule.
    static let fill = color(0x767680, 0x767680, alpha: 0.12, darkAlpha: 0.24)
    /// Ink.button: Keep's dark capsule.
    static let button = color(0x161615, 0x3A3A3C)
    /// Ink.surface: own cards and sheets.
    static let surface = color(0xFFFFFF, 0x1C1C1E)
    /// Ink.done: said done.
    static let done = color(0x1E6B3A, 0x79D99B)

    static func color(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1, darkAlpha: CGFloat? = nil) -> Color {
        Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let rgb = isDark ? dark : light
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: isDark ? darkAlpha ?? alpha : alpha)
        })
    }
}

/// One of the app's glyphs (Design/Glyphs.xcassets, which the extensions
/// carry too), on its 24-point grid at `size`, in the foreground style.
struct EntranceGlyph: View {
    let name: String
    var size: CGFloat = 20

    init(_ name: String, size: CGFloat = 20) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Yab's mark (Design/Art.xcassets), as the Live Activity draws it.
struct EntranceMark: View {
    var size: CGFloat = 28

    var body: some View {
        Image("YabMark")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
