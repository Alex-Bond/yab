import Foundation
import Testing
@testable import Fast

// What the field finds of the app's own commands by the words typed, and
// which of them Return may take over a search.
@Suite(.serialized)
struct CommandTests {
    /// The command the words name best, as the field ranks them.
    static func best(_ words: String) -> Command? {
        Command.allCases.compactMap { command in command.score(words).map { (command, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    @Test func feedbackIsFoundByItsNamesAndByWhatItIsFor() {
        #expect(Self.best("send feed") == .feedback)
        #expect(Self.best("feedback") == .feedback)
        #expect(Command.feedback.score("bug report") != nil)
        #expect(Command.feedback.score("bug") != nil)
    }

    @Test func feedbackNamedOutrightOpensOnReturn() {
        #expect(Command.feedback.opens)
        #expect(Command.feedback.score("feedb")! >= 2)
    }

    /// A word that only points at feedback lists it, and Return still searches.
    @Test func aBugIsStillASearch() {
        #expect(Command.feedback.score("bug")! < 2)
        #expect(Command.feedback.score("idea")! < 2)
        #expect(Command.feedback.score("report")! < 2)
    }

    /// Asked for in so many words, it leads the list and Return opens it.
    @Test func reportBugNamesFeedback() {
        #expect(Command.feedback.score("report bug")! >= 2)
        #expect(Command.feedback.score("report b")! >= 2)
        #expect(Command.feedback.score("Bug Report")! >= 2)
        #expect(Self.best("report a bug") == .feedback)
    }

    @Test func theMenusCommandsAreThere() {
        #expect(Self.best("reload") == .reload)
        #expect(Self.best("hard refresh") == .hardReload)
        #expect(Self.best("clear cookies") == .clearCookies)
        #expect(Self.best("zoom in") == .zoomIn)
        #expect(Self.best("devtools") != nil)
        #expect(Self.best("check for up") == .checkUpdates)
        #expect(Self.best("default browser") == .makeDefault)
        #expect(Self.best("close other") == .closeOthers)
        #expect(Self.best("new folder with") == .folderWithTabs)
    }

    /// What someone from Arc types for a boost finds one (register #447).
    @Test func boostsAreFoundByArcsWords() {
        #expect(Self.best("new boost") == .newBoost)
        #expect(Self.best("create boost") == .newBoost)
        #expect(Self.best("arc boosts") == .arcBoosts)
        #expect(Command.newBoost.score("boost") != nil)
        #expect(Command.boostStore.score("boost") != nil)
    }

    /// "check", "welcome" or "extension" and Return is a search: what
    /// the field lists of these, it lists under the places.
    @Test func newCommandsNeverTakeReturn() {
        for command in [Command.checkUpdates, .restartUpdate, .makeDefault, .welcome, .extensions, .reload, .closeOthers, .closeBefore, .closeAfter, .pinTab, .folderWithTabs] {
            #expect(!command.opens)
        }
    }

    @Test func sideClosingIsFoundInEitherLayout() {
        for words in ["close tabs to the left", "close tabs above", "close before", "close left", "close above"] {
            #expect(Self.best(words) == .closeBefore)
        }
        for words in ["close tabs to the right", "close tabs below", "close after", "close right", "close below"] {
            #expect(Self.best(words) == .closeAfter)
        }
    }

    @MainActor private func withTabs(_ count: Int, _ body: (Browser, [Tab]) throws -> Void) rethrows {
        let window = UUID(), browser = Browser(windowID: window)
        let tabs = (0..<count).map { index in
            let tab = Tab()
            tab.restore(url: URL(string: "https://side-close.test/\(index)")!, title: "Tab \(index)")
            browser.prepare(tab)
            return tab
        }
        browser.lay(tabs)
        defer {
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
        }
        try body(browser, tabs)
    }

    @MainActor @Test func closesOnlyTheRequestedSideAndLeavesTheOpenPage() {
        withTabs(5) { browser, tabs in
            browser.activeID = tabs[2].id
            browser.closeBefore()
            #expect(browser.tabs.map(\.id) == Array(tabs[2...].map(\.id)))
            #expect(browser.active === tabs[2])
            #expect(browser.ghosts.map(\.url) == tabs[..<2].compactMap(\.address))
            browser.closeAfter()
            #expect(browser.tabs.map(\.id) == [tabs[2].id])
            #expect(browser.active === tabs[2])
            #expect(!Command.closeBefore.available(in: browser))
            #expect(!Command.closeAfter.available(in: browser))
        }
    }

    @MainActor @Test func pinsKeptPlacesAndSealedAgentWorkStayInPlace() {
        withTabs(6) { browser, tabs in
            let agent = Agents.shared.attach(name: "Side close test")
            agent.sealed = true
            defer { agent.sealed = false; Agents.shared.detach(agent.id) }
            tabs[0].pin = "P"
            tabs[1].kept = true
            tabs[4].agent = agent.id
            browser.activeID = tabs[3].id
            #expect(browser.sideCloseTargets([tabs[3]], before: true).map(\.id) == [tabs[2].id])
            #expect(browser.sideCloseTargets([tabs[3]], before: false).map(\.id) == [tabs[5].id])
            browser.closeBefore()
            browser.closeAfter()
            #expect(browser.tabs.map(\.id) == [tabs[0].id, tabs[1].id, tabs[3].id, tabs[4].id])
            #expect(tabs[0].pending != nil && tabs[1].pending != nil)
            #expect(browser.sideCloseTargets([tabs[0]], before: false).isEmpty)
            #expect(browser.sideCloseTargets([tabs[1]], before: false).isEmpty)
            #expect(browser.sideCloseTargets([tabs[4]], before: false).isEmpty)
            #expect(browser.active === tabs[3])
        }
    }

    @MainActor @Test func theSelectedSplitPartnerStaysOnEitherSide() {
        withTabs(5) { browser, tabs in
            browser.activeID = tabs[2].id
            browser.pairs = [Pair(first: tabs[1].id, second: tabs[2].id)]
            browser.closeBefore()
            #expect(browser.tabs.map(\.id) == Array(tabs[1...].map(\.id)))
            #expect(browser.partner(of: tabs[2]) === tabs[1])
            browser.pairs = [Pair(first: tabs[2].id, second: tabs[3].id)]
            browser.closeAfter()
            #expect(browser.tabs.map(\.id) == [tabs[1].id, tabs[2].id, tabs[3].id])
            #expect(browser.partner(of: tabs[2]) === tabs[3])
            #expect(browser.active === tabs[2])
        }
    }

    @MainActor @Test func severalPickedTabsUseTheirFirstAndLastPositions() {
        withTabs(7) { browser, tabs in
            browser.activeID = tabs[2].id
            browser.extend(to: tabs[4])
            #expect(browser.chosen.map(\.id) == Array(tabs[2...4].map(\.id)))
            browser.closeBefore()
            #expect(browser.tabs.map(\.id) == Array(tabs[2...].map(\.id)))
            browser.closeAfter()
            #expect(browser.tabs.map(\.id) == Array(tabs[2...4].map(\.id)))
            #expect(browser.chosen.map(\.id) == Array(tabs[2...4].map(\.id)))
            #expect(browser.active === tabs[2])
        }
    }

    @MainActor @Test func sideClosingReopensTheWholeBatchInItsOriginalOrder() throws {
        try withTabs(6) { browser, tabs in
            let original = tabs.compactMap(\.address)
            tabs[0].pin = "P"
            tabs[1].kept = true
            browser.activeID = tabs[2].id
            browser.closeAfter()
            #expect(browser.ghosts.count == 3)
            let batch = try #require(browser.ghosts.first?.batch)
            #expect(browser.ghosts.allSatisfy { $0.batch == batch })
            #expect(browser.ghosts.map(\.index) == [3, 4, 5])
            browser.reopen()
            #expect(browser.tabs.compactMap(\.address) == original)
            #expect(browser.ghosts.isEmpty)
            #expect(browser.chosen.compactMap(\.address) == Array(original[3...]))
        }
    }

    @MainActor @Test func edgeAvailabilityAndBackgroundContextLeaveTheVisibleSplitAlone() {
        withTabs(5) { browser, tabs in
            browser.activeID = tabs[0].id
            #expect(!Command.closeBefore.available(in: browser))
            #expect(Command.closeAfter.available(in: browser))
            browser.activeID = tabs[4].id
            #expect(Command.closeBefore.available(in: browser))
            #expect(!Command.closeAfter.available(in: browser))
            browser.activeID = tabs[0].id
            browser.pairs = [Pair(first: tabs[0].id, second: tabs[1].id)]
            browser.closeBefore([tabs[3]])
            #expect(browser.tabs.map(\.id) == [tabs[0].id, tabs[1].id, tabs[3].id, tabs[4].id])
            #expect(browser.active === tabs[0])
            #expect(browser.partner(of: tabs[0]) === tabs[1])
        }
    }

    @MainActor @Test func sideClosingBatchRemembersOrdinaryPagesButNotPrivateOrMailPages() throws {
        try withTabs(4) { browser, tabs in
            let privateTab = Tab(shy: true)
            privateTab.restore(url: URL(string: "https://private-side-close.test/secret")!, title: "Private")
            browser.prepare(privateTab)
            tabs[2].restore(url: MailPage.url, title: "Mail")
            browser.lay([tabs[0], tabs[1], privateTab, tabs[2], tabs[3]])
            browser.activeID = tabs[0].id
            browser.closeAfter()
            #expect(browser.tabs.map(\.id) == [tabs[0].id])
            #expect(privateTab.gone && tabs[2].gone)
            #expect(browser.ghosts.map(\.url) == [tabs[1].address!, tabs[3].address!])
            let batch = try #require(browser.ghosts.first?.batch)
            #expect(browser.ghosts.allSatisfy { $0.batch == batch })
            browser.reopen()
            #expect(browser.tabs.compactMap(\.address) == [tabs[0].address!, tabs[1].address!, tabs[3].address!])
            #expect(browser.tabs.allSatisfy { !$0.shy && !MailPage.isMail($0.address) })
        }
    }

    @MainActor @Test func paletteSideClosingLabelsFollowEachWindowsOwnLayout() {
        let oldSidebar = Store.settings.object(forKey: "sidebar")
        defer { Store.settings.set(oldSidebar, forKey: "sidebar") }
        withTabs(3) { sidebar, sideTabs in
            sidebar.prefs.sidebar = true
            sidebar.activeID = sideTabs[1].id
            withTabs(3) { top, topTabs in
                top.prefs.sidebar = false
                top.activeID = topTabs[1].id
                // The shared preference now says Top. Returning to the
                // existing Sidebar window must still show Above / Below.
                sidebar.typed = "close tabs"
                #expect(sidebar.offers.first { $0.kind == .command(.closeBefore) }?.key == "Close Tabs Above")
                #expect(sidebar.offers.first { $0.kind == .command(.closeAfter) }?.key == "Close Tabs Below")
                top.typed = "close tabs"
                #expect(top.offers.first { $0.kind == .command(.closeBefore) }?.key == "Close Tabs to the Left")
                #expect(top.offers.first { $0.kind == .command(.closeAfter) }?.key == "Close Tabs to the Right")
                // An alias from the other layout keeps naming the action.
                top.typed = "close above"
                #expect(top.offers.first { $0.kind == .command(.closeBefore) }?.key == "Close Tabs to the Left")
            }
        }
    }

}
