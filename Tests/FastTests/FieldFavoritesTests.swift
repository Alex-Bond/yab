import Foundation
import Testing
import WebKit
@testable import Fast

// Favorites in ⌘T's field (FieldFavorites): what a row keeps, the list
// kept in the settings, and the empty field's rows around it. Each test
// keeps its list in a settings suite of its own and its own history, so
// none of it reaches another test or the person's browser.
@MainActor
struct FieldFavoritesTests {
    private let downloads = FieldFavorite(id: "place:downloads")
    private let history = FieldFavorite(id: "place:history")
    private let clipboard = FieldFavorite(id: "place:clipboard")
    private let news = FieldFavorite(id: "page:https://news.test/", name: "News")

    /// A list kept in a suite of its own, forgotten after.
    private func store() -> (FieldFavorites, UserDefaults, () -> Void) {
        let suite = "dev.serafim.fast.test.favorites-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        return (FieldFavorites(defaults: defaults), defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    // MARK: the list

    @Test func keptLastAndTakenOut() {
        let (favorites, _, done) = store()
        defer { done() }
        #expect(favorites.all.isEmpty)
        #expect(favorites.toggle(downloads))
        #expect(favorites.toggle(history))
        #expect(favorites.all.map(\.id) == ["place:downloads", "place:history"])
        #expect(favorites.has(history))
        #expect(!favorites.toggle(downloads))
        #expect(favorites.all.map(\.id) == ["place:history"])
        #expect(!favorites.has(downloads))
    }

    @Test func aPageIsOneWhateverItsSchemeOrWWW() {
        let (favorites, _, done) = store()
        defer { done() }
        favorites.toggle(FieldFavorite(id: "page:https://www.code.test/", name: "Code"))
        #expect(favorites.has(FieldFavorite(id: "page:http://code.test")))
        #expect(!favorites.has(FieldFavorite(id: "page:https://code.test/sam")))
        #expect(!favorites.has(FieldFavorite(id: "page:https://code.test:8443/")))
        #expect(!favorites.has(FieldFavorite(id: "page:https://code.test/?tab=stars")))
        // The same page again is the one kept, taken out.
        #expect(!favorites.toggle(FieldFavorite(id: "page:http://code.test")))
        #expect(favorites.all.isEmpty)
        // Written twice by hand, read once.
        favorites.all = [downloads, FieldFavorite(id: "place:downloads"), news]
        #expect(favorites.all == [downloads, news])
    }

    @Test func onlyTheHostIsAnyCase() {
        func same(_ one: String, _ other: String) -> Bool {
            FieldFavorite(id: "page:" + one).same == FieldFavorite(id: "page:" + other).same
        }
        #expect(same("https://WWW.Video.test/watch?v=aBc", "http://video.test/watch?v=aBc"))
        // A video's id in the query, a document's in the path, a fragment.
        #expect(!same("https://video.test/watch?v=aBc", "https://video.test/watch?v=abc"))
        #expect(!same("https://docs.test/d/AbC/edit", "https://docs.test/d/abc/edit"))
        #expect(!same("https://docs.test/#Part", "https://docs.test/#part"))
        #expect(FieldFavorite.page(URL(string: "https://Docs.TEST:8443/d/AbC?x=Y#Z")!) == "docs.test:8443/d/AbC?x=Y#Z")
    }

    @Test func aPairOfCommandsIsOneFavorite() {
        func of(_ command: Command) -> FieldFavorite? {
            FieldFavorite.of(Suggestion(key: command.title, title: "", url: nil, kind: .command(command)))
        }
        // Each half is kept as the pair's first, and read back as it.
        for (first, second) in Command.pairs {
            #expect(of(first)?.id == "do:" + first.rawValue)
            #expect(of(second)?.id == "do:" + first.rawValue)
            #expect(FieldFavorite(id: "do:" + second.rawValue).what == .command(first))
            #expect(second.halves == [first, second] && first.halves == [first, second])
        }
        #expect(Command.reload.halves == [.reload])
        #expect(of(.reload)?.id == "do:reload")
        // What ⌘T's field already is, and what is gone once done.
        #expect(of(.newTab) == nil)
        #expect(of(.makeDefault) == nil)
        // Listed as the half there to do now, whichever was kept.
        let (browser, done) = window([], favorites: [FieldFavorite(id: "do:hideBar")])
        defer { done() }
        let rows = browser.quietRows().filter(\.favorite)
        #expect(rows.map(\.kind) == [Suggestion.Kind.command(browser.prefs.addressBar ? Command.hideBar : .showBar)])
        #expect(browser.favorites.has(FieldFavorite(id: "do:showBar")))
    }

    @Test func keptInTheSettingsForSyncToCarry() {
        let (first, defaults, done) = store()
        defer { done() }
        first.toggle(downloads)
        first.toggle(news)
        let again = FieldFavorites(defaults: defaults)
        #expect(again.all == [downloads, news])
        #expect(again.all.last?.name == "News")
        // Plain property lists, the name only where there is one.
        let written = defaults.array(forKey: FieldFavorites.key) as? [[String: String]]
        #expect(written == [["id": "place:downloads"], ["id": "page:https://news.test/", "name": "News"]])
        #expect(SyncShapes.syncs(FieldFavorites.key))
        // The last one out leaves an empty list, for the other Macs to take.
        again.toggle(downloads)
        again.toggle(news)
        #expect(defaults.array(forKey: FieldFavorites.key)?.isEmpty == true)
        #expect(FieldFavorites(defaults: defaults).all.isEmpty)
    }

    @Test func movedUpAndDown() {
        let (favorites, _, done) = store()
        defer { done() }
        favorites.all = [downloads, history, clipboard, news]
        #expect(favorites.move(clipboard, by: -1))
        #expect(favorites.all == [downloads, clipboard, history, news])
        #expect(favorites.move(downloads, by: 1))
        #expect(favorites.all == [clipboard, downloads, history, news])
        // Nowhere to go past either end.
        #expect(!favorites.move(clipboard, by: -1))
        #expect(!favorites.move(news, by: 1))
        #expect(!favorites.move(FieldFavorite(id: "place:emoji"), by: 1))
        #expect(favorites.all == [clipboard, downloads, history, news])
    }

    @Test func movedPastOneTheFieldCantList() {
        let (favorites, _, done) = store()
        defer { done() }
        favorites.all = [downloads, history, clipboard, news]
        // History not listed (as Mail is while it's off): Clipboard History
        // goes up past Downloads, not into History's place.
        let shown = [downloads, clipboard, news].map(\.same)
        #expect(favorites.move(clipboard, by: -1, among: shown))
        #expect(favorites.all == [clipboard, downloads, history, news])
        #expect(favorites.move(downloads, by: 1, among: [clipboard, downloads, news].map(\.same)))
        #expect(favorites.all == [clipboard, history, news, downloads])
    }

    // MARK: what a row keeps

    @Test func whatARowKeeps() {
        func of(_ key: String, _ title: String = "", _ url: String? = nil, kind: Suggestion.Kind) -> FieldFavorite? {
            FieldFavorite.of(Suggestion(key: key, title: title, url: url.flatMap(URL.init(string:)), kind: kind))
        }
        #expect(of("History", kind: .place(.history))?.id == "place:history")
        #expect(of("Clipboard History", kind: .place(.clipboard))?.id == "place:clipboard")
        // About the page under the field: not kept.
        #expect(of("Selection", kind: .place(.selection)) == nil)
        #expect(of("Files", kind: .place(.files)) == nil)
        // A tab and Frequent say the page's name first, typed words'
        // history and a site the field knows their address.
        #expect(of("sam · Code", "code.test/sam", "https://code.test/sam", kind: .open)
                == FieldFavorite(id: "page:https://code.test/sam", name: "sam · Code"))
        #expect(of("Code", "code.test", "https://code.test/", kind: .visited)?.name == "Code")
        #expect(of("code.test/sam", "sam · Code", "https://code.test/sam", kind: .visited)?.name == "sam · Code")
        #expect(of("code.test", "Code", "https://code.test", kind: .known)?.name == "Code")
        #expect(of("localhost:3000", "", "http://localhost:3000", kind: .address)?.name == "")
        #expect(of("New Private Tab", "⇧⌘N", kind: .command(.privateTab))?.id == "do:privateTab")
        #expect(of("Appearance", "Settings", kind: .setting(.appearance))?.id == "set:appearance")
        // There only for now, or no page of the web.
        #expect(of("4", "2+2", kind: .sum) == nil)
        #expect(of("words", "Search", "https://search.test/?q=words", kind: .search) == nil)
        #expect(of("Copy Link", kind: .page("copy")) == nil)
        #expect(of("Mail", "", "yab://mail", kind: .open) == nil)
        #expect(of("Copied", kind: .clip(UUID())) == nil)
        #expect(of("Quick action that isn't kept", "", "https://new.test", kind: .quickAction("no-such-action")) == nil)
    }

    @Test func idsReadBack() {
        #expect(FieldFavorite(id: "place:downloads").what == .place(.downloads))
        #expect(FieldFavorite(id: "page:https://news.test/?a=b:c").what == .page(URL(string: "https://news.test/?a=b:c")!))
        #expect(FieldFavorite(id: "do:privateTab").what == .command(.privateTab))
        #expect(FieldFavorite(id: "set:appearance").what == .setting(.appearance))
        #expect(FieldFavorite(id: "quick:new-document").what == .quickAction("new-document"))
        #expect(FieldFavorite(id: "place:nowhere").what == nil)
        #expect(FieldFavorite(id: "nothing").what == nil)
    }

    @Test func theKeysAreRaycasts() {
        #expect(Shortcut.byAction[.fieldFavorite]?.key == Hotkey("f", [.shift, .command]))
        #expect(Shortcut.byAction[.fieldFavoriteUp]?.key == Hotkey("↑", [.option, .command]))
        #expect(Shortcut.byAction[.fieldFavoriteDown]?.key == Hotkey("↓", [.option, .command]))
        // Mail's From has ⇧⌘F too, heard only in mail, never in the field.
        #expect(!Keymap.conflicts(.fieldFavorite, Hotkey("f", [.shift, .command]), .mailFrom, Hotkey("f", [.shift, .command])))
        let action = FieldAction(id: "favorite", title: "Add to Favorites", keys: "⇧⌘F") {}
        #expect(action.shortcut == .fieldFavorite)
    }

    // MARK: the empty field

    private func page(_ address: String, title: String, seen: TimeInterval, store: WKWebsiteDataStore) -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let tab = Tab(configuration: configuration)
        tab.restore(url: URL(string: address)!, title: title)
        tab.touch(at: Date(timeIntervalSince1970: seen))
        return tab
    }

    private func visit(_ address: String, _ title: String, count: Int) -> Visit {
        let url = URL(string: address)!
        return Visit(url: address, key: Address.pretty(url).lowercased(), title: title, count: count, last: Date())
    }

    /// A window of the test's own with these tabs (none in front, as ⌘T
    /// over nothing), these favorites and this history.
    private func window(_ tabs: [Tab], favorites list: [FieldFavorite], visits: [Visit] = []) -> (Browser, () -> Void) {
        let id = UUID(), browser = Browser(windowID: id)
        let (favorites, _, done) = store()
        favorites.all = list
        browser.favorites = favorites
        browser.history = History(visits)
        browser.lay(tabs)
        // Now as this test's own: nothing Yab noticed elsewhere in the run
        // (an earlier suite's finished, unread tasks stood as three rows
        // of Now and left Recent Tabs and Frequent no room of the eight).
        let noticing = Hints.shared.suggesting
        Hints.shared.suggesting = false
        // The whole history's Frequent, whatever spaces the run has left.
        let reach = Store.settings.string(forKey: FrequentReach.key)
        Store.settings.set(FrequentReach.everySpace.rawValue, forKey: FrequentReach.key)
        return (browser, {
            Store.settings.set(reach, forKey: FrequentReach.key)
            Hints.shared.suggesting = noticing
            for tab in tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            done()
        })
    }

    private let sites = [("https://news.test/", "News", 40), ("https://code.test/", "Code", 30),
                         ("https://mail.test/", "Mail", 20), ("https://docs.test/", "Docs", 15),
                         ("https://maps.test/", "Maps", 10)]

    private func tabs() -> [Tab] {
        let store = WKWebsiteDataStore.nonPersistent()
        return [page("https://one.test/", title: "One", seen: 1, store: store),
                page("https://two.test/", title: "Two", seen: 2, store: store),
                page("https://three.test/", title: "Three", seen: 3, store: store),
                page("https://four.test/", title: "Four", seen: 4, store: store)]
    }

    /// The rows before Favorites, all of Now, and Favorites' rows.
    private func parts(_ rows: [Suggestion]) -> (now: Int, favorites: [Suggestion], setup: Int) {
        let first = rows.firstIndex(where: \.favorite) ?? rows.count
        // Getting started: its Set up Yab row, Yab for iPhone's own row
        // under it while no iPhone is in sync (PhoneBeta), and Connect
        // Claude or ChatGPT while no plan is connected (AIUse.connectOffered).
        return (first, rows.filter(\.favorite), rows.filter { $0.kind == .page("setup") || PhoneBeta.offered($0) || $0.kind == .hint(Hints.connectID) }.count)
    }

    @Test func withNoneNothingMoves() {
        let (browser, done) = window(tabs(), favorites: [], visits: sites.map { visit($0.0, $0.1, count: $0.2) })
        defer { done() }
        let rows = browser.quietRows()
        #expect(!rows.contains { $0.favorite })
        #expect(!rows.contains { browser.quietSection($0) == "Favorites" })
        // Three of the four tabs, and Frequent with what is left.
        #expect(rows.filter { $0.kind == .open }.count == 3)
        #expect(rows.count <= 8)
        #expect(rows.filter { $0.kind == .visited }.count == min(3, 8 - (rows.count - rows.filter { $0.kind == .visited }.count)))
    }

    @Test func favoritesFollowNowInTheirOrder() {
        let (browser, done) = window(tabs(), favorites: [downloads, history, clipboard, news],
                                     visits: sites.map { visit($0.0, $0.1, count: $0.2) })
        defer { done() }
        let rows = browser.quietRows()
        let (now, favorites, setup) = parts(rows)
        #expect(favorites.map(\.key) == ["Files", "History", "Clipboard History", "News"])
        #expect(favorites.allSatisfy { browser.quietSection($0) == "Favorites" })
        // One part, right under Now.
        #expect(Array(rows[now..<now + favorites.count]) == favorites)
        #expect(rows[..<now].allSatisfy { browser.quietSection($0) == "Now" })
        // A place is its own row, the page not open a page to open.
        #expect(favorites[0].kind == .place(.downloads))
        #expect(favorites[3].kind == .visited && favorites[3].url == URL(string: "https://news.test/"))
        // The rest share what is left of the eight, Recent Tabs first.
        let left = max(0, 8 - now - favorites.count - setup)
        #expect(rows.filter { $0.kind == .open }.count == min(3, left))
        #expect(rows.count <= max(8, now + favorites.count + setup))
        // News is listed once, as a favorite.
        #expect(rows.filter { $0.url?.host() == "news.test" }.count == 1)
    }

    @Test func aFavoritePageOpenIsItsTabAndIsNotRepeated() {
        let row = tabs()
        let kept = FieldFavorite(id: "page:http://two.test", name: "Second")
        let (browser, done) = window(row, favorites: [kept], visits: sites.map { visit($0.0, $0.1, count: $0.2) }
                                     + [visit("https://two.test/", "Two", count: 99)])
        defer { done() }
        let rows = browser.quietRows()
        let favorites = rows.filter(\.favorite)
        // Its tab, switched to, under the name it was kept by.
        #expect(favorites.map(\.kind) == [.open])
        #expect(favorites.first?.tab == row[1].id)
        #expect(favorites.first?.key == "Second")
        // Not in Recent Tabs, and its site not in Frequent.
        let recent = rows.filter { $0.kind == .open && !$0.favorite }
        #expect(!recent.contains { $0.tab == row[1].id })
        #expect(recent.count == 3)
        #expect(!rows.contains { $0.kind == .visited && $0.url?.host() == "two.test" })
    }

    @Test func aFavoriteSiteIsNotInFrequent() {
        let (browser, done) = window([], favorites: [news], visits: sites.map { visit($0.0, $0.1, count: $0.2) })
        defer { done() }
        let rows = browser.quietRows()
        let frequent = rows.filter { $0.kind == .visited && !$0.favorite }
        #expect(!frequent.isEmpty)
        #expect(!frequent.contains { $0.url?.host() == "news.test" })
        #expect(rows.filter { $0.url?.host() == "news.test" }.map(\.favorite) == [true])
    }

    @Test func allFavoritesListedTheRestShrinking() {
        let places: [FieldPlace] = [.downloads, .history, .clipboard, .bookmarks, .passwords, .autofill, .emoji]
        let (browser, done) = window(tabs(), favorites: places.map { FieldFavorite(id: "place:" + $0.rawValue) } + [FieldFavorite(id: "set:appearance")],
                                     visits: sites.map { visit($0.0, $0.1, count: $0.2) })
        defer { done() }
        let rows = browser.quietRows()
        let (now, favorites, setup) = parts(rows)
        // All of them, past the eight the box scrolls to, and nothing else
        // beside Now and getting started.
        #expect(favorites.count == 8)
        #expect(rows.count == now + 8 + setup)
        #expect(!rows.contains { !$0.favorite && ($0.kind == .open || $0.kind == .visited) })

        // Three: the others shrink to the five left, Recent Tabs first.
        browser.favorites.all = Array(browser.favorites.all.prefix(3))
        let fewer = browser.quietRows()
        let three = parts(fewer)
        #expect(three.favorites.count == 3)
        #expect(fewer.filter { $0.kind == .open }.count == min(3, 8 - three.now - 3 - three.setup))
        #expect(fewer.count <= 8)
    }

    @Test func oneThatCantBeListedWaits() {
        let (browser, done) = window([], favorites: [FieldFavorite(id: "place:selection"), FieldFavorite(id: "do:separate"), downloads])
        defer { done() }
        // Selection is never one; Separate Split View has no pair here.
        #expect(browser.quietRows().filter(\.favorite).map(\.key) == ["Files"])
    }

    // MARK: ⇧⌘F, Move Up and Move Down on the rows

    @Test func addedFromItsRowAndMovedWithTheRowChosen() throws {
        let row = tabs()
        let (browser, done) = window(row, favorites: [downloads, history])
        defer { done() }
        browser.typed = ""
        func chosen() throws -> Suggestion {
            let at = try #require(browser.query.current)
            return try #require(browser.offers.indices.contains(at) ? browser.offers[at] : nil)
        }
        // A tab of Recent Tabs: Add to Favorites, before Close Tab.
        let four: Int = try #require(browser.offers.firstIndex { $0.kind == .open && $0.tab == row[3].id })
        browser.picked = four
        let titles = browser.rowActions.map(\.title)
        let add = try #require(titles.firstIndex(of: "Add to Favorites"))
        #expect(add < (titles.firstIndex(of: "Close Tab") ?? 0))
        #expect(!titles.contains("Move Up"))
        #expect(browser.runAction("favorite"))
        // Kept last, its tab still the row, and that row chosen: the row
        // moving says it, the corner nothing.
        #expect(browser.favorites.all.map(\.id).last == "page:https://four.test/")
        #expect(!browser.toaster.shown)
        let kept = try chosen()
        #expect(kept.favorite && kept.tab == row[3].id)
        #expect(browser.offers.filter(\.favorite).map(\.key) == ["Files", "History", "Four"])
        // On a favorite: Remove, Move Up; the last has no Move Down.
        let own = browser.rowActions.map(\.title)
        #expect(own.contains("Remove from Favorites") && own.contains("Move Up") && !own.contains("Move Down"))
        #expect(browser.runAction("moveup"))
        #expect(browser.offers.filter(\.favorite).map(\.key) == ["Files", "Four", "History"])
        let moved = try chosen()
        #expect(moved.favorite && moved.key == "Four")
        // Taken out: back among Recent Tabs, still chosen there.
        #expect(browser.runAction("favorite"))
        #expect(browser.favorites.all == [downloads, history])
        let out = try chosen()
        #expect(!out.favorite && out.tab == row[3].id)
    }

    @Test func aFavoritePageHasNoForget() {
        let (browser, done) = window([], favorites: [news], visits: sites.map { visit($0.0, $0.1, count: $0.2) })
        defer { done() }
        browser.typed = ""
        browser.picked = browser.offers.firstIndex(where: \.favorite)
        let titles = browser.rowActions.map(\.title)
        #expect(titles.contains("Remove from Favorites"))
        #expect(!titles.contains("Remove"))
        #expect(!browser.forgetChosen())
        // Frequent's own row still has it.
        browser.picked = browser.offers.firstIndex { $0.kind == .visited && !$0.favorite }
        #expect(browser.rowActions.map(\.title).contains("Remove"))
        #expect(browser.rowActions.map(\.title).contains("Add to Favorites"))
    }

    /// #199: Frequent's row shows its page's title as its key, and ⇧⌫ and
    /// Forget This Page forgot that title, so the row stayed.
    @Test func aFrequentRowGoesWhenForgotten() throws {
        let deep = visit("https://code.test/pulls", "Pull Requests", count: 5)
        let (browser, done) = window([], favorites: [], visits: sites.map { visit($0.0, $0.1, count: $0.2) } + [deep])
        defer { done() }
        browser.typed = ""
        let row = try #require(browser.offers.firstIndex { $0.frequent == "code.test" })
        browser.picked = row
        #expect(browser.forgetChosen())
        #expect(!browser.history.remembers("code.test"))
        // The site, not just its page: no other page of it takes the row.
        #expect(!browser.offers.contains { $0.url?.host() == "code.test" })
        // By ⌘K too, on the next one.
        let next = try #require(browser.offers.firstIndex { $0.frequent != nil })
        let key = try #require(browser.offers[next].frequent)
        browser.picked = next
        #expect(browser.runAction("forget"))
        #expect(!browser.history.remembers(key))
        #expect(!browser.offers.contains { $0.frequent == key })
    }

    /// A right-click on a row chooses it and raises ⌘K's panel with its
    /// actions; the pointer crossing other rows on its way to the panel
    /// leaves the panel the row's (Forget This Page once forgot nothing).
    @Test func aRightClickedRowKeepsItsActions() async throws {
        let (browser, done) = window([], favorites: [], visits: sites.map { visit($0.0, $0.1, count: $0.2) })
        defer { done() }
        browser.typed = ""
        let rows = browser.offers.indices.filter { browser.offers[$0].frequent != nil }
        let first = try #require(rows.first), other = try #require(rows.dropFirst().first)
        let key = try #require(browser.offers[first].frequent)
        browser.showActions(forRow: first)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))
        #expect(browser.query.current == first)
        #expect(browser.query.acting == 0)
        #expect(browser.shownActions.map(\.title).contains("Remove"))
        browser.query.restingAt = nil
        browser.point(at: other)
        #expect(browser.query.current == first)
        let forget = try #require(browser.shownActions.firstIndex { $0.title == "Remove" })
        browser.query.acting = forget
        browser.submit()
        #expect(!browser.offers.contains { $0.frequent == key })
        #expect(browser.query.acting == nil)
    }

    @Test func aPageInHistoryOrBookmarksCanBeOne() {
        let (browser, done) = window([], favorites: [news])
        defer { done() }
        let delete = FieldAction(id: "delete", title: "Forget This Page") {}
        #expect(browser.favoriting(URL(string: "https://code.test/")!, named: "Code", [delete]).map(\.title) == ["Add to Favorites", "Forget This Page"])
        #expect(browser.favoriting(URL(string: "http://www.news.test")!, named: "News", []).map(\.title) == ["Remove from Favorites"])
    }

    @Test func typedWordsFindAFavoriteAsTheirKind() {
        let (browser, done) = window([], favorites: [history])
        defer { done() }
        browser.typed = "hist"
        let at = browser.offers.firstIndex { $0.kind == .place(.history) }
        #expect(at != nil)
        #expect(!browser.offers.contains { $0.favorite })
        browser.picked = at
        #expect(browser.rowActions.map(\.title) == ["Open History", "Remove from Favorites"])
        // Taken out from there: the typed rows stay where they are, and
        // the corner says what no row shows.
        let before = browser.offers
        #expect(browser.runAction("favorite"))
        #expect(browser.favorites.all.isEmpty)
        #expect(browser.offers == before)
        #expect(browser.toaster.shown && browser.toaster.words == "Removed from Favorites")
        #expect(browser.rowActions.map(\.title) == ["Open History", "Add to Favorites"])
        #expect(browser.runAction("favorite"))
        #expect(browser.favorites.all == [history])
        #expect(browser.toaster.words == "Added to Favorites")
    }

    @Test func aCommandCalledByItsWholeNameLeads() {
        let (browser, done) = window([], favorites: [])
        defer { done() }
        browser.typed = "site controls"
        #expect(browser.offers.first?.kind == .command(.extensions))
        // Only begun, it waits under the search.
        browser.typed = "site cont"
        #expect(browser.offers.first?.kind != .command(.extensions))
    }

    // MARK: private tabs

    @Test func aPrivateTabsRowIsNeverKept() throws {
        let shy = Tab(shy: true, configuration: Web.configuration(shy: true))
        shy.restore(url: URL(string: "https://secret.test/Plans")!, title: "Plans")
        shy.touch(at: Date(timeIntervalSince1970: 9))
        let (browser, done) = window(tabs() + [shy], favorites: [])
        defer { done() }
        browser.typed = ""
        // Listed in Recent Tabs from a plain field, as before, and never kept
        // from there: no Add to Favorites, and ⇧⌘F goes on.
        let shyRow: Int = try #require(browser.offers.firstIndex { $0.tab == shy.id })
        browser.picked = shyRow
        #expect(!browser.rowActions.contains { $0.id == "favorite" })
        #expect(!browser.runAction("favorite"))
        #expect(!browser.favoriteKey("favorite"))
        #expect(browser.favorites.all.isEmpty)
        // A plain tab's row beside it still can be.
        browser.picked = browser.offers.firstIndex { $0.kind == .open && $0.tab != shy.id }
        #expect(browser.rowActions.contains { $0.id == "favorite" })
        // The same page kept from elsewhere never switches to the private
        // tab, which stays in Recent Tabs as somewhere else.
        browser.favorites.all = [FieldFavorite(id: "page:https://secret.test/Plans", name: "Plans")]
        let rows = browser.quietRows()
        let kept = try #require(rows.first { $0.favorite })
        #expect(kept.kind == .visited && kept.tab == nil)
        #expect(rows.contains { !$0.favorite && $0.tab == shy.id })
    }
}
