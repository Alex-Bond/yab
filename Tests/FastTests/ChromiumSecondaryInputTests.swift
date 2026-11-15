import AppKit
import Testing
@testable import Fast

@MainActor
struct ChromiumSecondaryInputTests {
    @Test func appKitSecondaryDragInvalidatesPageCopyWithoutClaimingActivation() throws {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        // Retire before dispatch: exercise the AppKit override without opening a helper.
        page.retire(call: false, pictureInPicture: false)
        defer { tab.close() }
        let drag = try #require(NSEvent.mouseEvent(with: .rightMouseDragged,
            location: NSPoint(x: 130, y: 80), modifierFlags: [.shift], timestamp: 1,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        let before = page.pageCopyTurn
        page.rightMouseDragged(with: drag)
        #expect(page.pageCopyTurn == before + 1)
        #expect(page.lastInput == nil)
        #expect(ChromiumPage.pointerClickCount(drag) == 0)
    }
}
