import Foundation
import Testing
@testable import Fast

/// Row 1132 (#678): an address typed in ⌘T goes there on Return, and the
/// next row searches the person's engine for it, as Arc and Chrome offer.
@MainActor
@Suite(.serialized)
struct FieldAddressSearchTests {
    @Test func anAddressIsAlsoSearchedRightUnderIt() {
        let id = UUID()
        let browser = Browser(windowID: id)
        browser.prefs.searchSuggest = false
        defer {
            browser.dismiss()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        browser.newTab()
        let typed = "never-been-1132.example.test/page"
        browser.typed = typed
        let offers = browser.offers
        #expect(offers.first?.kind == .address)
        #expect(browser.query.lead == 0)
        // One ↓ away: the same words, searched, with the engine the field names.
        let search = offers.dropFirst().first
        #expect(search?.kind == .search)
        #expect(search?.key == typed)
        #expect(search?.title == browser.searchEngine.name)
        #expect(search?.url == browser.searchEngine.url(for: typed))
        // Never Ask or Task for an address.
        #expect(!offers.contains { $0.kind == .ask || $0.kind == .task })
    }
}
