import XCTest
@testable import Fast

// Which windows a page gets (WindowGate): a moment after your click, yes;
// on its own, no, and the plate says so; a site you allowed, a couple in a
// row while it is on screen.

final class WindowGateTests: XCTestCase {
    private typealias Ask = WindowGate.Ask

    func testWebKitsOwnClickOpensAndTakesTheClick() {
        XCTAssertEqual(WindowGate.decide(Ask(gesture: true), unasked: [], now: 100), .open(input: true))
    }

    func testAWindowSecondsAfterAClickOpens() {
        // A sign-in button that heard back from its server first.
        XCTAssertEqual(WindowGate.decide(Ask(sinceInput: 1.4), unasked: [], now: 100), .open(input: true))
        XCTAssertEqual(WindowGate.decide(Ask(sinceInput: WindowGate.after), unasked: [], now: 100), .open(input: true))
    }

    func testAWindowLongAfterTheClickIsBlockedAndSaid() {
        XCTAssertEqual(WindowGate.decide(Ask(sinceInput: WindowGate.after + 0.5), unasked: [], now: 100), .block(said: true))
    }

    func testAWindowWithNoInputAtAllIsBlocked() {
        // On load, or on a timer.
        XCTAssertEqual(WindowGate.decide(Ask(), unasked: [], now: 100), .block(said: true))
    }

    func testAnotherSitesFrameIsBlockedQuietly() {
        XCTAssertEqual(WindowGate.decide(Ask(allowed: true, own: false), unasked: [], now: 100), .block(said: false))
    }

    func testAnotherSitesFrameStillOpensOnAClickInIt() {
        XCTAssertEqual(WindowGate.decide(Ask(sinceInput: 0.2, own: false), unasked: [], now: 100), .open(input: true))
    }

    func testAnAllowedSiteOpensWithoutInputWhileOnScreen() {
        XCTAssertEqual(WindowGate.decide(Ask(allowed: true), unasked: [], now: 100), .open(input: false))
    }

    func testAnAllowedSiteInABackgroundTabIsBlocked() {
        XCTAssertEqual(WindowGate.decide(Ask(allowed: true, onScreen: false), unasked: [], now: 100), .block(said: true))
    }

    func testAnAllowedSiteGetsOnlyABurst() {
        let now: TimeInterval = 100
        XCTAssertEqual(WindowGate.decide(Ask(allowed: true), unasked: [now - 1], now: now), .open(input: false))
        XCTAssertEqual(WindowGate.decide(Ask(allowed: true), unasked: [now - 2, now - 1], now: now), .block(said: true))
        // Once the span has passed, again.
        let old = now - WindowGate.span - 1
        XCTAssertEqual(WindowGate.decide(Ask(allowed: true), unasked: [old, old], now: now), .open(input: false))
    }

    func testRecentKeepsOnlyTheSpan() {
        XCTAssertEqual(WindowGate.recent([1, 50, 95, 99], now: 100), [95, 99])
    }

    func testPlaceIsTheHostWithoutWww() {
        XCTAssertEqual(WindowGate.place(URL(string: "https://www.Linear.app/login")), "linear.app")
        XCTAssertEqual(WindowGate.place(URL(string: "https://accounts.google.com/o/oauth2")), "accounts.google.com")
        XCTAssertNil(WindowGate.place(URL(string: "about:blank")))
        XCTAssertNil(WindowGate.place(nil))
        XCTAssertNil(WindowGate.place(URL(string: "yab://task")))
    }

    func testBlockedKeepsOnePerPlaceNewestFirstAndAFew() {
        var page = PageWindows()
        page.block(BlockedWindow(url: URL(string: "https://accounts.google.com/a"), site: "linear.app"))
        page.block(BlockedWindow(url: URL(string: "https://ads.example/1"), site: "linear.app"))
        page.block(BlockedWindow(url: URL(string: "https://accounts.google.com/b"), site: "linear.app"))
        XCTAssertEqual(page.blocked.map { $0.url?.absoluteString }, ["https://accounts.google.com/b", "https://ads.example/1"])
        page.block(BlockedWindow(url: URL(string: "https://c.example/"), site: "linear.app"))
        page.block(BlockedWindow(url: URL(string: "https://d.example/"), site: "linear.app"))
        XCTAssertEqual(page.blocked.count, WindowGate.kept)
        XCTAssertEqual(WindowGate.place(page.blocked.first?.url), "d.example")
    }
}
