import Foundation
import Testing
@testable import Fast
@testable import MailCore

/// Outlook's events as Microsoft Graph's calendarView answers them (times in
/// UTC, as asked), turned into meetings and busy stretches; and its sign-in.
struct MeetingsOutlookTests {
    private func event(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    @Test func aTeamsMeetingIsAMeetingWithItsLinkAndPeople() throws {
        let meeting = try #require(OutlookCalendars.meeting(event("""
        {"id": "AAMk1", "iCalUId": "040000008200E", "subject": "Quarterly planning",
         "start": {"dateTime": "2026-10-15T17:00:00.0000000", "timeZone": "UTC"},
         "end": {"dateTime": "2026-10-15T18:00:00.0000000", "timeZone": "UTC"},
         "isAllDay": false, "isCancelled": false, "showAs": "busy", "responseStatus": {"response": "accepted"},
         "onlineMeeting": {"joinUrl": "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0"},
         "attendees": [{"emailAddress": {"address": "Me@Contoso.com"}}, {"emailAddress": {"address": "Dan@Contoso.com"}}]}
        """), account: "me@contoso.com"))
        #expect(meeting.title == "Quarterly planning")
        #expect(meeting.start == ISO8601DateFormatter().date(from: "2026-10-15T17:00:00Z"))
        #expect(meeting.link?.host() == "teams.microsoft.com")
        #expect(CallLink.key(meeting.link) != nil)
        #expect(meeting.people == ["dan@contoso.com"])
        #expect(meeting.id.hasSuffix("|outlook:me@contoso.com"))
    }

    @Test func allDayCancelledAndDeclinedAreLeftOut() {
        let at = #""start": {"dateTime": "2026-10-15T17:00:00.0000000"}, "end": {"dateTime": "2026-10-15T18:00:00.0000000"}"#
        for json in [#"{"id": "a", "isAllDay": true, \#(at)}"#, #"{"id": "c", "isCancelled": true, \#(at)}"#,
                     #"{"id": "d", "responseStatus": {"response": "declined"}, \#(at)}"#] {
            #expect(OutlookCalendars.meeting(event(json), account: "me@x.com") == nil)
        }
    }

    @Test func freeTimeTakesNothingAndTentativeIsAMaybe() throws {
        let at = #""start": {"dateTime": "2026-10-15T17:00:00.0000000"}, "end": {"dateTime": "2026-10-15T18:00:00.0000000"}"#
        #expect(OutlookCalendars.taken(event(#"{"showAs": "free", \#(at)}"#)) == nil)
        let maybe = try #require(OutlookCalendars.taken(event(#"{"iCalUId": "u", "responseStatus": {"response": "tentativelyAccepted"}, \#(at)}"#)))
        #expect(maybe.maybe && maybe.uid == "u")
    }

    @Test func signInIsMicrosoftsWithPKCEOnLocalhost() throws {
        let client = OutlookClient(id: "00000000-1111-2222-3333-444444444444")
        #expect(client.loopback == "localhost")
        let url = client.consent(redirect: "http://localhost:5000/oauth", challenge: "c", state: "s", hint: nil)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host() == "login.microsoftonline.com")
        #expect(url.path == "/common/oauth2/v2.0/authorize")
        #expect(items["scope"] == "offline_access openid email User.Read Calendars.Read")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["redirect_uri"] == "http://localhost:5000/oauth")
        // Off as it ships, until Yab's app at Microsoft exists.
        #expect(OutlookClient.shippedID.isEmpty)
    }
}
