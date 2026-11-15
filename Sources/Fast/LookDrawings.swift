import AppKit

/// Drawings over a space's color, as Telegram lays doodles over a chat's
/// wallpaper: small things drawn in one line, scattered without touching,
/// each turned a little its own way. One tile, drawn once per set and ink,
/// repeats across the window's ground (BackdropCoatingView.drawings), so a
/// window of any size costs one pattern image and nothing a frame.
///
/// Three sets: Browser, the things a browser is made of, Life, the rest
/// of the day, and Halloween, from Halloween 2026 and kept. Between the big ones, a few small marks fill the gaps, never
/// dots: dots would read as grain, and grain is its own slider.
enum LookDrawings {
    enum Set: String, CaseIterable {
        case browser, life, halloween

        var title: String {
            switch self {
            case .browser: return "Browser"
            case .life: return "Life"
            case .halloween: return "Halloween"
            }
        }

        fileprivate var glyphs: [Doodle] {
            switch self {
            case .browser: return [.globe, .cursor, .mail, .bookmark, .key, .lock, .search, .command, .tab, .download, .puzzle, .compass, .bolt, .pencil, .star]
            case .life: return [.cup, .heart, .cat, .moon, .note, .planet, .cloud, .plane, .sparkle, .star, .play, .globe]
            case .halloween: return [.pumpkin, .ghost, .bat, .spider, .web, .hat, .candy, .corn, .cauldron, .candle, .moon, .cat, .star]
            }
        }
    }

    /// How strongly they show when first picked.
    static let standard = 0.45

    /// The drawings' opacity over a color: from barely there to a quiet
    /// pattern, never loud. A light ground takes dark lines a little
    /// stronger than a dark one takes light ones, which would glare.
    static func opacity(_ strength: Double, dark: Bool) -> Double {
        let s = min(1, max(0, strength))
        return dark ? 0.015 + 0.17 * s : 0.02 + 0.2 * s
    }

    /// Whether a ground this color takes light lines.
    static func light(on ground: NSColor) -> Bool {
        let rgb = ground.usingColorSpace(.sRGB) ?? ground
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent < 0.6
    }

    /// A layer dressed in a paint's drawings, or hidden for none; drawn
    /// again only when the set or the ink changes (`drawn` keeps which).
    @MainActor static func dress(_ layer: CALayer, with paint: SpaceWash.Paint, drawn: inout String?) {
        guard let set = paint.drawings else {
            layer.isHidden = true
            return
        }
        let white = light(on: paint.color)
        let key = "\(set.rawValue)-\(white)"
        if drawn != key {
            layer.backgroundColor = NSColor(patternImage: tile(set, white: white)).cgColor
            drawn = key
        }
        layer.isHidden = false
        layer.opacity = Float(opacity(paint.drawingsStrength, dark: white))
    }

    /// The side of the square that repeats, in points.
    static let side: CGFloat = 320

    /// One tile of a set, in white or black, drawn once and kept.
    @MainActor static func tile(_ set: Set, white: Bool) -> NSImage {
        let key = "\(set.rawValue)-\(white)"
        if let made = tiles[key] { return made }
        let items = layout(set)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(white ? NSColor.white.cgColor : NSColor.black.cgColor)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for item in items {
                // Drawn again across the edges it overlaps, so the tile meets
                // itself with no seam.
                for dx in [-side, 0, side] {
                    for dy in [-side, 0, side] {
                        let x = item.x + dx, y = item.y + dy
                        guard x > -item.size * 1.6, x < side + item.size * 1.6, y > -item.size * 1.6, y < side + item.size * 1.6 else { continue }
                        context.saveGState()
                        context.translateBy(x: x, y: y)
                        context.rotate(by: item.angle)
                        context.scaleBy(x: item.size, y: item.size)
                        context.setLineWidth(1.3 / item.size)
                        context.addPath(item.glyph.path)
                        context.strokePath()
                        context.restoreGState()
                    }
                }
            }
            return true
        }
        tiles[key] = image
        return image
    }

    @MainActor private static var tiles: [String: NSImage] = [:]

    struct Item {
        fileprivate let glyph: Doodle
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let angle: CGFloat
    }

    /// Where each drawing sits on the tile: thrown at random from a fixed
    /// seed and kept only where it touches nothing, measured round the
    /// tile's edges too, as it repeats.
    static func layout(_ set: Set) -> [Item] {
        var seed: UInt64 = switch set {
        case .browser: 0x51A7_E5ED
        case .life: 0x0B1F_EDA7
        case .halloween: 0x0A11_E031
        }
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(1 << 31)
        }
        let big = set.glyphs, small: [Doodle] = [.squiggle, .plus, .sparkle]
        var items: [Item] = []
        for _ in 0..<5000 where items.count < 140 {
            let isBig = next() < 0.62
            let size = isBig ? 8.5 + next() * 5.5 : 3.6 + next() * 2.6
            let x = next() * side, y = next() * side
            let clear = items.allSatisfy { other in
                var dx = abs(other.x - x), dy = abs(other.y - y)
                dx = min(dx, side - dx)
                dy = min(dy, side - dy)
                let room = (other.size + size) * 1.15 + 5
                return dx * dx + dy * dy >= room * room
            }
            guard clear else { continue }
            let pool = isBig ? big : small
            let glyph = pool[min(pool.count - 1, Int(next() * CGFloat(pool.count)))]
            items.append(Item(glyph: glyph, x: x, y: y, size: size, angle: (next() - 0.5) * 1.1))
        }
        return items
    }
}

/// One drawing, in a box from -1 to 1 each way, y down.
fileprivate enum Doodle {
    case globe, cursor, mail, bookmark, key, lock, search, command, tab, download, puzzle, compass, bolt, pencil, star
    case cup, heart, cat, moon, note, planet, cloud, plane, sparkle, play
    case pumpkin, ghost, bat, spider, web, hat, candy, corn, cauldron, candle
    case squiggle, plus

    var path: CGPath {
        let p = CGMutablePath()
        func line(_ points: [(CGFloat, CGFloat)], closed: Bool = false) {
            guard let first = points.first else { return }
            p.move(to: CGPoint(x: first.0, y: first.1))
            points.dropFirst().forEach { p.addLine(to: CGPoint(x: $0.0, y: $0.1)) }
            if closed { p.closeSubpath() }
        }
        // Lines and curves written out as an SVG path's M, L, C, Q and Z,
        // all absolute: the Halloween ones were drawn that way.
        func svg(_ text: String) {
            var words = text.split(separator: " ").map(String.init)[...]
            func n() -> CGFloat { CGFloat(Double(words.popFirst() ?? "0") ?? 0) }
            func point() -> CGPoint { let x = n(); return CGPoint(x: x, y: n()) }
            while let word = words.popFirst() {
                switch word {
                case "M": p.move(to: point())
                case "L": p.addLine(to: point())
                case "C": let a = point(), b = point(); p.addCurve(to: point(), control1: a, control2: b)
                case "Q": let a = point(); p.addQuadCurve(to: point(), control: a)
                case "Z": p.closeSubpath()
                default: break
                }
            }
        }
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) { p.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)) }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) {
            p.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r)
        }
        switch self {
        case .globe:
            circle(0, 0, 1)
            p.addEllipse(in: CGRect(x: -0.45, y: -1, width: 0.9, height: 2))
            line([(-1, 0), (1, 0)])
        case .cursor:
            line([(-0.55, -1), (-0.55, 0.6), (-0.18, 0.25), (0.15, 0.95), (0.42, 0.83), (0.1, 0.15), (0.55, 0.12)], closed: true)
        case .mail:
            box(-1, -0.65, 2, 1.3, 0.18)
            line([(-0.95, -0.55), (0, 0.12), (0.95, -0.55)])
        case .bookmark:
            line([(-0.55, -1), (0.55, -1), (0.55, 1), (0, 0.55), (-0.55, 1)], closed: true)
        case .key:
            circle(-0.5, 0, 0.42)
            line([(-0.08, 0), (1, 0)])
            line([(0.68, 0), (0.68, 0.35)])
            line([(0.92, 0), (0.92, 0.28)])
        case .lock:
            box(-0.7, -0.1, 1.4, 1.05, 0.2)
            p.move(to: CGPoint(x: -0.45, y: -0.1))
            p.addLine(to: CGPoint(x: -0.45, y: -0.4))
            p.addArc(center: CGPoint(x: 0, y: -0.4), radius: 0.45, startAngle: .pi, endAngle: 0, clockwise: false)
            p.addLine(to: CGPoint(x: 0.45, y: -0.1))
        case .search:
            circle(-0.2, -0.2, 0.6)
            line([(0.23, 0.23), (0.95, 0.95)])
        case .command:
            let o: CGFloat = 0.38, r: CGFloat = 0.3, c = o + r * 0.62
            p.addRect(CGRect(x: -o, y: -o, width: o * 2, height: o * 2))
            for (u, v) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] { circle(CGFloat(u) * c, CGFloat(v) * c, r) }
        case .tab:
            line([(-1, 0.55), (-0.6, 0.55), (-0.6, -0.4), (-0.4, -0.55), (0.4, -0.55), (0.6, -0.4), (0.6, 0.55), (1, 0.55)])
        case .download:
            line([(0, -1), (0, 0.35)])
            line([(-0.45, -0.1), (0, 0.35), (0.45, -0.1)])
            line([(-0.9, 0.5), (-0.9, 0.9), (0.9, 0.9), (0.9, 0.5)])
        case .puzzle:
            p.move(to: CGPoint(x: -0.8, y: -0.8))
            p.addLine(to: CGPoint(x: -0.2, y: -0.8))
            p.addArc(center: CGPoint(x: 0, y: -0.8), radius: 0.2, startAngle: .pi, endAngle: 0, clockwise: false)
            p.addLine(to: CGPoint(x: 0.8, y: -0.8))
            p.addLine(to: CGPoint(x: 0.8, y: -0.2))
            p.addArc(center: CGPoint(x: 0.8, y: 0), radius: 0.2, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
            p.addLine(to: CGPoint(x: 0.8, y: 0.8))
            p.addLine(to: CGPoint(x: -0.8, y: 0.8))
            p.closeSubpath()
        case .compass:
            circle(0, 0, 1)
            line([(0, -0.7), (0.22, 0), (0, 0.7), (-0.22, 0)], closed: true)
        case .bolt:
            line([(0.15, -1), (-0.55, 0.12), (-0.02, 0.12), (-0.18, 1), (0.6, -0.22), (0.06, -0.22)], closed: true)
        case .pencil:
            line([(-0.9, 0.9), (-0.75, 0.45), (0.6, -0.9), (0.9, -0.6), (-0.45, 0.75)], closed: true)
        case .star:
            line((0..<10).map { i -> (CGFloat, CGFloat) in
                let r: CGFloat = i % 2 == 1 ? 0.42 : 1, a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                return (cos(a) * r, sin(a) * r)
            }, closed: true)
        case .cup:
            line([(-0.65, -0.1), (-0.55, 0.85), (0.45, 0.85), (0.55, -0.1)], closed: true)
            p.move(to: CGPoint(x: 0.52, y: 0.1))
            p.addArc(center: CGPoint(x: 0.68, y: 0.35), radius: 0.25, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
            p.move(to: CGPoint(x: -0.3, y: -0.35))
            p.addCurve(to: CGPoint(x: -0.3, y: -0.95), control1: CGPoint(x: -0.45, y: -0.55), control2: CGPoint(x: -0.15, y: -0.7))
        case .heart:
            p.move(to: CGPoint(x: 0, y: 0.85))
            p.addCurve(to: CGPoint(x: 0, y: -0.4), control1: CGPoint(x: -1.2, y: 0), control2: CGPoint(x: -0.7, y: -1))
            p.addCurve(to: CGPoint(x: 0, y: 0.85), control1: CGPoint(x: 0.7, y: -1), control2: CGPoint(x: 1.2, y: 0))
        case .cat:
            p.move(to: CGPoint(x: -0.8, y: -0.2))
            p.addLine(to: CGPoint(x: -0.75, y: -0.95))
            p.addLine(to: CGPoint(x: -0.3, y: -0.55))
            p.addQuadCurve(to: CGPoint(x: 0.3, y: -0.55), control: CGPoint(x: 0, y: -0.65))
            p.addLine(to: CGPoint(x: 0.75, y: -0.95))
            p.addLine(to: CGPoint(x: 0.8, y: -0.2))
            p.addCurve(to: CGPoint(x: 0, y: 0.85), control1: CGPoint(x: 0.95, y: 0.6), control2: CGPoint(x: 0.4, y: 0.85))
            p.addCurve(to: CGPoint(x: -0.8, y: -0.2), control1: CGPoint(x: -0.4, y: 0.85), control2: CGPoint(x: -0.95, y: 0.6))
            line([(-0.35, 0.3), (-1.05, 0.2)])
            line([(0.35, 0.3), (1.05, 0.2)])
        case .moon:
            p.addArc(center: .zero, radius: 0.9, startAngle: .pi * 0.35, endAngle: .pi * 1.65, clockwise: false)
            p.addArc(center: CGPoint(x: 0.45, y: -0.05), radius: 0.72, startAngle: .pi * 1.45, endAngle: .pi * 0.55, clockwise: true)
            p.closeSubpath()
        case .note:
            p.addEllipse(in: CGRect(x: -0.72, y: 0.41, width: 0.64, height: 0.48))
            line([(-0.1, 0.6), (-0.1, -1)])
            p.addQuadCurve(to: CGPoint(x: 0.55, y: -0.55), control: CGPoint(x: 0.3, y: -0.6))
        case .planet:
            circle(0, 0, 0.55)
            p.addEllipse(in: CGRect(x: -1.05, y: -0.3, width: 2.1, height: 0.6), transform: CGAffineTransform(rotationAngle: -0.35))
        case .cloud:
            p.move(to: CGPoint(x: -0.55, y: 0.55))
            p.addArc(center: CGPoint(x: -0.5, y: 0.15), radius: 0.4, startAngle: .pi * 0.5, endAngle: .pi * 1.5, clockwise: false)
            p.addArc(center: CGPoint(x: 0, y: -0.15), radius: 0.5, startAngle: .pi * 1.15, endAngle: .pi * 1.9, clockwise: false)
            p.addArc(center: CGPoint(x: 0.55, y: 0.15), radius: 0.4, startAngle: .pi * 1.5, endAngle: .pi * 0.5, clockwise: false)
            p.closeSubpath()
        case .plane:
            line([(-1, -0.05), (1, -0.8), (0.35, 0.9), (0.02, 0.18)], closed: true)
            line([(0.02, 0.18), (1, -0.8)])
        case .sparkle:
            p.move(to: CGPoint(x: 0, y: -1))
            p.addQuadCurve(to: CGPoint(x: 1, y: 0), control: CGPoint(x: 0.12, y: -0.12))
            p.addQuadCurve(to: CGPoint(x: 0, y: 1), control: CGPoint(x: 0.12, y: 0.12))
            p.addQuadCurve(to: CGPoint(x: -1, y: 0), control: CGPoint(x: -0.12, y: 0.12))
            p.addQuadCurve(to: CGPoint(x: 0, y: -1), control: CGPoint(x: -0.12, y: -0.12))
        case .play:
            box(-1, -0.68, 2, 1.36, 0.38)
            line([(-0.25, -0.35), (0.4, 0), (-0.25, 0.35)], closed: true)
        case .pumpkin:
            svg("M -0.92 0.12 C -1 -0.62 -0.36 -0.74 0 -0.5 C 0.36 -0.74 1 -0.62 0.92 0.12 C 0.86 0.8 -0.86 0.8 -0.92 0.12 Z")
            svg("M -0.3 -0.6 C -0.52 -0.12 -0.52 0.42 -0.3 0.7 M 0.3 -0.6 C 0.52 -0.12 0.52 0.42 0.3 0.7 M 0 -0.52 C 0 -0.8 0.1 -0.95 0.32 -1")
        case .ghost:
            // Yab's wink for a face.
            svg("M -0.7 0.92 L -0.7 -0.2 C -0.7 -1.12 0.7 -1.12 0.7 -0.2 L 0.7 0.92 L 0.35 0.66 L 0 0.92 L -0.35 0.66 Z")
            svg("M -0.28 -0.34 L -0.28 -0.04 M 0.08 -0.16 Q 0.24 -0.38 0.42 -0.24")
        case .bat:
            svg("M -1 -0.1 Q -0.7 -0.62 -0.36 -0.2 Q -0.18 -0.56 0 -0.26 Q 0.18 -0.56 0.36 -0.2 Q 0.7 -0.62 1 -0.1 Q 0.62 -0.04 0.48 0.3 Q 0.25 0.02 0 0.36 Q -0.25 0.02 -0.48 0.3 Q -0.62 -0.04 -1 -0.1 Z")
        case .spider:
            svg("M 0 -1 L 0 -0.12")
            p.addEllipse(in: CGRect(x: -0.26, y: -0.08, width: 0.52, height: 0.6))
            svg("M -0.22 0.1 Q -0.6 -0.15 -0.8 0.1 M -0.22 0.3 Q -0.6 0.3 -0.8 0.6 M 0.22 0.1 Q 0.6 -0.15 0.8 0.1 M 0.22 0.3 Q 0.6 0.3 0.8 0.6")
        case .web:
            // A corner's web: threads out from the top left, three sagging rounds.
            let angles: [CGFloat] = [0, 0.4, 0.8, 1.17, .pi / 2]
            for a in angles { line([(-1, -1), (-1 + cos(a) * 2.05, -1 + sin(a) * 2.05)]) }
            for r: CGFloat in [0.7, 1.25, 1.8] {
                p.move(to: CGPoint(x: -1 + r, y: -1))
                for (a, b) in zip(angles, angles.dropFirst()) {
                    let m = (a + b) / 2
                    p.addQuadCurve(to: CGPoint(x: -1 + cos(b) * r, y: -1 + sin(b) * r),
                                   control: CGPoint(x: -1 + cos(m) * r * 0.86, y: -1 + sin(m) * r * 0.86))
                }
            }
        case .hat:
            svg("M -1 0.62 Q 0 0.9 1 0.62 Q 0.4 0.44 0.42 0.42 L 0.12 -0.38 Q 0.22 -0.8 0.74 -0.9 Q 0.06 -0.98 -0.16 -0.44 L -0.42 0.42 Q -0.4 0.44 -1 0.62 Z M -0.38 0.3 Q 0 0.4 0.38 0.3")
        case .candy:
            p.addEllipse(in: CGRect(x: -0.42, y: -0.32, width: 0.84, height: 0.64))
            svg("M -0.42 0 L -1 -0.42 L -1 0.42 Z M 0.42 0 L 1 -0.42 L 1 0.42 Z M -0.12 -0.28 L 0.1 0.28")
        case .corn:
            svg("M -0.66 0.8 Q 0 -1.7 0.66 0.8 Q 0 1 -0.66 0.8 Z M -0.5 0.24 Q 0 0.4 0.5 0.24 M -0.28 -0.3 Q 0 -0.2 0.28 -0.3")
        case .cauldron:
            svg("M -0.86 -0.2 L 0.86 -0.2 M -0.76 -0.2 C -0.92 0.66 0.92 0.66 0.76 -0.2 M -0.48 0.56 L -0.6 0.86 M 0.48 0.56 L 0.6 0.86")
            circle(-0.18, -0.48, 0.14)
            circle(0.24, -0.72, 0.1)
        case .candle:
            svg("M -0.3 -0.16 L -0.3 0.92 L 0.3 0.92 L 0.3 -0.16 Z M 0 -0.16 L 0 -0.38 M 0 -0.42 Q -0.26 -0.68 0 -1 Q 0.26 -0.68 0 -0.42 M 0.3 0.1 Q 0.44 0.2 0.36 0.42")
        case .squiggle:
            line((0...16).map { i -> (CGFloat, CGFloat) in
                let t = CGFloat(i) / 16
                return (-1 + t * 2, sin(t * .pi * 3) * 0.32)
            })
        case .plus:
            line([(-0.6, 0), (0.6, 0)])
            line([(0, -0.6), (0, 0.6)])
        }
        return p
    }
}
