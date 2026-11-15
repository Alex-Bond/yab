import Foundation
import Testing
@testable import Fast
@testable import MailCore

/// Google Calendar's events as the API answers them, turned into meetings.
struct MeetingsGoogleTests {
    private func event(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    @Test func aMeetCallIsAMeetingWithItsLinkAndPeople() throws {
        let meeting = try #require(MeetingsGoogle.meeting(event("""
        {"id": "abc", "status": "confirmed", "eventType": "default", "summary": "Weekly sync",
         "start": {"dateTime": "2026-10-01T08:00:00-07:00"}, "end": {"dateTime": "2026-10-01T08:30:00-07:00"},
         "hangoutLink": "https://meet.google.com/srz-qvzy-tcx",
         "attendees": [{"email": "me@example.com", "self": true, "responseStatus": "accepted"},
                       {"email": "Daniel@Example.com", "responseStatus": "accepted"}]}
        """), account: "me@example.com"))
        #expect(meeting.title == "Weekly sync")
        #expect(meeting.start == ISO8601DateFormatter().date(from: "2026-10-01T15:00:00Z"))
        #expect(meeting.link?.absoluteString == "https://meet.google.com/srz-qvzy-tcx")
        #expect(meeting.people == ["daniel@example.com"])
        #expect(meeting.id.hasSuffix("|me@example.com"))
    }

    @Test func theCallComesFromConferenceDataWithoutAHangoutLink() {
        let meeting = MeetingsGoogle.meeting(event("""
        {"id": "z", "summary": "Zoom", "start": {"dateTime": "2026-10-01T08:00:00Z"}, "end": {"dateTime": "2026-10-01T09:00:00Z"},
         "conferenceData": {"entryPoints": [{"entryPointType": "phone", "uri": "tel:+1"},
                                            {"entryPointType": "video", "uri": "https://us02web.zoom.us/j/123456789"}]}}
        """), account: "a")
        #expect(meeting?.link?.host() == "us02web.zoom.us")
    }

    @Test func allDayCancelledDeclinedAndOutOfOfficeAreLeftOut() {
        let allDay = #"{"id": "d", "start": {"date": "2026-10-01"}, "end": {"date": "2026-10-02"}}"#
        let cancelled = #"{"id": "c", "status": "cancelled", "start": {"dateTime": "2026-10-01T08:00:00Z"}, "end": {"dateTime": "2026-10-01T09:00:00Z"}}"#
        let declined = #"{"id": "n", "start": {"dateTime": "2026-10-01T08:00:00Z"}, "end": {"dateTime": "2026-10-01T09:00:00Z"}, "attendees": [{"email": "me@x.com", "self": true, "responseStatus": "declined"}]}"#
        let away = #"{"id": "o", "eventType": "outOfOffice", "start": {"dateTime": "2026-10-01T08:00:00Z"}, "end": {"dateTime": "2026-10-01T09:00:00Z"}}"#
        for json in [allDay, cancelled, declined, away] {
            #expect(MeetingsGoogle.meeting(event(json), account: "me@x.com") == nil)
        }
    }

    @Test func calendarIsKnownFromTheScopesGoogleGave() {
        let both = MailGrant(refresh: "r", access: "a", scopes: "\(MailClient.scope) \(MailClient.calendarScope)")
        let mailOnly = MailGrant(refresh: "r", access: "a", scopes: MailClient.scope)
        #expect(both.calendar)
        #expect(!mailOnly.calendar)
    }

    @Test func theListIsTheTickedCalendarsPrimaryFirstWithoutGooglesOwn() {
        let items: [[String: Any]] = [
            ["id": "c_team@group.calendar.google.com", "summary": "Team", "selected": true],
            ["id": "me@x.com", "summary": "me@x.com", "primary": true, "selected": true],
            ["id": "c_off@group.calendar.google.com", "summary": "Unticked"],
            ["id": "c_hidden@group.calendar.google.com", "summary": "Hidden", "selected": true, "hidden": true],
            ["id": "en.usa#holiday@group.v.calendar.google.com", "summary": "Holidays", "selected": true],
            ["id": "dan@x.com", "summary": "dan@x.com", "summaryOverride": "Dan", "selected": true],
        ]
        let list = MeetingsGoogle.shown(items)
        #expect(list.map(\.id) == ["primary", "c_team@group.calendar.google.com", "dan@x.com"])
        #expect(list.map(\.name) == ["me@x.com", "Team", "Dan"])
        // A list without its primary still reads the primary.
        #expect(MeetingsGoogle.shown([]) == [MeetingsGoogle.primary])
    }

    @Test func aCalendarsIdIsEscapedInItsPath() {
        let google = MeetingsGoogle.events(URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!, calendar: "en.usa#x@group.calendar.google.com")
        #expect(google.absoluteString == "https://www.googleapis.com/calendar/v3/calendars/en.usa%23x@group.calendar.google.com/events")
        let fake = MeetingsGoogle.events(URL(string: "http://127.0.0.1:8123/gmail/v1/users/me/")!)
        #expect(fake.absoluteString == "http://127.0.0.1:8123/calendar/v3/calendars/primary/events")
    }
}

/// Every calendar an account shows, read and merged; the primary alone
/// when its consent left the list out.
@MainActor
@Suite(.serialized)
struct MeetingsGoogleCalendarsTests {
    final class Calendars: URLProtocol {
        nonisolated(unsafe) static var listed = true
        nonisolated(unsafe) static var asked: [String] = []
        static let team = "c_team@group.calendar.google.com"
        /// One moment for every answer: two calendars' copies of a meeting
        /// start together, however slow the run.
        static let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1800))
        static let later = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))

        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "www.googleapis.com" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let path = request.url!.path(percentEncoded: false)
            Self.asked.append(path)
            let (soon, later) = (Self.soon, Self.later)
            func event(_ id: String, _ title: String, uid: String) -> String {
                #"{"id": "\#(id)", "iCalUID": "\#(uid)", "summary": "\#(title)", "start": {"dateTime": "\#(soon)"}, "end": {"dateTime": "\#(later)"}}"#
            }
            let (status, body): (Int, String)
            switch path {
            case "/calendar/v3/users/me/calendarList":
                (status, body) = Self.listed
                    ? (200, #"{"items": [{"id": "me@x.com", "summary": "me@x.com", "primary": true, "selected": true}, {"id": "\#(Self.team)", "summary": "Team", "selected": true}]}"#)
                    : (403, #"{"error": {"code": 403, "errors": [{"reason": "insufficientPermissions"}]}}"#)
            case "/calendar/v3/calendars/primary/events":
                (status, body) = (200, #"{"items": [\#(event("a", "Design sync", uid: "sync@google.com"))]}"#)
            case "/calendar/v3/calendars/\(Self.team)/events":
                // The same sync, and one of the team's own.
                (status, body) = (200, #"{"items": [\#(event("b", "Design sync", uid: "sync@google.com")), \#(event("c", "Launch review", uid: "launch@google.com"))]}"#)
            default: (status, body) = (404, "{}")
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func gmail() -> MailGmail {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Calendars.self]
        return MailGmail(session: URLSession(configuration: config), token: { "t" })
    }

    private let account = "calendars-test@x.com"

    @Test func everyCalendarIsReadAndAMeetingInTwoIsOnce() async throws {
        Calendars.listed = true
        Calendars.asked = []
        Store.settings.set(true, forKey: MeetingsGoogle.listKey(account))
        MeetingsGoogle.forget(account)
        defer { Store.settings.removeObject(forKey: MeetingsGoogle.listKey(account)); Store.settings.removeObject(forKey: MeetingsGoogle.key(account)) }
        let meetings = try #require(await MeetingsGoogle.read(account, gmail: gmail()))
        #expect(meetings.map(\.title).sorted() == ["Design sync", "Launch review"])
        #expect(meetings.first { $0.title == "Design sync" }?.calendar == nil)
        #expect(meetings.first { $0.title == "Launch review" }?.calendar == "Team")
        // The list is kept: a second read asks only for the events.
        Calendars.asked = []
        _ = await MeetingsGoogle.read(account, gmail: gmail())
        #expect(!Calendars.asked.contains("/calendar/v3/users/me/calendarList"))
    }

    @Test func withoutTheListOnlyThePrimaryIsReadAndNothingIsAsked() async throws {
        Calendars.asked = []
        Store.settings.removeObject(forKey: MeetingsGoogle.listKey(account))
        MeetingsGoogle.forget(account)
        defer { Store.settings.removeObject(forKey: MeetingsGoogle.key(account)) }
        let meetings = try #require(await MeetingsGoogle.read(account, gmail: gmail()))
        #expect(meetings.map(\.title) == ["Design sync"])
        #expect(Calendars.asked == ["/calendar/v3/calendars/primary/events"])
    }

    @Test func aListTakenBackFallsToThePrimaryAndStaysThere() async throws {
        Calendars.listed = false
        Calendars.asked = []
        Store.settings.set(true, forKey: MeetingsGoogle.listKey(account))
        MeetingsGoogle.forget(account)
        defer {
            Calendars.listed = true
            Store.settings.removeObject(forKey: MeetingsGoogle.listKey(account))
            Store.settings.removeObject(forKey: MeetingsGoogle.key(account))
        }
        let meetings = try #require(await MeetingsGoogle.read(account, gmail: gmail()))
        #expect(meetings.map(\.title) == ["Design sync"])
        #expect(Store.settings.object(forKey: MeetingsGoogle.listKey(account)) as? Bool == false)
    }
}
