import SyncKit
import XCTest
@testable import YabPhone

/// The Mac's Today on a space's page (docs/iphone-mac-tabs.md, D): which
/// Mac a tab is under, the tab in front first, five then "Show all N",
/// and the words at the end of a Mac's line.
final class MacTodayTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        return c
    }()
    private let locale = Locale(identifier: "en_US")

    private func tab(_ n: Int, device: String? = "mac") -> SyncTab {
        SyncTab(id: "t\(n)", space: "work", order: String(format: "a%02d", n), url: "https://example.com/\(n)", title: "Tab \(n)", device: device)
    }

    private func mac(_ id: String = "mac", name: String = "MacBook Pro", front: String? = nil, state: MacState = .up) -> SyncMac {
        SyncMac(id: id, name: name, model: "Mac16,1", online: state.isUp,
                front: front.map { SyncPresence(device: id, name: name, at: 0, tab: $0) }, state: state)
    }

    func testTheTabInFrontLeadsTheRestKeepTheMacsOrder() {
        let lines = MacToday.lines(tabs: (0..<4).map { tab($0) }, macs: [mac(front: "t2")])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].name, "MacBook Pro")
        XCTAssertEqual(lines[0].rows.map(\.id), ["t2", "t0", "t1", "t3"])
        XCTAssertEqual(lines[0].rows.map(\.front), [true, false, false, false])
    }

    func testATabWithNoDeviceIsTheFirstMacs() {
        let lines = MacToday.lines(tabs: [tab(0, device: nil), tab(1, device: "other"), tab(2, device: "air")],
                                   macs: [mac(), mac("air", name: "MacBook Air")])
        XCTAssertEqual(lines.map(\.name), ["MacBook Pro", "MacBook Air"])
        XCTAssertEqual(lines[0].rows.map(\.id), ["t0", "t1"])
        XCTAssertEqual(lines[1].rows.map(\.id), ["t2"])
    }

    func testAMacWithNothingInTheSpaceHasNoLine() {
        XCTAssertEqual(MacToday.lines(tabs: [tab(0)], macs: [mac(), mac("air", name: "MacBook Air")]).map(\.id), ["mac"])
        XCTAssertTrue(MacToday.lines(tabs: [], macs: [mac()]).isEmpty)
    }

    func testNoMacYetStillShowsItsTabsUnderAName() {
        let lines = MacToday.lines(tabs: [tab(0)], macs: [], fallbackName: "Mira’s MacBook")
        XCTAssertEqual(lines.map(\.name), ["Mira’s MacBook"])
    }

    func testFiveThenShowAll() {
        let line = MacToday.lines(tabs: (0..<24).map { tab($0) }, macs: [mac()])[0]
        let folded = MacToday.visible(line, all: false)
        XCTAssertEqual(folded.rows.count, 5)
        XCTAssertEqual(folded.more, 24)
        let all = MacToday.visible(line, all: true)
        XCTAssertEqual(all.rows.count, 24)
        XCTAssertNil(all.more)
        let five = MacToday.lines(tabs: (0..<5).map { tab($0) }, macs: [mac()])[0]
        XCTAssertNil(MacToday.visible(five, all: false).more)
    }

    func testClosedWhileAsleepStaysDimmedUntilItWakes() {
        let lines = MacToday.lines(tabs: [tab(0)], macs: [mac(front: "t1", state: .asleep(since: Date()))], closing: [tab(1)])
        XCTAssertEqual(lines[0].rows.map(\.id), ["t0", "t1"])
        XCTAssertEqual(lines[0].rows.map(\.closing), [false, true])
        // Closing, it is not the one in front any more.
        XCTAssertFalse(lines[0].rows[1].front)
        XCTAssertEqual(MacToday.subtitle(lines[0].rows[1], up: false, host: "example.com"), "Closes when your Mac wakes")
    }

    func testTheLinesWords() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9, minute: 41))!
        let slept = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 8, minute: 12))!
        let rows = MacToday.lines(tabs: (0..<3).map { tab($0) }, macs: [mac(front: "t0")])[0]
        XCTAssertNil(MacToday.note(rows, folded: false, now: now, calendar: calendar, locale: locale))
        XCTAssertEqual(MacToday.note(rows, folded: true, now: now, calendar: calendar, locale: locale), "3 tabs")
        var asleep = rows
        asleep.state = .asleep(since: slept)
        XCTAssertEqual(MacToday.note(asleep, folded: false, now: now, calendar: calendar, locale: locale), "Asleep · 8:12")
        XCTAssertEqual(MacToday.at(slept, now: now, calendar: calendar, locale: Locale(identifier: "sv_SE")), "8:12")
        asleep.state = .closed(since: calendar.date(byAdding: .day, value: -1, to: slept)!)
        XCTAssertEqual(MacToday.note(asleep, folded: true, now: now, calendar: calendar, locale: locale), "Yab closed · Oct 19")
        XCTAssertEqual(MacToday.subtitle(rows.rows[0], up: true, host: "example.com"), "In front on Mac")
        XCTAssertEqual(MacToday.subtitle(rows.rows[0], up: false, host: "example.com"), "Was in front on Mac")
        XCTAssertEqual(MacToday.subtitle(rows.rows[1], up: true, host: "example.com"), "example.com")
    }
}
