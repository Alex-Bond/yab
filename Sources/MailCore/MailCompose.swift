import Foundation

// Writing mail (docs/mail.md, Reply): a reply's addresses, subject and
// headers from the mail it answers, a forward's from the mail it passes on,
// that mail under the words, and the message itself as Gmail takes it, RFC
// 5322 in base64url: plain text, or, when the words carry marks (MailRich)
// or the signature does, the plain text and the HTML together. A reply or a
// forward keeps In-Reply-To and References, so it lands in the thread for
// everyone, not only in Gmail.

public enum MailCompose {
    /// A reply to a thread's last message (the arrows' mail, given the
    /// messages up to it): to whoever wrote it, or where its Reply-To says,
    /// or, when it was yours, to whoever you wrote to; `all`, to everyone
    /// on it but you. The mail it answers goes under the words, quoted.
    public static func reply(to messages: [MailMessage], me: String, aliases: [String] = [], all: Bool = false,
                      zone: TimeZone = .current) -> MailDraft? {
        guard let last = messages.last else { return nil }
        let people = people(answering: last, me: [me] + aliases, all: all)
        let subject = messages.first?.subject ?? last.subject
        return MailDraft(thread: last.thread, to: people.to, cc: people.cc, subject: re(subject), inReplyTo: last.rfcID,
                         references: references(last), quote: quote(last, zone: zone))
    }

    /// A reply to everyone on the thread's last message (↩), as `reply`
    /// with `all`.
    static func replyAll(to messages: [MailMessage], me: String, aliases: [String] = [], zone: TimeZone = .current) -> MailDraft? {
        reply(to: messages, me: me, aliases: aliases, all: true, zone: zone)
    }

    /// Who a reply to a message goes to: its sender, or its Reply-To, which
    /// wins; with `all`, everyone it went to as well, its Cc kept as Cc.
    /// Yours (from an address in `me`): whoever you wrote to. You are never
    /// on it under any of your addresses, nobody is on it twice, and an
    /// address is the same in any case. Nobody left: its Cc, else its sender.
    public static func people(answering message: MailMessage, me: [String], all: Bool) -> (to: [MailPerson], cc: [MailPerson]) {
        let mine = Set(me.map { $0.lowercased() }.filter { !$0.isEmpty })
        var to: [MailPerson]
        if mine.contains(message.from.address.lowercased()) {
            to = message.to
        } else {
            let sender = message.replyTo.flatMap { $0.isEmpty ? nil : $0 } ?? [message.from]
            to = all ? sender + message.to : sender
        }
        var seen = mine
        func once(_ people: [MailPerson]) -> [MailPerson] { people.filter { seen.insert($0.address.lowercased()).inserted } }
        to = once(to)
        let cc = all ? once(message.cc) : []
        if to.isEmpty { return cc.isEmpty ? ([message.from], []) : (cc, []) }
        return (to, cc)
    }

    /// A forward of a thread's last message (the arrows' mail, given the
    /// messages up to it): to nobody yet, "Fwd: " once, the mail under the
    /// words as Gmail forwards it, in its thread with a reply's
    /// references, as Gmail sends a forward, and its files with it, as
    /// Gmail's Forward takes them (MailAttach.originals). `forwarded` says
    /// which mail it is.
    public static func forward(_ messages: [MailMessage], zone: TimeZone = .current) -> MailDraft? {
        guard let last = messages.last else { return nil }
        return MailDraft(thread: last.thread, subject: fwd(last.subject), inReplyTo: last.rfcID, references: references(last),
                         quote: forwarded(last, zone: zone), forwarded: last.id, files: MailAttach.originals(of: last))
    }

    /// What a reply or a forward carries of its thread: the message's own
    /// references, then the message.
    public static func references(_ message: MailMessage) -> String {
        [message.references, message.rfcID].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Re: once, however many times it was answered.
    public static func re(_ subject: String) -> String {
        let bare = subject.trimmingCharacters(in: .whitespaces)
        return bare.lowercased().hasPrefix("re:") ? bare : "Re: " + bare
    }

    /// Fwd: once, however many times it was passed on ("Fw:" too).
    static func fwd(_ subject: String) -> String {
        let bare = subject.trimmingCharacters(in: .whitespaces)
        let lower = bare.lowercased()
        return lower.hasPrefix("fwd:") || lower.hasPrefix("fw:") ? bare : "Fwd: " + bare
    }

    // MARK: - the mail before

    /// The mail a reply answers, as it goes under the words: who wrote it
    /// and when ("On Tue, Sep 29, 2026 at 10:00 AM, Anna Lindqvist
    /// <anna@fold.studio> wrote:"), then its lines, each marked.
    public static func quote(_ message: MailMessage, zone: TimeZone = .current) -> String {
        "On \(when(message.date, zone: zone)), \(said(message.from)) wrote:\n" + quoted(words(of: message))
    }

    /// Lines marked as quoted: "> " before each; a line quoted already one
    /// level deeper (">> "); an empty one a bare ">". A long line stays
    /// one line: the mail that shows it wraps it.
    public static func quoted(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            line.isEmpty ? ">" : line.hasPrefix(">") ? ">" + line : "> " + line
        }.joined(separator: "\n")
    }

    /// The line Gmail begins a forwarded mail with.
    public static let forwardLine = "---------- Forwarded message ---------"

    /// A forwarded mail as Gmail writes it under the words: the line that
    /// says so, its From, Date, Subject, To and Cc, then its words as they
    /// are.
    public static func forwarded(_ message: MailMessage, zone: TimeZone = .current) -> String {
        var head = [forwardLine, "From: " + said(message.from), "Date: " + when(message.date, zone: zone), "Subject: " + message.subject]
        if !message.to.isEmpty { head.append("To: " + message.to.map(said).joined(separator: ", ")) }
        if !message.cc.isEmpty { head.append("Cc: " + message.cc.map(said).joined(separator: ", ")) }
        return head.joined(separator: "\n") + "\n\n" + words(of: message)
    }

    /// Words chosen in the thread as a reply's start (Quick Quote): exactly
    /// those, each line marked, and a line under them to write on.
    public static func quickQuote(_ chosen: String) -> String {
        let words = chosen.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? "" : quoted(words) + "\n\n"
    }

    /// A mail's words as a quote takes them: its text, an HTML mail's own
    /// quotes marked as they nest; Unix's line ends, nothing blank after.
    public static func words(of message: MailMessage) -> String {
        var text = message.text ?? message.snippet
        // HTML alone: its words from the HTML again, its blockquotes marked.
        if let html = message.html, message.text == nil || message.text == HTMLText.plain(html) { text = plain(html) }
        return trailing(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
    }

    /// An HTML mail's words, what it quotes (its blockquotes) marked "> "
    /// as deep as they nest.
    public static func plain(_ html: String) -> String {
        let open = "\u{1}", close = "\u{2}"
        let marked = html
            .replacingOccurrences(of: "<blockquote\\b[^>]*>", with: "<br>\(open)<br>", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</blockquote\\s*>", with: "<br>\(close)<br>", options: [.regularExpression, .caseInsensitive])
        let lines = HTMLText.plain(marked).components(separatedBy: "\n")
        let edge = { (at: Int) in lines.indices.contains(at) && (lines[at] == open || lines[at] == close) }
        var depth = 0
        var out: [String] = []
        for (at, line) in lines.enumerated() {
            if line == open { depth += 1; continue }
            if line == close { depth = max(0, depth - 1); continue }
            let bare = line.replacingOccurrences(of: open, with: "").replacingOccurrences(of: close, with: "")
            // A blank line a quote's edge left behind is no line of the mail's.
            if bare.isEmpty, edge(at - 1) || edge(at + 1) { continue }
            out.append(depth == 0 ? bare : String(repeating: ">", count: depth) + (bare.isEmpty ? "" : " " + bare))
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A person as a quote or a forward names them: "Anna Lindqvist
    /// <anna@fold.studio>", or the address alone.
    public static func said(_ person: MailPerson) -> String {
        person.name.isEmpty ? person.address : "\(person.name) <\(person.address)>"
    }

    /// When a mail came, as Gmail says it over a quote: "Tue, Sep 29, 2026
    /// at 10:00 AM", in the Mac's time zone.
    public static func when(_ date: Date, zone: TimeZone = .current) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = zone
        format.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a"
        return format.string(from: date)
    }

    /// Text without the spaces and blank lines at its end.
    public static func trailing(_ text: String) -> String {
        var out = Substring(text)
        while let last = out.last, last.isWhitespace { out.removeLast() }
        return String(out)
    }

    // MARK: - the message

    /// A Message-ID of yab's own, so a send can be found in Sent again.
    public static func messageID(from me: String) -> String {
        let domain = me.split(separator: "@").last.map(String.init) ?? "yab.local"
        return "<yab-\(UUID().uuidString.lowercased())@\(domain)>"
    }

    /// The words as they go: what was written, the signature after "-- "
    /// (`signature`, its words), then the mail it answers or forwards, a
    /// blank line between each.
    public static func text(_ draft: MailDraft, signature: String = "") -> String {
        let sign = trailing(signature).isEmpty ? "" : "-- \n" + trailing(signature)
        guard !draft.quote.isEmpty || !sign.isEmpty else { return draft.body }
        return [trailing(draft.body), sign, draft.quote].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The words as the HTML part carries them: their own HTML (MailRich),
    /// or the plain words made HTML; the signature under them after "-- ";
    /// the mail answered or forwarded under that as Gmail quotes it, so
    /// Gmail folds it as its own; `tail` last of all.
    public static func html(_ draft: MailDraft, signature: MailSignature? = nil, tail: String = "") -> String {
        let words = draft.html.isEmpty ? MailRich.html(MailRich.trimmed(MailRich.plain(draft.body))) : draft.html
        var out = "<div dir=\"auto\">" + words + "</div>"
        if let signature { out += "<div><br></div><div class=\"gmail_signature\">-- <br>" + signature.html + "</div>" }
        if !draft.quote.isEmpty { out += "<div><br></div>" + quoteHTML(draft.quote, forward: !draft.forwarded.isEmpty) }
        return out + tail
    }

    /// A reply's quote as Gmail styles it: a gray bar on its left. The one
    /// style the HTML part carries, Gmail's own, so the quote reads there as
    /// Gmail's replies do.
    static let quoteStyle = "margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex"

    /// The mail a reply answers, or a forward passes on, as Gmail's HTML has
    /// it: who wrote it ("On …, Anna wrote:"), or the forwarded head, apart,
    /// then its words, the lines they quote quoted again as they nest.
    static func quoteHTML(_ quote: String, forward: Bool) -> String {
        let lines = quote.components(separatedBy: "\n")
        let open = "<div class=\"gmail_quote\"><div dir=\"auto\" class=\"gmail_attr\">"
        if forward {
            let blank = lines.firstIndex(of: "") ?? lines.count
            let head = lines[..<blank].map(MailRich.escaped).joined(separator: "<br>")
            return open + head + "<br></div><br>" + MailRich.html(quoted(Array(lines.dropFirst(blank + 1)), less: 0)) + "</div>"
        }
        return open + MailRich.escaped(lines.first ?? "") + "<br></div><blockquote class=\"gmail_quote\" style=\"" + quoteStyle + "\">"
            + MailRich.html(quoted(Array(lines.dropFirst()), less: 1)) + "</blockquote></div>"
    }

    /// Lines marked as quoted ("> ", ">> ") as lines in quotes, `less`
    /// levels fewer: the outermost is the quote's own.
    public static func quoted(_ lines: [String], less: Int) -> MailRich.Doc {
        lines.map { line in
            var depth = 0
            var rest = Substring(line)
            while rest.first == ">" {
                depth += 1
                rest = rest.dropFirst()
                if rest.first == " " { rest = rest.dropFirst() }
            }
            return MailRich.Line(String(rest), Array(repeating: .quote, count: max(0, depth - less)))
        }
    }

    /// The signature a draft goes with: its address's, when the draft is
    /// signed and its words don't hold it already (a reply written in your
    /// voice may); nil, none.
    public static func signing(_ draft: MailDraft, _ signature: MailSignature?) -> MailSignature? {
        guard draft.signed, let signature, !signature.isEmpty else { return nil }
        let squeezed = { (text: String) in text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
        return squeezed(draft.body).contains(squeezed(signature.text)) ? nil : signature
    }

    /// What a message goes with besides its words: the signature under
    /// them, the Reply-To its address carries, and for what comes later, an
    /// HTML part even for words with no mark (`twin`) and HTML at the very
    /// end of the HTML part (`tail`, P1.11's read status, a 1×1 picture,
    /// which brings the HTML part with it). An answer to an invitation
    /// carries its iCalendar REPLY (`calendar`, MailInvites.answer).
    public struct Extras: Equatable {
        public var signature: MailSignature?
        public var replyTo = ""
        public var twin = false
        public var tail = ""
        public var calendar = ""

        public init(signature: MailSignature? = nil, replyTo: String = "", twin: Bool = false, tail: String = "", calendar: String = "") {
            self.signature = signature
            self.replyTo = replyTo
            self.twin = twin
            self.tail = tail
            self.calendar = calendar
        }
    }

    /// Who a draft goes from, and what with, as the store has the account:
    /// its address's name (MailSendAs), Reply-To and signature, and the
    /// iCalendar REPLY of an answer to an invitation (MailInvites.answer).
    public static func going(_ draft: MailDraft, store: MailStore) -> (from: MailPerson, extras: Extras) {
        let all = store.sendAs()
        var from = MailSendAs.person(draft.from, all, me: store.value("me") ?? "")
        if from.name.isEmpty { from.name = store.value("name") ?? "" }
        var extras = Extras()
        extras.replyTo = all.first { $0.address == from.address }?.replyTo ?? ""
        if draft.signed {
            let html = store.signature(for: from.address)
            if !html.isEmpty { extras.signature = MailSignature(html: html) }
        }
        extras.calendar = store.rsvp(draft: draft.id)?.ics ?? ""
        return (from, extras)
    }

    /// A file as a message carries it: its name, its kind and its bytes.
    public struct Attached: Equatable {
        public var name: String
        public var mime: String
        public var data: Data
    }

    /// The message as it goes out: headers, then the words in base64. Bcc
    /// is among them: Gmail sends to it and takes it off what To and Cc
    /// get. From is the address it goes from (an alias's, MailSendAs). With
    /// files (MailAttach.parts), multipart/mixed: the words first, then each
    /// file as an attachment.
    public static func raw(_ draft: MailDraft, from me: MailPerson, date: Date = Date(), files: [Attached] = [], extras: Extras = Extras()) -> String {
        var lines = [
            "From: " + header(me),
            "To: " + draft.to.map(header).joined(separator: ", "),
        ]
        if !draft.cc.isEmpty { lines.append("Cc: " + draft.cc.map(header).joined(separator: ", ")) }
        if !draft.bcc.isEmpty { lines.append("Bcc: " + draft.bcc.map(header).joined(separator: ", ")) }
        if !extras.replyTo.isEmpty { lines.append("Reply-To: " + line(extras.replyTo)) }
        lines.append("Subject: " + encoded(line(draft.subject)))
        lines.append("Date: " + rfcDate(date))
        if !draft.messageID.isEmpty { lines.append("Message-ID: " + line(draft.messageID)) }
        if !draft.inReplyTo.isEmpty { lines.append("In-Reply-To: " + line(draft.inReplyTo)) }
        if !draft.references.isEmpty { lines.append("References: " + line(draft.references)) }
        lines.append("MIME-Version: 1.0")
        let head = lines.joined(separator: "\r\n") + "\r\n"
        guard !files.isEmpty else { return head + wordsPart(draft, extras) }
        let boundary = "yab-" + UUID().uuidString.lowercased()
        var out = head + "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
        out += "--\(boundary)\r\n" + wordsPart(draft, extras)
        for file in files { out += "--\(boundary)\r\n" + filePart(file) }
        return out + "--\(boundary)--\r\n"
    }

    /// The words as a part. Plain words (no mark, no marked signature) are
    /// plain text alone, UTF-8, in base64 76 to a line; marked ones go as
    /// multipart/alternative, the plain text and then the HTML (`html`), a
    /// reader showing the last it can. `extras.twin` or a `tail` brings the
    /// HTML even for plain words. An answer to an invitation
    /// (`extras.calendar`) is the last alternative, the text/calendar
    /// part iMIP reads (RFC 6047), with the method its object says.
    static func wordsPart(_ draft: MailDraft, _ extras: Extras = Extras()) -> String {
        let signature = signing(draft, extras.signature)
        let words = text(draft, signature: signature?.text ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        let plain = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n" + base64(Data(words.utf8)) + "\r\n"
        var parts = [plain]
        if !draft.html.isEmpty || signature?.marked == true || extras.twin || !extras.tail.isEmpty {
            let html = html(draft, signature: signature, tail: extras.tail)
            parts.append("Content-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n" + base64(Data(html.utf8)) + "\r\n")
        }
        if !extras.calendar.isEmpty { parts.append(calendarPart(extras.calendar)) }
        guard parts.count > 1 else { return plain }
        let boundary = "yab-alt-" + UUID().uuidString.lowercased()
        return "Content-Type: multipart/alternative; boundary=\"\(boundary)\"\r\n\r\n"
            + parts.map { "--\(boundary)\r\n" + $0 }.joined() + "--\(boundary)--\r\n"
    }

    /// An iCalendar object as a part: `text/calendar` with the method
    /// the object says (`method=REPLY`), as iMIP has it.
    static func calendarPart(_ calendar: String) -> String {
        let method = MailICS.lines(calendar).first { $0.name == "METHOD" }?.value.uppercased() ?? "REPLY"
        let ics = calendar.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        return "Content-Type: text/calendar; charset=utf-8; method=\(method)\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            + base64(Data(ics.utf8)) + "\r\n"
    }

    /// A file as a part: its kind and its name, an attachment, its bytes
    /// in base64.
    static func filePart(_ file: Attached) -> String {
        "Content-Type: " + file.mime + parameter("name", file.name) + "\r\n"
            + "Content-Disposition: attachment" + parameter("filename", file.name) + "\r\n"
            + "Content-Transfer-Encoding: base64\r\n\r\n" + base64(file.data) + "\r\n"
    }

    /// Bytes as a message carries them: base64, 76 to a line, CRLF between.
    public static func base64(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    /// A header's parameter (a file's name) on a line of its own: quoted
    /// when it is plain ASCII, else as RFC 2231 writes it, UTF-8 and
    /// percent-encoded (filename*=UTF-8''%D0%9E…), in pieces of 50 when
    /// long (filename*0*=…; filename*1*=…), so no line passes 78.
    static func parameter(_ name: String, _ value: String) -> String {
        let printable = value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
        if printable, value.count + name.count < 70 {
            return ";\r\n " + name + "=\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let plain = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~".utf8)
        let escaped = value.utf8.map { plain.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }
        // Pieces of at most 50, never cutting a %XX in two.
        var pieces: [String] = [], piece = ""
        for one in escaped {
            if piece.count + one.count > 50 { pieces.append(piece); piece = "" }
            piece += one
        }
        pieces.append(piece)
        if pieces.count == 1 { return ";\r\n " + name + "*=UTF-8''" + pieces[0] }
        return pieces.enumerated().map { n, piece in ";\r\n " + name + "*\(n)*=" + (n == 0 ? "UTF-8''" : "") + piece }.joined()
    }

    // MARK: - the call that carries it

    /// The most Google takes in a call that isn't an upload, 5 MB: a
    /// message whose call would carry more goes as an upload.
    static let callMost = 5 << 20

    /// Whether a message of this many bytes goes as an upload: as JSON, a
    /// call carries it in base64url, a third bigger, and a kilobyte around.
    static func uploads(_ bytes: Int) -> Bool { 4 * ((bytes + 2) / 3) + 1024 > callMost }

    /// A message and its thread as one upload (uploadType=multipart): the
    /// thread as JSON, then the message as it is.
    static func related(_ message: Data, thread: String) -> (data: Data, type: String) {
        let boundary = "yab-" + UUID().uuidString.lowercased()
        let meta = (try? JSONSerialization.data(withJSONObject: ["threadId": thread])) ?? Data("{}".utf8)
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body.append(meta)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8))
        body.append(message)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return (body, "multipart/related; boundary=\(boundary)")
    }

    /// A name that isn't plain ASCII, as RFC 2047 writes it.
    public static func encoded(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { !$0.isASCII }) else { return text }
        return "=?UTF-8?B?" + Data(text.utf8).base64EncodedString() + "?="
    }

    public static func header(_ person: MailPerson) -> String {
        // An address has no space in it: one that brought a line of its own
        // fails at Gmail rather than reaching whoever that line named.
        let address = line(person.address).replacingOccurrences(of: " ", with: "")
        let said = line(person.name)
        guard !said.isEmpty else { return address }
        let name = said.unicodeScalars.contains(where: { !$0.isASCII })
            ? encoded(said) : "\"" + said.replacingOccurrences(of: "\"", with: "") + "\""
        return "\(name) <\(address)>"
    }

    /// A header's words kept on its line. A CR or an LF in a subject, a name
    /// or an address (a mail's own words as Gmail decodes them, a list's
    /// mailto: subject, an agent's draft) would end the line and begin a
    /// header of its own, a Bcc nobody sees: every control character is a
    /// space instead.
    public static func line(_ text: String) -> String {
        let control = { (scalar: Unicode.Scalar) in scalar.value < 0x20 || scalar.value == 0x7F }
        guard text.unicodeScalars.contains(where: control) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.map { control($0) ? " " : $0 }))
    }

    static func rfcDate(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return format.string(from: date)
    }
}

extension MailGmail {
    /// Sends a message, in its thread when it is a reply or a forward; the
    /// message and thread ids as Gmail named them. One too big for a
    /// call of its own (MailCompose.uploads) goes as an upload, the same
    /// send by another door at the same price: the message alone
    /// (uploadType=media), or with its thread beside it as JSON
    /// (uploadType=multipart), media alone having no room for one.
    @discardableResult
    public func send(raw: String, thread: String) async throws -> (message: String?, thread: String) {
        let message = Data(raw.utf8)
        if MailCompose.uploads(message.count) {
            let media = (data: message, type: "message/rfc822")
            let how = thread.isEmpty ? "media" : "multipart"
            let upload = thread.isEmpty ? media : MailCompose.related(message, thread: thread)
            let got = try await call("upload/messages/send", [URLQueryItem(name: "uploadType", value: how)], method: "POST", upload: upload, again: false)
            return (got["id"] as? String, got["threadId"] as? String ?? thread)
        }
        var body: [String: Any] = ["raw": MailGmail.encode(raw)]
        if !thread.isEmpty { body["threadId"] = thread }
        let got = try await call("messages/send", method: "POST", body: body, again: false)
        return (got["id"] as? String, got["threadId"] as? String ?? thread)
    }

    /// Whether a message with this Message-ID is already in the mailbox: a
    /// send that timed out may have gone.
    public func has(messageID: String) async throws -> Bool {
        try await sentThread(messageID: messageID) != nil
    }

    /// The thread a message with this Message-ID is in, if it is in the
    /// mailbox.
    public func sentThread(messageID: String) async throws -> String? {
        let bare = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        return try await threads(query: "rfc822msgid:\(bare)", max: 1).ids.first
    }
}
