import AppKit
import Testing
@testable import Fast

/// The window a page is told it is in (Browser's answer to WebKit's
/// `_webView:getWindowFrameWithCompletionHandler:`), whose width is the
/// page's outerWidth: the page's own rectangle, never 0 by 0, which Google
/// Docs on Safari before 26.4 read as a quarter zoom and drew its words
/// blurry by (feedback #155).
@MainActor
struct PageWindowFrameTests {
    @Test func aPageInAWindowIsToldItsOwnRectangleOnTheScreen() {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        // Beside a column 189 points wide: the page, not the window.
        let page = NSView(frame: NSRect(x: 189, y: 0, width: 1251, height: 860))
        window.contentView?.addSubview(page)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let frame = Browser.windowFrame(of: page, shownIn: other)
        #expect(frame.size == CGSize(width: 1251, height: 860))
        #expect(frame.origin == window.convertToScreen(page.convert(page.bounds, to: nil)).origin)
        #expect(frame.minX == window.frame.minX + 189)
    }

    @Test func aPageBehindIsToldItsSizeWhereItsWindowStands() {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 1251, height: 860))
        let frame = Browser.windowFrame(of: page, shownIn: window)
        #expect(frame.size == CGSize(width: 1251, height: 860))
        #expect(frame.origin == window.frame.origin)
    }

    @Test func aPageWithNoWindowAnywhereIsToldItsOwnSize() {
        let page = NSView(frame: NSRect(x: 30, y: 40, width: 1251, height: 860))
        #expect(Browser.windowFrame(of: page, shownIn: nil) == CGRect(x: 0, y: 0, width: 1251, height: 860))
    }

    @Test func aPageNotSizedYetIsToldItsTabsWindow() {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        #expect(Browser.windowFrame(of: NSView(frame: .zero), shownIn: window) == window.frame)
    }
}
