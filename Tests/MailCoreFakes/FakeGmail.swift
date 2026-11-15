import Foundation
import MailCore

// Gmail kept in memory, as the mail engine's tests and the app's mail
// tests ask it (MailSyncTests and most Mail*Tests).

/// Gmail as the engine sees it: a mailbox, its history, and whatever
/// failures a test asks for.
public final class FakeGmail: @unchecked Sendable {
    public struct Message {
        public var id: String
        public var thread: String
        public var from: String
        public var to = "me@example.com"
        public var subject: String
        public var body: String
        public var at: Date
        public var labels: Set<String>
        var rfc: String? = nil
        public var replyTo: String? = nil
        public var cc: String? = nil
        /// A sent one's, as its raw message had it (Gmail keeps it in Sent).
        public var bcc: String? = nil
        /// A list's List-Unsubscribe and List-Unsubscribe-Post.
        public var unsubscribe: String? = nil
        public var unsubscribePost: String? = nil
        /// Files it carries, and HTML of its own (to draw a picture by cid:).
        public var files: [File] = []
        public var html: String? = nil
        public init(id: String, thread: String, from: String, to: String = "me@example.com", subject: String, body: String, at: Date, labels: Set<String>, rfc: String? = nil, replyTo: String? = nil, cc: String? = nil, bcc: String? = nil, unsubscribe: String? = nil, unsubscribePost: String? = nil, files: [File] = [], html: String? = nil) {
            self.id = id
            self.thread = thread
            self.from = from
            self.to = to
            self.subject = subject
            self.body = body
            self.at = at
            self.labels = labels
            self.rfc = rfc
            self.replyTo = replyTo
            self.cc = cc
            self.bcc = bcc
            self.unsubscribe = unsubscribe
            self.unsubscribePost = unsubscribePost
            self.files = files
            self.html = html
        }
    }

    /// A file a message carries, as Gmail gives its part: `inline`, a
    /// picture the HTML draws, in multipart/related; else an attachment.
    public struct File {
        public var name: String
        public var mime: String
        public var data: Data
        public var contentID: String? = nil
        public var inline = false
        /// The part's Content-Disposition as written, and Gmail's own
        /// `filename`, when a test wants other than the name.
        var disposition: String? = nil
        public var filename: String? = nil
        /// Its bytes in the message itself, no attachment id.
        public var carried = false
        public init(name: String, mime: String, data: Data, contentID: String? = nil, inline: Bool = false, disposition: String? = nil, filename: String? = nil, carried: Bool = false) {
            self.name = name
            self.mime = mime
            self.data = data
            self.contentID = contentID
            self.inline = inline
            self.disposition = disposition
            self.filename = filename
            self.carried = carried
        }
    }

    public var messages: [String: Message] = [:]
    public var history = 100
    /// Records since each history id: (id, added, deleted, labels added, labels removed).
    public var records: [(id: Int, added: [String], deleted: [String], labeled: [(String, [String], Bool)])] = []
    /// History older than this is gone (404).
    public var oldest = 0
    /// Statuses the next calls answer with, one each, before the real answer.
    public var failures: [Int] = []
    /// Paths Gmail says slow down to (403 rateLimitExceeded), how many more
    /// times; "*" for any path.
    public var tooFast: [String: Int] = [:]
    public var calls: [String] = []
    public var pageSize = 2
    /// Sends taken and then answered with a failure, as a timeout looks.
    public var dropAnswers = 0
    public var labels: [String: String] = [:]
    /// Gmail's ids for files change: one more, and every id given before is refused.
    public var rotation = 0
    public var sent: [String] = []
    /// How each send came: "raw" (JSON), "media" or "multipart" (uploads).
    public var doors: [String] = []
    /// The ids each messages/batchModify was given, in order.
    public var batches: [[String]] = []
    /// The account's send-as addresses as settings/sendAs gives them: its own
    /// alone, with no name and no signature, unless a test says more; nil,
    /// a Gmail that refuses the call.
    public var sendAs: [[String: Any]]? = [["sendAsEmail": "me@example.com", "displayName": "", "replyToAddress": "", "signature": "",
                                     "isPrimary": true, "isDefault": true, "treatAsAlias": false]]

    public init() {}

    public static var current = FakeGmail()
    /// Fakes by the host their world's MailGmail asks (MailOpsTests), so a
    /// suite of their own runs beside this one; any other host asks `current`.
    private static var worlds: [String: FakeGmail] = [:]
    private static let worldsLock = NSLock()

    public static func serve(_ fake: FakeGmail, at host: String) {
        worldsLock.lock()
        defer { worldsLock.unlock() }
        worlds[host] = fake
    }

    public static func serving(_ request: URLRequest) -> FakeGmail {
        worldsLock.lock()
        defer { worldsLock.unlock() }
        return worlds[request.url?.host ?? ""] ?? current
    }

    public func add(_ message: Message, record: Bool = true) {
        messages[message.id] = message
        if record {
            history += 1
            records.append((history, [message.id], [], []))
        }
    }

    func threadIDs() -> [String] {
        var seen: [String] = []
        for m in messages.values.sorted(by: { $0.at > $1.at }) where !seen.contains(m.thread) { seen.append(m.thread) }
        return seen
    }

    public func json(_ m: Message, full: Bool) -> [String: Any] {
        var headers: [[String: String]] = [
            ["name": "From", "value": m.from], ["name": "To", "value": m.to], ["name": "Subject", "value": m.subject],
            ["name": "Message-ID", "value": m.rfc ?? "<\(m.id)@example.com>"],
        ]
        for (name, value) in [("Reply-To", m.replyTo), ("Cc", m.cc), ("List-Unsubscribe", m.unsubscribe), ("List-Unsubscribe-Post", m.unsubscribePost)] {
            if let value { headers.append(["name": name, "value": value]) }
        }
        var payload: [String: Any] = ["headers": headers]
        if full {
            let words: [String: Any] = ["mimeType": "multipart/alternative", "filename": "", "parts": [
                ["mimeType": "text/plain", "filename": "", "body": ["data": MailGmail.encode(m.body)]],
                ["mimeType": "text/html", "filename": "", "body": ["data": MailGmail.encode(m.html ?? "<p>\(m.body)</p>")]],
            ]]
            if m.files.isEmpty {
                payload["mimeType"] = "multipart/alternative"
                payload["parts"] = words["parts"]
            } else {
                // mixed: the words (with the pictures they draw, related), then the attachments.
                let inline = m.files.indices.filter { m.files[$0].inline }.map { filePart(m, $0) }
                let attached = m.files.indices.filter { !m.files[$0].inline }.map { filePart(m, $0) }
                let related: [String: Any] = inline.isEmpty ? words : ["mimeType": "multipart/related", "filename": "", "parts": [words] + inline]
                payload["mimeType"] = "multipart/mixed"
                payload["parts"] = [related] + attached
                FakeGmail.number(&payload, "")
            }
        }
        return ["id": m.id, "threadId": m.thread, "labelIds": Array(m.labels), "snippet": String(m.body.prefix(40)),
                "internalDate": String(Int(m.at.timeIntervalSince1970 * 1000)), "historyId": String(history), "payload": payload]
    }

    /// A file's part as Gmail gives it, and its id, which changes with `rotation`.
    func filePart(_ m: Message, _ n: Int) -> [String: Any] {
        let file = m.files[n]
        var headers: [[String: String]] = [
            ["name": "Content-Type", "value": "\(file.mime); name=\"\(file.name)\""],
            ["name": "Content-Disposition", "value": file.disposition ?? "\(file.inline ? "inline" : "attachment"); filename=\"\(file.name)\""],
        ]
        if let cid = file.contentID { headers.append(["name": "Content-ID", "value": cid]) }
        let body: [String: Any] = file.carried ? ["size": file.data.count, "data": FakeGmail.base64url(file.data)]
            : ["size": file.data.count, "attachmentId": attachmentID(m, n)]
        return ["mimeType": file.mime, "filename": file.filename ?? file.name, "headers": headers, "body": body]
    }

    public func attachmentID(_ m: Message, _ n: Int) -> String { "att\(rotation)_\(m.id)_\(n)" }

    /// Gmail's part ids, as it numbers them: "", then "0", "1", then "0.0", "0.1"…
    public static func number(_ part: inout [String: Any], _ path: String) {
        part["partId"] = path
        guard var parts = part["parts"] as? [[String: Any]] else { return }
        for n in parts.indices { number(&parts[n], path.isEmpty ? "\(n)" : "\(path).\(n)") }
        part["parts"] = parts
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Whether a message answers a search, as Gmail reads it: by the same
    /// reading of it as the store's (MailQuery), every operator, words too,
    /// a day midnight in UTC.
    public func searched(_ m: Message, _ q: String, now: Date = Date()) -> Bool {
        let asked = MailQuery.parse(q, calendar: FakeGmail.utc)
        guard !asked.isEmpty else { return true }
        var message = MailMessage(id: m.id, thread: m.thread, from: MailPerson.one(m.from) ?? MailPerson(name: "", address: ""),
                                  to: MailPerson.list(m.to), cc: MailPerson.list(m.cc ?? ""), subject: m.subject,
                                  snippet: String(m.body.prefix(40)), date: m.at, labels: m.labels, text: m.body)
        message.attached = !m.files.isEmpty
        return asked.matches(message, me: "me@example.com", labels: { name in self.labels.first { $0.value.lowercased() == name.lowercased() }?.key },
                             now: now, calendar: FakeGmail.utc)
    }

    public static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let lock = NSLock()

    public func answer(_ request: URLRequest) -> (Int, Any) {
        lock.lock()
        defer { lock.unlock() }
        let url = request.url!
        // Google's door for media: the same path under /upload.
        let upload = url.path.hasPrefix("/upload/")
        let path = (upload ? String(url.path.dropFirst(7)) : url.path).replacingOccurrences(of: "/gmail/v1/users/me/", with: "")
        let query = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                               uniquingKeysWith: { a, _ in a })
        calls.append(request.httpMethod! + " " + (upload ? "upload/" : "") + path)
        if !failures.isEmpty { return (failures.removeFirst(), ["error": "failing"]) }
        for key in [path, "*"] where tooFast[key, default: 0] > 0 {
            tooFast[key, default: 0] -= 1
            return (403, ["error": ["code": 403, "errors": [["reason": "rateLimitExceeded"]], "status": "PERMISSION_DENIED"]])
        }
        if path == "profile" { return (200, ["emailAddress": "me@example.com", "historyId": String(history)]) }
        if path == "settings/sendAs", request.httpMethod == "GET" {
            guard let sendAs else { return (403, ["error": ["code": 403, "errors": [["reason": "insufficientPermissions"]], "status": "PERMISSION_DENIED"]]) }
            return (200, ["sendAs": sendAs])
        }
        if path == "threads", let q = query["q"], q.hasPrefix("rfc822msgid:") {
            let id = String(q.dropFirst("rfc822msgid:".count))
            let found = messages.values.filter { ($0.rfc ?? "").contains(id) }.map(\.thread)
            return (200, ["threads": Array(Set(found)).map { ["id": $0] }])
        }
        if path == "labels" {
            if request.httpMethod == "POST" {
                let body = (try? JSONSerialization.jsonObject(with: request.bodyData ?? Data()) as? [String: Any]) ?? [:]
                let name = body["name"] as? String ?? ""
                // A name taken, any case: Gmail's 409.
                if labels.values.contains(where: { $0.lowercased() == name.lowercased() }) {
                    return (409, ["error": ["code": 409, "errors": [["reason": "duplicate"]], "status": "ALREADY_EXISTS"]])
                }
                var n = labels.count + 1
                while labels["Label_\(n)"] != nil { n += 1 }
                labels["Label_\(n)"] = name
                return (200, ["id": "Label_\(n)", "name": name, "type": "user"])
            }
            return (200, ["labels": labels.map { ["id": $0.key, "name": $0.value, "type": "user"] }])
        }
        if path.hasPrefix("labels/"), request.httpMethod == "GET" {
            // One label with its counts, as labels.get gives them.
            let id = String(path.dropFirst(7))
            if id.hasPrefix("Label_"), labels[id] == nil { return (404, ["error": "no label"]) }
            let carrying = messages.values.filter { $0.labels.contains(id) }
            let unread = carrying.filter { $0.labels.contains("UNREAD") }
            return (200, ["id": id, "name": labels[id] ?? id, "type": id.hasPrefix("Label_") ? "user" : "system",
                          "messagesTotal": carrying.count, "messagesUnread": unread.count,
                          "threadsTotal": Set(carrying.map(\.thread)).count, "threadsUnread": Set(unread.map(\.thread)).count])
        }
        if path == "messages/send", upload {
            // An upload: the message as it is (media), or its thread as JSON
            // and then the message (multipart/related), as Gmail takes them.
            let data = request.bodyData ?? Data()
            switch query["uploadType"] {
            case "media":
                guard request.value(forHTTPHeaderField: "Content-Type") == "message/rfc822" else { return (400, ["error": "not message/rfc822"]) }
                return took(String(decoding: data, as: UTF8.self), thread: "", door: "media")
            case "multipart":
                guard let type = request.value(forHTTPHeaderField: "Content-Type"), type.hasPrefix("multipart/related; boundary="),
                      let parts = FakeGmail.related(data, boundary: String(type.dropFirst("multipart/related; boundary=".count))),
                      parts.count == 2 else { return (400, ["error": "not multipart/related"]) }
                let meta = (try? JSONSerialization.jsonObject(with: parts[0].body) as? [String: Any]) ?? [:]
                return took(String(decoding: parts[1].body, as: UTF8.self), thread: meta["threadId"] as? String ?? "", door: "multipart")
            default:
                return (400, ["error": "uploadType"])
            }
        }
        if path == "messages/send" {
            let body = (try? JSONSerialization.jsonObject(with: request.bodyData ?? Data()) as? [String: Any]) ?? [:]
            return took(MailGmail.decode(body["raw"] as? String ?? "") ?? "", thread: body["threadId"] as? String ?? "", door: "raw")
        }
        if path == "messages" {
            let label = query["labelIds"]
            let all = messages.values.filter { (label == nil || $0.labels.contains(label!)) && searched($0, query["q"] ?? "") }
                .sorted { $0.at > $1.at }
            let size = min(pageSize, Int(query["maxResults"] ?? "") ?? pageSize)
            let start = Int(query["pageToken"] ?? "0") ?? 0
            let page = Array(all[min(start, all.count)..<min(all.count, start + size)])
            var out: [String: Any] = ["messages": page.map { ["id": $0.id, "threadId": $0.thread] }, "resultSizeEstimate": all.count]
            if start + size < all.count { out["nextPageToken"] = String(start + size) }
            return (200, out)
        }
        if path == "threads" {
            let all = threadIDs()
            let start = Int(query["pageToken"] ?? "0") ?? 0
            let page = Array(all[start..<min(all.count, start + pageSize)])
            var out: [String: Any] = ["threads": page.map { ["id": $0] }]
            if start + pageSize < all.count { out["nextPageToken"] = String(start + pageSize) }
            return (200, out)
        }
        if path == "history" {
            let start = Int(query["startHistoryId"] ?? "0") ?? 0
            if start < oldest { return (404, ["error": "gone"]) }
            let after = records.filter { $0.id > start }
            return (200, ["historyId": String(history), "history": after.map { r -> [String: Any] in
                var out: [String: Any] = ["id": String(r.id)]
                out["messagesAdded"] = r.added.compactMap { id in messages[id].map { ["message": ["id": id, "threadId": $0.thread]] } }
                out["messagesDeleted"] = r.deleted.map { ["message": ["id": $0]] }
                out["labelsAdded"] = r.labeled.filter { $0.2 }.map { ["message": ["id": $0.0], "labelIds": $0.1] }
                out["labelsRemoved"] = r.labeled.filter { !$0.2 }.map { ["message": ["id": $0.0], "labelIds": $0.1] }
                return out
            }])
        }
        if path == "messages/batchModify", request.httpMethod == "POST" {
            // Up to a thousand ids, labels on and off each; Gmail answers 204.
            let body = (try? JSONSerialization.jsonObject(with: request.bodyData ?? Data()) as? [String: Any]) ?? [:]
            let ids = body["ids"] as? [String] ?? []
            guard !ids.isEmpty, ids.count <= 1000 else { return (400, ["error": "ids: 1 to 1000"]) }
            guard ids.allSatisfy({ messages[$0] != nil }) else { return (400, ["error": "Invalid id value"]) }
            batches.append(ids)
            relabel(ids, add: body["addLabelIds"] as? [String] ?? [], remove: body["removeLabelIds"] as? [String] ?? [])
            return (204, [String: Any]())
        }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 4, parts[0] == "messages", parts[2] == "attachments", request.httpMethod == "GET" {
            guard let m = messages[parts[1]] else { return (404, ["error": "no message"]) }
            for n in m.files.indices where attachmentID(m, n) == parts[3] {
                return (200, ["size": m.files[n].data.count, "data": FakeGmail.base64url(m.files[n].data)])
            }
            // An id from before Gmail changed them.
            return (400, ["error": ["code": 400, "message": "Invalid attachment token", "status": "INVALID_ARGUMENT"]])
        }
        if parts.count == 3, parts[0] == "messages", parts[2] == "modify", request.httpMethod == "POST" {
            guard messages[parts[1]] != nil else { return (404, ["error": "no message"]) }
            let body = (try? JSONSerialization.jsonObject(with: request.bodyData ?? Data()) as? [String: Any]) ?? [:]
            relabel([parts[1]], add: body["addLabelIds"] as? [String] ?? [], remove: body["removeLabelIds"] as? [String] ?? [])
            return (200, ["id": parts[1]])
        }
        if parts.count == 2, parts[0] == "messages", request.httpMethod == "GET" {
            guard let m = messages[parts[1]] else { return (404, ["error": "no message"]) }
            return (200, json(m, full: query["format"] == "full"))
        }
        if parts.count == 2, parts[0] == "threads" {
            let full = query["format"] == "full"
            let list = messages.values.filter { $0.thread == parts[1] }.sorted { $0.at < $1.at }
            if list.isEmpty { return (404, ["error": "no thread"]) }
            return (200, ["id": parts[1], "messages": list.map { json($0, full: full) }])
        }
        if parts.count == 3, parts[0] == "threads" {
            let ids = messages.values.filter { $0.thread == parts[1] }.map(\.id)
            if ids.isEmpty { return (404, ["error": "no thread"]) }
            let body = (try? JSONSerialization.jsonObject(with: request.bodyData ?? Data()) as? [String: Any]) ?? [:]
            // Trash takes it out of the inbox; untrash only out of Trash, as Gmail's do.
            let add = parts[2] == "trash" ? ["TRASH"] : parts[2] == "untrash" ? [] : body["addLabelIds"] as? [String] ?? []
            let remove = parts[2] == "trash" ? ["INBOX"] : parts[2] == "untrash" ? ["TRASH"] : body["removeLabelIds"] as? [String] ?? []
            relabel(ids, add: add, remove: remove)
            return (200, ["id": parts[1]])
        }
        return (404, ["error": "unknown \(path)"])
    }

    /// A message sent, kept in Sent as Gmail keeps it: what it was handed
    /// whole, its headers read from it.
    private func took(_ raw: String, thread: String, door: String) -> (Int, Any) {
        let head = raw.components(separatedBy: "\r\n\r\n").first ?? ""
        let header = { (name: String) in head.components(separatedBy: "\r\n").first { $0.hasPrefix(name + ": ") }.map { String($0.dropFirst(name.count + 2)) } ?? "" }
        sent.append(raw)
        doors.append(door)
        let id = "s\(sent.count)"
        // Its words and files as its parts hold them, read back as any
        // message's are: Gmail's own filename left empty, so the reading half
        // reads each name from the part's headers as they were written.
        let parts = MIMEReading(raw)?.parts ?? []
        // Its words however they nest (multipart/alternative, P1.8): the
        // first plain part, and the first HTML one.
        func leaves(_ tree: MIMETree) -> [MIMETree] { tree.type.hasPrefix("multipart/") ? tree.parts.flatMap(leaves) : [tree] }
        let words = MIMETree(raw).map(leaves)?.filter { $0.head["content-disposition"] == nil } ?? []
        let plain = words.first { $0.type == "text/plain" }, html = words.first { $0.type == "text/html" }
        let files = parts.filter { $0.head["content-disposition"] != nil }.map { part in
            File(name: part.filename ?? "", mime: part.type, data: part.data, disposition: part.head["content-disposition"], filename: "")
        }
        messages[id] = Message(id: id, thread: thread.isEmpty ? id : thread, from: header("From"), to: header("To"),
                               subject: header("Subject"), body: plain?.text ?? "", at: Date(),
                               labels: ["SENT"], rfc: header("Message-ID"),
                               cc: header("Cc").isEmpty ? nil : header("Cc"), bcc: header("Bcc").isEmpty ? nil : header("Bcc"), files: files,
                               html: html?.text)
        history += 1
        records.append((history, [id], [], []))
        if dropAnswers > 0 { dropAnswers -= 1; return (503, ["error": "timed out"]) }
        // As Gmail answers: the message, its thread (a new one's own).
        return (200, ["id": id, "threadId": messages[id]?.thread ?? id, "labelIds": ["SENT"]])
    }

    /// The parts of a multipart body by its boundary: each one's head and
    /// its bytes as they are.
    static func related(_ data: Data, boundary: String) -> [(head: String, body: Data)]? {
        let marker = Data(("--" + boundary).utf8)
        var parts: [(String, Data)] = []
        var at = data.startIndex
        guard let first = data.range(of: marker, in: at..<data.endIndex) else { return nil }
        at = first.upperBound
        while let next = data.range(of: marker, in: at..<data.endIndex) {
            var chunk = data[at..<next.lowerBound]
            // Each part: CRLF, its head, a blank line, its bytes, CRLF before the next marker.
            if chunk.starts(with: Data("\r\n".utf8)) { chunk = chunk.dropFirst(2) }
            if chunk.count >= 2, chunk.suffix(2) == Data("\r\n".utf8) { chunk = chunk.dropLast(2) }
            guard let split = chunk.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            parts.append((String(decoding: chunk[chunk.startIndex..<split.lowerBound], as: UTF8.self), Data(chunk[split.upperBound...])))
            at = next.upperBound
            if data[at...].starts(with: Data("--".utf8)) { break }
        }
        return parts
    }

    /// Labels on and off messages, as one record of history.
    private func relabel(_ ids: [String], add: [String], remove: [String]) {
        history += 1
        var labeled: [(String, [String], Bool)] = []
        for id in ids {
            messages[id]?.labels.formUnion(add)
            messages[id]?.labels.subtract(remove)
            if !add.isEmpty { labeled.append((id, add, true)) }
            if !remove.isEmpty { labeled.append((id, remove, false)) }
        }
        records.append((history, [], [], labeled))
    }
}

public final class FakeGmailProtocol: URLProtocol {
    public override class func canInit(with request: URLRequest) -> Bool { true }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    public override func startLoading() {
        let (status, body) = FakeGmail.serving(request).answer(request)
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    public override func stopLoading() {}
}

extension URLRequest {
    /// A body as URLProtocol hands it over: a stream, not the data.
    public var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
