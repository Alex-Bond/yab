import Foundation
import Testing
@testable import Fast

// A middle click or a ⌘-click with the tabs out of sight: the corner names
// what opened behind the page and goes to it (#239, register 1168).
struct OpenedBehindTests {
    private let pricing = URL(string: "https://www.example.com/pricing")!

    @Test func namesTheLinksOwnWords() {
        #expect(Browser.openedName(pricing, label: "  Pricing\n ") == "Pricing")
    }

    @Test func withoutWordsNamesTheSite() {
        #expect(Browser.openedName(pricing, label: nil) == "example.com")
        #expect(Browser.openedName(pricing, label: "") == "example.com")
        // A link that reads as its own address: the site reads better.
        #expect(Browser.openedName(pricing, label: "https://www.example.com/pricing") == "example.com")
    }

    @Test func aLongNameIsCutToFit() {
        let name = Browser.openedName(pricing, label: "A very long link title that goes on and on") { $0.count <= 20 }
        #expect(name.count <= 20)
        #expect(name.hasPrefix("A very"))
        #expect(name.hasSuffix("\u{2026}"))
    }

    @Test func itWearsThePageAndOffersGoThere() {
        let id = UUID()
        let say = Say.toast("Pricing", mark: nil, undo: true, act: "Go There", page: id)
        #expect(say.mark == .page(id))
        #expect(say.head == "Pricing")
        #expect(say.tail == .act("Go There"))
    }
}
