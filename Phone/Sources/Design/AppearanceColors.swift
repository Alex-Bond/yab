import SwiftUI
import UIKit

/// Light values stay the prototype's. Dark surfaces rise from charcoal to
/// slightly lighter cards; text and actions keep their contrast on both.
enum AppearanceColors {
    static func ui(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1, darkAlpha: CGFloat? = nil) -> UIColor {
        UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            return solid(isDark ? dark : light, alpha: isDark ? darkAlpha ?? alpha : alpha)
        }
    }

    static func color(_ light: UInt32, _ dark: UInt32, alpha: Double = 1, darkAlpha: Double? = nil) -> Color {
        Color(uiColor: ui(light, dark, alpha: CGFloat(alpha), darkAlpha: darkAlpha.map { CGFloat($0) }))
    }

    static func color(light: RGB, dark: UInt32, alpha: Double = 1) -> Color {
        let rgb = UInt32(light.r) << 16 | UInt32(light.g) << 8 | UInt32(light.b)
        return color(rgb, dark, alpha: alpha)
    }

    static func gray(_ alpha: Double) -> Color { color(0x3C3C43, 0xEBEBF5, alpha: alpha) }
    static func fill(_ alpha: Double) -> Color {
        color(0x767680, 0x767680, alpha: alpha, darkAlpha: min(1, alpha * 2))
    }

    private static func solid(_ rgb: UInt32, alpha: CGFloat) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: alpha)
    }
}

extension Ink {
    /// Own screens and cards, never colors substituted into a website.
    static let ground = AppearanceColors.color(0xFFFFFF, 0x121214)
    static let surface = AppearanceColors.color(0xFFFFFF, 0x1C1C1E)
    static let card = AppearanceColors.color(0xFFFFFF, 0x2C2C2E)
    static let black = AppearanceColors.color(0x000000, 0xF2F2F7)
    static let outline = AppearanceColors.color(0x000000, 0xFFFFFF)
    /// Decorative shadows disappear on dark surfaces; Liquid Glass remains native.
    static let shadow = AppearanceColors.color(0x000000, 0x000000, darkAlpha: 0)
}
