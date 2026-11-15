import Foundation
import Testing
@testable import Fast

/// Clear on the kept tabs' line (Tidy.swift): what it leaves, and what its
/// Undo brings back. No column in a test, so it goes the plain way, without
/// the dust; the choice of tabs and the batch are the same.
@MainActor
struct ClearTests {
    private static func world(_ count: Int) -> (Browser, [Tab], () -> Void) {
        let window = UUID(), browser = Browser(windowID: window)
        let tabs = (0..<count).map { index in
            let tab = Tab()
            tab.restore(url: URL(string: "https://clear.test/\(index)")!, title: "Tab \(index)")
            browser.prepare(tab)
            return tab
        }
        browser.lay(tabs)
        browser.activeID = tabs[0].id
        return (browser, tabs, {
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
        })
    }

    @Test func undoPutsTodaysFolderBackTogether() {
        let (browser, tabs, done) = Self.world(4)
        defer { done() }
        let nest = Nest(name: "hotels lisbon", search: "hotels lisbon")
        tabs[1].nest = nest
        tabs[2].nest = nest

        browser.tidyNow()
        #expect(browser.tabs.map(\.id) == [tabs[0].id])

        browser.untidy()
        #expect(browser.tabs.count == 4)
        let back = browser.tabs.filter { $0.nest === nest }
        #expect(back.map(\.title) == ["Tab 1", "Tab 2"])
        #expect(browser.tabs.last?.nest == nil)
    }

    @Test func aTaskLeftUnreadStays() {
        let (browser, tabs, done) = Self.world(3)
        defer { done() }
        tabs[1].unread = AgentFeed.Unread(session: "task")

        browser.tidyNow()
        #expect(browser.tabs.map(\.id) == [tabs[0].id, tabs[1].id])
        #expect(!browser.canTidyNow)
    }

    @Test func aRowRedrawnKeepsItsPlaceWhenTheOldOneGoes() {
        let rows = DrawnRows()
        let old = UUID(), new = UUID()
        let key = DrawnRows.folder("nest:x")
        rows.put(key, CGRect(x: 0, y: 10, width: 200, height: 28), by: old)
        rows.put(key, CGRect(x: 0, y: 40, width: 200, height: 28), by: new)
        rows.take(key, by: old)
        #expect(rows[key]?.minY == 40)
        rows.take(key, by: new)
        #expect(rows[key] == nil)
    }
}
