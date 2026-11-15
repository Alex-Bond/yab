import XCTest
@testable import YabPhone

@MainActor
final class FieldSearchQueryTests: XCTestCase {
    private var oldMotion = false
    override func setUp() { oldMotion = Motion.disabled; Motion.disabled = true }
    override func tearDown() { Motion.disabled = oldMotion }

    private func open(_ address: String, privateMode: Bool = false) -> AppModel {
        let world = World(name: "google-query", space: "public", spaces: [
            Space(id: "public", name: "Public", emoji: "", tint: RGB(240, 240, 240))
        ])
        let app = AppModel(world: world, fixturesEnabled: false, privateLockEnabled: { false })
        app.browser.open(PageFixtures.liveTab(for: URL(string: address)!, isPrivate: privateMode))
        app.surfaces.openField(.address)
        return app
    }

    func testGoogleResultsOpenWithDecodedSearchWordsSelected() {
        let cases = [
            ("https://www.google.com/search?q=lisbon+weather+october&ie=UTF-8", "lisbon weather october"),
            ("https://google.com/search?source=hp&q=C%2B%2B+%26+Swift", "C++ & Swift"),
            ("https://www.google.ru/search?q=%D0%BF%D0%BE%D0%B3%D0%BE%D0%B4%D0%B0+%D0%B7%D0%B0%D0%B2%D1%82%D1%80%D0%B0", "погода завтра"),
            ("https://www.google.co.uk/search?q=caf%C3%A9%20near%20me", "café near me"),
            ("https://www.google.co.jp/search?q=%252B+%2B", "%2B +")
        ]
        for (url, words) in cases {
            let app = open(url)
            XCTAssertEqual(app.field.text, words, "Google results must show the query instead of the URL")
            XCTAssertTrue(app.field.showsAddress, "the first edit replaces the selected query")
            XCTAssertEqual(app.field.words, "")
            XCTAssertEqual(app.browser.tab?.navigationURL?.absoluteString, url, "the page and share URL stay exact")
        }
    }

    func testOtherPagesAndEmptyOrAmbiguousQueriesKeepTheirExactAddress() {
        for url in ["https://example.com/search?q=words", "https://www.google.com/maps?q=words",
                    "https://mail.google.com/search?q=words", "https://google.com.example.net/search?q=words",
                    "https://google.example/search?q=words", "https://www.google.com/search?q=",
                    "https://www.google.com/search?source=hp", "https://www.google.com/search?q=one&q=two",
                    "https://owned@www.google.com/search?q=words", "https://www.google.com/url?q=https%3A%2F%2Fexample.com"] {
            XCTAssertEqual(open(url).field.text, url)
        }
    }

    func testQueryCanBeEditedWithoutSavingAnUnchangedDraft() throws {
        let app = open("https://www.google.com/search?q=lisbon+weather")
        let id = try XCTUnwrap(app.browser.tab?.id)
        app.field.editAddress()
        XCTAssertEqual(app.field.text, "lisbon weather")
        XCTAssertNil(app.field.draft(for: id), "the original query is not an unfinished edit")
        app.field.typed("lisbon weather october")
        app.surfaces.closeField()
        app.surfaces.openField(.address)
        XCTAssertEqual(app.field.text, "lisbon weather october", "an unfinished edit still wins over the original query")
        XCTAssertFalse(app.field.showsAddress)
        app.choose(try XCTUnwrap(app.fieldRows.first { $0.action == .search }))
        XCTAssertEqual(app.browser.tab?.id, id)
        let url = try XCTUnwrap(app.browser.tab?.navigationURL)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "lisbon weather october")
    }

    func testPrivateGoogleQueryIsShownButItsEditsAreNotKept() throws {
        let app = open("https://www.google.com/search?q=private+words", privateMode: true)
        let id = try XCTUnwrap(app.browser.tab?.id)
        XCTAssertEqual(app.field.text, "private words")
        app.field.typed("private edit")
        XCTAssertNil(app.field.draft(for: id))
        app.surfaces.closeField()
        app.surfaces.openField(.address)
        XCTAssertEqual(app.field.text, "private words")
        XCTAssertTrue(app.field.pageIsPrivate)
    }
}
