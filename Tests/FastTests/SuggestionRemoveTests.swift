import AppKit
import Testing
@testable import Fast

/// #2017: "twitter" in ⌘T offered a Raycast Store page as its first place,
/// and Chrome's key for taking a suggestion out, ⇧⌦ (fn⇧⌫ on a laptop),
/// did nothing to it.
@MainActor @Suite(.serialized)
struct SuggestionRemoveTests {
    private func withBrowser(_ body: (Browser) throws -> Void) rethrows {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let tab = Tab(later: .nonPersistent())
        tab.restore(url: URL(string: "https://fixture.example/")!, title: "Fixture")
        browser.lay([tab])
        browser.activeID = nil
        let suggest = browser.prefs.searchSuggest
        let requests = browser.prefs.fieldRequests
        browser.prefs.searchSuggest = false
        browser.prefs.fieldRequests = false
        browser.openFresh()
        defer {
            tab.close(); browser.dismiss(); browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.prefs.searchSuggest = suggest
            browser.prefs.fieldRequests = requests
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }
        try body(browser)
    }

    private static let store = URL(string: "https://www.raycast.com/thomaspaulmann/twitter")!

    /// X every day, typed; the Raycast Store's Twitter extension page a
    /// dozen times this week, opened from Raycast.
    private func world(_ browser: Browser) {
        let now = Date()
        browser.history = History([
            Visit(url: "https://x.com/home", key: "x.com/home", title: "Home / X", count: 300, last: now, typed: 0),
            Visit(url: "https://x.com/", key: "x.com", title: "Home / X", count: 340, last: now, typed: 40),
            Visit(url: Self.store.absoluteString, key: History.key(for: Self.store),
                  title: "Twitter | Raycast Store", count: 12, last: now),
            Visit(url: "https://www.raycast.com/", key: "raycast.com", title: "Raycast", count: 12, last: now),
        ])
    }

    private static func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ text: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: text, charactersIgnoringModifiers: text,
                         isARepeat: false, keyCode: code)!
    }

    /// fn⇧⌫ on a laptop, ⇧⌦ on a full keyboard: forward delete with ⇧.
    static let shiftForwardDelete = key(117, [.shift, .function], String(UnicodeScalar(NSDeleteFunctionKey)!))
    static let shiftDelete = key(51, [.shift], "\u{7f}")

    /// The reporter's history: X's address and titles never say "twitter",
    /// the Store page's title does. It still stands under the search and
    /// under X's own row, which "twitter" names as a site to search
    /// (Scopes, alias twitter): no count of visits puts it first.
    @Test func theStorePageStaysUnderTheSearchAndX() throws {
        try withBrowser { browser in
            world(browser)
            browser.replaceTyped("twitter")
            let list = browser.offers
            print("#2017 twitter:", list.map { "\($0.kind) \($0.url?.absoluteString ?? $0.key)" })
            #expect(browser.query.lead == 0)
            #expect(list.first?.kind == .search)
            let x = try #require(list.firstIndex { $0.url?.host() == "x.com" })
            let store = try #require(list.firstIndex { $0.url == Self.store })
            #expect(x < store)
        }
    }

    /// Chrome's key: ⇧⌦ (fn⇧⌫) takes the chosen place out, as ⇧⌫ does.
    @Test func shiftForwardDeleteIsTheFieldsForget() {
        #expect(Keymap.shared.matches(Self.shiftDelete, .fieldForget))
        #expect(Keymap.shared.matches(Self.shiftForwardDelete, .fieldForget))
        // Forward delete alone stays a delete.
        #expect(!Keymap.shared.matches(Self.key(117, [.function], String(UnicodeScalar(NSDeleteFunctionKey)!)), .fieldForget))
    }

    /// Walked to and fn⇧⌫ pressed, the Store page goes from the list and
    /// the history, and "twitter" no longer offers it.
    @Test func theStorePageGoesWithChromesKey() throws {
        try withBrowser { browser in
            world(browser)
            browser.replaceTyped("twitter")
            let row = try #require(browser.offers.firstIndex { $0.url == Self.store })
            browser.picked = row
            #expect(Keymap.shared.matches(Self.shiftForwardDelete, .fieldForget))
            #expect(browser.forgetChosen())
            #expect(!browser.history.remembers(History.key(for: Self.store)))
            #expect(!browser.offers.contains { $0.url == Self.store })
            browser.replaceTyped("twitte")
            browser.replaceTyped("twitter")
            #expect(!browser.offers.contains { $0.url == Self.store })
        }
    }
}
