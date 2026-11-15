import Foundation
import Testing
@testable import Fast

// A routine's when: every form that read before reads the same, the new
// ones (a day or a weekday of the month, gaps of days and weeks, a date,
// several times a day), and when they run next and were due, across short
// months, Feb 29, a change of clocks and a run missed while Yab was closed.
struct RoutineScheduleTests {
    static let us = Locale(identifier: "en_US")

    /// New York's: its clocks go forward on Mar 8, 2026.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func next(_ when: String, after now: Date, last: Date? = nil) -> Date? {
        Routines.next(Routine(id: "t", when: when, prompt: "x", last: last ?? now), after: now, calendar: calendar)
    }

    static func say(_ when: String) -> String {
        Routines.say(when, locale: us).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    @Test func everyOldFormReadsAsBefore() {
        let all = Set(1...7)
        #expect(Routines.schedule("daily 9:00") == .days(.week(all), at: [540]))
        #expect(Routines.schedule("everyday 9:00") == .days(.week(all), at: [540]))
        #expect(Routines.schedule("day 7:05") == .days(.week(all), at: [425]))
        #expect(Routines.schedule("weekdays 18:30") == .days(.week([2, 3, 4, 5, 6]), at: [1110]))
        #expect(Routines.schedule("weekends 10:00") == .days(.week([1, 7]), at: [600]))
        #expect(Routines.schedule("mon,thu 8:15") == .days(.week([2, 5]), at: [495]))
        #expect(Routines.schedule("Monday 9:00") == .days(.week([2]), at: [540]))
        #expect(Routines.schedule("fri,mon,wed 08:00") == .days(.week([2, 4, 6]), at: [480]))
        #expect(Routines.schedule("hourly") == .every(3600))
        #expect(Routines.schedule("every 2h") == .every(7200))
        #expect(Routines.schedule("every 30m") == .every(1800))
        #expect(Routines.schedule("on open") == .opens)
        #expect(Routines.schedule("on mail receipts") == .mail("receipts"))
        // And what didn't read still doesn't.
        for words in ["daily", "weekdays", "every 10m", "every 2", "whenever", "mon 9", "9:00", "daily 25:00", "daily 9:60",
                      "every morning", "on mail", "mon,xyz 9:00", "daily 9:00 extra"] {
            #expect(Routines.schedule(words) == nil, "\(words)")
        }
        // Routines kept before read and are said as they were.
        let kept = #"[{"id":"a","when":"weekdays 9:00","prompt":"check"},{"id":"b","when":"mon,thu 8:15","prompt":"x"},{"id":"c","when":"every 2h","prompt":"y"},{"id":"d","when":"on open","prompt":"z"}]"#
        let routines = try? JSONDecoder().decode([Routine].self, from: Data(kept.utf8))
        #expect(routines?.count == 4)
        #expect(routines?.allSatisfy { Routines.schedule($0.when) != nil } == true)
        #expect(Self.say("weekdays 9:00") == "Weekdays at 9:00 AM")
        #expect(Self.say("mon,thu 8:15") == "Mondays and Thursdays at 8:15 AM")
        #expect(RoutineWhen.join(RoutineWhen.split("mon,thu 8:15")) == "mon,thu 8:15")
        #expect(RoutineWhen.join(RoutineWhen.split("weekdays 9:00")) == "weekdays 9:00")
        #expect(RoutineWhen.join(RoutineWhen.split("every 2h")) == "every 2h")
    }

    @Test func newForms() {
        #expect(Routines.schedule("monthly 1 9:00") == .days(.month(1), at: [540]))
        #expect(Routines.schedule("on the 1st 9:00") == .days(.month(1), at: [540]))
        #expect(Routines.schedule("15th 10:00") == .days(.month(15), at: [600]))
        #expect(Routines.schedule("every month on the 22nd at 9:00") == .days(.month(22), at: [540]))
        #expect(Routines.schedule("monthly last 18:00") == .days(.month(0), at: [1080]))
        #expect(Routines.schedule("last day of month 18:00") == .days(.month(0), at: [1080]))
        #expect(Routines.schedule("first monday 9:00") == .days(.nth(1, weekday: 2), at: [540]))
        #expect(Routines.schedule("monthly third wed 9:00") == .days(.nth(3, weekday: 4), at: [540]))
        #expect(Routines.schedule("last friday 17:00") == .days(.nth(-1, weekday: 6), at: [1020]))
        #expect(Routines.schedule("every 3 days 9:00") == .days(.cycle(3), at: [540]))
        #expect(Routines.schedule("every other day 9:00") == .days(.cycle(2), at: [540]))
        #expect(Routines.schedule("every 2 weeks mon 9:00") == .days(.weeks(2, [2]), at: [540]))
        #expect(Routines.schedule("every 3 weeks mon,thu 9:00") == .days(.weeks(3, [2, 5]), at: [540]))
        #expect(Routines.schedule("every week fri 9:00") == .days(.week([6]), at: [540]))
        #expect(Routines.schedule("yearly oct 6 9:00") == .days(.year(month: 10, day: 6), at: [540]))
        #expect(Routines.schedule("every oct 6 9:00") == .days(.year(month: 10, day: 6), at: [540]))
        #expect(Routines.schedule("6 october 9:00") == .days(.year(month: 10, day: 6), at: [540]))
        #expect(Routines.schedule("yearly feb 29 9:00") == .days(.year(month: 2, day: 29), at: [540]))
        #expect(Routines.schedule("daily 9:00,18:00") == .days(.week(Set(1...7)), at: [540, 1080]))
        #expect(Routines.schedule("daily 18:00, 9:00") == .days(.week(Set(1...7)), at: [540, 1080]))
        #expect(Routines.schedule("monthly 1 9:00,13:30") == .days(.month(1), at: [540, 810]))
        for words in ["monthly 32 9:00", "monthly 9:00", "15 10:00", "yearly feb 30 9:00", "every 2 weeks 9:00", "every 0 days 9:00",
                      "sixth monday 9:00", "last 9:00", "yearly mon 9:00", "every 3 days"] {
            #expect(Routines.schedule(words) == nil, "\(words)")
        }
    }

    @Test func keptWordsReadBack() {
        let schedules: [Routines.Schedule] = [
            .days(.week(Set(1...7)), at: [540, 1080]), .days(.week([2, 5]), at: [495]), .days(.month(1), at: [540]),
            .days(.month(0), at: [1080]), .days(.nth(1, weekday: 2), at: [540]), .days(.nth(-1, weekday: 6), at: [1020]),
            .days(.cycle(3), at: [540]), .days(.weeks(2, [2, 5]), at: [540]), .days(.year(month: 10, day: 6), at: [540]),
            .every(3600), .every(7200), .every(1800), .opens,
        ]
        for schedule in schedules { #expect(Routines.schedule(Routines.words(schedule)) == schedule, "\(Routines.words(schedule))") }
        #expect(Routines.words(.days(.month(0), at: [1080])) == "monthly last 18:00")
        #expect(Routines.words(.days(.weeks(2, [2]), at: [540])) == "every 2 weeks mon 9:00")
        #expect(Routines.words(.days(.year(month: 10, day: 6), at: [540])) == "yearly oct 6 9:00")
    }

    @Test func saidInWords() {
        #expect(Self.say("monthly 1 9:00") == "Monthly on the 1st at 9:00 AM")
        #expect(Self.say("on the 22nd 9:00") == "Monthly on the 22nd at 9:00 AM")
        #expect(Self.say("monthly 13 9:00") == "Monthly on the 13th at 9:00 AM")
        #expect(Self.say("monthly last 18:00") == "Monthly on the last day at 6:00 PM")
        #expect(Self.say("first monday 9:00") == "Monthly on the first Monday at 9:00 AM")
        #expect(Self.say("last fri 17:00") == "Monthly on the last Friday at 5:00 PM")
        #expect(Self.say("every 3 days 9:00") == "Every 3 days at 9:00 AM")
        #expect(Self.say("every 2 weeks mon 9:00") == "Every 2 weeks on Mondays at 9:00 AM")
        #expect(Self.say("yearly oct 6 9:00") == "Every year on October 6 at 9:00 AM")
        #expect(Self.say("daily 9:00,18:00") == "Every day at 9:00 AM and 6:00 PM")
        #expect(Self.say("weekdays 9:00,13:00,18:00") == "Weekdays at 9:00 AM, 1:00 PM and 6:00 PM")
        // A table cell's words: its first time and how many more.
        func short(_ when: String) -> String { Routines.short(when, locale: Self.us).replacingOccurrences(of: "\u{202F}", with: " ") }
        #expect(short("weekdays 9:00") == "Weekdays 9:00 AM")
        #expect(short("monthly 1 9:00") == "On the 1st 9:00 AM")
        #expect(short("monthly last 18:00") == "Last day 6:00 PM")
        #expect(short("last friday 17:00,18:00") == "Last Fri 5:00 PM +1")
        #expect(short("yearly oct 6 9:00") == "Oct 6 9:00 AM")
        #expect(short("every 2h") == "Every 2 hours")
    }

    @Test func nextRuns() {
        // The 31st in a short month is its last day; the last day is the last.
        #expect(Self.next("monthly 31 9:00", after: Self.at(2026, 2, 10)) == Self.at(2026, 2, 28, 9))
        #expect(Self.next("monthly 31 9:00", after: Self.at(2026, 4, 1)) == Self.at(2026, 4, 30, 9))
        #expect(Self.next("monthly 31 9:00", after: Self.at(2026, 5, 1)) == Self.at(2026, 5, 31, 9))
        #expect(Self.next("monthly last 18:00", after: Self.at(2026, 2, 28, 19)) == Self.at(2026, 3, 31, 18))
        #expect(Self.next("monthly 1 9:00", after: Self.at(2026, 10, 6, 12)) == Self.at(2026, 11, 1, 9))
        #expect(Self.next("on the 1st 9:00", after: Self.at(2026, 11, 1, 8)) == Self.at(2026, 11, 1, 9))
        // Oct 6, 2026 is a Tuesday; Nov 1 a Sunday, Oct 31 a Saturday.
        #expect(Self.next("first monday 9:00", after: Self.at(2026, 10, 6)) == Self.at(2026, 11, 2, 9))
        #expect(Self.next("last friday 17:00", after: Self.at(2026, 10, 6)) == Self.at(2026, 10, 30, 17))
        #expect(Self.next("fifth friday 9:00", after: Self.at(2026, 11, 1)) == Self.at(2027, 1, 29, 9))
        // Feb 29 on Feb 28 in other years, on the 29th in a leap one.
        #expect(Self.next("yearly feb 29 9:00", after: Self.at(2027, 1, 1)) == Self.at(2027, 2, 28, 9))
        #expect(Self.next("yearly feb 29 9:00", after: Self.at(2027, 3, 1)) == Self.at(2028, 2, 29, 9))
        #expect(Self.next("yearly oct 6 9:00", after: Self.at(2026, 10, 6, 10)) == Self.at(2027, 10, 6, 9))
        // Several times a day.
        #expect(Self.next("daily 9:00,18:00", after: Self.at(2026, 10, 6, 10)) == Self.at(2026, 10, 6, 18))
        #expect(Self.next("daily 9:00,18:00", after: Self.at(2026, 10, 6, 19)) == Self.at(2026, 10, 7, 9))
        // Gaps count from the last run's day, that day itself included.
        #expect(Self.next("every 3 days 9:00", after: Self.at(2026, 10, 6, 10)) == Self.at(2026, 10, 9, 9))
        #expect(Self.next("every 3 days 9:00", after: Self.at(2026, 10, 6, 8)) == Self.at(2026, 10, 6, 9))
        #expect(Self.next("every 3 days 9:00", after: Self.at(2026, 10, 20), last: Self.at(2026, 10, 6, 9)) == Self.at(2026, 10, 21, 9))
        // Weeks from the Monday of the last run's week (Oct 5).
        #expect(Self.next("every 2 weeks mon 9:00", after: Self.at(2026, 10, 6)) == Self.at(2026, 10, 19, 9))
        #expect(Self.next("every 2 weeks mon,thu 9:00", after: Self.at(2026, 10, 6)) == Self.at(2026, 10, 8, 9))
        #expect(Self.next("every 2 weeks mon,thu 9:00", after: Self.at(2026, 10, 8, 10)) == Self.at(2026, 10, 19, 9))
        // Clocks forward on Mar 8: 9:00 is still 9:00, 23 hours after the day before's.
        let before = Self.at(2026, 3, 7, 9), after = Self.next("daily 9:00", after: Self.at(2026, 3, 7, 10))!
        #expect(Self.calendar.component(.hour, from: after) == 9)
        #expect(after.timeIntervalSince(before) == 23 * 3600)
        // 2:30 doesn't exist that night: it runs the moment after, that day.
        let skipped = Self.next("daily 2:30", after: Self.at(2026, 3, 7, 12))!
        #expect(Self.calendar.isDate(skipped, inSameDayAs: Self.at(2026, 3, 8, 12)))
        #expect(skipped > Self.at(2026, 3, 8, 1, 59) && skipped < Self.at(2026, 3, 8, 4))
        // Clocks back on Nov 1: 1:30 comes twice, it runs once.
        let twice = Self.next("daily 1:30", after: Self.at(2026, 10, 31, 12))!
        #expect(Self.next("daily 1:30", after: twice, last: twice).map { $0.timeIntervalSince(twice) > 20 * 3600 } == true)
    }

    @Test func aRunMissedWhileClosed() {
        let monthly = Routines.schedule("monthly 1 9:00")!
        let last = Self.at(2026, 10, 1, 9, 1)
        // Back the same day: it runs once, then not again that day.
        #expect(Routines.due(monthly, before: Self.at(2026, 11, 1, 15), since: last, calendar: Self.calendar) == Self.at(2026, 11, 1, 9))
        #expect(Routines.owed(monthly, last: last, now: Self.at(2026, 11, 1, 15), calendar: Self.calendar))
        #expect(!Routines.owed(monthly, last: Self.at(2026, 11, 1, 15), now: Self.at(2026, 11, 1, 16), calendar: Self.calendar))
        // Missed by more than twenty hours: the next time is the next one.
        #expect(!Routines.owed(monthly, last: last, now: Self.at(2026, 11, 2, 10), calendar: Self.calendar))
        // A gap of days owes its run on its day, counted from the last.
        let cycle = Routines.schedule("every 3 days 9:00")!
        let ran = Self.at(2026, 10, 6, 9, 0)
        #expect(!Routines.owed(cycle, last: ran.addingTimeInterval(30), now: Self.at(2026, 10, 8, 9, 30), calendar: Self.calendar))
        #expect(Routines.owed(cycle, last: ran.addingTimeInterval(30), now: Self.at(2026, 10, 9, 9, 1), calendar: Self.calendar))
        // Several times a day: the 9:00 missed, the 18:00 run, once.
        let twice = Routines.schedule("daily 9:00,18:00")!
        #expect(Routines.due(twice, before: Self.at(2026, 10, 6, 18, 5), since: nil, calendar: Self.calendar) == Self.at(2026, 10, 6, 18))
        #expect(Routines.owed(twice, last: Self.at(2026, 10, 5, 18), now: Self.at(2026, 10, 6, 18, 5), calendar: Self.calendar))
    }

    @Test func theEditorsMenus() {
        var parts = RoutineWhen.split("on the 1st 9:00")
        #expect(parts.repeats == RoutineWhen.monthly && parts.which == 0 && parts.monthDay == 1)
        #expect(RoutineWhen.join(parts) == "monthly 1 9:00")
        parts.which = -1
        parts.weekday = 6
        #expect(RoutineWhen.join(parts) == "last fri 9:00")
        parts = RoutineWhen.split("first monday 9:00")
        #expect(parts.which == 1 && parts.weekday == 2)
        parts = RoutineWhen.split("yearly feb 29 9:00")
        #expect(parts.repeats == RoutineWhen.yearly && parts.month == 2 && parts.yearDay == 29)
        parts.month = 4
        parts.yearDay = 31
        #expect(RoutineWhen.join(parts) == "yearly apr 30 9:00")
        parts = RoutineWhen.split("every 2 weeks mon,thu 9:00")
        #expect(parts.repeats == RoutineWhen.everyWeeks && parts.gap == 2 && parts.days == [2, 5])
        #expect(RoutineWhen.join(parts) == "every 2 weeks mon,thu 9:00")
        parts = RoutineWhen.split("every 3 days 9:00")
        #expect(parts.repeats == RoutineWhen.everyDays && parts.gap == 3)
        parts = RoutineWhen.split("daily 18:00,9:00")
        #expect(parts.repeats == "daily" && parts.minutes == [540, 1080])
        #expect(RoutineWhen.join(parts) == "daily 9:00,18:00")
        parts.repeats = RoutineWhen.monthly
        parts.which = 0
        parts.monthDay = 0
        #expect(RoutineWhen.join(parts) == "monthly last 9:00,18:00")
        // The row's quick menu keeps every time.
        #expect(Routines.quickTimes("daily 9:00,18:00").contains { $0.value == "weekdays 9:00,18:00" })
        // Every choice the editor offers makes words that read.
        for key in RoutineWhen.often {
            var made = RoutineWhen.split("weekdays 9:00")
            made.repeats = key
            #expect(Routines.schedule(RoutineWhen.join(made)) != nil, "\(key)")
        }
    }

    @Test func aCommandLinesWhen() {
        #expect(Routines.leading(["3", "days", "9:00", "check", "it"])! == ("every 3 days 9:00", ["check", "it"]))
        #expect(Routines.leading(["weekdays 9:00", "check my mail"])! == ("weekdays 9:00", ["check my mail"]))
        #expect(Routines.leading(["weekdays", "9:00", "check"])! == ("weekdays 9:00", ["check"]))
        #expect(Routines.leading(["first", "monday", "9:00", "pay", "rent"])! == ("first monday 9:00", ["pay", "rent"]))
        #expect(Routines.leading(["2h", "look"])! == ("every 2h", ["look"]))
        #expect(Routines.leading(["morning", "check", "my", "mail"]) == nil)
        #expect(Routines.leading(["list"]) == nil)
    }
}
