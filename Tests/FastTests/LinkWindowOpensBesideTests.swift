import Foundation
import Testing
@testable import Fast

/// Register 986 (#608): a window a small window's page opens comes up
/// beside it as a small window, not behind it in the main window's row,
/// unsaid. evals/small-window-arc/own_page.py drives the real click.
@MainActor
struct LinkWindowOpensBesideTests {
    @Test func windowsAPageOpensStayBesideIt() {
        // window.open with no size, and a target=_blank the page could not
        // keep in place (a frame's, a file page's): beside, a small window.
        #expect(Browser.smallWindowOpensBeside(sized: false, modified: nil, menu: nil))
        #expect(Browser.smallWindowOpensBeside(sized: true, modified: nil, menu: nil))
        // A new tab you asked for, ⌘-click or the menu's, goes to the row.
        #expect(!Browser.smallWindowOpensBeside(sized: false, modified: true, menu: nil))
        #expect(!Browser.smallWindowOpensBeside(sized: false, modified: false, menu: nil))
        #expect(!Browser.smallWindowOpensBeside(sized: false, modified: nil, menu: true))
        // A sized popup was always a small window, ⌘ or not.
        #expect(Browser.smallWindowOpensBeside(sized: true, modified: true, menu: nil))
    }
}
