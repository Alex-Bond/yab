import AppKit
import Testing
@testable import Fast

@Suite(.serialized)
@MainActor
struct Crash0467Tests {
    @Test func trackingExitReachesPointerWithoutReadingClickCount() throws {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
            eventNumber: 1, trackingNumber: 1, userData: nil))
        #expect(ChromiumPage.pointerClickCount(exit) == 0)
        page.hoverAdmitted = true
        page.mouseExited(with: exit)
        #expect(!page.hoverAdmitted)
        for type: NSEvent.EventType in [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: .zero,
                modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
                eventNumber: 1, clickCount: 2, pressure: 0))
            #expect(ChromiumPage.pointerClickCount(event) == 0)
            page.pointer("mouseMove", event)
        }
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: .zero,
                modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
                eventNumber: 1, clickCount: 2, pressure: 0))
            #expect(ChromiumPage.pointerClickCount(event) == 2)
        }
    }

    private final class ReenteringCell: NSView {
        weak var head: HeadView?
        var calls = 0
        var reentered: NSView?
        override func hitTest(_ point: NSPoint) -> NSView? {
            calls += 1
            // Bound the old route too: the regression fails without
            // overflowing the test runner's own stack.
            if calls == 1 { reentered = head?.hitTest(point) }
            return self
        }
    }

    @Test func headerStopsResponderReentryAndResetsAfterReturning() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let head = HeadView(frame: parent.bounds)
        parent.addSubview(head)
        #expect(head.hitTest(NSPoint(x: 10, y: 10)) == nil)
        let cell = ReenteringCell(frame: head.bounds)
        cell.head = head
        head.addSubview(cell)
        #expect(head.hitTest(NSPoint(x: 10, y: 10)) === cell)
        #expect(cell.calls == 1)
        #expect(cell.reentered == nil)
        #expect(head.hitTest(NSPoint(x: 10, y: 10)) === cell)
        #expect(cell.calls == 2)
        #expect(head.hitTest(NSPoint(x: 300, y: 300)) == nil)
    }

    @Test func contentFloorMeasurementLeavesLayoutBeforeBrowserMutation() async {
        let browser = Browser()
        let before = browser.contentFloor
        let measured = CGSize(width: 901, height: 601)
        WindowFloorLayout.onMain { browser.noteContentFloor(measured) }
        #expect(browser.contentFloor == before)
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(browser.contentFloor == measured)
    }
}
