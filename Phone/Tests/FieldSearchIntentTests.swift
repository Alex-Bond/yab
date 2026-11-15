import XCTest
@testable import YabPhone

@MainActor
final class FieldSearchIntentTests: XCTestCase {
    private let searches = [
        "Nintendo Switch", "iPhone 17 Pro", "Nintendo Switch?", "best coffee beans",
        "lisbon weather", "lisbon weather?", "best espresso grinder under 300 dollars",
        "how to center a div", "HOW TO reset AirPods?", "where to buy coffee",
        "what to see in lisbon", "weather?", "what is", "C++ & Swift", "café near me",
    ]
    private let questions = [
        "how do I reset my AirPods", "How do I reset my AirPods?", "is figma down",
        "what is the weather in lisbon", "can you explain this page?", "why not?",
    ]
    private var oldMotion = false
    private var oldChats = false
    private var oldActiveMode: Surfaces.FieldMode?

    override func setUp() {
        oldMotion = Motion.disabled; Motion.disabled = true
        oldChats = NewTabPager.shared.onChats; NewTabPager.shared.onChats = false
        oldActiveMode = NewTabPager.shared.activeFieldMode; NewTabPager.shared.activeFieldMode = nil
    }

    override func tearDown() {
        NewTabPager.shared.onChats = oldChats
        NewTabPager.shared.activeFieldMode = oldActiveMode
        Motion.disabled = oldMotion
    }

    func testOrdinaryQueriesLeadWithSearchOnEveryInputSurface() {
        for words in searches {
            XCTAssertEqual(Words.read(words), .search, words)
            for place in [WordsPlace.page, .newTab, .privatePage, .privateTab] {
                let row = Words.rows(for: words, in: place).first
                XCTAssertEqual(row?.action, .search, words)
                XCTAssertEqual(row?.key, .search, words)
            }
        }
    }

    func testClearQuestionsAskExceptInPrivate() {
        for words in questions {
            XCTAssertEqual(Words.read(words), .ask, words)
            for place in [WordsPlace.page, .newTab] {
                XCTAssertEqual(Words.rows(for: words, in: place).first?.action, .ask, words)
            }
            for place in [WordsPlace.privatePage, .privateTab] {
                XCTAssertEqual(Words.rows(for: words, in: place).map(\.action), [.search], words)
            }
        }
    }

    private func searchApp() -> AppModel {
        let page = Tab(id: "search-start", title: "Start page", site: "Example", icon: "globe", url: "example.com")
        let space = Space(id: "search", name: "Search", emoji: "", tint: RGB(240, 240, 240),
                          today: [page], current: page.id)
        return AppModel(world: World(name: "field-search-intent", space: space.id, spaces: [space]))
    }

    private func assertGoogleSearch(_ url: URL, words: String) throws {
        XCTAssertEqual(url.host(), "google.com", words)
        var parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.path, "/search", words)
        // Form spaces must be decoded before percent escapes so C%2B%2B stays C++.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        XCTAssertEqual(parts.queryItems?.filter { $0.name == "q" }, [URLQueryItem(name: "q", value: words)], words)
    }

    func testReturnSearchesOrdinaryQueriesWithoutMatchingTabsFromThePageAndNewTab() throws {
        for mode in [Surfaces.FieldMode.address, .newTab] {
            for words in searches {
                let app = searchApp()
                let original = try XCTUnwrap(app.browser.tab)
                let count = app.browser.space.today.count
                app.surfaces.openField(mode)
                app.field.put(words)
                XCTAssertEqual(app.fieldRows.first?.action, .search, words)
                XCTAssertEqual(app.fieldKey, .search, words)
                app.fieldReturn()
                XCTAssertNil(app.surfaces.chat, words)
                XCTAssertNil(app.surfaces.field, words)
                let tab = try XCTUnwrap(app.browser.tab)
                let url = try XCTUnwrap(tab.navigationURL)
                try assertGoogleSearch(url, words: words)
                XCTAssertEqual(app.browser.space.today.count, count + (mode == .newTab ? 1 : 0), words)
                if mode == .address { XCTAssertEqual(tab.id, original.id, words) }
                else { XCTAssertNotEqual(tab.id, original.id, words) }
            }
        }
    }

    func testReturnSwitchesToAMatchingTabInsteadOfStartingAChat() throws {
        for mode in [Surfaces.FieldMode.address, .newTab] {
            let app = AppModel(world: try World.load(named: "mira"))
            app.browser.select("work-hn")
            let tabs = app.browser.allTabs
            app.surfaces.openField(mode)
            app.field.put("what is")
            XCTAssertEqual(Words.read(app.field.words), .search)
            XCTAssertEqual(app.fieldRows.first?.action, .tab(id: "personal-yt-nn"))
            XCTAssertEqual(app.fieldKey, .go)
            XCTAssertTrue(app.fieldRows.contains { $0.action == .search })
            app.fieldReturn()
            XCTAssertNil(app.surfaces.chat)
            XCTAssertNil(app.surfaces.field)
            XCTAssertEqual(app.browser.tab?.id, "personal-yt-nn")
            XCTAssertEqual(app.browser.allTabs, tabs)
        }
    }

    func testAMatchingTabStillAllowsAnExplicitSearch() throws {
        for mode in [Surfaces.FieldMode.address, .newTab] {
            let app = AppModel(world: try World.load(named: "mira"))
            app.browser.select("work-hn")
            let original = try XCTUnwrap(app.browser.tab)
            let matching = try XCTUnwrap(app.browser.tab("personal-yt-nn"))
            let count = app.browser.space.today.count
            app.surfaces.openField(mode)
            app.field.put("what is")
            XCTAssertEqual(app.fieldRows.first?.action, .tab(id: matching.id))
            app.choose(try XCTUnwrap(app.fieldRows.first { $0.action == .search }))
            XCTAssertNil(app.surfaces.chat)
            XCTAssertNil(app.surfaces.field)
            let tab = try XCTUnwrap(app.browser.tab)
            try assertGoogleSearch(try XCTUnwrap(tab.navigationURL), words: "what is")
            XCTAssertEqual(app.browser.space.today.count, count + (mode == .newTab ? 1 : 0))
            XCTAssertEqual(app.browser.tab(matching.id), matching)
            if mode == .address { XCTAssertEqual(tab.id, original.id) }
            else { XCTAssertNotEqual(tab.id, original.id) }
        }
    }

    func testReturnStillAsksClearQuestions() throws {
        for mode in [Surfaces.FieldMode.address, .newTab] {
            for words in questions {
                let app = AppModel(world: try World.load(named: "mira"))
                app.surfaces.openField(mode)
                app.field.put(words)
                app.fieldReturn()
                XCTAssertEqual(app.surfaces.chat, .answer(question: words, aboutPage: mode == .address), words)
            }
        }
    }

    func testAnOrdinaryQueryCanStillBeAskedExplicitly() throws {
        let app = AppModel(world: try World.load(named: "mira"))
        app.surfaces.openField(.newTab)
        app.field.put("how to center a div")
        let ask = try XCTUnwrap(app.fieldRows.first { $0.action == .ask })
        app.choose(ask)
        XCTAssertEqual(app.surfaces.chat, .answer(question: "how to center a div", aboutPage: false))
    }

    func testAClearQuestionCanStillBeSearchedExplicitly() throws {
        let app = AppModel(world: try World.load(named: "mira"))
        app.surfaces.openField(.newTab)
        let words = "how do I reset my AirPods?"
        app.field.put(words)
        let search = try XCTUnwrap(app.fieldRows.first { $0.action == .search })
        app.choose(search)
        XCTAssertNil(app.surfaces.chat)
        XCTAssertEqual(app.browser.tab?.title, words + " · Google Search")
    }

    func testAddressesStillOpenBeforeQuestionsAndTasks() {
        for words in ["apple.com", "localhost:5173", "https://example.com/how?to=reset"] {
            XCTAssertEqual(Words.read(words), .open, words)
            XCTAssertEqual(Words.rows(for: words, in: .newTab).first?.action, .open, words)
        }
        XCTAssertEqual(Words.read("book a table for two?"), .task)
    }
}
