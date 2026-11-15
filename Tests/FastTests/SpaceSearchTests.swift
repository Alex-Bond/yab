import AppKit
import Foundation
import Testing
import SyncKit
@testable import Fast

/// Feedback #338: each space can search with an engine of its own, as in
/// Arc, and with none it searches with Settings › Search's. The choice is
/// kept with the space, synced with it, and read by the field.
@MainActor
struct SpaceSearchTests {
    init() { SyncShapes.register() }

    static let work = UUID(uuidString: "6A1E4F0C-3B2D-4F77-9C1A-0E5D2B7A9F10")!

    @Test func noEngineOfItsOwnIsSettingsSearchs() {
        #expect(EngineChoice.own(nil, custom: nil) == nil)
        #expect(EngineChoice.own("", custom: nil) == nil)
        #expect(EngineChoice.own("altavista", custom: nil) == nil)
        #expect(EngineChoice.space(nil, custom: nil) == .global)
        let space = Space(id: Self.work, name: "Work", icon: "💼", ownSignIns: false)
        #expect(space.engine == .global)
    }

    @Test func anEngineOfItsOwnSearchesThere() throws {
        let kagi = try #require(EngineChoice.own("kagi", custom: nil))
        #expect(kagi.engine == .kagi)
        #expect(kagi.name == "Kagi")
        #expect(kagi.url(for: "rust borrow checker")?.absoluteString == "https://kagi.com/search?q=rust%20borrow%20checker")
        // An address is still a place, not a search.
        #expect(kagi.destination(for: "example.com")?.host == "example.com")
        #expect(kagi.destination(for: "c++ tips")?.host == "kagi.com")
        let ddg = Space(id: Self.work, name: "Work", icon: "💼", ownSignIns: false, search: "duckduckgo")
        #expect(ddg.engine.url(for: "a+b")?.absoluteString == "https://duckduckgo.com/?q=a%2Bb")
    }

    @Test func aResultsPageOfItsOwnIsNamedForItsSite() throws {
        let page = "https://www.search.acme.internal/find?q=%s&src=yab"
        let own = try #require(EngineChoice.own("custom", custom: page))
        #expect(own.engine == .custom)
        #expect(own.name == "search.acme.internal")
        #expect(own.url(for: "q3 plan")?.absoluteString == "https://www.search.acme.internal/find?q=q3%20plan&src=yab")
        // One that doesn't hold up, or none, is Settings › Search's.
        #expect(EngineChoice.own("custom", custom: "not a page") == nil)
        #expect(EngineChoice.own("custom", custom: "https://%s.evil.com/") == nil)
        #expect(EngineChoice.space("custom", custom: nil) == .global)
    }

    @Test func theSpaceFileKeepsItAndOldOnesReadWithout() throws {
        let space = Space(id: Self.work, name: "Work", icon: "💼", ownSignIns: true, search: "custom",
                          searchCustom: "https://intra.example/s?q=%s")
        let back = try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(space))
        #expect(back == space)
        #expect(back.engine.name == "intra.example")
        let old = #"{"id":"6A1E4F0C-3B2D-4F77-9C1A-0E5D2B7A9F10","name":"Work","icon":"💼","ownSignIns":false}"#
        let read = try JSONDecoder().decode(Space.self, from: Data(old.utf8))
        #expect(read.search == nil && read.searchCustom == nil)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(read)) as? [String: Any]
        #expect(plain?["search"] == nil)
    }

    @Test func itSyncsWithTheSpaceAndOthersAreWrittenAsBefore() throws {
        let personal = Space(id: Space.firstID, name: "Personal", icon: "🏠", ownSignIns: false)
        let work = Space(id: Self.work, name: "Work", icon: "💼", ownSignIns: false, search: "custom",
                         searchCustom: "https://intra.example/s?q=%s")
        let written = SyncShapes.spaces([personal, work], orders: [:])
        #expect(written[Space.firstID.uuidString]?["search"] == nil)
        #expect(written[Space.firstID.uuidString]?["searchCustom"] == nil)
        #expect(written[Self.work.uuidString]?["search"]?.string == "custom")
        #expect(written[Self.work.uuidString]?["searchCustom"]?.string == "https://intra.example/s?q=%s")
        let records = written.map { Record(collection: SyncShapes.space, id: $0.key, fields: $0.value.filter { !$0.value.isNull }) }
        let read = SyncShapes.spaces(from: records)
        #expect(read.first { $0.id == Self.work }?.search == "custom")
        #expect(read.first { $0.id == Self.work }?.searchCustom == "https://intra.example/s?q=%s")
        #expect(read.first { $0.id == Space.firstID }?.search == nil)
        // Set back to the default: the field is left out, and the journal
        // takes it as gone.
        let journal = try Journal(path: nil, device: "space-search")
        _ = try journal.reconcile(SyncShapes.space, written)
        #expect(SyncShapes.spaces(from: journal.living(SyncShapes.space)).first { $0.id == Self.work }?.search == "custom")
        var plain = work
        plain.search = nil
        plain.searchCustom = nil
        _ = try journal.reconcile(SyncShapes.space, SyncShapes.spaces([personal, plain], orders: [:]))
        let after = SyncShapes.spaces(from: journal.living(SyncShapes.space)).first { $0.id == Self.work }
        #expect(after != nil)
        #expect(after?.search == nil)
        #expect(after?.searchCustom == nil)
    }

    @Test func theFieldSearchesWithTheSpaceOnScreen() throws {
        #expect(Store.testing)
        guard Store.testing else { return }
        _ = NSApplication.shared
        let previous = Spaces.read()
        defer { Spaces.write(previous) }
        let browser = Browser(windowID: UUID())
        defer { browser.letGo() }
        let home = UUID(), work = UUID()
        browser.spaces = [Space(id: home, name: "Home", icon: "🏠", ownSignIns: false),
                          Space(id: work, name: "Work", icon: "💼", ownSignIns: false)]
        browser.spaceID = home
        #expect(browser.searchEngine == .global)

        browser.setSpaceSearch(work, to: "kagi")
        #expect(browser.searchEngine == .global, "only the space it was set for")
        browser.spaceID = work
        #expect(browser.searchEngine.url(for: "words")?.host == "kagi.com")
        #expect(Spaces.read().first { $0.id == work }?.search == "kagi")

        // Other…: its page, kept while it is typed; Settings › Search's
        // until it holds up.
        browser.setSpaceSearch(work, to: "custom", custom: "https://intra")
        #expect(browser.searchEngine == .global)
        browser.setSpaceSearch(work, to: "custom", custom: "https://intra.example/s?q=%s")
        #expect(browser.searchEngine.url(for: "words")?.absoluteString == "https://intra.example/s?q=words")
        // A name that is no engine is no choice; back to the default.
        browser.setSpaceSearch(work, to: "altavista")
        #expect(browser.spaces.first { $0.id == work }?.search == nil)
        #expect(browser.spaces.first { $0.id == work }?.searchCustom == nil)
        #expect(browser.searchEngine == .global)
    }
}
