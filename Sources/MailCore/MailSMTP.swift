import Foundation

// Mail out by SMTP submission (RFC 6409, docs/mail-providers.md, M3): TLS
// from the first byte on 465 (RFC 8314), or STARTTLS on 587; EHLO, AUTH
// PLAIN or LOGIN, the envelope from the message's own To, Cc and Bcc, the
// message itself without its Bcc, dot-stuffed (RFC 5321, 4.5.2).

public struct MailSMTP: Sendable {
    public var host: String
    public var port: Int
    public var security: MailSecurity
    public var user: String
    public var password: String
    /// How this Mac names itself in EHLO.
    public var hello = "yab.local"
    /// AUTH LOGIN first where offered (`.login`, iCloud's, #441), else PLAIN.
    public var auth: MailPasswordWay?

    public init(host: String, port: Int, security: MailSecurity, user: String, password: String) {
        self.host = host
        self.port = port
        self.security = security
        self.user = user
        self.password = password
    }

    /// What the server said at each step, for the probe.
    public struct Said: Sendable {
        public var greeting = ""
        public var extensions: Set<String> = []
        public var auth = ""
        public var size: Int?
    }

    /// A reply: its code and its lines' words.
    struct Reply {
        var code: Int
        var lines: [String]
        var text: String { lines.joined(separator: " ") }
    }

    static func reply(_ socket: MailSocket) async throws -> Reply {
        var lines: [String] = []
        while true {
            let line = String(decoding: try await socket.line(), as: UTF8.self)
            guard line.count >= 3, let code = Int(line.prefix(3)) else { throw MailServerTrouble.unreadable(line) }
            lines.append(line.count > 4 ? String(line.dropFirst(4)) : "")
            if line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] == " " { return Reply(code: code, lines: lines) }
        }
    }

    static func say(_ socket: MailSocket, _ line: String) async throws -> Reply {
        try await socket.write(line + "\r\n")
        return try await reply(socket)
    }

    /// Signed in and ready for a message; the socket and what the server
    /// said. `authenticate` false stops before the password (the probe's
    /// first look).
    func open(authenticate: Bool = true) async throws -> (MailSocket, Said) {
        let socket = try MailSocket(host: host, port: port, security: security)
        var said = Said()
        do {
            let greeting = try await Self.reply(socket)
            said.greeting = greeting.text
            guard greeting.code == 220 else { throw MailServerTrouble.refused(greeting.text) }
            var ehlo = try await Self.say(socket, "EHLO " + hello)
            guard ehlo.code == 250 else { throw MailServerTrouble.refused(ehlo.text) }
            if security == .starttls, !socket.standIn {
                guard Self.extensions(ehlo).contains("STARTTLS") else { throw MailServerTrouble.capabilityMissing("begin TLS (STARTTLS)") }
                let go = try await Self.say(socket, "STARTTLS")
                guard go.code == 220 else { throw MailServerTrouble.tlsFailed(go.text) }
                await socket.secure()
                ehlo = try await Self.say(socket, "EHLO " + hello)
                guard ehlo.code == 250 else { throw MailServerTrouble.refused(ehlo.text) }
            }
            said.extensions = Self.extensions(ehlo)
            if let size = ehlo.lines.first(where: { $0.uppercased().hasPrefix("SIZE ") }) { said.size = Int(size.dropFirst(5).trimmingCharacters(in: .whitespaces)) }
            guard authenticate else { return (socket, said) }
            let auth = ehlo.lines.first { $0.uppercased().hasPrefix("AUTH") }?.uppercased() ?? ""
            let reply: Reply
            let login = auth.contains("LOGIN") && (self.auth == .login || !auth.contains("PLAIN"))
            if !login, auth.contains("PLAIN") || auth.isEmpty {
                let plain = Data(("\u{0}" + user + "\u{0}" + password).utf8).base64EncodedString()
                reply = try await Self.say(socket, "AUTH PLAIN " + plain)
            } else if login {
                var step = try await Self.say(socket, "AUTH LOGIN")
                if step.code == 334 { step = try await Self.say(socket, Data(user.utf8).base64EncodedString()) }
                if step.code == 334 { step = try await Self.say(socket, Data(password.utf8).base64EncodedString()) }
                reply = step
            } else {
                throw MailServerTrouble.capabilityMissing("sign in with a password (\(auth))")
            }
            said.auth = reply.text
            guard reply.code == 235 else { throw MailServerTrouble.login(reply.text) }
            return (socket, said)
        } catch {
            await socket.close()
            throw error
        }
    }

    static func extensions(_ ehlo: Reply) -> Set<String> {
        Set(ehlo.lines.dropFirst().map { $0.split(separator: " ").first.map { String($0).uppercased() } ?? "" })
    }

    /// The probe's check: the server reached and the password taken, nothing sent.
    public func check() async throws -> Said {
        let (socket, said) = try await open()
        _ = try? await Self.say(socket, "QUIT")
        await socket.close()
        return said
    }

    /// A whole message out from `from` to everyone it names.
    public func send(_ raw: Data, from: String) async throws {
        let recipients = MailRFC822.recipients(raw)
        guard !recipients.isEmpty else { throw MailServerTrouble.refused("No one to send it to") }
        let (socket, said) = try await open()
        defer { Task { await socket.close() } }
        let body = MailRFC822.withoutBcc(raw)
        if let size = said.size, size > 0, body.count > size { throw MailServerTrouble.refused("The message is larger than the server takes") }
        let sizeParam = said.extensions.contains("SIZE") ? " SIZE=\(body.count)" : ""
        let mail = try await Self.say(socket, "MAIL FROM:<\(from)>" + sizeParam)
        guard mail.code == 250 else { throw MailServerTrouble.refused(mail.text) }
        for to in recipients {
            let rcpt = try await Self.say(socket, "RCPT TO:<\(to)>")
            guard rcpt.code == 250 || rcpt.code == 251 else { throw MailServerTrouble.refused(rcpt.text) }
        }
        let data = try await Self.say(socket, "DATA")
        guard data.code == 354 else { throw MailServerTrouble.refused(data.text) }
        try await socket.write(Self.stuffed(body))
        let done = try await Self.reply(socket)
        guard done.code == 250 else { throw MailServerTrouble.refused(done.text) }
        _ = try? await Self.say(socket, "QUIT")
    }

    /// The message as DATA carries it: CRLF line ends, a dot doubled at a
    /// line's start, the lone dot that ends it.
    public static func stuffed(_ raw: Data) -> Data {
        var text = String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasSuffix("\n") { text.removeLast() }
        var out = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            out += (line.hasPrefix(".") ? "." : "") + line + "\r\n"
        }
        return Data((out + ".\r\n").utf8)
    }
}
