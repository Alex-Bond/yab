import AppKit
import Testing
@testable import Fast

// How deep a sideways swipe goes for how far the fingers came, and the rows
// it goes through: one at 110 points, one more every 80 for the first four,
// every 50 after, the older pages of one site gathered into a row, then the
// tab this one came from, then the history to search.
struct SwipeTests {
    @Test func waitsForEnoughTravelBeforeChoosingAxis() {
        #expect(Swipe.axis(x: 0, y: 0) == nil)
        #expect(Swipe.axis(x: 6, y: 0) == nil)
        #expect(Swipe.axis(x: 3, y: 3) == nil)
    }

    @Test func onlyClearlySidewaysTravelStartsPageOwnershipCheck() {
        #expect(Swipe.axis(x: 7, y: 0) == .across)
        #expect(Swipe.axis(x: 140, y: 0) == .across)
        #expect(Swipe.axis(x: 14, y: 10) == .across)
        #expect(Swipe.axis(x: 13, y: 10) == .down)
        #expect(Swipe.axis(x: 10, y: 14) == .down)
        #expect(Swipe.axis(x: 0, y: 140) == .down)
    }

    static func pages(_ hosts: [String]) -> [(title: String, host: String)] {
        hosts.enumerated().map { ("page \($0.offset)", $0.element) }
    }

    @Test func shortOfArmIsNothing() {
        #expect(Swipe.steps(travel: 0, rows: 5) == 0)
        #expect(Swipe.steps(travel: 109, rows: 5) == 0)
    }

    @Test func nowhereToGoNeverArms() {
        #expect(Swipe.steps(travel: 400, rows: 0) == 0)
    }

    /// The list itself comes only on a hold (SwipeHoldTests); once out,
    /// rows are counted from `open`, the pill's page first.
    @Test func theListOpensOnThePillsPage() {
        #expect(Swipe.steps(travel: 110, rows: 20) == 1)
        #expect(Swipe.steps(travel: 189, rows: 20) == 1)
        #expect(Swipe.steps(travel: Swipe.open, rows: 20) == 1)
    }

    @Test func thenEveryEightyThenEveryFifty() {
        #expect(Swipe.steps(travel: 270, rows: 20) == 2)
        #expect(Swipe.steps(travel: 350, rows: 20) == 3)
        #expect(Swipe.steps(travel: 429, rows: 20) == 3)
        #expect(Swipe.steps(travel: 430, rows: 20) == 4)
        #expect(Swipe.steps(travel: 480, rows: 20) == 5)
        #expect(Swipe.steps(travel: 5000, rows: 20) == 20)
    }

    @Test func neverPastTheLastRow() {
        #expect(Swipe.steps(travel: 900, rows: 3) == 3)
    }

    @Test func firstPagesOneByOneThenRunsOfASite() {
        let rows = Swipe.rows(Self.pages(["a.com", "a.com", "b.com", "c.com", "hn.com", "hn.com", "hn.com", "mail.com"]), from: nil)
        #expect(rows.map(\.kind) == [.page, .page, .page, .page, .run, .page, .search])
        #expect(rows[4].count == 3)
        #expect(rows[4].index == 4)
        #expect(rows[4].title == "page 4")
        #expect(rows[5].index == 7)
    }

    @Test func theTabItCameFromBeforeSearch() {
        let rows = Swipe.rows(Self.pages(["a.com", "b.com"]), from: "Inbox")
        #expect(rows.map(\.kind) == [.page, .page, .from, .search])
        #expect(rows[2].title == "Inbox")
    }

    @Test func aFirstPageWithAFromIsNotBlocked() {
        let rows = Swipe.rows([], from: "Inbox")
        #expect(rows.map(\.kind) == [.from])
        #expect(Swipe.rows([], from: nil).isEmpty)
    }

    /// Read the engine's real navigation list. The assertions below keep the
    /// same source-tab contract for native WK history and Chromium history.
    @MainActor private func history(_ tab: Tab) async throws -> PageNavigationList {
        try #require(try await Loaded.until(20) { !tab.loading && tab.builtPage?.contentProcess != nil })
        if let page = tab.builtPage as? ChromiumPage {
            return try await page.navigationHistory().list(page: page, tab: tab, back: true)
        }
        return PageNavigationList(web: try #require(tab.page.webKit), back: true)
    }

    @MainActor @Test func newTabFromAddressFieldSwipesBackToPreviousTab() async throws {
        let id = UUID()
        let browser = Browser(windowID: id)
        defer {
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        let previous = browser.open(URL(string: "about:blank")!, foreground: true)

        browser.send(URL(string: "about:blank#new")!, .ahead)

        let opened = browser.active!
        #expect(opened !== previous)
        #expect(opened.from == previous.id)
        let list = try await history(opened)
        let stops = list.stops
        #expect(stops.last?.kind == .from)
        if let origin = stops.last {
            list.take(origin)
        }
        #expect(try await Loaded.until(10) { browser.active === previous })
    }

    @MainActor private func preview() -> (Browser, NSWindow, Tab) {
        let browser = Browser(windowID: UUID())
        let source = browser.open(URL(string: "about:blank")!, foreground: true)
        source.restore(url: URL(string: "about:blank")!, title: "Previous")
        let window = NSWindow(contentRect: NSRect(x: -1000, y: -1000, width: 900, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let view = PeekView()
        view.frame = window.contentView!.bounds
        view.browser = browser
        window.contentView = view
        browser.peekView = view
        browser.peek(URL(string: "about:blank#peek")!, from: source)
        return (browser, window, source)
    }

    @MainActor @Test func swipingBackInPeekClosesIt() async throws {
        let (browser, window, source) = preview()
        defer {
            // The offscreen host was never ordered in. Closing it while
            // WebKit finishes the peek can crash the following test.
            browser.peeking?.close()
            for tab in browser.tabs { tab.close() }
            withExtendedLifetime(window) {}
            try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString).json"))
        }
        let page = browser.peeking!
        #expect(page.from == source.id)
        let list = try await history(page)
        let stops = list.stops
        #expect(stops.last?.kind == .from)

        browser.peekView = nil
        if let origin = stops.last { list.take(origin) }
        #expect(try await Loaded.until(10) { browser.peeking == nil && browser.active === source })
    }

    @MainActor @Test func keptPeekSwipesBackToPreviousTab() async throws {
        let id = UUID()
        let browser = Browser(windowID: id)
        defer {
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        let source = browser.open(URL(string: "about:blank")!, foreground: true)
        source.restore(url: URL(string: "about:blank")!, title: "Previous")
        let page = browser.blankTab()
        page.from = source.id
        browser.prepare(page)
        browser.outside.append(page)
        browser.peeking = page
        browser.peekFrom = source.id
        source.peek = page
        page.go(to: URL(string: "about:blank#peek")!)

        browser.keepPeek()
        #expect(browser.active === page)
        #expect(page.from == source.id)
        let list = try await history(page)
        let stops = list.stops
        #expect(stops.last?.kind == .from)
        if let origin = stops.last { list.take(origin) }
        #expect(try await Loaded.until(10) { browser.active === source })
    }

    @Test func runsAreCapped() {
        let hosts = (0..<60).map { "site\($0).com" }
        let rows = Swipe.rows(Self.pages(hosts), from: nil)
        #expect(rows.count == Swipe.named + Swipe.deepest + 1)
        #expect(rows.last?.kind == .search)
    }

    @Test func theStopLettingGoTakes() {
        let rows = Swipe.rows(Self.pages(["a.com", "b.com"]), from: nil)
        #expect(Pull(back: true, travel: 190, steps: 2, stops: rows).stop?.title == "page 1")
        #expect(Pull(back: true, travel: 270, steps: 3, stops: rows).stop?.kind == .search)
        #expect(Pull(back: true, travel: 50, steps: 0, stops: rows).stop == nil)
    }

    @Test func theSamePageInARowIsOne() {
        let pages: [(title: String, host: String)] = [("Sign in", "github.com"), ("Sign in", "github.com"), ("Sign in", "github.com"), ("Ask", "news.com")]
        let rows = Swipe.rows(pages, from: nil)
        #expect(rows.map(\.title) == ["Sign in", "Ask", "Search History"])
        #expect(rows[0].index == 0)
        #expect(rows[1].index == 3)
    }

    @Test func noSearchWithLessThanTwoPages() {
        #expect(Swipe.rows(Self.pages(["a.com"]), from: nil).map(\.kind) == [.page])
        let same: [(title: String, host: String)] = [("Sign in", "github.com"), ("Sign in", "github.com")]
        #expect(Swipe.rows(same, from: nil).map(\.kind) == [.page])
        #expect(Swipe.rows([], from: nil).isEmpty)
        #expect(Swipe.rows(Self.pages(["a.com", "b.com"]), from: nil).last?.kind == .search)
    }
}
