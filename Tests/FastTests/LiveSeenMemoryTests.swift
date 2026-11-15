import Foundation
import Testing
@testable import Fast

struct LiveSeenMemoryTests {
    private func item(_ n: Int, list: String? = nil, quote: String? = nil) -> LiveItem {
        LiveItem(key: "linear/ISSUE-\(n)", url: URL(string: "https://linear.app/team/issue/ISSUE-\(n)")!,
                 title: "Issue \(n)", group: "Team", words: .mention, updated: nil,
                 list: list, quote: quote)
    }

    @Test func repeatedRefreshesKeepOnlyRecentResults() {
        var cache = LiveSeenCache(limit: 64)
        for pass in 0..<1000 {
            cache.note((pass * 20..<(pass + 1) * 20).map { item($0, quote: String(repeating: "x", count: 1200)) })
            #expect(cache.count <= 64)
        }
        #expect(cache.item("linear/ISSUE-0") == nil)
        #expect(cache.item("linear/ISSUE-19999")?.title == "Issue 19999")
    }

    @Test func openTabsKeepBothSayingsPastTheLimitAndCanBeReleased() {
        var cache = LiveSeenCache(limit: 2)
        cache.note([item(1, quote: "assigned"), item(1, list: "mentions", quote: "mentioned")], news: ["mentions"])
        for n in 2..<100 {
            cache.note([item(n)], protecting: ["linear/ISSUE-1"])
        }
        #expect(cache.item("linear/ISSUE-1")?.quote == "assigned")
        #expect(cache.item("linear/ISSUE-1", news: true)?.quote == "mentioned")
        cache.note([item(100), item(101)])
        #expect(cache.count == 2)
        #expect(cache.item("linear/ISSUE-1") == nil)
    }

    @Test func onlyProtectedEntriesMayExceedTheLimit() {
        var cache = LiveSeenCache(limit: 2)
        let all = (0..<10).map { item($0) }
        cache.note(all, protecting: Set(all.map(\.key)))
        #expect(cache.count == 10)
        cache.prune(protecting: ["linear/ISSUE-0"])
        #expect(cache.count == 2)
        #expect(cache.item("linear/ISSUE-0") != nil)
    }

    @Test func readsAndUpdatesRefreshRecencyAndFallbackStillWorks() {
        var cache = LiveSeenCache(limit: 2)
        cache.note([item(1), item(2)])
        #expect(cache.item("linear/ISSUE-1", news: true) != nil)
        cache.note([item(3)])
        #expect(cache.item("linear/ISSUE-2") == nil)
        cache.note([item(1, quote: "updated")])
        #expect(cache.item("linear/ISSUE-1")?.quote == "updated")
        #expect(cache.count == 2)
    }
}
