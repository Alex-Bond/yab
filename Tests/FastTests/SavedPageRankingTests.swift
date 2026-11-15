import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct SavedPageRankingTests {
    @Test func wordStartsFindTitlesAndSiteNames() {
        let url = URL(string: "https://open.spotify.com/collection")!
        #expect(SavedPageMatch.matches("sp", title: "My Spotify Library", url: url))
        #expect(SavedPageMatch.matches("sp lib", title: "My Spotify Library", url: url))
        #expect(SavedPageMatch.matches("sp", title: "Music", url: url))
        #expect(!SavedPageMatch.matches("pot", title: "Spotify", url: url))
    }

    @Test(arguments: [false, true])
    func openAndPinnedNamesBeatHistory(pinned: Bool) {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let suggest = browser.prefs.searchSuggest
        browser.prefs.searchSuggest = false
        let tab = Tab(later: .nonPersistent())
        tab.restore(url: URL(string: "https://open.spotify.com/collection")!, title: "My Spotify Library")
        // A renamed tab must remain searchable by the page's own title.
        tab.name = "Music"
        if pinned { tab.pin = "S"; tab.homeTitle = "My Spotify Library" }
        browser.prepare(tab)
        browser.lay([tab])
        browser.activeID = nil
        defer {
            tab.close(); browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.prefs.searchSuggest = suggest
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }
        browser.history = History([Visit(url: "https://sp.example/", key: "sp.example", title: "Frequent", count: 1000, last: Date())])
        browser.openFresh()
        for words in ["sp", "lib", "sp lib"] {
            browser.replaceTyped(words)
            let merged = SearchSuggestions.merge([Suggestion(key: words + " music", title: "", url: nil, kind: .suggested)], into: browser.offers, lead: browser.query.lead)
            let at = merged.list.firstIndex { $0.tab == tab.id }
            #expect(at != nil)
            #expect(browser.ending == nil)
            if let at {
                for other in merged.list.indices where merged.list[other].key == "sp.example" || merged.list[other].kind == .suggested {
                    #expect(at < other)
                }
            }
        }
    }

    @Test func everySavedRowStaysAboveWebSuggestions() {
        let search = Suggestion(key: "sp", title: "", url: nil, kind: .search)
        let saved = (0..<5).map { Suggestion(key: "spotify-\($0)", title: "Spotify", url: nil, kind: .visited, bookmarked: true) }
        let web = Suggestion(key: "spotify music", title: "", url: nil, kind: .suggested)
        let merged = SearchSuggestions.merge([web], into: [search] + saved, lead: 0)
        #expect(merged.list.map(\.key) == [search.key] + saved.map(\.key) + [web.key])
    }

    @Test func actionsDoNotLetSuggestionsOvertakeSavedDestinations() {
        let search = Suggestion(key: "sp", title: "", url: nil, kind: .search)
        let action = Suggestion(key: "Search settings", title: "", url: nil, kind: .setting(.search))
        let web = Suggestion(key: "spotify music", title: "", url: nil, kind: .suggested)
        for saved in [Suggestion(key: "Spotify", title: "", url: nil, kind: .open),
                      Suggestion(key: "Spotify", title: "", url: nil, kind: .visited, bookmarked: true)] {
            let merged = SearchSuggestions.merge([web], into: [search, action, saved], lead: 0)
            #expect(merged.list == [search, action, saved, web])
            #expect(merged.lead == 0)
        }
    }

    @Test func savedNamesBeatHistoryAndSuggestions() {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let suggest = browser.prefs.searchSuggest
        let requests = browser.prefs.fieldRequests
        browser.prefs.searchSuggest = false
        browser.prefs.fieldRequests = false
        let url = URL(string: "https://open.spotify.com/collection/saved-ranking")!
        let id = browser.bookmarks.add(url, title: "My Spotify Library")
        defer {
            if let id { browser.bookmarks.remove(id) }
            browser.dismiss(); browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.prefs.searchSuggest = suggest
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
            browser.prefs.fieldRequests = requests
        }
        browser.history = History([Visit(url: "https://sp.example/", key: "sp.example", title: "Frequent", count: 1000, last: Date())])
        browser.openFresh()
        for text in ["sp", "lib", "sp lib"] {
            browser.replaceTyped(text)
            let merged = SearchSuggestions.merge([Suggestion(key: text + " music", title: "", url: nil, kind: .suggested)],
                                                  into: browser.offers, lead: browser.query.lead)
            let saved = merged.list.firstIndex { $0.url == url }
            #expect(saved != nil)
            #expect(browser.ending == nil)
            if let saved {
                #expect(merged.list[saved].bookmarked)
                #expect(merged.list.filter { $0.url == url }.count == 1)
                for at in merged.list.indices where merged.list[at].key == "sp.example" || merged.list[at].kind == .suggested {
                    #expect(saved < at)
                }
            }
        }
    }
}
