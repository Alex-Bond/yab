import AppKit
import Foundation
import Testing
@testable import Fast

/// Built-in destinations named in the field must be visible above web
/// results, and Return must open the same destination the list puts first.
@MainActor
@Suite(.serialized)
struct FieldPlacePriorityTests {
    private func withBrowser(_ body: (Browser) throws -> Void) rethrows {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let suggest = browser.prefs.searchSuggest
        let requests = browser.prefs.fieldRequests
        browser.prefs.searchSuggest = false
        browser.prefs.fieldRequests = false
        browser.history = History([])
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

    @Test func namedPlacesLeadForNamesAliasesAndLongPrefixes() throws {
        try withBrowser { browser in
            for place in [FieldPlace.clipboard, .emoji, .downloads, .passwords, .autofill,
                          .history, .bookmarks, .chats, .routines, .snippets, .store, .now] {
                for name in place.names {
                    for count in Set([3, max(3, name.count - 1), name.count]) where count <= name.count {
                        let words = String(name.prefix(count))
                        // "boo" also begins Bookmarks; "boos" names Store.
                        if place == .store, words == "boo" { continue }
                        browser.replaceTyped(words)
                        #expect(browser.offers.first?.kind == .place(place), "\(words) should lead to \(place)")
                        #expect(browser.query.lead == 0, "\(words)")
                        #expect(browser.offers.filter { $0.kind == .place(place) }.count == 1)
                    }
                }
            }
        }
    }

    @Test func namedPlaceBeatsHistoryCompletionAndSearchSuggestions() throws {
        try withBrowser { browser in
            let url = URL(string: "https://clipboard.example.test/manual")!
            browser.history = History([Visit(url: url.absoluteString, key: Address.pretty(url),
                                             title: "Clipboard history for Mac", count: 100, last: Date(), typed: 100)])
            browser.replaceTyped("clipboard")
            #expect(browser.ending == nil)
            #expect(browser.offers.first?.kind == .place(.clipboard))
            #expect(browser.offers.contains { $0.url == url })
            let suggestions = ["clipboard history", "clipboard history mac", "clipboard history windows"].map {
                Suggestion(key: $0, title: "", url: nil, kind: .suggested)
            }
            let merged = SearchSuggestions.merge(suggestions, into: browser.offers, lead: browser.query.lead)
            #expect(merged.list.first?.kind == .place(.clipboard))
            #expect(merged.lead == 0)
            #expect(merged.list.dropFirst().first?.kind == .search)
        }
    }

    @Test func returnOpensClipboardAndFiles() throws {
        try withBrowser { browser in
            for (words, place) in [("clipboard his", FieldPlace.clipboard), ("files", .downloads)] {
                browser.openFresh()
                browser.replaceTyped(words)
                #expect(browser.offers.first?.kind == .place(place))
                browser.submit()
                #expect(browser.query.place == place)
            }
        }
    }

    @Test func longerSearchesAndExplicitAddressesKeepTheirMeaning() throws {
        try withBrowser { browser in
            for words in ["files for taxes", "clipboard history windows 11", "password reset instructions"] {
                browser.replaceTyped(words)
                #expect(browser.offers.first?.kind == .search, "\(words)")
            }
            browser.replaceTyped("clipboard.example.test")
            #expect(browser.offers.first?.kind == .address)
            #expect(!browser.offers.contains { $0.kind == .place(.clipboard) })
        }
    }
}
