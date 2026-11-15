import Foundation
import Testing
@testable import Fast

struct WindowSessionsTests {
    private func entry(_ url: String) -> Session.Entry {
        Session.Entry(url: url, title: url, pin: nil, name: nil, seen: nil)
    }

    @Test func windowsKeepIndependentTabsAndSelection() {
        let first = UUID(), second = UUID()
        defer {
            try? FileManager.default.removeItem(at: Store.file("session-window-\(first.uuidString).json"))
            try? FileManager.default.removeItem(at: Store.file("session-window-\(second.uuidString).json"))
        }
        Session.write(now: true, space: Space.firstID, window: first,
                      .init(tabs: [entry("https://example.com/a"), entry("https://example.com/b")], active: 1))
        Session.write(now: true, space: Space.firstID, window: second,
                      .init(tabs: [entry("https://example.org/")], active: 0))

        let a = Session.read(space: Space.firstID, window: first)
        let b = Session.read(space: Space.firstID, window: second)
        #expect(a.tabs.map(\.url) == ["https://example.com/a", "https://example.com/b"])
        #expect(a.active == 1)
        #expect(b.tabs.map(\.url) == ["https://example.org/"])
        #expect(b.active == 0)
    }

    @Test func deletingSpaceRemovesItsSessionsFromEveryWindow() {
        let space = UUID(), first = UUID(), second = UUID()
        let urls = [first, second].map { Store.file("session-window-\($0.uuidString)-\(space.uuidString).json") }
        Session.write(now: true, space: space, window: first,
                      .init(tabs: [entry("https://example.com/")], active: 0))
        Session.write(now: true, space: space, window: second,
                      .init(tabs: [entry("https://example.org/")], active: 0))
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        Session.erase(space: space)
        #expect(urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @MainActor @Test func movingOnlyTabLeavesNoTabInFront() {
        let id = UUID()
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        let browser = Browser(windowID: id)
        let moved = browser.open(URL(string: "about:blank")!, foreground: true)

        browser.moveOut(moved)

        #expect(browser.tabs.isEmpty)
        #expect(browser.active == nil)
        #expect(browser.chosen.isEmpty)
        #expect(browser.fieldShowing && browser.fresh)
    }

    @MainActor @Test func liveTabHasOneWindowOwnerAfterMove() {
        let firstID = UUID(), secondID = UUID()
        defer {
            try? FileManager.default.removeItem(at: Store.file("session-window-\(firstID.uuidString).json"))
            try? FileManager.default.removeItem(at: Store.file("session-window-\(secondID.uuidString).json"))
        }
        let first = Browser(windowID: firstID)
        let second = Browser(windowID: secondID)
        let moved = first.open(URL(string: "about:blank")!, foreground: true)
        let page = moved.page
        let watches = moved.browserWatches.count
        #expect(watches > 0)

        first.moveOut(moved)
        second.moveIn(moved)

        #expect(!first.tabs.contains { $0 === moved })
        #expect(second.tabs.filter { $0 === moved }.count == 1)
        #expect(second.active === moved)
        #expect(moved.delegate === second)
        #expect(moved.browserWatches.count == watches)
        #expect(moved.builtPage === page && page.stateEvents === moved)

        second.moveOut(moved)
        first.moveIn(moved)
        #expect(first.active === moved)
        #expect(!second.tabs.contains { $0 === moved })
        #expect(moved.delegate === first)
        #expect(moved.browserWatches.count == watches)
        #expect(moved.builtPage === page && page.stateEvents === moved)
    }
}
