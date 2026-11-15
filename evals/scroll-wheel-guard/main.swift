import AppKit
import SwiftUI

@MainActor
final class ReturnView: NSView {
    weak var target: NSView?
    var calls = 0
    var nextEvent: NSEvent?
    private var depth = 0
    var maximum = 0
    override func scrollWheel(with event: NSEvent) {
        calls += 1; depth += 1; maximum = max(maximum, depth)
        defer { depth -= 1 }
        // A safety fuse reports the baseline recursion without crashing a worker.
        let forwarded = nextEvent ?? event
        nextEvent = nil
        if depth < 32 { target?.scrollWheel(with: forwarded) }
    }
}
@MainActor
final class ConsumingView: NSView {
    var calls = 0
    override func scrollWheel(with event: NSEvent) { calls += 1 }
}
@MainActor
final class ForwardingView: NSView {
    var calls = 0
    override func scrollWheel(with event: NSEvent) {
        calls += 1
        super.scrollWheel(with: event)
    }
}
@MainActor
final class StaleHit: NSView {
    weak var hit: NSView?
    var tests = 0
    override func hitTest(_ point: NSPoint) -> NSView? {
        tests += 1
        return tests <= 32 ? hit : nil
    }
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    #if SCROLL_GUARD_CANDIDATE
    ScrollWheelGuard.install()
    ScrollWheelGuard.install()
    #endif
    let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 320, height: 240),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = ReturnView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
    window.contentView = root
    defer { root.target = nil; window.close() }
    let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                     wheel1: -10, wheel2: 0, wheel3: 0)!
    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
    let event = NSEvent(cgEvent: cg)!
    let view = NSView(frame: root.bounds)
    root.addSubview(view); view.nextResponder = root; root.target = view
    view.scrollWheel(with: event)
    let cycle = root.calls
    let maximum = root.maximum
    root.calls = 0
    view.scrollWheel(with: event)
    let repeated = root.calls
    root.calls = 0
    root.nextEvent = NSEvent(cgEvent: cg.copy()!)!
    view.scrollWheel(with: event)
    let separate = root.calls
    root.target = nil; root.calls = 0
    view.removeFromSuperview()
    let outer = NSView(frame: root.bounds), inner = NSView(frame: root.bounds)
    root.addSubview(outer); outer.addSubview(inner)
    inner.scrollWheel(with: event)
    let ordinary = root.calls
    outer.removeFromSuperview(); root.calls = 0
    let overriding = ForwardingView(frame: root.bounds)
    root.addSubview(overriding)
    overriding.scrollWheel(with: event)
    let superCalls = root.calls
    overriding.removeFromSuperview()
    let consuming = ConsumingView(frame: root.bounds)
    root.addSubview(consuming)
    consuming.scrollWheel(with: event)
    consuming.scrollWheel(with: NSEvent(cgEvent: cg.copy()!)!)
    let consumed = consuming.calls
    consuming.removeFromSuperview(); root.calls = 0
    let container = NSView(frame: root.bounds); root.addSubview(container)
    let stale = StaleHit(frame: container.bounds); container.addSubview(stale)
    let top = NSView(frame: container.bounds); container.addSubview(top)
    let host = NSHostingView(rootView: AnyView(Color.clear)); host.frame = top.bounds; top.addSubview(host)
    let leaf = NSView(frame: host.bounds); host.addSubview(leaf); stale.hit = leaf
    leaf.scrollWheel(with: event)
    let sibling = stale.tests
    let value: [String: Any] = ["cycleCalls": cycle, "maximumDepth": maximum,
        "repeatedEventCalls": repeated, "ordinaryCalls": ordinary, "siblingHitTests": sibling,
        "separateEventCalls": separate, "overrideSuperCalls": superCalls, "consumedCalls": consumed,
        "os": ProcessInfo.processInfo.operatingSystemVersionString]
    print(String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!)
    #if SCROLL_GUARD_CANDIDATE
    guard cycle == 1, maximum == 1, repeated == 1, ordinary == 1, sibling <= 1, separate == 2, superCalls == 1, consumed == 2 else { exit(1) }
    #else
    guard cycle == 32, maximum == 32, repeated == 32, ordinary == 1, separate == 32, superCalls == 1, consumed == 2 else { exit(2) }
    #endif
}
