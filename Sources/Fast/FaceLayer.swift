import AppKit
import SwiftUI

// The face, drawn by Core Animation. Each pose is handed to the render
// server as a set of animations, looping ones included, so a face that
// watches, reads or waves costs the main thread nothing between one pose
// and the next. Drawn with SwiftUI's own animations, every face on screen
// woke the whole window's graph sixty times a second, forever: ten agent
// tabs held a quarter of a core at rest, and a folder opening had to share
// its frames with them.
//
// The drawing is the one in AgentFace.swift, on the same 24-point grid:
// FaceOutline for the circle and the hand, Eyes for the eyes and the tick,
// FolderOpen for a task's folder. Only the motion moved.

struct Face: NSViewRepresentable {
    let pose: FacePose
    let size: CGFloat
    /// Its ink; the hand is always the full ink, since it asks for you.
    var tint: Color = Palette.ink
    /// A folder's face: the outline a tall folder's, as high as the circle,
    /// the eyes on its front, and the hand held inside it.
    var folder = false
    /// The folder is open: its front lets down and outward, taking the
    /// eyes with it.
    var unfolded = false
    /// A script's face: a robot's head (see AgentFace).
    var script = false
    /// Outline width in points; nil follows the drawing size.
    var weight: CGFloat? = nil
    /// A folder's chosen color takes precedence over the window's shades.
    var folderTint: FolderTint? = nil

    @Environment(\.accessibilityReduceMotion) private var still

    func makeNSView(context: Context) -> FaceView { FaceView() }

    func updateNSView(_ view: FaceView, context: Context) {
        let paint = Face.paint(pose: pose, tint: tint, folder: folder, folderTint: folderTint, in: context.environment)
        view.update(pose: pose, size: size, ink: paint.ink, full: paint.full, body: paint.body, back: paint.back,
                    folder: folder, unfolded: unfolded, script: script, still: still, weight: weight)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FaceView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }

    /// Its colors where it is drawn. A folder is drawn in the shades of what
    /// it sits on, as Arc's are: its line, eyes and hand the space's color
    /// deepened, its back in shadow and its front in the light
    /// (Palette.shades). A chosen folder color supplies those shades instead.
    static func paint(pose: FacePose, tint: Color, folder: Bool, folderTint: FolderTint? = nil, in environment: EnvironmentValues)
        -> (ink: CGColor, full: CGColor, body: CGColor?, back: CGColor?) {
        let shades: Shades?
        if folder, let folderTint, folderTint != .black {
            shades = Shades(on: NSColor(folderTint.swatch), dark: environment.colorScheme == .dark)
        } else {
            shades = folder ? environment.tone.map(Palette.shades) ?? Palette.shades(dark: environment.colorScheme == .dark) : nil
        }
        // The hand is drawn in ink, so a tab's "needs you" never goes pale;
        // on a dark plate (the working dock while its question stands at
        // the bottom right) in the plate's lighter ink, as its words are.
        let ink = Palette.ink.resolve(in: environment), given = tint.resolve(in: environment)
        let light = { (c: Color.Resolved) in 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue }
        let hand = light(given) > light(ink) + 0.2 ? given : ink
        return (shades?.line.cgColor ?? (pose == .hand ? hand : given).cgColor,
                shades?.strongNS.cgColor ?? (pose == .hand ? hand : ink).cgColor,
                shades?.body.cgColor, shades?.back.cgColor)
    }
}

/// The face at rest in its pose, as one picture of the same layers: for a
/// row drawn into one picture itself (the strip's next space coming up,
/// StripComing's drawingGroup), where a view of AppKit's is drawn as a
/// yellow sign that it can't be.
struct StillFace: View {
    let pose: FacePose
    let size: CGFloat
    var tint: Color = Palette.ink
    var folder = false
    var unfolded = false
    var script = false
    /// Outline width in points; nil follows the drawing size.
    var weight: CGFloat? = nil
    var folderTint: FolderTint? = nil
    @Environment(\.self) private var environment
    @Environment(\.displayScale) private var scale

    var body: some View {
        let paint = Face.paint(pose: pose, tint: tint, folder: folder, folderTint: folderTint, in: environment)
        Group {
            if let image = FaceView.picture(pose: pose, size: size, ink: paint.ink, full: paint.full, body: paint.body,
                                            back: paint.back, folder: folder, unfolded: unfolded, script: script, scale: scale, weight: weight) {
                Image(decorative: image, scale: scale)
            }
        }
        .frame(width: size, height: size)
    }
}

final class FaceView: NSView {
    // From the outside in: the whole face's tilt (a hand's wave, a stuck
    // face's shake) about a point near its foot, its press about its
    // middle, and inside, the outline, and the folder's hand and the eyes,
    // both carried by the folder's front, the eyes turned by the gaze and
    // blinking.
    private let canvas = CALayer()
    private let tilt = CALayer()
    private let press = CALayer()
    private let ring = CAShapeLayer()
    /// A folder's fills, under its outline: the back, whole, and the front
    /// over it, each sampled on the outline's own clock as it opens.
    private let backFill = CAShapeLayer()
    private let frontFill = CAShapeLayer()
    private let outline = CAShapeLayer()
    /// A folder's front's top edge, across the body (FolderGrid.seam).
    private let seam = CAShapeLayer()
    private let wave = CALayer()
    private let hand = CAShapeLayer()
    private let front = CALayer()
    private let gaze = CALayer()
    private let lids = CALayer()
    private let eyes = CAShapeLayer()
    /// While you drive: one z, drifting up off the sleeping face.
    private let zee = CAShapeLayer()
    /// A script's robot: the bolts at the head's sides and its antenna.
    private let bolts = CAShapeLayer()
    private let antenna = CAShapeLayer()

    private var size: CGFloat = 0
    private var weight: CGFloat?
    private var folder = false
    private var pose: FacePose?
    private var still = false
    private var ink = CGColor(gray: 0, alpha: 1)
    private var full = CGColor(gray: 0, alpha: 1)
    private var body: CGColor?
    private var back: CGColor?
    /// Where the circle-to-hand morph, the tick and the folder's front were
    /// last sent, so the next change starts from there.
    private var morph: CGFloat = 0
    private var tick: CGFloat = 0
    /// How far the face is a script's robot (1) rather than the circle (0).
    private var robot: CGFloat = 0
    private var script = false
    private var unfolded = false
    private var fold = Fold(from: .shut, start: 0, duration: 0, opening: false)

    private struct Fold {
        /// Where the move started from, its start and length, and which way.
        let from: FolderPose
        let start: CFTimeInterval
        let duration: CFTimeInterval
        let opening: Bool

        var to: FolderPose { opening ? .open : .shut }

        /// Where it is `elapsed` seconds in.
        func pose(_ elapsed: CFTimeInterval) -> FolderPose {
            FaceView.fold(from: from, opening: opening, progress: duration > 0 ? min(1, elapsed / duration) : 1)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Drawn top down, as the grid is: a layer of our own under the
        // view's, since AppKit decides the flip of a hosting view's own.
        layer = CALayer()
        wantsLayer = true
        canvas.isGeometryFlipped = true
        layer?.addSublayer(canvas)
        canvas.addSublayer(tilt)
        tilt.addSublayer(press)
        press.addSublayer(ring)
        press.addSublayer(backFill)
        press.addSublayer(frontFill)
        press.addSublayer(outline)
        press.addSublayer(seam)
        press.addSublayer(bolts)
        press.addSublayer(antenna)
        press.addSublayer(front)
        front.addSublayer(wave)
        wave.addSublayer(hand)
        tilt.addSublayer(zee)
        front.addSublayer(gaze)
        gaze.addSublayer(lids)
        lids.addSublayer(eyes)
        for shape in [ring, backFill, frontFill, outline, seam, hand, eyes, zee, bolts, antenna] {
            shape.fillColor = nil
            shape.lineJoin = .round
            shape.lineCap = .round
        }
        ring.opacity = 0
        hand.opacity = 0
        bolts.opacity = 0
        antenna.opacity = 0
        zee.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Pictures of faces at rest (StillFace), by everything that draws them.
    private static var pictures: [String: CGImage] = [:]

    /// The face at rest in `pose`, drawn by its own layers once: still,
    /// so every layer stands where the pose ends.
    static func picture(pose: FacePose, size: CGFloat, ink: CGColor, full: CGColor, body: CGColor?, back: CGColor?,
                        folder: Bool, unfolded: Bool, script: Bool, scale: CGFloat, weight: CGFloat? = nil) -> CGImage? {
        let key = [String(describing: pose), "\(size)", "\(String(describing: weight))", "\(scale)", "\(folder)", "\(unfolded)", "\(script)",
                   "\(ink)", "\(full)", "\(String(describing: body))", "\(String(describing: back))"].joined(separator: "|")
        if let made = pictures[key] { return made }
        let view = FaceView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        view.update(pose: pose, size: size, ink: ink, full: full, body: body, back: back,
                    folder: folder, unfolded: unfolded, script: script, still: true, weight: weight)
        let pixels = Int((size * scale).rounded())
        guard pixels > 0, let layer = view.layer,
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        if pictures.count > 64 { pictures.removeAll() }
        pictures[key] = image
        return image
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for shape in [ring, backFill, frontFill, outline, seam, hand, eyes, zee, bolts, antenna] { shape.contentsScale = scale }
    }

    // MARK: - what SwiftUI hands over

    /// The pose being played is the face's first: no motion into it.
    private var fresh = false

    func update(pose: FacePose, size: CGFloat, ink: CGColor, full: CGColor, body: CGColor? = nil, back: CGColor? = nil,
                folder: Bool, unfolded: Bool, script: Bool, still: Bool, weight: CGFloat? = nil) {
        self.still = still
        let rebuilt = size != self.size || folder != self.folder || weight != self.weight
        let turned = script != self.script
        self.script = script
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if rebuilt {
            robot = script ? 1 : 0
            self.size = size
            self.weight = weight
            self.folder = folder
            self.unfolded = unfolded
            fold = Fold(from: unfolded ? .open : .shut, start: 0, duration: 0, opening: unfolded)
            build()
        }
        if ink != self.ink || full != self.full || body != self.body || back != self.back || rebuilt {
            self.ink = ink
            self.full = full
            self.body = body
            self.back = back
            paint()
        }
        CATransaction.commit()
        if unfolded != self.unfolded {
            self.unfolded = unfolded
            unfold(unfolded)
        }
        if pose != self.pose || rebuilt || turned {
            self.pose = pose
            // Made just now: drawn in its pose from the first frame. A
            // folder made as .seen had its eyes for 0.2 s, going, which read
            // as an agent's folder each time one was made (alpha 2026-10-13).
            fresh = rebuilt
            play(pose)
            fresh = false
        }
        if turned, !rebuilt { robotTo(script ? 1 : 0) }
    }

    // MARK: - drawing

    private var k: CGFloat { size / 24 }
    private var box: CGRect { CGRect(x: 0, y: 0, width: size, height: size) }

    private func place(_ layer: CALayer, anchor: CGPoint) {
        layer.bounds = box
        layer.anchorPoint = anchor
        layer.position = CGPoint(x: size * anchor.x, y: size * anchor.y)
    }

    private func build() {
        canvas.frame = box
        for layer in [tilt, press, ring, backFill, frontFill, outline, seam, wave, hand, front, gaze, lids, eyes, zee, bolts, antenna] {
            layer.removeAllAnimations()
            place(layer, anchor: CGPoint(x: 0.5, y: 0.5))
        }
        place(tilt, anchor: CGPoint(x: 0.5, y: 0.88))
        // The eyes blink about their own middle.
        place(lids, anchor: CGPoint(x: 0.5, y: 11 / 24))
        // The z grows about its own middle, off the circle's top right.
        place(zee, anchor: CGPoint(x: 18.6 / 24, y: 4.6 / 24))
        // A folder's front turns on its foot; a folder's hand waves from
        // its wrist, held a little right of and below the body's middle by
        // eye rather than by its box.
        place(front, anchor: CGPoint(x: 0.5, y: FolderGrid.foot / 24))
        wave.bounds = box
        wave.anchorPoint = CGPoint(x: 0.5, y: 16 / 24)
        // Its middle where the eyes' is on the front, which carries both,
        // so the hand turns and lets down with it and never leaves it.
        wave.position = CGPoint(x: size * 0.5 - 0.15 * k, y: size * 16 / 24 - 1 * k)

        ring.path = CGPath(ellipseIn: box.insetBy(dx: 3 * k, dy: 3 * k), transform: nil)
        ring.lineWidth = 1.2 * k
        outline.lineWidth = weight ?? 2 * k
        eyes.lineWidth = weight ?? 2 * k
        zee.lineWidth = 1.6 * k
        bolts.lineWidth = 2 * k
        antenna.lineWidth = 1.6 * k
        let z = CGMutablePath()
        z.addLines(between: [(16.6, 2.6), (20.6, 2.6), (16.6, 6.6), (20.6, 6.6)].map { CGPoint(x: $0.0 * k, y: $0.1 * k) })
        zee.path = z
        hand.path = FaceOutline(t: 1).path(in: box).cgPath
        eyes.path = eyesPath(tick: 0)
        tick = 0
        morph = 0
        hand.transform = CATransform3DMakeScale(0.001, 0.001, 1)
        if folder {
            outline.path = FolderOpen(pose: fold.to).path(in: box).cgPath
            front.transform = frontTransform(fold.to)
            fill(fold.to)
        } else {
            backFill.path = nil
            frontFill.path = nil
            seam.path = nil
            front.transform = CATransform3DIdentity
            robotAt(robot)
        }
        let scale = window?.backingScaleFactor ?? 2
        for shape in [ring, backFill, frontFill, outline, seam, hand, eyes, zee, bolts, antenna] { shape.contentsScale = scale }
    }

    private func paint() {
        eyes.strokeColor = ink
        zee.strokeColor = ink
        bolts.strokeColor = ink
        antenna.strokeColor = ink
        ring.strokeColor = ink
        hand.fillColor = full
        outline.strokeColor = strokeInk(morph)
        seam.strokeColor = strokeInk(morph)
        outline.fillColor = folder ? nil : fillInk(morph)
        frontFill.fillColor = folder ? body : nil
        backFill.fillColor = folder ? back : nil
    }

    /// The fills as they are at `pose`, without motion.
    private func fill(_ pose: FolderPose) {
        let (back, front) = FolderOpen.fills(pose: pose, in: box)
        backFill.path = back.cgPath
        frontFill.path = front.cgPath
        seam.path = FolderOpen.seam(pose: pose, in: box).cgPath
        seam.lineWidth = seamWidth(pose)
    }

    private func seamWidth(_ pose: FolderPose) -> CGFloat {
        (FolderGrid.seam + (2 - FolderGrid.seam) * pose.flap) * (weight.map { $0 / 2 } ?? k)
    }

    private func eyesPath(tick: CGFloat) -> CGPath {
        Eyes(gaze: .zero, open: 1, tick: tick).path(in: box).cgPath
    }

    /// The face's outline stroke gives way to the hand's fill as it morphs.
    private func strokeInk(_ m: CGFloat) -> CGColor {
        ink.copy(alpha: ink.alpha * (folder ? 1 : 1 - max(0, (m - 0.55) / 0.45))) ?? ink
    }

    private func fillInk(_ m: CGFloat) -> CGColor {
        full.copy(alpha: full.alpha * max(0, (m - 0.45) / 0.55)) ?? full
    }

    /// The eyes on a folder's front: lower than a face's, and carried with
    /// the front as the folder turns and it lets down. The turn isn't flat,
    /// so the eyes take its shape where they sit, which over their few
    /// points is flat enough: the map's slope there, and where it puts them.
    private func frontTransform(_ pose: FolderPose) -> CATransform3D {
        let lift = FolderGrid.eyes - 11
        func seen(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            FolderGrid.project(CGPoint(x: x, y: y + lift), front: true, pose: pose)
        }
        let step: CGFloat = 0.5
        let middle = seen(12, 11), across = seen(12 + step, 11), down = seen(12, 11 + step)
        let a = (across.x - middle.x) / step, b = (across.y - middle.y) / step
        let c = (down.x - middle.x) / step, d = (down.y - middle.y) / step
        // The layer turns about its anchor, on the front's foot: where the
        // map puts the anchor, less where it is.
        let anchor = CGPoint(x: 12, y: FolderGrid.foot)
        let moved = CGPoint(x: middle.x + a * (anchor.x - 12) + c * (anchor.y - 11),
                            y: middle.y + b * (anchor.x - 12) + d * (anchor.y - 11))
        let affine = CGAffineTransform(a: a, b: b, c: c, d: d, tx: (moved.x - anchor.x) * k, ty: (moved.y - anchor.y) * k)
        return CATransform3DMakeAffineTransform(affine)
    }

    // MARK: - the folder's front

    private static let arrive = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.2, y: 0.8), endControlPoint: UnitPoint(x: 0.2, y: 1))
    private static let easeOut = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0, y: 0), endControlPoint: UnitPoint(x: 0.58, y: 1))

    /// A folder's way open and shut, as one progress from 0 to 1. Opening,
    /// the shut folder first turns to you whole, and then its front lets
    /// down; shutting, the front shuts first, and then the folder turns
    /// back. So the front is only ever let down from a folder already
    /// turned, and never drawn half shut while the folder turns, when the
    /// back's top edge showed over it as a second line. From wherever a
    /// move reversed midway, `from`, each part runs the rest of its way.
    static func fold(from: FolderPose, opening: Bool, progress p: Double) -> FolderPose {
        func part(_ start: Double, _ length: Double) -> Double { min(1, max(0, (p - start) / length)) }
        if opening {
            let turn = CGFloat(arrive.value(at: part(0, 0.5)))
            let flap = CGFloat(arrive.value(at: part(0.3, 0.7)))
            return FolderPose(flap: from.flap + (1 - from.flap) * flap, turn: from.turn + (1 - from.turn) * turn)
        }
        let flap = CGFloat(easeOut.value(at: part(0, 0.55)))
        let turn = CGFloat(UnitCurve.easeInOut.value(at: part(0.45, 0.55)))
        return FolderPose(flap: from.flap * (1 - flap), turn: from.turn * (1 - turn))
    }

    /// A folder's face opened or shut on its clock, for the bench.
    static var unfolds = 0

    private func unfold(_ open: Bool) {
        guard folder else { return }
        FaceView.unfolds += 1
        // Wherever the last move has got to.
        let now = CACurrentMediaTime()
        let from = fold.pose(now - fold.start)
        let duration = still ? 0 : open ? 0.3 : 0.24
        fold = Fold(from: from, start: now, duration: duration, opening: open)
        let to = fold.to
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.path = FolderOpen(pose: to).path(in: box).cgPath
        front.transform = frontTransform(to)
        fill(to)
        CATransaction.commit()
        guard duration > 0 else { return }
        // Sampled a frame at a time, the outline and the eyes on one clock:
        // the turned front hides a different share of the back from one
        // frame to the next, so the outline isn't one path a path can be
        // tweened into, and each frame is held as drawn.
        let steps = max(2, Int((duration * 120).rounded(.up)))
        let poses = (0...steps).map { fold.pose(duration * Double($0) / Double(steps)) }
        let times = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        let shape = CAKeyframeAnimation(keyPath: "path")
        shape.values = poses.map { FolderOpen(pose: $0).path(in: box).cgPath }
        shape.calculationMode = .discrete
        let carry = CAKeyframeAnimation(keyPath: "transform")
        carry.values = poses.map { NSValue(caTransform3D: frontTransform($0)) }
        let fills = poses.map { FolderOpen.fills(pose: $0, in: box) }
        let backShape = CAKeyframeAnimation(keyPath: "path")
        backShape.values = fills.map { $0.back.cgPath }
        let frontShape = CAKeyframeAnimation(keyPath: "path")
        frontShape.values = fills.map { $0.front.cgPath }
        let seamShape = CAKeyframeAnimation(keyPath: "path")
        seamShape.values = poses.map { FolderOpen.seam(pose: $0, in: box).cgPath }
        let seamWide = CAKeyframeAnimation(keyPath: "lineWidth")
        seamWide.values = poses.map { seamWidth($0) }
        for animation in [shape, backShape, frontShape, seamShape, seamWide] { animation.calculationMode = .discrete }
        for animation in [shape, carry, backShape, frontShape, seamShape, seamWide] {
            animation.duration = duration
            animation.keyTimes = times
        }
        outline.add(shape, forKey: "fold")
        front.add(carry, forKey: "fold")
        backFill.add(backShape, forKey: "fold")
        seam.add(seamShape, forKey: "fold")
        seam.add(seamWide, forKey: "fold width")
        frontFill.add(frontShape, forKey: "fold")
    }

    // MARK: - poses

    private func now(_ layer: CALayer) -> CFTimeInterval { layer.convertTime(CACurrentMediaTime(), from: nil) }

    private func gazeTransform(_ x: CGFloat, _ y: CGFloat) -> CATransform3D {
        CATransform3DMakeTranslation(x * 2.3 * k, y * 2 * k, 0)
    }

    private func current(_ layer: CALayer) -> CATransform3D {
        layer.presentation()?.transform ?? layer.transform
    }

    /// Moves a layer's transform from wherever it is now to `to`.
    private func move(_ layer: CALayer, to: CATransform3D, duration: CFTimeInterval, timing: CAMediaTimingFunction, delay: CFTimeInterval = 0, key: String) {
        let from = current(layer)
        layer.transform = to
        guard !still, duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: to)
        animation.duration = duration
        animation.timingFunction = timing
        if delay > 0 {
            animation.beginTime = now(layer) + delay
            animation.fillMode = .backwards
        }
        layer.add(animation, forKey: key)
    }

    /// A motion that repeats until the pose changes, starting `delay` from now.
    private func loop(_ layer: CALayer, _ keyPath: String, values: [Any], times: [Double], duration: Double, timings: [CAMediaTimingFunction]? = nil, delay: Double, key: String, offset: Double = 0) {
        guard !still else { return }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times.map { NSNumber(value: $0 / duration) }
        animation.duration = duration
        if let timings { animation.timingFunctions = timings }
        animation.repeatCount = .infinity
        animation.beginTime = now(layer) + delay
        animation.timeOffset = offset
        layer.add(animation, forKey: key)
    }

    private static let inOut = CAMediaTimingFunction(name: .easeInEaseOut)
    private static let out = CAMediaTimingFunction(name: .easeOut)
    private static let linear = CAMediaTimingFunction(name: .linear)

    /// A glance path: where the gaze goes and when, held in between, and
    /// blinks at some of the stops, as one repeating pair of animations.
    private struct Script {
        var points: [CGPoint] = []
        var times: [Double] = []
        var timings: [CAMediaTimingFunction] = []
        var blinks: [Double] = []
        var t: Double = 0

        mutating func start(_ p: CGPoint) {
            points = [p]
            times = [0]
        }

        mutating func go(_ p: CGPoint, over: Double, _ timing: CAMediaTimingFunction) {
            t += over
            points.append(p)
            times.append(t)
            timings.append(timing)
        }

        mutating func hold(_ seconds: Double) {
            guard let last = points.last else { return }
            go(last, over: seconds, FaceView.linear)
        }

        mutating func blink() {
            blinks.append(t)
            hold(0.24)
        }
    }

    private func run(_ script: Script, delay: Double) {
        let duration = script.t
        loop(gaze, "transform", values: script.points.map { NSValue(caTransform3D: gazeTransform($0.x, $0.y)) },
             times: script.times, duration: duration, timings: script.timings, delay: delay, key: "gaze")
        guard !script.blinks.isEmpty else { return }
        var values: [Double] = [1]
        var times: [Double] = [0]
        for at in script.blinks {
            values += [1, 0.1, 0.1, 1]
            times += [at, at + 0.06, at + 0.09, at + 0.21]
        }
        values.append(1)
        times.append(duration)
        loop(lids, "transform.scale.y", values: values, times: times, duration: duration, delay: delay, key: "blink")
    }

    private func blinkOnce(after delay: Double) {
        guard !still else { return }
        let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
        blink.values = [1, 0.1, 0.1, 1]
        blink.keyTimes = [0, 0.29, 0.43, 1]
        blink.duration = 0.21
        blink.beginTime = now(lids) + delay
        lids.add(blink, forKey: "blink")
    }

    private func play(_ pose: FacePose) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (layer, key) in [(gaze, "gaze"), (lids, "blink"), (tilt, "tilt"), (wave, "tilt"), (tilt, "wave"), (wave, "wave"), (zee, "snooze"), (zee, "drift")] {
            layer.removeAnimation(forKey: key)
        }
        // What every pose starts from.
        if pose != .hand {
            if morph != 0 { morphTo(0, duration: 0.3, timing: FaceView.inOut) }
            move(tilt, to: CATransform3DIdentity, duration: 0.3, timing: FaceView.inOut, key: "tilt")
            move(wave, to: CATransform3DIdentity, duration: 0.3, timing: FaceView.inOut, key: "tilt")
        }
        if pose != .done {
            if tick != 0 { tickTo(0, spring: false) }
            fade(press, to: 1, duration: 0.3, key: "settle")
        }
        let open: CGFloat = pose == .drive && !script ? 0.12 : 1
        move(lids, to: CATransform3DMakeScale(1, open, 1), duration: 0.3, timing: FaceView.inOut, key: "open")
        if script, pose != .hand {
            scripted(pose)
            return
        }
        // A folder whose task is no longer at work, done, stopped or stuck,
        // is only a folder: its eyes go, and it keeps its full ink, where a
        // tab's face ticks, looks down or steps back.
        let over = folder && (pose == .done || pose == .seen || pose == .stuck)
        if folder, pose != .hand { fade(eyes, to: over ? 0 : 1, duration: fresh ? 0 : 0.2, key: "over") }
        fade(tilt, to: over ? 1 : pose == .seen ? 0.45 : pose == .drive ? 0.5 : pose == .stuck ? 0.6 : 1, duration: 0, key: "dim")

        var script = Script()
        switch pose {
        case .watch:
            // Glances one way, then the other, now and then a blink.
            let first = CGPoint(x: -CGFloat.random(in: 0.4...0.8), y: .random(in: -0.15...0.15))
            move(gaze, to: gazeTransform(first.x, first.y), duration: 0.7, timing: FaceView.inOut, key: "enter")
            script.start(first)
            for i in 0..<6 {
                let side: CGFloat = i % 2 == 0 ? 1 : -1
                script.hold(.random(in: 1.1...2.1))
                if Bool.random() { script.blink() }
                script.go(i == 5 ? first : CGPoint(x: side * .random(in: 0.4...0.8), y: .random(in: -0.15...0.15)), over: 0.7, FaceView.inOut)
            }
            run(script, delay: 0.7)
        case .read:
            // Along a line, back to the start of the next; a blink after a few.
            let start = CGPoint(x: -0.8, y: -0.3)
            move(gaze, to: gazeTransform(start.x, start.y), duration: 0.18, timing: FaceView.out, key: "enter")
            script.start(start)
            for line in 0..<3 {
                let y = -0.3 + CGFloat(line) * 0.3
                if line > 0 { script.go(CGPoint(x: -0.8, y: y), over: 0.18, FaceView.out) }
                script.hold(0.02)
                script.go(CGPoint(x: 0.8, y: y), over: 0.75, FaceView.linear)
                script.hold(0.05)
            }
            script.blink()
            script.hold(0.4)
            script.go(start, over: 0.18, FaceView.out)
            run(script, delay: 0.18)
        case .click:
            // To the spot, the press, and a look back.
            let from = current(gaze)
            gaze.transform = gazeTransform(-0.2, 0)
            if !still {
                let look = CAKeyframeAnimation(keyPath: "transform")
                look.values = [from, gazeTransform(0.6, 0.4), gazeTransform(0.6, 0.4), gazeTransform(-0.2, 0)].map { NSValue(caTransform3D: $0) }
                look.keyTimes = [0, 0.18, 0.87, 1.27].map { NSNumber(value: $0 / 1.27) }
                look.timingFunctions = [FaceView.out, FaceView.linear, FaceView.inOut]
                look.duration = 1.27
                gaze.add(look, forKey: "enter")
            }
            tap(after: 0.2)
        case .type:
            move(gaze, to: gazeTransform(-0.2, 0.55), duration: 0.2, timing: FaceView.out, key: "enter")
            script.start(CGPoint(x: -0.2, y: 0.55))
            for _ in 0..<10 {
                script.go(CGPoint(x: -0.2 + .random(in: -0.12...0.12), y: 0.55), over: 0.07, FaceView.linear)
                script.hold(0.02)
            }
            script.go(CGPoint(x: -0.2, y: 0.55), over: 0.07, FaceView.linear)
            run(script, delay: 0.2)
        case .load:
            // Waiting on the page: it looks up, as you do at a loading bar,
            // drifts a little and blinks now and then. No spinner of its own.
            let first = CGPoint(x: 0.25, y: -0.75)
            move(gaze, to: gazeTransform(first.x, first.y), duration: 0.9, timing: FaceView.inOut, key: "enter")
            script.start(first)
            for i in 0..<4 {
                script.hold(0.5)
                if Bool.random() { script.blink() }
                script.go(CGPoint(x: i % 2 == 0 ? -0.25 : 0.25, y: -0.75), over: 0.9, FaceView.inOut)
            }
            run(script, delay: 0.9)
        case .think:
            // Up and to one side, slowly, and held, never darting.
            let first = CGPoint(x: 0.45, y: -0.55)
            move(gaze, to: gazeTransform(first.x, first.y), duration: 1.2, timing: FaceView.inOut, key: "enter")
            script.start(first)
            for i in 0..<4 {
                script.hold(2)
                if Int.random(in: 0..<3) == 0 { script.blink() }
                script.go(CGPoint(x: i % 2 == 0 ? -0.45 : 0.45, y: -0.55), over: 1.2, FaceView.inOut)
            }
            run(script, delay: 1.2)
        case .hand:
            move(lids, to: CATransform3DMakeScale(1, 0.1, 1), duration: 0.08, timing: FaceView.linear, key: "open")
            morphTo(1, duration: 0.45, timing: CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1), delay: 0.1)
            // A wave as it lands, and a little again every few seconds.
            let rotation = [0.0, -14, 10, -5, 0, 0].map { $0 * .pi / 180 }
            loop(folder ? wave : tilt, "transform.rotation.z", values: rotation, times: [0, 0.16, 0.34, 0.5, 0.68, 4.68], duration: 4.68,
                 timings: [FaceView.inOut, FaceView.inOut, FaceView.inOut, FaceView.inOut, FaceView.linear], delay: 0.55, key: "wave")
        case .drive:
            move(gaze, to: gazeTransform(0, 0.3), duration: 0.3, timing: FaceView.inOut, key: "enter")
            // Asleep until you hand it back: one z comes up off its top
            // right, grows and drifts away, and a second of nothing before
            // the next. The face itself keeps still.
            guard !folder else { break }
            let rise = CATransform3DScale(CATransform3DMakeTranslation(1.6 * k, -5 * k, 0), 1.2, 1.2, 1)
            loop(zee, "opacity", values: [0, 1, 0, 0], times: [0, 0.7, 2.8, 3.8], duration: 3.8,
                 timings: [FaceView.out, FaceView.inOut, FaceView.linear], delay: 0.5, key: "snooze")
            loop(zee, "transform", values: [CATransform3DMakeScale(0.45, 0.45, 1), rise, rise].map { NSValue(caTransform3D: $0) },
                 times: [0, 2.8, 3.8], duration: 3.8, timings: [FaceView.out, FaceView.linear], delay: 0.5, key: "drift")
        case .done where folder, .seen where folder, .stuck where folder:
            break
        case .done:
            // The eyes come to the middle and swing into a tick, held a
            // moment in full ink, then let down slowly to the face's quiet.
            move(gaze, to: gazeTransform(0, 0), duration: 0.18, timing: FaceView.inOut, key: "enter")
            tickTo(1, spring: true, delay: 0.14)
            fade(press, to: 0.45, duration: 1.4, delay: 1.24, key: "settle")
        case .seen:
            move(gaze, to: gazeTransform(0, 0), duration: 0.3, timing: FaceView.inOut, key: "enter")
        case .stuck:
            move(gaze, to: gazeTransform(-0.2, 0.8), duration: 0.3, timing: FaceView.inOut, key: "enter")
            let shake = [0.0, 0, -4, 4, -2, 0].map { $0 * .pi / 180 }
            loop(tilt, "transform.rotation.z", values: shake, times: [0, 3.5, 3.58, 3.66, 3.74, 3.82], duration: 3.82, delay: 0.3, key: "wave")
        }
    }

    /// A script's robot, whose eyes move only while the script acts, and
    /// smoothly, with no blink: along three lines as it reads; low and
    /// swaying a little as it types; to the spot and a soft press as it
    /// clicks; up while a page comes; busy here with nothing to show (an
    /// eval, the page's text), ahead in full ink. Otherwise ahead, dimmed.
    private func scripted(_ pose: FacePose) {
        let acting = [.read, .click, .type, .load, .think].contains(pose)
        fade(tilt, to: acting ? 1 : 0.45, duration: 0.3, key: "dim")
        var script = Script()
        switch pose {
        case .read:
            let start = CGPoint(x: -0.8, y: -0.3)
            move(gaze, to: gazeTransform(start.x, start.y), duration: 0.25, timing: FaceView.inOut, key: "enter")
            script.start(start)
            for (line, y) in [-0.3, 0, 0.3].enumerated() {
                if line > 0 { script.go(CGPoint(x: -0.8, y: y), over: 0.3, FaceView.inOut) }
                script.go(CGPoint(x: 0.8, y: y), over: 0.75, FaceView.inOut)
            }
            script.go(start, over: 0.4, FaceView.inOut)
            run(script, delay: 0.25)
        case .type:
            let start = CGPoint(x: -0.15, y: 0.55)
            move(gaze, to: gazeTransform(start.x, start.y), duration: 0.25, timing: FaceView.inOut, key: "enter")
            script.start(start)
            script.go(CGPoint(x: 0.15, y: 0.55), over: 0.6, FaceView.inOut)
            script.go(start, over: 0.6, FaceView.inOut)
            run(script, delay: 0.25)
        case .click:
            let from = current(gaze)
            gaze.transform = gazeTransform(0, 0)
            guard !still else { break }
            let look = CAKeyframeAnimation(keyPath: "transform")
            look.values = [from, gazeTransform(0.6, 0.4), gazeTransform(0.6, 0.4), gazeTransform(0, 0)].map { NSValue(caTransform3D: $0) }
            look.keyTimes = [0, 0.25, 0.9, 1.3].map { NSNumber(value: $0 / 1.3) }
            look.timingFunctions = [FaceView.inOut, FaceView.linear, FaceView.inOut]
            look.duration = 1.3
            gaze.add(look, forKey: "enter")
            let give = CAKeyframeAnimation(keyPath: "transform.scale")
            give.values = [1, 0.88, 1]
            give.keyTimes = [0, 0.4, 1]
            give.timingFunctions = [FaceView.inOut, FaceView.inOut]
            give.duration = 0.3
            give.beginTime = now(press) + 0.25
            press.add(give, forKey: "press")
        case .load:
            move(gaze, to: gazeTransform(0, -0.75), duration: 0.4, timing: FaceView.inOut, key: "enter")
        default:
            move(gaze, to: gazeTransform(0, 0), duration: 0.4, timing: FaceView.inOut, key: "enter")
        }
    }

    // MARK: - the robot

    /// The robot's parts at `u` of the way from the circle (0) to the head
    /// (1): the head squares first, then the antenna and bolts grow out.
    private func robotParts(_ u: CGFloat) -> (head: CGFloat, grow: CGFloat) {
        func ease(_ x: CGFloat) -> CGFloat { let x = min(1, max(0, x)); return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
        return (ease(u / 0.7), ease((u - 0.35) / 0.65))
    }

    /// A bolt at each side of the head, grown `g` out from it.
    private func boltsPath(_ g: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for x in [3 - 1.8 * g, 21 + 1.8 * g] {
            path.move(to: CGPoint(x: x * k, y: 11.5 * k))
            path.addLine(to: CGPoint(x: x * k, y: 15.5 * k))
        }
        return path
    }

    /// The antenna off the head's top, its stem and the bulb at its end.
    private func antennaPath(_ g: CGFloat) -> CGPath {
        let top = FaceOutline.top, end = top - 2.7 * g, bulb = max(0.01, 1.0 * g)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 12 * k, y: top * k))
        path.addLine(to: CGPoint(x: 12 * k, y: end * k))
        path.addEllipse(in: CGRect(x: (12 - bulb) * k, y: (end - 2 * bulb) * k, width: 2 * bulb * k, height: 2 * bulb * k))
        return path
    }

    /// The eyes sit lower in the head than in the circle.
    private func robotEyes(_ head: CGFloat) -> CATransform3D {
        CATransform3DMakeTranslation(0, 1.8 * k * head, 0)
    }

    /// Everything of the robot drawn as it is at `u`, without motion.
    private func robotAt(_ u: CGFloat) {
        let (head, grow) = robotParts(u)
        outline.path = FaceOutline(t: morph, robot: head).path(in: box).cgPath
        bolts.path = boltsPath(grow)
        antenna.path = antennaPath(grow)
        bolts.opacity = adornmentOpacity(grow: grow, hand: morph)
        antenna.opacity = adornmentOpacity(grow: grow, hand: morph)
        if !folder { front.transform = robotEyes(head) }
    }

    /// The robot's side bolts and antenna must be gone before its outline
    /// reads as a raised hand, then return only as the hand folds away.
    private func adornmentOpacity(grow: CGFloat, hand: CGFloat) -> Float {
        Float(min(1, grow * 3) * max(0, 1 - hand * 4))
    }

    /// The circle into a script's robot (1) and back (0), an agent having
    /// taken its tab over, which then blinks.
    private func robotTo(_ target: CGFloat) {
        guard !folder else { return }
        let from = robot
        robot = target
        robotAt(target)
        guard !still, from != target else { return }
        // Back to the circle, the parts go in first and the head rounds last.
        let us = (0...16).map { i -> CGFloat in
            let x = CGFloat(i) / 16
            return target > from ? x : 1 - x
        }
        var parts: [(CALayer, String, [Any])] = []
        parts.append((outline, "path", us.map { FaceOutline(t: morph, robot: robotParts($0).head).path(in: box).cgPath }))
        parts.append((bolts, "path", us.map { boltsPath(robotParts($0).grow) }))
        parts.append((antenna, "path", us.map { antennaPath(robotParts($0).grow) }))
        parts.append((bolts, "opacity", us.map { adornmentOpacity(grow: robotParts($0).grow, hand: morph) }))
        parts.append((antenna, "opacity", us.map { adornmentOpacity(grow: robotParts($0).grow, hand: morph) }))
        parts.append((front, "transform", us.map { NSValue(caTransform3D: robotEyes(robotParts($0).head)) }))
        for (layer, keyPath, values) in parts {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.duration = 0.6
            layer.add(animation, forKey: "robot " + keyPath)
        }
        if target == 0 { blinkOnce(after: 0.65) }
    }

    private func fade(_ layer: CALayer, to value: Float, duration: CFTimeInterval, delay: CFTimeInterval = 0, key: String) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = value
        guard !still, duration > 0, from != value else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = FaceView.inOut
        if delay > 0 {
            animation.beginTime = now(layer) + delay
            animation.fillMode = .backwards
        }
        layer.add(animation, forKey: key)
    }

    /// Down at once, back on a spring with a little give, iOS's press; a
    /// face's ring from the spot, a folder only gives.
    private func tap(after delay: Double) {
        guard !still else { return }
        // Down in 0.06, then back on a spring (response 0.28, damping 0.55),
        // as one sampled motion.
        let omega = 2 * Double.pi / 0.28, damping = 0.55
        let wd = omega * sqrt(1 - damping * damping)
        let spring = 0.6
        var values: [Double] = [1, 0.8]
        var times: [Double] = [0, 0.06]
        for i in 1...24 {
            let t = spring * Double(i) / 24
            let x = 1 - exp(-damping * omega * t) * (cos(wd * t) + damping * omega / wd * sin(wd * t))
            values.append(0.8 + 0.2 * x)
            times.append(0.07 + t)
        }
        let give = CAKeyframeAnimation(keyPath: "transform.scale")
        give.values = values
        give.keyTimes = times.map { NSNumber(value: $0 / times.last!) }
        give.duration = times.last!
        give.beginTime = now(press) + delay
        press.add(give, forKey: "press")
        blinkOnce(after: delay + 0.07)
        guard !folder else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 1.6
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 0.45
        fadeOut.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fadeOut]
        group.duration = 0.32
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        group.beginTime = now(ring) + delay + 0.07
        ring.add(group, forKey: "ring")
    }

    /// The circle into the hand (1) and back (0): a face's outline morphs
    /// point for point, its stroke giving way to the hand's fill; a
    /// folder's hand grows out of the middle of its body. The eyes go first.
    private func morphTo(_ target: CGFloat, duration: Double, timing: CAMediaTimingFunction, delay: Double = 0) {
        let from = morph
        morph = target
        let steps = 10
        let ms = (0...steps).map { from + (target - from) * CGFloat($0) / CGFloat(steps) }
        var animations: [(CALayer, CAKeyframeAnimation)] = []
        func keyframes(_ layer: CALayer, _ keyPath: String, _ values: [Any]) {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animations.append((layer, animation))
        }
        eyes.opacity = Float(max(0, 1 - target * 2.2))
        keyframes(eyes, "opacity", ms.map { max(0, 1 - $0 * 2.2) })
        if folder {
            hand.opacity = Float(target)
            hand.transform = CATransform3DMakeScale(max(0.001, FolderGrid.handScale * target), max(0.001, FolderGrid.handScale * target), 1)
            keyframes(hand, "opacity", ms.map { $0 })
            keyframes(hand, "transform", ms.map { NSValue(caTransform3D: CATransform3DMakeScale(max(0.001, FolderGrid.handScale * $0), max(0.001, FolderGrid.handScale * $0), 1)) })
        } else {
            outline.path = FaceOutline(t: target, robot: robot).path(in: box).cgPath
            outline.strokeColor = strokeInk(target)
            outline.fillColor = fillInk(target)
            keyframes(outline, "path", ms.map { FaceOutline(t: $0, robot: robot).path(in: box).cgPath })
            keyframes(outline, "strokeColor", ms.map { strokeInk($0) })
            keyframes(outline, "fillColor", ms.map { fillInk($0) })
            let grow = robotParts(robot).grow
            if target == 1 {
                // The robot parts leave before the hand's first outline;
                // delaying their fade with the morph made them look like ears.
                bolts.removeAnimation(forKey: "robot opacity")
                antenna.removeAnimation(forKey: "robot opacity")
                bolts.opacity = 0
                antenna.opacity = 0
            } else {
                bolts.opacity = adornmentOpacity(grow: grow, hand: target)
                antenna.opacity = adornmentOpacity(grow: grow, hand: target)
                keyframes(bolts, "opacity", ms.map { adornmentOpacity(grow: grow, hand: $0) })
                keyframes(antenna, "opacity", ms.map { adornmentOpacity(grow: grow, hand: $0) })
            }
        }
        guard !still else { return }
        for (layer, animation) in animations {
            animation.duration = duration
            animation.timingFunction = timing
            if delay > 0 {
                animation.beginTime = now(layer) + delay
                animation.fillMode = .backwards
            }
            layer.add(animation, forKey: "morph " + animation.keyPath!)
        }
    }

    /// The eyes into the tick and back, on a spring going in.
    private func tickTo(_ target: CGFloat, spring: Bool, delay: Double = 0) {
        let from = tick
        tick = target
        eyes.path = eyesPath(tick: target)
        guard !still else { return }
        let animation = CAKeyframeAnimation(keyPath: "path")
        if spring {
            // Response 0.42, damping 0.82, sampled: a path can't spring by itself.
            let response = 0.42, damping = 0.82
            let omega = 2 * Double.pi / response
            let duration = 0.7
            let steps = 28
            animation.values = (0...steps).map { i -> CGPath in
                let t = duration * Double(i) / Double(steps)
                let wd = omega * sqrt(1 - damping * damping)
                let x = 1 - exp(-damping * omega * t) * (cos(wd * t) + damping * omega / wd * sin(wd * t))
                return eyesPath(tick: from + (target - from) * CGFloat(x))
            }
            animation.duration = duration
        } else {
            animation.values = (0...6).map { eyesPath(tick: from + (target - from) * CGFloat($0) / 6) }
            animation.duration = 0.3
            animation.timingFunction = FaceView.inOut
        }
        if delay > 0 {
            animation.beginTime = now(eyes) + delay
            animation.fillMode = .backwards
        }
        eyes.add(animation, forKey: "tick")
    }
}
