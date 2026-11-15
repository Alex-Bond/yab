import SwiftUI

/// The corner's own colors: dark in a light window and a dark one alike,
/// the way Arc's and Raycast's notices are. White on a white article was a
/// hairline and a shadow and little else, and read as part of the page; dark,
/// it is plainly the browser speaking, over any page. In a dark window, over
/// a dark site, a faint light edge keeps it from sinking in.
public enum HUD {
    public enum Surface { case dark, light, page }
    /// Its dark, for what flies to it or from it (MailMorph).
    public static let dark = NSColor(white: 0.114, alpha: 1)
    static let ground = Color(nsColor: dark)
    public static let ink = Color(nsColor: NSColor(white: 0.96, alpha: 1))
    public static let muted = Color(nsColor: NSColor(white: 0.82, alpha: 1))
    /// The rule between two parts of it.
    public static let rule = Color(nsColor: NSColor(white: 1, alpha: 0.16))
    static let edge = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.14)
            : NSColor(white: 0, alpha: 0.18)
    })

    /// The toast's dark Liquid Glass, and matching glass for page-colored
    /// agent cards or the light hand-back state. Solid grounds otherwise.
    public static func plate(_ corner: CGFloat, surface: Surface = .dark, space: NSColor? = nil) -> some View {
        plate(in: RoundedRectangle(cornerRadius: corner, style: .continuous), surface: surface, space: space)
    }

    /// The same tinted material for round floating controls.
    public static func plate<Plate: InsettableShape>(in shape: Plate, surface: Surface = .dark, space: NSColor? = nil) -> some View {
        HUDPlate(shape: shape, surface: surface, space: space)
    }

    /// What stands over a page: light glass over a dark one, the dark HUD
    /// otherwise. The dark HUD over X or YouTube was black on black, and
    /// Peek's buttons, the agent's pointer and its dock were hard to find.
    /// `page` is the page's own light (Tab.under), nil when not yet seen.
    public static func surface(over page: ColorScheme?) -> Surface { page == .dark ? .light : .dark }

    /// The other of light and dark: the agent's dock turns to it when you
    /// take over, whichever it stood in.
    public static func flipped(_ surface: Surface) -> Surface { surface == .light ? .dark : .light }

    /// Words on a plate of `surface`.
    public static func ink(on surface: Surface) -> Color { surface == .light ? lightInk : ink }
    /// Quieter words on a plate of `surface`.
    public static func muted(on surface: Surface) -> Color { surface == .light ? lightMuted : muted }
    /// The rule between two parts of a plate of `surface`.
    public static func rule(on surface: Surface) -> Color { surface == .light ? lightRule : rule }
    static let lightInk = Color(nsColor: NSColor(white: 0.08, alpha: 1))
    static let lightMuted = Color(nsColor: NSColor(white: 0.42, alpha: 1))
    static let lightRule = Color(nsColor: NSColor(white: 0, alpha: 0.1))

    /// The ground in a space's own color: the swatch's bright shade taken
    /// half way to black, plainly coral or sky, still dark enough for the
    /// light ink on every swatch alike.
    public static func ground(in space: NSColor) -> NSColor {
        (space.usingColorSpace(.sRGB) ?? space).blended(withFraction: 0.5, of: .black) ?? dark
    }
}

private struct HUDSurfaceKey: EnvironmentKey {
    static let defaultValue: HUD.Surface = .dark
}

extension EnvironmentValues {
    /// The plate a HUD's words stand on, for the views inside it to ink
    /// themselves by (Measure's dock and its sheet).
    public var hudSurface: HUD.Surface {
        get { self[HUDSurfaceKey.self] }
        set { self[HUDSurfaceKey.self] = newValue }
    }
}

/// The corner's ground. On glass, as the field's box has it: a material,
/// dark, that blurs the page into an even haze, and the glass over it
/// tinted with the dark ground, its rim and shadow the glass's own. The
/// page's colors come through warm under the words; over white it stays
/// dark enough for them. Without glass, the ground and edge, and a shadow
/// a little deeper than a light card's, so it stands off a busy page. On
/// the shape alone: a big blur redrawn every frame over a web page is
/// what makes a notice stutter.
private struct HUDPlate<Plate: InsettableShape>: View {
    let shape: Plate
    let surface: HUD.Surface
    /// The space's deep color, for a dark plate that wears it (the toast).
    let space: NSColor?
    @Environment(\.colorScheme) private var colorScheme

    /// How much of the dark ground tints the glass.
    static var tint: CGFloat { 0.6 }
    /// A space's color, held strong enough that the glass doesn't wash it
    /// back to gray.
    static var spaceTint: CGFloat { 0.9 }

    var body: some View {
        let ground: Color = surface == .dark ? space.map { Color(nsColor: HUD.ground(in: $0)) } ?? HUD.ground : surface == .light ? .white : Palette.ground
        if #available(macOS 26.0, *), LiquidGlass.wanted {
            ZStack {
                shape.fill(.regularMaterial)
                Color.clear.glassEffect(.regular.tint(ground.opacity(surface == .dark ? space == nil ? Self.tint : Self.spaceTint : 0.35)), in: shape)
            }
            .environment(\.colorScheme, surface == .dark ? .dark : surface == .light ? .light : colorScheme)
        } else {
            shape
                .fill(ground)
                .shadow(color: .black.opacity(surface == .dark ? 0.22 : 0.14), radius: surface == .dark ? 7 : 14, y: surface == .dark ? 3 : 4) // design: the HUD fallback keeps its small shadow on the shape when Liquid Glass is unavailable
                .overlay(shape.strokeBorder(surface == .dark ? HUD.edge : surface == .light ? .black.opacity(0.1) : Palette.hairline, lineWidth: 1))
        }
    }
}
