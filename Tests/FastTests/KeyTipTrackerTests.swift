import AppKit
import Testing
@testable import Fast

/// An AppKit view's tip (`keyTip`) hears the pointer through a tracking area
/// owned by a plain object. AppKit sends that owner `mouseEntered:` and
/// `mouseExited:`; an owner that answers to other names throws "unrecognized
/// selector". Under the run loop that is logged and the tip never shows; while
/// the spelling panel holds the events (crash 108, register 1141) it ended Yab.
struct KeyTipTrackerTests {
    @Test @MainActor func ownerAnswersAppKitsHoverMessages() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        view.keyTip("Close and pause")
        let owner = try #require(view.trackingAreas.first?.owner as? NSObject)
        #expect(owner.responds(to: #selector(NSResponder.mouseEntered(with:))))
        #expect(owner.responds(to: #selector(NSResponder.mouseExited(with:))))
    }
}
