import AppKit
import Testing
@testable import Fast

@MainActor
struct ChromiumRightDragTests {
    @Test func secondaryDragReachesPageInput() throws {
        _ = NSApplication.shared
        let tab = Tab(shy: true), page = ChromiumPage(tab: tab)
        // Exercise the real AppKit override without starting a helper endpoint.
        page.retire(call: false, pictureInPicture: false)
        defer { tab.close() }
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDragged,
            location: NSPoint(x: 90, y: 60), modifierFlags: [.shift], timestamp: 1,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        let turn = page.pageCopyTurn
        page.rightMouseDragged(with: event)
        #expect(page.pageCopyTurn == turn + 1)
        #expect(page.lastInput == nil) // Movement is not a fresh activation gesture.
        #expect(ChromiumPage.pointerClickCount(event) == 0)
    }
}
