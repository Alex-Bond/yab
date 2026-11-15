import Foundation
import Testing
@testable import Fast

// A private tab is nothing an agent sees: the chat never takes it as the
// page a message is about (its chip, its ideas, its picture, the + list),
// and ⌘J offers no site actions on it, while the same page in an ordinary
// tab is offered as before.
@MainActor
struct PrivateTabAgentTests {
    static func tab(_ address: String, shy: Bool) -> Fast.Tab {
        let tab = Fast.Tab(shy: shy)
        tab.restore(url: URL(string: address)!, title: "A page")
        return tab
    }

    @Test func chatTakesAnOrdinaryPage() {
        #expect(ChatComposer.page(Self.tab("https://example.com/", shy: false)) != nil)
    }

    @Test func chatNeverTakesAPrivatePage() {
        #expect(ChatComposer.page(Self.tab("https://example.com/", shy: true)) == nil)
    }

    @Test func noSiteActionsOnAPrivateTab() {
        let open = Self.tab("https://github.com/example/yab/pull/1", shy: false)
        let shy = Self.tab("https://github.com/example/yab/pull/1", shy: true)
        #expect(Hints.shared.actions(on: shy).isEmpty)
        // The same page, not private, keeps what its skill offers.
        #expect(Hints.shared.actions(on: open).count == Skills.actions(for: open.address).count)
    }
}
