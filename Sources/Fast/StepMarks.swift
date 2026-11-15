import AppKit
import QuartzCore
import SwiftUI
import SyncKit

// A step's mark: one small drawing for each kind of work an agent does,
// the lens for a search, the open book for a file it reads, the pencil on
// its pad for an edit, the cord and plug for another server's tool. While
// the step runs, the mark makes one gesture of that work on the Glint's
// beat (0.6 s into every 4), so the light over the verb and the mark move
// together; a step done stands still; a tick is written once as it lands,
// a failure shakes once, a request to you waves once and waits.
//
// Drawn the way Codex draws its Lottie icons, on Central's shapes in our
// 2 pt weight: every frame is geometry. A turn or a move is baked into the
// path, and what grows or shrinks (the lens turning edge-on, a folder's
// front falling open, a page turning over) moves its points, so the stroke
// never thins. The keyframes and curves of the marks Codex has too (its
// Search, Tasks, New chat, More, Library, Plugins, Projects, Memory and
// Thinking) are theirs, frame for frame at 60 fps; the rest keep its clock
// and curves. Each kind is sampled once into keyframes that Core Animation
// plays on the render server, so a running step costs the main thread
// nothing, as the face's poses do (FaceLayer).

/// A cubic Bézier timing curve, solved for x, as CSS's and Lottie's are.
struct StepCurve: Equatable {
    let x1: Double, y1: Double, x2: Double, y2: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }

    func callAsFunction(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx
        let cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by
        func sx(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
        func sy(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
        func dx(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }
        var t = x
        for _ in 0..<8 {
            let error = sx(t) - x
            if abs(error) < 1e-6 { return sy(t) }
            let slope = dx(t)
            if abs(slope) < 1e-6 { break }
            t -= error / slope
        }
        var low = 0.0, high = 1.0
        t = x
        for _ in 0..<40 {
            let value = sx(t)
            if abs(value - x) < 1e-6 { break }
            if x > value { low = t } else { high = t }
            t = (low + high) / 2
        }
        return sy(t)
    }

    /// Codex's own: in and out, out hard, in hard, a tick's, nearly even.
    static let both = StepCurve(0.33, 0, 0.67, 1)
    static let out = StepCurve(0.33, 0, 0, 1)
    static let inward = StepCurve(1, 0, 0.67, 1)
    static let tick = StepCurve(0.75, 0, 0.25, 1)
    static let even = StepCurve(0.17, 0.17, 0.83, 0.83)
    /// The lens turning edge-on, and back.
    static let flipIn = StepCurve(1, 0, 1, 1)
    static let flipOut = StepCurve(0, 0, 0, 1)
    /// A page lifting, and settling.
    static let lift = StepCurve(0.51, 0, 1, 1)
    static let soft = StepCurve(0.17, 0, 0.83, 1)
    static let settle = StepCurve(0, 0, 0.49, 1)
}

/// The value at frame `f` of keys (frame, value, the curve of the part
/// that starts there); before the first and after the last, held.
func stepKey(_ f: Double, _ keys: [(Double, [Double], StepCurve?)]) -> [Double] {
    guard let first = keys.first else { return [] }
    if f <= first.0 { return first.1 }
    for index in 0..<(keys.count - 1) {
        let (f0, v0, curve) = keys[index]
        let (f1, v1, _) = keys[index + 1]
        if f <= f1 {
            let p = f1 > f0 ? (f - f0) / (f1 - f0) : 1
            let q = curve.map { $0(p) } ?? p
            return zip(v0, v1).map { $0 + ($1 - $0) * q }
        }
    }
    return keys[keys.count - 1].1
}

func stepKey(_ f: Double, _ keys: [(Double, Double, StepCurve?)]) -> Double {
    stepKey(f, keys.map { ($0.0, [$0.1], $0.2) }).first ?? 0
}

// MARK: - geometry

/// Path data as the icons' SVGs have it (M L H V C Z, either case), made
/// a CGPath; kept, since the same few are asked for again and again.
enum StepPaths {
    @MainActor private static var made: [String: CGPath] = [:]

    @MainActor static func svg(_ d: String) -> CGPath {
        if let hit = made[d] { return hit }
        let path = parse(d)
        made[d] = path
        return path
    }

    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var tokens: [String] = []
        var number = ""
        func flush() { if !number.isEmpty { tokens.append(number); number = "" } }
        for character in d {
            if character.isLetter, character != "e", character != "E" {
                flush(); tokens.append(String(character))
            } else if character == "-" {
                if let last = number.last, last == "e" || last == "E" { number.append(character) } else { flush(); number.append(character) }
            } else if character == "." {
                if number.contains(".") && !number.contains("e") { flush() }
                number.append(character)
            } else if character.isNumber || character == "e" || character == "E" {
                number.append(character)
            } else {
                flush()
            }
        }
        flush()
        var index = 0
        var command: Character = "M"
        var current = CGPoint.zero, start = CGPoint.zero
        func next() -> CGFloat { defer { index += 1 }; return CGFloat(Double(tokens[index]) ?? 0) }
        func hasNumber() -> Bool { index < tokens.count && !(tokens[index].first?.isLetter ?? false) }
        while index < tokens.count {
            if let letter = tokens[index].first, letter.isLetter { command = letter; index += 1 }
            let relative = command.isLowercase
            let base = relative ? current : .zero
            switch command.uppercased() {
            case "M":
                guard hasNumber() else { break }
                let point = CGPoint(x: base.x + next(), y: base.y + next())
                path.move(to: point); current = point; start = point
                command = relative ? "l" : "L"
            case "L":
                guard hasNumber() else { break }
                let point = CGPoint(x: base.x + next(), y: base.y + next())
                path.addLine(to: point); current = point
            case "H":
                guard hasNumber() else { break }
                let x = (relative ? current.x : 0) + next()
                current = CGPoint(x: x, y: current.y); path.addLine(to: current)
            case "V":
                guard hasNumber() else { break }
                let y = (relative ? current.y : 0) + next()
                current = CGPoint(x: current.x, y: y); path.addLine(to: current)
            case "C":
                guard hasNumber() else { break }
                let c1 = CGPoint(x: base.x + next(), y: base.y + next())
                let c2 = CGPoint(x: base.x + next(), y: base.y + next())
                let end = CGPoint(x: base.x + next(), y: base.y + next())
                path.addCurve(to: end, control1: c1, control2: c2); current = end
            case "Z":
                path.closeSubpath(); current = start
                if hasNumber() { command = "L" }
            default:
                index += 1
            }
        }
        return path
    }

    /// A turn by `degrees` about a point, clockwise as the grid is drawn.
    static func turn(_ degrees: Double, _ x: Double, _ y: Double) -> CGAffineTransform {
        CGAffineTransform(translationX: -x, y: -y)
            .concatenating(CGAffineTransform(rotationAngle: degrees * .pi / 180))
            .concatenating(CGAffineTransform(translationX: x, y: y))
    }

    static func move(_ x: Double, _ y: Double) -> CGAffineTransform { CGAffineTransform(translationX: x, y: y) }

    static func moved(_ path: CGPath, _ transform: CGAffineTransform) -> CGPath {
        var transform = transform
        return path.copy(using: &transform) ?? path
    }

    /// A polygon's corners rounded, Lottie's way: each cut back its radius
    /// (at most half each side) and joined by a quarter circle's curve.
    static func rounded(_ points: [CGPoint], _ radii: [CGFloat], closed: Bool) -> CGPath {
        let path = CGMutablePath()
        let n = points.count
        guard n > 1 else { return path }
        let k: CGFloat = 0.5523
        func corner(_ i: Int) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
            let v = points[i], a = points[(i - 1 + n) % n], b = points[(i + 1) % n]
            let da = CGPoint(x: a.x - v.x, y: a.y - v.y), db = CGPoint(x: b.x - v.x, y: b.y - v.y)
            let la = max(1e-6, hypot(da.x, da.y)), lb = max(1e-6, hypot(db.x, db.y))
            let c = min(radii[i % radii.count], la / 2, lb / 2)
            let ua = CGPoint(x: da.x / la, y: da.y / la), ub = CGPoint(x: db.x / lb, y: db.y / lb)
            func at(_ u: CGPoint, _ s: CGFloat) -> CGPoint { CGPoint(x: v.x + u.x * s, y: v.y + u.y * s) }
            return (at(ua, c), at(ua, c * (1 - k)), at(ub, c * (1 - k)), at(ub, c))
        }
        if closed {
            path.move(to: corner(0).3)
            for i in 1...n {
                let c = corner(i % n)
                path.addLine(to: c.0)
                path.addCurve(to: c.3, control1: c.1, control2: c.2)
            }
            path.closeSubpath()
        } else {
            path.move(to: points[0])
            for i in 1..<(n - 1) {
                let c = corner(i)
                path.addLine(to: c.0)
                path.addCurve(to: c.3, control1: c.1, control2: c.2)
            }
            path.addLine(to: points[n - 1])
        }
        return path
    }

    /// The first `g` (0...1) of a polyline: a tick being written. Always
    /// as many segments, the ones not reached yet folded onto its tip, so
    /// one frame's path eases into the next's.
    static func partial(_ points: [CGPoint], _ g: Double) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        var left = lengths.reduce(0, +) * CGFloat(max(0, min(1, g)))
        var tip = first
        for (i, length) in lengths.enumerated() {
            if left > 0 {
                let q = min(1, left / max(length, 1e-6))
                let a = points[i], b = points[i + 1]
                tip = CGPoint(x: a.x + (b.x - a.x) * q, y: a.y + (b.y - a.y) * q)
                left -= length
            }
            path.addLine(to: tip)
        }
        return path
    }

    static func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, turned degrees: Double = 0) -> CGPath {
        let path = CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2), transform: nil)
        return degrees == 0 ? path : moved(path, turn(degrees, cx, cy))
    }

    static func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x1, y: y1))
        path.addLine(to: CGPoint(x: x2, y: y2))
        return path
    }
}

/// One stroke of a mark at one frame, on the 24-point grid.
struct StepStroke: Equatable {
    var path: CGPath
    var opacity: Double = 1
    /// Filled rather than stroked: the face's eyes.
    var fill = false
    /// A square cap, as a few of Central's shapes have.
    var square = false
}

// MARK: - the marks

// The marks themselves are SyncKit's (StepArt), the iPhone's too; how each
// moves and is drawn is the Mac's.
extension StepArt {
    /// The gesture's length, in frames at 60 a second.
    var frames: Double {
        switch self {
        case .readFile: return 90
        case .command: return 160
        case .wait: return 180
        case .memory: return 70
        case .hand: return 54
        case .key, .eye: return 46
        case .dialog: return 38
        case .plan, .close: return 34
        case .download, .upload, .code, .fill: return 30
        case .fail: return 24
        case .done: return 22
        case .think: return 12
        default: return 40
        }
    }

    /// Plays once, as it lands, rather than on every beat: a tick, a
    /// failure, a request to you.
    var once: Bool { self == .done || self == .fail || self == .hand }

    /// Where it rests: the start of its gesture, or the end of one that
    /// plays once (a tick written).
    var rest: Double { self == .done || self == .fail ? frames : 0 }

    @MainActor func draw(_ f: Double) -> [StepStroke] {
        typealias P = StepPaths
        func svg(_ d: String) -> CGPath { P.svg(d) }
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
        let q = StepCurve.both, out = StepCurve.out, inward = StepCurve.inward
        switch self {
        case .search:
            let s = stepKey(f, [(0, 100, StepCurve.flipIn), (10.256, 1, StepCurve.flipOut), (20, 100, nil)])
            return [StepStroke(path: P.ellipse(11, 11, max(0.07, 7 * s / 100), 7, turned: -45)),
                    StepStroke(path: svg("M20 20L16.05 16.05"))]
        case .history:
            let a = stepKey(f, [(0, 0, out), (40, 360, nil)])
            return [StepStroke(path: svg("M3 5V9H7")),
                    StepStroke(path: svg("M3.51172 15C4.74723 18.4956 8.08094 21 11.9996 21C16.9702 21 20.9996 16.9706 20.9996 12C20.9996 7.02944 16.9702 3 11.9996 3C8.27045 3 5.07102 5.26806 3.70551 8.5")),
                    StepStroke(path: svg("M12 12L15 15")),
                    StepStroke(path: P.moved(svg("M12 12V8"), P.turn(a, 12, 12)))]
        case .edit:
            let r = stepKey(f, [(0, 0, q), (14, 6, q), (26, -6, q), (39, 0, nil)])
            let i = max(0, min(38.999, f)), a = Int(i), t = i - Double(a)
            let d = (StepArt.drift[a].0 + (StepArt.drift[a + 1].0 - StepArt.drift[a].0) * t,
                     StepArt.drift[a].1 + (StepArt.drift[a + 1].1 - StepArt.drift[a].1) * t)
            let pencil = svg("M9 14.9999V12.4142C9 12.1489 9.10536 11.8946 9.29289 11.707L17.3358 3.66416C18.1168 2.88311 19.3832 2.88311 20.1642 3.66416L20.3358 3.83573C21.1168 4.61678 21.1168 5.88311 20.3358 6.66416L12.2929 14.707C12.1054 14.8946 11.851 14.9999 11.5858 14.9999H9Z")
            return [StepStroke(path: svg("M11 4H7.2C6.0799 4 5.51984 4 5.09202 4.21799C4.71569 4.40973 4.40973 4.71569 4.21799 5.09202C4 5.51984 4 6.0799 4 7.2V16.8C4 17.9201 4 18.4802 4.21799 18.908C4.40973 19.2843 4.71569 19.5903 5.09202 19.782C5.51984 20 6.0799 20 7.2 20H16.8C17.9201 20 18.4802 20 18.908 19.782C19.2843 19.5903 19.5903 19.2843 19.782 18.908C20 18.4802 20 17.9201 20 16.8V13")),
                    StepStroke(path: P.moved(pencil, P.turn(r, 9, 15).concatenating(P.move(d.0, d.1))), square: true)]
        case .type:
            return [(0.0, 13.0, 27.0, 4.0), (7, 20, 34, 12), (13, 26, 40, 20)].map { a, b, c, x in
                let y = stepKey(f, [(a, 0, out), (b, -3.64, inward), (c, 0, nil)])
                return StepStroke(path: P.ellipse(x, 12 + y, 1, 1))
            }
        case .skill:
            let r = stepKey(f, [(0, 0, inward), (14, 10, out), (26, 19.47, q), (39, 0, nil)])
            let x = stepKey(f, [(0, 0, inward), (14, -1.46, out), (26, 0.6, q), (39, 0, nil)])
            func book(_ x0: Double, _ x1: Double) -> CGPath { CGPath(roundedRect: CGRect(x: x0, y: 4, width: x1 - x0, height: 16), cornerWidth: 1.6, cornerHeight: 1.6, transform: nil) }
            return [StepStroke(path: book(2.66, 8.16)), StepStroke(path: book(8.16, 13.67)),
                    StepStroke(path: P.moved(book(15.17, 20.67), P.turn(r - 10, 17.92, 12).concatenating(P.move(x, 0))))]
        case .mcp:
            let wire = stepKey(f, [(0, 0, out), (20, -20, out), (30, 5, out), (39, 0, nil)])
            let plug = stepKey(f, [(0, 0, out), (20, -12, out), (39, 0, nil)])
            let o = stepKey(f, [(0, [0, 0], out), (20, [0.995, 0.671], out), (30, [-0.449, -0.25], out), (39, [0, 0], nil)])
            let outer = P.turn(wire, 12, 12)
            let inner = P.turn(plug, 12, 12).concatenating(P.move(o[0], o[1])).concatenating(outer)
            func held(_ p: CGPoint, _ k: Double) -> CGPoint {
                p.applying(P.turn(plug * k, 12, 12)).applying(P.move(o[0] * k, o[1] * k))
            }
            let a = held(pt(14.5, 14.5), 1), b = held(pt(15, 15), 0.7), c = held(pt(18, 18), 0.25)
            let cord = CGMutablePath()
            cord.move(to: a); cord.addLine(to: b)
            cord.addCurve(to: pt(21, 12), control1: c, control2: pt(21, 15.5))
            cord.addPath(svg("M21 12C21 7.02944 16.9706 3 12 3C7.02944 3 3 7.02944 3 12C3 16.9706 7.02944 21 12 21C12.6874 21 13.3568 20.9229 14 20.777"))
            return [StepStroke(path: P.moved(cord, outer)),
                    StepStroke(path: P.moved(svg("M13 8L8 13L10.5858 15.5858C11.3668 16.3668 12.6332 16.3668 13.4142 15.5858L15.5858 13.4142C16.3668 12.6332 16.3668 11.3668 15.5858 10.5858L13 8Z"), inner)),
                    StepStroke(path: P.moved(svg("M9 12L7.5 10.5M12 9L10.5 7.5"), inner))]
        case .folder:
            let u = stepKey(f, [(0, 0, out), (20, 1, out), (39, 0, nil)])
            func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * u }
            let x = mix(21, 19.6)
            return [StepStroke(path: P.rounded([pt(x, 11), pt(x, 7), pt(12.5, 7), pt(10.5, 4), pt(3, 4), pt(3, 19), pt(4.6, 19)], [0, 2, 1, 1, 2, 2, 0], closed: false)),
                    StepStroke(path: P.rounded([pt(mix(3, 8.6), 11), pt(mix(21, 21.6), 11), pt(mix(21, 19.8), 19), pt(mix(3, 4.4), 19)], [0.6, 0.6, 2, 2], closed: true))]
        case .readFile:
            var strokes = [
                StepStroke(path: P.rounded([pt(12, 19.2), pt(20, 17.6), pt(20, 4.6), pt(12, 6.2)], [0, 1.8, 1.8, 0], closed: false)),
                StepStroke(path: P.rounded([pt(12, 19.2), pt(4, 17.6), pt(4, 4.6), pt(12, 6.2)], [0, 1.8, 1.8, 0], closed: false)),
                StepStroke(path: svg("M12 6.2V19.2")),
            ]
            // Three pages over: each lifts slowly, crosses the spine fast and
            // settles; the third lands quicker, as in Codex's Memory.
            for (a, c, e) in [(0.0, 20.0, 45.0), (25, 45, 70), (41, 61, 79)] {
                let k = (e - c) / 25
                // Out of its turn it lies flat on one side, unseen, in the
                // same shape, so the next frame eases from it.
                let s = f < a ? [1.0, 0, 0] : f > e ? [-1.0, 0, 0] : f <= c
                    ? stepKey(f, [(a, [1, 0, 0], StepCurve.lift), (a + (c - a) * 0.8, [0.64, 3, 2.3], StepCurve.even), (a + (c - a) * 0.933, [0.2, 4.4, 2.2], StepCurve.even), (c, [0.04, 4.5, 2.4], nil)])
                    : stepKey(f, [(c, [-0.04, 4.5, 2.4], StepCurve.even), (c + 1.67 * k, [-0.2, 4.4, 2.2], StepCurve.soft), (c + 5 * k, [-0.64, 3, 2.3], StepCurve.settle), (e, [-1, 0, 0], nil)])
                let x = 12 + 8 * s[0], corner = CGFloat(min(1.8, abs(8 * s[0]) / 2))
                strokes.append(StepStroke(path: P.rounded([pt(12, 19.2), pt(x, 17.6 - s[2]), pt(x, 4.6 - s[1]), pt(12, 6.2)], [0, corner, corner, 0], closed: false),
                                          opacity: f < a || f > e ? 0 : 1))
            }
            return strokes
        case .command:
            let keys = (0...8).map { (Double($0) * 20, $0 % 2 == 0 ? 1.0 : 0.0, Optional(StepCurve.even)) }
            return [StepStroke(path: svg("M5 7L9.29289 11.2929C9.68342 11.6834 9.68342 12.3166 9.29289 12.7071L5 17")),
                    StepStroke(path: svg("M13 17H19"), opacity: stepKey(f, keys))]
        case .wait:
            let a = stepKey(f, [(0, 0, StepCurve.tick), (180, -180, nil)])
            return [StepStroke(path: P.moved(svg("M12 12L6.8906 8.59373C6.3342 8.2228 6 7.59834 6 6.92963V3H18V6.92963C18 7.59834 17.6658 8.2228 17.1094 8.59373L12 12ZM12 12L17.1094 15.4063C17.6658 15.7772 18 16.4017 18 17.0704V21H6V17.0704C6 16.4017 6.3342 15.7772 6.8906 15.4063L12 12ZM20 21H4M20 3H4"), P.turn(a, 12, 12)))]
        case .readPage, .pdf:
            let isPage = self == .readPage
            let sheet = isPage
                ? [StepStroke(path: svg("M5 5C5 3.89543 5.89543 3 7 3H17C18.1046 3 19 3.89543 19 5V19C19 20.1046 18.1046 21 17 21H7C5.89543 21 5 20.1046 5 19V5Z"))]
                : [StepStroke(path: svg("M12.1716 3H7C5.89543 3 5 3.89543 5 5V19C5 20.1046 5.89543 21 7 21H17C18.1046 21 19 20.1046 19 19V9.82843C19 9.29799 18.7893 8.78929 18.4142 8.41421L13.5858 3.58579C13.2107 3.21071 12.702 3 12.1716 3Z")),
                   StepStroke(path: svg("M13 3.5V7C13 8.10457 13.8954 9 15 9H18.5"))]
            let lines: [(Double, Double, Double)] = isPage ? [(7, 15, 0), (11, 15, 4), (15, 11, 8)] : [(13, 12, 0), (17, 15.5, 5)]
            return sheet + lines.map { y, x2, o in
                // Taken back, then written again, one after another.
                let g = stepKey(f, [(0, 1, inward), (8, 0, nil), (8 + o, 0, out), (24 + o + (isPage ? 0 : 2), 1, nil)])
                return StepStroke(path: P.line(9, y, 9 + (x2 - 9) * g, y), opacity: g > 0.04 ? 1 : 0)
            }
        case .open:
            let s = stepKey(f, [(0, 1, q), (13, 0, q), (26, 1, nil)])
            return [StepStroke(path: svg("M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C16.9706 3 21 7.02944 21 12Z")),
                    StepStroke(path: svg("M21 12H3")),
                    StepStroke(path: P.ellipse(12, 12, max(0.05, 3.5 * s), 9))]
        case .click:
            let t = stepKey(f, [(0, 0, q), (6, 1, q), (16, 0, nil)])
            var strokes = [StepStroke(path: P.moved(svg("M14.1365 20.8008L10.4008 11.0466C10.2461 10.6426 10.6426 10.2461 11.0466 10.4008L20.8008 14.1365C21.1883 14.2849 21.2368 14.8136 20.8827 15.03L17.353 17.1871C17.2853 17.2284 17.2284 17.2853 17.1871 17.353L15.03 20.8827C14.8136 21.2368 14.2849 21.1883 14.1365 20.8008Z"), P.move(-0.9 * t, -0.9 * t)))]
            let rays = [((11.0, 4.5), (11.0, 3.0)), ((15.5962, 6.40392), (16.6569, 5.34326)), ((6.40381, 15.5962), (5.34315, 16.6569)), ((4.5, 11.0), (3.0, 11.0)), ((6.40381, 6.40381), (5.34315, 5.34315))]
            for (i, ray) in rays.enumerated() {
                let d = Double(i)
                let g = stepKey(f, [(0, 1, inward), (6, 0, nil), (6 + d, 0, out), (20 + d, 1.35, q), (32 + d, 1, nil)])
                let (inner, outer) = ray
                func along(_ s: Double) -> (Double, Double) { (inner.0 + (outer.0 - inner.0) * s, inner.1 + (outer.1 - inner.1) * s) }
                let a = along(max(0, g - 1)), b = along(g)
                strokes.append(StepStroke(path: P.line(a.0, a.1, b.0, b.1), opacity: min(1, g * 4)))
            }
            return strokes
        case .point:
            let v = stepKey(f, [(0, 0, q), (10, 1, out), (34, 0, nil)])
            return [StepStroke(path: P.moved(svg("M3.68921 4.96392L9.08016 20.3265C9.38205 21.1868 10.5835 21.2274 10.9428 20.3895L13.6203 14.1453C13.7214 13.9094 13.9094 13.7214 14.1453 13.6203L20.3895 10.9428C21.2274 10.5835 21.1868 9.38205 20.3265 9.08016L4.96392 3.68921C4.17261 3.41153 3.41153 4.17261 3.68921 4.96392Z"), P.move(1.6 * v, 1.6 * v)))]
        case .scroll:
            let w = stepKey(f, [(0, 0, out), (13, 2.4, inward), (27, 0, nil)])
            let o = stepKey(f, [(0, 1, out), (13, 0.3, inward), (27, 1, nil)])
            let c = stepKey(f, [(4, 0, out), (17, 1.2, inward), (31, 0, nil)])
            return [StepStroke(path: svg("M12 17C9.23858 17 7 14.7614 7 12V7C7 4.23858 9.23858 2 12 2C14.7614 2 17 4.23858 17 7V12C17 14.7614 14.7614 17 12 17Z")),
                    StepStroke(path: P.line(12, 6 + w, 12, 8 + w), opacity: o),
                    StepStroke(path: P.moved(svg("M15 20L13.1094 21.2604C12.4376 21.7083 11.5624 21.7083 10.8906 21.2604L9 20"), P.move(0, c)))]
        case .shot:
            let v = stepKey(f, [(0, 0, q), (12, 1, out), (30, 0, nil)])
            let corners = [("M3 7V7C3 5.89543 3.89543 5 5 5V5", 1.0, 1.0), ("M19 5V5C20.1046 5 21 5.89543 21 7V7", -1, 1), ("M5 19V19C3.89543 19 3 18.1046 3 17V17", 1, -1)]
            var strokes = corners.map { d, x, y in StepStroke(path: P.moved(svg(d), P.move(x * v, y * v))) }
            strokes += ["M14 5H15", "M9 5H10", "M10 19H9", "M3 13V11"].map { StepStroke(path: svg($0), opacity: 1 - 0.7 * v) }
            strokes.append(StepStroke(path: P.ellipse(18.5, 15.5, 4.5, 4.5)))
            strokes.append(StepStroke(path: P.ellipse(18.5, 15.5, 1.5, 1.5), opacity: stepKey(f, [(8, 1, q), (12, 0.1, q), (18, 1, nil)])))
            return strokes
        case .mail:
            let y = stepKey(f, [(0, 0, q), (12, -1.5, q), (28, 0.18, q), (39, 0, nil)])
            let r = stepKey(f, [(0, 0, q), (12, -5, q), (28, 1, q), (39, 0, nil)])
            let m = stepKey(f, [(0, 12.6, q), (12, 10.6, q), (28, 12.8, q), (39, 12.6, nil)])
            let carry = P.turn(r, 12, 12).concatenating(P.move(0, y))
            return [StepStroke(path: P.moved(CGPath(roundedRect: CGRect(x: 3, y: 5, width: 18, height: 14), cornerWidth: 2, cornerHeight: 2, transform: nil), carry)),
                    StepStroke(path: P.moved(P.rounded([pt(3.8, 7), pt(12, m), pt(20.2, 7)], [0, 1.2, 0], closed: false), carry))]
        case .send:
            let d = f < 18 ? stepKey(f, [(0, 0, inward), (18, 9, nil)]) : stepKey(f, [(18, -9, out), (40, 0, nil)])
            let o = f < 18 ? stepKey(f, [(0, 1, inward), (18, 0, nil)]) : stepKey(f, [(18, 0, out), (40, 1, nil)])
            return [StepStroke(path: P.moved(svg("M9.61946 10.8613L20.9997 4.55422M9.04735 10.9043L4.10061 5.68812C3.49632 5.05091 3.94803 4 4.82621 4H20.2513C21.0247 4 21.5054 4.84039 21.1132 5.50702L13.1902 18.9762C12.7433 19.7358 11.6035 19.5879 11.3654 18.7393L9.28458 11.3223C9.24066 11.1658 9.15923 11.0223 9.04735 10.9043Z"), P.move(d, -d)), opacity: o)]
        case .hand:
            let a = stepKey(f, [(0, 0, q), (13, -18, q), (27, 14, q), (40, -8, q), (54, 0, nil)])
            return [StepStroke(path: P.moved(svg("M17.0016 7.5C17.0016 6.67157 17.6732 6 18.5016 6C19.33 6 20.0016 6.67157 20.0016 7.5V13.8292C20.0016 17.7895 16.7911 21 12.8308 21C10.1685 21 7.72528 19.525 6.48529 17.169L3.8065 12.0793C3.62131 11.7274 3.66217 11.2993 3.91055 10.9888L4.25222 10.5617C4.94224 9.69921 6.20083 9.55937 7.06335 10.2494L8.00161 11V5.5C8.00161 4.67157 8.67319 4 9.50161 4C10.33 4 11.0016 4.67157 11.0016 5.5M17.0016 7.5V5.5C17.0016 4.67157 16.33 4 15.5016 4C14.6732 4 14.0016 4.67157 14.0016 5.5M17.0016 7.5V12M11.0016 5.5V4.5C11.0016 3.67157 11.6732 3 12.5016 3C13.33 3 14.0016 3.67157 14.0016 4.5V5.5M11.0016 5.5V11M14.0016 5.5V11.5"), P.turn(a, 12, 21)))]
        case .key:
            let a = stepKey(f, [(0, 0, StepCurve.tick), (20, -35, nil), (28, -35, StepCurve.tick), (46, 0, nil)])
            let turned = P.turn(a, 15.5, 8.5)
            return [StepStroke(path: P.moved(svg("M15.4 8.5H15.5H15.6M16 8.5C16 8.77614 15.7761 9 15.5 9C15.2239 9 15 8.77614 15 8.5C15 8.22386 15.2239 8 15.5 8C15.7761 8 16 8.22386 16 8.5Z"), turned)),
                    StepStroke(path: P.moved(svg("M15.5 14C18.5376 14 21 11.5376 21 8.5C21 5.46243 18.5376 3 15.5 3C12.4624 3 10 5.46243 10 8.5C10 8.96094 10.0567 9.40863 10.1635 9.83649L4.58579 15.4142C4.21071 15.7893 4 16.298 4 16.8284V19C4 19.5523 4.44772 20 5 20H7.17157C7.70201 20 8.21071 19.7893 8.58579 19.4142L10 18V15.5H12.5L14.1635 13.8365C14.5914 13.9433 15.0391 14 15.5 14Z"), turned), square: true)]
        case .eye:
            let c = stepKey(f, [(0, 0, nil), (34, 0, q), (39, 1, q), (46, 0, nil)])
            let up = 2.97 + (17.5 - 2.97) * c, low = 21.03 + (19 - 21.03) * c
            let lid = CGMutablePath()
            lid.move(to: pt(2.50257, 11.0947))
            lid.addCurve(to: pt(21.4974, 11.0946), control1: pt(7.33998, up), control2: pt(16.66, up))
            lid.addCurve(to: pt(21.4974, 12.9053), control1: pt(21.8293, 11.6521), control2: pt(21.8293, 12.3477))
            lid.addCurve(to: pt(2.50257, 12.9054), control1: pt(16.66, low), control2: pt(7.33998, low))
            lid.addCurve(to: pt(2.50257, 11.0947), control1: pt(2.17069, 12.3479), control2: pt(2.17069, 11.6523))
            lid.closeSubpath()
            let look = stepKey(f, [(0, 0, q), (12, 1.6, q), (24, -1.2, q), (34, 0, nil)])
            return [StepStroke(path: lid), StepStroke(path: P.ellipse(12 + look, 12, 3, 3), opacity: 1 - c)]
        case .robot:
            let a = stepKey(f, [(0, 0, q), (14, -7, q), (28, 4, q), (40, 0, nil)])
            let ry = stepKey(f, [(0, 0.5, nil), (18, 0.5, q), (21, 0.02, q), (25, 0.5, nil)])
            let tilt = P.turn(a, 12, 19)
            return [StepStroke(path: P.moved(svg("M12 5V3M3.5 9C2.94772 9 2.5 9.44772 2.5 10C2.5 10.5523 2.94772 11 3.5 11M20.5 9C21.0523 9 21.5 9.44772 21.5 10C21.5 10.5523 21.0523 11 20.5 11M10 14.5H14M3.5 16V7C3.5 5.89543 4.39543 5 5.5 5H18.5C19.6046 5 20.5 5.89543 20.5 7V16C20.5 17.6569 19.1569 19 17.5 19H6.5C4.84315 19 3.5 17.6569 3.5 16Z"), tilt)),
                    StepStroke(path: P.moved(P.ellipse(8.5, 10, 0.5, ry), tilt)),
                    StepStroke(path: P.moved(P.ellipse(15.5, 10, 0.5, ry), tilt))]
        case .memory:
            // The folds light up in turn, left and right, on the stagger of
            // Codex's Memory pages.
            let order = [0, 1, 4, 5, 2, 3, 6, 7, 8]
            return StepArt.brain.enumerated().map { index, d in
                let d0 = Double(order.firstIndex(of: index) ?? 0) * 6
                return StepStroke(path: svg(d), opacity: stepKey(f, [(d0, 1, q), (d0 + 8, 0.25, q), (d0 + 22, 1, nil)]))
            }
        case .download:
            let y = 15 + stepKey(f, [(0, 0, out), (13, 2.2, inward), (27, 0, nil)])
            let arrow = CGMutablePath()
            arrow.addPath(svg("M3 5H7C9.76142 5 12 7.23858 12 10V15"))
            arrow.addLine(to: pt(12, y))
            arrow.move(to: pt(12, y)); arrow.addLine(to: pt(15.75, y - 3.75))
            arrow.move(to: pt(12, y)); arrow.addLine(to: pt(8.25, y - 3.75))
            return [StepStroke(path: svg("M3 9V17C3 18.1046 3.89543 19 5 19H19C20.1046 19 21 18.1046 21 17V7C21 5.89543 20.1046 5 19 5H16")), StepStroke(path: arrow)]
        case .upload:
            let y = 12 - stepKey(f, [(0, 0, out), (13, 2.4, inward), (27, 0, nil)])
            let arrow = CGMutablePath()
            arrow.move(to: pt(12, 19)); arrow.addLine(to: pt(12, y))
            arrow.move(to: pt(12, y)); arrow.addLine(to: pt(14.5, y + 2.5))
            arrow.move(to: pt(12, y)); arrow.addLine(to: pt(9.5, y + 2.5))
            return [StepStroke(path: svg("M8 19H7C4.23858 19 2 16.7614 2 14C2 11.4673 3.88316 9.37436 6.32568 9.04508C7.13649 6.69118 9.37075 5 12 5C15.3137 5 18 7.68629 18 11C20.2091 11 22 12.7909 22 15C22 17.2091 20.2091 19 18 19H16")), StepStroke(path: arrow)]
        case .code:
            let v = 1.8 * stepKey(f, [(0, 0, out), (14, 1, inward), (30, 0, nil)])
            return [StepStroke(path: P.moved(svg("M17 8L20.2929 11.2929C20.6834 11.6834 20.6834 12.3166 20.2929 12.7071L17 16"), P.move(v, 0))),
                    StepStroke(path: P.moved(svg("M7 16L3.70711 12.7071C3.31658 12.3166 3.31658 11.6834 3.70711 11.2929L7 8"), P.move(-v, 0)))]
        case .fill:
            let g = stepKey(f, [(0, 1, inward), (8, 0, nil), (10, 0, out), (30, 1, nil)])
            return [StepStroke(path: svg("M9 21H7C5.89543 21 5 20.1046 5 19V5C5 3.89543 5.89543 3 7 3H17C18.1046 3 19 3.89543 19 5V10")),
                    StepStroke(path: P.partial([pt(13.5, 19), pt(15.5, 21), pt(20.5, 15)], g), opacity: g > 0.02 ? 1 : 0)]
        case .plan:
            return [StepStroke(path: svg("M13 16H20M13 8H20"))] + [[pt(4, 9), pt(5.5, 10), pt(8.5, 6)], [pt(4, 17), pt(5.5, 18), pt(8.5, 14)]].enumerated().map { i, points in
                let o = Double(i) * 8
                let g = stepKey(f, [(o, 1, inward), (o + 7, 0, nil), (o + 8, 0, out), (o + 26, 1, nil)])
                return StepStroke(path: P.partial(points, g), opacity: g > 0.02 ? 1 : 0)
            }
        case .dialog:
            let y = stepKey(f, [(0, 0, q), (12, -1, q), (26, 0.2, q), (38, 0, nil)])
            let r = stepKey(f, [(0, 0, q), (12, -5, q), (26, 1.5, q), (38, 0, nil)])
            return [StepStroke(path: P.moved(svg("M12 21C16.9706 21 21 16.9706 21 12C21 7.02944 16.9706 3 12 3C7.02944 3 3 7.02944 3 12C3 13.3544 3.29919 14.639 3.83508 15.7911C3.93688 16.01 3.96848 16.2564 3.91125 16.4909L3.1326 19.682C2.95662 20.4032 3.60019 21.058 4.32437 20.8945L7.65314 20.1428C7.8775 20.0921 8.11161 20.1223 8.32149 20.2164C9.44452 20.7199 10.6895 21 12 21Z"), P.turn(r, 4, 20).concatenating(P.move(0, y))))]
        case .close:
            let g = stepKey(f, [(0, 1, inward), (10, 0, nil), (16, 0, out), (32, 1, nil)])
            let d = -3.5 * stepKey(f, [(0, 0, inward), (10, 1, nil), (16, 1, out), (32, 0, nil)])
            return [StepStroke(path: svg("M19 5H5C3.89543 5 3 5.89543 3 7V17C3 18.1046 3.89543 19 5 19H19C20.1046 19 21 18.1046 21 17V7C21 5.89543 20.1046 5 19 5Z")),
                    StepStroke(path: P.line(6.5, 8.5, 6.5 + 4 * g, 8.5), opacity: g > 0.02 ? 1 : 0),
                    StepStroke(path: P.moved(svg("M17 8.5H17.5M13.5 8.5H14"), P.move(d, 0)))]
        case .think:
            let h = stepKey(f, [(0, 4.5, q), (5, 0.8, q), (10, 4.5, nil)])
            func eye(_ x: Double) -> CGPath { CGPath(roundedRect: CGRect(x: x, y: 11 - h / 2, width: 2, height: h), cornerWidth: min(1, h / 2), cornerHeight: min(1, h / 2), transform: nil) }
            return [StepStroke(path: P.ellipse(12, 12, 9, 9)), StepStroke(path: eye(8.5), fill: true), StepStroke(path: eye(13.5), fill: true)]
        case .done:
            let g = stepKey(f, [(0, 0, out), (22, 1, nil)])
            return [StepStroke(path: P.partial([pt(5, 12.75), pt(10, 19), pt(19, 5)], g), opacity: g > 0.02 ? 1 : 0)]
        case .fail:
            let x = stepKey(f, [(0, 0, nil), (4, -1.8, nil), (8, 1.6, nil), (12, -1, nil), (16, 0.6, nil), (20, 0, nil)])
            let a = stepKey(f, [(4, 0, out), (16, 1, nil)]), b = stepKey(f, [(8, 0, out), (20, 1, nil)])
            let shake = P.move(x, 0)
            return [StepStroke(path: P.moved(svg("M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C16.9706 3 21 7.02944 21 12Z"), shake)),
                    StepStroke(path: P.moved(P.partial([pt(15, 9), pt(9, 15)], a), shake), opacity: a > 0.02 ? 1 : 0),
                    StepStroke(path: P.moved(P.partial([pt(9, 9), pt(15, 15)], b), shake), opacity: b > 0.02 ? 1 : 0)]
        }
    }

    /// Central's brain, fold by fold.
    static let brain = [
        "M4.33682 11.0002C4.12085 10.5456 4 10.037 4 9.5002C4 7.73696 5.30385 6.27826 7 6.03564",
        "M19.6632 11.0002C19.8792 10.5456 20 10.037 20 9.5002C20 7.73696 18.6961 6.27826 17 6.03564",
        "M7 16.8295C6.68722 16.94 6.35064 17.0002 6 17.0002C4.34315 17.0002 3 15.657 3 14.0002C3 12.694 3.83481 11.5827 5 11.1709",
        "M17 16.8295C17.3128 16.94 17.6494 17.0002 18 17.0002C19.6569 17.0002 21 15.657 21 14.0002C21 12.694 20.1652 11.5827 19 11.1709",
        "M12 5.5C12 4.11929 10.8807 3 9.5 3C8.11929 3 7 4.11929 7 5.5C7 6.06291 7.18604 6.58237 7.5 7.00024",
        "M12 5.5C12 4.11929 13.1193 3 14.5 3C15.8807 3 17 4.11929 17 5.5C17 6.06291 16.814 6.58237 16.5 7.00024",
        "M12 5.5V17.5",
        "M12 17.5C12 19.433 10.433 21 8.5 21C6.567 21 5 19.433 5 17.5",
        "M19 17.5C19 19.433 17.433 21 15.5 21C13.567 21 12 19.433 12 17.5",
    ]

    /// The pencil's drift in Codex's New chat, frame by frame, on our grid:
    /// a small loop, up and to the right and back.
    static let drift: [(Double, Double)] = [
        (0, 0), (-0.006, -0.011), (-0.028, -0.044), (-0.06, -0.102), (-0.102, -0.184), (-0.15, -0.292), (-0.2, -0.425), (-0.247, -0.589),
        (-0.281, -0.779), (-0.292, -0.991), (-0.265, -1.223), (-0.192, -1.462), (-0.066, -1.694), (0.112, -1.908), (0.328, -2.093), (0.64, -2.273),
        (0.986, -2.363), (1.339, -2.35), (1.678, -2.238), (1.979, -2.044), (2.231, -1.787), (2.424, -1.483), (2.549, -1.142), (2.591, -0.785),
        (2.539, -0.431), (2.394, -0.106), (2.167, 0.172), (1.979, 0.3), (1.745, 0.418), (1.492, 0.498), (1.234, 0.529), (0.988, 0.516),
        (0.762, 0.464), (0.563, 0.39), (0.395, 0.304), (0.256, 0.215), (0.15, 0.136), (0.072, 0.07), (0.022, 0.022), (0, 0),
    ]

    /// Every frame of its gesture, drawn once: per stroke, its paths and
    /// opacities frame by frame, and whether it moves at all.
    struct Sampled {
        let rest: [StepStroke]
        let paths: [[CGPath]]
        let opacities: [[Double]]
        let moves: [Bool]
        let fades: [Bool]
    }

    @MainActor private static var sampled: [StepArt: Sampled] = [:]

    @MainActor var frames60: Sampled {
        if let hit = StepArt.sampled[self] { return hit }
        let count = Int(frames.rounded(.up))
        let all = (0...count).map { draw(Double($0)) }
        let rest = draw(self.rest)
        let strokes = rest.count
        let paths = (0..<strokes).map { i in all.map { i < $0.count ? $0[i].path : rest[i].path } }
        let opacities = (0..<strokes).map { i in all.map { i < $0.count ? $0[i].opacity : rest[i].opacity } }
        let made = Sampled(rest: rest, paths: paths, opacities: opacities,
                           moves: paths.map { list in list.contains { $0 != list[0] } },
                           fades: opacities.map { list in list.contains { $0 != list[0] } })
        StepArt.sampled[self] = made
        return made
    }
}

// MARK: - on screen

/// When the beat began for a step: its gesture and the light over its verb
/// both count from here, 0.6 s in and every 4 s after.
enum StepBeat {
    static let period: CFTimeInterval = 4
    static let offset: CFTimeInterval = 0.6

    /// A layer's time as if it had started at `anchor`.
    static func begin(_ layer: CALayer, anchor: Date?) -> CFTimeInterval {
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        guard let anchor else { return now }
        return now - max(0, Date().timeIntervalSince(anchor))
    }
}

/// A step's mark: still, or making its gesture while its step runs.
struct StepMark: NSViewRepresentable {
    let art: StepArt
    var size: CGFloat = 14
    var tint: Color = Palette.muted
    /// Its step is running: the gesture on every beat.
    var live = false
    /// When the step began, which the beat counts from.
    var anchor: Date? = nil
    /// A mark that plays once (a tick, a failure, a request to you) and
    /// has just landed: it plays now. Otherwise it rests.
    var fresh = false

    @Environment(\.accessibilityReduceMotion) private var still

    func makeNSView(context: Context) -> StepMarkView { StepMarkView() }

    func updateNSView(_ view: StepMarkView, context: Context) {
        view.update(art: art, side: size, ink: tint.resolve(in: context.environment).cgColor,
                    live: live && !still, anchor: anchor, fresh: fresh && !still)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StepMarkView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

final class StepMarkView: NSView {
    private let canvas = CALayer()
    private var shapes: [CAShapeLayer] = []
    private var art: StepArt?
    private var live = false
    private var played = false
    private var anchor: Date?
    private var side: CGFloat = 14

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        // Drawn top down, as the grid is.
        canvas.isGeometryFlipped = true
        layer?.addSublayer(canvas)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        place()
    }

    /// The 24-point grid scaled to the mark's box, a little over it, as a
    /// Symbol draws its art (Glyphs.scale), and centered.
    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.frame = bounds
        canvas.sublayerTransform = StepMarkView.grid(side, in: bounds.size)
        CATransaction.commit()
    }

    /// The grid's transform for a box of `size`. Core Animation hangs a
    /// sublayer transform from the layer's anchor, its middle, not its
    /// corner: the grid's middle is moved onto it. Taken from the corner,
    /// every mark sat 2.5 points right of and under its box's middle, off
    /// the words beside it.
    static func grid(_ side: CGFloat, in size: CGSize) -> CATransform3D {
        let scale = side * 1.1 / 24
        return CATransform3DConcat(
            CATransform3DMakeScale(scale, scale, 1),
            CATransform3DMakeTranslation(scale * (size.width / 2 - 12), scale * (size.height / 2 - 12), 0))
    }

    @MainActor func update(art: StepArt, side: CGFloat, ink: CGColor, live: Bool, anchor: Date?, fresh: Bool) {
        let sampled = art.frames60
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let changed = art != self.art
        if changed {
            shapes.forEach { $0.removeFromSuperlayer() }
            shapes = sampled.rest.map { _ in
                let shape = CAShapeLayer()
                shape.lineWidth = 2
                shape.lineJoin = .round
                canvas.addSublayer(shape)
                return shape
            }
            self.art = art
            played = false
        }
        for (shape, stroke) in zip(shapes, sampled.rest) {
            shape.path = stroke.path
            shape.opacity = Float(stroke.opacity)
            shape.lineCap = stroke.square ? .square : .round
            shape.fillColor = stroke.fill ? ink : nil
            shape.strokeColor = stroke.fill ? nil : ink
        }
        if self.side != side { self.side = side; place() }
        CATransaction.commit()

        if art.once {
            // Played once as it lands, never again as the row is drawn anew.
            if fresh, !played { played = true; play(sampled, repeating: false) }
            return
        }
        guard changed || live != self.live || anchor != self.anchor else { return }
        self.live = live
        self.anchor = anchor
        shapes.forEach { $0.removeAnimation(forKey: "gesture") }
        if live { play(sampled, repeating: true) }
    }

    private func play(_ sampled: StepArt.Sampled, repeating: Bool) {
        let length = CFTimeInterval((sampled.paths.first?.count ?? 1) - 1) / 60
        let begin = StepBeat.begin(canvas, anchor: repeating ? anchor : nil)
        for (i, shape) in shapes.enumerated() {
            var parts: [CAAnimation] = []
            if sampled.moves[i] {
                let move = CAKeyframeAnimation(keyPath: "path")
                move.values = sampled.paths[i]
                move.calculationMode = .linear
                parts.append(move)
            }
            if sampled.fades[i] {
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = sampled.opacities[i].map { NSNumber(value: $0) }
                fade.calculationMode = .linear
                parts.append(fade)
            }
            guard !parts.isEmpty else { continue }
            for part in parts {
                part.duration = length
                part.beginTime = repeating ? StepBeat.offset : 0
            }
            let group = CAAnimationGroup()
            group.animations = parts
            group.duration = repeating ? max(StepBeat.period, StepBeat.offset + length) : length
            group.repeatCount = repeating ? .infinity : 1
            group.beginTime = begin
            group.fillMode = .both
            group.isRemovedOnCompletion = true
            shape.add(group, forKey: "gesture")
        }
    }
}
