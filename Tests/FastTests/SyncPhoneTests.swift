import Foundation
import SyncKit
import Testing
@testable import Fast

/// Send to iPhone (OpenOnPhone): the iPhone's own capability, the page's
/// record, taken once, refused when stale or interrupted.
struct SyncPhoneTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let page = URL(string: "https://example.com/essays/great-work?ref=mac#part-2")!

    // MARK: - the iPhone's capability

    @Test func onlyADevicesOwnRecordSaysItAnswersAssistants() throws {
        let phone = try Journal(path: nil, device: "phone")
        let own = try phone.change(.init(collection: OpenOnMac.capability, id: "phone"), OpenOnPhone.capability(device: "phone"))
        #expect(AssistantApprovalRecords.answers(own, device: "phone"))
        // An iPhone build from before approvals: pages, no answers.
        let older = try phone.change(.init(collection: OpenOnMac.capability, id: "old-phone"),
                                     ["device": "old-phone", "kind": "iphone", "open": .number(Double(OpenOnPhone.version))])
        #expect(!AssistantApprovalRecords.answers(older, device: "old-phone"))
        let mac = try Journal(path: nil, device: "mac")
        let forged = try mac.change(.init(collection: OpenOnMac.capability, id: "forged"), OpenOnPhone.capability(device: "forged"))
        #expect(!AssistantApprovalRecords.answers(forged, device: "forged"))
        let macs = try mac.change(.init(collection: OpenOnMac.capability, id: "mac"), SyncChats.capability(device: "mac"))
        #expect(AssistantApprovalRecords.answers(macs, device: "mac"))
    }

    @Test func onlyTheIPhonesOwnStampedRecordSaysItTakesPages() throws {
        let phone = try Journal(path: nil, device: "phone")
        let own = try phone.change(.init(collection: OpenOnMac.capability, id: "phone"), OpenOnPhone.capability(device: "phone"))
        #expect(OpenOnPhone.supports(own, device: "phone"))
        #expect(!OpenOnPhone.supports(own, device: "other-phone"))
        // A Mac's journal takes it as the iPhone wrote it, stamps and all.
        let mac = try Journal(path: nil, device: "mac")
        _ = try mac.receive([(record: own, version: 1)])
        #expect(OpenOnPhone.supports(mac.record(own.key), device: "phone"))
        // Written for it by another device: not the iPhone's word.
        let forged = try mac.change(.init(collection: OpenOnMac.capability, id: "forged-phone"), OpenOnPhone.capability(device: "forged-phone"))
        #expect(!OpenOnPhone.supports(forged, device: "forged-phone"))
        // A Mac's own commandcap says `open` too, for Open on Mac: not a phone's.
        let macs = try mac.change(.init(collection: OpenOnMac.capability, id: "mac"), SyncChats.capability(device: "mac"))
        #expect(OpenOnMac.supports(macs, device: "mac"))
        #expect(!OpenOnPhone.supports(macs, device: "mac"))
        // Removed: no longer offered.
        try phone.remove(own.key)
        #expect(!OpenOnPhone.supports(phone.record(own.key), device: "phone"))
    }

    // MARK: - a page for the iPhone

    private func sent(_ journal: Journal, id: String = "page-one", to device: String = "phone", at: Date? = nil,
                      title: String? = "How to Do Great Work") throws -> Record {
        try journal.change(.init(collection: "send", id: id),
                           OpenOnMac.fields(device: device, sender: "mac", url: page, at: at ?? now, space: UUID().uuidString, title: title))
    }

    @Test func aPageForTheIPhoneCarriesItsTitleAndSpaceAndIsTakenOnce() throws {
        let journal = try Journal(path: nil, device: "phone")
        let record = try sent(journal)
        #expect(record["title"]?.string == "How to Do Great Work")
        #expect(record["kind"]?.string == "open")
        #expect(OpenOnPhone.waiting(journal.all("send"), device: "phone").map(\.id) == ["page-one"])
        #expect(OpenOnPhone.waiting(journal.all("send"), device: "mac").isEmpty)
        var opened: [OpenOnPhone.Arrival] = []
        #expect(try OpenOnPhone.take(record, in: journal, device: "phone", at: now) { opened.append($0) })
        #expect(opened.count == 1)
        #expect(opened.first?.url == page)
        #expect(opened.first?.title == "How to Do Great Work")
        #expect(opened.first?.sender == "mac")
        #expect(opened.first?.space != nil)
        let taken = try #require(journal.record(record.key))
        #expect(taken["state"]?.string == "taken")
        // Again, a replay, or the Mac reading it: nothing opens twice.
        #expect(try OpenOnPhone.take(taken, in: journal, device: "phone", at: now) { opened.append($0) } == false)
        #expect(OpenOnPhone.waiting(journal.all("send"), device: "phone").isEmpty)
        #expect(opened.count == 1)
        // The Mac's own Open on Mac pass reads past a page for the iPhone.
        var macOpened = 0
        #expect(try OpenOnMac.consume(taken, in: journal, device: "mac", at: now) { _ in macOpened += 1 } == false)
        #expect(macOpened == 0)
    }

    @Test func aStalePageIsRefusedAndNeverOpened() throws {
        let journal = try Journal(path: nil, device: "phone")
        let late = try sent(journal, id: "late", at: now.addingTimeInterval(-OpenOnMac.lifetime - 60))
        var calls = 0
        #expect(try OpenOnPhone.take(late, in: journal, device: "phone", at: now) { _ in calls += 1 })
        #expect(calls == 0)
        #expect(journal.record(late.key)?["state"]?.string == "expired")
        // From the future (a clock far off): refused as invalid.
        let ahead = try sent(journal, id: "ahead", at: now.addingTimeInterval(3600))
        try OpenOnPhone.take(ahead, in: journal, device: "phone", at: now) { _ in calls += 1 }
        #expect(calls == 0)
        #expect(journal.record(ahead.key)?["state"]?.string == "failed")
    }

    @Test func oneLeftOpeningByARelaunchIsFailedNotOpened() throws {
        let journal = try Journal(path: nil, device: "phone")
        let record = try sent(journal)
        #expect(try journal.claimCommand(record, fields: ["state": "opening"]))
        let claimed = try #require(journal.record(record.key))
        #expect(OpenOnPhone.waiting(journal.all("send"), device: "phone").map(\.id) == [record.id])
        var calls = 0
        try OpenOnPhone.take(claimed, in: journal, device: "phone", at: now) { _ in calls += 1 }
        #expect(calls == 0)
        #expect(journal.record(record.key)?["state"]?.string == "failed")
    }

    @Test func freshPagesOpenAtOnceAndOlderOnesWait() throws {
        let journal = try Journal(path: nil, device: "phone")
        let arrival = try #require(OpenOnPhone.arrival(try sent(journal)))
        #expect(arrival.fresh(at: now.addingTimeInterval(60)))
        #expect(!arrival.fresh(at: now.addingTimeInterval(OpenOnPhone.fresh + 1)))
        // No title from the Mac: its host.
        let bare = try #require(OpenOnPhone.arrival(try sent(journal, id: "bare", title: nil)))
        #expect(bare.title == "example.com")
    }

    @Test func titlesAreOneShortLine() {
        #expect(OpenOnMac.title(.string("  Two\nlines\there  ")) == "Two lines here")
        #expect(OpenOnMac.title(.string(String(repeating: "a", count: 500)))?.count == 200)
        #expect(OpenOnMac.title(.string("   ")) == nil)
        #expect(OpenOnMac.title(.number(3)) == nil)
    }
}
