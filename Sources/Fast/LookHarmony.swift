import AppKit

/// A color in the existing Look editor's space, with chroma measured as a
/// share of the sRGB gamut at this lightness and hue.
struct LookColor: Equatable {
    var lightness: CGFloat
    var reach: CGFloat
    var hue: CGFloat

    init(lightness: CGFloat, reach: CGFloat, hue: CGFloat) {
        // All of it, black to white: a preset can be either (LookPresets).
        self.lightness = min(1, max(0, lightness))
        self.reach = min(1, max(0, reach))
        self.hue = Self.turn(hue)
    }

    init(_ color: NSColor) {
        let (l, c, h) = color.oklch
        let light = min(1, max(0, l))
        self.init(lightness: light, reach: c / max(0.001, Gamut.chroma(light, h)), hue: h)
    }

    static func turn(_ hue: CGFloat) -> CGFloat {
        let value = hue.truncatingRemainder(dividingBy: 2 * .pi)
        return value < 0 ? value + 2 * .pi : value
    }

    var lch: (CGFloat, CGFloat, CGFloat) { (lightness, Gamut.chroma(lightness, hue) * reach, hue) }
    var color: NSColor { NSColor(oklch: lch) }

    /// The hidden wheel on the dotted field. Its outer edge remains clear
    /// of the handles' edges and the add/remove buttons below.
    var point: CGPoint {
        CGPoint(x: 0.5 + cos(hue) * reach * 0.42, y: 0.5 + sin(hue) * reach * 0.42)
    }

    mutating func move(to point: CGPoint) {
        let x = point.x - 0.5, y = point.y - 0.5
        let distance = hypot(x, y)
        reach = min(1, distance / 0.42)
        if distance > 0.0001 { hue = Self.turn(atan2(y, x)) }
    }
}

/// The looks a click away under the field, as Arc's space editor has them:
/// five pages of nine, flat colors, three-color gradients, pastels, muted
/// darks and the grays from white to black. Each is a main color and the
/// colors linked to it. Arc's pastels, darks and grays are its own asset
/// catalog's (ColorPickerPastel/Drab/Greyscale, Display P3, put in sRGB);
/// the flat colors and gradients were read off a 60 fps film of the editor,
/// the gradients from their handles where they were picked (the 1st to 4th
/// and the 9th) and from their dots where they weren't.
enum LookPresets {
    struct Preset: Equatable {
        let main: String
        let links: [String]
    }

    struct Page {
        let name: String
        let presets: [Preset]
    }

    private static func flat(_ name: String, _ hexes: [String]) -> Page {
        Page(name: name, presets: hexes.map { Preset(main: $0, links: []) })
    }

    static let pages: [Page] = [
        flat("Colors", ["F2E9E3", "EC8FBB", "A0689A", "E54C6E", "F37C5A", "F3D85E", "44FE96", "74BFD6", "666587"]),
        Page(name: "Gradients", presets: [
            Preset(main: "F2E9E3", links: ["F1E2E7", "EFF2E5"]),
            Preset(main: "EC8FBB", links: ["E68CE7", "E9AA9C"]),
            Preset(main: "A0689A", links: ["9F6A80", "886E9D"]),
            Preset(main: "F37C5A", links: ["F23B97", "EDF349"]),
            Preset(main: "F3ED6E", links: ["F6BB6D", "FAA68E"]),
            Preset(main: "B7FF79", links: ["DDEB78", "E3BD78"]),
            Preset(main: "72F2E6", links: ["69E7B9", "8C95E0"]),
            Preset(main: "938EDC", links: ["8DABDA", "8DBCD0"]),
            Preset(main: "666587", links: ["7D5F88", "628087"]),
        ]),
        flat("Pastels", ["FEFBFA", "FFE9F3", "F1D1EC", "FFCBD1", "FFE0D3", "FFF9E5", "DEFDEB", "DCF3FC", "C5C6E5"]),
        flat("Muted", ["4E3A5A", "693558", "8F4042", "B16D40", "D7B35D", "CDCCA4", "7AA982", "226149", "26456B"]),
        flat("Grays", ["FFFFFF", "E5E5E5", "CCCCCC", "B2B2B2", "808080", "666666", "333333", "1A1A1A", "000000"]),
    ]

    /// Every page's presets one after another, as a row too narrow for a
    /// page of nine shows them: each with its page and its name there.
    static let all: [(preset: Preset, page: Int, name: String)] = pages.indices.flatMap { page in
        pages[page].presets.indices.map { (pages[page].presets[$0], page, "\(pages[page].name) \($0 + 1)") }
    }

    /// Where each page starts along `all`.
    static let starts: [Int] = pages.indices.map { page in pages[..<page].reduce(0) { $0 + $1.presets.count } }

    /// White's place, the Grays page's first, where a look that can wear
    /// No Color shows its dot instead, as Arc keeps it on its grayscale page.
    static let plainAt = starts[pages.count - 1]

    /// Where along `all` a look's colors come from, the first if none: the
    /// row opens on it.
    static func index(of color: NSColor, colors: [String]) -> Int {
        let hex = color.hex
        return all.firstIndex { $0.preset.main == hex && $0.preset.links == colors } ?? 0
    }
}

/// Relative hue, chroma and lightness keep a palette together when its
/// primary color moves. Imported colors keep their existing relationships.
struct LookHarmony: Equatable {
    struct Link: Equatable {
        var hue: CGFloat
        var reach: CGFloat = 0
        var lightness: CGFloat = 0
    }

    var links: [Link]

    init(primary: LookColor, colors: [String]) {
        links = colors.compactMap(NSColor.init(hex:)).map {
            let color = LookColor($0)
            return Link(hue: LookColor.turn(color.hue - primary.hue),
                        reach: color.reach - primary.reach,
                        lightness: color.lightness - primary.lightness)
        }
    }

    init(links: [Link] = []) { self.links = links }

    /// Two colors oppose each other; three form an evenly spaced triad.
    static func suggested(extras: Int) -> LookHarmony {
        LookHarmony(links: extras == 1 ? [Link(hue: .pi)]
                    : extras == 2 ? [Link(hue: 2 * .pi / 3), Link(hue: 4 * .pi / 3)] : [])
    }

    /// Whether the linked colors sit evenly round the wheel, as + puts them.
    var isEven: Bool {
        let even = Self.suggested(extras: links.count).links
        return even.count == links.count && zip(links, even).allSatisfy {
            let apart = LookColor.turn($0.hue - $1.hue)
            return min(apart, 2 * .pi - apart) < 0.01 && abs($0.reach) < 0.01 && abs($0.lightness) < 0.01
        }
    }

    /// The colors with one taken: that one only, the rest as they were.
    /// Nil takes the last.
    func removing(_ index: Int?) -> LookHarmony {
        var next = self
        guard !next.links.isEmpty else { return next }
        if let index, next.links.indices.contains(index) { next.links.remove(at: index) } else { next.links.removeLast() }
        return next
    }

    /// Where the ones left go after −: an even set closes up evenly, as
    /// Arc's; colors placed by hand or brought from another browser stay.
    func closingUp(after removing: LookHarmony) -> LookHarmony {
        isEven ? .suggested(extras: removing.links.count) : removing
    }

    func colors(from primary: LookColor) -> [LookColor] {
        links.map {
            LookColor(lightness: primary.lightness + $0.lightness,
                      reach: primary.reach + $0.reach, hue: primary.hue + $0.hue)
        }
    }

    /// Editing a small handle changes only its relationship to the main
    /// color. The main handle remains the palette's anchor afterwards.
    mutating func move(_ index: Int, to point: CGPoint, from primary: LookColor) {
        guard links.indices.contains(index) else { return }
        var color = colors(from: primary)[index]
        color.move(to: point)
        links[index].hue = LookColor.turn(color.hue - primary.hue)
        links[index].reach = color.reach - primary.reach
    }
}

/// The handle under the initial press stays held for the whole drag.
struct LookGrab {
    enum Handle: Equatable { case primary, following(Int) }
    let handle: Handle
    let offset: CGSize

    static func hit(_ at: CGPoint, primary: CGPoint, following: [CGPoint]) -> Handle? {
        if hypot(at.x - primary.x, at.y - primary.y) <= 18 { return .primary }
        return following.indices.filter {
            hypot(at.x - following[$0].x, at.y - following[$0].y) <= 12
        }.min {
            hypot(at.x - following[$0].x, at.y - following[$0].y)
                < hypot(at.x - following[$1].x, at.y - following[$1].y)
        }.map { .following($0) }
    }

    init(at: CGPoint, primary: CGPoint, following: [CGPoint]) {
        let hit = Self.hit(at, primary: primary, following: following)
        handle = hit ?? .primary
        let center: CGPoint
        switch handle {
        case .primary: center = primary
        case .following(let index): center = following[index]
        }
        offset = hit == nil ? .zero : CGSize(width: at.x - center.x, height: at.y - center.y)
    }

    func point(at: CGPoint, travel: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, (at.x - offset.width - 18) / travel.width)),
                y: min(1, max(0, (at.y - offset.height - 18) / travel.height)))
    }
}
