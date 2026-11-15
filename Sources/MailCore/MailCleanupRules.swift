import Foundation

// Clearing mail out, the rules without a screen (docs/mail.md, Cleanup):
// what List-Unsubscribe offers, who is blocked, what Get Me To Zero
// marks done, and the Bulk Actions log's entries. The acts are
// MailCleanup.swift's, in the app.

/// Leaving a list (RFC 2369, RFC 8058): the ways List-Unsubscribe gives,
/// and the one ⌘U takes.
public enum MailUnsubscribe {
    /// How ⌘U leaves a list: one POST that does it at once (RFC 8058), a
    /// mail to the list's address, or its page, opened for you to finish.
    public enum Way: Equatable {
        case oneClick(URL)
        case mail(Mailto)
        case page(URL)

        /// As the store keeps how a list was left.
        public var name: String {
            switch self {
            case .oneClick: return "one-click"
            case .mail: return "mail"
            case .page: return "page"
            }
        }

        /// It leaves you on the list's page, to finish there.
        public var isPage: Bool { if case .page = self { true } else { false } }
    }

    /// A mailto: address as a mail to send: who to, its subject and words.
    public struct Mailto: Equatable {
        public var to: [String]
        public var subject: String
        public var body: String
    }

    /// The addresses List-Unsubscribe gives, in its order: each between
    /// angle brackets, commas between, spaces and folds inside one ignored
    /// (RFC 2369); one written without brackets, split at its commas. Only
    /// mailto:, https: and http: count.
    public static func addresses(_ header: String) -> [URL] {
        var parts: [String] = []
        if header.contains("<") {
            var rest = header[...]
            while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
                parts.append(String(rest[rest.index(after: open)..<close]))
                rest = rest[rest.index(after: close)...]
            }
        } else {
            parts = header.split(separator: ",").map(String.init)
        }
        return parts.compactMap { part in
            let bare = part.filter { !$0.isWhitespace }
            guard let url = URL(string: bare), let scheme = url.scheme?.lowercased(), ["mailto", "https", "http"].contains(scheme) else { return nil }
            return url
        }
    }

    /// Whether List-Unsubscribe-Post offers one-click: its one value,
    /// "List-Unsubscribe=One-Click".
    public static func oneClick(_ post: String) -> Bool {
        post.filter { !$0.isWhitespace }.lowercased() == "list-unsubscribe=one-click"
    }

    /// The ways ⌘U can go, best first, each tried when the one before
    /// fails: one-click at the first https address when the list offers it
    /// there; a mail to its first mailto: address; its first web page.
    /// `testing`: a test world may post to this Mac itself, over http.
    public static func ways(header: String, post: String, testing: Bool = Store.testing) -> [Way] {
        let all = addresses(header)
        var out: [Way] = []
        let web = all.first { ["https", "http"].contains($0.scheme?.lowercased() ?? "") }
        if oneClick(post), let url = web, postable(url, testing: testing) { out.append(.oneClick(url)) }
        if let mail = all.lazy.compactMap(mailto).first { out.append(.mail(mail)) }
        if let url = web { out.append(.page(url)) }
        return out
    }

    /// The way ⌘U goes first; nil when the list gives none.
    public static func way(header: String, post: String, testing: Bool = Store.testing) -> Way? {
        ways(header: header, post: post, testing: testing).first
    }

    /// Where a one-click POST may go: https, to a host on the internet. A
    /// header is the sender's to write, so never this Mac, its network or
    /// an address in the private ranges; those open as a page, where you
    /// see where you are. A test world posts to this Mac, over http too.
    static func postable(_ url: URL, testing: Bool = Store.testing) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        if testing, ["127.0.0.1", "localhost"].contains(host) { return ["https", "http"].contains(scheme) }
        return scheme == "https" && outside(host)
    }

    /// A host on the internet: a name with a dot, not one of a home's or a
    /// Mac's own, or a numeric address outside the private ranges.
    public static func outside(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        // IPv6 written out: never needed for leaving a list.
        guard host.contains("."), !host.contains(":") else { return false }
        for local in ["localhost", "local", "internal", "lan", "home", "home.arpa", "intranet", "corp"]
        where host == local || host.hasSuffix("." + local) { return false }
        let octets = host.split(separator: ".").map { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 != nil }) else { return true }
        let a = octets[0]!, b = octets[1]!
        if [0, 10, 127].contains(a) || a >= 224 { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && b == 168 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        return true
    }

    /// A mailto: address (RFC 6068) as the mail ⌘U sends: its addresses,
    /// and the subject and words it asks for, "Unsubscribe" where it asks
    /// for none. Nil without an address mail can go to.
    static func mailto(_ url: URL) -> Mailto? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let rest = String(url.absoluteString.dropFirst("mailto:".count))
        let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var to = (parts.first ?? "").split(separator: ",").compactMap { $0.removingPercentEncoding }
        var subject = "", body = ""
        for field in (parts.count > 1 ? parts[1] : "").split(separator: "&") {
            let pair = field.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            guard pair.count == 2 else { continue }
            switch pair[0].lowercased() {
            case "subject": subject = pair[1]
            case "body": body = pair[1]
            case "to": to += pair[1].split(separator: ",").map(String.init)
            default: break
            }
        }
        let addresses = to.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter(MailAddress.valid)
        guard !addresses.isEmpty else { return nil }
        let said = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return Mailto(to: addresses, subject: said.isEmpty ? "Unsubscribe" : said,
                      body: body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unsubscribe" : body)
    }

    /// The ways out of a thread's list, from its newest mail by someone
    /// else that names one, and who that list is.
    public static func all(_ messages: [MailMessage], me: String, testing: Bool = Store.testing) -> (ways: [Way], sender: MailPerson)? {
        for message in messages.reversed() where message.from.address != me.lowercased() {
            guard let header = message.unsubscribe, !header.isEmpty else { continue }
            let ways = ways(header: header, post: message.unsubscribePost ?? "", testing: testing)
            if !ways.isEmpty { return (ways, message.from) }
        }
        return nil
    }

    /// The way ⌘U goes first for a thread, and who its list is.
    public static func of(_ messages: [MailMessage], me: String, testing: Bool = Store.testing) -> (way: Way, sender: MailPerson)? {
        all(messages, me: me, testing: testing).flatMap { found in found.ways.first.map { ($0, found.sender) } }
    }

    // MARK: - one-click

    /// RFC 8058's POST: "List-Unsubscribe=One-Click" to the list's address,
    /// with nothing of yours (no cookie, no sign-in, no cache), a redirect
    /// not followed, ten seconds at most, off the main thread. True when
    /// the list said yes.
    public static func post(_ url: URL, session: URLSession = MailUnsubscribe.session) async -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        guard let (_, response) = try? await session.data(for: request, delegate: Stay()) else { return false }
        return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// A session that keeps nothing and sends nothing kept.
    public static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    /// A redirect isn't followed: RFC 8058 has the list answer the POST itself.
    private final class Stay: NSObject, URLSessionTaskDelegate {
        public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

/// Senders kept out (Block Sender): an address, or a domain and every one
/// under it, kept in the account's store (`blocked`).
public enum MailBlock {
    /// What is kept for an address or a domain as found or typed: the
    /// address lowercased; the domain without @ and dots at its ends. Nil
    /// for what is neither.
    public static func entry(_ text: String) -> String? {
        var said = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let person = MailPerson.one(said), person.address.contains("@") { said = person.address }
        if said.hasPrefix("@") { said.removeFirst() }
        said = said.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if said.contains("@") { return MailAddress.valid(said) ? said : nil }
        guard said.contains("."), !said.contains(where: { $0.isWhitespace || $0 == "/" || $0 == ":" }) else { return nil }
        return said
    }

    /// Whether mail from an address is kept out by one of the entries: the
    /// address itself, its domain, or a domain it is under
    /// (news.substack.com under substack.com), never one that merely ends
    /// the same way (notsubstack.com).
    public static func blocks(_ entries: [String], _ address: String) -> Bool {
        let address = address.lowercased()
        guard let at = address.lastIndex(of: "@") else { return false }
        let domain = String(address[address.index(after: at)...])
        return entries.contains { entry in
            entry.contains("@") ? entry == address : domain == entry || domain.hasSuffix("." + entry)
        }
    }

    /// The domains everyone writes from: blocking one would keep out
    /// half the world, so only their addresses are offered.
    public static let common: Set<String> = ["gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com",
                                      "live.com", "msn.com", "yahoo.com", "ymail.com", "proton.me", "protonmail.com", "pm.me", "hey.com",
                                      "aol.com", "gmx.com", "gmx.de", "mail.ru", "yandex.ru", "fastmail.com", "zoho.com"]

    /// The domain Block Sender may offer beside the address: not a common
    /// one, and not your own.
    public static func domain(of address: String, me: String) -> String? {
        guard let domain = address.lowercased().split(separator: "@").last.map(String.init), domain.contains("."),
              !common.contains(domain), domain != me.lowercased().split(separator: "@").last.map(String.init) else { return nil }
        return domain
    }
}

/// Get Me To Zero: everything in the inbox older than a day, a week, a
/// month, or all of it, marked done in one act, the unread and the starred
/// left if you ask.
public enum MailZero {
    public enum Age: String, CaseIterable {
        case day, week, month, all

        /// As its row says it.
        public var name: String {
            switch self {
            case .day: return "Older Than a Day"
            case .week: return "Older Than a Week"
            case .month: return "Older Than a Month"
            case .all: return "Everything"
            }
        }

        /// As the log and the corner say it.
        public var said: String {
            switch self {
            case .day: return "older than a day"
            case .week: return "older than a week"
            case .month: return "older than a month"
            case .all: return "everything"
            }
        }

        /// Threads whose newest mail is before this; nil, every one.
        public func edge(_ now: Date) -> Date? {
            switch self {
            case .day: return now.addingTimeInterval(-86_400)
            case .week: return now.addingTimeInterval(-7 * 86_400)
            case .month: return now.addingTimeInterval(-30 * 86_400)
            case .all: return nil
            }
        }
    }

    /// What stays in the inbox: unread threads, starred ones. Kept in
    /// Settings (`mail.zero.unread`, `mail.zero.starred`), off at first.
    public struct Leave: Equatable {
        public var unread = false
        public var starred = false

        public static var chosen: Leave {
            get { Leave(unread: Store.settings.bool(forKey: "mail.zero.unread"), starred: Store.settings.bool(forKey: "mail.zero.starred")) }
            set {
                Store.settings.set(newValue.unread, forKey: "mail.zero.unread")
                Store.settings.set(newValue.starred, forKey: "mail.zero.starred")
            }
        }
    }

    /// The inbox's threads Get Me To Zero marks done, newest first.
    public static func threads(_ age: Age, leave: Leave, in store: MailStore, now: Date = Date()) -> [String] {
        threads(age, leave: leave, of: store.inboxThreads(), now: now)
    }

    public static func threads(_ age: Age, leave: Leave, of inbox: [(thread: String, last: Date, unread: Bool, starred: Bool)], now: Date = Date()) -> [String] {
        let edge = age.edge(now)
        return inbox.filter { thread in
            (edge.map { thread.last < $0 } ?? true) && !(leave.unread && thread.unread) && !(leave.starred && thread.starred)
        }.map(\.thread)
    }
}

/// An entry of the Bulk Actions log: Get Me To Zero, or everything from a
/// sender done or put in Trash; what it said, how many threads, when, and
/// when it was taken back.
public struct MailBulk: Equatable {
    public enum Kind: String {
        /// Get Me To Zero: out of the inbox.
        case zero
        /// Everything from a sender, out of the inbox.
        case done
        /// Everything from a sender, into Trash.
        case trash
    }

    public var id: Int64
    public var kind: Kind
    public var said: String
    public var threads: Int
    public var at: Date
    public var back: Date?
}
