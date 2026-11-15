import AppKit
import Testing
@testable import Fast

@Suite(.serialized)
struct PrivateNormalWindowTests {
    @MainActor private func withBrowser(_ purpose: BrowserWindowPurpose, _ body: (Browser) throws -> Void) rethrows {
        let browser = Browser(windowID: UUID(), purpose: purpose)
        defer {
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for tab in browser.tabs { tab.close() }
        }
        try body(browser)
    }

    @MainActor @Test func newWindowIsDiscoverableAndTeachesTheWindowShortcut() throws {
        let command = try #require(Command(rawValue: "newWindow"))
        for words in ["new window", "normal window", "regular window"] {
            #expect(CommandTests.best(words) == command)
        }
        #expect(command.title == "New Window")
        #expect(command.opens)
        #expect(command.keys == Keymap.shared.text(.newWindow))
        withBrowser(.privateOnly) { browser in
            #expect(command.available(in: browser))
            let page = browser.open(URL(string: "https://private-window.test/last")!, foreground: true)
            browser.close(page)
            #expect(browser.tabs.isEmpty)
            #expect(command.available(in: browser))
        }
    }

    @MainActor @Test func commandKOffersANormalWindowWithNoNormalTabs() {
        withBrowser(.privateOnly) { browser in
            #expect(browser.privateBrowsing)
            #expect(browser.fieldMenuActions.contains { $0.id == "newWindow" && $0.title == "New Window" })
            browser.showActions()
            #expect(browser.query.acting == 0)
            #expect(Browser.shownActions.contains("New Window"))
        }
    }

    @MainActor @Test func commandKStillWorksAfterTheLastPrivateTabCloses() {
        withBrowser(.privateOnly) { browser in
            let page = browser.open(URL(string: "https://private-window.test/last")!, foreground: true)
            browser.close(page)
            #expect(browser.tabs.isEmpty && browser.privateBrowsing)
            // The private foot hosts Cmd-K's panel even without an active tab.
            #expect(Omnibox(browser: browser, inset: 0).shy)
            browser.showActions()
            #expect(browser.query.acting == 0)
            #expect(browser.fieldMenuActions.contains { $0.id == "newWindow" })
        }
    }

    @MainActor @Test func normalFieldsKeepTheirExistingRowActions() {
        withBrowser(.normal) { browser in
            #expect(!Omnibox(browser: browser, inset: 0).shy)
            #expect(!browser.fieldMenuActions.contains { $0.id == "newWindow" })
        }
    }

    @MainActor @Test func anEmptyPrivateFieldDoesNotOfferNewWindowAsItsReturnAction() {
        withBrowser(.privateOnly) { browser in
            let compact = browser.prefs.compactField
            browser.prefs.compactField = true
            defer { browser.prefs.compactField = compact }
            // The field lists again for the compact card it now is.
            browser.typed = ""
            #expect(browser.fieldActions.isEmpty)
            #expect(!browser.runPrimary())
            browser.showActions()
            #expect(browser.shownActions.contains { $0.id == "newWindow" })
            browser.query.acting = nil
            #expect(browser.fieldActions.isEmpty)
            #expect(!browser.runPrimary())
        }
    }

    /// A private window opens as ⌘N's: no tab, the field asking, no empty
    /// "New Private Tab" row of its own.
    @MainActor @Test func aPrivateWindowOpensWithTheFieldAndNoTab() {
        withBrowser(.privateOnly) { browser in
            #expect(browser.tabs.isEmpty && browser.active == nil)
            #expect(browser.fieldShowing && browser.privateBrowsing)
            #expect(!Omnibox(browser: browser, inset: 0).stealth)
        }
    }

    /// ⌘T in a private window is everyone's ⌘T: the field over the page and
    /// no row until a place is chosen; what it opens is private.
    @MainActor @Test func commandTAsksOverThePageAndOpensOnlyPrivateTabs() {
        withBrowser(.privateOnly) { browser in
            let page = browser.open(URL(string: "https://private-window.test/news")!, foreground: true)
            browser.newTab()
            #expect(browser.windowPurpose == .privateOnly)
            #expect(browser.tabs.count == 1 && browser.active === page && browser.fieldShowing)
            let next = browser.open(URL(string: "https://private-window.test/weather")!, foreground: true)
            #expect(browser.tabs.count == 2 && browser.active === next)
            #expect(browser.tabs.allSatisfy { $0.shy && !$0.store.isPersistent })
        }
    }

    /// The empty field over a private window's page lists that window's
    /// other tabs and nothing of yours from anywhere else.
    @MainActor @Test func thePrivateFieldListsOnlyThisWindowsTabs() {
        withBrowser(.privateOnly) { browser in
            let compact = browser.prefs.compactField
            browser.prefs.compactField = true
            defer { browser.prefs.compactField = compact }
            let news = URL(string: "https://private-window.test/news")!
            browser.open(news, foreground: true)
            browser.open(URL(string: "https://private-window.test/weather")!, foreground: true)
            browser.newTab()
            #expect(browser.quietRows().map(\.url) == [news])
        }
    }

    @MainActor @Test func largePrivateFieldUsesTheUsualSectionsAndActions() {
        withBrowser(.privateOnly) { browser in
            let compact = browser.prefs.compactField
            browser.prefs.compactField = false
            defer { browser.prefs.compactField = compact }
            // Now as this test's own: what Yab noticed elsewhere in the run
            // (finished, unread tasks of earlier suites) took Frequent's room.
            let noticing = Hints.shared.suggesting
            Hints.shared.suggesting = false
            defer { Hints.shared.suggesting = noticing }
            // The whole history's Frequent, whatever spaces the run has left.
            let reach = Store.settings.string(forKey: FrequentReach.key)
            Store.settings.set(FrequentReach.everySpace.rawValue, forKey: FrequentReach.key)
            defer { Store.settings.set(reach, forKey: FrequentReach.key) }
            let suite = "dev.serafim.fast.test.private-field-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let favorites = FieldFavorites(defaults: defaults)
            favorites.all = [FieldFavorite(id: "page:https://favorite.test/", name: "Favorite")]
            browser.favorites = favorites
            let frequent = URL(string: "https://frequent.test/")!
            browser.history = History([Visit(url: frequent.absoluteString, key: Address.pretty(frequent).lowercased(),
                                             title: "Frequent", count: 30, last: Date())])

            let first = browser.open(URL(string: "https://private-window.test/news")!, foreground: true)
            browser.open(URL(string: "https://private-window.test/weather")!, foreground: true)
            browser.newTab()
            let rows = browser.quietRows()
            #expect(rows.contains { $0.favorite && browser.quietSection($0) == "Favorites" })
            #expect(rows.contains { $0.tab == first.id && browser.quietSection($0) == "Recent Tabs" })
            #expect(rows.contains { $0.url == frequent && browser.quietSection($0) == "Frequent" },
                    "\(rows.map { "\($0.key) [\(browser.quietSection($0) ?? "-")]" })")
            browser.typed = ""
            #expect(browser.offers.contains { $0.tab == first.id })
            if let recent = browser.offers.firstIndex(where: { $0.tab == first.id }) {
                browser.picked = recent
                #expect(browser.fieldActions.first?.title == "Switch to Tab")
                #expect(browser.fieldActions.count > 1)
            }
        }
    }

    @MainActor @Test func privateSidebarKeepsItsAddressAndNameWithTopBarSelected() {
        withBrowser(.privateOnly) { browser in
            let addressBar = browser.prefs.addressBar
            browser.prefs.addressBar = true
            defer { browser.prefs.addressBar = addressBar }
            #expect(browser.sidePlated)
            let head = ColumnLayout.head(browser)
            #expect(head.contains { if case .privateName = $0.kind { true } else { false } })
            #expect(!head.contains { if case .name = $0.kind { true } else { false } })
            #expect(ColumnLayout.lead(browser, pins: 0) == SideBar.pinsTop(plated: true, extensions: SidePlate.pinsHeight(in: browser)) + SideBar.row + SideBar.gap)
        }
    }

    @MainActor @Test func newWindowLeavesThePrivateSourceAndItsPageAlone() {
        withBrowser(.privateOnly) { browser in
            let page = browser.open(URL(string: "https://private-window.test/secret")!, foreground: true)
            var sources: [Browser] = []
            browser.newWindow { sources.append($0) }
            #expect(sources.count == 1 && sources.first === browser)
            #expect(browser.windowPurpose == .privateOnly && browser.active === page)
            #expect(browser.tabs.count == 1 && page.shy && !page.store.isPersistent)
        }
    }

    /// Register 1015: a private window showed your spaces in its foot, and
    /// pressing one did nothing. As in Arc, it has none: no row of spaces,
    /// no other space to swipe or step to, none of yours named.
    @MainActor @Test func privateWindowsListNoneOfYourSpaces() {
        let work = Space(id: UUID(), name: "Work", icon: "💼", ownSignIns: false)
        withBrowser(.normal) { browser in
            let was = browser.prefs.usesSpaces
            browser.prefs.usesSpaces = true
            defer { browser.prefs.usesSpaces = was }
            browser.spaces = [Space(id: Space.firstID, name: "Personal", icon: "🏠", ownSignIns: false), work]
            #expect(browser.spacesShown && browser.footShowsSpaces && browser.namesSpaces)
            #expect(browser.turnOrder.contains { $0.id == work.id })
        }
        withBrowser(.privateOnly) { browser in
            let was = browser.prefs.usesSpaces
            browser.prefs.usesSpaces = true
            defer { browser.prefs.usesSpaces = was }
            browser.spaces = [Space(id: Space.firstID, name: "Personal", icon: "🏠", ownSignIns: false), work]
            #expect(!browser.spacesShown && !browser.footShowsSpaces && !browser.swipesSpaces && !browser.namesSpaces)
            #expect(browser.turnOrder.map(\.id) == [browser.spaceID])
            #expect(!browser.turnOrder.contains { $0.id == work.id || $0.id == Space.mailID })
            let here = browser.spaceID
            browser.switchSpace(to: work.id)
            #expect(browser.spaceID == here)
        }
    }
}
