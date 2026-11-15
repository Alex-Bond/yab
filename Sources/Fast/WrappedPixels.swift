import CoreGraphics
import Foundation

// Yab Wrapped's arcade screen is drawn as an old machine drew it: a small
// grid of square pixels, 180 by 320, letters from a 5 by 7 font of our own
// (no font file, no license), a handful of 8 by 8 sprites. The grid is put
// on the glass by WrappedScreen, which adds the tube.

/// One color of the arcade's palette.
struct WrappedInk: Equatable {
    var r: CGFloat, g: CGFloat, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    static let white = WrappedInk(0xFFFFFF)
    static let dim = WrappedInk(0x8AA0FF)
    static let gold = WrappedInk(0xFFD166)
    static let slot = WrappedInk(0x1C2140)
    static let dots = WrappedInk(0x39406A)
    static let violet = WrappedInk(0x9B72FF)
    static let blue = WrappedInk(0x4A90FF)
    static let orange = WrappedInk(0xFF8A2A)
    static let green = WrappedInk(0x2FD27A)
    static let pink = WrappedInk(0xFF5FA2)
    static let cyan = WrappedInk(0x3FE0E0)
    static let red = WrappedInk(0xFF4D4D)
}

enum WrappedFont {
    static let width = 5, height = 7, advance = 6

    /// Each letter as seven rows of five, # lit.
    static let glyphs: [Character: [String]] = [
        "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
        "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
        "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
        "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
        "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
        "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"],
        "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "I": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "#####"],
        "J": ["..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
        "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
        "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
        "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
        "N": ["#...#", "##..#", "##..#", "#.#.#", "#..##", "#..##", "#...#"],
        "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
        "Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
        "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
        "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
        "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
        "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
        "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#."],
        "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
        "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
        "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
        "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
        "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
        "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
        " ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
        ".": [".....", ".....", ".....", ".....", ".....", ".....", "..#.."],
        ",": [".....", ".....", ".....", ".....", "..#..", "..#..", ".#..."],
        ":": [".....", "..#..", ".....", ".....", ".....", "..#..", "....."],
        "!": ["..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."],
        "?": [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
        "-": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
        "+": [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
        "/": ["....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."],
        "'": ["..#..", "..#..", ".#...", ".....", ".....", ".....", "....."],
        "%": ["##..#", "##..#", "...#.", "..#..", ".#...", "#..##", "#..##"],
        "(": ["...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#."],
        ")": [".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#..."],
        "#": [".#.#.", ".#.#.", "#####", ".#.#.", "#####", ".#.#.", ".#.#."],
        "=": [".....", ".....", "#####", ".....", "#####", ".....", "....."],
        "<": ["...#.", "..#..", ".#...", "#....", ".#...", "..#..", "...#."],
        ">": [".#...", "..#..", "...#.", "....#", "...#.", "..#..", ".#..."],
        "_": [".....", ".....", ".....", ".....", ".....", ".....", "#####"],
        "*": [".....", "#.#.#", ".###.", "#####", ".###.", "#.#.#", "....."],
        "·": [".....", ".....", ".....", "..#..", ".....", ".....", "....."],
        "~": [".....", ".....", ".#...", "#.#.#", "...#.", ".....", "....."],
        "@": [".###.", "#...#", "#.###", "#.#.#", "#.###", "#....", ".###."],
    ]

    /// The lit points of a letter, column and row from its top left;
    /// lowercase is drawn as capitals, anything unknown as a space.
    static func lit(_ c: Character) -> [(Int, Int)] {
        let up = String(c).uppercased()
        let rows = (up.count == 1 ? glyphs[Character(up)] : nil) ?? glyphs[" "]!
        var out: [(Int, Int)] = []
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch == "#" { out.append((x, y)) }
        }
        return out
    }

    /// How wide a line is, in grid pixels, at a scale.
    static func measure(_ text: String, scale: Int) -> Int {
        guard !text.isEmpty else { return 0 }
        return (text.count * advance - 1) * scale
    }

    /// The words of `text` in lines no wider than `columns` letters.
    static func wrap(_ text: String, columns: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            let next = line.isEmpty ? String(word) : line + " " + word
            if next.count > columns, !line.isEmpty {
                lines.append(line)
                line = String(word)
            } else {
                line = next
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }
}

/// 8 by 8 pictures for the levels and bonus stages.
enum WrappedSprite: String, CaseIterable {
    case agent, ask, mail, forms, code, video, tabs, ads, memory, reading, calls, phone, boosts, friends, moon, coin, heart, invader, search, gift, tree

    var rows: [String] {
        switch self {
        case .agent: return ["........", ".......#", "......##", "#....##.", "##..##..", ".####...", "..##....", "........"]
        case .ask: return [".######.", "#......#", "#.#..#.#", "#......#", "#.####.#", ".######.", "...##...", "....#..."]
        case .mail: return ["########", "##....##", "#.#..#.#", "#..##..#", "#......#", "#......#", "########", "........"]
        case .forms: return ["########", "#......#", "#.###..#", "#......#", "########", "#......#", "#.##...#", "########"]
        case .code: return ["........", ".#....#.", "#......#", "#..##..#", "#......#", ".#....#.", "........", "..####.."]
        case .video: return ["########", "#......#", "#.##...#", "#.####.#", "#.##...#", "#......#", "########", "..#..#.."]
        case .tabs: return ["###.....", "#.######", "#......#", "#......#", "#......#", "#......#", "########", "........"]
        case .ads, .invader: return ["..#..#..", "...##...", "..####..", ".##.##.#", "########", "#.####.#", "#.#..#.#", "...##..."]
        case .memory: return ["........", ".####...", "....#...", "...#....", ".####...", "......##", ".......#", "......##"]
        case .reading: return ["........", "###..###", "#..##..#", "#..##..#", "#..##..#", "#..##..#", "###..###", "........"]
        case .calls: return ["##......", "###.....", ".##.....", "..##....", "...##.##", "....####", ".....###", "......#."]
        case .phone: return ["..####..", ".#....#.", ".#....#.", ".#....#.", ".#....#.", ".#....#.", ".#.##.#.", "..####.."]
        case .boosts: return ["...##...", "..####..", ".######.", "...##...", "...##...", "..#..#..", ".#....#.", "........"]
        case .friends: return [".##..##.", "#..##..#", "#......#", "#......#", ".#....#.", "..#..#..", "...##...", "........"]
        case .moon: return ["...###..", "..##....", ".##.....", ".##.....", ".##.....", "..##....", "...###..", "........"]
        case .coin: return ["..####..", ".#....#.", "#..##..#", "#..#...#", "#..##..#", "#....#.#", ".#....#.", "..####.."]
        case .search: return ["..###...", ".#...#..", "#.....#.", "#.....#.", "#.....#.", ".#...#..", "..###.#.", "......##"]
        case .gift: return ["..#..#..", "...##...", "########", "#...#..#", "########", "#...#..#", "#...#..#", "########"]
        case .tree: return ["...##...", "..####..", "...##...", "..####..", ".######.", "########", "...##...", "...##..."]
        case .heart: return [".##..##.", "########", "########", "########", ".######.", "..####..", "...##...", "........"]
        }
    }
}

/// A grid to draw a screen on: CoreGraphics underneath, pixels on top,
/// y from the top as the screens are laid out.
struct WrappedGrid {
    let width: Int, height: Int
    let context: CGContext

    init?(width: Int, height: Int) {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        self.width = width
        self.height = height
        self.context = context
        context.setShouldAntialias(false)
        context.interpolationQuality = .none
        // Top-left origin, so a screen reads top to bottom.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        clear()
    }

    func clear(_ ink: WrappedInk = WrappedInk(0x000000)) {
        context.setFillColor(ink.cg)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ ink: WrappedInk) {
        context.setFillColor(ink.cg)
        context.fill(CGRect(x: x, y: y, width: w, height: h))
    }

    func frame(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ ink: WrappedInk) {
        rect(x, y, w, 1, ink)
        rect(x, y + h - 1, w, 1, ink)
        rect(x, y, 1, h, ink)
        rect(x + w - 1, y, 1, h, ink)
    }

    /// A line of text with its top at `y`: centered on `x`, or starting or
    /// ending there.
    enum Align { case left, center, right }
    func text(_ s: String, x: Int, y: Int, scale: Int = 1, ink: WrappedInk = .white, align: Align = .center) {
        let w = WrappedFont.measure(s, scale: scale)
        var cx = align == .center ? x - w / 2 : align == .right ? x - w : x
        context.setFillColor(ink.cg)
        for ch in s {
            for (px, py) in WrappedFont.lit(ch) {
                context.fill(CGRect(x: cx + px * scale, y: y + py * scale, width: scale, height: scale))
            }
            cx += WrappedFont.advance * scale
        }
    }

    /// Lines wrapped to fit, centered; returns the y under the last.
    @discardableResult
    func paragraph(_ s: String, y: Int, columns: Int = 25, scale: Int = 1, ink: WrappedInk = .dim, leading: Int = 11) -> Int {
        var y = y
        for line in WrappedFont.wrap(s, columns: columns) {
            text(line, x: width / 2, y: y, scale: scale, ink: ink)
            y += leading * scale
        }
        return y
    }

    func sprite(_ sprite: WrappedSprite, x: Int, y: Int, scale: Int = 1, ink: WrappedInk) {
        context.setFillColor(ink.cg)
        for (py, row) in sprite.rows.enumerated() {
            for (px, ch) in row.enumerated() where ch == "#" {
                context.fill(CGRect(x: x + px * scale, y: y + py * scale, width: scale, height: scale))
            }
        }
    }

    var image: CGImage? { context.makeImage() }
}
