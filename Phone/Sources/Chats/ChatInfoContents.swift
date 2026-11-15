import Foundation
#if canImport(SyncKit)
import SyncKit
#endif

/// What a chat touched, for Chat Info's tabs, as Telegram's profile lists a
/// chat's media, files and links: the sites its agent worked on (from its
/// turns' steps), the links said in it, the photos and the files sent with
/// it. Read from the chat as this iPhone shows it, nothing else: a step's
/// "tab:<id>" names a Mac tab and opens nothing here.
struct ChatInfoContents: Equatable, Sendable {
    struct Site: Equatable, Sendable, Identifiable {
        var id: String { host }
        /// Bare host: "booking.com".
        let host: String
        /// Where a tap goes: the last address a step named on it, else the site.
        let url: URL
        /// Steps that went to it.
        let visits: Int
        let last: Date?
    }

    struct Link: Equatable, Sendable, Identifiable {
        var id: String { url.absoluteString }
        let url: URL
        /// The link's own words, else its address without the scheme.
        let title: String
        let host: String
    }

    struct Item: Equatable, Sendable, Identifiable {
        let id: String
        let file: Message.File
    }

    /// Newest first, each once.
    var sites: [Site] = []
    var links: [Link] = []
    /// Photos, newest first.
    var media: [Item] = []
    /// Other files, newest first.
    var files: [Item] = []
    /// Steps of work across the chat and how long it worked, for one quiet line.
    var steps = 0
    var worked: TimeInterval = 0

    var isEmpty: Bool { sites.isEmpty && links.isEmpty && media.isEmpty && files.isEmpty }

    enum Tab: String, CaseIterable, Sendable, Identifiable {
        case sites, links, media, files
        var id: String { rawValue }
        var title: String {
            switch self {
            case .sites: "Sites"
            case .links: "Links"
            case .media: "Media"
            case .files: "Files"
            }
        }
    }

    /// The tabs with something in them, in Telegram's order of use here.
    var tabs: [Tab] {
        Tab.allCases.filter { tab in
            switch tab {
            case .sites: !sites.isEmpty
            case .links: !links.isEmpty
            case .media: !media.isEmpty
            case .files: !files.isEmpty
            }
        }
    }

    /// The work in one line: "750 steps · 2h 10m".
    var workLine: String? {
        guard steps > 0 else { return nil }
        let count = "\(steps) " + (steps == 1 ? "step" : "steps")
        return worked >= 1 ? count + " \u{00B7} " + TurnWork.span(worked) : count
    }

    init() {}

    /// One pass over the messages. Pure, so it runs off the main thread.
    init(messages: [Message]) {
        var sites: [String: (url: URL?, visits: Int, last: Date?, order: Int)] = [:]
        var links: [String: (link: Link, order: Int)] = [:]
        var media: [(Item, Int)] = []
        var files: [(Item, Int)] = []
        var seenFiles: Set<String> = []
        var order = 0
        for (index, message) in messages.enumerated() {
            if let work = message.work {
                let real = work.work
                steps += real.count
                worked += Self.worked(real)
                for step in real where step.kind == "tool" || step.kind == "subagent" {
                    let address = Self.address(step.detail)
                    var hosts = StepWords.hosts(step.detail).map(StepWords.bare)
                    if let site = StepWords.of(step).site, !hosts.contains(site) { hosts.append(site) }
                    if let address, let host = address.host.map(StepWords.bare), !hosts.contains(host) { hosts.append(host) }
                    for host in hosts where Self.isHost(host) {
                        order += 1
                        var entry = sites[host] ?? (nil, 0, nil, 0)
                        entry.visits += 1
                        entry.order = order
                        if let address, address.host.map(StepWords.bare) == host { entry.url = address }
                        if let when = step.ended ?? step.began { entry.last = max(entry.last ?? when, when) }
                        sites[host] = entry
                    }
                }
            }
            if [.you, .answer, .pick].contains(message.role) {
                for link in Self.links(in: message.text) + (message.pick.map { Self.links(in: $0.rows.joined().joined(separator: " ")) } ?? []) {
                    order += 1
                    // Said again, it moves up; its words are the first that named it.
                    let named = links[link.id].map { $0.link.title != Self.shortAddress($0.link.url) ? $0.link : link } ?? link
                    links[link.id] = (named, order)
                }
            }
            for (n, file) in message.files.enumerated() {
                let id = file.digest.isEmpty ? "\(index)/\(n)/\(file.name)" : file.digest + "/" + file.name
                guard seenFiles.insert(id).inserted else { continue }
                order += 1
                if file.isImage { media.append((Item(id: id, file: file), order)) } else { files.append((Item(id: id, file: file), order)) }
            }
        }
        self.sites = sites.sorted { $0.value.order > $1.value.order }.compactMap { host, entry in
            guard let url = entry.url ?? URL(string: "https://" + host) else { return nil }
            return Site(host: host, url: url, visits: entry.visits, last: entry.last)
        }
        self.links = links.values.sorted { $0.order > $1.order }.map(\.link)
        self.media = media.sorted { $0.1 > $1.1 }.map(\.0)
        self.files = files.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// A step's detail when it is a whole web address.
    static func address(_ detail: String) -> URL? {
        let words = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard words.hasPrefix("http://") || words.hasPrefix("https://"), !words.contains(" "),
              let url = URL(string: words), url.host?.contains(".") == true else { return nil }
        return url
    }

    /// A name a site goes by, not a file name that looks like one.
    static func isHost(_ host: String) -> Bool {
        guard host.contains("."), host.count < 80, !host.contains("/"), !host.contains(" ") else { return false }
        let last = host.split(separator: ".").last.map(String.init) ?? ""
        return last.count >= 2 && last.allSatisfy(\.isLetter) && !fileEndings.contains(last.lowercased())
    }

    private static let fileEndings: Set<String> = ["swift", "json", "md", "txt", "js", "ts", "py", "html", "css", "png", "jpg", "pdf", "plist", "yml", "yaml", "sh", "lock"]

    /// Time the steps took, overlapping ones once (steps run one after another).
    private static func worked(_ steps: [TurnWork.Step]) -> TimeInterval {
        let starts = steps.compactMap(\.began), ends = steps.compactMap { $0.ended ?? $0.began }
        guard let first = starts.min(), let last = ends.max(), last > first else { return 0 }
        return last.timeIntervalSince(first)
    }

    private static let markdownLink = try! NSRegularExpression(pattern: #"\[([^\]\n]{1,300})\]\((https?://[^\s)]+)\)"#)
    private static let bareLink = try! NSRegularExpression(pattern: #"(?<![\(\w])https?://[^\s<>()\[\]"']+"#)

    /// Web links in a message's words: Markdown's with their words, bare
    /// addresses as themselves. Only http and https, as the chat opens them.
    static func links(in text: String) -> [Link] {
        guard text.contains("http") else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        var out: [Link] = []
        func add(_ raw: String, title: String?) {
            var address = raw
            while let last = address.last, ".,;:!?".contains(last) { address.removeLast() }
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host.map(StepWords.bare), host.contains(".") else { return }
            let words = title.map { SubagentReport.plain($0) }.flatMap { $0.isEmpty ? nil : $0 }
            out.append(Link(url: url, title: words ?? Self.shortAddress(url), host: host))
        }
        for match in markdownLink.matches(in: text, range: whole) {
            guard let title = Range(match.range(at: 1), in: text), let url = Range(match.range(at: 2), in: text) else { continue }
            add(String(text[url]), title: String(text[title]))
        }
        for match in bareLink.matches(in: text, range: whole) {
            guard let url = Range(match.range, in: text) else { continue }
            let raw = String(text[url])
            if out.contains(where: { $0.url.absoluteString == raw }) { continue }
            add(raw, title: nil)
        }
        return out
    }

    /// "timeout.com/lisbon/guide": an address as a person reads it.
    static func shortAddress(_ url: URL) -> String {
        let host = url.host.map(StepWords.bare) ?? ""
        let path = url.path == "/" ? "" : url.path
        return host + path
    }
}

/// Chat Info's contents, kept per chat and its messages as they were: an
/// unchanged chat opens Info with them at once, a changed one (a new
/// message, an edited last turn) is read again. Only the newest few are kept.
@MainActor
enum ChatInfoMemo {
    struct Key: Hashable {
        let chat: Chat.ID
        let count: Int
        /// The last two messages: where a running chat changes.
        let tail: Int
    }

    private static var kept: [(key: Key, contents: ChatInfoContents)] = []
    static let limit = 8

    static func key(_ chat: Chat) -> Key {
        var hasher = Hasher()
        for message in chat.messages.suffix(2) { hasher.combine(message) }
        return Key(chat: chat.id, count: chat.messages.count, tail: hasher.finalize())
    }

    static func cached(_ chat: Chat) -> ChatInfoContents? { cached(key(chat)) }

    static func cached(_ key: Key) -> ChatInfoContents? { kept.first { $0.key == key }?.contents }

    static func keep(_ contents: ChatInfoContents, for key: Key) {
        kept.removeAll { $0.key.chat == key.chat }
        kept.insert((key, contents), at: 0)
        if kept.count > limit { kept.removeLast(kept.count - limit) }
    }

    /// The contents for this chat as it is now: kept ones at once, else read
    /// off the main thread and kept.
    static func contents(of chat: Chat) async -> ChatInfoContents {
        let key = key(chat)
        if let kept = cached(key) { return kept }
        let messages = chat.messages
        let read = await Task.detached(priority: .userInitiated) { ChatInfoContents(messages: messages) }.value
        keep(read, for: key)
        return read
    }

    static func reset() { kept = [] }
}
