import AppKit
import Testing
@testable import Fast

/// A tab keeps its id across a relaunch, which is what sync knows it by
/// (PLAN-sync.md), and never comes back with an id another tab has.
@MainActor
@Suite(.serialized)
struct SessionIDTests {
    private func world(_ body: (Browser, UUID) throws -> Void) rethrows {
        let id = UUID(), browser = Browser(windowID: id)
        defer {
            for tab in browser.tabs + browser.parkedTabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
        }
        try body(browser, id)
    }

    @Test func aTabComesBackWithItsOwnID() {
        world { browser, _ in
            let tabs = (0..<3).map { i -> Tab in
                let tab = Tab()
                browser.prepare(tab)
                tab.restore(url: URL(string: "https://ids.test/\(i)")!, title: "Tab \(i)")
                return tab
            }
            browser.lay(tabs)
            browser.activeID = tabs[1].id
            browser.writeSession(now: true)
            let ids = tabs.map(\.id)
            for tab in tabs { tab.close() }
            browser.lay([])
            let row = browser.loadRow(Space.firstID)
            defer { for tab in row.tabs { tab.close() } }
            #expect(row.tabs.map(\.id) == ids)
            #expect(row.active == ids[1])
        }
    }

    @Test func anIDAlreadyInUseIsNotTakenTwice() throws {
        try world { browser, window in
            let taken = UUID()
            let holder = Tab(id: taken)
            defer { holder.close() }
            Session.write(now: true, window: window, .init(tabs: [
                .init(url: "https://ids.test/a", title: "A", id: taken.uuidString),
                .init(url: "https://ids.test/b", title: "B", id: "not an id"),
                .init(url: "https://ids.test/c", title: "C"),
            ], active: 0))
            let row = browser.loadRow(Space.firstID)
            defer { for tab in row.tabs { tab.close() } }
            #expect(row.tabs.count == 3)
            #expect(!row.tabs.map(\.id).contains(taken))
            #expect(Set(row.tabs.map(\.id)).count == 3)
        }
    }
}
