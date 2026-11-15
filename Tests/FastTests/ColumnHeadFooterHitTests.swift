import AppKit
import Testing
@testable import Fast

/// The real native column's two pointer gates must leave the reserved
/// footer to its controls, even when the fixed pin grid reaches into it.
/// No window, WebKit page, pointer event, agent or provider is started.
@MainActor @Suite(.serialized)
struct ColumnHeadFooterHitTests {
    private func withPage(pins: Int, _ check: @MainActor (Browser, ColumnPage) throws -> Void) throws {
        try #require(Thread.isMainThread && Store.testing && Store.world != nil)
        try #require(Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        browser.dropSpare()
        let prefs = browser.prefs
        let old = (prefs.sidebar, prefs.sideShut, prefs.sideWidth)
        defer {
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.tabs.forEach { $0.close() }
            prefs.sidebar = old.0; prefs.sideShut = old.1; prefs.sideWidth = old.2
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
            browser.dropSpare()
        }
        prefs.sidebar = true; prefs.sideShut = false; prefs.sideWidth = 240
        let tabs = (0...pins).map { index in
            let tab = Tab(bench: true)
            tab.restore(url: URL(string: "about:blank#head-footer-\(index)")!, title: "Fixture \(index)")
            if index < pins { tab.pin = "\(index)" }
            return tab
        }
        browser.lay(tabs)
        browser.activeID = nil
        let page = ColumnPage(browser: browser, space: browser.spaceID)
        defer { page.hand.grip.watch(false) }
        lay(browser, page, height: 640, foot: SideBar.footHeight)
        try #require(page.window == nil && tabs.allSatisfy { $0.builtPage == nil })
        try check(browser, page)
        #expect(tabs.allSatisfy { $0.builtPage == nil })
    }

    private func lay(_ browser: Browser, _ page: ColumnPage, height: CGFloat, foot: CGFloat) {
        page.frame = CGRect(x: 0, y: 0, width: 240, height: height)
        page.live(ColumnLayout.live(browser), head: ColumnLayout.head(browser),
                  frame: .init(lead: ColumnLayout.lead(browser, pins: browser.pinCellCount),
                               footRoom: foot, top: 36, foot: foot > 0),
                  look: .init(tone: nil, scheme: .light, titleSize: 14, grain: 0))
        page.layoutSubtreeIfNeeded()
    }

    private func center(_ item: ColumnItem) -> CGPoint {
        CGPoint(x: SideBar.margin + (item.x ?? 0) + (item.width ?? 0) / 2,
                y: item.y + item.height / 2)
    }

    @Test(arguments: [SideBar.footHeight, SideBar.footHeight + 33])
    func tallPinGridCannotClaimTheFooter(foot: CGFloat) throws {
        try withPage(pins: 40) { browser, page in
            let pins = page.headItems.filter { if case .pin = $0.kind { true } else { false } }
            let first = try #require(pins.first), last = try #require(pins.last)
            let blocked = center(last), permitted = center(first)
            // Use the production grid's own cell, with its center inside the footer.
            let height = blocked.y + 20
            lay(browser, page, height: height, foot: foot)
            try #require(blocked.y > page.bounds.height - foot && blocked.y < page.bounds.height)
            try #require(permitted.y < page.bounds.height - foot)
            #expect(page.holds(permitted))
            #expect(page.item(at: permitted)?.id == first.id)
            #expect(!page.holds(blocked), "the native column must leave footer hits to its controls")
            #expect(page.item(at: blocked) == nil, "the drag gate must not select a pin behind the footer")
            #expect(!page.holds(CGPoint(x: 0, y: permitted.y)))
            #expect(page.item(at: CGPoint(x: 0, y: permitted.y)) == nil)
        }
    }

    @Test func removingTheFooterAndResizingRestoreTheSamePin() throws {
        try withPage(pins: 40) { browser, page in
            let last = try #require(page.headItems.last { if case .pin = $0.kind { true } else { false } })
            let point = center(last), height = point.y + 20, foot = SideBar.footHeight + 33
            lay(browser, page, height: height, foot: foot)
            #expect(!page.holds(point))
            #expect(page.item(at: point) == nil)
            lay(browser, page, height: height, foot: 0)
            #expect(page.holds(point))
            #expect(page.item(at: point)?.id == last.id)
            lay(browser, page, height: height + foot, foot: foot)
            #expect(page.holds(point))
            #expect(page.item(at: point)?.id == last.id)
            lay(browser, page, height: height, foot: foot)
            #expect(!page.holds(point))
            #expect(page.item(at: point) == nil)
        }
    }

    @Test func ordinaryRowsAndPinsAboveTheFooterStillTakeHits() throws {
        try withPage(pins: 4) { _, page in
            let pin = try #require(page.headItems.first { if case .pin = $0.kind { true } else { false } })
            #expect(page.holds(center(pin)))
            #expect(page.item(at: center(pin))?.id == pin.id)
            let row = try #require(page.items.first { if case .tab = $0.kind { true } else { false } })
            let document = try #require(page.scrollView.documentView)
            let point = document.convert(CGPoint(x: 30, y: row.y + row.height / 2), to: page)
            try #require(page.rowsClip.contains(point))
            #expect(page.holds(point))
            #expect(page.item(at: point)?.id == row.id)
            let footer = CGPoint(x: 30, y: page.bounds.height - 1)
            #expect(!page.holds(footer))
            #expect(page.item(at: footer) == nil)
        }
    }
}
