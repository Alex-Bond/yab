import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct PageHoverTrackingTests {
    private final class FlippedContent: NSView { override var isFlipped: Bool { true } }

    private final class Receiver: NSResponder {
        var moves = 0
        var exits: [NSEvent.EventType] = []
        var exitPoint: NSPoint?
        override func mouseMoved(with event: NSEvent) { moves += 1 }
        override func mouseExited(with event: NSEvent) { exits.append(event.type); exitPoint = event.locationInWindow }
    }

    @Test func nativeTrackingLeavesOnceWhenASiblingCoversThePageAndResumes() throws {
        _ = NSApplication.shared
        let acting = PageView.agentActing
        PageView.agentActing = false
        defer { PageView.agentActing = acting }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = FlippedContent(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let page = NSView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(page)
        let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView!.addSubview(overlay)
        #expect(!PageHoverTracking.owns(page, at: NSPoint(x: 100, y: 350)))
        #expect(PageHoverTracking.owns(page, at: NSPoint(x: 100, y: 50)))
        let receiver = Receiver()
        let original = NSTrackingArea(rect: page.bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: receiver)
        let wrapped = PageHoverTracking.wrap(original, in: page)
        let proxy = try #require(wrapped.owner as? NSResponder)
        @MainActor func move(_ x: CGFloat) throws {
            proxy.mouseMoved(with: try #require(NSEvent.mouseEvent(with: .mouseMoved,
                location: NSPoint(x: x, y: 350), modifierFlags: [], timestamp: 1,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
        }
        try move(300)
        #expect(receiver.moves == 1)
        try move(100); try move(110)
        #expect(receiver.moves == 1)
        #expect(receiver.exits == [.mouseExited], "A moved event must become a real native exit, once")
        let exitPoint = try #require(receiver.exitPoint)
        #expect(!page.bounds.contains(page.convert(exitPoint, from: nil)), "WebKit maps native exit to a move; its point must be outside")
        try move(310)
        #expect(receiver.moves == 2)
        #expect(wrapped.options == original.options && wrapped.rect == original.rect)
        #expect(PageHoverTracking.take(original, from: page)?.area === wrapped)
        #expect(PageHoverTracking.take(original, from: page) == nil)
        let flags = NSTrackingArea(rect: page.bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: receiver)
        #expect(PageHoverTracking.wrap(flags, in: page) === flags, "Keep WebKit's modifier-monitor identity")
    }
}
