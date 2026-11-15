import QuartzCore
import os
import UIKit

/// One number moved by the prototype's spring, frame by frame: the column's
/// top, the strip of spaces, the pages beside the tab. A finger hands its
/// speed in when it lets go, so a throw keeps going the way it was thrown,
/// which a SwiftUI animation of the same spring can't be told.
///
/// The spring is the prototype's own (`spring()` in prototype.html): stiffness
/// (2π / response)², damping 4π × damping / response, mass 1, integrated at
/// 240 Hz, at rest within 0.04 pt and 2 pt/s. Its numbers come from a named
/// Motion, and each run sits inside that Motion's signpost.
@MainActor
final class SpringValue: NSObject {
    private(set) var value: CGFloat
    private(set) var velocity: CGFloat = 0
    private(set) var target: CGFloat
    /// Told every new value, the first one too.
    var onUpdate: (CGFloat) -> Void
    /// Under Reduce Motion a run doesn't move: the value goes to its target
    /// at once while this view (the window) cross-fades from how it looked,
    /// Motion.fade's 0.2 s, the plan's rule for every morph.
    var fadeView: (() -> UIView?)?
    /// The most one frame may step: after a stall of the main thread the
    /// movement goes on from where it was instead of leaping to catch up.
    /// 0.05 s as before; a piece that must never jump says one frame.
    var maxStep: CFTimeInterval = 0.05

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var stiffness: CGFloat = 0
    private var friction: CGFloat = 0
    private var name: StaticString = "spring"
    private var signpost: OSSignpostIntervalState?
    private var completion: ((Bool) -> Void)?

    init(_ value: CGFloat, onUpdate: @escaping (CGFloat) -> Void = { _ in }) {
        self.value = value
        target = value
        self.onUpdate = onUpdate
        super.init()
    }

    var isMoving: Bool { link != nil }

    /// Straight there: a finger moving it, or a frozen state.
    func set(_ value: CGFloat) {
        stop()
        self.value = value
        target = value
        velocity = 0
        onUpdate(value)
    }

    /// Springs to `target` the way `motion` does. Velocity in points per
    /// second; nil keeps the speed it has.
    func animate(to target: CGFloat, _ motion: Motion, velocity: CGFloat? = nil, completion: ((Bool) -> Void)? = nil) {
        let v = velocity ?? self.velocity
        stop()
        self.target = target
        let still = abs(target - value) < 0.04 && abs(v) < 2
        if Motion.disabled || Motion.reduced || still {
            value = target
            self.velocity = 0
            if Motion.reduced, !Motion.disabled, !still, let view = fadeView?() {
                endFade()
                fading = (motion.name, MotionSignposts.begin("fade", motion: motion.name, expected: Motion.fadeDuration))
                UIView.transition(with: view, duration: Motion.fadeDuration, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                    self.onUpdate(target)
                } completion: { [weak self] _ in
                    MainActor.assumeIsolated { self?.endFade() }
                }
            } else {
                onUpdate(target)
            }
            completion?(true)
            return
        }
        let response = CGFloat(motion.response ?? 0.35)
        let damping = CGFloat(motion.damping ?? 1)
        stiffness = pow(2 * .pi / response, 2)
        friction = 4 * .pi * damping / response
        self.velocity = v
        self.completion = completion
        name = motion.name
        signpost = MotionSignposts.begin(motion.name)
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        last = CACurrentMediaTime()
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Reduce Motion's cross-fade running, under its "fade" signpost.
    private var fading: (name: StaticString, signpost: OSSignpostIntervalState?)?

    private func endFade() {
        guard let fade = fading else { return }
        fading = nil
        MotionSignposts.end("fade", fade.signpost, motion: fade.name)
    }

    /// Stops where it is; an unfinished run says so to its completion.
    func stop() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        MotionSignposts.end(name, signpost)
        signpost = nil
        let done = completion
        completion = nil
        done?(false)
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = min(maxStep, max(0, now - last))
        last = now
        let n = max(1, Int((dt * 240).rounded(.up)))
        let h = CGFloat(dt) / CGFloat(n)
        for _ in 0..<n {
            let a = -stiffness * (value - target) - friction * velocity
            velocity += a * h
            value += velocity * h
        }
        if abs(value - target) < 0.04 && abs(velocity) < 2 {
            value = target
            velocity = 0
            onUpdate(value)
            link.invalidate()
            self.link = nil
            MotionSignposts.end(name, signpost)
            signpost = nil
            let done = completion
            completion = nil
            done?(true)
            return
        }
        onUpdate(value)
    }
}

/// The prototype's little functions, kept in one place so other branches'
/// names never meet these.
enum ColumnMath {
    /// The rubber band: past an end, a thing moves less and less.
    static func rubber(_ x: CGFloat, _ d: CGFloat) -> CGFloat {
        let sign: CGFloat = x < 0 ? -1 : 1
        return sign * (1 - 1 / (abs(x) * 0.55 / d + 1)) * d
    }

    static func clamp<T: Comparable>(_ v: T, _ a: T, _ b: T) -> T { max(a, min(b, v)) }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}
