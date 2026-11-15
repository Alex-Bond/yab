import SwiftUI

/// The Mac's folder, drawn by the same geometry (FolderGrid in
/// Sources/Fast/AgentFace.swift) in the space's own shades (Shades in
/// Sources/Fast/Design.swift): a back with its tab, a front that turns down
/// on its hinge as the folder opens, the whole turned a little toward you,
/// with a plain front, as ordinary desktop folders. The prototype draws it the same way
/// (folder.js); every folder on the iPhone is Yab's own.
struct FolderIcon: View {
    var open: Bool
    /// The drawn size. A row's 20-point slot draws it 8% larger, as the
    /// prototype does (FolderIcon.slot).
    var size: CGFloat = 22
    /// The color it sits on: a space's wash. Nil is Work's, the prototype's default.
    var base: RGB? = nil
    var dark: Bool = false
    var variant: Variant = .folder
    /// The line's width in points; nil is 2 on the 24-point grid (Face's `weight`).
    var weight: CGFloat? = nil

    /// Under way between shut and open; nil at rest, where nothing redraws.
    @State private var fold: FolderFold?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Variant: Sendable {
        /// A folder of tabs from the Mac.
        case folder
        /// A task result uses the same ordinary folder, without an agent face.
        case task
    }

    /// A folder's size for an icon slot of `slot` points.
    static func slot(_ slot: CGFloat) -> CGFloat { (slot * 1.08).rounded() }

    var body: some View {
        TimelineView(.animation(paused: fold == nil)) { timeline in
            drawing(fold?.pose(at: timeline.date) ?? (open ? .open : .shut))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onChange(of: open) { _, open in
            guard !reduceMotion else { fold = nil; return }
            let now = Date()
            fold = FolderFold(from: fold?.pose(at: now) ?? (open ? .shut : .open), start: now, opening: open)
        }
        .task(id: fold) {
            guard let fold else { return }
            try? await Task.sleep(for: .seconds(fold.duration))
            if !Task.isCancelled { self.fold = nil }
        }
    }

    private func drawing(_ pose: FolderPose) -> some View {
        let shades = FolderShades(on: base ?? RGB(226, 233, 244), dark: dark)
        return Canvas { context, canvas in
            let rect = CGRect(origin: .zero, size: canvas)
            let k = rect.width / 24
            func place(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x * k, y: q.y * k) }
            func path(_ points: [CGPoint], close: Bool) -> Path {
                var p = Path()
                guard let first = points.first else { return p }
                p.move(to: place(first))
                for q in points.dropFirst() { p.addLine(to: place(q)) }
                if close { p.closeSubpath() }
                return p
            }
            let back = FolderGrid.back.map { FolderGrid.project($0, front: false, pose: pose) }
            let front = FolderGrid.front.map { FolderGrid.project($0, front: true, pose: pose) }
            let width = weight ?? 2 * k
            let line = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            // The back, filled and outlined; the front over it, filled; then the
            // front's sides and foot, and its top edge as the seam.
            context.fill(path(back, close: true), with: .color(shades.back))
            context.stroke(path(back, close: true), with: .color(shades.line), style: line)
            context.fill(path(front, close: true), with: .color(shades.body))
            let sides = Array(front[(FolderGrid.edge - 1)...]) + [front[0]]
            context.stroke(path(sides, close: false), with: .color(shades.line), style: line)
            let seamWidth = (FolderGrid.seam + (2 - FolderGrid.seam) * pose.flap) * width / 2
            let seam = Array(front.prefix(FolderGrid.edge))
            context.stroke(path(seam, close: false), with: .color(shades.line),
                           style: StrokeStyle(lineWidth: seamWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

/// A folder on its way, on the Mac's clock and curves (FaceView.fold): opening
/// it turns first and its front lets down from there; shutting, the front
/// comes up before it turns back. From wherever a move reversed midway, each
/// part runs the rest of its way.
struct FolderFold: Equatable {
    let from: FolderPose
    let start: Date
    let opening: Bool

    var duration: TimeInterval { opening ? 0.3 : 0.24 }

    private static let arrive = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.2, y: 0.8), endControlPoint: UnitPoint(x: 0.2, y: 1))
    private static let easeOut = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0, y: 0), endControlPoint: UnitPoint(x: 0.58, y: 1))

    func pose(at date: Date) -> FolderPose { pose(progress: date.timeIntervalSince(start) / duration) }

    func pose(progress: Double) -> FolderPose {
        let p = min(1, max(0, progress))
        func part(_ start: Double, _ length: Double) -> Double { min(1, max(0, (p - start) / length)) }
        if opening {
            let turn = CGFloat(Self.arrive.value(at: part(0, 0.5)))
            let flap = CGFloat(Self.arrive.value(at: part(0.3, 0.7)))
            return FolderPose(flap: from.flap + (1 - from.flap) * flap, turn: from.turn + (1 - from.turn) * turn)
        }
        let flap = CGFloat(Self.easeOut.value(at: part(0, 0.55)))
        let turn = CGFloat(UnitCurve.easeInOut.value(at: part(0.45, 0.55)))
        return FolderPose(flap: from.flap * (1 - flap), turn: from.turn * (1 - turn))
    }
}

/// The folder's three shades on a backdrop: its line, its body and its back,
/// the backdrop's hue at other lightnesses in OKLCH (Shades on the Mac).
struct FolderShades {
    let line: Color
    let body: Color
    let back: Color

    init(on base: RGB, dark: Bool) {
        let (l, c, h) = OKLCH.from(base)
        func ink(_ L: Double, _ more: Double) -> Color { OKLCH.color(L, min(0.13, c * more), h) }
        if dark {
            line = ink(0.86, 0.7)
            body = ink(min(0.66, l + 0.18), 1)
            back = ink(min(0.55, l + 0.05), 1.2)
        } else {
            line = ink(0.34, 1.1)
            body = ink(min(0.99, l + (1 - l) * 0.7), 0.5)
            back = ink(l - 0.09, 1.3)
        }
    }
}

/// sRGB to and from OKLCH, where lightness is what the eye sees and the hue
/// holds still (NSColor.oklch on the Mac).
enum OKLCH {
    static func from(_ rgb: RGB) -> (Double, Double, Double) {
        func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let r = linear(Double(rgb.r) / 255), g = linear(Double(rgb.g) / 255), b = linear(Double(rgb.b) / 255)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return (L, hypot(a, B), atan2(B, a))
    }

    static func rgb(_ L: Double, _ C: Double, _ h: Double) -> (Double, Double, Double) {
        let a = C * cos(h), b = C * sin(h)
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        func gamma(_ x: Double) -> Double {
            let x = max(0, min(1, x))
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return (gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    static func color(_ L: Double, _ C: Double, _ h: Double) -> Color {
        let (r, g, b) = rgb(L, C, h)
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - the Mac's folder geometry, verbatim

/// A folder on the 24-point grid, as tall as the face's circle, a tab at its
/// top left, and a front that turns down on a hinge along its foot as the
/// folder opens. Opening, it turns as a thing does: it swings a little to one
/// side about its upright middle, seen with some perspective, and leans.
/// The same as FolderGrid in Sources/Fast/AgentFace.swift; keep the two the same.
enum FolderGrid {
    static let eyes: CGFloat = 14.6
    static let foot: CGFloat = 20.5
    static let yaw: CGFloat = 23
    static let flap: CGFloat = 47
    static let roll: CGFloat = -8
    static let camera: CGFloat = 116
    static let corner: CGFloat = 2
    static let frontFoot: CGFloat = 2.8
    static let frontTop: CGFloat = 1.6
    static let lip: CGFloat = 9
    static let seam: CGFloat = 1.5

    static func project(_ point: CGPoint, front: Bool, pose: FolderPose) -> CGPoint {
        let radian = CGFloat.pi / 180
        let theta = flap * pose.flap * radian, phi = yaw * pose.turn * radian, rho = roll * pose.turn * radian
        var y = point.y, z: CGFloat = 0
        if front {
            let d = foot - y
            y = foot - d * cos(theta)
            z = d * sin(theta)
        }
        let x2 = 12 + (point.x - 12) * cos(phi) + z * sin(phi)
        let z2 = -(point.x - 12) * sin(phi) + z * cos(phi)
        let scale = camera / (camera - z2)
        let dx = (x2 - 12) * scale, dy = 13 + (y - 13) * scale - foot
        return CGPoint(x: 12 + dx * cos(rho) - dy * sin(rho), y: foot + dx * sin(rho) + dy * cos(rho))
    }

    static func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, from a0: CGFloat, to a1: CGFloat) -> [CGPoint] {
        guard r > 0.01 else { return [CGPoint(x: cx, y: cy)] }
        return (0...8).map { i in
            let a = (a0 + (a1 - a0) * CGFloat(i) / 8) * .pi / 180
            return CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
        }
    }

    static let back: [CGPoint] = {
        let r = corner
        var points = [CGPoint(x: 3, y: 20.5 - frontFoot), CGPoint(x: 3, y: 4.5 + r)]
        points += arc(3 + r, 4.5 + r, r, from: 180, to: 270)
        points += [CGPoint(x: 9.3, y: 4.5), CGPoint(x: 11.2, y: 6.5)]
        points += arc(21 - r, 6.5 + r, r, from: 270, to: 360)
        points += arc(21 - frontFoot, 20.5 - frontFoot, frontFoot, from: 0, to: 90)
        points += arc(3 + frontFoot, 20.5 - frontFoot, frontFoot, from: 90, to: 180)
        return points
    }()

    static let front: [CGPoint] = {
        let t = frontTop, r = frontFoot
        var points = arc(3 + t, lip + t, t, from: 180, to: 270)
        points += arc(21 - t, lip + t, t, from: 270, to: 360)
        points += arc(21 - r, 20.5 - r, r, from: 0, to: 90)
        points += arc(3 + r, 20.5 - r, r, from: 90, to: 180)
        return points
    }()
    static let edge = 18
}

/// How far a folder is on its way open: turned, and its front let down.
struct FolderPose: Equatable, Sendable {
    var flap: CGFloat
    var turn: CGFloat

    static let shut = FolderPose(flap: 0, turn: 0)
    static let open = FolderPose(flap: 1, turn: 1)
}
