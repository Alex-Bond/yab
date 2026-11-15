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

    @Test func pickedDestinationAndCategoryReturnOnNextCommandT() throws {
        try withBrowser { browser in
            let destinations = FieldPlace.allCases.filter { $0 != .selection && $0 != .files }
            let views = destinations.flatMap { place in
                (place == .autofill ? [2, 3] : [0]).map { (place, $0) }
            }
            for (place, filter) in views {
                browser.openFresh()
                browser.enterPlace(place)
                browser.query.placeFilter = filter
                // A pick closes the field through close(); only destination
                // state may survive, never the page form or revealed value.
                browser.close()
                #expect(browser.query.form == nil)
                browser.pressNewTab()
                #expect(browser.query.place == place)
                #expect(browser.query.placeFilter == filter)
                browser.pressNewTab()
                #expect(browser.query.place == nil)
                #expect(browser.query.returnPlace == nil)
            }
        }
    }

    @Test func escapeReturnsToDefaultAndForgetsDestination() throws {
        try withBrowser { browser in
            browser.enterPlace(.autofill)
            browser.query.placeFilter = 3
            browser.close()
            browser.pressNewTab()
            #expect(browser.query.place == .autofill)
            #expect(browser.leavePlace())
            #expect(browser.query.place == nil)
            #expect(browser.query.returnPlace == nil)
            browser.close()
            browser.pressNewTab()
            #expect(browser.query.place == nil)
        }
    }

    @Test func directDestinationsNeverBecomeTheCommandTReturnPlace() throws {
        try withBrowser { browser in
            for place in FieldPlace.allCases where place != .selection && place != .files {
                for dismiss in [false, true] {
                    // Start with a remembered destination to prove a direct
                    // entry replaces its provenance, rather than retaining it.
                    browser.openFresh()
                    browser.enterPlace(.history)
                    browser.close()
                    browser.openPlace(place)
                    #expect(browser.query.place == place)
                    if dismiss { browser.dismiss() } else { browser.close() }
                    browser.newTab()
                    #expect(browser.query.place == nil, "Direct \(place), dismiss=\(dismiss)")
                    #expect(browser.query.returnPlace == nil)
                    browser.close()
                }
            }
        }
    }

    @Test func directActionWhileAFieldPlaceIsOpenDoesNotInheritItsOrigin() throws {
        try withBrowser { browser in
            browser.enterPlace(.history)
            browser.openPlace(.emoji)
            browser.close()
            browser.newTab()
            #expect(browser.query.place == nil)
            browser.enterPlace(.history)
            // A direct action on the same destination toggles it closed.
            browser.openPlace(.history)
            browser.newTab()
            #expect(browser.query.place == nil)
        }
    }

    @Test func directSearchInTheFieldStillBelongsToThatField() throws {
        try withBrowser { browser in
            browser.replaceTyped("fixture")
            #expect(browser.takeOwn(Suggestion(key: "History", title: "", url: nil, kind: .within(.history))))
            browser.close()
            browser.newTab()
            #expect(browser.query.place == .history)
            #expect(browser.typed.isEmpty)
        }
    }

    @Test func destinationCommandsChosenInTheFieldKeepTheirOrigin() throws {
        try withBrowser { browser in
            for (command, place) in [(Command.history, FieldPlace.history), (.downloads, .downloads),
                                      (.bookmarks, .bookmarks), (.passwords, .passwords),
                                      (.autofill, .autofill), (.boostStore, .store)] {
                browser.openFresh()
                browser.take(Suggestion(key: command.title, title: "", url: nil, kind: .command(command)))
                #expect(browser.query.place == place)
                browser.close()
                browser.newTab()
                #expect(browser.query.place == place)
                browser.close()
            }
        }
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
                        if place == .autofill, words == "add" {
                            // The exact Add action is discoverable above the
                            // Addresses prefix; Return still chooses Addresses.
                            #expect(browser.offers.first?.kind == .command(.addExtension))
                            #expect(browser.offers[browser.query.lead ?? 0].kind == .place(place))
                        } else {
                            #expect(browser.offers.first?.kind == .place(place), "\(words) should lead to \(place)")
                            #expect(browser.query.lead == 0, "\(words)")
                        }
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
