import SwiftUI
import UIKit

/// A space's drawings, the Mac's (Sources/Fast/LookDrawings.swift): one
/// seamless 320 point tile per set and ink, thrown from a fixed seed, black
/// on a light ground, white on a dark one, from 2% to 22% at the most.
enum LookDrawings {
    enum Set: String, CaseIterable {
        case browser, life

        var title: String {
            switch self {
            case .browser: return "Browser"
            case .life: return "Life"
            }
        }

        fileprivate var glyphs: [Doodle] {
            switch self {
            case .browser: return [.globe, .cursor, .mail, .bookmark, .key, .lock, .search, .command, .tab, .download, .puzzle, .compass, .bolt, .pencil, .star]
            case .life: return [.cup, .heart, .cat, .moon, .note, .planet, .cloud, .plane, .sparkle, .star, .play, .globe]
            }
        }
    }

    /// How strongly they show when first picked.
    static let standard = 0.45

    static func opacity(_ strength: Double, dark: Bool) -> Double {
        let s = min(1, max(0, strength))
        return dark ? 0.015 + 0.17 * s : 0.02 + 0.2 * s
    }

    /// Whether a ground this color takes light lines.
    static func light(on ground: RGB) -> Bool {
        (0.299 * Double(ground.r) + 0.587 * Double(ground.g) + 0.114 * Double(ground.b)) / 255 < 0.6
    }

    static let side: CGFloat = 320

    @MainActor static func tile(_ set: Set, white: Bool) -> UIImage {
        let key = "\(set.rawValue)-\(white)"
        if let made = tiles[key] { return made }
        let items = layout(set)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { renderer in
            let context = renderer.cgContext
            context.setStrokeColor(white ? UIColor.white.cgColor : UIColor.black.cgColor)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for item in items {
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
        }
        tiles[key] = image
        return image
    }

    @MainActor private static var tiles: [String: UIImage] = [:]

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
        var seed: UInt64 = set == .browser ? 0x51A7_E5ED : 0x0B1F_EDA7
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

/// A look's drawings over its ground, tiled; nothing for none.
struct LookDrawingsFill: View {
    let drawings: String
    let strength: Double
    let ground: RGB

    var body: some View {
        if let set = LookDrawings.Set(rawValue: drawings) {
            let white = LookDrawings.light(on: ground)
            Image(uiImage: LookDrawings.tile(set, white: white))
                .resizable(resizingMode: .tile)
                .opacity(LookDrawings.opacity(strength, dark: white))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// One drawing, in a box from -1 to 1 each way, y down.
fileprivate enum Doodle {
    case globe, cursor, mail, bookmark, key, lock, search, command, tab, download, puzzle, compass, bolt, pencil, star
    case cup, heart, cat, moon, note, planet, cloud, plane, sparkle, play
    case squiggle, plus

    var path: CGPath {
        let p = CGMutablePath()
        func line(_ points: [(CGFloat, CGFloat)], closed: Bool = false) {
            guard let first = points.first else { return }
            p.move(to: CGPoint(x: first.0, y: first.1))
            points.dropFirst().forEach { p.addLine(to: CGPoint(x: $0.0, y: $0.1)) }
            if closed { p.closeSubpath() }
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

/// A fine grain over a space's ground, so a flat color reads as paper, as
/// the Mac's window wears it (Sources/Fast/Design.swift, Grain): one tile of
/// noise, white or black points of random strength, made once and tiled at
/// 0.2 of the amount.
enum LookGrain {
    static func opacity(_ amount: Double) -> Double { min(1, max(0, amount)) * 0.2 }

    static let tile: UIImage = {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt32 = 0x2545F491
        for i in 0..<(side * side) {
            // xorshift: the same grain every launch, and the Mac's.
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            let white: UInt8 = seed & 1 == 0 ? 0 : 255
            let alpha = UInt8(seed >> 8 & 0xFF)
            let v = UInt8((Int(white) * Int(alpha)) / 255)
            pixels[i * 4] = v; pixels[i * 4 + 1] = v; pixels[i * 4 + 2] = v; pixels[i * 4 + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return UIImage() }
        // 128 pixels on 64 points, as the Mac's.
        return UIImage(cgImage: image, scale: 2, orientation: .up)
    }()
}

/// The grain over a ground, nothing at none.
struct LookGrainFill: View {
    let amount: Double
    var body: some View {
        if amount > 0 {
            Image(uiImage: LookGrain.tile)
                .resizable(resizingMode: .tile)
                .opacity(LookGrain.opacity(amount))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
