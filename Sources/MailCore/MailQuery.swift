import Foundation

// A search of mail in Gmail's own words (docs/mail.md, Search): from:, to:,
// cc:, subject:, has:attachment, is:unread, is:starred, label:, in:,
// category:, before:, after:, older_than:, newer_than:, "words in quotes",
// a minus before anything, OR, {braces} and (parentheses). One value says
// what was asked, and three things answer it: the store, from the mail on
// this Mac (`local`, its word index and its columns); Gmail, from the whole
// mailbox (`gmail`, the same search written as Gmail reads it); and a
// message or a thread in hand (`matches`). The column's search and the
// agents' mail_search read it, and the splits and labels to come.
//
// As Gmail does, a search is asked of each message, and a thread answers
// when one of its messages does. Words here match a word's start, as you
// type them ("lind" finds Lindqvist); in quotes, the words as they stand
// together. has:attachment is what each mail kept says of its files
// (MailMessage.attached). What the Mac can't tell (a label it hasn't
// learned the name of, Gmail operators it keeps no column for) makes the
// whole search Gmail's to answer: half an answer from here would read as
// the whole one.

public struct MailQuery: Equatable, Hashable, Sendable {
    /// Where words are looked for in a message.
    public enum Part: String, Sendable { case all, subject }

    /// A field of people in a message's head.
    public enum Field: String, Sendable { case from, to, cc, bcc }

    public indirect enum Term: Equatable, Hashable, Sendable {
        /// Words: a word's start, or (`exact`, quoted) the words as they
        /// stand together.
        case text(String, Part, exact: Bool)
        /// A name, an address or a piece of one in a field; "me" is the account.
        case person(Field, String)
        /// A label by its name (label:work/clients), or one of Gmail's own
        /// boxes (in:inbox, `box`); category:updates is Gmail's label for it.
        case label(String, box: Bool)
        /// is:unread, is:read, is:starred, is:important.
        case flag(String)
        /// has:attachment, has:userlabels and the rest.
        case has(String)
        /// On or after a moment; before one.
        case after(Date)
        case before(Date)
        /// Newer or older than so many days, weeks, months or years ago.
        case newer(Int, Calendar.Component)
        case older(Int, Calendar.Component)
        /// in:anywhere: Spam and Trash too.
        case anywhere
        /// One of Gmail's operators this Mac keeps nothing for (size:,
        /// filename:, list:): Gmail alone answers it.
        case other(String, String)
        case not(Term)
        case all([Term])
        case any([Term])
    }

    /// What was asked, nil for nothing at all.
    public let root: Term?
    /// As it was typed.
    public let text: String

    public var isEmpty: Bool { root == nil }

    // MARK: - reading a search

    /// Gmail's operators by name, and what this Mac makes of each.
    private static let fields: [String: Field] = ["from": .from, "to": .to, "cc": .cc, "bcc": .bcc]
    private static let others: Set<String> = ["filename", "list", "deliveredto", "rfc822msgid", "size", "larger", "smaller", "around"]

    /// A search as typed, read the way Gmail reads it: OR binds closer than
    /// the space between terms, a minus negates what follows it, a word
    /// before a colon that is no operator of Gmail's is a word. Never fails:
    /// what can't be read is words. Dates are midnight in `calendar`'s zone.
    public static func parse(_ text: String, calendar: Calendar = .current) -> MailQuery {
        var reader = Reader(chars: Array(text), calendar: calendar)
        let terms = reader.sequence(until: nil)
        return MailQuery(root: flat(.all(terms)), text: text)
    }

    /// A person's mail as the search's chip narrows it: with them (from,
    /// to or cc), from them, or to them; and words, when there are any.
    public static func person(_ rel: String, _ address: String, words: String = "", calendar: Calendar = .current) -> MailQuery {
        let who: Term
        switch rel {
        case "from": who = .person(.from, address)
        case "to": who = .person(.to, address)
        default: who = .any([.person(.from, address), .person(.to, address), .person(.cc, address)])
        }
        let more = parse(words, calendar: calendar).root
        let said = rel + ":" + address + (words.trimmingCharacters(in: .whitespaces).isEmpty ? "" : " " + words)
        return MailQuery(root: flat(.all([who] + (more.map { [$0] } ?? []))), text: said)
    }

    /// Nested ANDs and ORs made one, a group of one its term, nothing gone.
    private static func flat(_ term: Term) -> Term? {
        switch term {
        case .all(let terms), .any(let terms):
            let any: Bool
            if case .any = term { any = true } else { any = false }
            var out: [Term] = []
            for one in terms.compactMap(flat) {
                switch (one, any) {
                case (.all(let inner), false), (.any(let inner), true): out += inner
                default: out.append(one)
                }
            }
            if out.isEmpty { return nil }
            if out.count == 1 { return out[0] }
            return any ? .any(out) : .all(out)
        case .not(let inner):
            return flat(inner).map { .not($0) }
        case .text(let words, _, _):
            return MailQuery.words(words).isEmpty ? nil : term
        default:
            return term
        }
    }

    private struct Reader {
        public let chars: [Character]
        public let calendar: Calendar
        public var at = 0

        public init(chars: [Character], calendar: Calendar) {
            self.chars = chars
            self.calendar = calendar
        }

        public var done: Bool { at >= chars.count }

        public mutating func spaces() {
            while !done, chars[at].isWhitespace { at += 1 }
        }

        /// Terms one after another, all of them asked: up to `end` (a
        /// closing parenthesis or brace) or the end.
        public mutating func sequence(until end: Character?) -> [Term] {
            var out: [Term] = []
            while true {
                spaces()
                if done { break }
                if let end, chars[at] == end { at += 1; break }
                // A stray closing mark is no term.
                if chars[at] == ")" || chars[at] == "}" { at += 1; continue }
                if let term = either(until: end) { out.append(term) }
            }
            return out
        }

        /// A term, or several with OR between them.
        mutating func either(until end: Character?) -> Term? {
            var terms: [Term] = []
            if let first = unary(until: end) { terms.append(first) }
            while true {
                let mark = at
                spaces()
                guard word(is: "OR") else { at = mark; break }
                at += 2
                spaces()
                if let next = unary(until: end) { terms.append(next) }
            }
            return terms.count > 1 ? .any(terms) : terms.first
        }

        /// The next characters are this word on its own (OR, AND).
        public func word(is said: String) -> Bool {
            let letters = Array(said)
            guard at + letters.count <= chars.count, Array(chars[at..<at + letters.count]) == letters else { return false }
            let after = at + letters.count
            return after == chars.count || chars[after].isWhitespace || chars[after] == "(" || chars[after] == "\""
        }

        public mutating func unary(until end: Character?) -> Term? {
            spaces()
            guard !done else { return nil }
            if word(is: "AND") {
                at += 3
                return unary(until: end)
            }
            if chars[at] == "-", at + 1 < chars.count, !chars[at + 1].isWhitespace {
                at += 1
                return unary(until: end).map { .not($0) }
            }
            return primary(until: end)
        }

        public mutating func primary(until end: Character?) -> Term? {
            switch chars[at] {
            case "(":
                at += 1
                return .all(sequence(until: ")"))
            case "{":
                at += 1
                return .any(sequence(until: "}"))
            case "\"":
                return .text(quoted(), .all, exact: true)
            default:
                break
            }
            let token = bare()
            guard let colon = token.firstIndex(of: ":") else { return .text(token, .all, exact: false) }
            let name = token[..<colon].lowercased(), rest = String(token[token.index(after: colon)...])
            guard MailQuery.operators.contains(name) else { return .text(token, .all, exact: false) }
            // The value: a word, words in quotes, or a group in parentheses.
            if rest.isEmpty, !done, chars[at] == "\"" {
                return MailQuery.term(name, quoted(), quoted: true, calendar: calendar)
            }
            if rest.isEmpty, !done, chars[at] == "(" || chars[at] == "{" {
                let any = chars[at] == "{"
                at += 1
                let group = sequence(until: any ? "}" : ")")
                let scoped = group.map { MailQuery.scope($0, name: name, calendar: calendar) }
                return any ? .any(scoped) : .all(scoped)
            }
            if rest.isEmpty { return .text(token, .all, exact: false) }
            return MailQuery.term(name, rest, quoted: false, calendar: calendar)
        }

        /// Words between quotes; an unclosed quote runs to the end.
        public mutating func quoted() -> String {
            at += 1
            var out = ""
            while !done, chars[at] != "\"" {
                out.append(chars[at])
                at += 1
            }
            if !done { at += 1 }
            return out
        }

        /// A word up to a space, a quote or a parenthesis or brace.
        public mutating func bare() -> String {
            var out = ""
            while !done, !chars[at].isWhitespace, !"(){}\"".contains(chars[at]) {
                out.append(chars[at])
                at += 1
            }
            // A lone mark the loop can't take still moves the reader on.
            if out.isEmpty, !done {
                out.append(chars[at])
                at += 1
            }
            return out
        }
    }

    private static let operators: Set<String> = Set(fields.keys).union(others).union([
        "subject", "label", "in", "is", "has", "category", "before", "after", "older", "newer", "older_than", "newer_than",
    ])

    /// An operator's term from its value.
    private static func term(_ name: String, _ value: String, quoted: Bool, calendar: Calendar) -> Term {
        let value = value.trimmingCharacters(in: .whitespaces)
        if let field = fields[name] { return .person(field, value) }
        switch name {
        case "subject": return .text(value, .subject, exact: quoted)
        case "label": return .label(value, box: false)
        case "in": return value.lowercased() == "anywhere" ? .anywhere : .label(value, box: true)
        case "is": return .flag(value.lowercased())
        case "has": return .has(value.lowercased())
        case "category":
            let tab = value.lowercased() == "primary" ? "personal" : value.lowercased()
            return .label("CATEGORY_" + tab.uppercased(), box: true)
        case "before", "older": return day(value, calendar: calendar).map { .before($0) } ?? .other(name, value)
        case "after", "newer": return day(value, calendar: calendar).map { .after($0) } ?? .other(name, value)
        case "older_than": return span(value).map { .older($0.0, $0.1) } ?? .other(name, value)
        case "newer_than": return span(value).map { .newer($0.0, $0.1) } ?? .other(name, value)
        default: return .other(name, value)
        }
    }

    /// A group after an operator (subject:(board deck), from:(anna OR
    /// mark)): the operator taken by each of its words.
    private static func scope(_ term: Term, name: String, calendar: Calendar) -> Term {
        switch term {
        case .text(let words, _, let exact): return MailQuery.term(name, words, quoted: exact, calendar: calendar)
        case .not(let inner): return .not(scope(inner, name: name, calendar: calendar))
        case .all(let terms): return .all(terms.map { scope($0, name: name, calendar: calendar) })
        case .any(let terms): return .any(terms.map { scope($0, name: name, calendar: calendar) })
        default: return term
        }
    }

    /// A day as Gmail takes one: 2024/01/31, 2024-1-31, 01/31/2024, or a
    /// moment in seconds since 1970; midnight of the day where `calendar` is.
    public static func day(_ text: String, calendar: Calendar) -> Date? {
        if text.count >= 9, text.allSatisfy(\.isNumber), let seconds = Double(text) { return Date(timeIntervalSince1970: seconds) }
        let parts = text.split(whereSeparator: { "/-.".contains($0) }).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let (year, month, day) = parts[0] > 31 ? (parts[0], parts[1], parts[2]) : (parts[2], parts[0], parts[1])
        guard year > 1900, (1...12).contains(month), (1...31).contains(day) else { return nil }
        var asked = DateComponents()
        asked.year = year
        asked.month = month
        asked.day = day
        guard let date = calendar.date(from: asked), calendar.component(.day, from: date) == day else { return nil }
        return date
    }

    /// 3d, 2w, 6m, 1y: Gmail's days, months and years, and weeks.
    public static func span(_ text: String) -> (Int, Calendar.Component)? {
        guard let unit = text.lowercased().last, let count = Int(text.dropLast()), count >= 0 else { return nil }
        switch unit {
        case "d": return (count, .day)
        case "w": return (count * 7, .day)
        case "m": return (count, .month)
        case "y": return (count, .year)
        default: return nil
        }
    }

    // MARK: - words

    /// Words as the store's word index splits them (unicode61): runs of
    /// letters and digits, as typed. The index folds what it is asked as it
    /// folded what it keeps, so they go to it like this.
    public static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// The same words lowercased, accents off: compared here, in hand.
    public static func tokens(_ text: String) -> [String] { words(fold(text)) }

    /// For comparing as the search does: case and accents gone.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The words to light in what a search found: what it looks for, not
    /// what it leaves out or the operators' own.
    public var lit: [String] {
        var out: [String] = []
        func walk(_ term: Term, _ negated: Bool) {
            switch term {
            case .text(let words, _, _) where !negated: out += MailQuery.words(words)
            case .person(.from, let who) where !negated && who.lowercased() != "me": out += MailQuery.words(who)
            case .not(let inner): walk(inner, !negated)
            case .all(let terms), .any(let terms): terms.forEach { walk($0, negated) }
            default: break
            }
        }
        root.map { walk($0, false) }
        return out
    }

    /// The words it looks for, as typed, not what it leaves out or an
    /// operator's: what an index of words alone is asked (the mail memory).
    public var keywords: [String] {
        var out: [String] = []
        func walk(_ term: Term, _ negated: Bool) {
            switch term {
            case .text(let words, _, _) where !negated: out += MailQuery.words(words)
            case .not(let inner): walk(inner, !negated)
            case .all(let terms), .any(let terms): terms.forEach { walk($0, negated) }
            default: break
            }
        }
        root.map { walk($0, false) }
        return out
    }

    /// The one person it wants mail from, when it names one with from:
    /// beside everything else it asks (not "me").
    public var sender: String? {
        let top: [Term]
        switch root {
        case .all(let terms)?: top = terms
        case let one?: top = [one]
        case nil: top = []
        }
        let named = top.compactMap { term -> String? in
            if case .person(.from, let who) = term, who.lowercased() != "me" { return who }
            return nil
        }
        return named.count == 1 ? named[0] : nil
    }

    // MARK: - asking Gmail

    /// The same search as Gmail reads it, every operator in its own words;
    /// a day as its moment in seconds, so Gmail's midnight is this Mac's.
    public var gmail: String { root.map { Self.gmail($0, top: true) } ?? "" }

    private static func gmail(_ term: Term, top: Bool = false) -> String {
        switch term {
        case .text(let words, .all, let exact): return exact ? "\"" + clean(words) + "\"" : value(words)
        case .text(let words, .subject, let exact): return "subject:" + (exact ? "\"" + clean(words) + "\"" : value(words))
        case .person(let field, let who): return field.rawValue + ":" + value(who)
        case .label(let name, let box):
            if name.hasPrefix("CATEGORY_") { return "category:" + name.dropFirst(9).lowercased() }
            return (box ? "in:" : "label:") + value(name.replacingOccurrences(of: " ", with: "-"))
        case .flag(let flag): return "is:" + flag
        case .has(let what): return "has:" + what
        case .after(let date): return "after:" + String(Int(date.timeIntervalSince1970))
        case .before(let date): return "before:" + String(Int(date.timeIntervalSince1970))
        case .newer(let count, let unit): return "newer_than:" + said(count, unit)
        case .older(let count, let unit): return "older_than:" + said(count, unit)
        case .anywhere: return "in:anywhere"
        case .other(let name, let value): return name + ":" + Self.value(value)
        case .not(let inner):
            switch inner {
            case .all, .any: return "-(" + gmail(inner, top: true) + ")"
            default: return "-" + gmail(inner)
            }
        case .all(let terms):
            let said = terms.map { gmail($0) }.joined(separator: " ")
            return top ? said : "(" + said + ")"
        case .any(let terms):
            let said = terms.map { gmail($0) }.joined(separator: " OR ")
            return top ? said : "(" + said + ")"
        }
    }

    private static func said(_ count: Int, _ unit: Calendar.Component) -> String {
        "\(count)" + (unit == .year ? "y" : unit == .month ? "m" : "d")
    }

    private static func clean(_ text: String) -> String { text.replacingOccurrences(of: "\"", with: " ") }

    /// A value as one word, in quotes when it has room for more.
    private static func value(_ text: String) -> String {
        text.contains(where: { $0.isWhitespace || "(){}".contains($0) }) ? "\"" + clean(text) + "\"" : text
    }

    // MARK: - what the Mac can't tell

    /// Gmail's own boxes and what their labels are called.
    public static let boxes: [String: String] = [
        "inbox": "INBOX", "sent": "SENT", "starred": "STARRED", "important": "IMPORTANT", "unread": "UNREAD",
        "trash": "TRASH", "spam": "SPAM", "draft": "DRAFT", "drafts": "DRAFT", "chat": "CHAT", "chats": "CHAT",
    ]

    /// A label's id as the store keeps it in messages: a box's name, a
    /// category's, or a label of yours by `known` (its name to its id).
    public static func labelID(_ name: String, known: (String) -> String?) -> String? {
        if name.hasPrefix("CATEGORY_") { return name }
        if let box = boxes[name.lowercased()] { return box }
        return known(name)
    }

    /// Whether the store can answer every term of it: false for a has:
    /// it keeps nothing for, Gmail's operators it keeps nothing for, Bcc,
    /// an is: it doesn't know, and labels it doesn't know the name of.
    public func answerable(labels known: (String) -> String?) -> Bool {
        func can(_ term: Term) -> Bool {
            switch term {
            case .text, .after, .before, .newer, .older, .anywhere: return true
            case .person(let field, _): return field != .bcc
            case .label(let name, _): return MailQuery.labelID(name, known: known) != nil
            case .flag(let flag): return ["unread", "read", "starred", "important"].contains(flag)
            case .has(let what): return ["attachment", "userlabels", "nouserlabels"].contains(what)
            case .other: return false
            case .not(let inner): return can(inner)
            case .all(let terms), .any(let terms): return terms.allSatisfy(can)
            }
        }
        return root.map(can) ?? true
    }

    /// Labels of yours it names, for the store to learn the ids of.
    public var labelNames: [String] {
        var out: [String] = []
        func walk(_ term: Term) {
            switch term {
            case .label(let name, _) where MailQuery.labelID(name, known: { _ in nil }) == nil: out.append(name)
            case .not(let inner): walk(inner)
            case .all(let terms), .any(let terms): terms.forEach(walk)
            default: break
            }
        }
        root.map(walk)
        return out
    }

    /// The search reaches past what this Mac keeps: it asks for mail older
    /// than a day (before:, older_than:), or for a span that starts before
    /// `horizon`, the oldest the sync keeps of everything. Gmail answers it.
    public func reachesPast(_ horizon: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        func ago(_ count: Int, _ unit: Calendar.Component) -> Date { calendar.date(byAdding: unit, value: -count, to: now) ?? now }
        // Not before a day is after it, and the other way round.
        func reach(_ term: Term, _ negated: Bool) -> Bool {
            switch term {
            case .before(let date): return negated ? date < horizon : true
            case .older(let count, let unit): return negated ? ago(count, unit) < horizon : true
            case .after(let date): return negated ? true : date < horizon
            case .newer(let count, let unit): return negated ? true : ago(count, unit) < horizon
            case .not(let inner): return reach(inner, !negated)
            case .all(let terms), .any(let terms): return terms.contains { reach($0, negated) }
            default: return false
            }
        }
        return root.map { reach($0, false) } ?? false
    }

    /// It asks of labels or flags (label:, in:, category:, is:,
    /// has:userlabels): what answers it moves as mail is labeled or read,
    /// not only as mail comes (MailSplitCache keeps a split's answers by it).
    public var labeled: Bool {
        func asks(_ term: Term) -> Bool {
            switch term {
            case .label, .flag: return true
            case .has(let what): return what == "userlabels" || what == "nouserlabels"
            case .not(let inner): return asks(inner)
            case .all(let terms), .any(let terms): return terms.contains(where: asks)
            default: return false
            }
        }
        return root.map(asks) ?? false
    }

    /// Whether it asks for Spam or Trash, which a search otherwise leaves out.
    var wantsBin: Bool {
        func wants(_ term: Term) -> Bool {
            switch term {
            case .anywhere: return true
            case .label(let name, _): return ["TRASH", "SPAM"].contains(MailQuery.boxes[name.lowercased()] ?? "")
            case .not(let inner): return wants(inner)
            case .all(let terms), .any(let terms): return terms.contains(where: wants)
            default: return false
            }
        }
        return root.map(wants) ?? false
    }

    // MARK: - the store's answer

    /// What the store asks of each message (`messages m`, its word index
    /// `words` by the message's rowid): a WHERE and its arguments. Nil when
    /// it can't tell (`answerable`). From: and words go to the word index;
    /// To and Cc are read folded, case and accents off, by the store's own
    /// SQL function yab_fold, so a name in any script is found.
    /// `words`: the word index's expression alone, when that is all the
    /// search asks (no person, label or time, Spam and Trash left out):
    /// the store answers it from the index and a map of its own, without
    /// reading a message (MailStore.find).
    public func local(me: String, labels known: (String) -> String?, now: Date = Date(), calendar: Calendar = .current)
        -> (sql: String, args: [Any], words: String?)? {
        guard let root, answerable(labels: known) else { return nil }
        var args: [Any] = []
        let me = me.lowercased()

        /// Words for the word index, or nil for none to look for.
        func match(_ term: Term) -> String? {
            switch term {
            case .text(let words, let part, let exact):
                let phrase = MailQuery.words(words).joined(separator: " ")
                guard !phrase.isEmpty else { return nil }
                return (part == .subject ? "subject : " : "") + "\"" + phrase + "\"" + (exact ? "" : "*")
            case .person(.from, let who) where who.lowercased() != "me":
                let phrase = MailQuery.words(who).joined(separator: " ")
                return phrase.isEmpty ? nil : "sender : \"" + phrase + "\"*"
            default: return nil
            }
        }

        func words(_ expression: String) -> String {
            args.append(expression)
            return "m.rowid IN (SELECT rowid FROM words WHERE words MATCH ?)"
        }

        func has(_ label: String) -> String {
            args.append("|" + label + "|")
            return "instr(m.labels, ?) > 0"
        }

        func at(_ op: String, _ date: Date) -> String {
            args.append(date.timeIntervalSince1970)
            return "m.at " + op + " ?"
        }

        func sql(_ term: Term) -> String {
            if let expression = match(term) { return words(expression) }
            switch term {
            // Nothing in it a word could be made of: it asks nothing.
            case .text: return "1"
            case .person(.from, let who):
                guard who.lowercased() == "me" else { return "1" }
                args.append(me)
                return "m.from_addr = ?"
            case .person(let field, let who):
                let needle = who.lowercased() == "me" ? me : MailQuery.fold(who)
                guard !needle.isEmpty else { return "1" }
                // Plain letters by SQLite's own LIKE, which folds their case;
                // accents and any other script by yab_fold, slower, row by row.
                let plain = who.allSatisfy(\.isASCII)
                let like = "%" + needle.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_") + "%"
                func contains(_ column: String) -> String {
                    args.append(plain ? like : needle)
                    return plain ? column + " LIKE ? ESCAPE '\\'" : "instr(yab_fold(\(column)), ?) > 0"
                }
                // To is anyone it was sent to, as Gmail's to: is.
                return field == .cc ? contains("m.cc") : "(" + contains("m.recipients") + " OR " + contains("m.cc") + ")"
            case .label(let name, _): return has(MailQuery.labelID(name, known: known) ?? "")
            case .flag("read"): return "NOT " + has("UNREAD")
            case .flag(let flag): return has(flag.uppercased())
            case .has("attachment"): return "m.attached = 1"
            case .has("userlabels"): return "instr(m.labels, '|Label_') > 0"
            case .has("nouserlabels"): return "instr(m.labels, '|Label_') = 0"
            case .after(let date): return at(">=", date)
            case .before(let date): return at("<", date)
            case .newer(let count, let unit): return at(">=", calendar.date(byAdding: unit, value: -count, to: now) ?? now)
            case .older(let count, let unit): return at("<", calendar.date(byAdding: unit, value: -count, to: now) ?? now)
            case .anywhere: return "1"
            case .has, .other: return "0"
            case .not(let inner): return "NOT (" + sql(inner) + ")"
            case .all(let terms):
                // Words asked together are one ask of the index.
                let found = terms.compactMap(match)
                var parts = found.isEmpty ? [] : [words(found.joined(separator: " AND "))]
                parts += terms.filter { match($0) == nil }.map(sql)
                return parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " AND ") + ")"
            case .any(let terms):
                let found = terms.compactMap(match)
                if found.count == terms.count { return words("(" + found.joined(separator: " OR ") + ")") }
                return "(" + terms.map(sql).joined(separator: " OR ") + ")"
            }
        }

        var clause = sql(root)
        let alone = !wantsBin && args.count == 1 && clause == "m.rowid IN (SELECT rowid FROM words WHERE words MATCH ?)" ? args[0] as? String : nil
        if !wantsBin { clause = "(" + clause + ") AND instr(m.labels, '|TRASH|') = 0 AND instr(m.labels, '|SPAM|') = 0" }
        return (clause, args, alone)
    }

    // MARK: - a message or a thread in hand

    /// Whether a message answers, as the store would say: its subject,
    /// sender and words (its body, or its snippet before the body is here),
    /// its people, labels and time.
    public func matches(_ message: MailMessage, me: String, labels known: (String) -> String? = { _ in nil },
                 now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let root else { return false }
        let subject = MailQuery.tokens(message.subject)
        let sender = MailQuery.tokens(message.from.name + " " + message.from.address)
        let all = subject + sender + MailQuery.tokens(message.text ?? message.snippet)
        let recipients = MailQuery.fold(message.to.map(\.header).joined(separator: ", "))
        let cc = MailQuery.fold(message.cc.map(\.header).joined(separator: ", "))
        let me = me.lowercased()
        func ask(_ term: Term) -> Bool {
            switch term {
            case .text(let words, let part, let exact):
                return MailQuery.found(MailQuery.tokens(words), in: part == .subject ? subject : all, prefix: !exact)
            case .person(.from, let who):
                return who.lowercased() == "me" ? message.from.address.lowercased() == me
                    : MailQuery.found(MailQuery.tokens(who), in: sender, prefix: true)
            case .person(let field, let who):
                let needle = who.lowercased() == "me" ? me : MailQuery.fold(who)
                if field == .cc { return cc.contains(needle) }
                return field == .to && (recipients.contains(needle) || cc.contains(needle))
            case .label(let name, _): return MailQuery.labelID(name, known: known).map(message.labels.contains) ?? false
            case .flag("read"): return !message.labels.contains("UNREAD")
            case .flag(let flag): return message.labels.contains(flag.uppercased())
            case .has("attachment"): return message.attached == true
            case .has("userlabels"): return message.labels.contains { $0.hasPrefix("Label_") }
            case .has("nouserlabels"): return !message.labels.contains { $0.hasPrefix("Label_") }
            case .has, .other: return false
            case .after(let date): return message.date >= date
            case .before(let date): return message.date < date
            case .newer(let count, let unit): return message.date >= calendar.date(byAdding: unit, value: -count, to: now) ?? now
            case .older(let count, let unit): return message.date < calendar.date(byAdding: unit, value: -count, to: now) ?? now
            case .anywhere: return true
            case .not(let inner): return !ask(inner)
            case .all(let terms): return terms.allSatisfy(ask)
            case .any(let terms): return terms.contains(where: ask)
            }
        }
        if !wantsBin, !message.labels.isDisjoint(with: ["TRASH", "SPAM"]) { return false }
        return ask(root)
    }

    /// Whether a thread answers, as a list shows it: its subject, its last
    /// words and the people who wrote in it, its labels, unread, its last
    /// time. A thread doesn't say who mail was sent to or what is in its
    /// files: to:, cc: and has: never match one (the store answers those,
    /// message by message).
    public func matches(_ thread: MailThread, me: String, labels known: (String) -> String? = { _ in nil },
                 now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let root else { return false }
        let subject = MailQuery.tokens(thread.subject)
        let people = MailQuery.tokens(thread.people.map { $0.name + " " + $0.address }.joined(separator: " "))
        let all = subject + people + MailQuery.tokens(thread.snippet)
        func ask(_ term: Term) -> Bool {
            switch term {
            case .text(let words, let part, let exact):
                return MailQuery.found(MailQuery.tokens(words), in: part == .subject ? subject : all, prefix: !exact)
            case .person(.from, let who):
                return who.lowercased() == "me" ? thread.lastIsMine || thread.labels.contains("SENT")
                    : MailQuery.found(MailQuery.tokens(who), in: people, prefix: true)
            case .person: return false
            case .label(let name, _): return MailQuery.labelID(name, known: known).map(thread.labels.contains) ?? false
            case .flag("unread"): return thread.unread
            case .flag("read"): return !thread.unread
            case .flag(let flag): return thread.labels.contains(flag.uppercased())
            case .has("attachment"): return thread.attached
            case .has("userlabels"): return thread.labels.contains { $0.hasPrefix("Label_") }
            case .has("nouserlabels"): return !thread.labels.contains { $0.hasPrefix("Label_") }
            case .has, .other: return false
            case .after(let date): return thread.last >= date
            case .before(let date): return thread.last < date
            case .newer(let count, let unit): return thread.last >= calendar.date(byAdding: unit, value: -count, to: now) ?? now
            case .older(let count, let unit): return thread.last < calendar.date(byAdding: unit, value: -count, to: now) ?? now
            case .anywhere: return true
            case .not(let inner): return !ask(inner)
            case .all(let terms): return terms.allSatisfy(ask)
            case .any(let terms): return terms.contains(where: ask)
            }
        }
        if !wantsBin, !thread.labels.isDisjoint(with: ["TRASH", "SPAM"]) { return false }
        return ask(root)
    }

    /// The words one after another in `text`, the last a word's start
    /// when `prefix`, as the word index matches a phrase.
    public static func found(_ words: [String], in text: [String], prefix: Bool) -> Bool {
        guard !words.isEmpty else { return true }
        guard text.count >= words.count else { return false }
        for start in 0...(text.count - words.count) {
            var all = true
            for (n, word) in words.enumerated() {
                let here = text[start + n]
                let last = n == words.count - 1
                if !(here == word || (prefix && last && here.hasPrefix(word))) {
                    all = false
                    break
                }
            }
            if all { return true }
        }
        return false
    }

    public init(root: Term?, text: String) {
        self.root = root
        self.text = text
    }
}
