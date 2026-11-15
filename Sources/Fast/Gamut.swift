import AppKit
import SwiftUI

/// A swatch as a dot of its color as the window would wear it now, in
/// Appearance, a space's page in Settings and the tray. Your own is every
/// hue until it is the one picked; then its color inside the rainbow, which
/// stays round its edge to say it can be changed.
struct SwatchDot: View {
    let swatch: Swatch
    /// Your own is the swatch picked.
    let ownPicked: Bool
    let custom: NSColor
    let dark: Bool
    var rim = Color.primary.opacity(0.1)

    var body: some View {
        let color = Color(nsColor: swatch.color(dark: dark, custom: custom))
        if swatch == .plain {
            PlainDot()
        } else if swatch == .custom {
            ZStack {
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                if ownPicked { Circle().fill(color).padding(3) } // design: the picked color inside the rainbow's ring
            }
        } else {
            Circle().fill(color).overlay(Circle().strokeBorder(rim, lineWidth: 1))
        }
    }
}

/// What sRGB can show of OKLCH.
enum Gamut {
    /// Linear sRGB for an OKLCH color, unclamped, to tell whether it fits.
    static func linear(_ L: CGFloat, _ C: CGFloat, _ h: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let a = C * cos(h), b = C * sin(h)
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    static func srgb(_ L: CGFloat, _ C: CGFloat, _ h: CGFloat) -> (Double, Double, Double) {
        func gamma(_ x: CGFloat) -> Double {
            let x = min(1, max(0, x))
            return Double(x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055)
        }
        let (r, g, b) = linear(L, C, h)
        return (gamma(r), gamma(g), gamma(b))
    }

    /// The most color this lightness and hue can have on screen. Strict at
    /// the edges: a tolerance of even a ten-thousandth let black hold a
    /// tenth of a chroma, its channels being cubes too small to fail it,
    /// so a field at black printed colors no black can have.
    static func chroma(_ L: CGFloat, _ h: CGFloat) -> CGFloat {
        var lo: CGFloat = 0, hi: CGFloat = 0.37
        for _ in 0..<14 {
            let mid = (lo + hi) / 2
            let (r, g, b) = linear(L, mid, h)
            let fits = [r, g, b].allSatisfy { $0 >= -1e-12 && $0 <= 1 + 1e-12 }
            if fits { lo = mid } else { hi = mid }
        }
        return lo
    }
}
