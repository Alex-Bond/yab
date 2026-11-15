import CryptoKit
import Foundation
import Security

// Read statuses (docs/mail.md, Read statuses; the site's half and the
// contract between the two: fast-web's docs/read-statuses.md). Off until
// turned on for an account in Settings › Mail › Writing. A mail sent with
// them on ends with a 1×1 picture of yetanotherbrowser.com's, named by a
// token, and the site writes down each time it loads: when, and what kind
// of reader loaded it, nothing else. The token is the first half of the
// SHA-256 of a key only this Mac keeps, one a mail; the site answers about
// a mail only to whoever gives its key, so a recipient, who has the token,
// can't watch when the others opened it. No address, subject or word of
// the mail goes to the site.
//
// Asked every five minutes while Yab is active, after a sync, and at once
// when a thread with such a mail of yours opens: the mail of the last 30
// days, 200 keys a call (MailCenter.askReads). Gmail loads a mail's
// pictures through Google's proxy when the mail is shown, so those count;
// Apple Mail's privacy loads every picture by itself, read or not, hours
// after it came, so its loads are a maybe, whenever they come. Said in
// words under your mail, in Sent and in Waiting; never in a notification.
// Pictures like it in mail that comes to you stay blocked (MailHTML), and
// ours never load here, whatever that setting says.

public enum MailReads {
    /// The site that serves the pictures and answers for them.
    public static let site = URL(string: "https://yetanotherbrowser.com")!

    /// Where the pictures point and the site is asked: the site, or in a
    /// test world a stand-in on this Mac (YAB_OPENS_URL), so checks never
    /// reach it.
    public static var base: URL {
        if Store.testing, let given = ProcessInfo.processInfo.environment["YAB_OPENS_URL"].flatMap(URL.init(string:)), given.host != nil {
            return given
        }
        return site
    }

    /// Never in mail to more people than this: a picture in a mail to a
    /// crowd says nothing of who opened it.
    public static let most = 10
    /// How long after it went a mail is asked about.
    public static let kept: TimeInterval = 30 * 86_400
    /// How often the site is asked about all of it while Yab is active.
    public static let every: TimeInterval = 300
    /// The most keys one ask carries, as the site takes them.
    public static let batch = 200

    // MARK: - the setting

    /// Whether an account's mail goes with read statuses (Settings › Mail ›
    /// Writing), off until turned on: meta `reads` in its store, so `yab
    /// mail flush` sends a mail set for later as the app would.
    public static func on(_ store: MailStore) -> Bool { store.value("reads") == "on" }

    public static func set(_ on: Bool, in store: MailStore) { store.set("reads", on ? "on" : nil) }

    // MARK: - keys and tokens

    /// A key: 16 bytes from the system's secure random generator.
    public static func newKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // The other generator the system keeps for secrets (arc4random).
            var system = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &system) }
        }
        return Data(bytes)
    }

    /// A key's token: the first 16 bytes of the SHA-256 of its bytes.
    public static func token(of key: Data) -> Data { Data(SHA256.hash(data: key).prefix(16)) }

    /// A key, as written, its token as written; nil for what isn't a key.
    public static func token(for key: String) -> String? { decoded(key).map { encoded(token(of: $0)) } }

    /// 16 bytes in base64url without padding: 22 characters, the last one
    /// of A, Q, g or w, as the site takes them and no other way.
    public static func encoded(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decoded(_ text: String) -> Data? {
        guard written(text) else { return nil }
        let plain = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=="
        return Data(base64Encoded: plain)
    }

    /// Written as a key or a token is: 16 bytes in base64url.
    public static func written(_ text: String) -> Bool { text.range(of: "^[A-Za-z0-9_-]{21}[AQgw]$", options: .regularExpression) != nil }

    // MARK: - the picture

    /// The picture a token names.
    public static func address(of token: String, base: URL = base) -> URL {
        base.appendingPathComponent("o").appendingPathComponent(token + ".gif")
    }

    /// The picture as it goes last in a mail's HTML part: 1×1, no border,
    /// nothing said.
    public static func image(_ token: String, base: URL = base) -> String {
        "<img src=\"" + address(of: token, base: base).absoluteString + "\" width=\"1\" height=\"1\" alt=\"\" style=\"border:0;width:1px;height:1px\">"
    }

    /// HTML as this Mac shows it, our pictures out: a mail of yours read
    /// here, or a reply quoting it (Gmail's quote keeps it, through its own
    /// proxy), never counts as opened, whatever Block tracking pixels says.
    public static func strip(_ html: String) -> String {
        guard html.range(of: "/o/", options: .literal) != nil else { return html }
        var hosts = [NSRegularExpression.escapedPattern(for: "yetanotherbrowser.com")]
        if let host = base.host, base != site { hosts.append(NSRegularExpression.escapedPattern(for: host + (base.port.map { ":\($0)" } ?? ""))) }
        let pattern = "<img\\b[^>]*(?:" + hosts.joined(separator: "|") + ")/o/[A-Za-z0-9_-]{21}[AQgw]\\.gif[^>]*>"
        return html.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }

    // MARK: - going out

    /// Whether a mail goes with a read status, the setting being on: words
    /// of the person's (not an unsubscribe or an answer to an invitation,
    /// which Yab writes for them), to someone, to 10 people at most, none of
    /// them the person under any of their addresses (`mine`), whose own copy
    /// would count as opened.
    public static func wanted(_ draft: MailDraft, mine: Set<String>) -> Bool {
        guard !draft.id.hasPrefix("unsubscribe:"), !draft.id.hasPrefix("rsvp:") else { return false }
        let people = Set((draft.to + draft.cc + draft.bcc).map { $0.address.lowercased() }.filter { !$0.isEmpty })
        return !people.isEmpty && people.count <= most && people.isDisjoint(with: mine)
    }

    /// The addresses that are the account's: its own, and the ones it sends as.
    public static func mine(_ store: MailStore) -> Set<String> {
        Set(([store.me] + store.aliases + store.sendAs().map(\.address)).map { $0.lowercased() }.filter { !$0.isEmpty })
    }

    /// The key a mail about to go carries (MailOps.send): the one kept for
    /// it at a try before, which Gmail may have sent without saying so, or
    /// a new one, kept now, before it goes; nil when it goes without (off,
    /// or not a mail for one). A mail taken back before it went (Undo send,
    /// a send set for later opened again) never got this far: no key.
    public static func key(for draft: MailDraft, in store: MailStore, now: Date = MailClock.now) -> String? {
        guard !draft.messageID.isEmpty else { return nil }
        guard on(store), wanted(draft, mine: mine(store)) else {
            // Turned off since a try that didn't go: it goes without.
            store.dropRead(message: draft.messageID)
            return nil
        }
        return store.readKey(message: draft.messageID, at: now) { encoded(newKey()) }
    }

    /// A mail that went (MailOps.send): its key kept against its thread and
    /// the time it went.
    public static func sent(_ draft: MailDraft, thread: String, at: Date, in store: MailStore) {
        guard !draft.messageID.isEmpty else { return }
        store.readSent(message: draft.messageID, thread: thread, at: at)
    }

    // MARK: - what the site says

    /// What loaded the picture, as the site tells it from the User-Agent.
    public enum Kind: String, Sendable {
        /// Gmail, on the web and in its apps, through Google's proxy, when
        /// the mail is shown: usually someone reading it.
        case google = "google-proxy"
        /// Apple Mail's privacy, which loads every picture by itself, read
        /// or not: a maybe.
        case apple = "apple-privacy"
        /// A mail app loading it itself, another proxy, a company's scanner.
        case other
    }

    public struct Open: Equatable, Sendable {
        public var at: Date
        public var kind: Kind
    }

    /// The site's answer to an ask (`{"opens": {key: [{at, kind}]}}`): each
    /// key with an open, its opens newest first; nil for what isn't one.
    public static func opens(from data: Data) -> [String: [Open]]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let all = json["opens"] as? [String: Any] else {
            return nil
        }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var out: [String: [Open]] = [:]
        for (key, list) in all {
            guard written(key), let list = list as? [[String: Any]] else { continue }
            out[key] = list.compactMap { one in
                guard let said = one["at"] as? String, let at = precise.date(from: said) ?? plain.date(from: said) else { return nil }
                // A kind the site learns later counts as a reader's own.
                return Open(at: at, kind: Kind(rawValue: one["kind"] as? String ?? "") ?? .other)
            }.sorted { $0.at > $1.at }
        }
        return out
    }

    // MARK: - said

    /// A mail's opens as the lines say them: how many surely and how many
    /// maybe (Apple Mail's privacy), and the last of each.
    public struct Seen: Equatable, Sendable {
        public var sure = 0
        public var maybe = 0
        public var last: Date?
        var lastMaybe: Date?
        /// Every open, newest first: the card under the line lists them.
        public var opens: [Open] = []

        public init(_ opens: [Open]) {
            self.opens = opens.sorted { $0.at > $1.at }
            for open in opens {
                if open.kind == .apple {
                    maybe += 1
                    lastMaybe = max(lastMaybe ?? open.at, open.at)
                } else {
                    sure += 1
                    last = max(last ?? open.at, open.at)
                }
            }
        }

        public var isEmpty: Bool { sure == 0 && maybe == 0 }
    }

    /// Under your mail in a thread: "Opened 2h ago", "Opened 3× · last 2h
    /// ago"; Apple Mail's privacy's loads a maybe, "Maybe opened 2h ago ·
    /// Apple Mail’s privacy", or beside sure ones "· 1 maybe, Apple Mail’s
    /// privacy". "" while it wasn't opened: nothing to say.
    public static func line(_ seen: Seen, now: Date = MailClock.now) -> String {
        var parts: [String] = []
        if seen.sure > 0, let last = seen.last {
            parts = seen.sure == 1 ? ["Opened " + ago(last, now: now)] : ["Opened \(seen.sure)×", "last " + ago(last, now: now)]
            if seen.maybe > 0 { parts.append("\(seen.maybe) maybe, Apple Mail’s privacy") }
        } else if seen.maybe > 0, let last = seen.lastMaybe {
            parts = seen.maybe == 1 ? ["Maybe opened " + ago(last, now: now)] : ["Maybe opened \(seen.maybe)×", "last " + ago(last, now: now)]
            parts.append("Apple Mail’s privacy")
        }
        return parts.joined(separator: " · ")
    }

    /// One open as the card under the line says where it was: Gmail's
    /// proxy is Gmail on any device, Apple Mail's privacy a maybe.
    public static func place(_ kind: Kind) -> String {
        switch kind {
        case .google: return "In Gmail"
        case .apple: return "Apple Mail, maybe"
        case .other: return "Elsewhere"
        }
    }

    /// A list's row, Sent's and Waiting's, in a word or two: "Opened",
    /// "Opened 3×", "Maybe opened"; "" while it wasn't.
    public static func short(_ seen: Seen) -> String {
        if seen.sure > 0 { return seen.sure == 1 ? "Opened" : "Opened \(seen.sure)×" }
        return seen.maybe > 0 ? "Maybe opened" : ""
    }

    /// As mail_read tells an agent of a mail of yours that went with one.
    public static func told(_ seen: Seen, now: Date = MailClock.now) -> String {
        seen.isEmpty ? "not opened yet" : line(seen, now: now)
    }

    /// How long ago, as mail's statuses say it: "just now", "5m ago",
    /// "2h ago", "3d ago".
    public static func ago(_ date: Date, now: Date = MailClock.now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    // MARK: - asking

    /// The line to the site: a session of its own, no cookie sent or kept,
    /// nothing written to a cache, given up after 15 seconds.
    public struct Client: Sendable {
        public var base: URL = MailReads.base
        public var session: URLSession = Client.session

        public static let session: URLSession = {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            return URLSession(configuration: config)
        }()

        public init(base: URL = MailReads.base, session: URLSession = Client.session) {
            self.base = base
            self.session = session
        }

        /// When these keys' mail was opened, as the site says it: only in
        /// the body, never in the address, which logs keep.
        public func opens(_ keys: [String]) async throws -> [String: [Open]] {
            var request = URLRequest(url: base.appendingPathComponent("api/opens"), timeoutInterval: 15)
            request.httpMethod = "POST"
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["keys": keys])
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let found = MailReads.opens(from: data) else {
                throw URLError(.badServerResponse)
            }
            return found
        }
    }

    /// The site asked about mail of yours: a thread's (`thread`), or all
    /// that went in the last 30 days, 200 keys an ask; what it said kept.
    /// Whether anything new came. Stops at an ask that fails (offline, the
    /// site away): the next turn asks again.
    public static func ask(_ store: MailStore, thread: String? = nil, client: Client = Client(), now: Date = MailClock.now) async -> Bool {
        let keys = store.readKeys(since: now.addingTimeInterval(-kept), thread: thread).map(\.key)
        var news = 0
        for start in stride(from: 0, to: keys.count, by: batch) {
            guard let found = try? await client.opens(Array(keys[start..<min(keys.count, start + batch)])) else { break }
            news += store.keepOpens(found)
        }
        return news > 0
    }

    /// Each of these mails that went with a key, by Message-ID, as its line
    /// says it.
    public static func seen(_ messages: [String], in store: MailStore) -> [String: Seen] {
        store.opens(messages: messages).mapValues(Seen.init)
    }

    /// Each of these threads' newest mail of yours that went with a key, as
    /// a list's row says it: "" while it wasn't opened.
    public static func rows(_ threads: [String], in store: MailStore) -> [String: String] {
        let newest = store.readMessages(threads: threads)
        guard !newest.isEmpty else { return [:] }
        let found = Self.seen(Array(newest.values), in: store)
        return newest.compactMapValues { message in found[message].map(short).flatMap { $0.isEmpty ? nil : $0 } }
    }
}
