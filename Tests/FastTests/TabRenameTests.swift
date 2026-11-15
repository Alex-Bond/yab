import Foundation
import Testing
@testable import Fast

// Renaming a tab in the column: a double-click opens the field, and an edit
// whose tab went away is put down rather than left holding the keys.
@Suite(.serialized)
@MainActor
struct TabRenameTests {
    private func withTabs(_ count: Int, _ body: (Browser, [Tab]) throws -> Void) rethrows {
        let window = UUID(), browser = Browser(windowID: window)
        let tabs = (0..<count).map { index in
            let tab = Tab()
            tab.restore(url: URL(string: "https://rename.test/\(index)")!, title: "Tab \(index)")
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

    @Test func twoTapsOnOneTabOpenTheField() {
        withTabs(2) { browser, tabs in
            browser.tapTab(tabs[1])
            #expect(browser.editingTab == nil)
            browser.tapTab(tabs[1])
            #expect(browser.editingTab == tabs[1].id)
            browser.cancelTabEdit()
        }
    }

    @Test func anEditWhoseTabClosedIsPutDown() {
        withTabs(3) { browser, tabs in
            browser.activeID = tabs[0].id
            browser.beginTabEdit(tabs[2])
            browser.tabDraft = "Mine"
            browser.close(tabs[2])
            browser.commitTabEdit()
            #expect(browser.editingTab == nil)
            #expect(browser.tabDraft.isEmpty)
        }
    }
}
