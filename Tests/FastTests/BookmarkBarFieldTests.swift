import Foundation
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct BookmarkBarFieldTests {
    private func withBrowser(_ run: (Browser) async throws -> Void) async rethrows {
        let browser = Browser(windowID: UUID())
        let keys = ["bookmarks.bar", "search.suggest", FieldRequest.key]
        let saved = keys.map { Store.settings.object(forKey: $0) }
        let mode = browser.prefs.bookmarkBar
        let suggest = browser.prefs.searchSuggest
        let requests = browser.prefs.fieldRequests
        browser.prefs.searchSuggest = false
        browser.prefs.fieldRequests = false
        defer {
            browser.prefs.bookmarkBar = mode
            browser.prefs.searchSuggest = suggest
            browser.prefs.fieldRequests = requests
            for (key, value) in zip(keys, saved) { Store.settings.set(value, forKey: key) }
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            browser.dropSpare()
            browser.letGo()
            if let window = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(window.uuidString).space")
            }
        }
        try await run(browser)
    }

    @Test func theEnabledBarSurvivesTheNewTabFieldAndEscape() async {
        await withBrowser { browser in
            let tab = Tab()
            tab.restore(url: URL(string: "https://bookmarks-field.test/")!, title: "Page")
            browser.prepare(tab)
            browser.lay([tab])
            browser.activeID = tab.id
            browser.prefs.bookmarkBar = .always
            #expect(browser.shelfShown)
            browser.pressNewTab()
            #expect(browser.fieldShowing && browser.asked == .tab)
            #expect(browser.shelfShown)
            browser.dismiss()
            #expect(browser.active === tab && browser.shelfShown)
        }
    }

    @Test func theEnabledBarDoesNotNeedAnActiveTab() async {
        await withBrowser { browser in
            #expect(browser.active == nil)
            browser.prefs.bookmarkBar = .always
            #expect(browser.shelfShown)
            browser.pressNewTab()
            #expect(browser.shelfShown)
            browser.dismiss()
            #expect(browser.shelfShown)
            browser.pressNewTab()
            #expect(browser.fieldShowing && browser.shelfShown)
        }
    }

    @Test func theBarCanBeHiddenAndShownWhileTheTablessFieldIsOpen() async throws {
        try await withBrowser { browser in
            browser.prefs.bookmarkBar = .never
            browser.openFresh()
            for expected in [BookmarkBarMode.always, .never, .always] {
                browser.toggleBookmarkBar()
                for _ in 0..<80 where browser.shelving {
                    try await Task.sleep(for: .milliseconds(25))
                }
                #expect(!browser.shelving)
                #expect(browser.prefs.bookmarkBar == expected)
                #expect(browser.shelfShown == (expected == .always))
                #expect(browser.fieldShowing && browser.active == nil)
            }
        }
    }
}
