import Foundation
import Testing
@testable import Fast
@testable import MailCore

// The agent's newer mail and calendar tools (docs/mail.md, Mail for agents):
// what each is called by, which lists a name means, how a waiting send is
// said, the calendar's free time and event pages, and who is given which
// tool. Their work on a mailbox is evals/mail/agent_tools.py's.
@MainActor
struct MailAgentToolsTests {
    static func at(_ text: String) -> Date {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm"
        return format.date(from: text)!
    }

    @Test func aListIsNamedByItsIDItsNameOrALabel() {
        let labels = ["Work/Clients", "Receipts"]
        #expect(MailAgent.listID("Needs you", labels: labels) == "needs")
        #expect(MailAgent.listID("waiting", labels: labels) == "waiting")
        #expect(MailAgent.listID("drafts", labels: labels) == "kept")
        #expect(MailAgent.listID("Kept", labels: labels) == "kept")
        #expect(MailAgent.listID("snoozed", labels: labels) == "later")
        #expect(MailAgent.listID("Archive", labels: labels) == "older")
        #expect(MailAgent.listID("Sent", labels: labels) == "sent")
        #expect(MailAgent.listID("All Mail", labels: labels) == "all")
        #expect(MailAgent.listID("reminders", labels: labels) == "reminders")
        #expect(MailAgent.listID("Opened", labels: labels) == "opened")
        #expect(MailAgent.listID("Archived Today", labels: labels) == MailSplits.skipped)
        #expect(MailAgent.listID("work/clients", labels: labels) == "label:Work/Clients")
        #expect(MailAgent.listID("label:Receipts", labels: labels) == "label:Receipts")
        #expect(MailAgent.listID("nothing like this", labels: labels) == nil)
        #expect(MailAgent.listID("  ", labels: labels) == nil)
    }

    @Test func aWaitingSendSaysWhenItGoes() {
        let now = Self.at("2026-10-20 09:00")
        let op = { (seconds: TimeInterval) in MailOp(seq: 1, kind: .send, thread: "new:1", label: "", tries: 0, notBefore: now.addingTimeInterval(seconds)) }
        #expect(MailAgent.goes(op(4.2), now: now) == "sending in 5s")
        #expect(MailAgent.goes(op(-1), now: now) == "going now (Gmail hasn't taken it yet)")
        #expect(MailAgent.goes(op(86_400), now: now).hasPrefix("set to go "))
    }

    @Test func anEventIsNamedByItsGoogleID() {
        #expect(AgentCalendar.eid("https://www.google.com/calendar/event?eid=ZGVzaWduIG1lQGV4YW1wbGUuY29t") == "ZGVzaWduIG1lQGV4YW1wbGUuY29t")
        #expect(AgentCalendar.eid("https://calendar.google.com/calendar/r/eventedit/ZGVzaWduIG1l?authuser=0") == "ZGVzaWduIG1l")
        #expect(AgentCalendar.eid("ZGVzaWduIG1l") == "ZGVzaWduIG1l")
        #expect(AgentCalendar.eid("") == nil)
        #expect(AgentCalendar.eid("https://example.com/event?eid=ZGVzaWduIG1l") == nil)
        #expect(AgentCalendar.eid("not an id at all") == nil)
    }

    @Test func calendarAddOpensAnEventsOwnEditPageOrARepeatingNewOne() throws {
        let edit = try AgentCalendar.page(["event": "https://www.google.com/calendar/event?eid=ZGVzaWduIG1l"], accounts: ["me@example.com"]).get()
        #expect(edit.absoluteString.hasPrefix("https://calendar.google.com/calendar/r/eventedit/ZGVzaWduIG1l"))
        #expect(URLComponents(url: edit, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "authuser" }?.value == "me@example.com")

        let weekly = try AgentCalendar.page(["title": "Standup", "start": "2026-10-20T09:00", "recurrence": "FREQ=WEEKLY;COUNT=10"], accounts: []).get()
        let items = URLComponents(url: weekly, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "recur" }?.value == "RRULE:FREQ=WEEKLY;COUNT=10")
        let said = try AgentCalendar.page(["title": "Standup", "start": "2026-10-20T09:00", "recurrence": "RRULE:FREQ=DAILY"], accounts: []).get()
        #expect(URLComponents(url: said, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "recur" }?.value == "RRULE:FREQ=DAILY")

        if case .success = AgentCalendar.page(["title": "Standup", "start": "2026-10-20T09:00", "recurrence": "weekly"], accounts: []) {
            Issue.record("a recurrence that isn't an RRULE was taken")
        }
        if case .success = AgentCalendar.page(["event": "not an id at all"], accounts: []) {
            Issue.record("an event that isn't one was taken")
        }
    }

    @Test func freeTimeIsWorkingHoursAroundWhatIsBusy() {
        let now = Self.at("2026-10-20 08:00")
        let busy = [BusyTime(title: "Design review", start: Self.at("2026-10-20 10:00"), end: Self.at("2026-10-20 12:00")),
                    BusyTime(title: "Hiring sync", start: Self.at("2026-10-20 14:00"), end: Self.at("2026-10-20 15:00"))]
        let hours = MailSlots.Hours(start: 9 * 60, end: 18 * 60, length: 30, days: [1, 2, 3, 4, 5, 6, 7])
        let said = AgentCalendar.free(busy, from: now, days: 1, minutes: 60, hours: hours)
        #expect(said.contains("60 minutes or more, working hours 9:00–18:00"), Comment(rawValue: said))
        #expect(said.contains("2026-10-20: 09:00–10:00, 12:00–14:00, 15:00–18:00"), Comment(rawValue: said))
        #expect(said.contains("Only the user's own calendars"))
        let full = AgentCalendar.free([BusyTime(title: "Offsite", start: Self.at("2026-10-20 00:00"), end: Self.at("2026-10-21 00:00"))],
                                      from: now, days: 1, minutes: 60, hours: hours)
        #expect(full.contains("Nothing free"), Comment(rawValue: full))
        #expect(AgentCalendar.free(nil, from: now, days: 1, minutes: nil).hasPrefix("No calendar Yab can read"))
    }

    @Test func aGoogleEventInTheCalendarNamesItsEvent() {
        let day = Self.at("2026-10-20 00:00")
        let busy = [BusyTime(title: "Design review", start: Self.at("2026-10-20 10:00"), end: Self.at("2026-10-20 12:00"),
                             link: "https://www.google.com/calendar/event?eid=ZGVzaWduIG1l"),
                    BusyTime(title: "Dentist", start: Self.at("2026-10-20 16:00"), end: Self.at("2026-10-20 17:00"))]
        let said = AgentCalendar.describe(busy, from: day, days: 1, meetings: [])
        #expect(said.contains("Design review · event: ZGVzaWduIG1l"), Comment(rawValue: said))
        #expect(said.contains("Dentist\n"), Comment(rawValue: said))
        #expect(said.contains("calendar_free"))
    }

    @Test func aSetupAskedInTheChatSaysSo() {
        let icloud = MailKnownProviders.by(id: "icloud")!
        let asked = MailSetup.words("me@icloud.com", provider: icloud, asked: true)
        #expect(asked.contains("The user asked for it in this chat"))
        #expect(!asked.contains("I pressed Set It Up"))
        #expect(asked.contains("mail_setup with do: keep_password"))
        let pressed = MailSetup.words("me@icloud.com", provider: icloud)
        #expect(pressed.contains("I pressed Set It Up") && pressed.contains("signed in to"))
    }

    @Test func mailAccountsIsGivenWhileAgentsMayWorkOnMailAndMailListWithAMailbox() {
        let names = { (a: Mcp.Audience) in Mcp.list(for: a).compactMap { $0["name"] as? String } }
        var a = Mcp.Audience()
        #expect(!names(a).contains("mail_accounts") && !names(a).contains("mail_list"))
        #expect(names(a).contains("calendar_free"))
        a.mailAgents = true
        #expect(names(a).contains("mail_accounts") && !names(a).contains("mail_list"))
        a.mailbox = true
        #expect(names(a).contains("mail_list"))
        // A subagent is given neither: mail is the chat's.
        var sub = Mcp.Audience(inner: true, sub: true)
        sub.mailbox = true; sub.mailAgents = true
        #expect(!names(sub).contains("mail_accounts") && !names(sub).contains("mail_list"))

        let act = Mcp.list(for: a).first { $0["name"] as? String == "mail_act" }
        let kinds = ((act?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["do"] as? [String: Any]
        #expect((kinds?["enum"] as? [String])?.contains("unsubscribe") == true)
        #expect((kinds?["enum"] as? [String])?.contains("remind") == true)
        let send = Mcp.list(for: a).first { $0["name"] as? String == "mail_send" }
        #expect(((send?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["undo"] != nil)
        let list = Mcp.list(for: a).first { $0["name"] as? String == "mail_list" }
        #expect((list?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
    }

    @Test func noAccountIsSaidWithHowToConnectOne() {
        guard MailCenter.shared.accounts.isEmpty else { return }
        #expect(MailAgent.accountsSaid(MailCenter.shared).contains("mail_accounts add"))
    }

    @Test func aMailSnippetsStepsAndChatAboutsReadBack() {
        #expect(ChatItem.about("mail_act", ["thread": "a|b", "do": "unsubscribe"]) == "unsubscribe:")
        #expect(ChatItem.about("mail_send", ["draft": "a|new:1", "undo": true]) == "undo:")
        #expect(ChatItem.about("mail_list", ["list": "Kept"]) == "list:Kept")
        #expect(ChatItem.about("mail_accounts", ["do": "add", "address": "me@icloud.com"]) == "add:me@icloud.com")
    }
}
