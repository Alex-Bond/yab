import AppKit
import Testing
@testable import Fast

/// The column says which row the pointer is on (ColumnPage.point), from
/// where the pointer is and where its rows are: a row that slides or
/// scrolls under a still pointer lights, the one it left goes dark
/// (register 1239).
@MainActor @Suite(.serialized)
struct ColumnPointedTests {
    @MainActor
    private struct World {
        let browser: Browser
        let page: ColumnPage
        let window: NSWindow
        let column: ColumnView
        var tabs: [Tab]

        func sync() {
            let items = tabs.enumerated().map { index, tab in
                ColumnItem(id: tab.id.uuidString, kind: .tab(tab), indent: 0,
                           y: CGFloat(index) * ColumnLayout.step, height: SideBar.row)
            }
            page.live(items, head: [], frame: .init(lead: 0, footRoom: 0, top: 0, foot: false),
                      look: .init(tone: nil, scheme: .light, titleSize: 13, grain: 0))
            page.layoutSubtreeIfNeeded()
        }

        /// The pointer moved to the middle of row `row` as laid now.
        func move(toRow row: Int) throws {
            let y = CGFloat(row) * ColumnLayout.step + SideBar.row / 2
            let inPage = page.convert(CGPoint(x: 120, y: y), from: page.scrollView.documentView)
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: page.convert(inPage, to: nil), modifierFlags: [],
                                                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 0, clickCount: 0, pressure: 0))
            page.point(event)
        }

        func lit(_ tab: Tab) -> Bool {
            let cell = page.scrollView.documentView?.subviews.compactMap { $0 as? ColumnCell }
                .first { !$0.isHidden && $0.itemID == tab.id.uuidString }
            return cell?.current?.pointed == true
        }
    }

    private func world(_ check: (inout World) throws -> Void) throws {
        try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let prefs = browser.prefs
        let old = (prefs.sidebar, prefs.sideShut, prefs.sideFlank)
        prefs.sidebar = true; prefs.sideShut = false
        browser.lookForMailSignInLink = {}
        let tabs = (0..<40).map { number in
            let tab = Tab()
            tab.restore(url: URL(string: "https://column-pointed.invalid/\(number)")!, title: "Row \(number)")
            browser.prepare(tab)
            return tab
        }
        browser.lay(tabs)
        browser.activeID = nil
        let page = ColumnPage(browser: browser, space: browser.spaceID)
        page.frame = CGRect(x: 0, y: 0, width: 240, height: 300)
        let window = NSWindow(contentRect: CGRect(x: -30000, y: 0, width: 240, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let column = ColumnView(browser: browser)
        column.frame = page.frame
        window.contentView = column
        column.addSubview(page)
        column.slide(out: true, animated: false)
        window.orderFrontRegardless()
        defer {
            page.hand.grip.watch(false)
            window.close()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            tabs.forEach { $0.close() }
            browser.dropSpare()
            prefs.sidebar = old.0; prefs.sideShut = old.1; prefs.sideFlank = old.2
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
        }
        var w = World(browser: browser, page: page, window: window, column: column, tabs: tabs)
        w.sync()
        try check(&w)
    }

    @Test func theRowThatSlidesUnderAStillPointerLights() throws {
        try world { w in
            try w.move(toRow: 3)
            #expect(w.page.pointedID == w.tabs[3].id.uuidString && w.lit(w.tabs[3]))
            #expect(w.browser.glance.heard == w.tabs[3].id)
            // Closed from its cross: the next comes up under the pointer.
            let closed = w.tabs.remove(at: 3)
            w.sync()
            #expect(w.page.pointedID == w.tabs[3].id.uuidString, "the row now under the pointer")
            #expect(w.lit(w.tabs[3]))
            #expect(w.browser.glance.heard == w.tabs[3].id)
            #expect(closed !== w.tabs[3])
        }
    }

    @Test func aScrollUnderAStillPointerMovesTheLight() throws {
        try world { w in
            try w.move(toRow: 2)
            #expect(w.lit(w.tabs[2]))
            let clip = w.page.scrollView.contentView
            clip.scroll(to: CGPoint(x: 0, y: clip.bounds.minY + 3 * ColumnLayout.step))
            w.page.scrollView.reflectScrolledClipView(clip)
            #expect(w.page.pointedID == w.tabs[5].id.uuidString)
            #expect(w.lit(w.tabs[5]) && !w.lit(w.tabs[2]))
        }
    }

    @Test func leavingThePageDarkensTheRow() throws {
        try world { w in
            try w.move(toRow: 1)
            #expect(w.lit(w.tabs[1]))
            let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                           windowNumber: w.window.windowNumber, context: nil, eventNumber: 0,
                                                           trackingNumber: 0, userData: nil))
            w.page.point(exit)
            #expect(w.page.pointedID == nil && !w.lit(w.tabs[1]))
            #expect(w.browser.glance.heard == nil)
        }
    }

    @Test(arguments: [Flank.left, .right])
    func aLayerHiddenColumnCannotOwnThePointer(flank: Flank) throws {
        try world { w in
            w.browser.prefs.sideFlank = flank
            try w.move(toRow: 1)
            #expect(w.browser.glance.heard == w.tabs[1].id)
            // The native frames stay put while the column's layers leave.
            w.column.slide(out: false, animated: false)
            #expect(w.page.pointedID == nil)
            #expect(w.browser.glance.heard == nil)
            try w.move(toRow: 2)
            #expect(w.page.pointedID == nil && !w.lit(w.tabs[2]))
            #expect(w.browser.glance.heard == nil)
            w.sync()
            #expect(w.page.pointedID == nil)
            w.column.slide(out: true, animated: false)
            w.sync()
            #expect(w.page.pointedID == nil, "hidden input must not replay on reveal")
            try w.move(toRow: 2)
            #expect(w.page.pointedID == w.tabs[2].id.uuidString && w.lit(w.tabs[2]))
            #expect(w.browser.glance.heard == w.tabs[2].id)
        }
    }
}
