import AppKit
import Foundation
import Testing
@testable import Fast

/// Google's NAVIGATION results in ⌘T's real list, as Chromium's omnibox
/// lists them: a site's row among the engine's words, under the row Return
/// takes, and once when history already goes there.
@MainActor
@Suite(.serialized)
struct NavigationSuggestionTests {
    private func withBrowser(_ visits: [Visit], _ body: (Browser) throws -> Void) rethrows {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let suggest = browser.prefs.searchSuggest
        let requests = browser.prefs.fieldRequests
        // No request goes out: the engine's answer is the recorded one.
        browser.prefs.searchSuggest = false
        browser.prefs.fieldRequests = false
        browser.history = History(visits)
        defer {
            browser.dismiss()
            browser.letGo()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            browser.prefs.searchSuggest = suggest
            browser.prefs.fieldRequests = requests
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }
        browser.openFresh()
        try body(browser)
    }

    private func visit(_ address: String, _ title: String, count: Int, typed: Int) -> Visit {
        let url = URL(string: address)!
        return Visit(url: url.absoluteString, key: History.key(for: url), title: title, count: count, last: Date(), typed: typed)
    }

    /// The list ⌘T shows once the engine's answer is in, as Browser.guess
    /// composes it.
    private func answered(_ browser: Browser, _ words: String, _ answer: String) -> (list: [Suggestion], lead: Int?) {
        browser.replaceTyped(words)
        let items = SearchSuggestions.read(Data(answer.utf8), engine: .google, typed: words)
        let rows = SearchSuggestions.rows(items) { Engine.url(for: $0, template: Engine.google.template(custom: "")) }
        let merged = SearchSuggestions.merge(rows, into: browser.offers, lead: browser.query.lead)
        print("after \(words): " + merged.list.map { "\($0.kind)\($0.engine ? "/engine" : "") \($0.key)" }.joined(separator: " | "))
        return merged
    }

    @Test func twitterListsTwitterComAsASiteUnderTheSearch() throws {
        // The world of fix/suggestion-remove: x.com every day, the Raycast
        // Store's Twitter page a dozen times.
        try withBrowser([visit("https://x.com/home", "Home / X", count: 60, typed: 30),
                         visit("https://www.raycast.com/store/twitter", "Twitter - Raycast Store", count: 12, typed: 0)]) { browser in
            let merged = answered(browser, "twitter", SearchSuggestionsTests.twitter)
            let lead = try #require(merged.lead)
            #expect(merged.list[lead].kind != .known)
            let site = try #require(merged.list.firstIndex { $0.engine })
            #expect(merged.list[site].url?.absoluteString == "https://twitter.com")
            #expect(merged.list[site].key == "twitter.com")
            #expect(merged.list[site].kind == .known)
            let search = try #require(merged.list.firstIndex { $0.kind == .search })
            #expect(site > search && site > lead)
            // Under the engine's words, as Chromium 157 lists it.
            #expect(merged.list[site - 1].key == "twitter login")
            #expect(merged.list.filter { $0.url?.host() == "twitter.com" }.count == 1)
        }
    }

    @Test func aSiteHistoryAlreadyListsIsNotListedTwice() throws {
        // The same address in history: one row, history's.
        try withBrowser([visit("https://twitter.com/", "X", count: 9, typed: 3)]) { browser in
            let merged = answered(browser, "twitter", SearchSuggestionsTests.twitter)
            #expect(!merged.list.contains { $0.engine })
            #expect(merged.list.filter { $0.url?.host() == "twitter.com" }.count == 1)
        }
        // Another page of the site is another destination.
        try withBrowser([visit("https://twitter.com/settings", "Settings / X", count: 9, typed: 0)]) { browser in
            let merged = answered(browser, "twitter", SearchSuggestionsTests.twitter)
            #expect(merged.list.contains { $0.engine && $0.url?.absoluteString == "https://twitter.com" })
            #expect(merged.list.contains { $0.kind == .visited && $0.url?.path() == "/settings" })
        }
        // github.com is one of the field's known sites: its row stays the one.
        try withBrowser([]) { browser in
            let merged = answered(browser, "github", SearchSuggestionsTests.github)
            #expect(!merged.list.contains { $0.engine })
            #expect(merged.list.filter { $0.url?.host() == "github.com" }.count == 1)
        }
    }

    @Test func aSiteScoredAboveTheWordsIsNeverReturnsRow() throws {
        // Google scores facebook.com 1150 against the words' 851; Chrome 157
        // still keeps the words searched as the default match and lists the
        // site last (farm 41d5b0b7ec6245ba).
        try withBrowser([]) { browser in
            let merged = answered(browser, "faceb", SearchSuggestionsTests.faceb)
            let lead = try #require(merged.lead)
            #expect(merged.list[lead].kind == .search)
            #expect(browser.query.ending == nil)
            #expect(merged.list.last { $0.kind == .suggested || $0.engine }?.url?.absoluteString == "https://www.facebook.com/")
        }
    }
}
