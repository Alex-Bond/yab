import AppKit
import Testing
@testable import Fast

@Suite(.serialized)
@MainActor
struct ChromiumLatchTests {
    @Test func consecutiveWheelNotchesUseTheSharedPageLatch() throws {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 400, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        defer {
            WheelLatch.release(in: page)
            ScrollLatch.release(in: page)
            page.retire(call: false, pictureInPicture: false)
            window.contentView = nil
            window.close()
            tab.close()
        }
        func notch(at time: TimeInterval) throws -> NSEvent {
            let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0))
            event.timestamp = CGEventTimestamp(time * 1e9)
            event.flags = []
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
            event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window.windowNumber))
            let screen = window.convertPoint(toScreen: NSPoint(x: 100, y: 100))
            event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
            typealias Place = @convention(c) (CGEvent, CGPoint) -> Void
            let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation"))
            unsafeBitCast(symbol, to: Place.self)(event, CGPoint(x: 100, y: 300))
            let made = try #require(NSEvent(cgEvent: event))
            try #require(made.window === window)
            try #require(made.locationInWindow == NSPoint(x: 100, y: 100))
            return made
        }
        // Clear an unrelated test's latch through its normal target boundary.
        let first = try notch(at: 17)
        #expect(WheelLatch.route(first) === first)
        page.scrollWheel(with: first)
        let next = try notch(at: 17.05)
        #expect(WheelLatch.route(next) == nil, "Chromium must register with the shared wheel latch")
        #expect(page.remoteID == nil, "Latch registration is synchronous and needs no helper")
    }
}
