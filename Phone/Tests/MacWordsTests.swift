import SyncKit
import XCTest
@testable import YabPhone

/// Which Mac work goes to and what the phone says of one that is down
/// (docs/mac-asleep-status.md): MacState from presence, MacPick's rules,
/// MacWords' lines, the wait rows SyncMapping makes of them.
final class MacWordsTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        return c
    }()
    private let locale = Locale(identifier: "en_US")
    /// Friday Oct 16 2026, 20:00 in Stockholm.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 20))! }
    private func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// The formatter's narrow space before AM and PM, read as a space.
    private func p(_ s: String?) -> String? { s?.replacingOccurrences(of: "\u{202F}", with: " ") }

    private func mac(_ id: String, _ state: MacState, used: Date? = nil) -> SyncMac {
        SyncMac(id: id, name: id == "mini" ? "Mac mini" : "MacBook Pro", model: "Mac16,1", lastSeen: nil,
                online: state.isUp, front: nil, state: state, usedAt: used)
    }

    func testStateFromPresence() {
        let said = now.addingTimeInterval(-600)
        let asleep = SyncPresence(device: "m", name: "M", at: said.timeIntervalSince1970, asleep: true)
        XCTAssertEqual(MacState.of(presence: asleep, lastSeen: now, now: now, onlineFor: 150), .asleep(since: said))
        let quit = SyncPresence(device: "m", name: "M", at: said.timeIntervalSince1970, asleep: true, why: "quit")
        XCTAssertEqual(MacState.of(presence: quit, lastSeen: now, now: now, onlineFor: 150), .closed(since: said))
        let up = SyncPresence(device: "m", name: "M", at: now.timeIntervalSince1970)
        XCTAssertEqual(MacState.of(presence: up, lastSeen: now.addingTimeInterval(-20), now: now, onlineFor: 150), .up)
        XCTAssertEqual(MacState.of(presence: up, lastSeen: said, now: now, onlineFor: 150), .silent(since: said))
    }

    func testPresenceKeepsWhy() {
        let record = Record(collection: SyncCollection.presence, id: "m", fields: ["name": "M", "at": .number(1), "asleep": .bool(true), "why": "quit"])
        XCTAssertEqual(SyncPresence(device: "m", record: record).why, "quit")
    }

    func testPickPrefersTheMacUsedLastThatIsUp() {
        let macs = [mac("mac", .up, used: at(16, 9, 0)), mac("mini", .up, used: at(16, 19, 0))]
        XCTAssertEqual(MacPick.pick(macs, chosen: nil)?.id, "mini")
        // Used last but asleep: the one that is up.
        let asleep = [mac("mac", .up, used: at(16, 9, 0)), mac("mini", .asleep(since: at(16, 19, 30)), used: at(16, 19, 0))]
        XCTAssertEqual(MacPick.pick(asleep, chosen: nil)?.id, "mac")
        // None up: the one used last, which waits.
        let down = [mac("mac", .asleep(since: at(16, 18, 52)), used: at(16, 9, 0)), mac("mini", .closed(since: at(16, 19, 30)), used: at(16, 19, 0))]
        XCTAssertEqual(MacPick.pick(down, chosen: nil)?.id, "mini")
        // Picked by hand, even asleep; one it can't use is passed over.
        XCTAssertEqual(MacPick.pick(asleep, chosen: "mini")?.id, "mini")
        XCTAssertEqual(MacPick.pick(asleep, chosen: "mini", can: { $0.id != "mini" })?.id, "mac")
        XCTAssertNil(MacPick.pick([], chosen: nil))
    }

    func testOtherMacIsOneThatIsUp() {
        let macs = [mac("mac", .asleep(since: at(16, 18, 52))), mac("mini", .up, used: at(16, 19, 0))]
        XCTAssertEqual(MacPick.other(than: "mac", in: macs)?.id, "mini")
        XCTAssertNil(MacPick.other(than: "mini", in: macs))
    }

    func testSince() {
        XCTAssertEqual(p(MacWords.since(at(16, 18, 52), now: now, calendar: calendar, locale: locale)), "since 6:52 PM")
        XCTAssertEqual(p(MacWords.since(at(15, 18, 52), now: now, calendar: calendar, locale: locale)), "since yesterday 6:52 PM")
        XCTAssertEqual(p(MacWords.since(at(13, 18, 52), now: now, calendar: calendar, locale: locale)), "since Tuesday")
        XCTAssertEqual(p(MacWords.since(at(13, 18, 52), now: now, calendar: calendar, short: true, locale: locale)), "since Tue")
        XCTAssertEqual(p(MacWords.since(at(2, 18, 52), now: now, calendar: calendar, locale: locale)), "since Oct 2")
    }

    func testWaitRows() {
        let sent = now.addingTimeInterval(-300)
        XCTAssertNil(MacWords.waiting("MacBook Pro", .up, sent: sent, now: now))
        XCTAssertEqual(p(MacWords.waiting("MacBook Pro", .asleep(since: at(16, 18, 52)), sent: sent, now: now, calendar: calendar, locale: locale)),
                       "MacBook Pro is asleep · since 6:52 PM\nIt starts when it wakes.")
        XCTAssertEqual(p(MacWords.waiting("MacBook Pro", .closed(since: at(16, 18, 52)), sent: sent, now: now, calendar: calendar, locale: locale)),
                       "Yab is closed on MacBook Pro · since 6:52 PM\nIt starts when Yab opens.")
        XCTAssertEqual(p(MacWords.waiting("MacBook Pro", .silent(since: at(16, 18, 52)), sent: sent, now: now, calendar: calendar, locale: locale)),
                       "No word from MacBook Pro · since 6:52 PM\nIt starts when it’s back.")
        // Ten hours on: when it expires instead.
        let early = at(16, 9, 0)
        XCTAssertEqual(p(MacWords.waiting("MacBook Pro", .asleep(since: early), sent: early, now: now, calendar: calendar, locale: locale)),
                       "MacBook Pro is asleep · since 9:00 AM\nExpires at 9:00 PM if it’s still asleep.")
    }

    func testRowWords() {
        XCTAssertEqual(p(MacWords.state(.up, now: now)), "Up")
        XCTAssertEqual(p(MacWords.state(.asleep(since: at(16, 18, 52)), now: now, calendar: calendar, locale: locale)), "Asleep since 6:52 PM")
        XCTAssertEqual(p(MacWords.state(.closed(since: at(13, 18, 52)), now: now, calendar: calendar, locale: locale)), "Yab closed since Tue")
        XCTAssertEqual(p(MacWords.state(.silent(since: nil), now: now)), "No word yet")
        XCTAssertEqual(MacWords.openSubtitle("MacBook Pro", .up, several: false), nil)
        XCTAssertEqual(MacWords.openSubtitle("Mac mini", .up, several: true), "Mac mini")
        XCTAssertEqual(MacWords.openSubtitle("MacBook Pro", .asleep(since: now), several: false), "MacBook Pro · asleep")
        XCTAssertEqual(MacWords.openSubtitle("MacBook Pro", .closed(since: now), several: false), "MacBook Pro · Yab closed")
        XCTAssertEqual(MacWords.openSubtitle("MacBook Pro", .silent(since: now), several: true), "MacBook Pro · away")
        // When it opens moved to the toast, which says it for each state.
        XCTAssertEqual(MacWords.sentToast("MacBook Pro", .closed(since: now)), "Yab is closed on MacBook Pro. Opens when it opens.")
        XCTAssertEqual(MacWords.sentToast("MacBook Pro", .silent(since: now)), "Sent to MacBook Pro. Opens when it’s back.")
        XCTAssertEqual(MacWords.sentToast("MacBook Pro", .asleep(since: now)), "MacBook Pro is asleep. Opens when it wakes.")
        XCTAssertEqual(MacWords.beforeSending("MacBook Pro", .asleep(since: now)), "MacBook Pro is asleep · it starts when it wakes")
        XCTAssertNil(MacWords.beforeSending("MacBook Pro", .up))
    }

    func testCancelledSendIsRead() {
        let record = Record(collection: SyncCollection.send, id: "s", fields: ["device": "mac", "text": "hi", "at": .number(1), "state": "cancelled"])
        XCTAssertEqual(SyncSend(record)?.state, .cancelled)
    }

    func testWaitRowFromMapping() {
        let macs = SyncMapping.Macs(name: { _ in "MacBook Pro" }, state: { _ in .asleep(since: Date()) },
                                    other: { _, _ in SyncMac(id: "mini", name: "Mac mini", model: "Mac16,1", lastSeen: nil, online: true, front: nil, state: .up) })
        let send = SyncSend(Record(collection: SyncCollection.send, id: "s",
                                   fields: ["device": "mac", "text": "plan a calm saturday", "at": .number(Date().timeIntervalSince1970),
                                            "clientChat": "local", "clientDevice": "phone"]))!
        let chat = SyncMapping.pendingChat(send, old: nil, macAsleep: true, macs: macs)
        let wait = chat?.messages.last
        XCTAssertEqual(wait?.role, .wait)
        XCTAssertTrue(wait?.text.hasPrefix("MacBook Pro is asleep · since ") == true)
        XCTAssertEqual(wait?.mac?.offerName, "Mac mini")
        XCTAssertEqual(wait?.mac?.send, "s")
        XCTAssertEqual(chat?.messages.first { $0.role == .you }?.mac?.send, "s")
        // Taken back: nothing to show.
        let cancelled = SyncSend(Record(collection: SyncCollection.send, id: "s",
                                        fields: ["device": "mac", "text": "x", "at": .number(1), "clientChat": "local", "state": "cancelled"]))!
        XCTAssertNil(SyncMapping.pendingChat(cancelled, old: nil, macAsleep: true, macs: macs))
    }
}
