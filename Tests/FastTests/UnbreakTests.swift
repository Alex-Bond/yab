import XCTest
@testable import Fast

// The corner that offers a broken page its ads back (Unbreak): three of your
// reloads of a site in twenty seconds, once a visit, and quiet for a week
// after three offers let go in a row. The clock is handed in.

final class UnbreakTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testThreeReloadsInTwentySecondsCount() {
        var watch = ReloadWatch()
        XCTAssertFalse(watch.reloaded("nytimes.com", at: at(0)))
        XCTAssertFalse(watch.reloaded("nytimes.com", at: at(8)))
        XCTAssertTrue(watch.reloaded("nytimes.com", at: at(19)))
    }

    func testReloadsSpreadOverMoreThanTwentySecondsDont() {
        var watch = ReloadWatch()
        XCTAssertFalse(watch.reloaded("nytimes.com", at: at(0)))
        XCTAssertFalse(watch.reloaded("nytimes.com", at: at(12)))
        XCTAssertFalse(watch.reloaded("nytimes.com", at: at(25)))
        // 12 and 25 are still inside the window with 30.
        XCTAssertTrue(watch.reloaded("nytimes.com", at: at(30)))
    }

    func testAnotherSiteStartsAgain() {
        var watch = ReloadWatch()
        _ = watch.reloaded("nytimes.com", at: at(0))
        _ = watch.reloaded("nytimes.com", at: at(1))
        XCTAssertFalse(watch.reloaded("example.com", at: at(2)))
        XCTAssertEqual(watch.site, "example.com")
        XCTAssertEqual(watch.stamps.count, 1)
    }

    func testAskedOnceAVisit() {
        var watch = ReloadWatch()
        for second in 0..<3 { _ = watch.reloaded("nytimes.com", at: at(Double(second))) }
        watch.ask()
        XCTAssertTrue(watch.asked)
        XCTAssertTrue(watch.stamps.isEmpty)
        // Three more on the same visit: counted, but asked already.
        for second in 3..<6 { _ = watch.reloaded("nytimes.com", at: at(Double(second))) }
        XCTAssertTrue(watch.asked)
        // Gone elsewhere and back: a new visit.
        watch.visit("example.com")
        watch.visit("nytimes.com")
        XCTAssertFalse(watch.asked)
    }

    func testTheSameSiteIsTheSameVisit() {
        var watch = ReloadWatch()
        _ = watch.reloaded("nytimes.com", at: at(0))
        watch.ask()
        watch.visit("nytimes.com")
        XCTAssertTrue(watch.asked)
    }

    func testThreeLetGoInARowMeansAWeekQuiet() {
        var limit = UnbreakLimit()
        XCTAssertTrue(limit.allows(at: at(0)))
        limit.shown(at: at(0))
        limit.shown(at: at(60))
        XCTAssertTrue(limit.allows(at: at(120)))
        limit.shown(at: at(120))
        XCTAssertFalse(limit.allows(at: at(121)))
        XCTAssertFalse(limit.allows(at: at(120 + UnbreakLimit.quiet - 1)))
        XCTAssertTrue(limit.allows(at: at(120 + UnbreakLimit.quiet)))
    }

    func testTakingItBreaksTheStreak() {
        var limit = UnbreakLimit()
        limit.shown(at: at(0))
        limit.shown(at: at(1))
        limit.taken()
        limit.shown(at: at(2))
        limit.shown(at: at(3))
        XCTAssertTrue(limit.allows(at: at(4)))
        XCTAssertEqual(limit.ignored, 2)
    }

    func testTakingTheThirdStillCountsAsTaken() {
        var limit = UnbreakLimit()
        for second in 0..<3 { limit.shown(at: at(Double(second))) }
        XCTAssertFalse(limit.allows(at: at(3)))
        limit.taken()
        XCTAssertTrue(limit.allows(at: at(4)))
    }

    func testAfterTheWeekTheCountStartsFresh() {
        var limit = UnbreakLimit()
        for second in 0..<3 { limit.shown(at: at(Double(second))) }
        let later = at(2 + UnbreakLimit.quiet + 10)
        XCTAssertTrue(limit.allows(at: later))
        limit.shown(at: later)
        XCTAssertNil(limit.quietUntil)
        XCTAssertEqual(limit.ignored, 1)
    }

    func testTheLimitKeepsAcrossLaunches() throws {
        var limit = UnbreakLimit()
        for second in 0..<3 { limit.shown(at: at(Double(second))) }
        let back = try JSONDecoder().decode(UnbreakLimit.self, from: JSONEncoder().encode(limit))
        XCTAssertEqual(back, limit)
    }

    func testAPageIsItsAddressLessTheFragment() {
        XCTAssertEqual(Unbreak.page(URL(string: "https://nytimes.com/a?b=1#c")), "https://nytimes.com/a?b=1")
        XCTAssertNil(Unbreak.page(nil))
    }
}
