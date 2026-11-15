import Foundation

/// A thing a turn made, as the chat shows it under the answer: pages found,
/// a comparison, an event, a reminder, a watch, a routine, a folder of
/// tabs. Said by the tool that made it, on a line of its result
/// ("Card: {json}", as save_page's "Saved: PATH" says its file), never
/// read out of the answer's words. The Mac keeps it as a step of its own
/// (ChatItem kind "card", the JSON its text), so it syncs to the iPhone as
/// any step does.
public struct ResultCard: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case links, table, event, promise, watch, routine, folder
    }

    /// A row: a page found, a table's line, a tab in a folder.
    public struct Row: Codable, Hashable, Sendable {
        public var title: String
        public var url: String?
        /// Its host, for the favicon and the line under it.
        public var site: String?
        /// Minutes to read it, for a link.
        public var minutes: Int?
        /// A table's cells after the first (its title).
        public var cells: [String]?
        /// A folder's tab, by its id.
        public var tab: String?

        public init(title: String, url: String? = nil, site: String? = nil, minutes: Int? = nil, cells: [String]? = nil, tab: String? = nil) {
            self.title = title; self.url = url; self.site = site; self.minutes = minutes; self.cells = cells; self.tab = tab
        }
    }

    public var kind: Kind
    /// An event's or a folder's name, a watch's condition ("under $180"),
    /// a routine's when in words, whose reply a promise waits on.
    public var title: String
    /// An event's state ("invite sent"), a routine's next run.
    public var detail: String?
    /// An event's start, a reminder's day.
    public var at: Double?
    /// An event's end.
    public var end: Double?
    /// A watch's value now ("$195").
    public var value: String?
    /// A watch's site.
    public var site: String?
    public var rows: [Row]?
    /// A table's row the answer names, lit.
    public var lit: Int?
    /// What it is in Yab: a watch's id, a routine's, a folder's, a thread.
    public var ref: String?
    /// Where it opens: an event's page, a watched page.
    public var url: String?

    public init(kind: Kind, title: String = "", detail: String? = nil, at: Double? = nil, end: Double? = nil, value: String? = nil,
                site: String? = nil, rows: [Row]? = nil, lit: Int? = nil, ref: String? = nil, url: String? = nil) {
        self.kind = kind; self.title = title; self.detail = detail; self.at = at; self.end = end; self.value = value
        self.site = site; self.rows = rows; self.lit = lit; self.ref = ref; self.url = url
    }

    /// The most rows a card holds.
    public static let mostRows = 8
    /// What starts a tool result's line that carries a card.
    public static let prefix = "Card: "

    /// Its JSON, keys sorted, on one line.
    public var json: String {
        let coder = JSONEncoder()
        coder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? coder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Its line in a tool's result.
    public var line: String { Self.prefix + json }

    /// From its JSON; nil for anything else, a kind this Yab doesn't know
    /// included, or a card with nothing to show.
    public init?(json: String) {
        guard let data = json.data(using: .utf8), var card = try? JSONDecoder().decode(ResultCard.self, from: data) else { return nil }
        if let rows = card.rows { card.rows = Array(rows.filter { !$0.title.isEmpty }.prefix(Self.mostRows)) }
        if let lit = card.lit, lit < 0 || lit >= (card.rows?.count ?? 0) { card.lit = nil }
        switch card.kind {
        case .links, .table, .folder: if card.rows?.isEmpty ?? true { return nil }
        case .event, .watch, .routine: if card.title.isEmpty { return nil }
        case .promise: break
        }
        self = card
    }

    /// The cards in a tool's result, each on a line of its own.
    public static func cards(in words: String) -> [ResultCard] {
        words.split(separator: "\n").compactMap { line in
            line.hasPrefix(prefix) ? ResultCard(json: String(line.dropFirst(prefix.count))) : nil
        }
    }

    /// A result's words with its card lines taken out: what a model or a
    /// person reading the words needs.
    public static func without(_ words: String) -> String {
        words.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix(prefix) }.joined(separator: "\n")
    }

    /// The site a URL is on, without www.
    public static func host(_ url: String?) -> String? {
        guard let url, let host = URL(string: url)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A row's line under its title: "aeon.co · 12 min".
    public static func under(_ row: Row) -> String {
        [row.site ?? host(row.url), row.minutes.map { "\($0) min" }].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    /// A day as a promise says it: "today", "tomorrow", "Thursday" within
    /// the week, else "Oct 28".
    public static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US")
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case 2...6:
            format.dateFormat = "EEEE"
        default:
            format.dateFormat = "MMM d"
        }
        return format.string(from: date)
    }

    /// A promise in words: "Back in your inbox Thursday if Tim hasn't
    /// answered", or, with no day, "Tells you when Tim answers".
    public func promise(now: Date = Date(), calendar: Calendar = .current) -> String {
        let who = title.isEmpty ? "nobody" : title
        guard let at else { return "Tells you when \(title.isEmpty ? "they answer" : who + " answers")" }
        return "Back in your inbox \(Self.day(Date(timeIntervalSince1970: at), now: now, calendar: calendar)) if \(who) hasn\u{2019}t answered"
    }

    /// An event's hours: "10:30 – 11:00 AM", "11:30 AM – 12:30 PM".
    public func hours(calendar: Calendar = .current) -> String? {
        guard let at else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US")
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = "h:mm a"
        let start = Date(timeIntervalSince1970: at)
        guard let end else { return format.string(from: start) }
        let finish = Date(timeIntervalSince1970: end)
        let half = { (date: Date) in calendar.component(.hour, from: date) < 12 }
        let first = format.string(from: start)
        return (half(start) == half(finish) ? String(first.dropLast(3)) : first) + " \u{2013} " + format.string(from: finish)
    }
}
