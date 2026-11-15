import XCTest
@testable import YabPhone

final class SuggestionsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func visit(_ url: String, title: String = "Page", hours: Double = 48, count: Int = 1,
                       parts: [Int]? = nil, outside: Bool? = nil) -> BrowserVisit {
        BrowserVisit(url: url, title: title, site: "", icon: "", host: "", visitedAt: now.addingTimeInterval(-hours * 3600),
                     count: count, parts: parts, outside: outside)
    }

    private func place(_ url: String, title: String = "Page", typed: Bool = false, hours: Double = 24, device: String? = "mac") -> SyncedPlace {
        SyncedPlace(key: url, url: url, title: title, last: now.addingTimeInterval(-hours * 3600).timeIntervalSince1970, typed: typed, device: device)
    }

    private func input(_ visits: [BrowserVisit] = [], _ places: [SyncedPlace] = [], hour: Int = 12) -> Suggestions.Input {
        Suggestions.Input(visits: visits, places: places, own: "phone", current: nil, engineHost: "google.com",
                          now: now, hour: hour, limit: 5)
    }

    func testANewPhoneGetsTheMacsHabitsByWholeSites() {
        let picks = Suggestions.make(input([], [
            place("https://github.com/pulls"), place("https://github.com/issues"), place("https://github.com/", title: "GitHub: Let's build from here"),
            place("https://linear.app/", title: "Linear", typed: true), place("https://www.youtube.com/watch?v=1"),
        ]))
        XCTAssertEqual(picks.map(\.host), ["github.com", "linear.app", "youtube.com"])
        XCTAssertEqual(picks.map(\.title), ["GitHub", "Linear", "Youtube"])
        XCTAssertEqual(picks.first?.url, "https://github.com/", "a habit opens the site, not an old page")
        XCTAssertTrue(picks.allSatisfy { $0.kind == .site })
    }

    func testOneSiteStandsOnceHoweverManyPagesWereOpen() {
        let visits = (0..<4).map { visit("https://yetanotherbrowser.com/changelog/\($0)", title: "Yab \($0)", hours: Double($0 + 1)) }
        let picks = Suggestions.make(input(visits + [visit("https://en.wikipedia.org/wiki/Wright", title: "Wright", hours: 5)]))
        XCTAssertEqual(picks.map(\.host), ["yetanotherbrowser.com", "en.wikipedia.org"])
        XCTAssertEqual(picks.first?.title, "Yab 0")
        XCTAssertEqual(picks.first?.kind, .page)
    }

    func testPagesNobodyComesBackToAreNotOffered() {
        let picks = Suggestions.make(input([
            visit("https://fraudalertresponse.chase.com/x", hours: 0.1, outside: true),
            visit("https://login.tailscale.com/admin", hours: 0.2),
            visit("https://www.google.com/", hours: 0.3, count: 40),
            visit("https://accounts.example.com/signin", hours: 0.4),
            visit("https://example.com/cb?client_id=1&redirect_uri=x", hours: 0.5),
        ], [place("http://localhost:3000/", typed: true), place("http://192.168.1.4/"), place("https://nas.local/"), place("file:///etc/hosts")]))
        XCTAssertEqual(picks, [])
    }

    func testALinkFromAnotherAppOpenedAgainIsYours() {
        let picks = Suggestions.make(input([visit("https://example.com/a", hours: 1, count: 2, outside: true)]))
        XCTAssertEqual(picks.map(\.host), ["example.com"])
    }

    func testAMomentsSearchReadsAsItsWordsOnce() {
        let picks = Suggestions.make(input([visit("https://www.google.com/search?q=edgar+wright", hours: 1),
                                            visit("https://www.google.com/search?q=older", hours: 2),
                                            visit("https://example.com/", title: "Example", hours: 3)]))
        XCTAssertEqual(picks.first?.kind, .search("edgar wright"))
        XCTAssertEqual(picks.filter { if case .search = $0.kind { true } else { false } }.count, 1)
        XCTAssertEqual(picks.last?.host, "example.com")
    }

    func testThePhoneOutweighsTheMacOnlyOnceItHasAHistory() {
        let mac = (0..<20).map { place("https://github.com/\($0)") }
        let few = input([visit("https://x.com/", count: 2)], mac)
        XCTAssertEqual(Suggestions.habits(few).first?.host, "github.com")
        let many = input([visit("https://x.com/", count: 200)], mac)
        XCTAssertEqual(Suggestions.habits(many).first?.host, "x.com")
    }

    func testThePartOfTheDayComesFromThePhone() {
        let visits = [visit("https://x.com/", count: 100, parts: [0, 0, 100, 0]), visit("https://github.com/", count: 120, parts: [100, 20, 0, 0])]
        XCTAssertEqual(Suggestions.habits(input(visits, hour: 9)).first?.host, "github.com")
        XCTAssertEqual(Suggestions.habits(input(visits, hour: 20)).first?.host, "x.com")
    }

    func testASiteFromTheMacLeftUnopenedHereSinks() {
        var quiet = input([], [place("https://figma.com/"), place("https://figma.com/a"), place("https://figma.com/b"), place("https://linear.app/")])
        XCTAssertEqual(Suggestions.habits(quiet).first?.host, "figma.com")
        quiet.shown = ["figma.com": 4]
        XCTAssertEqual(Suggestions.habits(quiet).first?.host, "figma.com")
        quiet.shown = ["figma.com": 5]
        quiet.places.removeAll { $0.url.hasPrefix("https://figma.com/") && $0.url != "https://figma.com/" }
        XCTAssertEqual(Suggestions.habits(quiet).first?.host, "linear.app")
    }

    func testARemovedSiteAndTheCurrentPageStayAway() {
        var value = input([visit("https://example.com/", hours: 1), visit("https://news.site/", hours: 2)], [place("https://linear.app/")])
        value.current = "https://example.com/"
        value.removed = ["linear.app"]
        let hosts = Suggestions.make(value).map(\.host)
        XCTAssertEqual(hosts.filter { $0 == "linear.app" }, [])
        XCTAssertEqual(hosts.first, "news.site")
    }

    func testThePhonesOwnPlacesAreNotCountedTwice() {
        XCTAssertEqual(Suggestions.habits(input([], [place("https://example.com/", device: "phone")])), [])
    }

    func testNamesDropTheTagline() {
        XCTAssertEqual(Suggestions.name(of: "x.com", home: "X - The Everything App / X"), "X")
        XCTAssertEqual(Suggestions.name(of: "github.com", home: "GitHub: Let's build from here"), "GitHub")
        XCTAssertEqual(Suggestions.name(of: "linear.app", home: nil), "Linear")
    }

    func testOldVisitsStillDecode() throws {
        let old = #"{"url":"https://a.com/","title":"A","site":"a.com","icon":"a","host":"a.com","visitedAt":0,"count":3}"#
        let visit = try JSONDecoder().decode(BrowserVisit.self, from: Data(old.utf8))
        XCTAssertEqual(visit.count, 3)
        XCTAssertNil(visit.parts)
    }
}
