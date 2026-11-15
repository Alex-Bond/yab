import Foundation
import Testing
@testable import MailCore

// A date in a mail becomes an event (docs/mail.md, Calendar): which dates
// are found (a day named, still ahead, not quoted, words with no date of
// their own read from the mail's day), where they are marked in a mail's
// HTML, and the event a thread makes of one, in words and in Google
// Calendar's.

struct MailEventTests {
    static let calendar = Calendar.current

    static func parts(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    static func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - which dates

    @Test func aRangeWithItsDay() {
        let found = MailDates.find("Let\u{2019}s have CES and CSMs meet on June 17, 2027 from 3pm to 3:30pm to walk through FTUE.", sent: Date())
        #expect(found.count == 1)
        guard let date = found.first else { return }
        #expect(Self.parts(date.start) == DateComponents(year: 2027, month: 6, day: 17, hour: 15, minute: 0))
        #expect(date.end.map(Self.parts) == DateComponents(year: 2027, month: 6, day: 17, hour: 15, minute: 30))
        #expect(!date.allDay)
        #expect(date.words.contains("June 17"))
    }

    @Test func aTimeAloneIsNoDate() {
        #expect(MailDates.find("Call me at 3pm, or at 4:30 if that\u{2019}s easier.", sent: Date()).isEmpty)
    }

    @Test func overIsLeftOut() {
        #expect(MailDates.find("We met on March 3, 2025 at 10am.", sent: Self.day(2025, 3, 1)).isEmpty)
    }

    @Test func tooFarOffIsLeftOut() {
        #expect(MailDates.find("The lease ends on June 1, 2040.", sent: Date()).isEmpty)
    }

    /// "Due by" a day is that day, marked from the day on.
    @Test func aDayThingsEndByIsThatDay() {
        let found = MailDates.find("The deck is due by June 17, 2027.", sent: Date())
        #expect(found.first?.start == Self.day(2027, 6, 17))
        #expect(found.first?.words == "June 17, 2027")
    }

    @Test func aDayAloneIsAllDay() {
        let found = MailDates.find("The offsite is on June 17, 2027.", sent: Date())
        #expect(found.count == 1)
        #expect(found.first?.allDay == true)
        #expect(found.first?.start == Self.day(2027, 6, 17))
    }

    @Test func quotedLinesAreLeftOut() {
        let text = "Works for me.\n> On Monday Anna wrote:\n> See you on June 17, 2027 at 3pm\nAnd June 18, 2027 at 4pm too?"
        let found = MailDates.find(text, sent: Date())
        #expect(found.count == 1)
        #expect(found.first.map { Self.parts($0.start).day } == 18)
    }

    /// A weekday or tomorrow, from the mail's own day: Monday March 1, 2027.
    @Test func wordsWithNoDateAreReadFromTheMailsDay() {
        let sent = Self.day(2027, 3, 1, 9)
        let now = Self.day(2027, 2, 28)
        let friday = MailDates.find("Can we talk Friday at 10am?", sent: sent, now: now)
        #expect(friday.first.map { Self.parts($0.start) } == DateComponents(year: 2027, month: 3, day: 5, hour: 10, minute: 0))
        let tomorrow = MailDates.find("How about tomorrow at 2pm?", sent: sent, now: now)
        #expect(tomorrow.first.map { Self.parts($0.start) } == DateComponents(year: 2027, month: 3, day: 2, hour: 14, minute: 0))
    }

    @Test func oldMailsTomorrowIsOver() {
        #expect(MailDates.find("How about tomorrow at 2pm?", sent: Self.day(2026, 9, 1, 9)).isEmpty)
    }

    // MARK: - in HTML

    @Test func marksTheMailsOwnWordsOnly() {
        let html = """
        <style>p{margin:0} /* June 20, 2027 at 1pm */</style>\
        <div>Meet on <b>June 17, 2027 at 3pm</b>?</div>\
        <div>Or <a href="https://example.com">June 19, 2027 at 1pm</a></div>\
        <div class="gmail_quote"><div>On Jun 1, 2027 at 9:00 AM Anna wrote:</div><div>see you June 18, 2027 at 4pm</div></div>
        """
        let marked = MailDates.marked(html, sent: Date())
        #expect(marked.found.count == 1)
        #expect(marked.html.contains("<b><a href=\"yab-mail-date:0\""))
        #expect(marked.html.contains(">June 17, 2027 at 3pm</a></b>"))
        // The rest as it was.
        #expect(marked.html.contains("<a href=\"https://example.com\">June 19, 2027 at 1pm</a>"))
        #expect(marked.html.contains("<div>see you June 18, 2027 at 4pm</div>"))
        #expect(marked.html.contains("/* June 20, 2027 at 1pm */"))
        #expect(marked.html.replacingOccurrences(of: #"<a href="yab-mail-date:0" style="[^"]*">"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "3pm</a></b>", with: "3pm</b>") == html)
    }

    @Test func entitiesAreReadAndKept() {
        let marked = MailDates.marked("<p>Dinner on June&nbsp;17, 2027 at 7pm &amp; drinks</p>", sent: Date(), first: 2)
        #expect(marked.found.count == 1)
        #expect(marked.html.contains("<a href=\"yab-mail-date:2\""))
        #expect(marked.html.contains(">June&nbsp;17, 2027 at 7pm</a> &amp; drinks"))
    }

    @Test func decodedKeepsWhereEachUnitWas() {
        let (text, map) = MailDates.decoded("a&amp;b&#8211;c")
        #expect(text == "a&b\u{2013}c")
        #expect(map == [0, 1, 6, 7, 14, 15])
    }

    @Test func aMarksAddress() {
        #expect(MailDates.index(URL(string: "yab-mail-date:3")!) == 3)
        #expect(MailDates.index(URL(string: "https://example.com/3")!) == nil)
    }

    // MARK: - the event

    static let sinead = MailPerson(name: "Sinead Torres", address: "sinead@example.com")

    @Test func theEventAThreadMakes() {
        let start = Self.day(2027, 6, 17, 15)
        let date = MailDates.Found(range: NSRange(location: 0, length: 4), words: "June 17, 2027 at 3pm", start: start, end: nil, allDay: false)
        let event = MailEvent.make(subject: "Re: Fwd: FTUE Walkthrough", date: date,
                                   people: [Self.sinead, MailPerson(name: "Me", address: "ME@x.com"),
                                            MailPerson(name: "Calendar", address: "calendar-notifications@google.com"),
                                            MailPerson(name: "Sinead", address: "Sinead@example.com")],
                                   me: ["me@x.com"], words: ["Thanks!", "Join at https://meet.google.com/abc-defg-hij please"], slot: 45)
        #expect(event.title == "FTUE Walkthrough")
        #expect(event.start == start)
        #expect(event.end == start.addingTimeInterval(45 * 60))
        #expect(event.people == [Self.sinead])
        #expect(event.place == "https://meet.google.com/abc-defg-hij")
        #expect(event.whereSaid == "Google Meet")
        #expect(event.who == "Sinead Torres, you")
        #expect(event.with == "With Sinead \u{00B7} Google Meet")
        var crowd = event
        crowd.people += [MailPerson(name: "Mark Chen", address: "mark@example.com"), MailPerson(name: "", address: "kenji@example.com")]
        crowd.place = ""
        #expect(crowd.with == "With Sinead, Mark and 1 more")
        crowd.people = []
        #expect(crowd.with == nil)
    }

    @Test func aWrittenRangeAndAnAllDayEvent() {
        let start = Self.day(2027, 6, 17, 15)
        let ranged = MailDates.Found(range: NSRange(), words: "", start: start, end: start.addingTimeInterval(1800), allDay: false)
        #expect(MailEvent.make(subject: "", date: ranged, people: [], me: [], words: [], slot: 60).end == start.addingTimeInterval(1800))
        let day = MailDates.Found(range: NSRange(), words: "", start: Self.day(2027, 6, 17), end: nil, allDay: true)
        let event = MailEvent.make(subject: "", date: day, people: [], me: [], words: ["No link here"], slot: 30)
        #expect(event.title == "New Event")
        #expect(event.end == Self.day(2027, 6, 18))
        #expect(event.place.isEmpty)
        #expect(event.who == "you")
    }

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func spaced(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2009}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    @Test func whenInWords() {
        let start = Self.utc.date(from: DateComponents(year: 2027, month: 6, day: 17, hour: 15))!
        let now = Self.utc.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        let us = Locale(identifier: "en_US")
        let timed = MailEvent(title: "x", start: start, end: start.addingTimeInterval(1800), allDay: false)
        #expect(Self.spaced(timed.when(calendar: Self.utc, locale: us, now: now)) == "Thu, Jun 17 \u{00B7} 3:00 – 3:30 PM")
        let day = Self.utc.startOfDay(for: start)
        let allDay = MailEvent(title: "x", start: day, end: day.addingTimeInterval(86_400), allDay: true)
        #expect(Self.spaced(allDay.when(calendar: Self.utc, locale: us, now: now)) == "Thu, Jun 17")
        #expect(Self.spaced(allDay.when(calendar: Self.utc, locale: us, now: Self.utc.date(from: DateComponents(year: 2026, month: 1, day: 1))!))
                    .contains("2027"))
    }

    @Test func inGoogleCalendarsWords() {
        let utc = TimeZone(identifier: "UTC")!
        let start = Self.utc.date(from: DateComponents(year: 2027, month: 6, day: 17, hour: 15))!
        let timed = MailEvent(title: "FTUE", start: start, end: start.addingTimeInterval(1800), allDay: false,
                              people: [Self.sinead], place: "https://meet.google.com/abc-defg-hij").google(zone: utc)
        #expect(timed["summary"] as? String == "FTUE")
        #expect((timed["start"] as? [String: String])?["dateTime"] == "2027-06-17T15:00:00Z")
        #expect((timed["end"] as? [String: String])?["dateTime"] == "2027-06-17T15:30:00Z")
        #expect((timed["start"] as? [String: String])?["timeZone"] == utc.identifier)
        #expect(timed["location"] as? String == "https://meet.google.com/abc-defg-hij")
        let attendees = timed["attendees"] as? [[String: Any]]
        #expect(attendees?.first?["email"] as? String == "sinead@example.com")
        #expect(attendees?.first?["displayName"] as? String == "Sinead Torres")
        let day = Self.utc.startOfDay(for: start)
        let allDay = MailEvent(title: "Offsite", start: day, end: day.addingTimeInterval(86_400), allDay: true).google(zone: utc)
        #expect((allDay["start"] as? [String: String])?["date"] == "2027-06-17")
        #expect((allDay["end"] as? [String: String])?["date"] == "2027-06-18")
        #expect(allDay["attendees"] == nil)
    }

    /// Making events is never asked for: Connect asks what it asked before.
    @Test func connectNeverAsksToMakeEvents() {
        for listing in [false, true] {
            #expect(!MailClient.scopes(listing: listing).split(separator: " ").contains { $0 == MailClient.eventsScope })
        }
        #expect(MailGrant(refresh: "", access: "", scopes: MailClient.calendarScope).calendarWrite == false)
        #expect(MailGrant(refresh: "", access: "", scopes: MailClient.calendarScope + " " + MailClient.eventsScope).calendarWrite)
    }
}
