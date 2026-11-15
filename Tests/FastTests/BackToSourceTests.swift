import Testing
import WebKit
@testable import Fast

@MainActor
@Suite(.serialized)
struct BackToSourceTests {
    private func world() -> Browser { Browser(windowID: UUID()) }
    private func open(_ browser: Browser, from source: Tab? = nil, linked: Bool = false) -> Tab {
        browser.open(URL(string: "about:blank#page")!, foreground: true, from: source, linked: linked, rowNow: true)
    }
    private func clean(_ browser: Browser) {
        for tab in browser.tabs { browser.close(tab) }
        try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString).json"))
    }

    @Test func linkFirstPageClosesAndReturnsToSource() {
        let browser = world()
        defer { clean(browser) }
        let source = open(browser)
        let child = open(browser, from: source, linked: true)
        #expect(!child.hasBackHistory)
        #expect(child.canGoBack)
        browser.back(byKey: true)
        #expect(child.gone)
        #expect(!browser.tabs.contains { $0 === child })
        #expect(browser.active === source)
    }

    @Test func chromiumLinkReturnsToSourceWithoutStartingNativeHistory() throws {
        let browser = world()
        defer { clean(browser) }
        let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }
        let source = Tab(shy: true, engine: .chromium, factory: factory)
        let child = Tab(shy: true, engine: .chromium, factory: factory)
        source.restore(url: URL(string: "about:blank#source")!, title: "Source")
        child.restore(url: URL(string: "about:blank#child")!, title: "Child")
        browser.prepare(source); browser.prepare(child)
        browser.lay([source, child])
        browser.activeID = child.id
        browser.linkBack(child, to: source)
        let page = try #require(child.page as? ChromiumPage)
        #expect(page.remoteID == nil)
        browser.back()
        #expect(child.gone && browser.active === source, "Chromium Back must honor the shared source-tab destination")
        #expect(page.remoteID == nil, "Returning to a source must not start native history")
    }

    @Test(arguments: [false, true])
    func adoptedPopupNeedsAnInitialNativeLinkAction(scripted: Bool) throws {
        let browser = world()
        defer { clean(browser) }
        let source = open(browser)
        let child = Tab(shy: true, engine: .chromium)
        browser.prepare(child); browser.lay(browser.tabs + [child]); browser.activeID = child.id
        let page = ChromiumPage(tab: child)
        page.popupBackSource = source
        page.confirmPopupSource(scripted ? .other : .linkActivated)
        #expect(child.backSourceAvailable == !scripted)
        // A later click must never turn a script-created window into a link tab.
        page.confirmPopupSource(.linkActivated)
        #expect(child.backSourceAvailable == !scripted)
        if !scripted {
            child.back()
            #expect(child.gone && browser.active === source)
        }
    }

    @Test func typedAddressWithFromDoesNotClose() {
        let browser = world()
        defer { clean(browser) }
        let source = open(browser)
        let child = open(browser, from: source)
        #expect(child.from == source.id)
        #expect(!child.canGoBack)
        browser.back()
        #expect(!child.gone)
        #expect(browser.active === child)
    }

    @Test func scriptedOpenerDoesNotEnableBack() {
        let browser = world()
        defer { clean(browser) }
        let source = open(browser)
        let child = open(browser)
        child.opener = source.id
        child.from = source.id
        #expect(!child.canGoBack)
        child.back()
        #expect(!child.gone)
    }

    @Test func sourceClosingDisablesBackImmediately() {
        let browser = world()
        defer { clean(browser) }
        let source = open(browser)
        let child = open(browser, from: source, linked: true)
        #expect(child.canGoBack)
        browser.close(source)
        #expect(!child.canGoBack)
        browser.back()
        #expect(!child.gone)
        #expect(browser.active === child)
    }

    @Test func explicitlyAllowedScriptWindowStillDoesNotEnableBack() {
        let browser = world()
        defer { clean(browser) }
        let source = open(browser)
        let child = browser.open(URL(string: "about:blank#script")!, foreground: true,
                                 from: source, linked: true, backToSource: false, rowNow: true)
        #expect(!child.canGoBack)
        #expect(!browser.closeBackToSource(child))
    }

    @Test func unrelatedNewTabDoesNotEnableBack() {
        let browser = world()
        defer { clean(browser) }
        _ = open(browser)
        let child = open(browser)
        #expect(!child.canGoBack)
        #expect(!browser.closeBackToSource(child))
    }

    @Test func smallWindowSourceIsAValidDestinationUntilItCloses() {
        let browser = world()
        defer { clean(browser) }
        let source = Tab()
        browser.prepare(source)
        browser.outside.append(source)
        let child = open(browser, from: source, linked: true)
        #expect(child.canGoBack)
        #expect(browser.backSource(for: child) === source)
        source.close()
        browser.outside.removeAll { $0 === source }
        #expect(!child.canGoBack)
    }

    @Test func returnCanFollowAChainOfLinks() {
        let browser = world()
        defer { clean(browser) }
        let root = open(browser)
        let middle = open(browser, from: root, linked: true)
        let child = open(browser, from: middle, linked: true)
        child.back()
        #expect(browser.active === middle)
        #expect(child.gone)
        middle.back()
        #expect(browser.active === root)
        #expect(middle.gone)
    }

    @Test func swipeFromRowClosesALinkTab() {
        let browser = world()
        defer { clean(browser) }
        let source = open(browser)
        let child = open(browser, from: source, linked: true)
        child.onFrom?(child)
        #expect(child.gone)
        #expect(browser.active === source)
    }

    @Test func swipeFromRowOnATypedTabOnlyGoesBack() {
        let browser = world()
        defer { clean(browser) }
        let source = open(browser)
        let child = open(browser, from: source)
        child.onFrom?(child)
        #expect(!child.gone)
        #expect(browser.active === source)
    }

    @Test func swipeFromRowLeavesAKeptTabOpen() {
        let browser = world()
        defer { clean(browser) }
        let source = open(browser)
        let child = open(browser, from: source, linked: true)
        child.kept = true
        child.onFrom?(child)
        #expect(!child.gone)
        #expect(browser.active === source)
    }
}
