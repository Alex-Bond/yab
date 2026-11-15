import Foundation
import CoreGraphics

// Deliberately no AppKit. The actual enum receives modeled phases/window
// identity and view geometry, and registers its own monitor callback.
struct Phase: OptionSet {
    let rawValue: UInt
    static let began = Phase(rawValue: 1 << 0)
    static let mayBegin = Phase(rawValue: 1 << 1)
    static let changed = Phase(rawValue: 1 << 2)
    static let ended = Phase(rawValue: 1 << 3)
    static let cancelled = Phase(rawValue: 1 << 4)
}

final class NSWindow {}

@MainActor class NSView {
    var window: NSWindow?
    weak var superview: NSView?
    var bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
    var visibleRect = CGRect(x: 0, y: 0, width: 400, height: 400)
    var isHidden = false
    var ancestorHidden = false
    var isHiddenOrHasHiddenAncestor: Bool { isHidden || ancestorHidden }
    var received = 0
    func scrollWheel(with event: NSEvent) { received += 1 }
    func isDescendant(of root: NSView) -> Bool {
        self === root || superview?.isDescendant(of: root) == true
    }
}

@MainActor final class NSEvent {
    enum Mask { case scrollWheel }
    let phase: Phase
    let momentumPhase: Phase
    let window: NSWindow?
    let locationInWindow: CGPoint
    static var monitor: ((NSEvent) -> NSEvent?)?
    static var monitorCount = 0
    init(phase: Phase = [], momentum: Phase = [], window: NSWindow?,
         point: CGPoint = CGPoint(x: 100, y: 100)) {
        self.phase = phase
        self.momentumPhase = momentum
        self.window = window
        self.locationInWindow = point
    }
    static func addLocalMonitorForEvents(matching mask: Mask,
                                         handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        monitorCount += 1
        monitor = handler
        return NSObject()
    }
}

// ACTUAL_SCROLL_LATCH_ENUM

private struct ContractFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor private enum Tests {
    @MainActor final class Rig {
        let window = NSWindow()
        let page = NSView()
        init() { page.window = window }
        func event(phase: Phase = .changed, momentum: Phase = [],
                   point: CGPoint = CGPoint(x: 100, y: 100)) -> NSEvent {
            NSEvent(phase: phase, momentum: momentum, window: window, point: point)
        }
    }
    static func expect(_ value: @autoclosure () -> Bool, _ why: String) throws {
        if !value() { throw ContractFailure(description: why) }
    }
    static func route(_ event: NSEvent) -> NSEvent? {
        // An optional monitor's nil result means the event was consumed.
        // Do not coalesce it with the original event.
        guard let monitor = NSEvent.monitor else { return event }
        return monitor(event)
    }
    static func released(_ rig: Rig, rejected: NSEvent) throws {
        try expect(route(rejected) === rejected, "An unavailable target must return the event to AppKit")
        try expect(rig.page.received == 0, "The unavailable target received a gesture event")
        rig.page.isHidden = false
        rig.page.ancestorHidden = false
        rig.page.visibleRect = rig.page.bounds
        let restored = rig.event()
        try expect(route(restored) === restored, "Restoring visibility must not revive the old latch")
        try expect(rig.page.received == 0, "An invalidated latch resumed delivery")
    }
    static func run() -> [[String: Any]] {
        let checks: [(String, @MainActor () throws -> Void)] = [
            ("logical column hide releases its descendant without revival", {
                let rig = Rig(), column = NSView()
                rig.page.superview = column
                ScrollLatch.hold(rig.page)
                ScrollLatch.release(in: column)
                try released(rig, rejected: rig.event())
            }),
            ("column release preserves unrelated receiver and releases self", {
                let rig = Rig(), column = NSView()
                ScrollLatch.hold(rig.page)
                ScrollLatch.release(in: column)
                try expect(route(rig.event()) == nil && rig.page.received == 1,
                           "Hiding an unrelated column must preserve the gesture")
                ScrollLatch.release(in: rig.page)
                let next = rig.event()
                try expect(route(next) === next && rig.page.received == 1,
                           "Releasing the receiver itself must return its next event")
            }),
            ("visible changed and momentum events continue", {
                let rig = Rig()
                ScrollLatch.hold(rig.page)
                try expect(route(rig.event()) == nil, "A visible changed event must remain latched")
                try expect(route(rig.event(phase: [], momentum: .changed)) == nil, "Momentum must stay with its visible target")
                try expect(rig.page.received == 2, "The active target must receive both events")
            }),
            ("hidden ancestor rejects and releases", {
                let rig = Rig()
                ScrollLatch.hold(rig.page)
                rig.page.ancestorHidden = true
                try released(rig, rejected: rig.event())
            }),
            ("hidden page rejects and releases", {
                let rig = Rig()
                ScrollLatch.hold(rig.page)
                rig.page.isHidden = true
                try released(rig, rejected: rig.event(phase: [], momentum: .changed))
            }),
            ("fully clipped page rejects and releases", {
                let rig = Rig()
                ScrollLatch.hold(rig.page)
                rig.page.visibleRect = CGRect(x: -20000, y: -20000, width: 400, height: 400)
                try released(rig, rejected: rig.event())
            }),
            ("empty visible intersection rejects and releases", {
                let rig = Rig()
                ScrollLatch.hold(rig.page)
                rig.page.visibleRect = CGRect(x: 400, y: 0, width: 20, height: 400)
                try released(rig, rejected: rig.event(phase: [], momentum: .changed))
            }),
            ("pointer outside visible target keeps gesture", {
                let rig = Rig()
                ScrollLatch.hold(rig.page)
                let outside = rig.event(point: CGPoint(x: 900, y: 900))
                try expect(route(outside) == nil, "Pointer motion must not retarget an active trackpad gesture")
                try expect(rig.page.received == 1, "The original visible target must keep the gesture")
            }),
            ("partially visible target keeps gesture", {
                let rig = Rig()
                ScrollLatch.hold(rig.page)
                rig.page.visibleRect = CGRect(x: 390, y: 0, width: 30, height: 400)
                try expect(route(rig.event()) == nil, "A nonempty visible intersection must remain valid")
                try expect(rig.page.received == 1, "A partly visible target was rejected")
            }),
            ("new began gesture releases old target", {
                let rig = Rig()
                ScrollLatch.hold(rig.page)
                try released(rig, rejected: rig.event(phase: .began))
            }),
            ("new mayBegin gesture releases old target", {
                let rig = Rig()
                ScrollLatch.hold(rig.page)
                try released(rig, rejected: rig.event(phase: .mayBegin))
            }),
            ("legacy wheel releases trackpad target", {
                let rig = Rig()
                ScrollLatch.hold(rig.page)
                try released(rig, rejected: rig.event(phase: []))
            }),
            ("window mismatch releases target", {
                let rig = Rig()
                ScrollLatch.hold(rig.page)
                try released(rig, rejected: NSEvent(phase: .changed, window: NSWindow()))
            }),
            ("detached target releases gesture", {
                let rig = Rig()
                ScrollLatch.hold(rig.page)
                rig.page.window = nil
                let detached = rig.event()
                try expect(route(detached) === detached && rig.page.received == 0, "A detached target consumed the event")
                rig.page.window = rig.window
                let restored = rig.event()
                try expect(route(restored) === restored && rig.page.received == 0, "Reattachment revived the old latch")
            }),
            ("momentum end is delivered then releases", {
                let rig = Rig()
                ScrollLatch.hold(rig.page)
                try expect(route(rig.event(phase: [], momentum: .ended)) == nil, "The final momentum event must reach its target")
                let after = rig.event(phase: [], momentum: .changed)
                try expect(route(after) === after && rig.page.received == 1, "Momentum end did not release the target")
            }),
            ("momentum cancel is delivered then releases", {
                let rig = Rig()
                ScrollLatch.hold(rig.page)
                try expect(route(rig.event(phase: [], momentum: .cancelled)) == nil, "Momentum cancellation must reach its target")
                let after = rig.event()
                try expect(route(after) === after && rig.page.received == 1, "Momentum cancellation did not release")
            }),
            ("gesture cancel is delivered then releases", {
                let rig = Rig()
                ScrollLatch.hold(rig.page)
                try expect(route(rig.event(phase: .cancelled)) == nil, "Gesture cancellation must reach its target")
                let after = rig.event()
                try expect(route(after) === after && rig.page.received == 1, "Gesture cancellation did not release")
            }),
        ]
        var results: [[String: Any]] = []
        for (name, check) in checks {
            do {
                try check()
                print("PASS \(name)")
                results.append(["name": name, "passed": true])
            } catch {
                print("FAIL \(name): \(error)")
                results.append(["name": name, "passed": false, "error": String(describing: error)])
            }
        }
        return results
    }
}

@main private struct Main {
    @MainActor static func main() throws {
        let results = Tests.run()
        let passed = results.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": results.count,
                                   "monitor_count": NSEvent.monitorCount, "results": results]
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: bytes, as: UTF8.self))
        if !passed { exit(1) }
    }
}
