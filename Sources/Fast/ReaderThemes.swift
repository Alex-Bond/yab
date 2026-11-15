import Foundation
import SwiftUI

// Reading mode's themes, shared by the Mac and the iPhone (Phone/project.yml
// compiles this file too): six themes, as Apple Books has them (Original,
// Quiet, Paper, Bold, Calm, Focus), each with its face, weight, size,
// spacing and a light and a dark pair of colors, and over them a light or
// dark of their own and a wider page. What you change in a theme
// (Customize) is kept with that theme until Reset gives the theme back.
// Nothing here is AppKit or UIKit: each device draws its own controls
// (ReaderAppearance and ReaderCard on the Mac, ReaderSettingsPage on the
// iPhone) and sends the page the same payload.

enum ReaderThemeID: String, CaseIterable, Codable, Identifiable {
    case original, quiet, paper, bold, calm, focus
    var id: String { rawValue }
    var spec: ReaderThemeSpec { ReaderThemeSpec.all[self]! }
}

/// The faces Customize offers, each one a Mac has on it. Atkinson
/// Hyperlegible isn't one, and isn't bundled.
enum ReaderFont: String, CaseIterable, Codable {
    /// The face the site set its article in.
    case site
    case newYork, charter, iowan, palatino, athelas, georgia, sfPro

    var title: String {
        switch self {
        case .site: "Original"
        case .newYork: "New York"
        case .charter: "Charter"
        case .iowan: "Iowan Old Style"
        case .palatino: "Palatino"
        case .athelas: "Athelas"
        case .georgia: "Georgia"
        case .sfPro: "SF Pro"
        }
    }

    /// A line beside its name in the list, where the name doesn't say it.
    var hint: String? { self == .site ? "the site\u{2019}s" : nil }

    /// As the page asks for it. The site's own face is the page's to say
    /// (Reader.siteFace), so it is none here.
    var css: String {
        switch self {
        case .site: ""
        case .newYork: "ui-serif, \"New York\", Georgia, serif"
        case .charter: "Charter, Georgia, serif"
        case .iowan: "\"Iowan Old Style\", Georgia, serif"
        case .palatino: "Palatino, \"Palatino Linotype\", Georgia, serif"
        case .athelas: "Athelas, Georgia, serif"
        case .georgia: "Georgia, serif"
        case .sfPro: "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
        }
    }

    /// The face in the card: a tile's Aa, a row of the list set in itself.
    /// The site's is drawn in the Mac's own, as Original's tile is.
    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch self {
        case .site, .sfPro: .system(size: size, weight: weight)
        case .newYork: .system(size: size, weight: weight, design: .serif)
        case .charter: .custom("Charter", size: size).weight(weight)
        case .iowan: .custom("Iowan Old Style", size: size).weight(weight)
        case .palatino: .custom("Palatino", size: size).weight(weight)
        case .athelas: .custom("Athelas", size: size).weight(weight)
        case .georgia: .custom("Georgia", size: size).weight(weight)
        }
    }
}

/// A ground and the ink on it, checked: sRGB hex only, and ink that reads.
struct ReaderColors: Codable, Equatable {
    var background: String
    var text: String

    init(_ background: String, _ text: String) {
        self.background = Self.hex(background) ?? "#ffffff"
        let asked = Self.hex(text) ?? "#171717"
        let dark = Self.luminance(self.background) < 0.179
        self.text = Self.contrast(self.background, asked) >= 4.5 ? asked : (dark ? "#ffffff" : "#000000")
    }

    var dark: Bool { Self.luminance(background) < 0.179 }

    static func hex(_ text: String) -> String? {
        let bare = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard bare.count == 6, bare.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + bare.lowercased()
    }

    static func luminance(_ hex: String) -> Double {
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0
        let c = [16, 8, 0].map { shift -> Double in
            let value = Double((rgb >> shift) & 255) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722
    }

    static func contrast(_ a: String, _ b: String) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

}

/// What a theme sets, or a theme with its edits: everything Customize and
/// the card's two pills change, and the face.
struct ReaderLook: Equatable {
    /// An index into `ReaderLook.sizes`.
    var size: Int
    var line: Double
    /// Character and word spacing, and the margins, in percent: of the
    /// face's size for the first two, of the column for the margins.
    var letter: Int
    var word: Int
    var margins: Int
    var justify: Bool
    var font: ReaderFont
    var bold = false
    /// Colors of your own (Settings › Custom colors), for light and dark
    /// alike; none, the theme's pair for each.
    var colors: ReaderColors? = nil

    /// The text sizes, in points, the A pills step through.
    static let sizes = [14, 15, 16, 17, 18, 20, 22, 24, 26, 28]
    static let lines: ClosedRange<Double> = 1.3...2.1
    static let letters: ClosedRange<Double> = -3...10
    static let words: ClosedRange<Double> = 0...40
    static let marginRange: ClosedRange<Double> = -30...30

    var points: Int { Self.sizes[min(max(size, 0), Self.sizes.count - 1)] }
}

struct ReaderThemeSpec {
    let id: ReaderThemeID
    let name: String
    let light: ReaderColors
    let dark: ReaderColors
    let weight: Int
    let look: ReaderLook

    var fontWeight: Font.Weight { weight >= 700 ? .bold : weight >= 500 ? .medium : .regular }

    /// The six, in the card's order, as the Oct 21 prototype drew them,
    /// set in the Mac's own faces.
    static let ordered: [ReaderThemeSpec] = [
        ReaderThemeSpec(id: .original, name: "Original", light: ReaderColors("#ffffff", "#1d1d1f"), dark: ReaderColors("#1c1c1e", "#e8e8ea"),
                        weight: 400, look: ReaderLook(size: 4, line: 1.6, letter: 0, word: 0, margins: 0, justify: false, font: .site)),
        ReaderThemeSpec(id: .quiet, name: "Quiet", light: ReaderColors("#f2f1ee", "#5a5852"), dark: ReaderColors("#111111", "#8e8b85"),
                        weight: 400, look: ReaderLook(size: 4, line: 1.7, letter: 0, word: 0, margins: 0, justify: false, font: .newYork)),
        ReaderThemeSpec(id: .paper, name: "Paper", light: ReaderColors("#f7f3ea", "#2a2620"), dark: ReaderColors("#252320", "#ddd6c8"),
                        weight: 400, look: ReaderLook(size: 4, line: 1.7, letter: 0, word: 0, margins: 0, justify: true, font: .charter)),
        ReaderThemeSpec(id: .bold, name: "Bold", light: ReaderColors("#ffffff", "#000000"), dark: ReaderColors("#000000", "#ffffff"),
                        weight: 700, look: ReaderLook(size: 5, line: 1.55, letter: 1, word: 0, margins: 0, justify: false, font: .sfPro)),
        ReaderThemeSpec(id: .calm, name: "Calm", light: ReaderColors("#efe4cf", "#4a3b28"), dark: ReaderColors("#3a332b", "#ebe0cd"),
                        weight: 400, look: ReaderLook(size: 5, line: 1.75, letter: 0, word: 4, margins: 0, justify: false, font: .iowan)),
        ReaderThemeSpec(id: .focus, name: "Focus", light: ReaderColors("#fffdf6", "#1d1b16"), dark: ReaderColors("#17160f", "#f2edd9"),
                        weight: 500, look: ReaderLook(size: 5, line: 1.8, letter: 0, word: 0, margins: -10, justify: false, font: .athelas)),
    ]
    static let all = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
}

/// What was changed in a theme, and only that: a value set back to the
/// theme's own is no edit.
struct ReaderEdit: Codable, Equatable {
    var size: Int?
    var line: Double?
    var letter: Int?
    var word: Int?
    var margins: Int?
    var justify: Bool?
    var font: ReaderFont?
    var bold: Bool?
    var colors: ReaderColors?

    init() {}

    init(_ look: ReaderLook, against base: ReaderLook) {
        size = look.size == base.size ? nil : look.size
        line = abs(look.line - base.line) < 0.001 ? nil : look.line
        letter = look.letter == base.letter ? nil : look.letter
        word = look.word == base.word ? nil : look.word
        margins = look.margins == base.margins ? nil : look.margins
        justify = look.justify == base.justify ? nil : look.justify
        font = look.font == base.font ? nil : look.font
        bold = look.bold == base.bold ? nil : look.bold
        colors = look.colors == base.colors ? nil : look.colors
    }

    var isEmpty: Bool { self == ReaderEdit() }

    func applied(to base: ReaderLook) -> ReaderLook {
        var look = base
        if let size { look.size = min(max(size, 0), ReaderLook.sizes.count - 1) }
        if let line { look.line = min(max(line, ReaderLook.lines.lowerBound), ReaderLook.lines.upperBound) }
        if let letter { look.letter = letter }
        if let word { look.word = word }
        if let margins { look.margins = margins }
        if let justify { look.justify = justify }
        if let font { look.font = font }
        if let bold { look.bold = bold }
        if let colors { look.colors = colors }
        return look
    }
}

/// Light or dark over every theme: the Mac's, or one of the two.
enum ReaderMode: String, CaseIterable, Codable {
    case auto, light, dark

    #if os(iOS)
    private static let automatic = "Match iPhone"
    #else
    private static let automatic = "Match the Mac"
    #endif
    var title: String {
        switch self {
        case .auto: Self.automatic
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Everything reading mode keeps: the theme, the light, the page's width
/// and each theme's edits.
struct ReaderPrefs: Equatable {
    var theme: ReaderThemeID = .original
    var mode: ReaderMode = .auto
    var wide = false
    var edits: [ReaderThemeID: ReaderEdit] = [:]

    var spec: ReaderThemeSpec { theme.spec }

    func look(_ id: ReaderThemeID) -> ReaderLook {
        let base = id.spec.look
        return edits[id]?.applied(to: base) ?? base
    }
    var look: ReaderLook { look(theme) }

    func edited(_ id: ReaderThemeID) -> Bool { !(edits[id]?.isEmpty ?? true) }

    /// The theme in front changed, what is kept being only what now
    /// differs from the theme.
    mutating func change(_ body: (inout ReaderLook) -> Void) {
        var next = look
        body(&next)
        let edit = ReaderEdit(next, against: spec.look)
        edits[theme] = edit.isEmpty ? nil : edit
    }

    /// One knob of the theme in front back to the theme's own.
    mutating func restore(_ path: WritableKeyPath<ReaderLook, Int>) { let own = spec.look[keyPath: path]; change { $0[keyPath: path] = own } }
    mutating func restore(_ path: WritableKeyPath<ReaderLook, Double>) { let own = spec.look[keyPath: path]; change { $0[keyPath: path] = own } }

    mutating func reset(_ id: ReaderThemeID? = nil) { edits[id ?? theme] = nil }

    /// Smaller or larger by a step, held at the ends. Says whether it moved.
    @discardableResult
    mutating func step(_ by: Int) -> Bool {
        let was = look.size
        change { $0.size = min(max($0.size + by, 0), ReaderLook.sizes.count - 1) }
        return look.size != was
    }

    /// Whether the page reads dark, `system` saying whether the Mac does.
    func isDark(system: Bool) -> Bool {
        switch mode {
        case .auto: system
        case .light: false
        case .dark: true
        }
    }

    func colors(_ id: ReaderThemeID, dark: Bool) -> ReaderColors {
        look(id).colors ?? (dark ? id.spec.dark : id.spec.light)
    }

    // MARK: what the page is sent

    struct Ground: Encodable, Equatable {
        let bg: String
        let ink: String
        let dark: Bool
    }

    struct Payload: Encodable, Equatable {
        let mode: String
        let day: Ground
        let night: Ground
        let font: String
        let weight: Int
        let size: Int
        let line: Double
        let letter: Double
        let word: Double
        let width: Double
        let justify: Bool
    }

    /// The column's width in ems of its own size: 38, wide 48, less the
    /// margins' share.
    var width: Double {
        let base: Double = wide ? 48 : 38
        return ((base * (1 - Double(look.margins) / 100)) * 100).rounded() / 100
    }

    var payload: Payload {
        let look = look
        func ground(_ c: ReaderColors) -> Ground { Ground(bg: c.background, ink: c.text, dark: c.dark) }
        return Payload(mode: mode.rawValue,
                       day: ground(colors(theme, dark: false)), night: ground(colors(theme, dark: true)),
                       font: look.font.css, weight: look.bold ? 700 : spec.weight, size: look.points,
                       line: look.line, letter: Double(look.letter) / 100, word: Double(look.word) / 100,
                       width: width, justify: look.justify)
    }

    // MARK: kept

    enum Key {
        static let theme = "reader.style"
        static let mode = "reader.mode"
        static let wide = "reader.wide"
        static let edits = "reader.edits"
        /// Before the themes: System, Light, Dark, Sepia or Custom, and
        /// Custom's two colors.
        static let old = "reader.theme"
        static let oldBackground = "reader.background"
        static let oldText = "reader.text"
    }

    static func load(from store: UserDefaults) -> ReaderPrefs {
        guard let id = store.string(forKey: Key.theme) else {
            let moved = migrated(theme: store.string(forKey: Key.old), background: store.string(forKey: Key.oldBackground),
                                 text: store.string(forKey: Key.oldText))
            moved.save(to: store)
            return moved
        }
        var prefs = ReaderPrefs()
        prefs.theme = ReaderThemeID(rawValue: id) ?? .original
        prefs.mode = store.string(forKey: Key.mode).flatMap(ReaderMode.init) ?? .auto
        prefs.wide = store.bool(forKey: Key.wide)
        if let text = store.string(forKey: Key.edits), let decoded = try? JSONDecoder().decode([String: ReaderEdit].self, from: Data(text.utf8)) {
            for (key, edit) in decoded {
                guard let id = ReaderThemeID(rawValue: key), !edit.isEmpty else { continue }
                prefs.edits[id] = edit
            }
        }
        return prefs
    }

    func save(to store: UserDefaults) {
        store.set(theme.rawValue, forKey: Key.theme)
        store.set(mode.rawValue, forKey: Key.mode)
        store.set(wide, forKey: Key.wide)
        let kept = Dictionary(uniqueKeysWithValues: edits.filter { !$0.value.isEmpty }.map { ($0.key.rawValue, $0.value) })
        let data = (try? JSONEncoder().encode(kept)) ?? Data("{}".utf8)
        store.set(String(decoding: data, as: UTF8.self), forKey: Key.edits)
    }

    /// The five colors before themes, each where it reads the same now:
    /// System, Light and Dark are Original under the Mac's light, Light or
    /// Dark; Sepia is Calm in the light; Custom is Original with its two
    /// colors kept as an edit, so Reset is the way back.
    static func migrated(theme old: String?, background: String?, text: String?) -> ReaderPrefs {
        var prefs = ReaderPrefs()
        switch old {
        case "light": prefs.mode = .light
        case "dark": prefs.mode = .dark
        case "sepia": prefs.theme = .calm; prefs.mode = .light
        case "custom":
            let colors = ReaderColors(background ?? "f4ecd8", text ?? "302b23")
            prefs.change { $0.colors = colors }
        default: break
        }
        return prefs
    }
}
