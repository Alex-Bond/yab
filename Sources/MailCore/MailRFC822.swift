import Foundation

// A whole message as a server that isn't Gmail gives it (RFC 5322, MIME):
// read into the shape of Gmail's message resource, so one reader
// (MailGmail.message) makes every provider's MailMessage, its words, its
// files and its invitation alike. Parts are numbered as Gmail numbers them
// ("0", "0.1"); a file's id is "p:" and that number, its bytes read again
// from the message whole when asked (MailRFC822.part).

public enum MailRFC822 {
    /// One part of a message: its headers as they came, its body's bytes
    /// with the transfer encoding undone, and the parts inside it.
    public struct Part {
        public var headers: [(name: String, value: String)] = []
        public var body = Data()
        public var parts: [Part] = []
        public var path = ""

        public func header(_ name: String) -> String? {
            headers.first { $0.name.lowercased() == name }?.value
        }

        public var type: (value: String, params: [String: String]) {
            let said = MailMime.parameters(header("content-type") ?? "text/plain")
            return (said.value.isEmpty ? "text/plain" : said.value.lowercased(), said.params)
        }
    }

    // MARK: - reading

    /// A message's head and body split where the first empty line is.
    static func split(_ data: Data) -> (head: Data, body: Data) {
        let bytes = [UInt8](data)
        var at = 0
        while at < bytes.count {
            if bytes[at] == 10 {
                // \n\n or \n\r\n
                if at + 1 < bytes.count, bytes[at + 1] == 10 { return (Data(bytes[0..<at]), Data(bytes[(at + 2)...])) }
                if at + 2 < bytes.count, bytes[at + 1] == 13, bytes[at + 2] == 10 { return (Data(bytes[0..<at]), Data(bytes[(at + 3)...])) }
            }
            at += 1
        }
        return (data, Data())
    }

    /// Headers unfolded, in their order, values with RFC 2047's words as
    /// they came (decoded where they are read).
    public static func headers(_ head: Data) -> [(name: String, value: String)] {
        // Headers are ASCII by the RFC; 8-bit ones in the wild are UTF-8 or Latin 1.
        let text = String(data: head, encoding: .utf8) ?? String(decoding: head, as: UTF8.self)
        var out: [(String, String)] = []
        // Swift keeps "\r\n" as one Character: lines are split on bytes' "\n" after "\r\n" is made "\n", a lone "\r" left off.
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            if let first = line.first, first == " " || first == "\t", !out.isEmpty {
                out[out.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                out.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                            String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
        }
        return out
    }

    /// A message, or a part of one, read: multiparts into their parts,
    /// a leaf's transfer encoding undone.
    public static func parse(_ data: Data, path: String = "") -> Part {
        let (head, body) = split(data)
        var part = Part(headers: headers(head), path: path)
        let type = part.type
        if type.value.hasPrefix("multipart/"), let boundary = type.params["boundary"], !boundary.isEmpty {
            for (n, chunk) in chunks(body, boundary: boundary).enumerated() {
                part.parts.append(parse(chunk, path: path.isEmpty ? "\(n)" : "\(path).\(n)"))
            }
        } else {
            let encoding = (part.header("content-transfer-encoding") ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            part.body = decoded(body, encoding: encoding)
        }
        return part
    }

    /// The pieces between a multipart's boundaries, their CRLF before each
    /// boundary left out.
    static func chunks(_ body: Data, boundary: String) -> [Data] {
        let bytes = [UInt8](body)
        let mark = [UInt8](("--" + boundary).utf8)
        var starts: [(at: Int, end: Int, last: Bool)] = []
        var at = 0
        var lineStart = true
        while at < bytes.count {
            if lineStart, at + mark.count <= bytes.count, Array(bytes[at..<(at + mark.count)]) == mark {
                let after = at + mark.count
                let last = after + 1 < bytes.count && bytes[after] == 45 && bytes[after + 1] == 45
                var end = after
                while end < bytes.count, bytes[end] != 10 { end += 1 }
                starts.append((at, min(end + 1, bytes.count), last))
                at = min(end + 1, bytes.count)
                lineStart = true
                if last { break }
                continue
            }
            lineStart = bytes[at] == 10
            at += 1
        }
        var out: [Data] = []
        for (n, start) in starts.enumerated() where !start.last {
            let from = start.end
            var to = n + 1 < starts.count ? starts[n + 1].at : bytes.count
            // The line break before the next boundary belongs to it.
            if to > from, bytes[to - 1] == 10 { to -= 1 }
            if to > from, bytes[to - 1] == 13 { to -= 1 }
            out.append(Data(bytes[from..<max(from, to)]))
        }
        return out
    }

    static func decoded(_ body: Data, encoding: String) -> Data {
        switch encoding {
        case "base64":
            return Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? body
        case "quoted-printable":
            return quotedPrintable(body)
        default:
            return body
        }
    }

    /// Quoted-printable's =XX and soft line breaks undone.
    static func quotedPrintable(_ body: Data) -> Data {
        let bytes = [UInt8](body)
        var out = Data()
        out.reserveCapacity(bytes.count)
        var at = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: return b - 48
            case 65...70: return b - 55
            case 97...102: return b - 87
            default: return nil
            }
        }
        while at < bytes.count {
            let b = bytes[at]
            if b == 61 {
                if at + 1 < bytes.count, bytes[at + 1] == 10 { at += 2; continue }
                if at + 2 < bytes.count, bytes[at + 1] == 13, bytes[at + 2] == 10 { at += 3; continue }
                if at + 2 < bytes.count, let high = hex(bytes[at + 1]), let low = hex(bytes[at + 2]) {
                    out.append(high << 4 | low)
                    at += 3
                    continue
                }
            }
            out.append(b)
            at += 1
        }
        return out
    }

    // MARK: - as Gmail's resource

    /// The words a part holds, in UTF-8, from its charset.
    static func text(_ part: Part) -> String {
        MailMime.decode(part.body, charset: part.type.params["charset"] ?? "utf-8")
    }

    /// A part as Gmail's API gives one: words carry their bytes (as UTF-8),
    /// files an id to fetch them by.
    static func resource(_ part: Part) -> [String: Any] {
        let type = part.type
        var out: [String: Any] = [
            "partId": part.path,
            "mimeType": type.value,
            "headers": part.headers.map { ["name": $0.name, "value": $0.value] },
        ]
        let disposition = MailMime.parameters(part.header("content-disposition") ?? "")
        let name = MailMime.filename("", disposition: disposition.params, type: type.params)
        out["filename"] = name
        if !part.parts.isEmpty || type.value.hasPrefix("multipart/") {
            out["parts"] = part.parts.map(resource)
            out["body"] = ["size": 0]
            return out
        }
        let attached = disposition.value.lowercased() == "attachment"
        let words = (type.value == "text/plain" || type.value == "text/html") && !attached && name.isEmpty
        let calendar = type.value == "text/calendar" || type.value == "application/ics"
        if words || calendar {
            out["body"] = ["size": part.body.count, "data": MailGmail.encode(text(part))] as [String: Any]
        } else {
            out["body"] = ["size": part.body.count, "attachmentId": "p:" + part.path] as [String: Any]
        }
        return out
    }

    /// The words a list shows of a message: its first plain words, or its
    /// HTML's, about two hundred letters.
    static func snippet(_ part: Part) -> String {
        func first(_ type: String, _ part: Part) -> Part? {
            if part.parts.isEmpty { return part.type.value == type ? part : nil }
            for child in part.parts { if let found = first(type, child) { return found } }
            return nil
        }
        let words: String
        if let plain = first("text/plain", part) {
            words = text(plain)
        } else if let html = first("text/html", part) {
            words = HTMLText.plain(text(html))
        } else {
            return ""
        }
        let flat = words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(flat.prefix(200))
    }

    /// A raw message as Gmail's message resource: `id` and `thread` the
    /// provider's, `labels` Yab's, `date` when the server got it.
    public static func resource(_ raw: Data, id: String, thread: String, labels: Set<String>, date: Date?) -> [String: Any] {
        let message = parse(raw)
        var payload = resource(message)
        // Gmail decodes the encoded words of a message's own headers.
        payload["headers"] = message.headers.map { ["name": $0.name, "value": MailMime.words($0.value)] }
        let sent = message.header("date").flatMap(MailRFC822.sentDate)
        let at = date ?? sent ?? Date()
        return ["id": id, "threadId": thread, "labelIds": Array(labels).sorted(),
                "snippet": snippet(message), "internalDate": String(Int64(at.timeIntervalSince1970 * 1000)),
                "sizeEstimate": raw.count, "payload": payload]
    }

    /// A raw message as the store keeps it.
    public static func message(_ raw: Data, id: String, thread: String, labels: Set<String>, date: Date?, full: Bool) -> MailMessage? {
        MailGmail.message(resource(raw, id: id, thread: thread, labels: labels, date: date), full: full)
    }

    /// A file's bytes by its id ("p:0.1"), from the message whole.
    public static func part(_ raw: Data, id: String) -> Data? {
        guard id.hasPrefix("p:") else { return nil }
        let path = String(id.dropFirst(2))
        func find(_ part: Part) -> Part? {
            if part.path == path { return part }
            for child in part.parts { if let found = find(child) { return found } }
            return nil
        }
        return find(parse(raw)).map(\.body)
    }

    // MARK: - headers

    private static let dates: [DateFormatter] = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz",
        "d MMM yyyy HH:mm:ss zzz",
    ].map { format in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    /// RFC 5322's date, with the comment some mailers add after it.
    public static func sentDate(_ text: String) -> Date? {
        var clean = text
        if let paren = clean.firstIndex(of: "(") { clean = String(clean[..<paren]) }
        clean = clean.trimmingCharacters(in: .whitespaces)
        for f in dates { if let d = f.date(from: clean) { return d } }
        return nil
    }

    /// Message-IDs in a header (References, In-Reply-To), in order, each
    /// with its brackets.
    public static func ids(_ header: String) -> [String] {
        var out: [String] = []
        var current: String?
        for char in header {
            if char == "<" { current = "<" } else if char == ">", var id = current {
                id.append(">")
                out.append(id)
                current = nil
            } else if current != nil, !char.isWhitespace {
                current?.append(char)
            }
        }
        return out
    }

    /// The addresses a message goes to: To, Cc and Bcc, bare.
    public static func recipients(_ raw: Data) -> [String] {
        let head = headers(split(raw).head)
        var out: [String] = []
        for (name, value) in head where ["to", "cc", "bcc"].contains(name.lowercased()) {
            out += MailPerson.list(MailMime.words(value)).map(\.address).filter { !$0.isEmpty }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }
    }

    /// A message without its Bcc header: what goes in SMTP's DATA, so
    /// those copied blind stay unseen.
    public static func withoutBcc(_ raw: Data) -> Data {
        let (head, body) = split(raw)
        let text = String(decoding: head, as: UTF8.self)
        let eol = text.contains("\r\n") || text.hasSuffix("\r") ? "\r\n" : "\n"
        var kept: [String] = []
        var skipping = false
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let bare = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
            if let first = bare.first, first == " " || first == "\t" {
                if !skipping { kept.append(bare) }
                continue
            }
            skipping = bare.lowercased().hasPrefix("bcc:")
            if !skipping { kept.append(bare) }
        }
        var out = Data((kept.joined(separator: eol) + eol + eol).utf8)
        out.append(body)
        return out
    }
}
