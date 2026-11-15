import AppKit
import Testing
@testable import Fast

@MainActor
struct HeaderPressPointTests {
    @Test func aGapHitCannotAuthorizeAPressOneToFourPointsAway() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        window.contentView = view
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 380),
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        #expect(TopPress.holds(down, in: view, grab: true, zoom: 1, at: CGPoint(x: 100, y: 20)) == TopPress.replaySupported)
        #expect(!TopPress.holds(down, in: view, grab: true, zoom: 1))
        for distance in 1...4 {
            #expect(!TopPress.holds(down, in: view, grab: true, zoom: 1, at: CGPoint(x: CGFloat(100 - distance), y: 20)))
            #expect(!TopPress.holds(down, in: view, grab: true, zoom: 1, at: CGPoint(x: 100, y: CGFloat(20 + distance))))
        }
        #expect(!TopPress.holds(down, in: view, grab: true, zoom: 1, at: CGPoint(x: CGFloat.nan, y: 20)))
    }

    @Test func missingAndNonfiniteRelayCoordinatesCannotHoldAPress() {
        #expect(TopDragRelay.point(grab: true, x: nil, y: 20) == nil)
        #expect(TopDragRelay.point(grab: true, x: 100, y: .infinity) == nil)
        #expect(TopDragRelay.point(grab: false, x: 100, y: 20) == nil)
        #expect(TopDragRelay.point(grab: true, x: 100, y: 20) == CGPoint(x: 100, y: 20))
    }
}
