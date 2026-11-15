import AppKit

// The marks on the floating windows' buttons that move: drawn as Core
// Animation layers over the button, so a change is started on the main
// thread and played by the render server. Each changes at once with
// Reduce Motion, and when told `now`: the first word, or a window not
// on screen.

/// A mark in a button, white unless told, centered, the glyph's own square.
private func markLayer(_ name: String, size: CGFloat, in button: NSButton, color: NSColor = .white) -> CALayer {
    let layer = CALayer()
    layer.contents = Glyphs.image(name, size: size, color: color)
    layer.contentsGravity = .center
    layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    button.layer?.addSublayer(layer)
    return layer
}

/// Over the whole button, its middle the button's, so a scale or a turn
/// goes about the mark's middle.
private func center(_ layers: [CALayer], in button: NSButton?) {
    guard let button else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for layer in layers {
        layer.bounds = button.bounds
        layer.position = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        layer.contentsScale = button.window?.backingScaleFactor ?? layer.contentsScale
    }
    CATransaction.commit()
}

private var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
/// Fast out, a soft landing: every mark here moves on it.
let markCurve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

/// A button's mark and its other one, one over the other: turning over,
/// the one going shrinks to half, still whole in color, 0.1 s, and the one
/// coming is there at once, whole, the moment it is gone, as the system's
/// picture in picture swaps pause for play (read off a 120 fps recording).
/// The microphone and the camera of a call, play and pause of a video: one
/// motion for every switch in a floating window.
final class Turn {
    private let first: CALayer
    private let second: CALayer
    private weak var button: NSButton?
    private var on: Bool?

    /// `ink` is the second mark's color, for a switch that turns light
    /// when on (a call's screen shared: dark on white).
    init(on button: NSButton, _ first: String, _ second: String, size: CGFloat, ink: NSColor = .white) {
        self.button = button
        self.first = markLayer(first, size: size, in: button)
        self.second = markLayer(second, size: size, in: button, color: ink)
    }

    /// How long the one going takes to shrink away.
    static let shrink: CFTimeInterval = 0.1

    /// The second mark when true, the first when false.
    func set(_ on: Bool, now: Bool) {
        guard on != self.on else { return }
        let quiet = now || self.on == nil || reduced
        self.on = on
        let going = on ? first : second, coming = on ? second : first
        let half = CATransform3DMakeScale(0.5, 0.5, 1)
        // Where the one going is on screen now: a second press before it is
        // gone shrinks the other from where it has got to.
        let from = going.presentation().map { ($0.transform, $0.opacity) } ?? (going.transform, going.opacity)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        going.removeAnimation(forKey: "turn")
        coming.removeAnimation(forKey: "turn")
        going.opacity = 0
        going.transform = half
        coming.opacity = 1
        coming.transform = CATransform3DIdentity
        CATransaction.commit()
        guard !quiet, from.1 > 0.01 else { return }

        let now = CACurrentMediaTime()
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: from.0)
        scale.toValue = NSValue(caTransform3D: half)
        scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [from.1, from.1, 0]
        fade.keyTimes = [0, 0.85, 1]
        let away = CAAnimationGroup()
        away.animations = [scale, fade]
        away.duration = Self.shrink
        going.add(away, forKey: "turn")

        // Out of sight until the other has shrunk away.
        let wait = CABasicAnimation(keyPath: "opacity")
        wait.fromValue = 0
        wait.toValue = 0
        wait.beginTime = now
        wait.duration = Self.shrink
        coming.add(wait, forKey: "turn")
    }

    func layout() { center([first, second], in: button) }

    /// Both out of sight while something else stands in the button: a
    /// video held up has its spinner where pause was.
    func veil(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        first.isHidden = on
        second.isHidden = on
        CATransaction.commit()
    }
}

/// The speaker with its two waves, or with a cross where they were. Going
/// quiet turns over as any switch does; sound back, the cross goes and the
/// waves come back one after the other, the near one first, 60 ms apart.
final class SpeakerMark {
    private let body: CALayer
    private let inner: CALayer
    private let outer: CALayer
    private let cross: CALayer
    private weak var button: NSButton?
    private var muted: Bool?

    init(on button: NSButton, size: CGFloat) {
        self.button = button
        body = markLayer("speaker.body.fill", size: size, in: button)
        inner = markLayer("speaker.wave.inner.fill", size: size, in: button)
        outer = markLayer("speaker.wave.outer.fill", size: size, in: button)
        cross = markLayer("speaker.xmark", size: size, in: button)
    }

    func set(muted: Bool, now: Bool) {
        guard muted != self.muted else { return }
        let quiet = now || self.muted == nil || reduced
        self.muted = muted
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let small = CATransform3DMakeScale(0.8, 0.8, 1)
        cross.opacity = muted ? 1 : 0
        cross.transform = muted ? CATransform3DIdentity : small
        for wave in [inner, outer] { wave.opacity = muted ? 0 : 1 }
        CATransaction.commit()
        guard !quiet else { return }

        // The model is where it ends; these play the way there.
        cross.add(Self.turn(appearing: muted), forKey: "turn")
        if muted {
            let out = Self.fade(from: 1, to: 0, after: 0, over: 0.12)
            inner.add(out, forKey: "fade")
            outer.add(out, forKey: "fade")
        } else {
            inner.add(Self.fade(from: 0, to: 1, after: 0.06, over: 0.12), forKey: "fade")
            outer.add(Self.fade(from: 0, to: 1, after: 0.12, over: 0.12), forKey: "fade")
        }
    }

    private static func turn(appearing: Bool) -> CAAnimationGroup {
        let small = NSValue(caTransform3D: CATransform3DMakeScale(0.8, 0.8, 1))
        let whole = NSValue(caTransform3D: CATransform3DIdentity)
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = appearing ? small : whole
        scale.toValue = appearing ? whole : small
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = appearing ? 0 : 1
        fade.toValue = appearing ? 1 : 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.14
        group.timingFunction = markCurve
        return group
    }

    private static func fade(from: Float, to: Float, after delay: CFTimeInterval, over duration: CFTimeInterval) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.beginTime = delay > 0 ? CACurrentMediaTime() + delay : 0
        fade.duration = duration
        // Waiting its turn, a wave coming back stays out of sight.
        fade.fillMode = .backwards
        return fade
    }

    func layout() { center([body, inner, outer, cross], in: button) }
}

/// The back or forward mark: its arrow goes once around the way it points,
/// 0.55 s, slow off and slow in, while the 15 stays, as the system's
/// picture in picture turns its arrows. Presses close together add their
/// turns.
final class SkipMark {
    private let arrow: CALayer
    private let digits: CALayer
    private weak var button: NSButton?
    private let forward: Bool

    init(on button: NSButton, forward: Bool, size: CGFloat) {
        self.button = button
        self.forward = forward
        arrow = markLayer(forward ? "goforward.arrow" : "gobackward.arrow", size: size, in: button)
        digits = markLayer("skip.15", size: size, in: button)
    }

    func turn() {
        guard !reduced else { return }
        // In the button's flipped layer coordinates, positive turns right.
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = (forward ? 1.0 : -1.0) * 2 * Double.pi
        spin.isAdditive = true
        spin.duration = 0.55
        spin.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.3, 1)
        arrow.add(spin, forKey: nil)
    }

    /// Nowhere to go this way (a live stream at its edge): faint, as a
    /// button that can't be pressed is.
    func dim(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduced ? 0 : 0.16)
        for layer in [arrow, digits] { layer.opacity = on ? 0.3 : 1 }
        CATransaction.commit()
    }

    func layout() { center([arrow, digits], in: button) }
}

/// A button over a floating window's picture. Under the pointer its
/// circle lightens, a white wash over whatever color it is, the dark
/// glass or the red; pressed, it gives to 92% and comes back as it is let
/// go, which also answers a press on a mark drawn in layers, where
/// there is no image for AppKit to darken.
final class FloatButton: NSButton {
    private let wash = CALayer()
    private var area: NSTrackingArea?
    /// A right-click, where the button has more to offer than its press
    /// (a call's microphone and camera: their devices).
    var onSecondary: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        wash.backgroundColor = NSColor.white.cgColor
        wash.opacity = 0
        // Under the marks, over the circle: first in, and a circle drawn
        // later as a layer of its own goes in under it.
        layer?.addSublayer(wash)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.frame = bounds
        wash.cornerRadius = layer?.cornerRadius ?? bounds.height / 2
        wash.maskedCorners = layer?.maskedCorners ?? wash.maskedCorners
        CATransaction.commit()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onSecondary else { return super.rightMouseDown(with: event) }
        onSecondary()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { lit(true) }
    override func mouseExited(with event: NSEvent) { lit(false) }
    override func viewDidHide() { lit(false) }

    override var isEnabled: Bool {
        didSet { if !isEnabled { lit(false) } }
    }

    private func lit(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        wash.opacity = on && isEnabled ? 0.14 : 0
        CATransaction.commit()
    }

    /// A switch that answers the press itself rather than the release (a
    /// call's microphone and camera): told when it goes down, when the
    /// pointer leaves or comes back while held, and when it is let go,
    /// inside or not. The action is still sent only on a release inside.
    enum Press { case down, held(inside: Bool), up(inside: Bool) }
    var onPress: ((Press) -> Void)?

    /// AppKit's own tracking runs inside: this returns when it is let go.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        guard let onPress, let window else {
            give(true)
            super.mouseDown(with: event)
            give(false)
            return
        }
        // Its own tracking, so the press is known at once, not at the end.
        onPress(.down)
        var inside = true
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let now = bounds.insetBy(dx: -8, dy: -8).contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                onPress(.up(inside: now))
                if now, let action { NSApp.sendAction(action, to: target, from: self) }
                return
            }
            if now != inside {
                inside = now
                onPress(.held(inside: now))
            }
        }
    }

    private func give(_ pressed: Bool) {
        guard let layer, !reduced else { return }
        let w = bounds.width / 2, h = bounds.height / 2
        var to = CATransform3DIdentity
        if pressed {
            to = CATransform3DMakeTranslation(w, h, 0)
            to = CATransform3DScale(to, 0.92, 0.92, 1)
            to = CATransform3DTranslate(to, -w, -h, 0)
        }
        let from = layer.presentation()?.transform ?? layer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = to
        CATransaction.commit()
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = NSValue(caTransform3D: from)
        move.toValue = NSValue(caTransform3D: to)
        move.duration = pressed ? 0.08 : 0.16
        move.timingFunction = markCurve
        layer.add(move, forKey: "give")
    }

    var benchLit: Bool { wash.opacity > 0 }
}

/// Turning in a button while its video is held up: a ring, faint, with a
/// quarter of it white going round, 22 across, as YouTube's and the
/// system's players wait in the middle. Turned by the render server, and
/// only while it shows; still with Reduce Motion.
final class WaitMark {
    private let ring = CAShapeLayer()
    private let arc = CAShapeLayer()
    private weak var button: NSButton?
    private(set) var running = false

    static let side: CGFloat = 22
    static let line: CGFloat = 2.5

    init(on button: NSButton) {
        self.button = button
        let round = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: Self.side, height: Self.side).insetBy(dx: Self.line / 2, dy: Self.line / 2), transform: nil)
        for (layer, color) in [(ring, NSColor(white: 1, alpha: 0.22)), (arc, NSColor.white)] {
            layer.path = round
            layer.fillColor = nil
            layer.strokeColor = color.cgColor
            layer.lineWidth = Self.line
            layer.lineCap = .round
            layer.isHidden = true
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
            button.layer?.addSublayer(layer)
        }
        arc.strokeStart = 0
        arc.strokeEnd = 0.26
    }

    func run(_ on: Bool) {
        guard on != running else { return }
        running = on
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.isHidden = !on
        arc.isHidden = !on
        arc.removeAnimation(forKey: "turn")
        if on, !reduced {
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            // Clockwise: z turns the other way in a layer that isn't flipped.
            turn.toValue = -2 * Double.pi
            turn.duration = 0.8
            turn.repeatCount = .infinity
            turn.timingFunction = CAMediaTimingFunction(name: .linear)
            arc.add(turn, forKey: "turn")
        }
        CATransaction.commit()
    }

    func layout() {
        guard let button else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [ring, arc] {
            layer.bounds = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
            layer.position = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        }
        CATransaction.commit()
    }
}
