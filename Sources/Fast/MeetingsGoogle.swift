import Foundation

// Meetings from Google: each account connected for mail whose consent let
// its calendar through (MailGrant.calendar) is read with the mail's own
// token, today's and tomorrow's. Its primary calendar, and, where its
// consent let the calendar list through too (MailGrant.calendarList),
// every other calendar it shows in Google Calendar: a team's, a second
// one, a booking tool's. An account connected before the calendar was
// asked for is tried once; Google's no is kept, and that account is left to
// the mail until it is connected again. One without the list reads its
// primary alone, as before, and is never asked again by itself.

@MainActor
enum MeetingsGoogle {
    /// The accounts to read: connected, and not known to have left the
    /// calendar out.
    static var accounts: [String] {
        // Gmail's accounts alone: an IMAP one's calendar isn't Google's.
        MailCenter.shared.accounts.filter { MailCenter.kind(of: $0) == .gmail && Store.settings.object(forKey: key($0)) as? Bool != false }
    }

    static func key(_ account: String) -> String { "mail.calendar.\(account)" }
    /// True once the account's consent gave its calendar list.
    static func listKey(_ account: String) -> String { "mail.calendars.\(account)" }

    /// One calendar of an account: its primary, or another it shows.
    struct Shown: Equatable {
        let id: String
        /// Its name as the account shows it; said beside its meetings only
        /// when it isn't the primary.
        let name: String
        let primary: Bool
    }

    static let primary = Shown(id: "primary", name: "", primary: true)

    /// Each account's list, read once in half an hour: calendars come and
    /// go far less often than their meetings.
    private static var kept: [String: (at: Date, list: [Shown])] = [:]

    /// Its list read again next time: connected again, or gone.
    static func forget(_ account: String) { kept[account] = nil }

    /// The calendars to read: the primary first, then every other one the
    /// account shows, when its list was given; the primary alone when it
    /// wasn't, or when Google won't say this time.
    static func calendars(_ account: String, gmail: MailGmail, token: String) async -> [Shown] {
        guard Store.settings.bool(forKey: listKey(account)) else { return [primary] }
        if let kept = kept[account], Date().timeIntervalSince(kept.at) < 30 * 60 { return kept.list }
        var parts = URLComponents(url: url(gmail.base, "users/me/calendarList"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "minAccessRole", value: "reader"), URLQueryItem(name: "maxResults", value: "250")]
        var request = URLRequest(url: parts.url!, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await gmail.session.data(for: request) else { return kept[account]?.list ?? [primary] }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403, refused(data) {
            // The list taken back on Google's page: the primary alone, asked no more.
            Store.settings.set(false, forKey: listKey(account))
            kept[account] = nil
            return [primary]
        }
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return kept[account]?.list ?? [primary]
        }
        let list = shown(json["items"] as? [[String: Any]] ?? [])
        kept[account] = (Date(), list)
        return list
    }

    /// calendarList's items as the calendars to read: the ones ticked in
    /// Google Calendar's side list, not hidden, the primary first. Google's
    /// own (holidays, birthdays, week numbers) are days, not meetings.
    nonisolated static func shown(_ items: [[String: Any]]) -> [Shown] {
        let all = items.compactMap { item -> Shown? in
            guard let id = item["id"] as? String, item["deleted"] as? Bool != true, item["hidden"] as? Bool != true else { return nil }
            let primary = item["primary"] as? Bool == true
            guard primary || item["selected"] as? Bool == true else { return nil }
            if !primary, id.hasSuffix("group.v.calendar.google.com") { return nil }
            let name = (item["summaryOverride"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? item["summary"] as? String ?? ""
            return Shown(id: primary ? "primary" : id, name: name, primary: primary)
        }
        let others = all.filter { !$0.primary }
        return [all.first(where: \.primary) ?? primary] + others
    }

    /// The account's meetings, soonest first, from every calendar it shows,
    /// a meeting in two of them once; nil when Google wouldn't answer this
    /// time (offline, a token refused), so the last read stays.
    static func read(_ account: String, gmail: MailGmail) async -> [Meeting]? {
        guard let token = try? await gmail.token() else { return nil }
        let from = Date().addingTimeInterval(-4 * 3600), to = Date().addingTimeInterval(26 * 3600)
        var found: [Meeting] = []
        var seen = Set<String>()
        var answered = false
        for calendar in await calendars(account, gmail: gmail, token: token) {
            var parts = URLComponents(url: events(gmail.base, calendar: calendar.id), resolvingAgainstBaseURL: false)!
            parts.queryItems = [
                URLQueryItem(name: "timeMin", value: stamp.string(from: from)),
                URLQueryItem(name: "timeMax", value: stamp.string(from: to)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "maxResults", value: "50"),
            ]
            var request = URLRequest(url: parts.url!, timeoutInterval: 20)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await gmail.session.data(for: request) else {
                if calendar.primary { return nil } else { continue }
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 403, calendar.primary {
                // The calendar was never given (an account from before it was
                // asked for, or left out on Google's page): asked no more. Any
                // other no (the Calendar API off in Yab's project) is tried
                // again later.
                guard refused(data) else { return nil }
                Store.settings.set(false, forKey: key(account))
                return []
            }
            guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Another calendar that won't answer leaves the rest.
                if calendar.primary { return nil } else { continue }
            }
            answered = true
            for event in json["items"] as? [[String: Any]] ?? [] {
                guard var meeting = meeting(event, account: account), meeting.end > Date() else { continue }
                // The same meeting in two calendars: the first, the primary's.
                let uid = (event["iCalUID"] as? String ?? meeting.id) + "@\(meeting.start.timeIntervalSince1970)"
                guard seen.insert(uid).inserted else { continue }
                if !calendar.primary, !calendar.name.isEmpty { meeting.calendar = calendar.name }
                found.append(meeting)
            }
        }
        guard answered else { return nil }
        if Store.settings.object(forKey: key(account)) == nil { Store.settings.set(true, forKey: key(account)) }
        return found.sorted { $0.start < $1.start }
    }

    /// Google's no for a scope that wasn't given, not any other 403.
    nonisolated static func refused(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        return text.contains("insufficientPermissions") || text.contains("SCOPE_INSUFFICIENT")
    }

    /// An event as Google has it: one at a time of day (not all day), not
    /// cancelled, not one you said no to, not a working location or time
    /// marked out of office.
    nonisolated static func meeting(_ event: [String: Any], account: String) -> Meeting? {
        guard event["status"] as? String != "cancelled",
              (event["eventType"] as? String).map({ $0 == "default" || $0 == "fromGmail" }) ?? true,
              let id = event["id"] as? String,
              let start = time(event["start"]), let end = time(event["end"]) else { return nil }
        let attendees = event["attendees"] as? [[String: Any]] ?? []
        if attendees.contains(where: { $0["self"] as? Bool == true && $0["responseStatus"] as? String == "declined" }) { return nil }
        let entries = (event["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]] ?? []
        let video = entries.first { $0["entryPointType"] as? String == "video" }?["uri"] as? String
        let link = [event["hangoutLink"] as? String, video, event["location"] as? String, event["description"] as? String]
            .lazy.compactMap { CallLink.find(in: $0) }.first
        let people = attendees.filter { $0["self"] as? Bool != true }.compactMap { ($0["email"] as? String)?.lowercased() }
        // The account at the id's end, so a read that fails keeps its own.
        return Meeting(id: "g:\(id)@\(start.timeIntervalSince1970)|\(account)", title: event["summary"] as? String ?? "",
                       start: start, end: end, link: link, people: people)
    }

    /// What is taken in an account's calendars from one moment to another
    /// (the primary, and every other it shows when its list was given),
    /// every page (events.list, each occurrence of a series on its own),
    /// with the token and the line its mail uses: not canceled, not
    /// declined, not shown as free, not a working location, a meeting in
    /// two calendars once. Nil when Google wouldn't answer; none when the
    /// calendar was never given.
    static func busy(_ account: String, gmail: MailGmail, from: Date, to: Date) async -> [BusyTime]? {
        guard let token = try? await gmail.token() else { return nil }
        var found: [BusyTime] = []
        var seen = Set<String>()
        for calendar in await calendars(account, gmail: gmail, token: token) {
            var page: String?
            repeat {
                var parts = URLComponents(url: events(gmail.base, calendar: calendar.id), resolvingAgainstBaseURL: false)!
                parts.queryItems = [
                    URLQueryItem(name: "timeMin", value: stamp.string(from: from)),
                    URLQueryItem(name: "timeMax", value: stamp.string(from: to)),
                    URLQueryItem(name: "singleEvents", value: "true"),
                    URLQueryItem(name: "orderBy", value: "startTime"),
                    URLQueryItem(name: "maxResults", value: "250"),
                ] + (page.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
                var request = URLRequest(url: parts.url!, timeoutInterval: 20)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                guard let (data, response) = try? await gmail.session.data(for: request) else {
                    if calendar.primary { return nil } else { break }
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 403, calendar.primary, refused(data) {
                    Store.settings.set(false, forKey: key(account))
                    return []
                }
                guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    if calendar.primary { return nil } else { break }
                }
                for time in (json["items"] as? [[String: Any]] ?? []).compactMap({ taken($0) }) {
                    guard time.uid.isEmpty || seen.insert(time.uid + "@\(time.start.timeIntervalSince1970)").inserted else { continue }
                    found.append(time)
                }
                page = json["nextPageToken"] as? String
            } while page != nil && found.count < 2_500
        }
        return found
    }

    /// An event as a stretch taken, or nil for one that takes nothing.
    nonisolated static func taken(_ event: [String: Any]) -> BusyTime? {
        guard event["status"] as? String != "cancelled", event["transparency"] as? String != "transparent",
              event["eventType"] as? String != "workingLocation",
              let start = moment(event["start"]), let end = moment(event["end"]) else { return nil }
        let me = (event["attendees"] as? [[String: Any]] ?? []).first { $0["self"] as? Bool == true }
        if me?["responseStatus"] as? String == "declined" { return nil }
        return BusyTime(title: event["summary"] as? String ?? "", start: start, end: end, uid: event["iCalUID"] as? String ?? "",
                    maybe: me.map { $0["responseStatus"] as? String != "accepted" } ?? false, link: event["htmlLink"] as? String ?? "")
    }

    /// Where a calendar's events are read: Google's, or the same host as
    /// a test world's fake Gmail (agent-mail-account), which serves both.
    nonisolated static func events(_ base: URL, calendar: String = "primary") -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~@")
        return url(base, "calendars/\(calendar.addingPercentEncoding(withAllowedCharacters: allowed) ?? calendar)/events")
    }

    /// A path of the Calendar API, at Google or a test world's fake.
    nonisolated static func url(_ base: URL, _ path: String) -> URL {
        let google = URL(string: "https://www.googleapis.com/calendar/v3/" + path)!
        guard base.host() != "gmail.googleapis.com", var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return google }
        parts.percentEncodedPath = "/calendar/v3/" + path
        parts.query = nil
        return parts.url ?? google
    }

    /// A dateTime, or an all-day date from its midnight here.
    nonisolated private static func moment(_ value: Any?) -> Date? {
        if let at = time(value) { return at }
        guard let day = (value as? [String: Any])?["date"] as? String else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format.date(from: day)
    }

    /// `{"dateTime": "2026-10-01T08:00:00-07:00"}`; an all-day event has
    /// only a date, and is no meeting.
    nonisolated private static func time(_ value: Any?) -> Date? {
        guard let text = (value as? [String: Any])?["dateTime"] as? String else { return nil }
        return stamp.date(from: text) ?? precise.date(from: text)
    }

    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format
    }()

    nonisolated(unsafe) private static let precise: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format
    }()
}
