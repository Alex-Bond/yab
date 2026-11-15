import Foundation
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct SelectedTabReloadTests {
    private func world(_ body: (Browser, [Tab]) throws -> Void) rethrows {
        let id = UUID()
        let browser = Browser(windowID: id)
        browser.lay([])
        let tabs = (0..<4).map { browser.open(URL(string: "https://reload.example.test/\($0)")!, foreground: false, atEnd: true) }
        defer {
            browser.letGo()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        try body(browser, tabs)
    }

    @Test func keyboardReloadSnapshotsTheSelectionInRowOrder() {
        world { browser, tabs in
            browser.select(tabs[0])
            browser.extend(to: tabs[2])
            #expect(browser.reloadTargets().map(\.id) == tabs.prefix(3).map(\.id))
            #expect(browser.active === tabs[0])
            #expect(browser.chosen.map(\.id) == tabs.prefix(3).map(\.id))
        }
    }

    @Test func explicitReloadDoesNotExpandToTheSelection() {
        world { browser, tabs in
            browser.select(tabs[0])
            browser.extend(to: tabs[2])
            #expect(browser.reloadTargets(tabs[1]).map(\.id) == [tabs[1].id])
            #expect(browser.reloadTargets(tabs[3]).map(\.id) == [tabs[3].id])
        }
    }

    @Test func noSelectionReloadsOnlyTheActiveTab() {
        world { browser, tabs in
            browser.select(tabs[2])
            #expect(browser.reloadTargets().map(\.id) == [tabs[2].id])
        }
    }
    @Test func peekReloadTakesPrecedenceOverTheTabSelection() {
        world { browser, tabs in
            browser.select(tabs[0])
            browser.extend(to: tabs[2])
            browser.peeking = tabs[3]
            defer { browser.peeking = nil }
            #expect(browser.reloadTargets().map(\.id) == [tabs[3].id])
            #expect(browser.reloadTargets(tabs[1]).map(\.id) == [tabs[1].id])
        }
    }

}
