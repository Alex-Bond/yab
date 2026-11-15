import Foundation
import Testing
@testable import Fast

@MainActor
struct HistoryCompletionTests {
    private let now = Date(timeIntervalSince1970: 1_790_334_000)

    private func visit(_ key: String, count: Int, typed: Int? = nil) -> Visit {
        Visit(url: "https://\(key)", key: key, title: "", count: count, last: now, typed: typed)
    }

    @Test func deliberatelyChosenPageCanCompleteOneLetter() {
        let history = History([
            visit("x.com/home", count: 14_343, typed: 758),
            visit("x.com", count: 734, typed: 136),
        ])
        let offers = history.suggestions(for: "x", now: now)
        #expect(offers.first?.key == "x.com/home")
        #expect(history.completion(for: "x", among: offers) == ".com/home")
    }

    @Test func familiarDomainCanCompleteBelowAnUnchosenPage() {
        let history = History([
            visit("x.com/home", count: 14_343),
            visit("x.com", count: 734, typed: 1),
        ])
        let offers = history.suggestions(for: "x", now: now)
        #expect(offers.first?.key == "x.com/home")
        #expect(history.completion(for: "x", among: offers) == ".com")
    }

    @Test func linksAloneDoNotCompleteADeepPageFromOneLetter() {
        let history = History([visit("zebra.example.com/article", count: 1000, typed: 1)])
        let offers = history.suggestions(for: "z", now: now)
        #expect(history.completion(for: "z", among: offers) == nil)
    }

    @Test func knownUnambiguousDomainStillCompletesWithoutHistory() {
        let history = History([])
        let offers = history.suggestions(for: "x", now: now)
        #expect(history.completion(for: "x", among: offers) == ".com")
    }
}
