import Foundation

/// How typed words read, the Mac's rules (⌘T, `Browser.wordsLead`,
/// `TaskWords`, `Address` in Sources/Fast) brought over whole, so the same
/// words lead to the same row on both: an address is a place, a verb first
/// and three words or more is a task, a question is Ask, anything else is a
/// search. Pure Swift: no views, no stores, tested on its own (WordsTests).
enum Words {
    enum Kind: String, Sendable, Equatable, CaseIterable {
        /// Nothing typed.
        case none
        /// An address: lumen.events, localhost:5173, https://….
        case open
        /// A question word first, with three words or a question mark.
        case ask
        /// A thing to do: a verb first and three words or more.
        case task
        /// Anything else.
        case search
    }

    /// What the words are, the Mac's order: an address first, then a task
    /// read strongly, then a question, else a search. A verb first wins over
    /// a question mark ("book the 18:35 to lisbon?" is a task), as on the Mac.
    static func read(_ text: String) -> Kind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        if address(trimmed) != nil { return .open }
        if TaskReading.strength(trimmed) == .strong { return .task }
        if question(trimmed) { return .ask }
        return .search
    }

    // MARK: - questions

    /// The words a question starts with (the Mac's `TaskWords.asking`).
    static let asking: Set<String> = [
        "how", "what", "why", "who", "whom", "whose", "which", "when", "where", "is", "are", "was", "were",
        "can", "could", "does", "do", "did", "should", "would", "will", "whats", "what's", "how's",
    ]

    /// A question word first, with three words or a question mark. A mark
    /// alone or a how-to phrase still means a search, as on the Mac.
    static func question(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = split(trimmed)
        guard words.count >= 2, !trimmed.contains("://") else { return false }
        guard asking.contains(words[0].trimmingCharacters(in: .punctuationCharacters)),
              words[1].trimmingCharacters(in: .punctuationCharacters) != "to" else { return false }
        return words.count >= 3 || trimmed.hasSuffix("?")
    }

    // MARK: - what the words point at

    /// Words that point at the page in front ("this", "here", "page"):
    /// a task from the plate's field takes the page along.
    static func pointsAtPage(_ text: String) -> Bool {
        let words = Set(split(text).map { $0.trimmingCharacters(in: .punctuationCharacters) })
        return !words.isDisjoint(with: ["this", "here", "page"])
    }

    /// Three letters or more of "settings" or "preferences":
    /// Yab's own Settings is a row, the way ⌘T finds it on the Mac.
    static func wantsSettings(_ text: String) -> Bool {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard typed.count >= 3 else { return false }
        return ["settings", "preferences"].contains { $0.hasPrefix(typed) }
    }

    static func split(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // MARK: - addresses

    /// The page the words name, if they are an address (the Mac's
    /// `Address.url(from:)`): a host with a dot and a letters' ending, an IP,
    /// localhost, a machine's name with a server's port, or anything written
    /// with http(s)://. Nil for words, an email address, a version number.
    static func address(_ typed: String) -> URL? {
        Address.url(from: typed)
    }
}

/// Tasks in words, the Mac's `TaskWords`: the verbs a task starts with and
/// how strongly words read as one.
enum TaskReading {
    enum Strength: Sendable, Equatable { case strong, weak }

    /// The verbs a task starts with: the Mac's own, word for word. The
    /// prototype's readWords has a few more (request and others);
    /// they read as searches here as on the Mac, until the Mac takes them
    /// (Phone/Tests/WordsPhrases.json is checked on both).
    static let verbs: Set<String> = [
        "find", "compare", "book", "collect", "gather", "research", "summarize", "summarise", "check", "track",
        "list", "look", "get", "buy", "order", "reserve", "schedule", "plan", "write", "draft", "reply",
        "answer", "email", "make", "build", "pick", "choose", "recommend", "tell", "explain", "translate",
        "fill", "sign", "cancel", "unsubscribe", "watch", "remind", "download", "save", "organize", "sort",
        "clean", "review", "read", "go", "open", "show", "help", "figure", "work", "fix", "extract", "copy",
        "rewrite", "shorten", "turn", "convert", "calculate", "estimate", "monitor", "notify", "send", "post",
        "create", "add", "remove", "update", "change", "move",
    ]

    /// Whether the words read as a thing to do rather than an address or a
    /// search: a verb first and three words or more, strongly; five words or
    /// more without one, weakly (the search stays first then: taking a
    /// search for a task costs more than the other way round). Short
    /// requests to change Yab itself ("dark mode") are tasks too.
    static func strength(_ text: String) -> Strength? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if nativeRequest(trimmed) { return .strong }
        let words = Words.split(trimmed)
        guard words.count >= 3, !trimmed.contains("://") else { return nil }
        // A word with a domain's dot in it is an address, or a site's name.
        if words.contains(where: { $0.range(of: #"^[a-z0-9-]+\.[a-z]{2,}(/.*)?$"#, options: .regularExpression) != nil }) { return nil }
        let first = words[0].trimmingCharacters(in: .punctuationCharacters)
        if verbs.contains(first) { return .strong }
        return words.count >= 5 ? .weak : nil
    }

    /// Short requests to change Yab itself (the Mac's
    /// `TaskWords.nativeRequest`): a verb about a setting's subject.
    static func nativeRequest(_ text: String) -> Bool {
        let text = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, !text.contains("://") else { return false }
        if ["dark mode", "light mode"].contains(text) { return true }
        if undoRequest(text) { return true }
        let first = words[0].trimmingCharacters(in: .punctuationCharacters)
        let verbs: Set<String> = ["turn", "set", "enable", "disable", "change", "add", "connect", "reconnect", "disconnect", "create", "rename",
                                  "move", "pin", "unpin", "hide", "show", "make"]
        let asking = ["can", "could"].contains(first)
        guard verbs.contains(first) || (asking && words.dropFirst().contains(where: { verbs.contains($0) })) else { return false }
        let subjects = ["theme", "dark", "light", "sidebar", "space", "spaces", "tabs", "tab", "font", "zoom", "gmail", "mail", "bookmark"]
        return subjects.contains { text.contains($0) }
    }

    static func undoRequest(_ text: String) -> Bool {
        let text = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "undo" || text.hasPrefix("undo the last")
    }
}

/// What typed words have to be to be a place, the Mac's `Address`: this
/// either hands back a URL or nothing, and nothing means the words are words.
enum Address {
    /// Schemes the field takes as a place to go.
    private static let ours: Set<String> = ["http", "https", "about", "data"]

    /// Words a scheme is spelled with: tel:911 or javascript:1 is never a
    /// machine called tel.
    private static let schemes: Set<String> = ours.union([
        "javascript", "mailto", "tel", "sms", "ftp", "ws", "wss", "blob", "view-source", "file",
        "facetime", "facetime-audio", "maps", "news", "webcal", "callto", "sip", "ssh", "git",
    ])

    /// Ports a machine on the network is reached at: the web's own and the
    /// ones a server picks for itself, 1024 and up. Below that, word:3 is a
    /// verse, a version, a ratio, not a server.
    private static func serves(_ port: Int) -> Bool {
        port >= 1024 || [80, 443].contains(port)
    }

    static func url(from typed: String) -> URL? { url(from: typed, names: true) }

    /// `names`: a bare name with a port, nas:5000, counts.
    static func url(from typed: String, names: Bool) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }

        // Written with a scheme, it is taken at its word.
        if let split = text.range(of: "://") {
            let scheme = text[..<split.lowerBound].lowercased()
            guard ours.contains(scheme) else { return nil }
            return URL(string: text)
        }
        if text.lowercased().hasPrefix("about:") || text.lowercased().hasPrefix("data:") {
            return URL(string: text)
        }

        // Everything else has to look like a host before it gets a scheme put
        // in front of it. "hello world" is not a website, and neither is "todo".
        let head = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !head.isEmpty, !head.contains("@") else { return nil } // an email address
        guard let (host, port) = split(head) else { return nil }
        let number = port.map { Int(UInt16($0) ?? 0) }
        if number == 0 { return nil }
        let machine = names && isName(host) && !schemes.contains(host) && number.map(serves) == true
        guard looksLikeHost(host) || machine else { return nil }
        // A local server almost never has a certificate.
        return URL(string: (isLocal(host) ? "http://" : "https://") + text)
    }

    private static func split(_ head: Substring) -> (host: String, port: Substring?)? {
        if head.hasPrefix("[") {
            guard let close = head.firstIndex(of: "]") else { return nil }
            let rest = head[head.index(after: close)...]
            guard rest.isEmpty || rest.hasPrefix(":") else { return nil }
            return (head[...close].lowercased(), rest.isEmpty ? nil : rest.dropFirst())
        }
        let parts = head.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let host = parts.first, !host.isEmpty else { return nil }
        return (host.lowercased(), parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
    }

    private static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if host.hasPrefix("[") {
            let inside = host.dropFirst().dropLast()
            if inside == "::1" { return true }
            guard let first = inside.split(separator: ":", omittingEmptySubsequences: false).first,
                  let hextet = UInt16(first, radix: 16) else { return false }
            return hextet & 0xFFC0 == 0xFE80 || hextet & 0xFE00 == 0xFC00
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { UInt8($0) }
        guard parts.count == 4, numbers.count == 4 else { return parts.count == 1 }
        switch (numbers[0], numbers[1]) {
        case (0, _), (10, _), (127, _), (192, 168), (169, 254), (172, 16...31): return true
        default: return false
        }
    }

    private static func isName(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && !host.hasSuffix("-")
            && host.contains { $0.isLetter }
            && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func looksLikeHost(_ host: String) -> Bool {
        if host == "localhost" { return true }
        if host.hasPrefix("["), host.hasSuffix("]") {
            let inside = host.dropFirst().dropLast()
            return inside.contains(":") && inside.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        let numbers = host.split(separator: ".", omittingEmptySubsequences: false)
        if numbers.count == 4, numbers.allSatisfy({ UInt8($0) != nil }) { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        guard labels.allSatisfy({ label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }) else { return false }
        // The last label carries the weight: a dotted thing ending in letters is
        // a domain, a dotted thing ending in digits is a version number.
        let tld = labels[labels.count - 1]
        return tld.count >= 2 && tld.allSatisfy { $0.isLetter }
    }

    /// What the field shows for a page: no scheme, no www.
    static func pretty(_ url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        var bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let port = url.port { bare += ":\(port)" }
        let path = url.path(percentEncoded: true)
        var text = path.isEmpty || path == "/" ? bare : bare + path
        if let query = url.query(percentEncoded: true), !query.isEmpty { text += "?" + query }
        if let fragment = url.fragment(percentEncoded: true), !fragment.isEmpty { text += "#" + fragment }
        return text
    }
}
