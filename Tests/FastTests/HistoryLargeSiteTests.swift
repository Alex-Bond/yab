import Foundation
import Testing
@testable import Fast

// The field's places from a history with many pages at one site (row 1165):
// only a site's best few are counted on a key, and the rows are the same as
// when every page was.
@MainActor
struct HistoryLargeSiteTests {
    private let now = Date(timeIntervalSince1970: 1_790_334_000)

    private func visit(_ key: String, count: Int, title: String = "") -> Visit {
        Visit(url: "https://\(key)", key: key, title: title, count: count, last: now)
    }

    /// 1,500 pages at one site, each gone to a different number of times,
    /// its front door among them, and a few pages elsewhere.
    private func site() -> History {
        var visits = (0..<1_500).map { visit("bulk.example/page-\($0)", count: 1 + ($0 * 7919) % 1_500) }
        visits.append(visit("bulk.example", count: 1_600))
        visits.append(visit("other.example/bulk.example/page-1", count: 900))
        return History(visits)
    }

    @Test func theBestPagesOfABigSiteLead() {
        let offers = site().suggestions(for: "bulk", now: now)
        // The front door first (a root counts 1.5 more), then the four
        // pages gone to most.
        let pages = (0..<1_500).sorted { (1 + ($0 * 7919) % 1_500) > (1 + ($1 * 7919) % 1_500) }.prefix(4)
        #expect(offers.map(\.key) == ["bulk.example"] + pages.map { "bulk.example/page-\($0)" })
    }

    @Test func aBookmarkedPagePastTheFirstFewStillCounts() {
        // Its two visits more (History.markWeight) bring the sixth page up
        // beside the fourth; the fourth keeps its place by its address.
        let counts = ["a": 20, "b": 19, "c": 18, "d": 17, "e": 16, "f": 15, "g": 14, "h": 13]
        let history = History(counts.map { visit("bm.example/" + $0.key, count: $0.value) })
        history.keep(bookmarks: [.site("F", URL(string: "https://bm.example/f")!)], revision: 1)
        let offers = history.suggestions(for: "bm", now: now)
        #expect(offers.map(\.key) == ["a", "b", "c", "d", "f"].map { "bm.example/" + $0 })
        #expect(offers.last?.bookmarked == true)
    }

    @Test func pagesAsGoodAsTheFifthAreStillWeighed() {
        // Twenty pages gone to alike: the shortest addresses win the tie,
        // wherever they sit in the site's order.
        let visits = (0..<20).map { visit("tie.example/" + String(repeating: "a", count: 20 - $0), count: 2) }
        let offers = History(visits).suggestions(for: "tie", now: now)
        #expect(offers.map(\.key) == (1...5).map { "tie.example/" + String(repeating: "a", count: $0) })
    }

    @Test func wordsWithASlashFindOnlyThatSitesPages() {
        let offers = site().suggestions(for: "bulk.example/page-1", now: now)
        #expect(!offers.isEmpty)
        #expect(offers.allSatisfy { $0.key.hasPrefix("bulk.example/page-1") })
        #expect(site().suggestions(for: "/page-1", now: now).isEmpty)
        #expect(site().suggestions(for: "bulk.example/missing", now: now).isEmpty)
        #expect(site().suggestions(for: "bulk.example/page-1499", now: now).map(\.key) == ["bulk.example/page-1499"])
    }

    @Test func boundsKeepBookmarksRootsAndFutureVisits() {
        var places = (0..<1_500).map { visit("bulk.example/page-\($0)", count: 1 + ($0 * 7919) % 1_500) }
        places.append(visit("bulk.example", count: 1_499))
        places.append(Visit(url: "https://bulk.example/future", key: "bulk.example/future", title: "",
                            count: 1_499, last: now.addingTimeInterval(86_400 * 90)))
        let marked = places.first { $0.count == 1_497 }!.key
        let history = History(places)
        history.keep(bookmarks: [.site("Saved", URL(string: "https://" + marked)!)], revision: 1)
        // Compare every page, without the index's bounds, at different dates.
        // Future visits do not decay until their date, so ordering at index
        // creation cannot be assumed to hold for all of these queries.
        for days in [-30.0, 0, 30, 120] {
            let date = now.addingTimeInterval(days * 86_400)
            for needle in ["bu", "bulk.example/", "bulk.example/page-1", "bulk.example/page-1499", "bulk.example/missing"] {
                let scored = places.filter { $0.key.hasPrefix(needle) }.map { place in
                    (place.key, 10 + Double(place.count) * exp(-max(0, date.timeIntervalSince(place.last)) / (86_400 * 30))
                     + (place.key == marked ? History.markWeight : 0) + (place.key.contains("/") ? 0 : 1.5))
                }.sorted {
                    if $0.1 != $1.1 { return $0.1 > $1.1 }
                    if $0.0.count != $1.0.count { return $0.0.count < $1.0.count }
                    return $0.0 < $1.0
                }
                for limit in [1, 5, 40] {
                    #expect(history.suggestions(for: needle, limit: limit, now: date).map(\.key)
                            == scored.prefix(limit).map(\.0), "\(needle), day \(days), limit \(limit)")
                }
            }
        }
    }

    @Test func hostMasksKeepCanonicallyEquivalentLetters() {
        let composed = "café.example"
        let decomposed = "cafe\u{301}.example"
        for (host, needle) in [(composed, decomposed), (decomposed, composed)] {
            let history = History([visit(host, count: 4)])
            #expect(history.suggestions(for: needle, now: now).map(\.key) == [host])
        }
        // A mask is only a rejection filter; the actual text still decides.
        #expect(!History([visit("ba.example", count: 4)]).suggestions(for: "ab", now: now).contains { $0.key == "ba.example" })
    }

    @Test func invalidAddressesDoNotHideUsableRowsBelowTheBound() {
        let valid = (0..<5).map { visit("bulk.example/page-\($0)", count: 10 - $0) }
        let invalid = (0..<5).map {
            Visit(url: "http://[invalid", key: "bulk.example/bad-\($0)", title: "", count: 1_000, last: now)
        }
        let history = History(valid + invalid)
        #expect(history.suggestions(for: "bulk", now: now).map(\.key) == valid.map(\.key))
        #expect(history.suggestions(for: "bulk.example/", now: now).map(\.key) == valid.map(\.key))
    }

    @Test func punctuatedQueriesStillMatchAddressesAndPlainWordsMatchTitles() {
        let history = History([visit("video.example/watch", count: 4, title: "YouTube: watch, don't miss it")])
        #expect(history.suggestions(for: "youtube watch", now: now).map(\.key) == ["video.example/watch"])
        #expect(history.suggestions(for: "youtube/watch", now: now).isEmpty)
        #expect(history.suggestions(for: "video.example/wa", now: now).map(\.key) == ["video.example/watch"])
        #expect(history.suggestions(for: "don't", now: now).isEmpty)
    }
}
