import Foundation
import Testing
@testable import Fast

// Bookmarks among the plain field's places (History.keep(bookmarks:)):
// ranked as history ranks, a bookmark as two visits, each place once.
@MainActor
struct BookmarkSuggestionsTests {
    private let now = Date(timeIntervalSince1970: 1_790_334_000)

    private func visit(_ key: String, title: String = "", count: Int) -> Visit {
        Visit(url: "https://\(key)", key: key, title: title, count: count, last: now)
    }

    private func site(_ title: String, _ address: String) -> Bookmark {
        .site(title, URL(string: address)!)
    }

    @Test func aBookmarkNeverVisitedIsOfferedByItsAddress() {
        let history = History([visit("github.com", count: 3)])
        history.keep(bookmarks: [.folder("Work", [site("Linear", "https://linear.app/team")])], revision: 1)
        let offers = history.suggestions(for: "lin", now: now)
        #expect(offers.first?.key == "linear.app/team")
        #expect(offers.first?.bookmarked == true)
        #expect(offers.first?.kind == .visited)
        #expect(!history.remembers("linear.app/team"))
    }

    @Test func aBookmarkIsFoundByItsTitle() {
        let history = History([])
        history.keep(bookmarks: [site("Quarterly Planning Doc", "https://docs.google.com/document/d/abc")], revision: 1)
        #expect(history.suggestions(for: "quarterly pl", now: now).first?.key == "docs.google.com/document/d/abc")
        #expect(!history.suggestions(for: "pl", now: now).contains { $0.bookmarked })
    }

    @Test func aVisitedBookmarkIsOneRowRankedTwoVisitsHigher() {
        let history = History([
            visit("figma.com/files/a", title: "Design", count: 3),
            visit("figma.com/files/b", title: "Design", count: 4),
        ])
        #expect(history.suggestions(for: "figma.com/f", now: now).map(\.key) == ["figma.com/files/b", "figma.com/files/a"])
        history.keep(bookmarks: [site("Design A", "https://figma.com/files/a"), site("Again", "https://www.figma.com/files/a")], revision: 1)
        let offers = history.suggestions(for: "figma.com/f", now: now)
        #expect(offers.map(\.key) == ["figma.com/files/a", "figma.com/files/b"])
        #expect(offers.map(\.bookmarked) == [true, false])
        // Its title stays the page's own, as last seen.
        #expect(offers.first?.title == "Design")
        // Found by the page's title, counted the same, and once.
        let titled = history.suggestions(for: "design", now: now)
        #expect(titled.map(\.key) == ["figma.com/files/a", "figma.com/files/b"])
        #expect(titled.first?.bookmarked == true)
    }

    @Test func aBookmarkStandsBelowAPlaceGoneToOften() {
        let history = History([visit("news.ycombinator.com", count: 30)])
        history.keep(bookmarks: [site("News", "https://newsletter.example.com/")], revision: 1)
        #expect(history.suggestions(for: "news", now: now).map(\.key) == ["news.ycombinator.com", "newsletter.example.com"])
    }

    @Test func aBookmarkedSiteTheFieldKnowsIsListedOnce() {
        let history = History([])
        history.keep(bookmarks: [site("YouTube", "https://youtube.com/")], revision: 1)
        let offers = history.suggestions(for: "youtube", now: now)
        #expect(offers.filter { $0.key == "youtube.com" }.count == 1)
        #expect(offers.first { $0.key == "youtube.com" }?.bookmarked == true)
    }

    @Test func changedBookmarksAreReadAgainAndTheSameRevisionIsNot() {
        let history = History([])
        history.keep(bookmarks: [site("Alpha", "https://alpha.dev/")], revision: 1)
        #expect(history.suggestions(for: "alp", now: now).first?.key == "alpha.dev")
        history.keep(bookmarks: [], revision: 1)
        #expect(history.suggestions(for: "alp", now: now).first?.key == "alpha.dev")
        history.keep(bookmarks: [], revision: 2)
        #expect(!history.suggestions(for: "alp", now: now).contains { $0.bookmarked })
    }

    @Test func folderAndNonWebBookmarksOfferNothing() {
        let history = History([])
        history.keep(bookmarks: [.folder("Recipes", []), site("Script", "javascript:alert(1)")], revision: 1)
        #expect(!history.suggestions(for: "rec", now: now).contains { $0.bookmarked })
        #expect(!history.suggestions(for: "scri", now: now).contains { $0.bookmarked })
    }
}
