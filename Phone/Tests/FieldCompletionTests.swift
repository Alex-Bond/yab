import XCTest
@testable import YabPhone

/// The best row's address written on after the words.
final class FieldCompletionTests: XCTestCase {
    private func site(_ host: String?) -> WordRow {
        WordRow(action: .site(key: "k"), icon: .favicon(key: "k", host: host), title: "Netflix", subtitle: "",
                key: .go, group: .sites)
    }

    func testSiteHostIsWrittenOn() {
        XCTAssertEqual(site("netflix.com").completion(after: "net"), "flix.com")
        XCTAssertEqual(site("www.netflix.com").completion(after: "Net"), "flix.com")
        XCTAssertEqual(site("www.netflix.com").completion(after: "ww"), "w.netflix.com")
    }

    func testNothingWhenTheWordsAreNotTheHostsStart() {
        XCTAssertNil(site("netflix.com").completion(after: "flix"))
        XCTAssertNil(site("netflix.com").completion(after: "netflix.com"))
        XCTAssertNil(site(nil).completion(after: "net"))
    }

    func testPagesAndNotSearches() {
        let page = WordRow(action: .place(url: "https://news.ycombinator.com/item?id=1"), icon: .globe,
                           title: "HN", subtitle: "", key: .go, group: .sites)
        XCTAssertEqual(page.completion(after: "news.y"), "combinator.com")
        let search = WordRow(action: .search, icon: .magnifier, title: "n", subtitle: "", key: .search, group: .web)
        XCTAssertNil(search.completion(after: "n"))
    }
}
