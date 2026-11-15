import AppKit
import Testing
@testable import Fast

/// Legacy, phase-less wheel routing. All events stay inside the test;
/// no global posts, pointer movement, window ordering or activation.
@Suite(.serialized)
@MainActor
struct WheelLatchTests {
    private final class Receiver: NSView {
        var received = 0
        override func scrollWheel(with event: NSEvent) { received += 1 }
    }

    @MainActor private final class Rig {
        let window: NSWindow
        let ancestor: NSView
        let receiver: Receiver

        init() {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 400, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
            root.clipsToBounds = true
            window.contentView = root
            ancestor = NSView(frame: root.bounds)
            receiver = Receiver(frame: ancestor.bounds)
            root.addSubview(ancestor)
            ancestor.addSubview(receiver)
        }

        func event(at time: TimeInterval, point: NSPoint = NSPoint(x: 100, y: 100),
                   dx: Int32 = 0, phase: Int64 = 0) throws -> NSEvent {
            let made = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                wheelCount: 2, wheel1: -1, wheel2: dx, wheel3: 0))
            made.timestamp = CGEventTimestamp(time * 1e9)
            made.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
            made.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            made.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
            let screen = window.convertPoint(toScreen: point)
            made.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
            // Existing SwipePageTests uses this in-process window binding.
            // This event is never sent to WindowServer or NSApp.
            made.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window.windowNumber))
            typealias Place = @convention(c) (CGEvent, CGPoint) -> Void
            let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation"))
            unsafeBitCast(symbol, to: Place.self)(made, CGPoint(x: point.x, y: 400 - point.y))
            let event = try #require(NSEvent(cgEvent: made))
            try #require(event.window === window)
            try #require(event.locationInWindow == point)
            try #require(!event.hasPreciseScrollingDeltas)
            try #require(event.momentumPhase == [])
            if phase == 0 { try #require(event.phase == []) }
            return event
        }
    }

    private func withColumn(_ check: (Rig, ColumnView) throws -> Void) throws {
        let rig = Rig()
        let windowID = UUID(), browser = Browser(windowID: windowID)
        let prefs = browser.prefs
        let old = (prefs.sidebar, prefs.sideShut)
        prefs.sidebar = true
        prefs.sideShut = true
        browser.fullScreen = true
        browser.sidePeek = true
        let root = try #require(rig.window.contentView)
        root.wantsLayer = true
        let column = ColumnView(browser: browser)
        column.frame = root.bounds
        root.addSubview(column)
        // Keep the receiver below a real column ancestor, as RowsScroll is,
        // without requiring the rows' SwiftUI content to render on screen.
        column.addSubview(rig.ancestor)
        root.layoutSubtreeIfNeeded()
        column.slide(out: true, animated: false)
        defer {
            rig.window.close()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            prefs.sidebar = old.0
            prefs.sideShut = old.1
            try? FileManager.default.removeItem(at: Store.file("session-window-\(windowID.uuidString).json"))
        }
        try #require(column.shown)
        try check(rig, column)
    }

    @Test func visibleTargetContinuesUntilTheWheelIsQuiet() throws {
        let rig = Rig()
        defer { rig.window.close() }
        WheelLatch.hold(rig.receiver, try rig.event(at: 1))
        #expect(WheelLatch.route(try rig.event(at: 1.05)) == nil)
        #expect(WheelLatch.route(try rig.event(at: 1.15)) == nil)
        #expect(rig.receiver.received == 2)
        let late = try rig.event(at: 1.31)
        #expect(WheelLatch.route(late) === late)
        #expect(rig.receiver.received == 2)
    }

    @Test func hiddenPeekAncestorReleasesTheLatch() throws {
        let rig = Rig()
        defer { rig.window.close() }
        WheelLatch.hold(rig.receiver, try rig.event(at: 1))
        rig.ancestor.isHidden = true
        try #require(rig.receiver.window === rig.window)
        let hidden = try rig.event(at: 1.02)
        #expect(WheelLatch.route(hidden) === hidden)
        #expect(rig.receiver.received == 0)
        // Becoming visible again cannot revive the rejected old latch.
        rig.ancestor.isHidden = false
        let visibleAgain = try rig.event(at: 1.04)
        #expect(WheelLatch.route(visibleAgain) === visibleAgain)
        #expect(rig.receiver.received == 0)
    }

    @Test func parkedColumnAncestorReleasesTheLatch() throws {
        let rig = Rig()
        defer { rig.window.close() }
        WheelLatch.hold(rig.receiver, try rig.event(at: 1))
        // ColumnPages.park retains the subtree/window and moves its
        // ancestor, without setting isHidden, to x=-20000.
        rig.ancestor.setFrameOrigin(NSPoint(x: -20000, y: 0))
        try #require(!rig.receiver.isHiddenOrHasHiddenAncestor)
        try #require(rig.receiver.window === rig.window)
        let parked = try rig.event(at: 1.02)
        #expect(WheelLatch.route(parked) === parked)
        #expect(rig.receiver.received == 0)
        rig.ancestor.setFrameOrigin(.zero)
        let restored = try rig.event(at: 1.04)
        #expect(WheelLatch.route(restored) === restored)
        #expect(rig.receiver.received == 0)
    }

    @Test func puttingAwayColumnReleasesItsReceiverWithoutHidingTheView() throws {
        try withColumn { rig, column in
            WheelLatch.hold(rig.receiver, try rig.event(at: 1))
            try #require(WheelLatch.route(try rig.event(at: 1.01)) == nil)
            try #require(rig.receiver.received == 1)

            // The production hide moves the drawing with a sublayer
            // transform. Its view geometry deliberately stays in place.
            column.slide(out: false, animated: false)
            try #require(!column.shown)
            try #require(column.hitTest(NSPoint(x: 100, y: 100)) == nil)
            try #require(rig.receiver.window === rig.window)
            try #require(!rig.receiver.isHiddenOrHasHiddenAncestor)
            let hidden = try rig.event(at: 1.02)
            let point = rig.receiver.convert(hidden.locationInWindow, from: nil)
            try #require(rig.receiver.visibleRect.intersection(rig.receiver.bounds).contains(point))
            #expect(WheelLatch.route(hidden) === hidden)
            #expect(rig.receiver.received == 1)

            // Revealing the same retained column cannot revive its latch.
            column.slide(out: true, animated: false)
            try #require(column.shown)
            let revealed = try rig.event(at: 1.04)
            #expect(WheelLatch.route(revealed) === revealed)
            #expect(rig.receiver.received == 1)
        }
    }

    @Test func puttingAwayColumnPreservesAnUnrelatedReceiver() throws {
        try withColumn { rig, column in
            let root = try #require(rig.window.contentView)
            let other = Receiver(frame: root.bounds)
            root.addSubview(other)
            WheelLatch.hold(other, try rig.event(at: 1))
            column.slide(out: false, animated: false)
            try #require(!column.shown)
            let next = try rig.event(at: 1.02)
            #expect(WheelLatch.route(next) == nil)
            #expect(other.received == 1)
            #expect(rig.receiver.received == 0)
        }
    }

    @Test func changedTargetPointOrWindowAndTrackpadAreLeftToAppKit() throws {
        let rig = Rig()
        let other = Rig()
        defer { rig.window.close(); other.window.close() }
        for next in [try rig.event(at: 1.02, point: NSPoint(x: 102, y: 100)),
                     try rig.event(at: 1.02, phase: 1), try other.event(at: 1.02)] {
            WheelLatch.hold(rig.receiver, try rig.event(at: 1))
            #expect(WheelLatch.route(next) === next)
        }
        #expect(rig.receiver.received == 0)
    }

    @Test func sidewaysColumnWheelStillFallsThrough() throws {
        let rig = Rig()
        defer { rig.window.close() }
        WheelLatch.hold(rig.receiver, try rig.event(at: 1), upDownOnly: true)
        let sideways = try rig.event(at: 1.02, dx: 3)
        #expect(WheelLatch.route(sideways) === sideways)
        #expect(rig.receiver.received == 0)
    }
}
