import Foundation
import Testing
@testable import MailCore

// Free slots (docs/mail.md, Calendar): the free time of the next five
// working days, in working hours, a slot's length at a time, round what is
// busy; said as text with the zone, slots side by side as one, a change of
// time between them said too; the booking link after them.

struct MailSlotsTests {
    /// A calendar of a zone, as the Mac's would be.
    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// A wall time in a calendar's zone.
    static func at(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static let weekdays: Set<Int> = [2, 3, 4, 5, 6]
    let berlin = MailSlotsTests.calendar("Europe/Berlin")

    @Test func roundWhatIsBusyInWorkingHours() {
        // Tuesday, Oct 6 2026, 8:00: the whole working day ahead.
        let now = Self.at(berlin, 2026, 10, 6, 8)
        let busy = [
            BusyTime(title: "Review", start: Self.at(berlin, 2026, 10, 6, 10), end: Self.at(berlin, 2026, 10, 6, 11)),
            BusyTime(title: "Call", start: Self.at(berlin, 2026, 10, 6, 14, 15), end: Self.at(berlin, 2026, 10, 6, 14, 45)),
            // Nothing of no length is busy.
            BusyTime(title: "Reminder", start: Self.at(berlin, 2026, 10, 6, 9), end: Self.at(berlin, 2026, 10, 6, 9)),
        ]
        let hours = MailSlots.Hours(start: 9 * 60, end: 18 * 60, length: 30, days: Self.weekdays)
        let slots = MailSlots.free(busy: busy, from: now, hours: hours, days: 1, calendar: berlin)
        let said = slots.map { MailICS.format("H:mm", berlin.timeZone).string(from: $0.start) }
        #expect(said.first == "9:00")
        #expect(!said.contains("10:00") && !said.contains("10:30") && said.contains("11:00"))
        // 14:15 to 14:45 takes both slots it touches.
        #expect(!said.contains("14:00") && !said.contains("14:30") && said.contains("15:00"))
        #expect(said.last == "17:30")
        #expect(slots.count == 18 - 4)
        #expect(slots.allSatisfy { $0.duration == 30 * 60 })
    }

    @Test func fromNowOnFiveWorkingDaysWeekendsLeftOut() {
        // Thursday, Oct 8 2026, 15:10: today's slots from 15:30, then Fri,
        // Mon, Tue, Wed; no weekend.
        let now = Self.at(berlin, 2026, 10, 8, 15, 10)
        let hours = MailSlots.Hours(start: 9 * 60, end: 18 * 60, length: 60, days: Self.weekdays)
        let slots = MailSlots.free(busy: [], from: now, hours: hours, calendar: berlin)
        let days = Set(slots.map { MailICS.format("EEE d", berlin.timeZone).string(from: $0.start) })
        #expect(days == ["Thu 8", "Fri 9", "Mon 12", "Tue 13", "Wed 14"])
        // The grid is the working day's, an hour a slot: today's next is at 16:00.
        #expect(slots.first?.start == Self.at(berlin, 2026, 10, 8, 16))
        #expect(slots.filter { berlin.isDate($0.start, inSameDayAs: now) }.count == 2)
        // Today's hours over: it isn't one of the five.
        let late = MailSlots.free(busy: [], from: Self.at(berlin, 2026, 10, 8, 17, 45), hours: hours, calendar: berlin)
        let lateDays = Set(late.map { MailICS.format("EEE d", berlin.timeZone).string(from: $0.start) })
        #expect(lateDays == ["Fri 9", "Mon 12", "Tue 13", "Wed 14", "Thu 15"])
        // Hours of your own: 10 to 12.
        let short = MailSlots.free(busy: [], from: Self.at(berlin, 2026, 10, 12, 7), hours: MailSlots.Hours(start: 600, end: 720, length: 30, days: Self.weekdays),
                                   days: 1, calendar: berlin)
        #expect(short.map { MailICS.format("H:mm", berlin.timeZone).string(from: $0.start) } == ["10:00", "10:30", "11:00", "11:30"])
    }

    @Test func theFirstOfTheNextThreeDaysOffered() {
        let now = Self.at(berlin, 2026, 10, 6, 8)
        let hours = MailSlots.Hours(start: 9 * 60, end: 18 * 60, length: 30, days: Self.weekdays)
        let busy = [BusyTime(title: "Offsite", start: Self.at(berlin, 2026, 10, 7, 0), end: Self.at(berlin, 2026, 10, 7, 13))]
        let slots = MailSlots.free(busy: busy, from: now, hours: hours, calendar: berlin)
        let offered = MailSlots.suggested(slots, now: now, calendar: berlin)
        // Not today; Wednesday's first free one is after the offsite.
        #expect(offered.map(\.start) == [Self.at(berlin, 2026, 10, 7, 13), Self.at(berlin, 2026, 10, 8, 9), Self.at(berlin, 2026, 10, 9, 9)])
    }

    @Test func saidWithTheZoneSlotsSideBySideAsOne() {
        let now = Self.at(berlin, 2026, 10, 5, 9)
        let slots = [
            DateInterval(start: Self.at(berlin, 2026, 10, 6, 14), duration: 1800),
            DateInterval(start: Self.at(berlin, 2026, 10, 7, 10), duration: 1800),
            DateInterval(start: Self.at(berlin, 2026, 10, 7, 10, 30), duration: 1800),
        ]
        #expect(MailSlots.text(slots, now: now, calendar: berlin) == "Tue 14:00–14:30, Wed 10:00–11:00 (CEST)")
        // In winter, CET; in New York, its own.
        let winter = [DateInterval(start: Self.at(berlin, 2026, 12, 1, 14), duration: 1800), DateInterval(start: Self.at(berlin, 2026, 12, 2, 10), duration: 3600)]
        #expect(MailSlots.text(winter, now: Self.at(berlin, 2026, 11, 30, 9), calendar: berlin) == "Tue 14:00–14:30, Wed 10:00–11:00 (CET)")
        let york = Self.calendar("America/New_York")
        #expect(MailSlots.text(slots, now: now, calendar: york) == "Tue 8:00–8:30, Wed 4:00–5:00 (EDT)")
        // The booking link on a line after them; alone with none picked.
        #expect(MailSlots.text(Array(slots.prefix(1)), booking: " https://cal.com/sam ", now: now, calendar: berlin)
                == "Tue 14:00–14:30 (CEST)\nOr book a time: https://cal.com/sam")
        #expect(MailSlots.text([], booking: "https://cal.com/sam", now: now, calendar: berlin) == "Book a time: https://cal.com/sam")
        #expect(MailSlots.text([], now: now, calendar: berlin).isEmpty)
        // A week or more ahead, the date says which day.
        let later = [slots[0], DateInterval(start: slots[0].start.addingTimeInterval(7 * 86_400), duration: 1800)]
        #expect(MailSlots.text(later, now: now, calendar: berlin) == "Tue Oct 6 14:00–14:30, Tue Oct 13 14:00–14:30 (CEST)")
    }

    /// Across a change of time: New York leaves daylight time on Sunday,
    /// Nov 1 2026. 9:00 stays 9:00 on the wall clock, an hour later in UTC,
    /// and each day's zone is said where they differ.
    @Test func aChangeOfTimeMovesNoSlot() {
        let york = Self.calendar("America/New_York")
        let now = Self.at(york, 2026, 10, 29, 8)
        let hours = MailSlots.Hours(start: 9 * 60, end: 17 * 60, length: 30, days: Self.weekdays)
        let slots = MailSlots.free(busy: [], from: now, hours: hours, days: 3, calendar: york)
        let thursday = slots.first { york.component(.day, from: $0.start) == 29 }
        let monday = slots.first { york.component(.day, from: $0.start) == 2 }
        #expect(thursday?.start == ISO8601DateFormatter().date(from: "2026-10-29T13:00:00Z"))
        #expect(monday?.start == ISO8601DateFormatter().date(from: "2026-11-02T14:00:00Z"))
        #expect(slots.filter { york.component(.day, from: $0.start) == 2 }.count == 16)
        let said = MailSlots.text([thursday!, monday!], now: now, calendar: york)
        #expect(said == "Thu 9:00–9:30 (EDT), Mon 9:00–9:30 (EST)")
        // In Europe the same week turned on Oct 25: Berlin's busy hour is still its own.
        let busy = [BusyTime(title: "Standup", start: Self.at(berlin, 2026, 10, 26, 9), end: Self.at(berlin, 2026, 10, 26, 9, 30))]
        let free = MailSlots.free(busy: busy, from: Self.at(berlin, 2026, 10, 23, 18), hours: hours, days: 2, calendar: berlin)
        #expect(free.first?.start == Self.at(berlin, 2026, 10, 26, 9, 30))
    }

    @Test func zonesAsPeopleWriteThem() {
        let winter = ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z")!
        let summer = ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z")!
        let said = { (zone: String, at: Date) in MailSlots.said(TimeZone(identifier: zone)!, at: at) }
        #expect(said("Europe/Berlin", winter) == "CET" && said("Europe/Berlin", summer) == "CEST")
        #expect(said("America/New_York", winter) == "EST" && said("America/Los_Angeles", summer) == "PDT")
        #expect(said("Europe/London", winter) == "GMT" && said("Europe/London", summer) == "BST")
        #expect(said("Asia/Kolkata", winter) == "IST")
        // No name in English: the offset.
        #expect(said("Europe/Moscow", winter) == "GMT+3")
    }

    @Test func settingsKeepTheirHoursAndLength() {
        let hours = MailSlots.Hours()
        #expect(hours.start == 540 && hours.end == 1080 && hours.length == 30 && hours.days == nil)
        #expect(MailSlots.lengths.contains(hours.length))
        // Merged as people say them: touching or overlapping, one.
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let merged = MailSlots.merged([DateInterval(start: start.addingTimeInterval(1800), duration: 1800), DateInterval(start: start, duration: 1800),
                                       DateInterval(start: start.addingTimeInterval(7200), duration: 1800)])
        #expect(merged == [DateInterval(start: start, duration: 3600), DateInterval(start: start.addingTimeInterval(7200), duration: 1800)])
    }
}
