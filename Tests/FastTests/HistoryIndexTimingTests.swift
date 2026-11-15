import Combine
import Foundation
import Testing
@testable import Fast

/// History's index is made off the main thread a moment after the last
/// change (docs/main-thread-budget.md): a page load among tens of thousands
/// of places neither lists them all nor copies them on the main thread, and
/// the index still ends up holding what was added, never an older one.
@MainActor struct HistoryIndexTimingTests {
    private func big(_ count: Int) -> History {
        let now = Date()
        return History((0..<count).map { index in
            Visit(url: "https://bulk\(index % 300).example/page-\(index)", key: "bulk\(index % 300).example/page-\(index)",
                  title: "Bulk page \(index)", count: 1 + index % 5, last: now.addingTimeInterval(-Double(index) * 60), typed: nil)
        })
    }

    private func ready(_ history: History) async {
        var waits: AnyCancellable?
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            waits = history.indexReady.first().sink { _ in done.resume() }
        }
        waits?.cancel()
    }

    @Test func aPlaceVisitedNowIsFoundOnceTheIndexIsBack() async {
        let history = big(5_000)
        history.record(URL(string: "https://zebrafish.example/tank")!, title: "Zebrafish tank")
        // Asked at once, the index is on its way and nothing old is offered.
        #expect(history.isIndexing)
        await ready(history)
        #expect(history.suggestions(for: "zebraf").first?.key.hasPrefix("zebrafish.example") == true)
    }

    @Test func manyChangesInARowMakeOneIndexWithAllOfThem() async {
        let history = big(5_000)
        var sent = 0
        let counting = history.indexReady.sink { sent += 1 }
        defer { counting.cancel() }
        for n in 0..<20 { history.record(URL(string: "https://quick\(n).example/")!, title: "Quick \(n)") }
        await ready(history)
        // Give a stray second build time to land, if there were one.
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(sent == 1)
        #expect(history.suggestions(for: "quick19").first?.key == "quick19.example")
    }

    @Test func forgettingDropsAPlaceFromFrequentAtOnce() {
        let now = Date()
        let history = History((0..<12).map { index in
            Visit(url: "https://often\(index).example/", key: "often\(index).example", title: "Often \(index)",
                  count: 40 - index, last: now, typed: nil)
        })
        #expect(history.frequent(8, now: now).contains { $0.key == "often0.example" })
        history.forget("often0.example")
        #expect(!history.frequent(8, now: now).contains { $0.key == "often0.example" })
    }
}
