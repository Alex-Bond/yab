import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct BookmarkBarTests {
    private func page(_ title: String, _ path: String = "/", host: String = "bookmarks.test") -> Bookmark {
        Bookmark.site(title, URL(string: "https://\(host)\(path)")!)
    }

    private func world(_ body: (Browser) async throws -> Void) async rethrows {
        let id = UUID(), browser = Browser(windowID: id)
        defer {
            browser.glance.drop()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for tab in browser.everyTab { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
        }
        try await body(browser)
    }

    @Test func stacksOnlyAdjacentRootPagesInIconStyles() {
        let a = page("A", "/a"), b = page("B", "/b")
        let folder = Bookmark.folder("Folder", [a, b])
        let other = page("Other", host: "other.test")
        let roots = [a, b, folder, a, other, b]
        for style in [BookmarkStyle.icons, .folders] {
            let chips = BookmarkBar.chips(roots, style: style)
            #expect(chips.map { $0.nodes.count } == [2, 1, 1, 1, 1])
            #expect(chips[0].id == a.id)
            #expect(chips[0].contents == [a, b])
            #expect(chips[1].contents == [a, b])
            #expect(chips.flatMap(\.nodes) == roots)
        }
        #expect(BookmarkBar.chips(roots, style: .names).map(\.node) == roots)
    }

    @Test func hostMatchingIsCaseInsensitiveAndKeepsSubdomainsSeparate() {
        let roots = [page("A", host: "BOOKMARKS.test"), page("B"), page("C", host: "www.bookmarks.test")]
        #expect(BookmarkBar.chips(roots, style: .icons).map { $0.nodes.count } == [2, 1])
    }

    @Test func stackAndFolderWidthsIncludeTheirCountsAndOverflow() {
        let roots = [page("A"), page("B", "/b"), Bookmark.folder("Folder", [page("C")]), page("D", host: "other.test")]
        let chips = BookmarkBar.chips(roots, style: .folders)
        let whole = BookmarkBar.run(chips[...], more: false, style: .folders)
        #expect(BookmarkBar.fit(chips, in: whole, style: .folders) == chips.count)
        let firstAndMore = BookmarkBar.run(chips.prefix(1), more: true, style: .folders)
        #expect(BookmarkBar.fit(chips, in: firstAndMore, style: .folders) == 1)
        #expect(BookmarkBar.run(chips.prefix(0), more: true, style: .folders) == BookmarkBar.more)
        #expect(BookmarkBar.fit(chips, in: 0, style: .folders) == 0)
        #expect(BookmarkBar.span(chips[0], style: .folders) > BookmarkBar.row)
        let folder = chips[1].node
        #expect(BookmarkBar.span(folder, style: .folders) == BookmarkBar.pad * 2 + BookmarkBar.icon + BookmarkBar.iconGap * 2 + BookmarkBar.words(folder) + BookmarkBar.countWidth(1))
    }

    @Test func titleTailUsesTheExistingSiteRules() {
        let revenue = page("Charts - Revenue | RevenueCat", host: "app.revenuecat.com")
        #expect(BookmarkBar.titleParts(revenue).title == "Charts - Revenue")
        #expect(BookmarkBar.titleParts(revenue).tail == "RevenueCat")
        #expect(BookmarkBar.titleParts(page("Design - Engineering")).title == "Design - Engineering")
        let pull = page("Keep tabs by mira · Pull Request #412 · acme/yab · GitHub", "/acme/yab/pull/412", host: "github.com")
        #expect(BookmarkBar.titleParts(pull).title == "Keep tabs")
        #expect(BookmarkBar.path(page("Agents", "/agents")) == "/agents")
        #expect(BookmarkBar.path(page("Home")) == "/")
    }

    @Test func folderMenuKeepsDetailsContextAndDeepSearch() async {
        await world { browser in
            let page = self.page("Charts - Revenue | RevenueCat", host: "app.revenuecat.com")
            let inner = Bookmark.folder("Favorites", [page])
            let menu = BookmarkBar.panelMenu([inner], browser: browser, title: "Imported", scheme: .dark, fetchMissing: false)
            let list = ActionMenuList(menu: menu, falls: true)
            #expect(list.placeholder == "Search Imported…")
            #expect(list.lines.first?.detail == "1")
            #expect(list.lines.first?.image != nil)
            #expect(list.lines.first?.context != nil)
            #expect(list.lines.last?.title == "Open All in New Tabs")
            #expect(list.lines.last?.detail == "1")
            #expect(list.lines.last?.boundary == .line)
            list.query = "RevenueCat"
            #expect(list.lines.contains { $0.title == "Charts - Revenue" && $0.detail == "RevenueCat" && $0.from == "Favorites" && $0.image != nil && $0.context != nil })
            list.query = "Charts"
            #expect(list.lines.first?.title == "Charts - Revenue")
        }
    }

    @Test func aFolderInsideSearchesItsOwnLinesAndEscapeEmptiesThatFirst() async {
        await world { browser in
            let inner = Bookmark.folder("Favorites", [page("Mail", "/mail"), page("Calendar", "/calendar")])
            let menu = BookmarkBar.panelMenu([inner], browser: browser, title: "Imported", scheme: .dark, fetchMissing: false)
            let list = ActionMenuList(menu: menu, falls: true)
            list.showChild = { _, _ in }
            list.take(0)
            let child = try! #require(list.child)
            #expect(child.searchVisible)
            #expect(child.focused)
            #expect(child.placeholder == "Search Favorites…")
            #expect(ActionMenuView.height(child) == ActionMenuView.listHeight(child) + ActionMenuView.search + 1)
            child.query = "Cal"
            #expect(child.lines.map(\.title) == ["Calendar"])
            child.side(-1)
            #expect(list.child === child)
            list.escape()
            #expect(child.query.isEmpty)
            #expect(list.child === child)
            list.escape()
            #expect(list.child == nil)
        }
    }

    @Test func aFolderMarkIsDrawnInItsColorsNotAsATemplate() async {
        await world { _ in
            let image = BookmarkBar.image(Bookmark.folder("Folder", []), scheme: .dark)
            #expect(image != nil)
            #expect(image?.isTemplate == false)
        }
    }

    @Test func stackMenuSearchesPathsAndEmptyMenuCannotOpenAll() async {
        await world { browser in
            let menu = BookmarkBar.panelMenu([page("Agents", "/agents"), page("Billing", "/settings")], browser: browser, title: "bookmarks.test", stack: true, scheme: .light, fetchMissing: false)
            let list = ActionMenuList(menu: menu, falls: true)
            #expect(list.lines.map(\.detail) == ["/agents", "/settings", "2"])
            list.query = "/settings"
            #expect(list.lines.map(\.title) == ["Billing"])
            let empty = BookmarkBar.panelMenu([], browser: browser, title: "Empty Folder", scheme: .light, fetchMissing: false)
            let emptyList = ActionMenuList(menu: empty, falls: true)
            #expect(emptyList.lines.last?.title == "Open All in New Tabs")
            #expect(emptyList.lines.last?.enabled == false)
            #expect(emptyList.lines.last?.detail == "0")
        }
    }

    @Test func bookmarkCardsUseTheSharedFolderDwellAndWarmTransfer() async throws {
        try await world { browser in
            let glance = browser.glance
            let first = "bookmark:first", next = "bookmark:next"
            let chip = BookmarkBar.Chip(nodes: [page("One")])
            let a = CGRect(x: 0, y: 0, width: 24, height: 24), b = a.offsetBy(dx: 24, dy: 0)
            var pointer = CGPoint(x: 12, y: 12)
            glance.pointerLocation = { pointer }
            glance.putBookmark(first, chip: chip, frame: a)
            glance.putBookmark(next, chip: chip, frame: b)
            glance.hoverBookmark(first, true)
            #expect(glance.shownFolder == nil)
            try await Task.sleep(for: .milliseconds(550))
            #expect(glance.shownFolder == first)
            #expect(!glance.searching)
            glance.hoverBookmark(first, false)
            pointer.x = 36
            glance.hoverBookmark(next, true)
            #expect(glance.shownFolder == next)
            glance.removeBookmark(next)
            #expect(glance.shownFolder == nil)
            #expect(glance.bookmarkChips[next] == nil)
            #expect(glance.folderFrames[next] == nil)
        }
    }

    @Test func openTabWinsOverLiveNowAndButtonSelectsIt() async {
        await world { browser in
            let number = Int.random(in: 100_000..<999_999)
            let url = URL(string: "https://linear.app/test/issue/OPEN-\(number)/bookmarks")!
            let node = Bookmark.site("Saved Title", url)
            LiveSeen.note([LiveItem(key: "linear/OPEN-\(number)", url: url, title: "Live Title", group: "QA", words: .late, updated: nil)])
            let tab = Tab()
            tab.restore(url: URL(string: node.url!)!, title: "Open Title")
            browser.prepare(tab)
            browser.lay([tab])
            let open = BookmarkGlance.opened(node, in: browser)
            #expect(open?.tab === tab)
            let gist = BookmarkGlance.gist(node, open: open, at: Date())
            #expect(gist.now?.text == "Open in " + browser.space.name)
            #expect(gist.action?.label == "Go to Tab")
            open?.go()
            #expect(browser.activeID == tab.id)
            #expect(browser.tabs.count == 1)
        }
    }

    @Test func duplicateOpenTabsAreCounted() async {
        await world { browser in
            let node = page("Saved", "/duplicate")
            let tabs = (0..<2).map { _ in
                let tab = Tab()
                tab.restore(url: URL(string: node.url!)!, title: "Open")
                browser.prepare(tab)
                return tab
            }
            browser.lay(tabs)
            let open = BookmarkGlance.opened(node, in: browser)
            #expect(open?.count == 2)
            #expect(open?.text.hasSuffix(" · 2 tabs") == true)
        }
    }

    @Test func savedSpaceMatchesAreIgnoredOnceTheRowIsLoaded() async {
        await world { browser in
            let node = page("Saved", "/saved")
            let space = UUID()
            let saved = BookmarkGlance.Stored(browser: browser, space: space, url: URL(string: node.url!)!)
            #expect(BookmarkGlance.opened(node, in: browser, stored: [saved])?.tab == nil)
            #expect(BookmarkGlance.opened(node, in: browser, stored: [saved])?.count == 1)
            browser.parked[space] = Parked(tabs: [], active: nil)
            #expect(BookmarkGlance.opened(node, in: browser, stored: [saved]) == nil)
        }
    }

    @Test func liveFolderSignalsAndPlainFallbackUseTabGist() async {
        await world { browser in
            let number = Int.random(in: 100_000..<999_999)
            let url = URL(string: "https://linear.app/test/issue/QA-\(number)/bookmarks")!
            let item = LiveItem(key: "linear/QA-\(number)", url: url, title: "Finish bookmarks", group: "QA", words: .late, updated: nil, due: Date(timeIntervalSince1970: 0))
            LiveSeen.note([item])
            let node = Bookmark.site("Old label", url)
            let gist = BookmarkGlance.gist(node, open: nil, at: Date(timeIntervalSince1970: 2 * 86_400))
            #expect(gist.title == item.title)
            #expect(gist.now?.word == "Late")
            #expect(gist.now?.text == "by 2 days")
            #expect(gist.action == nil)
            let plain = page("Guide - Bookmarks", "/guide")
            #expect(BookmarkGlance.gist(plain, open: nil, at: Date()).title == "Guide")
            #expect(BookmarkGlance.gist(plain, open: nil, at: Date()).now == nil)
            #expect(BookmarkGlance.site(URL(string: "https://www.bookmarks.test/agents")!) == "bookmarks.test/agents")
        }
    }

    @Test func missingStoredPictureReturnsNothing() async {
        let picture = await TabGlance.storedStill(URL(string: "https://\(UUID().uuidString).invalid/no-picture")!)
        #expect(picture == nil)
    }
}
