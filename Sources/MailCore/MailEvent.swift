import Foundation

// A date written in a mail becomes an event (docs/mail.md, Calendar): the
// dates and times in a mail's own words, found by NSDataDetector, kept
// only when they name a day and are still ahead; the event a thread makes
// of one (its subject, the range written or a slot's length, its people,
// a call's link in its words); and that event in Google Calendar's words,
// for the day the account gives `calendar.events`.

public enum MailDates {
    /// A date in a mail's words, as the event takes it: where it stands in
    /// the text searched (a run of an HTML mail's text, in `marked`), the
    /// words, when it begins, when it ends when the words say so, and
    /// whether it is a day without a time.
    public struct Found: Equatable {
        public var range: NSRange
        public var words: String
        public var start: Date
        public var end: Date?
        public var allDay: Bool

        public init(range: NSRange, words: String, start: Date, end: Date?, allDay: Bool) {
            self.range = range
            self.words = words
            self.start = start
            self.end = end
            self.allDay = allDay
        }
    }

    /// Made once and shared: making a detector costs more than a mail's search.
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    private static func pattern(_ text: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: text, options: [.caseInsensitive])
    }

    /// What says which day: a month by name, a date in numbers, a weekday,
    /// today, tonight or tomorrow. A time alone ("at 3pm") names none.
    private static let month = pattern(#"\b(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec)\b"#)
    private static let numbers = pattern(#"\b\d{4}-\d{1,2}-\d{1,2}\b|\b\d{1,2}[./-]\d{1,2}[./-]\d{2,4}\b|\b\d{1,2}/\d{1,2}\b"#)
    private static let weekday = pattern(#"\b(sunday|monday|tuesday|wednesday|thursday|friday|saturday|sun|mon|tues|tue|wed|thurs|thur|thu|fri|sat)\b"#)
    private static let relative = pattern(#"\b(today|tonight|tomorrow)\b"#)
    private static let next = pattern(#"\bnext\b"#)
    /// What says a time of day.
    private static let time = pattern(#"\b\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)|\b\d{1,2}:\d{2}\b|\b(noon|midnight|tonight)\b"#)

    /// Words that make the date an end, not a range's start.
    private static let until = pattern(#"\b(until|till|ends?|ending|by|through|thru|due|before|deadline)\b"#)
    /// Where a date's own words begin: the first day, number or weekday.
    private static let begins = pattern(#"\d|\b(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec|sunday|monday|tuesday|wednesday|thursday|friday|saturday|sun|mon|tues|tue|wed|thurs|thur|thu|fri|sat|today|tonight|tomorrow|noon|midnight)\b"#)

    /// How many UTF-16 units come before a match's own date words.
    private static func lead(_ words: String) -> Int {
        begins.firstMatch(in: words, range: NSRange(location: 0, length: (words as NSString).length))?.range.location ?? 0
    }

    private static func first(_ regex: NSRegularExpression, in text: String) -> String? {
        let whole = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: whole.length)).map { whole.substring(with: $0.range).lowercased() }
    }

    /// Weekdays as Calendar numbers them, 1 Sunday.
    private static func weekdayNumber(_ word: String) -> Int? {
        let starts = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        return starts.firstIndex { word.hasPrefix($0) }.map { $0 + 1 }
    }

    /// The dates in a mail's words worth an event: each naming a day, and
    /// not over by `now`, nor more than two years off. Words with no date
    /// of their own (a weekday, today, tomorrow) are read from the day the
    /// mail was sent, not from today: "Friday" in last week's mail is that
    /// week's. Lines quoted with ">" are left out.
    public static func find(_ text: String, sent: Date, now: Date = Date(), calendar: Calendar = .current) -> [Found] {
        guard let detector, !text.isEmpty else { return [] }
        let whole = text as NSString
        let quoted = quotedLines(whole)
        var out: [Found] = []
        for match in detector.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
            guard let detected = match.date, !quoted.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            // The detector takes words before the date in ("Dinner on",
            // "ends on"): the mark starts at the day, and a date something
            // ends or is due by is that day, not a range from today.
            var range = match.range, date = detected, duration = match.duration
            let lead = lead(whole.substring(with: range))
            if lead > 0 {
                let before = whole.substring(with: NSRange(location: range.location, length: lead))
                if duration > 0, first(until, in: before) != nil { date = date.addingTimeInterval(duration); duration = 0 }
                range = NSRange(location: range.location + lead, length: range.length - lead)
            }
            let words = whole.substring(with: range)
            guard let found = read(words, date: date, duration: duration, zone: match.timeZone, range: range,
                                   sent: sent, now: now, calendar: calendar) else { continue }
            out.append(found)
        }
        return out
    }

    /// Whether the detector's words say which day: a month, a date in
    /// numbers, a weekday, today, tonight or tomorrow.
    static func namesDay(_ words: String) -> Bool {
        [month, numbers, weekday, relative].contains { first($0, in: words) != nil }
    }

    /// One date the detector found, as an event takes it; nil when it
    /// names no day, or is over, or is too far off to be meant.
    static func read(_ words: String, date: Date, duration: TimeInterval, zone: TimeZone?, range: NSRange,
                     sent: Date, now: Date, calendar: Calendar) -> Found? {
        guard namesDay(words) else { return nil }
        let explicit = first(month, in: words) != nil || first(numbers, in: words) != nil
        let day = first(weekday, in: words)
        let near = first(relative, in: words)
        let timed = first(time, in: words) != nil
        var calendar = calendar
        if let zone { calendar.timeZone = zone }
        var start = date
        if !explicit {
            // From the mail's own day: the detector reads them from today.
            let sentDay = calendar.startOfDay(for: sent)
            var target: Date?
            switch near {
            case "today", "tonight": target = sentDay
            case "tomorrow": target = calendar.date(byAdding: .day, value: 1, to: sentDay)
            default:
                if let day, let number = weekdayNumber(day) {
                    let ahead = (number - calendar.component(.weekday, from: sentDay) + 7) % 7
                    let later = ahead == 0 && first(next, in: words) != nil ? 7 : ahead
                    target = calendar.date(byAdding: .day, value: later, to: sentDay)
                }
            }
            guard let target else { return nil }
            let clock = calendar.dateComponents([.hour, .minute], from: date)
            start = calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0, of: target) ?? target
        }
        var end: Date?
        if timed {
            if duration > 0 { end = start.addingTimeInterval(duration) }
        } else {
            start = calendar.startOfDay(for: start)
            if duration >= 86_400 / 2 {
                end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start.addingTimeInterval(duration)))
            }
        }
        let over = timed ? (end ?? start) : (end ?? calendar.date(byAdding: .day, value: 1, to: start) ?? start)
        guard over > now, start < now.addingTimeInterval(2 * 365 * 86_400) else { return nil }
        return Found(range: range, words: words, start: start, end: end, allDay: !timed)
    }

    /// The lines of a text mail that quote another: "> " at their start.
    private static func quotedLines(_ text: NSString) -> [NSRange] {
        var out: [NSRange] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let line = text.substring(with: range).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") { out.append(range) }
        }
        return out
    }

    // MARK: - in a mail's HTML

    /// The address a date's mark in a mail's HTML opens: its number among
    /// the mail's dates.
    public static let scheme = "yab-mail-date"

    public static func index(_ url: URL) -> Int? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let rest = url.absoluteString.dropFirst(scheme.count + 1)
        return Int(rest)
    }

    /// Under a date: the accent, thin and faint, the words their own color.
    static let markStyle = "color:inherit;text-decoration:underline;text-decoration-color:color-mix(in srgb, AccentColor 55%, transparent);"
        + "text-decoration-thickness:1.5px;text-underline-offset:3px;cursor:pointer"

    /// Elements whose words are no date of the mail's own: a link's, a
    /// style's, the page's head, and every part that quotes the mail
    /// before (Gmail's, Outlook's, Yahoo's, Thunderbird's, a blockquote).
    private static let skipped: Set<String> = ["a", "style", "script", "title", "head", "blockquote", "textarea", "button", "select", "code"]
    private static let quoting = pattern(#"\b(class|id)\s*=\s*["']?[^"'>]*\b(gmail_quote|gmail_attr|yahoo_quoted|moz-cite-prefix|divRplyFwdMsg|protonmail_quote)\b"#)
    private static let void: Set<String> = ["br", "img", "hr", "meta", "link", "input", "wbr", "col", "area", "base", "source", "embed", "param", "track"]

    /// A mail's HTML with each date worth an event marked where it stands
    /// (a link to `scheme`:<n>, n counting from `first`), and the dates in
    /// their order. Only words between tags are read, each run alone, its
    /// entities read as the page shows them; tags, attributes and the
    /// parts `skipped` and `quoting` name stay as they were.
    public static func marked(_ html: String, sent: Date, now: Date = Date(), calendar: Calendar = .current,
                              first: Int = 0) -> (html: String, found: [Found]) {
        let raw = html as NSString
        let length = raw.length
        var out = ""
        var found: [Found] = []
        var skip: (name: String, depth: Int)?
        var at = 0
        let lt = UInt16(UInt8(ascii: "<")), gt = UInt16(UInt8(ascii: ">"))
        while at < length {
            if raw.character(at: at) == lt {
                // A comment whole, or a tag to its own end, quotes kept.
                var end: Int
                if raw.length - at >= 4, raw.substring(with: NSRange(location: at, length: 4)) == "<!--" {
                    let close = raw.range(of: "-->", range: NSRange(location: at, length: length - at))
                    end = close.location == NSNotFound ? length : NSMaxRange(close)
                } else {
                    end = at + 1
                    var quote: UInt16 = 0
                    while end < length {
                        let c = raw.character(at: end)
                        if quote != 0 { if c == quote { quote = 0 } }
                        else if c == 34 || c == 39 { quote = c }
                        else if c == gt { break }
                        end += 1
                    }
                    end = min(length, end + 1)
                }
                let tag = raw.substring(with: NSRange(location: at, length: end - at))
                out += tag
                at = end
                guard let parsed = tagName(tag) else { continue }
                let (name, closing, alone) = parsed
                if var open = skip {
                    if name == open.name, !alone { open.depth += closing ? -1 : 1 }
                    skip = open.depth > 0 ? open : nil
                } else if !closing, !alone, skipped.contains(name) || quoting.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) != nil {
                    skip = (name, 1)
                }
                continue
            }
            // Words to the next tag.
            let next = raw.range(of: "<", range: NSRange(location: at, length: length - at))
            let end = next.location == NSNotFound ? length : next.location
            let run = raw.substring(with: NSRange(location: at, length: end - at))
            at = end
            if skip != nil || run.allSatisfy(\.isWhitespace) { out += run; continue }
            let (text, map) = decoded(run)
            let dates = find(text, sent: sent, now: now, calendar: calendar)
            guard !dates.isEmpty else { out += run; continue }
            let runText = run as NSString
            var from = 0
            for date in dates {
                let lo = map[date.range.location], hi = map[NSMaxRange(date.range)]
                guard lo >= from, hi > lo else { continue }
                out += runText.substring(with: NSRange(location: from, length: lo - from))
                out += "<a href=\"\(scheme):\(first + found.count)\" style=\"\(markStyle)\">"
                out += runText.substring(with: NSRange(location: lo, length: hi - lo)) + "</a>"
                from = hi
                found.append(date)
            }
            out += runText.substring(from: from)
        }
        return (out, found)
    }

    /// A tag's name, lowercased, whether it closes one, and whether it
    /// stands alone (void, or written `/>`); nil for a doctype or the like.
    private static func tagName(_ tag: String) -> (String, Bool, Bool)? {
        var body = tag.dropFirst()
        let closing = body.first == "/"
        if closing { body = body.dropFirst() }
        let name = body.prefix { $0.isLetter || $0.isNumber }.lowercased()
        guard !name.isEmpty else { return nil }
        let alone = void.contains(name) || tag.hasSuffix("/>")
        return (name, closing, alone)
    }

    private static let entities: [String: String] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "ndash": "\u{2013}", "mdash": "\u{2014}",
        "rsquo": "\u{2019}", "lsquo": "\u{2018}", "rdquo": "\u{201D}", "ldquo": "\u{201C}", "hellip": "\u{2026}", "thinsp": " ", "ensp": " ", "emsp": " ",
    ]

    /// A run of HTML's words as the page shows them, and where each of its
    /// UTF-16 units began in the run (one more at the end: the run's end).
    /// A no-break space reads as a space: the detector takes no other.
    static func decoded(_ run: String) -> (String, [Int]) {
        let raw = run as NSString
        var text = ""
        var map: [Int] = []
        var at = 0
        while at < raw.length {
            var piece: String?
            var width = 1
            if raw.character(at: at) == 38 {
                let semi = raw.range(of: ";", range: NSRange(location: at, length: min(12, raw.length - at)))
                if semi.location != NSNotFound {
                    let name = raw.substring(with: NSRange(location: at + 1, length: semi.location - at - 1))
                    if name.hasPrefix("#") {
                        let digits = name.dropFirst()
                        let value = digits.lowercased().hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                        piece = value.flatMap(Unicode.Scalar.init).map { $0 == "\u{00A0}" ? " " : String(Character($0)) }
                    } else {
                        piece = entities[name.lowercased()]
                    }
                    if piece != nil { width = semi.location - at + 1 }
                }
            }
            let unit = piece ?? raw.substring(with: NSRange(location: at, length: 1))
            let shown = unit == "\u{00A0}" ? " " : unit
            for _ in 0..<(shown as NSString).length { map.append(at) }
            text += shown
            at += width
        }
        map.append(raw.length)
        return (text, map)
    }
}

/// The event a thread makes of a date in it: what (its subject), when, who
/// (its people; you are the one adding it), and where (a call's link
/// written in its mail, or nothing).
public struct MailEvent: Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var people: [MailPerson]
    public var place: String

    public init(title: String, start: Date, end: Date, allDay: Bool, people: [MailPerson] = [], place: String = "") {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.people = people
        self.place = place
    }

    /// `people`: everyone on the thread; `me`, your addresses, left out of
    /// it; `words`, the thread's mails, newest first, for a call's link;
    /// `slot`, the minutes an event with no end written lasts (Settings ›
    /// Mail › Calendar's slot length).
    public static func make(subject: String, date: MailDates.Found, people: [MailPerson], me: [String], words: [String],
                            slot: Int, calendar: Calendar = .current) -> MailEvent {
        let mine = Set(me.map { $0.lowercased() })
        var seen = Set<String>()
        let guests = people.filter { person in
            let address = person.address.lowercased()
            guard address.contains("@"), !mine.contains(address), !automated(address) else { return false }
            return seen.insert(address).inserted
        }
        let end = date.end ?? (date.allDay ? calendar.date(byAdding: .day, value: 1, to: date.start) ?? date.start
                                          : date.start.addingTimeInterval(TimeInterval(max(5, slot)) * 60))
        let place = words.lazy.compactMap { CallLink.find(in: $0) }.first?.absoluteString ?? ""
        return MailEvent(title: title(subject), start: date.start, end: end, allDay: date.allDay, people: guests, place: place)
    }

    /// A subject as an event's title: without "Re:", "Fwd:" and the like.
    public static func title(_ subject: String) -> String {
        var text = subject.trimmingCharacters(in: .whitespaces)
        let prefix = try! NSRegularExpression(pattern: #"^\s*(re|fwd?|aw|wg|sv|tr)\s*(\[\d+\])?\s*:\s*"#, options: [.caseInsensitive])
        while let match = prefix.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            text = (text as NSString).substring(from: NSMaxRange(match.range))
        }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "New Event" : text
    }

    /// An address no person reads: no guest of an event.
    static func automated(_ address: String) -> Bool {
        let local = address.split(separator: "@").first.map(String.init) ?? address
        return ["noreply", "no-reply", "donotreply", "do-not-reply", "notifications", "mailer-daemon"].contains { local.contains($0) }
    }

    /// When, in words: "Tue, Jun 17 · 3:00 – 3:30 PM", "Tue, Jun 17",
    /// the year only when it isn't this one.
    public func when(calendar: Calendar = .current, locale: Locale = .current, now: Date = Date()) -> String {
        let format = DateIntervalFormatter()
        format.calendar = calendar
        format.locale = locale
        format.timeZone = calendar.timeZone
        let year = calendar.component(.year, from: start) != calendar.component(.year, from: now) ? "y" : ""
        if allDay {
            format.dateTemplate = "EEEMMMd" + year
            let last = calendar.date(byAdding: .day, value: -1, to: end) ?? start
            return format.string(from: start, to: max(start, last))
        }
        guard calendar.isDate(start, inSameDayAs: end.addingTimeInterval(-1)) else {
            format.dateTemplate = "EEEMMMd" + year + "jmm"
            return format.string(from: start, to: end)
        }
        let day = DateFormatter()
        day.calendar = calendar
        day.locale = locale
        day.timeZone = calendar.timeZone
        day.setLocalizedDateFormatFromTemplate("EEEMMMd" + year)
        format.dateTemplate = "jmm"
        return day.string(from: start) + " \u{00B7} " + format.string(from: start, to: end)
    }

    /// With whom and where, in words: "With Sinead · Google Meet", first
    /// names, two and how many more; nil with nobody and nowhere.
    public var with: String? {
        let names = people.map { person -> String in
            let name = person.name.trimmingCharacters(in: .whitespaces)
            if let first = name.split(separator: " ").first { return String(first) }
            return person.address.split(separator: "@").first.map(String.init) ?? person.address
        }
        var who = ""
        if !names.isEmpty {
            who = "With " + names.prefix(2).joined(separator: names.count == 2 ? " and " : ", ")
            if names.count > 2 { who += " and \(names.count - 2) more" }
        }
        let parts = [who, whereSaid].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// Who, in words: the people's names, and you last.
    public var who: String {
        (people.map { $0.name.isEmpty ? $0.address : $0.name } + ["you"]).joined(separator: ", ")
    }

    /// Where, in words: Google Meet or Zoom for a call's link, else as written.
    public var whereSaid: String {
        guard let url = URL(string: place), let key = CallLink.key(url) else { return place }
        if key.hasPrefix("meet:") { return "Google Meet" }
        if key.hasPrefix("zoom:") { return "Zoom" }
        if key.hasPrefix("teams:") { return "Microsoft Teams" }
        if key.hasPrefix("webex:") { return "Webex" }
        return url.host() ?? place
    }

    // MARK: - Google Calendar

    /// events.insert's body (with `sendUpdates=all` the guests are asked
    /// by Google): an all-day event by its dates, its last exclusive; a
    /// timed one in your zone.
    public func google(zone: TimeZone = .current) -> [String: Any] {
        var body: [String: Any] = ["summary": title]
        if allDay {
            let day = DateFormatter()
            day.calendar = Calendar(identifier: .gregorian)
            day.locale = Locale(identifier: "en_US_POSIX")
            day.timeZone = zone
            day.dateFormat = "yyyy-MM-dd"
            body["start"] = ["date": day.string(from: start)]
            body["end"] = ["date": day.string(from: max(end, start.addingTimeInterval(86_400)))]
        } else {
            let stamp = ISO8601DateFormatter()
            stamp.timeZone = zone
            stamp.formatOptions = [.withInternetDateTime]
            body["start"] = ["dateTime": stamp.string(from: start), "timeZone": zone.identifier]
            body["end"] = ["dateTime": stamp.string(from: end), "timeZone": zone.identifier]
        }
        if !place.isEmpty { body["location"] = place }
        if !people.isEmpty {
            body["attendees"] = people.map { person -> [String: Any] in
                var one: [String: Any] = ["email": person.address]
                if !person.name.isEmpty { one["displayName"] = person.name }
                return one
            }
        }
        return body
    }
}

extension MailClient {
    /// Making events in Google Calendar: never asked for yet. An account
    /// that gave it anyway (a consent of another day) adds its events
    /// there, guests asked by Google; every other adds to the Mac's.
    public static let eventsScope = "https://www.googleapis.com/auth/calendar.events"
}

extension MailGrant {
    /// The consent let Yab make events in its calendar (MailClient.eventsScope).
    public var calendarWrite: Bool { scopes.split(separator: " ").contains { $0 == MailClient.eventsScope } }
}
