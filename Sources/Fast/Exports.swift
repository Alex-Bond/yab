import Foundation

// What another browser writes out for someone to carry over: a bookmarks
// file, a history export, a passwords CSV. Each is read once and taken in;
// the file stays theirs to throw away, and nothing here keeps a copy.
//
// Pure reading, no app state, so it runs off the main thread and is what
// the tests hold to.

// MARK: - CSV

enum Csv {
    /// Quoted fields, doubled quotes inside them, and newlines inside those,
    /// all three turn up in a real export. A byte-order mark in front, which
    /// Excel and some password managers write, is not part of the first
    /// column's name.
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let body = text.hasPrefix("\u{FEFF}") ? text.dropFirst() : Substring(text)
        var index = body.startIndex

        while index < body.endIndex {
            let c = body[index]
            if quoted {
                if c == "\"" {
                    let next = body.index(after: index)
                    if next < body.endIndex, body[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n", "\r":
                    row.append(field)
                    field = ""
                    if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
            index = body.index(after: index)
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }

    /// A header cell as the lists below spell it: lowercase, no spaces or
    /// underscores, so "Last Visit Time", "last_visit_time" and
    /// "lastVisitTime" are one name.
    static func name(_ cell: String) -> String {
        cell.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

// MARK: - a bookmarks file

/// The "Netscape bookmark file" Safari, Firefox, Chrome and the rest all
/// export: a DL list of DT lines, a folder an H3 with a DL after it, a page
/// an A. Read by its tags, not as a document, the way the browsers that
/// import it do: its P and DT are never closed, and real files are looser
/// still.
enum BookmarkFile {
    /// The tree, with the bar's contents first at the top level, the way
    /// another browser's bookmarks come in (see Chromium.bookmarks), then
    /// the other folders. Nil when the text isn't a bookmarks file.
    static func parse(_ text: String) -> [Bookmark]? {
        guard text.range(of: "<dl", options: .caseInsensitive) != nil,
              text.range(of: "<a ", options: .caseInsensitive) != nil || text.range(of: "<h3", options: .caseInsensitive) != nil
        else { return nil }
        // Firefox and Chrome say which folder is the bar; Safari only names
        // it. A name counts only in a file that marks none.
        let marks = text.range(of: "personal_toolbar_folder", options: .caseInsensitive) != nil

        // One level for each DL that is open: what it holds, and the folder
        // it is, if it is one.
        struct Level {
            var title: String?
            var bar = false
            var added: Date?
            var nodes: [Bookmark] = []
        }
        var levels = [Level()]
        var bar: [Bookmark]?
        // The folder just named, waiting for the DL that holds what is in it.
        var named: (title: String, bar: Bool, added: Date?)?

        func close() {
            let done = levels.removeLast()
            guard let title = done.title else {
                levels[levels.count - 1].nodes += done.nodes
                return
            }
            if done.bar, bar == nil {
                bar = done.nodes
            } else {
                levels[levels.count - 1].nodes.append(.folder(title, done.nodes, added: done.added))
            }
        }

        var at = text.startIndex
        while let open = text[at...].firstIndex(of: "<") {
            guard let shut = text[open...].firstIndex(of: ">") else { break }
            let tag = text[text.index(after: open)..<shut]
            at = text.index(after: shut)
            switch tag.prefix(while: { !$0.isWhitespace }).lowercased() {
            case "dl":
                levels.append(Level(title: named?.title, bar: named?.bar ?? false, added: named?.added))
                named = nil
            case "/dl":
                if levels.count > 1 { close() }
            case "h3":
                let end = text.range(of: "</h3", options: .caseInsensitive, range: at..<text.endIndex)?.lowerBound ?? at
                let title = plain(text[at..<end])
                let flagged = tag.range(of: "personal_toolbar_folder=\"true\"", options: .caseInsensitive) != nil
                // Only near the top: a folder called Favorites three deep is
                // just a folder.
                let called = !marks && levels.count <= 2 && barNames.contains(title.lowercased())
                named = (title, flagged || called, added(tag))
                at = end
            case "a":
                let end = text.range(of: "</a", options: .caseInsensitive, range: at..<text.endIndex)?.lowerBound ?? at
                let title = plain(text[at..<end])
                at = end
                guard let href = attribute("href", in: tag),
                      let url = URL(string: href), Bookmark.keepable(url)
                else { continue }
                levels[levels.count - 1].nodes.append(.site(title, url, added: added(tag)))
            default:
                continue
            }
        }
        // A file cut short: what is still open closes where it stands.
        while levels.count > 1 { close() }
        return (bar ?? []) + levels[0].nodes
    }

    /// The folder a file's bookmarks go in, one of its own for each file so
    /// that two browsers' exports don't merge: the browser that wrote it
    /// when the file shows which, "Safari Bookmarks"; else the file's own
    /// name, "Work Links" for work_links.html; and for a name that says
    /// nothing, as Chrome's bookmarks_9_24_26.html doesn't, that name whole.
    static func name(for file: URL, text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("com.apple.readinglist") || lower.contains(">favorites</h3>") && !lower.contains("personal_toolbar_folder") {
            return "Safari Bookmarks"
        }
        if lower.contains("<h1>bookmarks menu</h1>") || lower.contains(">bookmarks toolbar</h3>") { return "Firefox Bookmarks" }
        if lower.contains(">favorites bar</h3>") || lower.contains(">favourites bar</h3>") { return "Edge Bookmarks" }

        let stem = file.deletingPathExtension().lastPathComponent
        let words = String(stem.reversed().drop { $0.isNumber || "_- .".contains($0) }.reversed())
            .replacingOccurrences(of: "_", with: " ")
        if words.isEmpty || ["bookmarks", "favorites", "favourites", "export"].contains(words.lowercased()) {
            return "Bookmarks from " + file.lastPathComponent
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// As browsers name their bar in the files they write, in British
    /// English too, the way Edge writes it there.
    private static let barNames: Set<String> = [
        "bookmarks bar", "bookmarks toolbar", "favorites", "favourites", "favorites bar", "favourites bar",
    ]

    /// When a page or a folder was kept, as the browser that wrote the file
    /// says it: seconds since 1970, as the format has them, or milliseconds
    /// or microseconds from some; Safari writes none. Never a day to come.
    private static func added(_ tag: Substring) -> Date? {
        guard let number = attribute("add_date", in: tag).flatMap(Double.init), number > 0 else { return nil }
        let date = number < 1e11 ? Date(timeIntervalSince1970: number) : HistoryFile.date(number)
        return date.flatMap { $0 > Date() ? nil : $0 }
    }

    /// One attribute's value, quoted either way or not at all.
    static func attribute(_ name: String, in tag: Substring) -> String? {
        guard let key = tag.range(of: name + "=", options: .caseInsensitive) else { return nil }
        var rest = tag[key.upperBound...]
        let value: Substring
        if let quote = rest.first, quote == "\"" || quote == "'" {
            rest = rest.dropFirst()
            value = rest.prefix { $0 != quote }
        } else {
            value = rest.prefix { !$0.isWhitespace }
        }
        return plain(value)
    }

    /// Text between tags as it reads: any tag inside dropped, the usual
    /// entities turned back into what they stand for, space collapsed.
    static func plain(_ raw: Substring) -> String {
        var text = ""
        var inTag = false
        for c in raw {
            if c == "<" { inTag = true } else if c == ">" { inTag = false } else if !inTag { text.append(c) }
        }
        if text.contains("&") {
            var out = ""
            var rest = Substring(text)
            while let amp = rest.firstIndex(of: "&") {
                out += rest[..<amp]
                let tail = rest[amp...]
                guard let semi = tail.prefix(10).firstIndex(of: ";") else {
                    out.append("&")
                    rest = tail.dropFirst()
                    continue
                }
                let entity = tail[tail.index(after: amp)..<semi].lowercased()
                if let known = entities[entity] {
                    out += known
                } else if entity.hasPrefix("#x"), let code = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                    out.unicodeScalars.append(scalar)
                } else if entity.hasPrefix("#"), let code = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(code) {
                    out.unicodeScalars.append(scalar)
                } else {
                    out += tail[amp...semi]
                }
                rest = tail[tail.index(after: semi)...]
            }
            text = out + rest
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]

    // MARK: written

    /// Yab's bookmarks as the same file, written the way Chrome writes its
    /// own (Bookmark Manager › Export Bookmarks), so any browser takes them
    /// in: what is on Yab's bar inside the bar's folder, marked as the bar,
    /// folders as H3 and DL, pages as A, each with when it was kept.
    /// `parse` reads it back as it was.
    static func write(_ roots: [Bookmark]) -> String {
        var out = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file.
             It will be read and overwritten.
             DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>

        """
        out += "    <DT><H3 ADD_DATE=\"\(stamp(nil))\" LAST_MODIFIED=\"0\" PERSONAL_TOOLBAR_FOLDER=\"true\">Bookmarks bar</H3>\n"
        out += "    <DL><p>\n"
        write(roots, depth: 2, into: &out)
        out += "    </DL><p>\n</DL><p>\n"
        return out
    }

    private static func write(_ nodes: [Bookmark], depth: Int, into out: inout String) {
        let pad = String(repeating: "    ", count: depth)
        for node in nodes {
            if let url = node.url {
                out += "\(pad)<DT><A HREF=\"\(escaped(url))\" ADD_DATE=\"\(stamp(node.added))\">\(escaped(node.title))</A>\n"
            } else {
                out += "\(pad)<DT><H3 ADD_DATE=\"\(stamp(node.added))\" LAST_MODIFIED=\"0\">\(escaped(node.title))</H3>\n"
                out += "\(pad)<DL><p>\n"
                write(node.children ?? [], depth: depth + 1, into: &out)
                out += "\(pad)</DL><p>\n"
            }
        }
    }

    /// Seconds since 1970, as the format has them; now when nobody said.
    private static func stamp(_ date: Date?) -> Int { Int((date ?? Date()).timeIntervalSince1970) }

    /// The four characters the format can't hold as they are, as Chrome
    /// writes them.
    static func escaped(_ text: String) -> String {
        var out = ""
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }
}

// MARK: - a history export

/// Where someone has been, as a browser or an extension wrote it out: a CSV
/// with an address, a title and when (Safari, history exporters), or the
/// JSON Safari's Export Browsing Data and Google Takeout write. Each row a
/// visit or a place with its count; either way it comes out as places, the
/// same as another browser's history (see Chromium.places).
enum HistoryFile {
    /// An exported file's text, whatever it was written in: UTF-16 when it
    /// starts with that byte-order mark, as Excel and Windows tools save a
    /// CSV, else UTF-8, else Latin-1, which reads any bytes at all.
    static func text(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return text(data)
    }

    static func text(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Nil when it is neither. `fallback` is when a row that says nothing of
    /// its time was visited: the file's own date, so no later than that.
    static func places(in text: String, fallback: Date) -> [Chromium.Place]? {
        let trimmed = text.drop(while: { $0 == "\u{FEFF}" || $0.isWhitespace })
        if trimmed.first == "{" || trimmed.first == "[" {
            return json(Data(trimmed.utf8), fallback: fallback)
        }
        return csv(String(trimmed), fallback: fallback)
    }

    private static func csv(_ text: String, fallback: Date) -> [Chromium.Place]? {
        var rows = Csv.rows(text)
        guard !rows.isEmpty else { return nil }
        let header = rows.removeFirst().map(Csv.name)
        func column(_ names: Set<String>) -> Int? { header.firstIndex { names.contains($0) } }
        guard let urlAt = column(["url", "address", "link", "pageurl", "uri", "location"]) else { return nil }
        let titleAt = column(["title", "name", "pagetitle"])
        let timeAt = column([
            "visittime", "lastvisittime", "lastvisited", "lastvisit", "visitdate", "datevisited", "visitedon",
            "visited", "time", "date", "datetime", "timestamp", "timeusec", "visittimeusec",
        ])
        let countAt = column(["visitcount", "visits", "count", "numberofvisits"])

        var out: [Chromium.Place] = []
        for row in rows where row.count > urlAt {
            func cell(_ at: Int?) -> String? {
                guard let at, row.count > at else { return nil }
                let value = row[at].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            guard let place = place(
                address: row[urlAt].trimmingCharacters(in: .whitespaces),
                title: cell(titleAt) ?? "",
                when: cell(timeAt).flatMap(date),
                count: cell(countAt).flatMap { Int($0) },
                fallback: fallback
            ) else { continue }
            out.append(place)
        }
        return out
    }

    private static func json(_ data: Data, fallback: Date) -> [Chromium.Place]? {
        guard let top = try? JSONSerialization.jsonObject(with: data) else { return nil }
        // Safari: {"history": [...]}; Takeout: {"Browser History": [...]};
        // a bare list from anything else.
        let list = (top as? [[String: Any]])
            ?? (top as? [String: Any]).flatMap { $0["history"] ?? $0["Browser History"] } as? [[String: Any]]
        guard let list else { return nil }
        return list.compactMap { item in
            let when = (item["time_usec"] ?? item["visit_time"] ?? item["lastVisitTime"] ?? item["time"]).flatMap { raw -> Date? in
                if let number = raw as? NSNumber { return date(number.doubleValue) }
                return (raw as? String).flatMap(date)
            }
            return place(
                address: item["url"] as? String ?? "",
                title: item["title"] as? String ?? "",
                when: when,
                count: (item["visit_count"] ?? item["visitCount"]) as? Int,
                fallback: fallback
            )
        }
    }

    private static func place(address: String, title: String, when: Date?, count: Int?, fallback: Date) -> Chromium.Place? {
        guard let url = URL(string: address), url.scheme == "http" || url.scheme == "https" else { return nil }
        // Never in the future: a time guessed in the wrong unit, or a clock
        // that was wrong, would otherwise rank a place first for months.
        return Chromium.Place(url: url, title: title, count: max(1, count ?? 1), typed: 0, last: min(when ?? fallback, Date()))
    }

    /// A time as the exporters write one: a number in whichever unit and
    /// epoch its size gives away, or a date in words.
    static func date(_ text: String) -> Date? {
        if let number = Double(text) { return date(number) }
        if let date = iso.date(from: text) ?? isoFraction.date(from: text) { return date }
        for format in formats {
            if let date = format.date(from: text) { return date }
        }
        return nil
    }

    /// Chromium's microseconds since 1601, Unix microseconds, milliseconds
    /// or seconds, or Apple's seconds since 2001, Safari's own, told apart
    /// by size. For a time between September 2001, when Unix seconds reach
    /// 1e9, and 2032, when Apple's do, each unit falls in a band of its own;
    /// outside those years the guess can be wrong, and `place` keeps a wrong
    /// one from landing in the future.
    static func date(_ number: Double) -> Date? {
        guard number.isFinite, number > 0 else { return nil }
        switch number {
        case 1e16...: return Date(timeIntervalSince1970: number / 1_000_000 - 11_644_473_600)
        case 1e14...: return Date(timeIntervalSince1970: number / 1_000_000)
        case 1e11...: return Date(timeIntervalSince1970: number / 1000)
        case 1e9...: return Date(timeIntervalSince1970: number)
        default: return Date(timeIntervalSinceReferenceDate: number)
        }
    }

    private static let iso = ISO8601DateFormatter()
    private static let isoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let formats: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
        "MM/dd/yyyy HH:mm:ss", "M/d/yyyy, h:mm:ss a", "M/d/yyyy h:mm:ss a", "M/d/yyyy", "dd.MM.yyyy HH:mm:ss", "dd.MM.yyyy",
    ].map { pattern in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter
    }
}
