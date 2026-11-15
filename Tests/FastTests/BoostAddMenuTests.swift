import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct BoostAddMenuTests {
    private func world(_ check: (Browser, Tab) throws -> Void) rethrows {
        _ = NSApplication.shared
        let connected = Agents.connectedInTests
        let ready = Agents.assumedInTests
        let browser = Browser(windowID: UUID())
        let tab = Tab(bench: true)
        tab.restore(url: URL(string: "https://example.test/article")!, title: "Example")
        browser.lay([tab])
        browser.activeID = tab.id
        defer {
            Agents.connectedInTests = connected
            Agents.assumedInTests = ready
            browser.letGo()
        }
        try check(browser, tab)
    }

    @Test func disconnectedAIIsAbsentEvenFromSearch() throws {
        try world { browser, tab in
            Agents.connectedInTests = false
            // A CLI installed/signed in outside Yab is not a connection.
            Agents.assumedInTests = true
            let menu = BoostAddMenu.make(browser: browser, tab: tab)
            let list = ActionMenuList(menu: menu, falls: true)
            #expect(list.searchVisible)
            #expect(list.lines.map(\.title) == ["Customize…", "Boost Store…", "Userscript from File…"])
            #expect(list.lines.allSatisfy { $0.enabled && $0.image != nil })
            list.query = "AI"
            #expect(list.lines.isEmpty)
            list.query = "file"
            #expect(list.lines.map(\.title) == ["Userscript from File…"])
        }
    }

    @Test func connectedAIAppearsOnTheNextOpenAndSearchFindsIt() throws {
        try world { browser, tab in
            Agents.connectedInTests = false
            #expect(ActionMenuList(menu: BoostAddMenu.make(browser: browser, tab: tab), falls: true).lines.count == 3)
            Agents.connectedInTests = true
            let list = ActionMenuList(menu: BoostAddMenu.make(browser: browser, tab: tab), falls: true)
            #expect(list.lines.map(\.title) == ["Customize…", "Create with AI…", "Boost Store…", "Userscript from File…"])
            list.query = "AI"
            #expect(list.lines.map(\.title) == ["Create with AI…"])
            Agents.connectedInTests = false
            let reopened = ActionMenuList(menu: BoostAddMenu.make(browser: browser, tab: tab), falls: true)
            #expect(reopened.lines.map(\.title) == ["Customize…", "Boost Store…", "Userscript from File…"])
        }
    }

    @Test func storeWorksWithoutAI() throws {
        try world { browser, tab in
            Agents.connectedInTests = false
            let menu = BoostAddMenu.make(browser: browser, tab: tab)
            let index = try #require(menu.items.firstIndex { $0.title == "Boost Store…" })
            menu.performActionForItem(at: index)
            #expect(browser.fieldShowing)
            #expect(browser.query.place == .store)
        }
    }

    @Test func createWithAIUsesThePanelsTabAndRechecksConnection() throws {
        try world { browser, tab in
            Agents.connectedInTests = true
            Agents.assumedInTests = true
            let menu = BoostAddMenu.make(browser: browser, tab: tab)
            let index = try #require(menu.items.firstIndex { $0.title == "Create with AI…" })
            Agents.connectedInTests = false
            menu.performActionForItem(at: index)
            #expect(browser.chatAttach.words(for: browser.chatID).isEmpty)
            Agents.connectedInTests = true
            menu.performActionForItem(at: index)
            // The words are the new chat's own draft (#1238), shown by its field.
            #expect(browser.chatAttach.words(for: browser.chatID) == "Create a boost for example.test: ")
        }
    }
}
