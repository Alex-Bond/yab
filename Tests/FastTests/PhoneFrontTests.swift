import Foundation
import SyncKit
import Testing
@testable import Fast

/// From iPhone (PhoneFront): an iPhone's page in front, as its presence says
/// it, offered on the Mac for a minute, and its row under the field.
struct PhoneFrontTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func presence(kind: String? = "iphone", url: String = "https://example.com/reading", changed: Date? = nil,
                          tab: String? = "4F2B1C3A-4E5D-4A7B-9C8D-0E1F2A3B4C5D") -> Record {
        var fields: [String: Value] = ["name": "Mira’s iPhone", "at": .number(now.timeIntervalSince1970), "url": .string(url),
                                       "title": "Reading on the train"]
        if let kind { fields["kind"] = .string(kind) }
        if let tab { fields["tab"] = .string(tab) }
        fields.merge(PhoneFront.fields(space: "6A1E4F0C-3B2D-4F77-9C1A-0E5D2B7A9F10", changed: changed ?? now)) { _, new in new }
        return Record(collection: "presence", id: "phone", fields: fields)
    }

    @Test func anIPhonesPresenceSaysItsPageAndWhenItChanged() throws {
        let read = try #require(PhoneFront.page(device: "phone", record: presence()))
        #expect(read.url.absoluteString == "https://example.com/reading")
        #expect(read.title == "Reading on the train")
        #expect(read.name == "Mira’s iPhone")
        #expect(read.space == "6A1E4F0C-3B2D-4F77-9C1A-0E5D2B7A9F10")
        #expect(read.changed == now)
        // A Mac's presence, an address only that device reaches, no page: none.
        #expect(PhoneFront.page(device: "mac", record: presence(kind: nil)) == nil)
        #expect(PhoneFront.page(device: "phone", record: presence(url: "http://localhost:5173")) == nil)
        #expect(PhoneFront.page(device: "phone", record: presence(url: "https://user:pass@example.com")) == nil)
        var without = presence()
        without.fields["changed"] = nil
        #expect(PhoneFront.page(device: "phone", record: without) == nil)
    }

    @Test func fromIPhoneIsOfferedForAMinuteUnlessTheMacShowsIt() throws {
        let read = try #require(PhoneFront.page(device: "phone", record: presence()))
        #expect(PhoneFront.offered(read, now: now.addingTimeInterval(30), front: nil, frontTab: nil))
        #expect(!PhoneFront.offered(read, now: now.addingTimeInterval(PhoneFront.window + 1), front: nil, frontTab: nil))
        // The same tab or the same page in front on the Mac: nothing to offer.
        #expect(!PhoneFront.offered(read, now: now, front: nil, frontTab: "4f2b1c3a-4e5d-4a7b-9c8d-0e1f2a3b4c5d"))
        #expect(!PhoneFront.offered(read, now: now, front: URL(string: "http://www.example.com/reading/")!, frontTab: nil))
        #expect(PhoneFront.offered(read, now: now, front: URL(string: "https://example.com/other")!, frontTab: UUID().uuidString))
        // Two iPhones: the page that changed last.
        let older = try #require(PhoneFront.page(device: "old", record: presence(url: "https://example.org/older", changed: now.addingTimeInterval(-20))))
        #expect(PhoneFront.offer([older, read], now: now.addingTimeInterval(5), front: nil, frontTab: nil)?.device == "phone")
    }

    @MainActor
    @Test func fromIPhoneIsARowOfItsOwnBesideACopiedLink() throws {
        let read = try #require(PhoneFront.page(device: "phone", record: presence()))
        let row = SyncPhones.hint(read)
        #expect(row.id.hasPrefix("noticed.phone."))
        #expect(row.title == "Reading on the train")
        #expect(row.detail == "From Mira’s iPhone")
        #expect(row.url == read.url)
        #expect(row.phone == now)
        #expect(Noticing.Kind.of(row) == .phone)
        let habit = Hint(id: "habit.x", icon: .site("x.com"), title: "X", detail: "You open it most mornings", url: URL(string: "https://x.com"),
                         source: .habit)
        #expect(Hints.order(found: [], noticed: [habit, row], setup: [], now: now).map(\.id) == [row.id, habit.id])
        #expect(Hints.overPage([habit, row], now: now).map(\.id) == [row.id])
        // Turned off with Don't Show Things Like This.
        #expect(Noticing.Off(kinds: [Noticing.Kind.phone.rawValue]).hides(row))
    }
}
