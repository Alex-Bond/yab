import AppKit
import Foundation
import Testing
import WebKit
@testable import Fast

/// #238: without a configured rule, a typed address belongs to this Space;
/// choosing a Switch to Tab row explicitly may still take its Space with it.
/// #866: a configured rule applies to a new site requested with Cmd-T.
/// Cookie sharing does not make two Spaces the same destination.
@MainActor
@Suite(.serialized)
struct FieldSpaceURLTests {
    @Test(arguments: [false, true])
    func profileDiscoveryKeepsTheFixturesSignIns(isolated: Bool) {
        let w = World(isolated: isolated); defer { w.close() }
        let original = Spaces.store(for: w.other.id)
        // Native profile discovery reads the persisted Space list and rebuilds
        // its sign-in map, just as opening a Chromium-backed tab does.
        _ = ChromiumPersistentProfiles.plan(for: w.remote.store)
        #expect(Spaces.sharing.contains(w.other.id) == !isolated)
        #expect(Spaces.store(for: w.other.id) === original)
    }

    @MainActor private final class World {
        let browser: Browser
        let home = Space(id: UUID(), name: "URL home", icon: "H", ownSignIns: false)
        let other: Space
        let target = URL(string: "https://chat.space238.test/inbox")!
        let remote: Tab
        let current: Tab
        let previousCurrent = Spaces.current
        let previousSuggestions = Store.settings.object(forKey: "search.suggest")
        let previousSpaces = Store.settings.object(forKey: "spaces")
        let previousList = try? Data(contentsOf: Store.file("spaces.json"))
        let previousRoute = LinkRoutes.shared.route(site: "chat.space238.test")

        init(isolated: Bool) {
            _ = NSApplication.shared
            other = Space(id: UUID(), name: "URL other", icon: "O", ownSignIns: isolated)
            browser = Browser(windowID: UUID())
            browser.prefs.usesSpaces = true
            browser.prefs.searchSuggest = false
            browser.spaces.append(contentsOf: [home, other])
            // Profile discovery reads spaces.json. A Browser-only list would
            // lose these shared sign-ins when that read rebuilds the map.
            Spaces.write(browser.spaces)
            browser.spaceID = other.id
            Spaces.current = other.id
            remote = Tab(later: Spaces.store(for: home.id))
            remote.restore(url: target, title: "Chat")
            current = Tab(later: Spaces.store(for: other.id))
            current.restore(url: URL(string: "https://current.space238.test/")!, title: "Current")
            browser.prepare(remote)
            browser.prepare(current)
            browser.lay([current])
            browser.activeID = current.id
            browser.parked[home.id] = Parked(tabs: [remote], active: remote.id)
            browser.history = History([])
        }

        func close() {
            if let previousRoute { LinkRoutes.shared.set(previousRoute.site, to: previousRoute.space) }
            else { LinkRoutes.shared.remove("chat.space238.test") }
            browser.letGo()
            Spaces.current = previousCurrent
            Store.settings.set(previousSpaces, forKey: "spaces")
            Store.settings.set(previousSuggestions, forKey: "search.suggest")
            if let previousList { try? previousList.write(to: Store.file("spaces.json")) }
            else { try? FileManager.default.removeItem(at: Store.file("spaces.json")) }
            _ = Spaces.read()
            for id in [home.id, other.id] {
                Spaces.sharing.remove(id)
                Spaces.pageCounts[id] = nil
                if let window = browser.windowID {
                    try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString)-\(id.uuidString).json"))
                }
            }
            if let window = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(window.uuidString).space")
            }
        }

        func ask(_ words: String, completing: Bool = false) {
            browser.openFresh()
            browser.replaceTyped(words, completing: completing)
        }
    }

    /// #865: exercise the composed popup delegate, including the kept-tab
    /// Peek branch that used to consume this link before consulting rules.
    @Test(arguments: [false, true])
    func keptPagesNewTabUsesItsDestinationRule(background: Bool) async throws {
        let w = World(isolated: true); defer { w.close() }
        LinkRoutes.shared.set("chat.space238.test", to: w.home.id)
        w.current.kept = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let source = Tab(configuration: configuration, factory: .webKitOnly)
        source.restore(url: URL(string: "about:blank#page-link")!, title: "Source")
        source.kept = true
        w.browser.prepare(source)
        w.browser.lay([source])
        w.browser.activeID = source.id
        let page = requireNativeWebKitFixture(source, "FieldSpaceURLTests")
        let action = PageAction(request: URLRequest(url: w.target), kind: .linkActivated,
            targetIsMainFrame: nil, source: nil, modifierFlags: [], buttonNumber: 0,
            shouldPerformDownload: false, userInitiated: true)
        let request = PagePopup(id: UUID(), action: action, width: nil, height: nil,
            toolbarsVisible: nil, menuForeground: background ? false : nil)
        var answers = 0
        w.browser.page(page as any PageHandle, open: request) { child in
            answers += 1
            #expect(child == nil)
        }
        for _ in 0..<50 where !background && w.browser.spaceID != w.home.id {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(answers == 1)
        #expect(w.browser.peeking == nil)
        #expect(source.address == URL(string: "about:blank#page-link"))
        if background {
            #expect(w.browser.spaceID == w.other.id)
            #expect(w.browser.parked[w.home.id]?.tabs.contains { $0.address == w.target } == true)
        } else {
            #expect(w.browser.spaceID == w.home.id)
            #expect(w.browser.tabs.contains { $0.address == w.target })
        }
    }

    /// #866: a configured destination applies to a new site explicitly
    /// requested with Cmd-T, before its WebView chooses its cookie store.
    @Test(arguments: [false, true])
    func configuredFullURLUsesDestinationSpace(isolated: Bool) {
        let w = World(isolated: isolated); defer { w.close() }
        // A newly requested site, rather than a result paired with an
        // existing remote tab, still follows its configured destination.
        w.remote.restore(url: URL(string: "https://unrelated.space238.test/")!, title: "Unrelated")
        LinkRoutes.shared.set("chat.space238.test", to: w.home.id)
        w.ask(w.target.absoluteString)
        w.browser.submit()
        #expect(w.browser.spaceID == w.home.id)
        #expect(w.browser.active?.address == w.target)
        #expect(w.browser.active !== w.remote, "Routing a new site is not selecting an existing tab")
        #expect(w.browser.active?.store === Spaces.store(for: w.home.id))
        #expect(w.browser.parked[w.other.id]?.tabs.contains { $0 === w.current } == true)
    }

    @Test(arguments: [false, true])
    func configuredSiteSuggestionUsesDestinationSpace(isolated: Bool) throws {
        let w = World(isolated: isolated); defer { w.close() }
        LinkRoutes.shared.set("chat.space238.test", to: w.home.id)
        w.ask("chat")
        w.browser.query.offers = [Suggestion(key: "Chat", title: "Chat", url: w.target, kind: .visited)]
        w.browser.picked = 0
        w.browser.submit()
        #expect(w.browser.spaceID == w.home.id)
        #expect(w.browser.active?.address == w.target)
        #expect(w.browser.active !== w.remote)
        #expect(w.browser.active?.store === Spaces.store(for: w.home.id))
    }

    @Test func configuredRuleDoesNotMoveSameTabNavigation() {
        let w = World(isolated: true); defer { w.close() }
        LinkRoutes.shared.set("chat.space238.test", to: w.home.id)
        w.browser.edit()
        w.browser.replaceTyped(w.target.absoluteString, completing: false)
        w.browser.submit()
        #expect(w.browser.spaceID == w.other.id)
        #expect(w.browser.active === w.current)
        #expect(w.current.address == w.target)
    }

    @Test func configuredRuleDoesNotOverrideExplicitExistingTab() throws {
        let w = World(isolated: true); defer { w.close() }
        // The rule points away from the existing tab. Choosing that tab
        // explicitly still selects it, rather than routing a new page.
        LinkRoutes.shared.set("chat.space238.test", to: w.other.id)
        w.ask(Address.pretty(w.target))
        w.browser.picked = try #require(w.browser.offers.firstIndex { $0.tab == w.remote.id })
        w.browser.submit()
        #expect(w.browser.spaceID == w.home.id)
        #expect(w.browser.active === w.remote)
    }

    @Test func configuredRuleDoesNotMovePrivateSite() {
        let w = World(isolated: true); defer { w.close() }
        LinkRoutes.shared.set("chat.space238.test", to: w.home.id)
        w.browser.open(URL(string: "https://private.space238.test/")!, foreground: true, shy: true)
        w.ask(w.target.absoluteString)
        w.browser.submit()
        #expect(w.browser.spaceID == w.other.id)
        #expect(w.browser.active?.address == w.target)
        #expect(w.browser.active?.shy == true)
    }

    @Test func configuredRuleDoesNotMoveSearchResult() {
        let w = World(isolated: true); defer { w.close() }
        LinkRoutes.shared.set("chat.space238.test", to: w.home.id)
        w.ask("chat")
        w.browser.query.offers = [Suggestion(key: "chat", title: "Search", url: w.target, kind: .search)]
        w.browser.picked = 0
        w.browser.submit()
        #expect(w.browser.spaceID == w.other.id)
        #expect(w.browser.active?.address == w.target)
    }

    @Test(arguments: [false, true])
    func typingAnotherSpacesURLStaysHere(isolated: Bool) throws {
        let w = World(isolated: isolated); defer { w.close() }
        w.ask(Address.pretty(w.target))
        #expect(w.browser.offers.contains { $0.tab == w.remote.id }, "Explicit Switch to Tab remains available")
        let lead = try #require(w.browser.query.lead)
        #expect(w.browser.offers[lead].tab == nil)
        w.browser.submit()
        #expect(w.browser.spaceID == w.other.id)
        #expect(w.browser.active?.address == w.target)
        #expect(w.browser.activeID != w.remote.id)
        #expect(w.browser.active?.store === Spaces.store(for: w.other.id))
        #expect(w.browser.parked[w.home.id]?.tabs.contains { $0 === w.remote } == true)
    }

    @Test(arguments: [false, true])
    func completingAnotherSpacesURLStaysHere(isolated: Bool) throws {
        let w = World(isolated: isolated); defer { w.close() }
        w.browser.history = History([Visit(url: w.target.absoluteString, key: Address.pretty(w.target).lowercased(),
                                          title: "Chat", count: 5, last: Date(), typed: 5)])
        w.ask("chat.space238.test/in", completing: true)
        #expect(w.browser.ending == "box")
        let lead = try #require(w.browser.query.lead)
        #expect(w.browser.offers[lead].url == w.target)
        #expect(w.browser.offers[lead].tab == nil)
        w.browser.submit()
        #expect(w.browser.spaceID == w.other.id)
        #expect(w.browser.active?.address == w.target)
        #expect(w.browser.activeID != w.remote.id)
    }

    @Test(arguments: [false, true])
    func deliberatelyChoosingAnotherSpacesTabStillSwitches(isolated: Bool) throws {
        let w = World(isolated: isolated); defer { w.close() }
        w.ask(Address.pretty(w.target))
        w.browser.picked = try #require(w.browser.offers.firstIndex { $0.tab == w.remote.id })
        w.browser.submit()
        #expect(w.browser.spaceID == w.home.id)
        #expect(w.browser.active === w.remote)
    }

    @Test(arguments: [false, true])
    func aTabInThisSpaceIsStillReused(includingSharedPin: Bool) throws {
        let w = World(isolated: false); defer { w.close() }
        let local = Tab(later: Spaces.store(for: w.other.id))
        local.restore(url: w.target, title: "Local chat")
        if includingSharedPin { local.pin = "C"; local.everywhere = UUID() }
        w.browser.prepare(local)
        w.browser.lay([w.current, local])
        w.ask(Address.pretty(w.target))
        let lead = try #require(w.browser.query.lead)
        #expect(w.browser.offers[lead].tab == local.id)
        w.browser.submit()
        #expect(w.browser.spaceID == w.other.id)
        #expect(w.browser.active === local)
    }

    @Test(arguments: [false, true], [false, true])
    func namedRemoteResultOffersCopyBeforeSwitch(isolated: Bool, pinned: Bool) throws {
        let w = World(isolated: isolated); defer { w.close() }
        if pinned { w.remote.pin = "C" }
        w.ask("chat")
        let rows = w.browser.offers
        let copy = try #require(rows.firstIndex { $0.url == w.target && $0.tab == nil })
        let jump = try #require(rows.firstIndex { $0.tab == w.remote.id })
        #expect(copy < jump)
        #expect(rows[copy].id != rows[jump].id)
        let merged = SearchSuggestions.merge([Suggestion(key: "chat online", title: "", url: nil, kind: .suggested)],
                                              into: rows, lead: w.browser.query.lead)
        let web = try #require(merged.list.firstIndex { $0.kind == .suggested })
        #expect(copy < web)
        #expect(jump < web)
        // Walking to the ordinary result opens here, regardless of which
        // search/agent row is Return's initial choice for ambiguous words.
        w.browser.picked = copy
        #expect(w.browser.fieldActions.first?.title == Browser.openWords(.tab))
        w.browser.submit()
        #expect(w.browser.spaceID == w.other.id)
        #expect(w.browser.active?.address == w.target)
        #expect(w.browser.active !== w.remote)
        #expect(w.browser.active?.store === Spaces.store(for: w.other.id))
    }

    @Test(arguments: [false, true])
    func remoteHostPrefixDefaultsToHere(isolated: Bool) throws {
        let w = World(isolated: isolated); defer { w.close() }
        let target = URL(string: "https://quasar238.test/inbox")!
        w.remote.restore(url: target, title: "Quasar Library")
        w.ask("quasar")
        let lead = try #require(w.browser.query.lead)
        #expect(w.browser.offers[lead].url == target)
        #expect(w.browser.offers[lead].tab == nil)
        w.browser.submit()
        #expect(w.browser.spaceID == w.other.id)
        #expect(w.browser.active?.address == target)
    }

    @Test func remoteTitleDefaultOpensHere() throws {
        let w = World(isolated: true); defer { w.close() }
        w.remote.name = "Quasar Library"
        w.ask("quasar")
        let lead = try #require(w.browser.query.lead)
        #expect(w.browser.offers[lead].url == w.target)
        #expect(w.browser.offers[lead].tab == nil)
        w.browser.submit()
        #expect(w.browser.spaceID == w.other.id)
        #expect(w.browser.active?.address == w.target)
    }

    @Test(arguments: [false, true])
    func remoteCopyStaysHereDespiteSiteRule(isolated: Bool) throws {
        let w = World(isolated: isolated); defer { w.close() }
        LinkRoutes.shared.set("chat.space238.test", to: w.home.id)
        w.ask(Address.pretty(w.target))
        let lead = try #require(w.browser.query.lead)
        #expect(w.browser.offers[lead].url == w.target)
        #expect(w.browser.offers[lead].tab == nil)
        w.browser.submit()
        #expect(w.browser.spaceID == w.other.id)
        #expect(w.browser.active?.address == w.target)
        #expect(w.browser.active?.store === Spaces.store(for: w.other.id))
    }

    @Test func arrowsReachExplicitRemoteJump() throws {
        let w = World(isolated: true); defer { w.close() }
        w.ask("chat")
        let jump = try #require(w.browser.offers.firstIndex { $0.tab == w.remote.id })
        for _ in w.browser.offers.indices where w.browser.query.current != jump { w.browser.walk(1) }
        #expect(w.browser.query.current == jump)
        w.browser.submit()
        #expect(w.browser.spaceID == w.home.id)
        #expect(w.browser.active === w.remote)
    }

    @Test(arguments: [false, true])
    func remoteCopiesFollowTabMatchSetting(tabs: Bool) {
        let w = World(isolated: false); defer { w.close() }
        let under = FieldUnder.shared
        let previousTabs = under.tabs, previousPages = under.pages
        defer { under.tabs = previousTabs; under.pages = previousPages }
        under.tabs = tabs
        under.pages = false
        w.remote.name = "Remote library"
        w.ask("library")
        let rows = w.browser.offers.filter { $0.url == w.target }
        #expect(rows.count == (tabs ? 2 : 0))
    }

    @Test func remoteAddressLabelHasDistinctCopyAndJumpIdentities() throws {
        let w = World(isolated: true); defer { w.close() }
        w.remote.name = History.key(for: w.target)
        w.ask("chat")
        let rows = w.browser.offers.filter { $0.url == w.target }
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.id)).count == 2)
        w.browser.picked = try #require(w.browser.offers.firstIndex { $0.tab == w.remote.id })
        w.browser.guessAgain()
        let selected = try #require(w.browser.query.current)
        #expect(w.browser.offers[selected].tab == w.remote.id)
    }

    /// #260a: the open tabs of the Space on screen come first. Three fresher
    /// tabs in another Space never push this Space's tab out of the list.
    private func boards(_ w: World) -> (design: Tab, work: [Tab]) {
        let design = Tab(later: Spaces.store(for: w.other.id))
        design.restore(url: URL(string: "https://board.space260.test/design")!, title: "Board design")
        design.touch(at: Date().addingTimeInterval(-3600))
        w.browser.prepare(design)
        w.browser.lay([w.current, design])
        var work: [Tab] = []
        for n in 1...3 {
            let tab = Tab(later: Spaces.store(for: w.home.id))
            tab.restore(url: URL(string: "https://board.space260.test/work\(n)")!, title: "Board work \(n)")
            tab.touch(at: Date().addingTimeInterval(Double(-n)))
            w.browser.prepare(tab)
            work.append(tab)
        }
        w.browser.parked[w.home.id] = Parked(tabs: [w.remote] + work, active: w.remote.id)
        return (design, work)
    }

    @Test func threeFreshWorkTabsDontPushOutTheDesignTab() {
        let w = World(isolated: false); defer { w.close() }
        let (design, work) = boards(w)
        let rows = w.browser.openPages(matching: "board")
        #expect(rows.map(\.tab) == [design.id] + work.map(\.id))
        #expect(rows.first?.space == nil)
        #expect(rows.dropFirst().allSatisfy { $0.space == w.home.id })
    }

    @Test func thisSpacesTabsThenOtherSpacesThenHistory() throws {
        let w = World(isolated: false); defer { w.close() }
        let (design, work) = boards(w)
        let visited = URL(string: "https://board.space260.test/history")!
        w.browser.history = History([Visit(url: visited.absoluteString, key: Address.pretty(visited).lowercased(),
                                           title: "Board history", count: 5, last: Date(), typed: 5)])
        w.ask("board")
        let offers = w.browser.offers
        let here = try #require(offers.firstIndex { $0.tab == design.id })
        let place = try #require(offers.firstIndex { $0.url == visited && $0.tab == nil })
        let elsewhere = try #require(offers.firstIndex { $0.tab == work[0].id })
        #expect(here < place)
        #expect(elsewhere < place)
        let suggestions = [Suggestion(key: "board games", title: "", url: nil, kind: .suggested)]
        let merged = SearchSuggestions.merge(suggestions, into: offers, lead: w.browser.query.lead)
        let web = try #require(merged.list.firstIndex { $0.kind == .suggested })
        for tab in [design] + work {
            let at = try #require(merged.list.firstIndex { $0.tab == tab.id })
            #expect(at < web)
            let history = try #require(merged.list.firstIndex { $0.url == visited && $0.tab == nil })
            #expect(at < history)
        }
        // Return never leads to another Space's tab.
        let workIDs = Set(work.map(\.id))
        if let lead = w.browser.query.lead, let tab = offers[lead].tab {
            #expect(!workIDs.contains(tab))
        }
    }
}
