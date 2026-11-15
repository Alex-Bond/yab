import AppKit

/// Scroll events over the page in front, for `bench wheelscript`, made the
/// way the window server makes a real one and posted to the app's queue,
/// so a Mac whose jobs may not post real events (no Accessibility) still
/// scrolls a page as a mouse or a trackpad would (evals/m1-scroll).
///
/// `wheel`: `notches` line notches of a clicking wheel, `gap` seconds apart.
/// `flick`: a trackpad's flick, the fingers' moves 8 ms apart, then the
/// glide's 16 ms apart, slowing, as evals/page-scroll-lag posts real ones.
/// `up` scrolls back up. Posted from a thread of their own, each due on
/// its own clock, whatever the main thread is doing, as real events are.
/// It is a bench file of its own so an older build can be measured with it
/// (scripts/runs/rev_app.sh --edit evals/m1-scroll/hook.sh).
enum PageWheelBench {
    struct Move { let dy: Double; let phase: Int64; let momentum: Int64; let line: Bool; let at: Double }

    /// The fingers' moves of a flick, in points, 8 ms apart.
    static let flick: [Double] = [4, 8, 12, 16, 20, 24, 26, 28, 28, 28, 28, 28]

    static func script(kind: String, notches: Int, gap: Double, up: Bool) -> [Move] {
        let sign: Double = up ? 1 : -1
        if kind == "wheel" {
            return (0..<max(1, notches)).map { Move(dy: sign, phase: 0, momentum: 0, line: true, at: Double($0) * gap) }
        }
        // mayBegin, began, changed..., ended; then the glide: begin,
        // continue..., end (CGScrollPhase 128, 1, 2, 4; momentum 1, 2, 3).
        var moves = [Move(dy: 0, phase: 128, momentum: 0, line: false, at: 0)]
        var at = 0.03
        for (index, dy) in flick.enumerated() {
            moves.append(Move(dy: sign * dy, phase: index == 0 ? 1 : 2, momentum: 0, line: false, at: at))
            at += 1.0 / 120
        }
        moves.append(Move(dy: 0, phase: 4, momentum: 0, line: false, at: at))
        var speed = 56.0, step = 0
        while speed >= 0.5 {
            at += 1.0 / 60
            moves.append(Move(dy: sign * speed, phase: 0, momentum: step == 0 ? 1 : 2, line: false, at: at))
            speed *= 0.95
            step += 1
        }
        moves.append(Move(dy: 0, phase: 0, momentum: 3, line: false, at: at + 1.0 / 60))
        return moves
    }

    /// Posts the script at the middle of `web`, a fraction `x`, `y` across
    /// it from its top left; answers where, and the seconds it lasts.
    @MainActor static func post(_ request: [String: Any], over web: NSView) -> [String: Any] {
        guard let window = web.window, let content = window.contentView else { return ["error": "no window"] }
        var moves = script(kind: request["kind"] as? String ?? "wheel", notches: request["notches"] as? Int ?? 1,
                           gap: request["gap"] as? Double ?? 0.045, up: request["up"] as? Bool ?? false)
        let horizontal = request["axis"] as? String == "horizontal"
        // Keep the existing vertical probes unchanged. A held horizontal
        // gesture exercises the real pill/list and final page permission.
        let hold = min(3, max(0, request["hold"] as? Double ?? 0))
        if horizontal {
            moves = moves.filter { $0.momentum == 0 }.map {
                Move(dy: $0.dy, phase: $0.phase, momentum: 0, line: $0.line, at: $0.at + ($0.phase == 4 ? hold : 0))
            }
        }
        let fx = request["x"] as? Double ?? 0.5, fy = request["y"] as? Double ?? 0.5
        let bounds = web.bounds
        let local = NSPoint(x: bounds.minX + bounds.width * fx,
                            y: web.isFlipped ? bounds.minY + bounds.height * fy : bounds.maxY - bounds.height * fy)
        let point = web.convert(local, to: nil)
        let screen = window.convertPoint(toScreen: point)
        let location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
        let inWindow = CGPoint(x: point.x, y: content.bounds.height - point.y)
        let number = Int64(window.windowNumber)
        // Controlled delivery-age probe. Events are posted normally, but
        // their uptime stamp can predate delivery, as after a busy run loop.
        let age = request["age_ms"] as? Double ?? 0
        let ageMS = age.isFinite ? min(max(age, 0), 1000) : 0
        let ageNS = UInt64(ageMS * 1_000_000)
        typealias Place = @convention(c) (CGEvent, CGPoint) -> Void
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else {
            return ["error": "no CGEventSetWindowLocation"]
        }
        let place = unsafeBitCast(symbol, to: Place.self)
        let started = Date().timeIntervalSince1970
        let posted = moves
        Thread.detachNewThread {
            let start = DispatchTime.now().uptimeNanoseconds
            for move in posted {
                let due = start + UInt64(move.at * 1e9)
                while DispatchTime.now().uptimeNanoseconds + 1_500_000 < due { usleep(1000) }
                while DispatchTime.now().uptimeNanoseconds < due {}
                let delta = Int32(move.dy.rounded())
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: move.line ? .line : .pixel, wheelCount: horizontal ? 2 : 1,
                                          wheel1: horizontal ? 0 : delta, wheel2: horizontal ? delta : 0, wheel3: 0) else { continue }
                if !move.line {
                    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    event.setIntegerValueField(horizontal ? .scrollWheelEventPointDeltaAxis2 : .scrollWheelEventPointDeltaAxis1, value: Int64(delta))
                    event.setDoubleValueField(horizontal ? .scrollWheelEventFixedPtDeltaAxis2 : .scrollWheelEventFixedPtDeltaAxis1, value: move.dy)
                    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: move.phase)
                    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: move.momentum)
                }
                // No keys held: a source-less event takes the session's,
                // and adhd's has had ⌘ down, which makes a notch a zoom's.
                event.flags = []
                event.timestamp = CGEventTimestamp(due > ageNS ? due - ageNS : 0)
                event.location = location
                // Which window it is for, and where in it: without them
                // AppKit makes an event for no window, which nothing takes.
                event.setIntegerValueField(CGEventField(rawValue: 51)!, value: number)
                place(event, inWindow)
                guard let wheel = NSEvent(cgEvent: event) else { continue }
                NSApp.postEvent(wheel, atStart: false)
            }
        }
        return ["ok": true, "at": [Double(point.x), Double(point.y)], "screen": [Double(location.x), Double(location.y)],
                "events": moves.count, "seconds": moves.last?.at ?? 0, "started": started, "age_ms": ageMS]
    }
}
