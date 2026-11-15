import SwiftUI

// One button, everywhere yab draws its own, in the tab's shape: a rounded
// rectangle at Radius.control, so a button and a tab are one family. Three
// sizes and five kinds. Primary is ink, the one thing you came to press;
// secondary a wash of ink; quiet only words until the pointer is on them;
// danger the red of what cannot be undone; raised the ground under a
// hairline, for a button standing on a lit row, where a wash on the wash
// is lost. A page drawn in HTML, an agent task's answer, takes the same
// from `ButtonCSS`, so a Save is the same Save in a panel, a page and a pill.
//
// Onboarding's buttons are glass, large: Liquid Glass in the window's own
// look, light in the light and dark in the dark. The system's alerts
// stay the system's.

public enum ButtonKind {
    case primary, secondary, quiet, danger, raised
    /// Liquid Glass in the window's own look, its words the ink; a wash of
    /// the ink where there is no glass.
    case glass
}

/// An icon on its own: a square as tall as the size, the control's
/// corner, or a circle, with no room at its sides.
public enum ButtonIcon { case square, round }

public enum ButtonSize {
    /// 24, inside a row or a pill: Save, Bring in, Copy.
    case small
    /// 28, the end of a row, a page's own actions.
    case regular
    /// 36, the one button of a screen.
    case large
    /// 48, round, a word under it: a screen's own actions in a row, as a
    /// contact's Call and Mute (a chat's Keep, Copy, Archive).
    case hero

    public var height: CGFloat {
        switch self {
        case .small: 24
        case .regular: 28
        case .large: 36
        case .hero: 48
        }
    }
    public var padding: CGFloat {
        switch self {
        case .small: 10
        case .regular: 13
        case .large: 20
        case .hero: 24
        }
    }
    /// Pressed, every size gives up about 1.5 pt of its height, so a small
    /// button answers the finger as plainly as a large one.
    public var pressed: CGFloat { self == .small ? 0.94 : self == .regular ? 0.95 : 0.96 }
    /// How far a key's plate stands in from the button's edges, top,
    /// bottom and trailing alike (KeyPlate).
    public var keyInset: CGFloat { self == .large || self == .hero ? 8 : 4 }
    /// Half of what the leading padding has over the 6 before the keys:
    /// moved into that gap, so the words stand in the middle of their room.
    public var keyLead: CGFloat { (padding - 6) / 2 }
    public var font: Font {
        self == .small ? .system(size: 11.5) : self == .regular ? .system(size: 12.5) : .system(size: 13, weight: .semibold)
    }
    /// The words' size, which the keys beside them take (KeyGlyphs).
    public var wordSize: CGFloat { self == .small ? 11.5 : self == .regular ? 12.5 : 13 }
}

public struct YabButtonStyle: ButtonStyle {
    var kind: ButtonKind = .secondary
    var size: ButtonSize = .regular
    /// The words in another color, a Remove in red, on a secondary or quiet;
    /// on a primary, its ground (the Mac's accent, the chat's Send and Done)
    /// under white words.
    var tint: Color? = nil
    /// Toasts and agent docks use the same button geometry over their own
    /// dark or light glass, independently of the window's appearance.
    var surface: HUD.Surface = .page
    /// Only floating notices opt in: a translucent ink layer lets their
    /// existing glass plate show through without another backdrop sample.
    var glass: Bool = false
    /// Only an icon: the button as wide as it is tall.
    var icon: ButtonIcon? = nil
    /// Round at both ends, for a button inside a round field (the chat's
    /// one line), concentric with it.
    var capsule = false
    /// A button inset in a field follows the field's corner less its gap.
    var cornerRadius: CGFloat = Radius.control

    public func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, kind: kind, size: size, tint: tint, surface: surface, glass: glass, icon: icon, capsule: capsule, cornerRadius: cornerRadius)
    }

    private struct Face: View {
        let configuration: Configuration
        let kind: ButtonKind
        let size: ButtonSize
        let tint: Color?
        let surface: HUD.Surface
        let glass: Bool
        let icon: ButtonIcon?
        let capsule: Bool
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        private var pressed: Bool { configuration.isPressed }

        /// The room at a button's sides: none for an icon alone.
        private var side: CGFloat { icon == nil ? size.padding : 0 }
        /// An icon's button is as wide as it is tall.
        private var wide: CGFloat? { icon == nil ? nil : size.height }

        /// The control's corner, or a circle for a round icon.
        private var face: AnyShape {
            icon == .round ? AnyShape(Circle()) : capsule ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }

        var body: some View {
            configuration.label
                .font(size.font)
                .lineLimit(1)
                .foregroundStyle(ink)
                .environment(\.keyPlate, KeyPlate(height: size.height - 2 * size.keyInset, pull: size.padding - size.keyInset, lead: size.keyLead))
                .padding(.trailing, side)
                .modifier(LeadingRoom(padding: side))
                .frame(minWidth: wide, minHeight: size.height)
                .background {
                    let shape = face
                    if kind == .glass, LiquidGlass.wanted, #available(macOS 26.0, *) {
                        Color.clear.glassEffect(.regular.interactive(), in: shape)
                            .overlay(shape.fill(surfaceInk.opacity(pressed ? 0.08 : hovering ? 0.04 : 0)))
                    } else if kind == .primary && glass && LiquidGlass.wanted {
                        shape.fill(surfaceInk.opacity(pressed ? 0.7 : hovering ? 0.78 : 0.86))
                            .overlay(shape.stroke(ground.opacity(0.16), lineWidth: 1).padding(0.5))
                    } else {
                        shape.fill(fill)
                    }
                }
                .overlay {
                    // The hairline round the face's own shape: a round icon's
                    // is a circle, as Change Icon's by its search.
                    if kind == .raised {
                        if icon == .round {
                            Circle().strokeBorder(hairline, lineWidth: 1)
                        } else if capsule {
                            Capsule().strokeBorder(hairline, lineWidth: 1)
                        } else {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(hairline, lineWidth: 1)
                        }
                    }
                }
                .contentShape(face)
                .scaleEffect(pressed && !reduceMotion ? size.pressed : 1)
                .animation(pressed ? Press.down : Press.up, value: pressed)
                .opacity(enabled ? 1 : 0.72)
                .onHover { hovering = $0 && enabled }
                .animation(Motion.quick, value: hovering)
        }

        private var ink: Color {
            switch kind {
            case .primary: return tint == nil ? ground : .white
            // White on the red in both looks, as the system's destructive
            // buttons are: the dark window's near-black on a red read muddy.
            case .danger: return .white
            case .secondary, .raised, .glass: return tint ?? surfaceInk
            case .quiet: return tint ?? (hovering || pressed ? surfaceInk : muted)
            }
        }

        private var surfaceInk: Color {
            switch surface {
            case .dark: HUD.ink
            case .light: .black.opacity(0.92)
            case .page: Palette.ink
            }
        }

        private var ground: Color {
            switch surface {
            case .dark: HUD.ground
            case .light: .white
            case .page: Palette.ground
            }
        }

        private var muted: Color {
            switch surface {
            case .dark: HUD.muted
            case .light: .black.opacity(0.55)
            case .page: Palette.muted
            }
        }

        private var hairline: Color {
            switch surface {
            case .dark: HUD.edge
            case .light: .black.opacity(0.1)
            case .page: Palette.hairline
            }
        }

        /// A wash of the ink rather than a gray of its own, so it reads the
        /// same on a page, a Settings card or a colored strip.
        private var fill: Color {
            switch kind {
            case .primary: return (tint ?? surfaceInk).opacity(pressed ? 0.75 : hovering ? 0.85 : 1)
            case .danger:
                return Color(red: pressed ? 0.56 : hovering ? 0.62 : 0.68, green: 0.12, blue: 0.10)
            case .secondary, .glass: return surfaceInk.opacity(pressed ? 0.15 : hovering ? 0.11 : 0.07)
            case .quiet: return surfaceInk.opacity(pressed ? 0.1 : hovering ? 0.06 : 0)
            case .raised: return pressed ? surfaceInk.opacity(0.11) : hovering ? (surface == .page ? Palette.wash : surfaceInk.opacity(0.06)) : ground
            }
        }
    }
}

/// A press goes down on a short spring with no give and comes back on a
/// longer one: fast enough to answer the finger, never a jump from one size
/// to the other. Both are springs, so a click let go halfway down turns
/// round where it is instead of snapping. Buttons are pressed all day (P10),
/// so neither gives. Onboarding's Continue, pressed once a chapter, may give
/// a little on the way back. A key that presses a button moves nothing.
public enum Press {
    public static let down = Animation.spring(duration: 0.16, bounce: 0)
    public static let up = Animation.spring(duration: 0.28, bounce: 0)
    static let upWithGive = Animation.spring(duration: 0.38, bounce: 0.3)
}

/// For a button that draws its own face, onboarding's two, the same
/// press: down at once, back on a spring.
public struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var up: Animation = Press.up
    /// What the press shrinks towards: its middle, or for a control held
    /// against one edge, that edge, so the edge stays put under the pointer.
    var anchor: UnitPoint = .center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(scale: CGFloat = 0.96, up: Animation = Press.up, anchor: UnitPoint = .center) {
        self.scale = scale
        self.up = up
        self.anchor = anchor
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1, anchor: anchor)
            .animation(configuration.isPressed ? Press.down : up, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == YabButtonStyle {
    public static func yab(_ kind: ButtonKind = .secondary, _ size: ButtonSize = .regular,
                    tint: Color? = nil, surface: HUD.Surface = .page,
                    glass: Bool = false, icon: ButtonIcon? = nil, capsule: Bool = false,
                    cornerRadius: CGFloat = Radius.control) -> YabButtonStyle {
        YabButtonStyle(kind: kind, size: size, tint: tint, surface: surface, glass: glass, icon: icon, capsule: capsule, cornerRadius: cornerRadius)
    }
}

/// The same button for the pages drawn in HTML. Each page keeps its own
/// colors (--ink, --ground, --wash, --hover, --muted, --bad) and takes the
/// shape from here: `btn`, then `primary`, `quiet`, `danger` or `raised`, then `sm` or
/// `lg`. `inline` is a link inside a sentence, not a button.
public enum ButtonCSS {
    /// The one red for what can't be taken back, a button's fill or a
    /// word: the system's own, bright in both looks, and the same red the
    /// rest of the app's warnings already use (Color.red). The pages set
    /// theirs, --bad, to it (`bad`).
    public static let danger = Color(nsColor: .systemRed)
    /// The same red for the pages drawn in HTML, light and dark.
    static let bad = (light: "#ff3b30", dark: "#ff453a")

    public static let css = """
    .btn { display: inline-flex; align-items: center; justify-content: center; gap: 6px; height: 28px; padding: 0 13px; border-radius: 8px; background: var(--wash); color: var(--ink); font-size: 12.5px; line-height: 1; white-space: nowrap; flex: none; }
    .btn, .pressable { --press: .95; transition: background .12s, color .12s, transform .28s cubic-bezier(.2, .8, .2, 1); }
    .btn:active, .pressable:active { transform: scale(var(--press)); transition: background .04s linear, color .04s linear, transform .16s cubic-bezier(.2, .8, .2, 1); }
    .btn.sm { --press: .94; } .btn.lg { --press: .96; }
    @media (prefers-reduced-motion: reduce) { .btn:active, .pressable:active { transform: none; } }
    .btn:hover { background: color-mix(in srgb, var(--wash), var(--ink) 6%); }
    .btn:active { background: color-mix(in srgb, var(--wash), var(--ink) 11%); }
    .btn:focus-visible { outline: 2px solid var(--ink); outline-offset: 2px; }
    .btn[disabled] { opacity: .45; pointer-events: none; }
    .btn.primary { background: var(--ink); color: var(--ground); }
    .btn.primary:hover { background: color-mix(in srgb, var(--ink) 85%, var(--ground)); }
    .btn.primary:active { background: color-mix(in srgb, var(--ink) 75%, var(--ground)); }
    .btn.danger { background: var(--bad, #ff3b30); color: #fff; }
    .btn.danger:hover { background: color-mix(in srgb, var(--bad, #ff3b30) 88%, var(--ground)); }
    .btn.danger:active { background: color-mix(in srgb, var(--bad, #ff3b30) 78%, var(--ground)); }
    .btn.raised { background: var(--ground); box-shadow: 0 0 0 1px var(--hairline); }
    .btn.raised:hover { background: var(--wash); }
    .btn.raised:active { background: color-mix(in srgb, var(--wash), var(--ink) 11%); }
    .btn.quiet { background: none; color: var(--muted); }
    .btn.quiet:hover { background: var(--hover); color: var(--ink); }
    .btn.quiet:active { background: var(--wash); color: var(--ink); }
    .btn.sm { height: 24px; padding: 0 10px; font-size: 11.5px; }
    .btn.lg { height: 36px; padding: 0 20px; font-size: 13px; font-weight: 600; }
    .btn kbd { font: 500 12.5px -apple-system, sans-serif; opacity: .6; }
    .btn.sm kbd { font-size: 11.5px; } .btn.lg kbd { font-size: 13px; }
    \(KeysWeb.css)
    .inline { color: var(--ink); text-decoration: underline; text-decoration-color: var(--faint); text-underline-offset: 2px; }
    .inline:hover { text-decoration-color: currentColor; }
    """
}

/// The marks of a shortcut, ⌘ ⇧ ⌥ ⌃ ↩ ⌫ ⇥, as line drawings on a 24-point
/// square, stroked at 2.2 with round ends: one table for the app's keys
/// (KeyGlyphs) and the pages' (KeysWeb), so a shortcut is drawn the same
/// wherever it is. The font's own ⌘ and ↩ sat at different heights beside
/// the letters and read as crooked.
/// Where a button's keys stand on it, handed down by the button
/// (YabButtonStyle): each key's plate as tall as the button less its
/// inset top and bottom, and the last one as far in from the trailing edge,
/// the keys pulled that much past the button's own padding. `lead` is what
/// moves from the button's leading padding into the gap before the keys, so
/// the words stand in the middle of the room left of the plates, as much
/// before them as after (KeyLead).
public struct KeyPlate {
    public let height: CGFloat
    public let pull: CGFloat
    public var lead: CGFloat = 0
    /// The plates' corner, for keys set close in a rounder thing, so they
    /// follow its curve; a tag's otherwise.
    public var corner: CGFloat = Radius.small

    public init(height: CGFloat, pull: CGFloat, lead: CGFloat = 0, corner: CGFloat = Radius.small) {
        self.height = height
        self.pull = pull
        self.lead = lead
        self.corner = corner
    }
}

/// What a button's keys took from its leading padding (KeyPlate.lead),
/// told up to the button, which gives it back (LeadingRoom).
struct KeyLead: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A button's leading padding, less what its keys moved into their gap:
/// the whole padding when it has none.
/// The face of a button that is two presses on one card: its action, and
/// behind a hairline a chevron with a menu (the small window's Open in
/// <space>, Copy for Agent). White on a light ground, a lighter glass on a
/// dark one, brighter under the pointer, a half-point edge in light.
public struct SplitFace: ViewModifier {
    let lit: Bool
    @Environment(\.tone) private var tone
    @Environment(\.colorScheme) private var scheme

    public init(lit: Bool) { self.lit = lit }

    public func body(content: Content) -> some View {
        let dark = (tone?.scheme ?? scheme) == .dark
        content
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(dark ? Color.white.opacity(lit ? 0.2 : 0.14) : Color.white.opacity(lit ? 1 : 0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(Palette.ink.opacity(dark ? 0 : 0.08), lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
    }
}

public struct LeadingRoom: ViewModifier {
    let padding: CGFloat
    @State private var lead: CGFloat = 0

    public init(padding: CGFloat) { self.padding = padding }

    public func body(content: Content) -> some View {
        content
            .onPreferenceChange(KeyLead.self) { lead = $0 }
            .padding(.leading, padding - lead)
    }
}

private struct KeyPlateKey: EnvironmentKey {
    static let defaultValue: KeyPlate? = nil
}

extension EnvironmentValues {
    public var keyPlate: KeyPlate? {
        get { self[KeyPlateKey.self] }
        set { self[KeyPlateKey.self] = newValue }
    }
}

public enum KeyArt {
    static let paths: [Character: String] = [
        "⌘": "M15 6v12a3 3 0 1 0 3-3H6a3 3 0 1 0 3 3V6a3 3 0 1 0-3 3h12a3 3 0 1 0-3-3",
        // Shift as wide and as tall as ⌘ beside it, as SF Pro draws the
        // two; it stood a third smaller, in 5 to 19 of the square.
        "⇧": "M12 3.5 3.5 12H8v8.5h8V12h4.5z",
        "⌥": "M3 3h6l6 18h6M14 3h7",
        "⌃": "m18 15-6-6-6 6",
        // Return as the Mac draws it, ⏎ in SF Pro and on the menus: square,
        // the short bar on top, down the right, the long line back to the
        // arrow; not a corner arrow, nor a round hook.
        "↩": "M14 5h4.5a1.5 1.5 0 0 1 1.5 1.5v6a1.5 1.5 0 0 1-1.5 1.5H3m4.5-4.5L3 14l4.5 4.5",
        "⌫": "M20 5H9l-7 7 7 7h11a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2Zm-8 4 6 6m0-6-6 6",
        "⇥": "M3 12h14m-5-5 5 5-5 5M21 5v14",
        // Slash in the square's middle: the font's stood a point and a half
        // under its plate's, as it runs below the baseline.
        "/": "M15.5 4 8.5 20",
    ]

    static func svg(_ path: String) -> String {
        ##"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="\##(path)"/></svg>"##
    }

    @MainActor private static var made: [Character: NSImage] = [:]

    /// A mark as a template image, or nil for a key that is a letter.
    @MainActor public static func image(_ key: Character) -> NSImage? {
        if let hit = made[key] { return hit }
        guard let path = paths[key], let image = NSImage(data: Data(svg(path).utf8)) else { return nil }
        image.isTemplate = true
        made[key] = image
        return image
    }
}

/// A shortcut on a page drawn in HTML, as `KeyGlyphs` draws one in the app,
/// from the same drawings (KeyArt), each mark in the middle of its plate,
/// ↩ too: the plate is what lines up with the words.
/// `keys('⇧⌘B')` in a page's script (after `esc`) gives the markup; it
/// takes the color of what it sits in. Each key stands on a plate of that
/// color, faint, as KeyGlyphs has it; in a `.btn` the plate is the button's
/// height less its inset, and the button's trailing padding is that inset.
enum KeysWeb {
    static let css = """
    .keys { display: inline-flex; align-items: center; gap: 2px; font-size: 11.5px; font-weight: 500; }
    .keys svg { width: 12px; height: 12px; display: block; }
    .keys .k { display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box; min-width: 17px; height: 17px; padding: 0 3px; border-radius: 5px; background: color-mix(in srgb, currentColor 14%, transparent); }
    .btn kbd .keys { font-size: inherit; }
    .btn kbd .keys svg { width: 13px; height: 13px; }
    .btn.sm kbd .keys svg { width: 12px; height: 12px; }
    .btn.lg kbd .keys svg { width: 14px; height: 14px; }
    .btn kbd .k { min-width: 20px; height: 20px; padding: 0 4px; }
    .btn.sm kbd .k { min-width: 16px; height: 16px; padding: 0 2px; }
    .btn.lg kbd .k { min-width: 20px; height: 20px; padding: 0 3px; }
    .keys .k.one { padding: 0; aspect-ratio: 1; }
    .btn:has(kbd), .btn.sm:has(kbd) { padding-right: 4px; }
    .btn.lg:has(kbd) { padding-right: 8px; }
    .btn:has(kbd) { padding-left: 9.5px; } .btn:has(kbd) kbd { margin-left: 3.5px; }
    .btn.sm:has(kbd) { padding-left: 8px; } .btn.sm:has(kbd) kbd { margin-left: 2px; }
    .btn.lg:has(kbd) { padding-left: 13px; } .btn.lg:has(kbd) kbd { margin-left: 7px; }
    """

    static var js: String {
        let glyphs = KeyArt.paths.sorted { $0.key < $1.key }
            .map { "  '\($0.key)': '<path d=\"\($0.value)\"/>'," }
            .joined(separator: "\n")
        return """
        const GLYPH = {
        \(glyphs)
        };
        const keys = (s) => {
          // Each key on its plate: a mark alone, letters together (esc).
          const written = s.replace(/⏎/g, '↩');
          const runs = [];
          let letters = false;
          for (const c of written) {
            if (GLYPH[c]) {
              runs.push(c);
              letters = false;
            } else if (letters) {
              runs[runs.length - 1] += c;
            } else {
              runs.push(c);
              letters = true;
            }
          }
          // A mark or a single letter on a square plate; letters together (esc) as wide as they need.
          const face = (r) => GLYPH[r] ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">' + GLYPH[r] + '</svg>' : '<span>' + esc(r) + '</span>';
          return '<span class="keys" data-keys="' + esc(written) + '">' + runs.map((r) => '<span class="k' + (GLYPH[r] || r.length === 1 ? ' one' : '') + '" data-k="' + esc(r) + '">' + face(r) + '</span>').join('') + '</span>';
        };
        """
    }
}
