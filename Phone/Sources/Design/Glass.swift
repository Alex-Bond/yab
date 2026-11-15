import SwiftUI

/// Liquid Glass for Yab's floating pieces, the prototype's `.g` (light) and
/// `.g.dark` plates. Always the system's glass (.glassEffect), never a blur
/// made by hand: it refracts what is under it, adapts its contrast, and
/// follows Reduce Transparency on its own.
enum GlassTone: Sendable {
    /// The prototype's .g: light glass, white at .58, ink on it. The white
    /// keeps it light over a dark page, where the system's glass would turn dark.
    case light
    /// The prototype's .g.dark: rgba(28, 28, 30, .55), white on it.
    case dark
    /// A space's own wash: its color at .62, as the plate wears it.
    case tinted(RGB)
    /// A private tab's plate: rgba(44, 42, 52, .78).
    case privateTab

    func glass(for scheme: ColorScheme) -> Glass {
        switch self {
        case .light: .regular.tint((scheme == .dark ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.55) : Color.white.opacity(0.58)))
        case .dark: .regular.tint(Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.55))
        case let .tinted(rgb): .regular.tint(scheme == .dark ? Ink.surface.opacity(0.62) : Color(rgb: rgb, opacity: 0.62))
        case .privateTab: .regular.tint(Ink.privateGlass.opacity(0.78))
        }
    }

    /// What is written on it.
    var ink: Color {
        switch self {
        case .light, .tinted: Ink.primary
        case .dark, .privateTab: Ink.onDark
        }
    }

    var isDark: Bool {
        switch self {
        case .dark, .privateTab: true
        case .light, .tinted: false
        }
    }
}

extension View {
    /// The view on a glass plate of `shape`. Interactive by default: it
    /// answers a touch the way the system's glass buttons do.
    func glassPlate<S: Shape>(_ shape: S, tone: GlassTone = .light, interactive: Bool = true) -> some View {
        modifier(GlassPlate(shape: shape, tone: tone, interactive: interactive))
    }

    /// A capsule plate: the plate, the field, the Now line, the toast.
    func glassCapsule(tone: GlassTone = .light, interactive: Bool = true) -> some View {
        glassPlate(Capsule(style: .continuous), tone: tone, interactive: interactive)
    }

    /// A round plate: back, the space, +, chats.
    func glassCircle(tone: GlassTone = .light, interactive: Bool = true) -> some View {
        glassPlate(Circle(), tone: tone, interactive: interactive)
    }
}

/// Dark/private plates keep their explicit style. Light and space plates
/// follow Appearance, including UIKit's own glass rendering and contrast.
private struct GlassPlate<S: Shape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let shape: S
    let tone: GlassTone
    let interactive: Bool

    func body(content: Content) -> some View {
        let scheme: ColorScheme = tone.isDark ? .dark : colorScheme
        content
            .foregroundStyle(tone.ink)
            .glassEffect(tone.glass(for: scheme).interactive(interactive), in: shape)
            .environment(\.colorScheme, scheme)
    }
}
