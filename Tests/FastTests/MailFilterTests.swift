import Foundation
import Testing
@testable import Fast
@testable import MailCore

struct MailFilterTests {
    private func rules(_ lines: [String]) -> [MailSplitSort.Rule] {
        lines.enumerated().map { n, line in
            MailSplitSort.Rule(MailList.Split(id: "filter\(n)", title: "", q: line, mode: .also))
        }
    }

    @Test func countsRespectOtherFiltersAndOnlyReportNewThreads() {
        let store = MailSplitTests().store()
        let unread = MailRule.line([MailRule(kind: "search", value: "is:unread")])
        let found = MailFilterCounts.counted(rules([
            "from:anna@fold.studio",
            "from:anna@fold.studio from:digest.example",
            "from:anna@fold.studio from:digest.example " + unread,
            "kind:invoice " + unread,
            "from:stripe.com",
        ]), in: [store], now: MailSplitTests.now)
        #expect(found == [.init(all: 2, added: 1), .init(all: 1, added: 0),
                          .init(all: 1, added: 1), .init(all: 1, added: 1)])
        _ = MailOps.archive(["anna"], in: store)
        let changed = MailFilterCounts.counted(rules(["", "from:anna@fold.studio", unread]), in: [store], now: MailSplitTests.now)
        #expect(changed == [.init(), .init(all: 1, added: 1)])
    }

    @Test func countsAcrossAccountsAndAcrossBitsetChunks() {
        let first = MailSplitTests().store()
        let second = MailSplitTests().store(me: "someone@other.io")
        let queries = Array(repeating: "from:anna@fold.studio", count: 130)
        let found = MailFilterCounts.counted(rules(["from:digest.example"] + queries),
                                            in: [first, second], now: MailSplitTests.now)
        #expect(found.count == 130)
        #expect(found.allSatisfy { $0 == .init(all: 2, added: 2) })
        let same = MailFilterCounts.counted(rules(["from:anna@fold.studio"] + queries),
                                           in: [first], now: MailSplitTests.now)
        #expect(same.allSatisfy { $0 == .init(all: 1, added: 0) })
    }

    @Test func libraryCountsAllThreadsButShowsOnlyTheNewestFive() throws {
        let fixture = MailSplitTests()
        let store = MailStore(file: MailStore.memory)
        store.set("me", MailSplitTests.me.address)
        store.put((0..<40).map { n in
            fixture.mail("m\(n)", "thread\(n)", from: "Anna <anna@fold.studio>", hours: Double(n),
                         labels: n == 0 ? [] : ["INBOX"], subject: "Message \(n)")
        })
        let found = try #require(MailSplitLibrary.previews(rules(["from:fold.studio"]),
                                                         in: [store], now: MailSplitTests.now)["filter0"])
        #expect(found.count == 39)
        #expect(found.rows.map(\.subject) == (1...5).map { "Message \($0)" })
    }

    @Test func librarySortsAcrossAccountsWithIdenticalThreadIDs() throws {
        let fixture = MailSplitTests()
        let first = fixture.store()
        let second = MailStore(file: MailStore.memory)
        second.set("me", "other@acme.io")
        second.put([fixture.mail("new", "anna", from: "Anna <anna@fold.studio>", hours: 0.5,
                                 labels: ["INBOX"], subject: "Newest")])
        let found = try #require(MailSplitLibrary.previews(rules(["from:fold.studio"]),
                                                         in: [first, second], now: MailSplitTests.now)["filter0"])
        #expect(found.count == 2)
        #expect(found.rows.map(\.subject) == ["Newest", "Hello"])
    }
}
