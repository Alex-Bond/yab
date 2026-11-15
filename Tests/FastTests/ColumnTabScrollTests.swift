import AppKit
import Testing
import WebKit
@testable import Fast

/// A page arriving/leaving repaints the persistent native column without
/// throwing away the reader's viewport. Explicit row navigation still follows.
@MainActor @Suite(.serialized)
struct ColumnTabScrollTests {
    private func withColumn(_ check: (Browser, ColumnPages, ColumnPage, [Tab]) throws -> Void) throws {
        try #require(Thread.isMainThread && Store.testing && Store.world != nil)
        try #require(Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        browser.lookForMailSignInLink = {}
        browser.dropSpare()
        let prefs = browser.prefs
        let old = (prefs.sidebar, prefs.sideShut, prefs.sideWidth, prefs.usesSpaces)
        prefs.sidebar = true; prefs.sideShut = false; prefs.sideWidth = 240; prefs.usesSpaces = false
        let tabs = (0..<65).map { number in
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let tab = Tab(configuration: configuration)
            tab.restore(url: URL(string: "https://tab-scroll.invalid/\(number)")!, title: "Fixture \(number)")
            if number < 4 { tab.pin = "\(number)" }
            else if number < 64 { tab.kept = true }
            browser.prepare(tab)
            return tab
        }
        browser.lay(tabs)
        browser.takeOwnFolders()
        browser.activeID = tabs.last?.id
        defer {
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            tabs.forEach { $0.close() }
            prefs.sidebar = old.0; prefs.sideShut = old.1; prefs.sideWidth = old.2; prefs.usesSpaces = old.3
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
            browser.dropSpare()
        }
        let pages = ColumnPages(browser: browser)
        pages.frame = CGRect(x: 0, y: 0, width: 240, height: 600)
        pages.given(.init(lead: 44, footRoom: SideBar.footHeight, top: 36, foot: true),
                    look: .init(tone: nil, scheme: .light, titleSize: 13, grain: 0))
        pages.sync()
        defer { pages.stop(); pages.pages.values.forEach { $0.hand.grip.watch(false) } }
        let page = try #require(pages.shown)
        try #require(page.window == nil && tabs.allSatisfy { $0.builtPage == nil })
        try #require(tabs.filter { $0.kept }.count == 60 && tabs.filter { $0.pin != nil }.count == 4)
        try check(browser, pages, page, tabs)
        #expect(tabs.allSatisfy { $0.builtPage == nil })
    }

    @Test func closingTheLastOrdinaryTabKeepsTheScrolledKeptList() throws {
        try withColumn { browser, pages, page, tabs in
            let ordinary = try #require(tabs.last)
            page.scroll(to: 400)
            let before = page.offset
            try #require(before > 350)
            browser.close(ordinary)
            pages.sync()
            #expect(browser.activeID == nil)
            #expect(!browser.tabs.contains { $0.id == ordinary.id })
            #expect(pages.shown === page)
            #expect(abs(page.offset - before) < 0.5)
            pages.sync()
            #expect(abs(page.offset - before) < 0.5)
        }
    }

    @Test func aVisiblePageArrivingFromTheEmptyFieldKeepsItsViewport() throws {
        try withColumn { browser, pages, page, _ in
            browser.activeID = nil
            pages.sync()
            page.scroll(to: 400)
            let before = page.offset
            let item = try #require(page.items.first { row in
                if case .tab = row.kind { return row.y >= before + 20 && row.y + row.height < before + page.rowsClip.height - 20 }
                return false
            })
            let id = try #require(UUID(uuidString: item.id))
            browser.activeID = id
            pages.sync()
            #expect(abs(page.offset - before) < 0.5)
            #expect(pages.shown === page)
        }
    }

    @Test func explicitlySelectingAnOffscreenRowStillFollowsIt() throws {
        try withColumn { browser, pages, page, tabs in
            page.scroll(to: 400)
            let target = try #require(tabs.dropFirst(4).last)
            browser.activeID = tabs[4].id
            pages.sync()
            page.scroll(to: 400)
            browser.activeID = target.id
            pages.sync()
            let item = try #require(page.items.first { $0.id == target.id.uuidString })
            #expect(page.offset > 400)
            #expect(item.y >= page.offset - 0.5)
            #expect(item.y + item.height <= page.offset + page.rowsClip.height + 0.5)
        }
    }

    @Test(arguments: [6.0, 400.0])
    func aPicturedSpaceKeepsTheNativeRowsScroll(_ offset: Double) throws {
        try withColumn { browser, pages, page, _ in
            let window = NSWindow(contentRect: pages.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { pages.removeFromSuperview(); window.close() }
            try #require(window.contentView).addSubview(pages)
            page.scroll(to: CGFloat(offset))
            let saved = PagedSpace.savedOffset(in: browser, space: browser.spaceID)
            #expect(abs(saved - offset) < 0.5)
            #expect(PagedSpace.savedOffset(in: browser, space: UUID()) == 0)
            #expect(PagedSpace.savedOffset(in: browser, space: Space.mailID) == 0)
            let row = Parked(tabs: browser.tabs, active: browser.activeID)
            let coming = PagedSpace(browser: browser, prefs: browser.prefs, mail: false, row: row,
                                    travelling: [], space: browser.space, scrollOffset: saved)
            var atTop = coming
            atTop.scrollOffset = 0
            // Equatable SwiftUI pages must redraw when only the viewport
            // changed, even with identical folders, pins and active tab.
            #expect(coming != atTop)
            #expect(abs(page.rowsTop + saved - page.rowsClip.minY) < 0.5)
        }
    }

    @Test(arguments: [true, false])
    func anExplicitFullResetStillWinsOverAPaintRefresh(resetFirst: Bool) throws {
        try withColumn { browser, pages, page, _ in
            page.scroll(to: 400)
            if resetFirst { page.showAfresh() }
            browser.activeID = nil
            if !resetFirst { page.showAfresh() }
            pages.sync()
            #expect(abs(page.offset) < 0.5)
        }
    }
}
