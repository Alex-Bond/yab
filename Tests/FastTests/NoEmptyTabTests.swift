import Foundation
import Testing
@testable import Fast

/// A tab comes only with a page: ⌘T and Split View ask with the field over
/// the page, ⌘N opens a window whose field asks on its own ground, and with
/// nothing in front the field stands on its own.
struct NoEmptyTabTests {
    @MainActor private func window() -> (Browser, UUID) {
        let id = UUID()
        return (Browser(windowID: id), id)
    }

    @MainActor private func forget(_ id: UUID) {
        try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
    }

    @MainActor @Test func aNewWindowHasNoTab() {
        let (browser, id) = window()
        defer { forget(id) }
        #expect(browser.tabs.isEmpty)
        #expect(browser.active == nil)
        #expect(browser.fieldShowing && browser.fresh && browser.asking == .tab)
    }

    @MainActor @Test func escapeInAnEmptyWindowHidesTheField() {
        let (browser, id) = window()
        defer { forget(id) }
        browser.edit()
        browser.typed = "unfinished search"
        browser.dismiss()
        #expect(browser.typed.isEmpty && !browser.fieldShowing)
        #expect(browser.fieldPutAway && browser.fieldCanPutAway)
        #expect(browser.active == nil && browser.tabs.isEmpty && browser.under == nil)
        browser.dismiss()
        #expect(!browser.fieldShowing)
    }

    @MainActor @Test func newTabOverAPageMakesNoTab() {
        let (browser, id) = window()
        defer { forget(id) }
        let page = browser.open(URL(string: "about:blank#page")!, foreground: true)
        browser.newTab()
        #expect(browser.tabs.count == 1)
        #expect(browser.asked == .tab && browser.fieldShowing)
        browser.dismiss()
        #expect(browser.active === page && !browser.fieldShowing && browser.asked == nil)
    }

    @MainActor @Test func escapePutsAwayAPrivateWindowsEmptyField() {
        let id = UUID()
        let browser = Browser(windowID: id, purpose: .privateOnly)
        defer { browser.letGo(); forget(id) }
        browser.edit()
        browser.typed = "unfinished private search"
        browser.dismiss()
        #expect(browser.privateBrowsing && !browser.fieldShowing)
        #expect(browser.typed.isEmpty && browser.fieldPutAway && browser.fieldCanPutAway)
    }

    /// New Tab in Folder (⌥⌘T): ⌘T's field, no tab until a place is
    /// chosen, and the tab it makes lands at the end of that folder.
    @MainActor @Test func newTabInFolderLandsInTheFolder() {
        let (browser, id) = window()
        defer { forget(id) }
        let first = browser.open(URL(string: "about:blank#first")!, foreground: true)
        let page = browser.open(URL(string: "about:blank#page")!, foreground: true)
        browser.newFolder(with: [first, page])
        guard let nest = page.nest else { Issue.record("no folder"); return }
        browser.select(page)
        #expect(browser.folderHere === nest)
        browser.newTab(in: browser.folderHere)
        #expect(browser.tabs.count == 2)
        #expect(browser.asked == .tab && browser.landing === nest)
        #expect(browser.openWords(browser.asking) == "Open in \(nest.name)")
        browser.send(URL(string: "about:blank#new")!, .here)
        let made = browser.tabs.first { $0 !== first && $0 !== page }
        #expect(made?.nest === nest && made?.kept == true)
        #expect(browser.tabs(in: nest).last === made)
        #expect(browser.landing == nil)
        // Escape lets the folder go: the next ⌘T's tab is today's.
        browser.select(page)
        browser.newTab(in: nest)
        browser.dismiss()
        browser.newTab()
        #expect(browser.landing == nil)
        browser.send(URL(string: "about:blank#today")!, .here)
        #expect(browser.tabs.last { $0.nest == nil && !$0.kept } != nil)
        #expect(browser.tabs(in: nest).count == 3)
    }

    /// ⌘T's field lights New Tab's row in place of the tab under it; ⌘L's
    /// and Split View's leave the tab lit.
    @MainActor @Test func newTabIsLitWhileTheFieldAsksForIt() {
        let (browser, id) = window()
        defer { forget(id) }
        #expect(browser.newTabLit)
        _ = browser.open(URL(string: "about:blank#page")!, foreground: true)
        #expect(!browser.newTabLit)
        browser.newTab()
        #expect(browser.newTabLit)
        browser.dismiss()
        #expect(!browser.newTabLit)
        browser.edit()
        #expect(!browser.newTabLit)
        browser.dismiss()
        browser.openFresh(.split)
        #expect(!browser.newTabLit)
        browser.dismiss()
    }

    /// ⌘N, as Arc's (feedback #285): a window at once, nothing asked over
    /// the page it was pressed on, and the new window's field asking on its
    /// own ground for the window's first tab.
    @MainActor @Test func newWindowOpensAWindowAtOnce() {
        let (browser, id) = window()
        let (made, madeID) = window()
        defer { forget(id); forget(madeID) }
        let page = browser.open(URL(string: "about:blank#page")!, foreground: true)
        var asked: [Browser] = []
        browser.newWindow { asked.append($0) }
        #expect(asked.count == 1 && asked.first === browser)
        #expect(browser.asked == nil && !browser.fieldShowing)
        #expect(browser.active === page && browser.tabs.count == 1)
        // The window it makes: no tab, the field up and asking for one.
        #expect(made.tabs.isEmpty && made.active == nil)
        #expect(made.fieldShowing && made.fresh && made.asking == .tab)
        #expect(Browser.openWords(made.asking) == "Open in New Tab")
    }

    /// ⌘N while ⌘T's field is up: that field goes, and the window opens.
    @MainActor @Test func newWindowLetsTheNewTabFieldGo() {
        let (browser, id) = window()
        defer { forget(id) }
        let page = browser.open(URL(string: "about:blank#page")!, foreground: true)
        browser.newTab()
        #expect(browser.asked == .tab && browser.fieldShowing)
        var opened = 0
        browser.newWindow { _ in opened += 1 }
        #expect(opened == 1)
        #expect(browser.asked == nil && !browser.fieldShowing && browser.active === page)
    }

    @MainActor @Test func splitViewAsksItsOwn() {
        let (browser, id) = window()
        defer { forget(id) }
        browser.splitBook.place = CGRect(x: 0, y: 0, width: 1400, height: 900)
        _ = browser.open(URL(string: "about:blank#page")!, foreground: true)
        browser.splitView()
        #expect(browser.asked == .split && browser.tabs.count == 1)
        #expect(Browser.openWords(browser.asking) == "Open in Split View")
    }

    /// Split View's field, given a tab already open, puts it beside the
    /// page rather than switching to it (feedback 31).
    @MainActor @Test func splitViewTakesAnOpenTabBesideThePage() {
        let (browser, id) = window()
        defer { forget(id) }
        browser.splitBook.place = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let other = browser.open(URL(string: "https://example.test/other")!, foreground: true)
        let page = browser.open(URL(string: "https://example.test/page")!, foreground: true)
        browser.splitView()
        #expect(browser.asked == .split)
        #expect(browser.splitTakes(other) && !browser.splitTakes(page))
        browser.take(Suggestion(key: other.label, title: "", url: other.address, kind: .open, tab: other.id))
        #expect(browser.pairs.count == 1)
        #expect(browser.pair(of: page.id)?.contains(other.id) == true)
        #expect(browser.tabs.count == 2 && !browser.fieldShowing)
        // In a pair already, the page has nothing more to take.
        #expect(!browser.splitTakes(other))
    }

    /// ⌘W on the last tab closes it for good: the field on the window's
    /// own ground, and Escape brings nothing back. ⌘⇧T still does.
    @MainActor @Test func theLastTabClosesToTheGround() {
        let (browser, id) = window()
        defer { forget(id) }
        let url = URL(string: "https://example.test/last")!
        let page = browser.open(url, foreground: true)
        browser.shut([page])
        #expect(browser.tabs.isEmpty && browser.active == nil)
        #expect(browser.under == nil && browser.fieldShowing)
        #expect(browser.ghosts.map(\.url).contains(url))

        browser.dismiss()
        #expect(browser.tabs.isEmpty && browser.active == nil)
        #expect(browser.under == nil && !browser.fieldShowing)

        browser.reopen()
        #expect(browser.tabs.count == 1 && browser.active != nil)
        #expect(!browser.ghosts.map(\.url).contains(url))
    }

    @MainActor @Test func answeringTheFieldLetsTheLastTabGo() {
        let (browser, id) = window()
        defer { forget(id) }
        // Use a hierarchical page URL: WebKit rewrites opaque about: fragments.
        // This case checks closed-tab retention, not URL normalization.
        let url = URL(string: "https://example.test/last")!
        let page = browser.open(url, foreground: true)
        browser.shut([page])
        browser.send(URL(string: "about:blank#next")!, .here)
        #expect(browser.under == nil)
        #expect(browser.tabs.count == 1 && browser.active !== page)
        #expect(browser.ghosts.map(\.url).contains(url))
    }
}
