import AppKit
import SwiftUI

/// Two fingers over the native mail pane use mail's history. The column
/// keeps its space gesture, out over the pane as a card too (SpaceSwipe.
/// claims), and a vertical scroll keeps its original view. With nothing
/// to go back to, the swipe stays mail's, as a page's does in Yab and in
/// Arc: only the column changes spaces.
struct MailSwipe: NSViewRepresentable {
    var navigate: (Int) -> Void

    func makeNSView(context: Context) -> Catch {
        let view = Catch()
        view.navigate = navigate
        return view
    }

    func updateNSView(_ view: Catch, context: Context) { view.navigate = navigate }

    static func dismantleNSView(_ view: Catch, coordinator: ()) { view.stop() }

    final class Catch: NSView {
        var navigate: (Int) -> Void = { _ in }
        private var monitor: Any?
        private var gesture = Gesture()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.heard(event)
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            gesture = Gesture()
        }

        func heard(_ event: NSEvent) -> NSEvent? {
            guard window != nil, event.window === window else { return event }
            // Only a gesture's start asks where it is (Gesture.hear).
            let starts = event.phase == .began || event.phase == .mayBegin
            let inside = starts && !isHiddenOrHasHiddenAncestor && bounds.contains(convert(event.locationInWindow, from: nil))
                && !SpaceSwipe.claims(event)
            let result = gesture.hear(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                                      phase: event.phase, momentum: event.momentumPhase,
                                      precise: event.hasPreciseScrollingDeltas, inside: inside, time: event.timestamp)
            if let step = result.step { navigate(step) }
            return result.taken ? nil : event
        }
    }

    struct Gesture {
        private var owned = false
        private var across: Bool?
        private var x: CGFloat = 0
        private var y: CGFloat = 0
        private var travel: CGFloat = 0
        private var direction: CGFloat = 1
        private var recent: [(TimeInterval, CGFloat)] = []

        mutating func hear(x dx: CGFloat, y dy: CGFloat, phase: NSEvent.Phase,
                           momentum: NSEvent.Phase = [], precise: Bool = true,
                           inside: Bool = true, time: TimeInterval) -> (taken: Bool, step: Int?) {
            guard precise else { return (false, nil) }
            if phase == .mayBegin || phase == .began {
                self = Gesture()
                owned = inside
            }
            guard owned else { return (false, nil) }
            // A glide cannot navigate twice or scroll the newly opened screen.
            if momentum != [] { return (across == true, nil) }
            if phase == .cancelled {
                let taken = across == true
                self = Gesture()
                return (taken, nil)
            }
            if phase == .began || phase == .changed {
                if across == nil {
                    x += abs(dx)
                    y += abs(dy)
                    travel += dx
                    if x + y > 6 {
                        across = x > y * 1.3
                        direction = travel >= 0 ? 1 : -1
                        travel = abs(travel)
                    }
                } else if across == true {
                    let move = dx * direction
                    travel = max(0, travel + move * (move < 0 ? 3 : 1))
                }
                if across == true {
                    recent.append((time, travel))
                    if recent.count > 6 { recent.removeFirst() }
                }
            }
            let taken = across == true
            guard phase == .ended else { return (taken, nil) }
            let speed: CGFloat
            if let first = recent.first, let last = recent.last,
               time - last.0 < Swipe.quickRest, last.0 - first.0 > 0.005 {
                speed = (last.1 - first.1) / CGFloat(last.0 - first.0)
            } else { speed = 0 }
            let armed = travel >= Swipe.arm || travel >= 60 && speed > 1000
            let step = taken && armed ? (direction > 0 ? -1 : 1) : nil
            recent = []
            travel = 0
            return (taken, step)
        }
    }
}
