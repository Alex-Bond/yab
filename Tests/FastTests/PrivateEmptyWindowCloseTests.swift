import AppKit
import Testing
@testable import Fast

/// Composed Close Tab dispatch to the registered window. The spy records
/// a close request without closing native UI; focused-key acceptance is
/// retained separately in the QA card and golden path.
@MainActor @Suite(.serialized)
struct PrivateEmptyWindowCloseTests {
    @MainActor private final class CloseWindow: NSWindow {
        var closeRequests = 0

        override func performClose(_ sender: Any?) {
            closeRequests += 1
        }
    }

    @MainActor private final class Fixture {
        let id: UUID
        let browser: Browser
        let window: CloseWindow
        private let previousSharing: Set<UUID>
        private weak var previousFoldersBrowser: Browser?

        init(_ purpose: BrowserWindowPurpose) throws {
            try #require(Store.testing && Store.unitTests && Store.settings !== UserDefaults.standard)
            _ = NSApplication.shared
            previousSharing = Spaces.sharing
            previousFoldersBrowser = Folders.shared.browser
            let windowID = UUID()
            id = windowID
            browser = Browser(windowID: windowID, purpose: purpose)
            window = CloseWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 600),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            BrowserWindows.shared.register(window, for: browser)
        }

        func page() -> Tab {
            let tab = Tab(shy: browser.windowPurpose == .privateOnly)
            tab.restore(url: URL(string: "https://private-close.invalid/owned")!, title: "Owned page")
            browser.prepare(tab)
            browser.lay([tab])
            browser.activeID = tab.id
            return tab
        }

        func close() {
            // close(), unlike the spied performClose(), emits registry
            // teardown for this fixture's registered window.
            window.close()
            browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            if Folders.shared.browser === browser { Folders.shared.browser = previousFoldersBrowser }
            Spaces.sharing = previousSharing
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            for suffix in Set([""] + browser.spaces.map({ "-" + $0.id.uuidString })) {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString)\(suffix).json"))
            }
            try? FileManager.default.removeItem(at: Store.file("spaces-window-\(id.uuidString).json"))
        }
    }

    @Test func aFreshEmptyPrivateWindowRequestsOnlyItsOwnClose() throws {
        let target = try Fixture(.privateOnly); defer { target.close() }
        let other = try Fixture(.privateOnly); defer { other.close() }
        try #require(target.browser.tabs.isEmpty && target.browser.activeID == nil)
        try #require(BrowserWindows.shared.window(for: target.browser) === target.window)
        let focus = target.browser.query.focusRequest

        target.browser.shut(target.browser.chosen, byKey: true)

        #expect(target.window.closeRequests == 1)
        #expect(other.window.closeRequests == 0)
        #expect(target.browser.query.focusRequest == focus, "Close must not reopen the private field")
        #expect(target.browser.tabs.isEmpty && target.browser.ghosts.isEmpty)
    }

    @Test(arguments: [BrowserWindowPurpose.normal, .privateOnly], [false, true])
    func anEmptyWindowClosesWithItsFieldShownOrHidden(_ purpose: BrowserWindowPurpose, hidden: Bool) throws {
        let target = try Fixture(purpose); defer { target.close() }
        let other = try Fixture(purpose); defer { other.close() }
        target.browser.lay([])
        target.browser.activeID = nil
        target.browser.askNew()
        if hidden { target.browser.dismiss() }
        #expect(target.browser.fieldShowing == !hidden)
        target.browser.typed = "unfinished search"
        let focus = target.browser.query.focusRequest

        target.browser.shut(target.browser.chosen, byKey: true)

        #expect(target.window.closeRequests == 1)
        #expect(other.window.closeRequests == 0)
        #expect(target.browser.query.focusRequest == focus)
        #expect(target.browser.tabs.isEmpty && target.browser.ghosts.isEmpty)
    }

    @Test(arguments: [BrowserWindowPurpose.normal, .privateOnly])
    func anEmptyWindowFieldTogglesAndEscapeDismissesIt(_ purpose: BrowserWindowPurpose) throws {
        let target = try Fixture(purpose); defer { target.close() }
        let browser = target.browser
        browser.lay([])
        browser.activeID = nil
        browser.askNew()
        #expect(browser.fieldShowing)
        browser.pressNewTab()
        #expect(!browser.fieldShowing)
        // An unchanged empty column arriving through sync must not reopen it.
        browser.lay([])
        #expect(!browser.fieldShowing && browser.fieldPutAway)
        browser.edit()
        #expect(browser.fieldShowing && !browser.fieldPutAway)
        browser.dismiss()
        #expect(!browser.fieldShowing)
        browser.pressNewTab()
        #expect(browser.fieldShowing && browser.typed.isEmpty)
        browser.typed = "unfinished search"
        browser.pressNewTab()
        #expect(!browser.fieldShowing && browser.typed.isEmpty)
        browser.pressNewTab()
        #expect(browser.fieldShowing && browser.typed.isEmpty)
        browser.dismiss()
        #expect(!browser.fieldShowing)
        browser.newTab()
        #expect(browser.fieldShowing && browser.typed.isEmpty)
        #expect(browser.tabs.isEmpty && browser.active == nil)
        #expect(target.window.closeRequests == 0)
    }

    @Test(arguments: ["empty", "kept", "pin", "mixed"], [false, true])
    func newWindowEscapeCloseDoesNotReopenTheField(_ column: String, typed: Bool) throws {
        let target = try Fixture(.normal); defer { target.close() }
        let other = try Fixture(.normal); defer { other.close() }
        let control = other.page()
        let browser = target.browser
        let retained: [Tab] = (column == "mixed" ? ["pin", "kept"] : column == "empty" ? [] : [column]).map { kind in
            let tab = Tab()
            tab.restore(url: URL(string: "https://empty-close.invalid/\(kind)")!, title: kind)
            tab.kept = kind == "kept"
            if kind == "pin" { tab.pin = "P" }
            browser.prepare(tab)
            return tab
        }
        other.browser.newWindow { source in
            #expect(source === other.browser)
            // A new window has the Space's retained rows, none in front.
            browser.lay(retained)
            browser.activeID = nil
            browser.askNew()
        }
        try #require(browser.fieldShowing && browser.active == nil && browser.under == nil)
        if typed { browser.typed = "unfinished search" }
        browser.dismiss()
        try #require(!browser.fieldShowing && browser.fieldPutAway && browser.typed.isEmpty)
        let focus = browser.query.focusRequest

        browser.shut(browser.chosen, byKey: true)

        #expect(target.window.closeRequests == 1 && other.window.closeRequests == 0)
        #expect(!browser.fieldShowing && browser.query.focusRequest == focus)
        #expect(browser.tabs.map(\.id) == retained.map(\.id) && retained.allSatisfy { !$0.gone })
        #expect(browser.ghosts.isEmpty)
        #expect(other.browser.active === control && !control.gone)
    }

    @Test(arguments: [false, true], [false, true])
    func closeCommandClosesGroundWithRetainedRows(hidden: Bool, typed: Bool) throws {
        let target = try Fixture(.normal); defer { target.close() }
        let pin = target.page()
        pin.pin = "P"
        target.browser.activeID = nil
        target.browser.askNew()
        if hidden { target.browser.dismiss() }
        if typed { target.browser.typed = "unfinished search" }
        let focus = target.browser.query.focusRequest

        #expect(Command.closeTab.available(in: target.browser))
        Command.closeTab.run(in: target.browser)

        #expect(target.window.closeRequests == 1)
        #expect(target.browser.query.focusRequest == focus)
        #expect(target.browser.tabs.first === pin && !pin.gone)
    }

    @Test func aRetainedRowDoesNotMakeABackgroundPageOrGuestAnEmptyWindow() throws {
        let target = try Fixture(.normal); defer { target.close() }
        let browser = target.browser
        let page = target.page()
        let pin = Tab()
        pin.restore(url: URL(string: "https://empty-close.invalid/pin")!, title: "Pin")
        pin.pin = "P"
        browser.prepare(pin)
        browser.lay([pin, page])
        browser.activeID = nil
        #expect(!Command.closeTab.available(in: browser))
        browser.shut([], byKey: true)
        #expect(target.window.closeRequests == 0 && !page.gone)
        browser.lay([pin])
        browser.under = .space(page, from: browser.spaceID)
        #expect(!Command.closeTab.available(in: browser))
        browser.shut([], byKey: true)
        #expect(target.window.closeRequests == 0 && browser.underTab === page)
        browser.settleUnder()
        browser.fieldGuest = page
        #expect(!Command.closeTab.available(in: browser))
        browser.fieldGuest = nil
    }

    @Test(arguments: [BrowserWindowPurpose.normal, .privateOnly])
    func aBackgroundPageKeepsItsWindowWhenNoTabIsSelected(_ purpose: BrowserWindowPurpose) throws {
        let target = try Fixture(purpose); defer { target.close() }
        let page = target.page()
        target.browser.activeID = nil
        let focus = target.browser.query.focusRequest
        try #require(target.browser.chosen.isEmpty)

        target.browser.shut(target.browser.chosen, byKey: true)

        #expect(target.window.closeRequests == 0)
        #expect(target.browser.tabs.count == 1 && target.browser.tabs.first === page && !page.gone)
        #expect(target.browser.query.focusRequest > focus)
    }

    @Test(arguments: [BrowserWindowPurpose.normal, .privateOnly])
    func aWindowWithAPageKeepsItsExistingFieldToggle(_ purpose: BrowserWindowPurpose) throws {
        let target = try Fixture(purpose); defer { target.close() }
        let page = target.page()
        target.browser.pressNewTab()
        #expect(target.browser.fieldShowing && target.browser.asked == .tab)
        target.browser.pressNewTab()
        #expect(!target.browser.fieldShowing && target.browser.active === page)
        target.browser.pressNewTab()
        target.browser.dismiss()
        #expect(!target.browser.fieldShowing && target.browser.active === page)
        #expect(target.browser.tabs.count == 1 && target.window.closeRequests == 0)
    }

    /// Feedback #1163: each press closes one page; only the next press on
    /// the empty window closes that window. The other window stays intact.
    @Test(arguments: [BrowserWindowPurpose.normal, .privateOnly])
    func repeatedCloseWalksThePagesThenClosesTheEmptyWindow(_ purpose: BrowserWindowPurpose) throws {
        let target = try Fixture(purpose); defer { target.close() }
        let other = try Fixture(purpose); defer { other.close() }
        let control = other.page()
        let browser = target.browser
        let pages = (0..<3).map { index in
            let page = Tab(shy: purpose == .privateOnly)
            page.restore(url: URL(string: "https://close-sequence.invalid/\(index)")!, title: "Page \(index)")
            browser.prepare(page)
            return page
        }
        browser.lay(pages)
        browser.activeID = pages.last?.id
        browser.pressNewTab()
        for remaining in stride(from: 2, through: 0, by: -1) {
            let closing = try #require(browser.active)
            browser.shut(browser.chosen, byKey: true)
            #expect(closing.gone && browser.tabs.count == remaining)
            #expect(target.window.closeRequests == 0 && other.window.closeRequests == 0)
            #expect(other.browser.active === control && !control.gone)
            #expect(remaining == 0 ? browser.active == nil : browser.active != nil)
        }
        #expect(browser.fieldShowing)
        #expect(browser.ghosts.count == (purpose == .normal ? 3 : 0))
        browser.shut(browser.chosen, byKey: true)
        #expect(target.window.closeRequests == 1 && other.window.closeRequests == 0)
    }

    @Test func repeatedCloseRetainsPinnedRowsThenClosesTheGroundWindow() throws {
        let target = try Fixture(.normal); defer { target.close() }
        let browser = target.browser
        let pin = target.page()
        pin.pin = "P"
        browser.shut(browser.chosen, byKey: true)
        #expect(browser.active == nil && !pin.gone && browser.tabs.first === pin)
        let pages = (0..<3).map { index in
            let page = Tab()
            page.restore(url: URL(string: "https://close-sequence.invalid/\(index)")!, title: "Page \(index)")
            browser.prepare(page)
            return page
        }
        browser.lay([pin] + pages)
        browser.activeID = pages.last?.id
        for remaining in stride(from: 2, through: 0, by: -1) {
            browser.shut(browser.chosen, byKey: true)
            #expect(browser.tabs.count == remaining + 1 && browser.tabs.contains { $0 === pin })
            #expect(!pin.gone && pin.pin == "P" && target.window.closeRequests == 0)
        }
        #expect(browser.active == nil)
        browser.shut(browser.chosen, byKey: true)
        #expect(browser.tabs.count == 1 && browser.tabs.first === pin && !pin.gone)
        #expect(target.window.closeRequests == 1 && browser.fieldShowing)
    }

    @Test func closingAPrivatePageStillClosesOnlyThatPage() throws {
        let target = try Fixture(.privateOnly); defer { target.close() }
        let other = try Fixture(.privateOnly); defer { other.close() }
        let page = target.page()
        try #require(page.built == nil && page.shy)

        target.browser.shut(target.browser.chosen, byKey: true)

        #expect(page.gone && target.browser.tabs.isEmpty && target.browser.activeID == nil)
        #expect(target.window.closeRequests == 0 && other.window.closeRequests == 0)
        #expect(target.browser.fieldShowing && target.browser.ghosts.isEmpty)
    }

    /// The regular field and Actions must expose the same empty-window routes
    /// as the menu. History completion and web suggestions may not bury them.
    @Test(arguments: [BrowserWindowPurpose.normal, .privateOnly], [false, true])
    func emptyWindowCommandsLeadComposedOffersAndRemainInActions(_ purpose: BrowserWindowPurpose, retained: Bool) throws {
        let target = try Fixture(purpose); defer { target.close() }
        let browser = target.browser
        if retained {
            let pin = target.page()
            pin.pin = "P"
            browser.activeID = nil
        }
        let menu = browser.prefs.menuCommands, suggest = browser.prefs.searchSuggest
        let requests = browser.prefs.fieldRequests, commands = FieldUnder.shared.commands
        let pages = FieldUnder.shared.pages, rows = FieldUnder.shared.rows
        let savedKeys = Store.settings.object(forKey: "shortcuts")
        let systemKeys = Hotkeys.userKeys()
        defer {
            browser.prefs.menuCommands = menu; browser.prefs.searchSuggest = suggest
            browser.prefs.fieldRequests = requests; FieldUnder.shared.commands = commands
            FieldUnder.shared.pages = pages; FieldUnder.shared.rows = rows
            if let savedKeys { Store.settings.set(savedKeys, forKey: "shortcuts") }
            else { Store.settings.removeObject(forKey: "shortcuts") }
            Keymap.shared.adoptStored(); Keymap.shared.take(system: systemKeys)
        }
        browser.prefs.menuCommands = true; browser.prefs.searchSuggest = false
        browser.prefs.fieldRequests = false; FieldUnder.shared.commands = true
        FieldUnder.shared.pages = true; FieldUnder.shared.rows = [FieldUnder.search]
        Keymap.shared.take(system: [:])
        Keymap.shared.set(Hotkey("t", [.control, .option, .command]), for: .newTab)
        Keymap.shared.set(Hotkey("w", [.control, .option, .command]), for: .closeTab)
        for (command, alias) in [(Command.newTab, "newtab"), (.closeTab, "closetab")] {
            if retained && command == .newTab { continue }
            let url = URL(string: "https://\(alias).example.test/")!
            browser.history = History([Visit(url: url.absoluteString, key: Address.pretty(url),
                                             title: command.title, count: 200, last: Date(), typed: 100)])
            let found = browser.history.suggestions(for: alias, limit: 5)
            #expect(browser.history.completion(for: alias, among: found) != nil,
                    "This fixture must offer a real history completion before command ranking")
            for hidden in [false, true] {
                browser.askNew()
                if hidden { browser.dismiss() }
                #expect(command.available(in: browser))
                for words in [command.title, alias] {
                    browser.query.actionsPage = false
                    browser.replaceTyped(words)
                    #expect(browser.ending == nil)
                    let offers = browser.offers
                    #expect(offers.first?.kind == .command(command))
                    #expect(offers.contains { $0.url == url })
                    let lead = try #require(browser.query.lead)
                    if command == .closeTab {
                        #expect(offers[lead].kind != .command(.closeTab), "Ranking must never make Close Tab the default Return action")
                    }
                    let suggestions = (1...4).map {
                        Suggestion(key: words + " web \($0)", title: "", url: nil, kind: .suggested)
                    }
                    let merged = SearchSuggestions.merge(suggestions, into: offers, lead: lead)
                    #expect(merged.list.first?.kind == .command(command))
                    #expect(merged.list.contains { $0.kind == .suggested })
                    #expect(merged.lead.map { merged.list[$0].id } == offers[lead].id)
                    #expect(offers.first?.title == command.keys)
                    browser.query.actionsPage = true
                    browser.replaceTyped(words)
                    #expect(browser.offers.contains { $0.kind == .command(command) })
                }
            }
        }
        browser.query.actionsPage = false
        // A small window's field must not close or toggle its owning browser.
        browser.fieldGuest = Tab(bench: true)
        #expect(!Command.closeTab.available(in: browser) && !Command.newTab.available(in: browser))
        browser.fieldGuest = nil
    }

    @Test(arguments: [BrowserWindowPurpose.normal, .privateOnly])
    func emptyWindowCommandsExecuteTheMenuRoutes(_ purpose: BrowserWindowPurpose) throws {
        let target = try Fixture(purpose); defer { target.close() }
        let other = try Fixture(purpose); defer { other.close() }
        let browser = target.browser
        browser.askNew()
        Command.newTab.run(in: browser)
        #expect(!browser.fieldShowing && browser.tabs.isEmpty)
        Command.newTab.run(in: browser)
        #expect(browser.fieldShowing && browser.tabs.isEmpty)
        browser.typed = "unfinished search"
        browser.take(Suggestion(key: "Close Tab", title: "", url: nil, kind: .command(.closeTab)))
        #expect(target.window.closeRequests == 1 && other.window.closeRequests == 0)
        #expect(browser.tabs.isEmpty && browser.ghosts.isEmpty)
        // A retained background page keeps the existing contextual exclusion.
        let page = target.page()
        browser.activeID = nil
        #expect(!Command.closeTab.available(in: browser))
        Command.closeTab.run(in: browser)
        #expect(!page.gone && target.window.closeRequests == 1)
    }


    /// Only the new window-closing route requires deliberate row selection;
    /// a page keeps the field's existing explicit-title Return contract.
    @Test(arguments: [BrowserWindowPurpose.normal, .privateOnly])
    func closeTabWithAPageRetainsItsExplicitTitleReturnPolicy(_ purpose: BrowserWindowPurpose) throws {
        let target = try Fixture(purpose); defer { target.close() }
        let browser = target.browser
        let page = target.page()
        let menu = browser.prefs.menuCommands, suggest = browser.prefs.searchSuggest
        let requests = browser.prefs.fieldRequests, commands = FieldUnder.shared.commands
        let rows = FieldUnder.shared.rows
        defer {
            browser.prefs.menuCommands = menu; browser.prefs.searchSuggest = suggest
            browser.prefs.fieldRequests = requests; FieldUnder.shared.commands = commands
            FieldUnder.shared.rows = rows
        }
        browser.prefs.menuCommands = true; browser.prefs.searchSuggest = false
        browser.prefs.fieldRequests = false; FieldUnder.shared.commands = true
        FieldUnder.shared.rows = [FieldUnder.search]
        browser.history = History([])
        browser.edit()
        browser.replaceTyped("Close Tab")
        #expect(browser.offers.first?.kind == .command(.closeTab))
        let lead = try #require(browser.query.lead)
        #expect(browser.offers[lead].kind == .command(.closeTab))
        let suggestions = [Suggestion(key: "close tab web", title: "", url: nil, kind: .suggested)]
        let merged = SearchSuggestions.merge(suggestions, into: browser.offers, lead: lead)
        #expect(merged.lead.map { merged.list[$0].kind } == .command(.closeTab))
        browser.take(browser.offers[lead])
        #expect(page.gone && browser.tabs.isEmpty && target.window.closeRequests == 0)
        browser.replaceTyped("Close Tab")
        #expect(browser.offers.first?.kind == .command(.closeTab))
        let emptyLead = try #require(browser.query.lead)
        #expect(browser.offers[emptyLead].kind != .command(.closeTab))
        // Selecting the promoted row deliberately still invokes the window route.
        let close = try #require(browser.offers.first { $0.kind == .command(.closeTab) })
        browser.take(close)
        #expect(target.window.closeRequests == 1)
    }

}
