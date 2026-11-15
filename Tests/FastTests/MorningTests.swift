import Foundation
import Testing
@testable import Fast

// The new tab's rows from a look: how long each lasts, when it shows, in
// what order, and what a second look does to the first one's.
struct MorningTests {
    static let now = ISO8601DateFormatter().date(from: "2026-09-25T09:00:00-07:00")!
    static let never: (String) -> Date? = { _ in nil }

    static func found(_ id: String, at: Date = now, _ change: (inout Hints.Found) -> Void = { _ in }) -> Hints.Found {
        var found = Hints.Found(id: id, title: id, detail: "", at: at)
        found.confirmed = at
        change(&found)
        return found
    }

    static func item(_ title: String, _ more: [String: Any] = [:]) -> [String: Any] {
        ["title": title].merging(more) { $1 }
    }

    @Test func aRowWithoutATimeLastsADayFromItsLastLook() {
        let row = Self.found("a", at: Self.now.addingTimeInterval(-19 * 3600))
        #expect(Hints.lasts(row, now: Self.now))
        #expect(!Hints.lasts(row, now: Self.now.addingTimeInterval(2 * 3600)))
    }

    @Test func aMeetingGoesAQuarterHourAfterItStarts() {
        let meeting = Self.found("m") { $0.kind = "meeting"; $0.due = Self.now.addingTimeInterval(1800) }
        #expect(Hints.lasts(meeting, now: Self.now.addingTimeInterval(1800 + 14 * 60)))
        #expect(!Hints.lasts(meeting, now: Self.now.addingTimeInterval(1800 + 16 * 60)))
        let deadline = Self.found("d") { $0.due = Self.now.addingTimeInterval(1800) }
        #expect(Hints.lasts(deadline, now: Self.now.addingTimeInterval(1800 + 90 * 60)))
    }

    @Test func aDoneRowIsKeptOnlyToBeSeenGoing() {
        let done = Self.found("x") { $0.done = Self.now }
        #expect(Hints.lasts(done, now: Self.now.addingTimeInterval(11 * 3600)))
        #expect(!Hints.lasts(done, now: Self.now.addingTimeInterval(13 * 3600)))
        let shown = Hints.visible([done], now: Self.now, lastVisit: Self.never)
        #expect(shown.first?.done == true)
    }

    @Test func putOffUntilItsTime() {
        let row = Self.found("p") { $0.snooze = Self.now.addingTimeInterval(3600) }
        #expect(Hints.visible([row], now: Self.now, lastVisit: Self.never).isEmpty)
        #expect(Hints.visible([row], now: Self.now.addingTimeInterval(3601), lastVisit: Self.never).count == 1)
    }

    @Test func aTrialShowsTheDayBeforeItCharges() {
        let trial = Self.found("t") { $0.subscription = "trial"; $0.due = Self.now.addingTimeInterval(3 * 86_400); $0.site = "figma.com" }
        #expect(Hints.visible([trial], now: Self.now, lastVisit: Self.never).isEmpty)
        let dayBefore = Self.now.addingTimeInterval(2 * 86_400 + 3600)
        let shown = Hints.visible([trial], now: dayBefore, lastVisit: { _ in dayBefore })
        #expect(shown.count == 1)
        #expect(shown.first?.cancel == true)
    }

    @Test func aRenewalShowsOnlyForASiteNotUsed() {
        let renewal = Self.found("r") { $0.subscription = "renewal"; $0.due = Self.now.addingTimeInterval(2 * 86_400); $0.site = "midjourney.com"; $0.detail = "$30" }
        let used = Hints.visible([renewal], now: Self.now, lastVisit: { _ in Self.now.addingTimeInterval(-86_400) })
        #expect(used.isEmpty)
        let unused = Hints.visible([renewal], now: Self.now, lastVisit: Self.never)
        #expect(unused.first?.detail == "$30, not opened in a month")
        let early = Hints.visible([renewal], now: Self.now.addingTimeInterval(-2 * 86_400), lastVisit: Self.never)
        #expect(early.isEmpty)
    }

    @Test func whatIsCloseInTimeGoesFirst() {
        let a = Self.found("a")
        let b = Self.found("b") { $0.due = Self.now.addingTimeInterval(5 * 3600) }
        let c = Self.found("c") { $0.due = Self.now.addingTimeInterval(40 * 60) }
        let d = Self.found("d") { $0.due = Self.now.addingTimeInterval(20 * 60) }
        let order = Hints.visible([a, b, c, d], now: Self.now, lastVisit: Self.never).map(\.id)
        #expect(order == ["d", "c", "a", "b"])
    }

    @Test func theTimeLeftReadsInMinutes() {
        #expect(Hints.until(Self.now.addingTimeInterval(25 * 60), now: Self.now) == "in 25m")
        #expect(Hints.until(Self.now.addingTimeInterval(24 * 60 + 10), now: Self.now) == "in 25m")
        #expect(Hints.until(Self.now.addingTimeInterval(80 * 60), now: Self.now) == "in 1h 20m")
        #expect(Hints.until(Self.now.addingTimeInterval(30), now: Self.now) == "now")
        #expect(Hints.until(Self.now.addingTimeInterval(-10 * 60), now: Self.now) == "now")
        #expect(Hints.until(Self.now.addingTimeInterval(3 * 3600), now: Self.now) == nil)
        #expect(Hints.until(Self.now.addingTimeInterval(-20 * 60), now: Self.now) == nil)
    }

    @Test func handedBackByIdItKeepsWhatYouDid() {
        let seen = Self.now.addingTimeInterval(-3600)
        let before = [Self.found("found.x", at: Self.now.addingTimeInterval(-5 * 3600)) { $0.seen = seen; $0.url = "https://a.test/1" }]
        let again = Hints.found(Self.item("Acme wants an answer", ["id": "found.x", "url": "https://a.test/other"]), title: "Acme wants an answer", before: before, now: Self.now)
        #expect(again.id == "found.x")
        #expect(again.seen == seen)
        #expect(again.confirmed == Self.now)
        #expect(again.at == before[0].at)
    }

    @Test func foundAgainByItsLinkIsTheSameRow() {
        let first = Hints.found(Self.item("One", ["url": "https://a.test/1"]), title: "One", before: [], now: Self.now)
        let second = Hints.found(Self.item("One, again", ["url": "https://a.test/1"]), title: "One, again", before: [first], now: Self.now)
        #expect(first.id == second.id)
        #expect(second.title == "One, again")
        let unknown = Hints.found(Self.item("Two", ["id": "found.nothing", "url": "https://a.test/2"]), title: "Two", before: [first], now: Self.now)
        #expect(unknown.id != "found.nothing")
    }

    @Test func whatTheAgentHandsOverIsRead() {
        let item = Self.item("Design review", ["due": "2026-09-25T10:30:00-07:00", "quote": "  Please look at the flows  ",
                                               "join": "https://meet.google.com/abc-defg-hij", "subscription": "monthly", "kind": "meeting"])
        let found = Hints.found(item, title: "Design review", before: [], now: Self.now)
        #expect(found.due == Self.now.addingTimeInterval(90 * 60))
        #expect(found.quote == "Please look at the flows")
        #expect(found.join == "https://meet.google.com/abc-defg-hij")
        #expect(found.subscription == nil)
        #expect(Hints.date("2026-09-25T10:30") != nil)
        #expect(Hints.date("2026-09-25T17:30:00.000Z") == Self.now.addingTimeInterval(90 * 60))
        #expect(Hints.date("2026-09-25T10:30-07:00") == Self.now.addingTimeInterval(90 * 60))
        #expect(Hints.date("tomorrow") == nil)
    }

    @Test func aSecondLookResolvesKeepsAndLetsGo() {
        let stale = Self.found("stale", at: Self.now.addingTimeInterval(-21 * 3600))
        let waiting = Self.found("waiting", at: Self.now.addingTimeInterval(-2 * 3600))
        let answered = Self.found("answered", at: Self.now.addingTimeInterval(-2 * 3600))
        let before = Hints.resolve(["answered", "nothing"], in: [stale, waiting, answered], now: Self.now)
        #expect(before.first { $0.id == "answered" }?.done == Self.now)
        let new = Hints.found(Self.item("New", ["url": "https://a.test/new"]), title: "New", before: before, now: Self.now)
        let all = Hints.merge([new, new], into: before, now: Self.now)
        #expect(all.map(\.id) == [new.id, "waiting", "answered"])
    }

    @Test func rowsHaveNoLongDash() {
        #expect(Hints.plain("45 min call — review the flows") == "45 min call, review the flows")
        #expect(Hints.plain("$240 declined—retry needed") == "$240 declined, retry needed")
        #expect(Hints.plain("Sep 26–27") == "Sep 26, 27")
        #expect(Hints.plain("Q4-pilot") == "Q4-pilot")
    }

    @Test func laterTodayIsFiveOrThreeHours() {
        var parts = DateComponents(year: 2026, month: 9, day: 25, hour: 9)
        let morning = Calendar.current.date(from: parts)!
        #expect(Calendar.current.component(.hour, from: Hints.laterToday(from: morning)) == 17)
        parts.hour = 16
        parts.minute = 30
        let late = Calendar.current.date(from: parts)!
        #expect(Hints.laterToday(from: late) == late.addingTimeInterval(3 * 3600))
        let tomorrow = Hints.tomorrowMorning(from: late)
        #expect(Calendar.current.component(.day, from: tomorrow) == 26)
        #expect(Calendar.current.component(.hour, from: tomorrow) == 9)
    }
}

// What PLAN-morning-qa.md suspected, each held to what it should do, and the
// rules at their edges.
struct MorningEdgeTests {
    static let now = MorningTests.now
    static let never = MorningTests.never
    static func found(_ id: String, at: Date = now, _ change: (inout Hints.Found) -> Void = { _ in }) -> Hints.Found {
        MorningTests.found(id, at: at, change)
    }
    static func local(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    // S1
    @Test func putAwayIdsGoOldestFirstNotByName() {
        var ids: [String] = []
        ids = Hints.remember(ids, adding: ["zzz"], limit: 3)
        for id in ["b", "c", "d"] { ids = Hints.remember(ids, adding: [id], limit: 3) }
        #expect(ids == ["b", "c", "d"])
        ids = Hints.remember(ids, adding: ["aaa"], limit: 3)
        #expect(ids == ["c", "d", "aaa"])
        #expect(Hints.remember(["c", "d"], adding: ["c", "c"], limit: 3) == ["d", "c"])
    }

    // S2, S3
    @Test func aRenewalIsJudgedByItsServiceNotItsMail() {
        let renewal = Self.found("r") {
            $0.subscription = "renewal"; $0.due = Self.now.addingTimeInterval(2 * 86_400)
            $0.site = "mail.google.com"; $0.service = "midjourney.com"
        }
        let mailOpenedToday: (String) -> Date? = { $0 == "mail.google.com" ? Self.now : nil }
        #expect(Hints.visible([renewal], now: Self.now, lastVisit: mailOpenedToday).count == 1)
        let noService = Self.found("r2") { $0.subscription = "renewal"; $0.due = Self.now.addingTimeInterval(86_400) }
        #expect(Hints.visible([noService], now: Self.now, lastVisit: Self.never).isEmpty)
        let serviceGiven = Hints.found(["title": "Midjourney renews", "service": "https://www.Midjourney.com/account"], title: "Midjourney renews", before: [], now: Self.now)
        #expect(serviceGiven.service == "midjourney.com")
    }

    @Test func aServiceIsKnownByItsNameOnAnyHost() {
        #expect(Hints.brand("notion.com") == "notion")
        #expect(Hints.brand("https://www.notion.so/workspace") == "notion")
        #expect(Hints.brand("app.notion.com") == "notion")
        #expect(Hints.brand("bbc.co.uk") == "bbc")
        #expect(Hints.brand("notion.localtest.me") == "notion")
        #expect(Hints.uses("app.notion.com", "notion.so"))
        #expect(Hints.uses("notion.localtest.me", "notion.com"))
        #expect(!Hints.uses("mail.google.com", "midjourney.com"))
        #expect(!Hints.uses("mail.localtest.me", "notion.com"))
        #expect(Hints.uses("mail.google.com", "google.com"))
    }

    @Test func aSubscriptionWithoutADayWaits() {
        let trial = Self.found("t") { $0.subscription = "trial" }
        #expect(Hints.visible([trial], now: Self.now, lastVisit: Self.never).isEmpty)
    }

    // S4
    @Test func theSamePlaceWrittenDifferentlyIsOneRow() {
        let one = Hints.place("https://www.example.com/a/b/?utm_source=x&id=7&fbclid=q")
        #expect(one == Hints.place("http://example.com/a/b?id=7"))
        #expect(Hints.place("https://mail.google.com/mail/u/0/#inbox/FMfcgz123") == Hints.place("https://mail.google.com/mail/u/0/#all/FMfcgz123"))
        #expect(Hints.place("https://mail.google.com/mail/u/0/#inbox/AAA") != Hints.place("https://mail.google.com/mail/u/0/#inbox/BBB"))
        #expect(Hints.place("https://x.com/?b=2&a=1") == Hints.place("https://x.com/?a=1&b=2"))
        let first = Hints.found(["title": "One", "url": "https://example.com/t/1?utm_campaign=z"], title: "One", before: [], now: Self.now)
        let again = Hints.found(["title": "One", "url": "https://www.example.com/t/1/"], title: "One", before: [first], now: Self.now)
        #expect(first.id == again.id)
    }

    // S9
    @Test func anythingWithACallLinkIsAMeeting() {
        let call = Self.found("c") { $0.kind = "event"; $0.join = "https://meet.google.com/abc-defg-hij"; $0.due = Self.now }
        #expect(!Hints.lasts(call, now: Self.now.addingTimeInterval(20 * 60)))
        let event = Self.found("e") { $0.kind = "call"; $0.due = Self.now }
        #expect(!Hints.lasts(event, now: Self.now.addingTimeInterval(20 * 60)))
    }

    // S12
    @Test func aRowLeadsOnlyWhereThePersonHasBeen() {
        let hosts: Set<String> = ["mail.google.com", "github.com", "app.slack.com"]
        #expect(Hints.known("https://mail.google.com/mail/u/0/#inbox/x", among: hosts))
        #expect(Hints.known("https://www.github.com/a/b/pull/1", among: hosts))
        #expect(Hints.known("https://slack.com/x", among: hosts))
        #expect(Hints.known("https://gist.github.com/x", among: hosts))
        #expect(!Hints.known("https://github.com.evil.io/login", among: hosts))
        #expect(!Hints.known("https://mybank-verify.com/", among: hosts))
        #expect(Hints.known(nil, among: hosts))
        let items: [[String: Any]] = [
            ["title": "Verify your bank", "url": "https://mybank-verify.com/login"],
            ["title": "Review #412", "url": "https://github.com/a/b/pull/412", "join": "https://evil.io/call"],
            ["title": "Standup", "url": "https://mail.google.com/x", "join": "https://meet.google.com/abc-defg-hij"],
        ]
        let admitted = Hints.admit(items, known: hosts)
        #expect(admitted.items.count == 2)
        #expect(admitted.refused == ["mybank-verify.com"])
        #expect(admitted.items[0]["join"] == nil)
        #expect(admitted.items[1]["join"] as? String == "https://meet.google.com/abc-defg-hij")
        #expect(Hints.admit(items, known: nil).items.count == 3)
    }

    // When to look
    @Test func aLookComesOnANewMorningOrAfterABreak() {
        let yesterdayNoon = Self.local(24, 12)
        #expect(Agents.time(now: Self.local(25, 9), last: yesterdayNoon, away: Self.local(25, 8, 59)))
        #expect(!Agents.time(now: Self.local(25, 4, 50), last: Self.local(24, 23), away: Self.local(25, 4)))
        #expect(Agents.time(now: Self.local(25, 1), last: Self.local(23, 22), away: Self.local(25, 0, 59)))
        #expect(!Agents.time(now: Self.local(25, 11), last: Self.local(25, 9), away: Self.local(25, 7)))
        #expect(Agents.time(now: Self.local(25, 13), last: Self.local(25, 9), away: Self.local(25, 9, 30)))
        #expect(!Agents.time(now: Self.local(25, 13), last: Self.local(25, 9), away: Self.local(25, 12)))
    }

    // Section 1: the rules at their edges
    @Test func lifetimesAtTheirEdges() {
        let row = Self.found("a")
        #expect(Hints.lasts(row, now: Self.now.addingTimeInterval(20 * 3600 - 60)))
        #expect(!Hints.lasts(row, now: Self.now.addingTimeInterval(20 * 3600 + 60)))
        let done = Self.found("d") { $0.done = Self.now }
        #expect(Hints.lasts(done, now: Self.now.addingTimeInterval(12 * 3600 - 60)))
        #expect(!Hints.lasts(done, now: Self.now.addingTimeInterval(12 * 3600 + 60)))
    }

    @Test func putOffAtTheEdgesOfTheDay() {
        #expect(Calendar.current.component(.hour, from: Hints.laterToday(from: Self.local(25, 15, 59))) == 17)
        #expect(Hints.laterToday(from: Self.local(25, 16, 1)) == Self.local(25, 19, 1))
        #expect(Hints.laterToday(from: Self.local(25, 23, 30)) == Self.local(26, 2, 30))
        #expect(Hints.tomorrowMorning(from: Self.local(25, 0, 30)) == Self.local(25, 9))
        #expect(Hints.tomorrowMorning(from: Self.local(25, 5)) == Self.local(26, 9))
        #expect(Hints.tomorrowMorning(from: Self.local(25, 22)) == Self.local(26, 9))
    }

    @Test func subscriptionWindowsAtTheirEdges() {
        let trial = { (left: TimeInterval) in Self.found("t") { $0.subscription = "trial"; $0.due = Self.now.addingTimeInterval(left) } }
        #expect(Hints.visible([trial(36 * 3600 - 60)], now: Self.now, lastVisit: Self.never).count == 1)
        #expect(Hints.visible([trial(36 * 3600 + 60)], now: Self.now, lastVisit: Self.never).isEmpty)
        let renewal = Self.found("r") { $0.subscription = "renewal"; $0.due = Self.now.addingTimeInterval(86_400); $0.service = "x.com" }
        #expect(Hints.visible([renewal], now: Self.now, lastVisit: { _ in nil }).count == 1)
        #expect(Hints.visible([renewal], now: Self.now, lastVisit: { _ in Self.now.addingTimeInterval(-29 * 86_400) }).isEmpty)
    }

    @Test func pastTimesStayOnTopAQuarterHour() {
        let a = Self.found("a")
        let started = Self.found("s") { $0.due = Self.now.addingTimeInterval(-10 * 60) }
        #expect(Hints.visible([a, started], now: Self.now, lastVisit: Self.never).map(\.id) == ["s", "a"])
    }

    @Test func aTimeLongGoneDoesNotJumpTheQueue() {
        let overdue = Self.found("o") { $0.due = Self.now.addingTimeInterval(-2 * 3600) }
        let meeting = Self.found("m") { $0.kind = "meeting"; $0.due = Self.now.addingTimeInterval(33 * 60) }
        #expect(Hints.visible([overdue, meeting], now: Self.now, lastVisit: Self.never).map(\.id) == ["m", "o"])
    }

    @Test func aRoutineOfferedComesAfterWhatIsOwed() {
        let offer = Self.found("r") { $0.when = "weekdays 9:00"; $0.task = "Check Ledger" }
        let owed = Self.found("a")
        #expect(Hints.visible([offer, owed], now: Self.now, lastVisit: Self.never).map(\.id) == ["a", "r"])
        let declined = Self.found("r") { $0.when = "weekdays 9:00"; $0.task = "Check Ledger"; $0.done = Self.now }
        #expect(Hints.visible([declined], now: Self.now, lastVisit: Self.never).first?.done == true)
    }

    @Test func aDeadlineGoneByIsStillOwed() {
        let overdue = Self.found("o") { $0.due = Self.now.addingTimeInterval(-3 * 3600) }
        #expect(Hints.lasts(overdue, now: Self.now))
        let stale = Self.found("s", at: Self.now.addingTimeInterval(-21 * 3600)) { $0.due = Self.now.addingTimeInterval(-3 * 3600) }
        #expect(!Hints.lasts(stale, now: Self.now))
    }

    @Test func resolvedWinsOverHandedBackInOneAnswer() {
        let before = Hints.resolve(["x"], in: [Self.found("x") { $0.url = "https://a.test/1" }], now: Self.now)
        let again = Hints.found(["title": "X", "id": "x"], title: "X", before: before, now: Self.now)
        #expect(again.done == Self.now)
    }

    @Test func titleWithoutALinkKeepsItsRow() {
        let first = Hints.found(["title": "Call the bank"], title: "Call the bank", before: [], now: Self.now)
        let again = Hints.found(["title": "Call the bank"], title: "Call the bank", before: [first], now: Self.now)
        #expect(first.id == again.id)
    }

    @Test func datesInEveryShape() {
        #expect(Hints.date("2026-11-01T01:30:00-08:00") == Hints.date("2026-11-01T09:30:00Z"))
        #expect(Hints.date("2026-11-01T01:30:00-07:00") == Hints.date("2026-11-01T08:30:00Z"))
        #expect(Hints.date("2026-09-25") != nil)
        #expect(Hints.date("") == nil)
        #expect(Hints.date("25/09/2026") == nil)
    }

    @Test func textIsCutOnCharactersAndPlain() {
        let long = String(repeating: "👩‍👩‍👧", count: 70)
        let found = Hints.found(["title": long, "detail": "a — b\nc"], title: long, before: [], now: Self.now)
        #expect(found.title.count == 60)
        #expect(found.title.unicodeScalars.count == long.prefix(60).unicodeScalars.count)
        #expect(found.detail == "a, b c")
    }

    @Test func aFileFromBeforeStillReads() throws {
        let old = #"[{"id":"found.1","title":"Acme","detail":"Q4","url":"https://a.test","site":"a.test","kind":"reply","at":780000000}]"#
        let read = try JSONDecoder().decode([Hints.Found].self, from: Data(old.utf8))
        #expect(read.count == 1)
        #expect(Hints.visible(read, now: Date(timeIntervalSinceReferenceDate: 780000000 + 3600), lastVisit: Self.never).count == 1)
    }
}
