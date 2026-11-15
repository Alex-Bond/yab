import Foundation
import Testing
@testable import Fast
@testable import MailCore

/// What an agent was given on 2026-10-14: the iPhone's history and tabs,
/// the calendar, and the settings it could not reach before.
struct AgentKnowsTests {
    @Test func anotherDevicesPlacesAreFoundAndSaidWhereTheyWereOpened() {
        let now = Date()
        let elsewhere = [
            AgentDevices.Visit(url: URL(string: "https://www.nytimes.com/2026/10/13/crossword.html")!, title: "The Crossword", at: now.addingTimeInterval(-3600), device: "Anna's iPhone (iPhone)"),
            AgentDevices.Visit(url: URL(string: "https://github.com/yab/yab/pull/12")!, title: "Fix sync", at: now.addingTimeInterval(-7200), device: "Studio"),
        ]
        let phone = AgentHistory.pages(matching: nil, host: nil, device: "iphone", elsewhere: elsewhere)
        #expect(phone.contains("The Crossword  (on Anna's iPhone (iPhone))"))
        #expect(!phone.contains("Fix sync"))
        let none = AgentHistory.pages(matching: nil, host: nil, device: "ipad", elsewhere: elsewhere)
        #expect(none.contains("Devices with history here: Anna's iPhone (iPhone), Studio"))
        #expect(AgentHistory.pages(matching: nil, host: nil, device: "iphone", elsewhere: []).hasPrefix("Nothing from another device"))
    }

    @Test func momentsReadWithAndWithoutTheirZone() throws {
        let local = try #require(AgentCalendar.moment("2026-10-15T09:00"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: local)
        #expect([parts.year, parts.month, parts.day, parts.hour, parts.minute] == [2026, 10, 15, 9, 0])
        let zoned = try #require(AgentCalendar.moment("2026-10-15T09:00:00Z"))
        #expect(zoned.timeIntervalSince1970 == 1_792_054_800)
        #expect(AgentCalendar.moment("tomorrow at nine") == nil)
        #expect(AgentCalendar.day("2026-10-15") == Calendar.current.startOfDay(for: local))
    }

    @Test func anEventIsGoogleCalendarsOwnPageFilledIn() throws {
        let request: [String: Any] = ["title": "Coffee with Anna", "start": "2026-10-15T09:00:00Z", "minutes": 45,
                                      "guests": ["anna@fold.studio", "not an address"], "account": "Me@Gmail.com"]
        let url = try AgentCalendar.page(request, accounts: ["me@gmail.com", "work@yab.dev"]).get()
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host() == "calendar.google.com" && url.path() == "/calendar/r/eventedit")
        #expect(items["text"] == "Coffee with Anna")
        #expect(items["dates"] == "20261015T090000Z/20261015T094500Z")
        #expect(items["add"] == "anna@fold.studio")
        #expect(items["authuser"] == "me@gmail.com")
        #expect(throws: AgentCalendar.Failure.self) { try AgentCalendar.page(["title": "x", "start": "2026-10-15T09:00", "account": "else@x.com"], accounts: ["me@gmail.com"]).get() }
        #expect(throws: AgentCalendar.Failure.self) { try AgentCalendar.page(["title": "x", "start": "2026-10-15T09:00", "end": "2026-10-15T08:00"], accounts: []).get() }
        #expect(throws: AgentCalendar.Failure.self) { try AgentCalendar.page(["start": "2026-10-15T09:00"], accounts: []).get() }
    }

    @Test func aDaySaysItsEventsAndTheCallsLink() throws {
        let day = try #require(AgentCalendar.day("2026-10-15"))
        let start = day.addingTimeInterval(10 * 3600), end = start.addingTimeInterval(1800)
        let busy = [BusyTime(title: "Standup", start: start, end: end, maybe: true), BusyTime(title: "Standup", start: start, end: end)]
        let call = Meeting(id: "1", title: "Standup", start: start, end: end, link: URL(string: "https://meet.google.com/abc-defg-hij"))
        let said = AgentCalendar.describe(busy, from: day, days: 2, meetings: [call])
        #expect(said.components(separatedBy: "Standup").count == 2)
        #expect(said.contains("10:00–10:30  Standup (not said yes to) · call: https://meet.google.com/abc-defg-hij"))
        #expect(said.contains("Nothing."))
        #expect(AgentCalendar.describe(nil, from: day, days: 1, meetings: []).hasPrefix("No calendar Yab can read"))
    }

    @MainActor @Test func mailAndSyncSettingsAreActionsAndPrivateOnesAreNot() throws {
        let ids = Set(NativeActions.descriptors.compactMap { $0["id"] as? String })
        for id in ["mail-undo", "mail-hours", "mail-badge", "mail-ads", "sync-history", "app-icon", "snippets-semicolon", "search-suggest", "small-key"] {
            #expect(ids.contains("settings.set." + id), "\(id)")
        }
        #expect(ids.contains("mail.set_notify") && ids.contains("mail.set_read_statuses"))
        for id in ["mail-people", "sync-passwords", "mail-agents", "mail-memory"] { #expect(!ids.contains("settings.set." + id), "\(id)") }
        let undo = try #require(NativeActions.descriptors.first { $0["id"] as? String == "settings.set.mail-undo" })
        try NativeActions.validate(["value": .number(10)], descriptor: undo)
        #expect(throws: NativeFailure.self) { try NativeActions.validate(["value": .number(7)], descriptor: undo) }
        let hours = try #require(NativeSetting.all.first { $0.id == "mail-hours" })
        #expect(throws: NativeFailure.self) { try hours.write(Preferences(), .string("18:00-09:00")) }
        let item = try #require(SettingsItem.all.first { $0.id == "mail-people" })
        #expect(NativeActions.classification(item) == "user_only")
    }
}
