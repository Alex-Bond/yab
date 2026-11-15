import Foundation
import Testing
@testable import Fast

// Habits from visits (PLAN-hints §5): a table of visits and what is found.
// All in Los Angeles' time, where summer time ends on Sunday, November 1.
struct HabitsTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// A local time, "2026-09-21 09:05".
    static func at(_ text: String) -> Date {
        let parts = text.split(whereSeparator: { " -:".contains($0) }).compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4]))!
    }

    static func visits(_ address: String, _ times: [String], title: String? = nil) -> [Habits.Visit] {
        times.map { Habits.Visit(url: URL(string: address)!, at: at($0), title: title) }
    }

    static func found(_ visits: [Habits.Visit], now: String) -> [Habit] {
        Habits.now(visits: visits, now: at(now), calendar: calendar)
    }

    // Monday the 21st to Thursday the 24th; Friday the 18th skipped.
    static let board = visits("https://linear.app/yab/team/YAB/active", [
        "2026-09-21 09:00", "2026-09-22 09:05", "2026-09-23 09:10", "2026-09-24 09:20",
        "2026-09-24 11:40",
    ], title: "Active issues · Linear")

    @Test func fourOfTheLastFiveWeekdays() {
        let habits = Self.found(Self.board, now: "2026-09-25 09:00")
        #expect(habits.map(\.place) == ["linear.app/yab"])
        #expect(habits.first?.weekday == nil)
        #expect(habits.first?.detail == "You open it most weekdays around 9 AM")
        #expect(habits.first?.title == "Active issues · Linear")
        #expect(habits.first?.url.absoluteString == "https://linear.app/yab/team/YAB/active")
    }

    @Test func itsTimeIsTheWindowAndTenMinutesBefore() {
        // First visits 9:00, 9:05, 9:10, 9:20: the middle 9:10, the window 8:25 to 9:55.
        #expect(Self.found(Self.board, now: "2026-09-25 08:14").isEmpty)
        #expect(Self.found(Self.board, now: "2026-09-25 08:15").count == 1)
        #expect(Self.found(Self.board, now: "2026-09-25 09:55").count == 1)
        #expect(Self.found(Self.board, now: "2026-09-25 09:56").isEmpty)
        // Not on a weekend: a weekday habit is a weekday's.
        #expect(Self.found(Self.board, now: "2026-09-26 09:00").isEmpty)
    }

    @Test func threeOfTheLastFourMondays() {
        let payouts = Self.visits("https://dashboard.stripe.com/payouts", ["2026-09-21 10:00", "2026-09-14 10:10", "2026-09-07 09:50"],
                                  title: "Payouts · Stripe")
        let habits = Self.found(payouts, now: "2026-09-28 10:00")
        #expect(habits.map(\.place) == ["dashboard.stripe.com/payouts"])
        #expect(habits.first?.weekday == 2)
        #expect(habits.first?.detail == "You open it most Mondays around 10 AM")
        // Only Mondays.
        #expect(Self.found(payouts, now: "2026-09-29 10:00").isEmpty)
    }

    @Test func fiftyMinutesLateBreaksTheWindow() {
        let shifted = Self.visits("https://news.ycombinator.com/", ["2026-09-21 09:00", "2026-09-22 09:00", "2026-09-23 09:00",
                                                                    "2026-09-24 10:35", "2026-09-18 10:40"])
        #expect(Self.found(shifted, now: "2026-09-25 09:00").isEmpty)
        #expect(Self.found(shifted, now: "2026-09-25 10:30").isEmpty)
    }

    @Test func openedTodayIsNoHabitToday() {
        let today = Self.board + Self.visits("https://linear.app/yab/inbox", ["2026-09-25 07:30"])
        #expect(Self.found(today, now: "2026-09-25 09:00").isEmpty)
        // Another part of the same site doesn't count as the place.
        let elsewhere = Self.board + Self.visits("https://linear.app/settings", ["2026-09-25 07:30"])
        #expect(Self.found(elsewhere, now: "2026-09-25 09:00").count == 1)
    }

    @Test func aPlaceOpenEveryHourIsNoHabit() {
        var mail: [String] = []
        for day in ["2026-09-18", "2026-09-21", "2026-09-22", "2026-09-23", "2026-09-24"] {
            for hour in 8...17 { mail.append("\(day) \(hour):05") }
        }
        #expect(Self.found(Self.visits("https://mail.google.com/mail/u/0/#inbox", mail), now: "2026-09-25 08:00").isEmpty)
    }

    @Test func aWindowAcrossMidnight() {
        // Wednesday's first visit was two minutes past midnight.
        let late = Self.visits("https://www.duolingo.com/learn", ["2026-09-21 23:55", "2026-09-22 23:58", "2026-09-23 00:02", "2026-09-24 23:56"])
        let habits = Self.found(late, now: "2026-09-25 23:50")
        #expect(habits.map(\.place) == ["duolingo.com/learn"])
        #expect(habits.first?.detail == "You open it most weekdays around midnight")
        #expect(Self.found(late, now: "2026-09-25 22:40").isEmpty)
    }

    @Test func summerTimeEndingKeepsTheLocalHour() {
        // 9:00 in the morning, local, the week before summer time ends and
        // the Monday after: seven hours from UTC before, eight after.
        let standup = Self.visits("https://app.slack.com/huddle", ["2026-10-26 09:00", "2026-10-27 09:00", "2026-10-28 09:00",
                                                                  "2026-10-29 09:00", "2026-10-30 09:00"])
        let habits = Self.found(standup, now: "2026-11-02 09:00")
        #expect(habits.count == 1)
        #expect(habits.first?.detail == "You open it most weekdays around 9 AM")
        #expect(Self.found(standup, now: "2026-11-02 10:00").isEmpty)
    }

    @Test func oneHabitASite() {
        let root = Self.visits("https://stripe.com/", ["2026-09-21 09:00", "2026-09-22 09:00", "2026-09-23 09:00", "2026-09-24 09:00"])
        let payouts = Self.visits("https://stripe.com/payouts", ["2026-09-21 09:01", "2026-09-22 09:01", "2026-09-23 09:01",
                                                                 "2026-09-24 09:01", "2026-09-18 09:01"])
        #expect(Self.found(root + payouts, now: "2026-09-25 09:00").map(\.place) == ["stripe.com/payouts"])
    }

    @Test func whatIsNeverAPlace() {
        #expect(Habits.place(URL(string: "https://www.google.com/maps/@37.7")!) == "google.com/maps")
        #expect(Habits.place(URL(string: "https://www.google.com/search?q=yab")!) == nil)
        #expect(Habits.place(URL(string: "https://duckduckgo.com/?q=yab")!) == nil)
        #expect(Habits.place(URL(string: "https://accounts.google.com/signin")!) == nil)
        #expect(Habits.place(URL(string: "https://t.co/abc")!) == nil)
        #expect(Habits.place(URL(string: "http://localhost:3000/")!) == nil)
        #expect(Habits.place(URL(string: "yab://bookmarks")!) == nil)
    }
}
