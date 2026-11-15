import Foundation
import Testing
@testable import Fast
@testable import MailCore

// When a snoozed thread comes back and when a mail set for later goes out,
// in words (docs/mail.md, Snooze and send later).
struct MailLaterTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return calendar
    }()

    // Monday, Sep 28 2026, 10:00 in Lisbon.
    static func day(_ day: Int, _ hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    @Test func snoozeChoicesOnAMondayMorning() {
        let anna = MailPerson(name: "Anna Lindqvist", address: "anna@fold.studio")
        let meeting = Meeting(id: "m", title: "Design review", start: Self.day(1 + 28, 15), end: Self.day(29, 16), link: nil,
                              people: ["anna@fold.studio"])
        let choices = MailLater.snoozes(for: anna, meetings: [meeting], now: Self.day(28, 10), calendar: Self.calendar)
        #expect(choices.map(\.label) == ["Later today", "Tomorrow morning", "This weekend", "Next week", "Until Anna replies",
                                         "Before your meeting with Anna"])
        #expect(choices.map(\.detail) == ["18:00", "Tue 9:00", "Sat 9:00", "Mon 9:00", "", "Tue 14:45"])
        #expect(choices[4].at == nil && choices[4].reply)
        #expect(choices[5].at == Self.day(29, 14, minute: 45))
    }

    @Test func noLaterTodayInTheEvening() {
        let choices = MailLater.snoozes(for: nil, meetings: [], now: Self.day(28, 20), calendar: Self.calendar)
        #expect(choices.first?.label == "Tomorrow morning")
        #expect(!choices.contains { $0.label.hasPrefix("Until") })
    }

    @Test func sendChoices() {
        let choices = MailLater.sends(now: Self.day(28, 10), calendar: Self.calendar)
        #expect(choices.map(\.detail) == ["Tue 8:00", "Tue 13:00", "Mon 8:00"])
        // On a Sunday, tomorrow morning is Monday morning: said once.
        #expect(MailLater.sends(now: Self.day(27, 10), calendar: Self.calendar).count == 2)
    }

    @Test func timesTypedInWords() {
        let now = Self.day(28, 10)
        #expect(MailLater.parse("in 3 days", now: now, calendar: Self.calendar) == Self.day(1 + 30, 9))
        #expect(MailLater.parse("in 2 hours", now: now, calendar: Self.calendar) == Self.day(28, 12))
        #expect(MailLater.parse("in an hour", now: now, calendar: Self.calendar) == Self.day(28, 11))
        // The date detector reads "yesterday" off the real clock, not `now`.
        #expect(MailLater.parse("yesterday") == nil)
        #expect(MailLater.parse("gibberish", now: now, calendar: Self.calendar) == nil)
    }

    static func utc(_ month: Int, _ day: Int, _ hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    static func wall(_ date: Date, in zone: String) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.dateComponents([.weekday, .hour, .minute], from: date)
    }

    @Test func aTimeTypedWithAPlaceIsThatPlacesClock() throws {
        // The detector reads "mon" off the real clock: Monday 10:00 in Tokyo, ahead.
        let tokyo = try #require(MailLater.typed("mon 10am tokyo", now: Date()))
        #expect(tokyo.zone?.identifier == "Asia/Tokyo")
        #expect(tokyo.place == "Tokyo")
        let wall = Self.wall(tokyo.at, in: "Asia/Tokyo")
        #expect(wall.weekday == 2 && wall.hour == 10 && wall.minute == 0)
        #expect(tokyo.at > Date())
        let said = MailLater.said(tokyo, calendar: Self.calendar)
        #expect(said.title.hasPrefix("Mon, ") && said.title.hasSuffix(", 10:00 AM in Tokyo"))
        // Tokyo's Monday 10:00 is Lisbon's Monday 1:00 or 2:00.
        #expect(said.here?.hasPrefix("Mon ") == true && said.here?.hasSuffix(":00 AM here") == true)
        #expect(MailLater.typed("friday 3pm in new york", now: Date())?.place == "New York")
        #expect(MailLater.typed("tomorrow 9am at sydney", now: Date())?.zone?.identifier == "Australia/Sydney")
    }

    @Test func noPlaceNamedSaysOnlyTheDate() throws {
        let now = Self.day(28, 10)
        let typed = try #require(MailLater.typed("in 2 hours", now: now, calendar: Self.calendar))
        #expect(typed.zone == nil && typed.place == nil)
        let said = MailLater.said(typed, calendar: Self.calendar)
        #expect(said.title == "Mon, Sep 28, 12:00 PM")
        #expect(said.here == nil)
        // A place on a relative time: its morning there.
        let three = try #require(MailLater.typed("in 3 days tokyo", now: now, calendar: Self.calendar))
        #expect(three.at == Self.utc(10, 1, 0))
    }

    @Test func theWeekNewYorkAndBerlinAreFiveHoursApart() {
        // Europe leaves summer time on Oct 25, America on Nov 1.
        let now = Self.utc(10, 19, 12)
        #expect(MailLater.parse("October 28, 2026 at 10am in new york", now: now) == Self.utc(10, 28, 14))
        #expect(MailLater.parse("October 28, 2026 at 10am berlin", now: now) == Self.utc(10, 28, 9))
        // A week later both are back on standard time: six hours.
        #expect(MailLater.parse("November 4, 2026 at 10am new york", now: now) == Self.utc(11, 4, 15))
        #expect(MailLater.parse("November 4, 2026 at 10am berlin", now: now) == Self.utc(11, 4, 9))
    }

    @Test func zoneLetters() {
        let now = Self.utc(10, 19, 12)
        #expect(MailLater.parse("October 28, 2026 at 10am PST", now: now) == Self.utc(10, 28, 17))
        #expect(MailLater.parse("October 28, 2026 at 10am EDT", now: now) == Self.utc(10, 28, 14))
        #expect(MailLater.parse("October 28, 2026 at 10am UTC", now: now) == Self.utc(10, 28, 10))
        #expect(MailLater.parse("October 28, 2026 at 10am JST", now: now) == Self.utc(10, 28, 1))
        #expect(MailLater.parse("October 28, 2026 at 10am AEST", now: now) == Self.utc(10, 27, 23))
        #expect(MailLater.parse("October 28, 2026 at 10am CET", now: now) == Self.utc(10, 28, 9))
        let typed = MailLater.typed("October 28, 2026 at 10am pst", now: now)
        #expect(typed.map { MailLater.said($0, calendar: Self.calendar).title } == "Wed, Oct 28, 10:00 AM PT")
        // Only an hour, gone there today: that hour tomorrow.
        let hour = MailLater.typed("10 am AEST", now: Date())
        #expect(hour.map { $0.at > Date() && $0.at < Date().addingTimeInterval(86_400 + 3_600) } == true)
    }

    @Test func aPlaceADayAheadReadsTodayAndTomorrowOnItsOwnDate() {
        // 21:39 in California is 15:39 the next day in Sydney.
        let now = Self.utc(10, 20, 4)
        #expect(MailLater.days(from: now, here: TimeZone(identifier: "America/Los_Angeles")!, there: TimeZone(identifier: "Australia/Sydney")!) == 1)
        #expect(MailLater.days(from: now, here: TimeZone(identifier: "Australia/Sydney")!, there: TimeZone(identifier: "America/Los_Angeles")!) == -1)
        #expect(MailLater.days(from: now, here: TimeZone(identifier: "Europe/Lisbon")!, there: TimeZone(identifier: "Europe/Berlin")!) == 0)
    }

    @Test func wordsThatAreNoTimeStayNil() {
        let now = Self.utc(10, 19, 12)
        #expect(MailLater.typed("tokyo", now: now) == nil)
        #expect(MailLater.typed("in tokyo", now: now) == nil)
        #expect(MailLater.typed("gibberish berlin", now: now) == nil)
        #expect(MailLater.typed("lunch with pst", now: now) == nil)
        #expect(MailLater.typed("October 1, 2026 at 10am tokyo", now: now) == nil)
    }

    @Test func doItAsksForOneThingAndNeverSends() {
        let prompt = MailDesk.doIt(thread: "me@example.com|anna", subject: "Thursday works? \"deck\"")
        #expect(prompt.contains("mail_read"))
        #expect(prompt.contains("me@example.com|anna"))
        #expect(prompt.contains("Never pay"))
        #expect(prompt.contains("mail_draft"))
        #expect(!prompt.contains("\"deck\""))
    }
}
