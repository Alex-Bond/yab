import AppKit
import QuartzCore

/// Chrome's scroll of one mouse wheel notch, copied: cc's
/// ScrollOffsetAnimationCurve for a wheel (kEaseInOut, kInverseDelta;
/// cc/animation/scroll_offset_animation_curve.cc). It eases in and out
/// (cubic-bezier 0.42, 0, 0.58, 1) over 200 ms for anything up to 120
/// points, 100 ms from 480 up, in between on a line. A notch that comes while
/// one glides moves the target on and starts a new segment from where the
/// page is, at the speed it has (the first control point scaled to it), and
/// no longer than the time to cover the rest at that speed, times 2.5.
struct WheelCurve {
    private(set) var from: CGPoint
    private(set) var to: CGPoint
    /// When this segment began and ends, seconds (CACurrentMediaTime).
    private(set) var start: Double
    private(set) var end: Double
    private var ease: Bezier

    init(from: CGPoint, to: CGPoint, at time: Double, delayedBy delay: Double = 0) {
        self.from = from
        self.to = to
        start = time
        end = time + Self.duration(Self.longer(to - from), delayedBy: delay)
        ease = Bezier(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
    }

    /// Seconds for `delta` points: Chrome's frames at 60 a second, 12 up to
    /// 120 points, 6 from 480, one fewer for every 60 points between.
    static func duration(_ delta: Double, delayedBy delay: Double = 0) -> Double {
        // Chrome's EaseInOutSegmentDuration subtracts time already spent
        // waiting for input delivery; a late notch must not get a fresh
        // 200 ms tail on top of that wait.
        max(0, min(max(14 - abs(delta) / 60, 6), 12) / 60 - max(0, delay))
    }

    /// The axis that moves more, with its sign (cc's MaximumDimension).
    static func longer(_ v: CGPoint) -> Double {
        abs(v.x) > abs(v.y) ? Double(v.x) : Double(v.y)
    }

    func value(at time: Double) -> CGPoint {
        let span = end - start
        if span <= 0 || time >= end { return to }
        if time <= start { return from }
        let p = CGFloat(ease.value((time - start) / span))
        return CGPoint(x: from.x + (to.x - from.x) * p, y: from.y + (to.y - from.y) * p)
    }

    func done(at time: Double) -> Bool { time >= end }

    /// Points a second along the longer axis (cc's CalculateVelocity).
    func velocity(at time: Double) -> Double {
        let span = end - start
        guard span > 0 else { return 0 }
        return ease.slope((time - start) / span) * Self.longer(to - from) / span
    }

    /// Another notch while this one glides (cc's UpdateTarget).
    mutating func retarget(to target: CGPoint, at now: Double) {
        // Chrome's UpdateTarget keeps the latest segment start when input
        // predates it, but consumes that delay from the next duration.
        let delayedBy = max(0, start - now)
        let time = max(now, start)
        if abs(Self.longer(to - target)) < 0.01 {
            to = target
            return
        }
        let here = value(at: time)
        let rest = Self.longer(target - here)
        if abs(rest) < 0.01 {
            (from, to, start, end) = (target, target, time, time)
            return
        }
        guard end - start > 0 else {
            (from, to, start, end) = (here, target, time, time + Self.duration(rest, delayedBy: delayedBy))
            ease = Bezier(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
            return
        }
        let speed = velocity(at: time)
        // As long as it takes to get there at this speed, with some room
        // for the easing out; going back the other way, no bound.
        var bound = Double.infinity
        if abs(speed) >= 0.01 {
            let at = rest / speed * 2.5
            if at >= 0 { bound = at }
        }
        let span = min(Self.duration(rest, delayedBy: delayedBy), bound)
        if span < 0.01 {
            (from, to, start, end) = (target, target, time, time)
            return
        }
        let slope = min(max(speed * span / rest, -1000), 1000)
        ease = Bezier(x1: 0.42, y1: 0.42 * slope, x2: 0.58, y2: 1)
        (from, to, start, end) = (here, target, time, time + span)
    }

    /// A cubic Bézier from (0, 0) to (1, 1), as gfx::CubicBezier solves it.
    struct Bezier {
        let ax, bx, cx, ay, by, cy: Double
        let startSlope, endSlope: Double

        init(x1: Double, y1: Double, x2: Double, y2: Double) {
            cx = 3 * x1
            bx = 3 * (x2 - x1) - cx
            ax = 1 - cx - bx
            cy = 3 * y1
            by = 3 * (y2 - y1) - cy
            ay = 1 - cy - by
            startSlope = x1 > 0 ? y1 / x1 : (y1 == 0 && x2 > 0 ? y2 / x2 : 0)
            endSlope = x2 < 1 ? (y2 - 1) / (x2 - 1) : 0
        }

        private func x(_ s: Double) -> Double { ((ax * s + bx) * s + cx) * s }
        private func y(_ s: Double) -> Double { ((ay * s + by) * s + cy) * s }
        private func dx(_ s: Double) -> Double { (3 * ax * s + 2 * bx) * s + cx }
        private func dy(_ s: Double) -> Double { (3 * ay * s + 2 * by) * s + cy }

        /// The curve's parameter where its x is `x`.
        private func solve(_ x: Double) -> Double {
            var s = x
            for _ in 0..<8 {
                let error = self.x(s) - x
                if abs(error) < 1e-7 { return s }
                let d = dx(s)
                if abs(d) < 1e-6 { break }
                s -= error / d
            }
            var low = 0.0, high = 1.0
            s = x
            while low < high {
                let value = self.x(s)
                if abs(value - x) < 1e-7 { return s }
                if x > value { low = s } else { high = s }
                s = (low + high) / 2
                if high - low < 1e-9 { break }
            }
            return s
        }

        func value(_ x: Double) -> Double {
            if x <= 0 { return 0 }
            if x >= 1 { return 1 }
            return y(solve(x))
        }

        func slope(_ x: Double) -> Double {
            if x <= 0 { return startSlope }
            if x >= 1 { return endSlope }
            let s = solve(x), d = dx(s)
            return abs(d) < 1e-9 ? 0 : dy(s) / d
        }
    }
}

private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }

/// A clicking mouse wheel's notch glides over the page (rows
/// 888, 476): WebKit moves the whole notch, 40 points a line, in one frame,
/// with its scroll animator on or off (evals/m1-scroll). Here a notch is
/// not handed to WebKit; WheelCurve says where the page should be on each
/// frame, and each frame's points go to WebKit as a precise wheel event,
/// as a smooth-scrolling mouse's driver sends them, from where the notch
/// was. WebKit still does the scrolling, so a box that scrolls inside the
/// page, a frame, the end of the page, a page that takes the wheel for
/// itself (a map, an editor) are all as before; such a page hears the
/// notch as those few events, adding up to the notch.
///
/// Only notches: an event with a phase or a glide (a trackpad, a Magic
/// Mouse), or with precise deltas, goes on as it is and stops a glide.
/// So does ⌘ or ⌃ with the wheel. Off with Reduce Motion, with the
/// system's smooth scrolling turned off (NSScrollAnimationEnabled NO), and
/// with YAB_SMOOTH_SCROLL 0 or keys (Web.smoothScrolling).
@MainActor
final class WheelGlide: NSObject {
    /// Points a line of a notch, WebKit's and Chrome's
    /// (Scrollbar::pixelsPerLineStep, kScrollbarPixelsPerCocoaTick).
    static let line: Double = 40

    static let on: Bool = {
        let pick = ProcessInfo.processInfo.environment["YAB_SMOOTH_SCROLL"] ?? ""
        if pick == "0" || pick == "keys" { return false }
        if let system = UserDefaults.standard.object(forKey: "NSScrollAnimationEnabled") as? Bool, !system { return false }
        return true
    }()

    private weak var view: NSView?
    private let send: (NSEvent) -> Void
    private var curve: WheelCurve?
    /// Points sent so far in this glide, whole ones.
    private var sent = CGPoint.zero
    /// The last notch, whose window, place and flags each event keeps.
    private var notch: CGEvent?
    private var link: CADisplayLink?
    /// Notches taken and events sent, for bench wheelscript.
    private(set) var notches = 0
    private(set) var events = 0
    private(set) var offered = 0
    /// Why the last event it was offered went on as it was.
    private(set) var passed = ""

    init(view: NSView, send: @escaping (NSEvent) -> Void) {
        self.view = view
        self.send = send
    }

    /// Whether `event` is a notch to glide.
    static func glides(_ event: NSEvent) -> Bool {
        event.type == .scrollWheel && event.phase == [] && event.momentumPhase == [] && !event.hasPreciseScrollingDeltas
            && event.modifierFlags.intersection([.command, .control]).isEmpty
            && (event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0)
    }

    /// NSEvent timestamps and CACurrentMediaTime use the uptime clock.
    /// A missing or future stamp must not extend a glide or poison it.
    static func delay(since timestamp: TimeInterval, at now: TimeInterval) -> TimeInterval {
        guard timestamp.isFinite, timestamp > 0, now.isFinite else { return 0 }
        return max(0, now - timestamp)
    }

    /// Takes `event` if it is a notch to glide; anything else stops a glide
    /// and is the caller's to hand on.
    func take(_ event: NSEvent) -> Bool {
        offered += 1
        let why = !Self.on ? "off" : !Self.glides(event) ? "not a notch" : view?.window == nil ? "no window"
            : NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? "reduce motion" : event.cgEvent == nil ? "no event" : nil
        guard why == nil, let view, let cg = event.cgEvent?.copy() else {
            passed = (why ?? "no event") + String(format: " (phase %d, momentum %d, precise %d, flags %lx, dx %.2f, dy %.2f)",
                                                  Int(event.phase.rawValue), Int(event.momentumPhase.rawValue),
                                                  event.hasPreciseScrollingDeltas ? 1 : 0, event.modifierFlags.rawValue,
                                                  Double(event.scrollingDeltaX), Double(event.scrollingDeltaY))
            if event.type == .scrollWheel, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 || event.phase != [] {
                stop()
            }
            return false
        }
        notch = cg
        notches += 1
        let now = CACurrentMediaTime()
        let delay = Self.delay(since: event.timestamp, at: now)
        let delta = CGPoint(x: Double(event.scrollingDeltaX) * Self.line, y: Double(event.scrollingDeltaY) * Self.line)
        if var going = curve, !going.done(at: now) {
            going.retarget(to: going.to + delta, at: now - delay)
            curve = going
        } else {
            // What the last glide left under a point carries on.
            let left = curve.map { $0.to - sent } ?? .zero
            sent = .zero
            curve = WheelCurve(from: .zero, to: left + delta, at: now, delayedBy: delay)
        }
        if link == nil {
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        return true
    }

    func stop() {
        link?.invalidate()
        link = nil
        curve = nil
        sent = .zero
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let curve, let notch, view?.window != nil else {
            stop()
            return
        }
        let time = link.targetTimestamp
        let at = curve.value(at: time)
        let want = CGPoint(x: at.x.rounded(), y: at.y.rounded())
        let step = want - sent
        if step != .zero {
            sent = want
            if let event = Self.event(like: notch, by: step) {
                events += 1
                send(event)
            }
        }
        if curve.done(at: time) {
            link.invalidate()
            self.link = nil
        }
    }

    /// A precise wheel event of `step` points, no phase, for the window and
    /// the place in it `notch` was for, now.
    static func event(like notch: CGEvent, by step: CGPoint) -> NSEvent? {
        guard let cg = notch.copy() else { return nil }
        let dx = Int64(step.x), dy = Int64(step.y)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        cg.timestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds)
        return NSEvent(cgEvent: cg)
    }
}
