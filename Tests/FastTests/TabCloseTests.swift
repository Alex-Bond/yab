import Foundation
import Testing
@testable import Fast

struct TabCloseTests {
    @MainActor @Test func closeOnEmptyFieldDoesNotInventATabOrRefocusTheField() {
        let id = UUID()
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        let browser = Browser(windowID: id)
        browser.lay([])
        browser.activeID = nil
        let focus = browser.query.focusRequest
        browser.typed = "unfinished search"
        browser.shut([], byKey: true)
        #expect(browser.activeID == nil && browser.tabs.isEmpty && browser.fieldShowing)
        #expect(browser.typed == "unfinished search")
        #expect(browser.query.focusRequest == focus)
        browser.typed = "another search"
        browser.shut([], byKey: true)
        #expect(browser.typed == "another search" && browser.activeID == nil && browser.tabs.isEmpty)
        #expect(browser.ghosts.isEmpty, "An empty field never invents a closed tab")
    }

    @MainActor @Test func anotherCloseAfterLastPageKeepsItsUndo() {
        let id = UUID()
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        let browser = Browser(windowID: id)
        let tab = Tab()
        tab.restore(url: URL(string: "https://close.test/page")!, title: "Page")
        browser.prepare(tab)
        browser.lay([tab])
        browser.activeID = tab.id
        browser.shut([tab], byKey: true)
        #expect(browser.activeID == nil && browser.tabs.isEmpty && browser.fieldShowing)
        let ghosts = browser.ghosts.count
        #expect(ghosts == 1)
        browser.typed = "new search"
        browser.shut(browser.chosen, byKey: true)
        #expect(browser.typed == "new search" && browser.activeID == nil && browser.tabs.isEmpty)
        #expect(browser.ghosts.count == ghosts, "Repeated Close Tab keeps the actual page in Recently Closed")
    }

    @MainActor @Test func closingLinkReturnsToItsPinnedSource() {
        let id = UUID()
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        let browser = Browser(windowID: id)
        let twitter = browser.open(URL(string: "about:blank")!, foreground: true)
        browser.pin(twitter)

        let other = browser.open(URL(string: "about:blank")!, foreground: true)
        browser.pin(other)
        browser.select(twitter)
        let link = browser.open(URL(string: "about:blank")!, foreground: true, from: twitter)

        browser.shut(link)

        #expect(browser.active === twitter)
        #expect(!browser.tabs.contains { $0 === link })
    }
}
