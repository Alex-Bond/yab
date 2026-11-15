import Foundation

/// What a tab's card says beyond its name (Glance.swift): who or where it
/// is, the one thing about it now, and the one thing to do about it that a
/// click on the tab would not. Worked out from what the tab already knows
/// about itself and from what a live folder last read about the thing it
/// shows; never read from a site for the card alone. docs/tab-cards.md.
struct TabGist: Equatable {
    /// The thing's own name, when the page's title says more than that
    /// ("Fix it by anna · Pull Request #12 · acme/yab · GitHub").
    var title: String?
    /// Under the title, in place of the site: "anna · #12".
    var facts: String?
    /// The person the facts line is about, drawn as their initial.
    var person: String?
    var now: Now?
    var action: Action?

    /// One line, the first that applies: what could be lost, what waits
    /// for you, then what is only going on.
    struct Now: Equatable {
        /// Said first, in the line's weight: "Failing", "Not sent".
        var word: String?
        var text: String
        var tone: Tone
    }

    enum Tone: Equatable {
        /// Something for you: in ink.
        case you
        /// Something gone wrong: in the failing red.
        case wrong
        /// Only going on: muted.
        case going
    }

    struct Action: Equatable {
        var label: String
        var kind: Kind
    }

    enum Kind: Equatable {
        /// Another page of the same thing, in this tab: a pull request's
        /// checks or its files.
        case open(URL)
        case play, pause, sleep, reload
        /// A calendar pin with nothing to read: where Google (or the Mac's
        /// calendars) is connected.
        case connectCalendar
    }

    /// Everything the card may say, as plain values, so the rules can be
    /// tested without a tab.
    struct Signals {
        var address: URL?
        var label: String
        var draft = false
        var camera = false
        var microphone = false
        var deaf: Date?
        /// An AI chat or a builder at work, since when, and its word
        /// (ChatBusy): "Answering", "Researching", "Building".
        var busy: Date?
        var busyWord = ""
        /// Its answer came while you were elsewhere, and its word: "Answer
        /// ready", a builder's "Done".
        var done: Date?
        var doneWord = ""
        var playing: Bool?
        var position: Double = 0
        var duration: Double = 0
        var streaming = false
        var weight: UInt64 = 0
        var canSleep = false
        /// A pinned calendar with no calendar connected to read its
        /// meetings from (Meetings.unconnected).
        var noCalendar = false
        /// What the tab's live folder says of it, or a folder's last
        /// reading of the same thing in another tab.
        var words: LiveWords?
        var item: LiveItem?
        var now = Date()
    }

    /// Over this, a tab says how much memory it takes, and offers Sleep.
    static let heavy: UInt64 = 1 << 30

    static func make(_ s: Signals) -> TabGist {
        var gist = TabGist()
        let pull = PullPage(s.address, label: s.label)
        if let pull {
            gist.title = pull.title
            gist.person = pull.author
            gist.facts = [pull.author, "#\(pull.number)"].compactMap { $0 }.joined(separator: " · ")
        } else if let item = s.item, item.key.hasPrefix("linear/") {
            let id = String(item.key.dropFirst("linear/".count))
            gist.person = item.person
            gist.facts = [item.person, id, item.group.isEmpty ? nil : item.group, item.due.map { "due " + day($0) }]
                .compactMap { $0 }.joined(separator: " · ")
        }

        // What could be lost.
        if s.draft {
            gist.now = Now(word: "Not sent", text: "typed on this page", tone: .you)
            return gist
        }
        if s.camera || s.microphone {
            let what = s.camera && s.microphone ? "camera and mic on" : s.camera ? "camera on" : "mic on"
            gist.now = Now(word: "On a call", text: what, tone: .you)
            return gist
        }
        if let deaf = s.deaf {
            gist.now = Now(word: "Not responding", text: span(s.now.timeIntervalSince(deaf)), tone: .wrong)
            gist.action = Action(label: "Reload", kind: .reload)
            return gist
        }
        // A calendar pin that can't say your next meeting: where to connect one.
        if s.noCalendar {
            gist.now = Now(word: nil, text: "No calendar connected", tone: .you)
            gist.action = Action(label: "Connect", kind: .connectCalendar)
            return gist
        }
        // A chat's answer: coming, or come and not opened.
        if let busy = s.busy {
            gist.now = Now(word: nil, text: s.busyWord + " · " + span(s.now.timeIntervalSince(busy)), tone: .going)
            return gist
        }
        if let done = s.done {
            gist.now = Now(word: s.doneWord, text: span(s.now.timeIntervalSince(done)) + " ago", tone: .you)
            return gist
        }
        // What waits for you on the site.
        if let words = s.words, words.needsYou {
            gist.now = said(words, item: s.item, now: s.now)
            if let pull { gist.action = pull.action(for: words) }
            return gist
        }
        // What is only going on.
        if let playing = s.playing {
            if s.streaming {
                gist.now = Now(word: nil, text: playing ? "Playing live" : "Paused", tone: .going)
            } else if s.duration > 0 {
                let left = max(0, s.duration - s.position)
                gist.now = Now(word: nil, text: (playing ? "Playing · " : "Paused · ") + clock(left) + " left", tone: .going)
            } else {
                gist.now = Now(word: nil, text: playing ? "Playing" : "Paused", tone: .going)
            }
            gist.action = Action(label: playing ? "Pause" : "Play", kind: playing ? .pause : .play)
            return gist
        }
        if let words = s.words {
            gist.now = said(words, item: s.item, now: s.now)
            return gist
        }
        if s.weight > heavy {
            gist.now = Now(word: nil, text: String(format: "Uses %.1f GB", Double(s.weight) / Double(1 << 30)), tone: .going)
            if s.canSleep { gist.action = Action(label: "Sleep", kind: .sleep) }
        }
        return gist
    }

    /// A live folder's word, in a line.
    private static func said(_ words: LiveWords, item: LiveItem?, now: Date) -> Now {
        switch words {
        case .failing: return Now(word: "Failing", text: "checks", tone: .wrong)
        case .review: return Now(word: "Review", text: "asked of you", tone: .you)
        case .changes: return Now(word: "Changes", text: "requested", tone: .you)
        case .ready: return Now(word: "Ready", text: "to merge", tone: .going)
        case .late:
            let late = item?.due.map { max(1, Int(now.timeIntervalSince($0) / 86_400)) }
            return Now(word: "Late", text: late.map { $0 == 1 ? "by a day" : "by \($0) days" } ?? "past its date", tone: .wrong)
        case .mention: return Now(word: "Mention", text: item?.quote.map { "“\($0)”" } ?? "you’re named here", tone: .you)
        case .comment: return Now(word: "Comment", text: item?.quote.map { "“\($0)”" } ?? "for you", tone: .you)
        case .request: return Now(word: "Request", text: "to see it", tone: .you)
        case .shared: return Now(word: "Shared", text: "with you", tone: .going)
        case .changed: return Now(word: "Changed", text: "since you looked", tone: .going)
        case .new: return Now(word: "New", text: item?.updated.map { "since " + ago($0, now: now) } ?? "for you", tone: .going)
        }
    }

    /// "40s", "3m", "1h".
    static func span(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }

    /// "17m", "1h 4m", "45s".
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let s = now.timeIntervalSince(date)
        if s < 3600 { return "\(max(1, Int(s / 60)))m ago" }
        if s < 86_400 { return "\(Int(s / 3600))h ago" }
        return day(date)
    }

    private static func day(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "MMM d"
        return format.string(from: date)
    }
}

extension TabGist {
    /// The card's for this tab now.
    @MainActor
    static func of(_ tab: Tab, at now: Date = Date()) -> TabGist {
        var s = Signals(address: tab.address, label: tab.label)
        s.draft = tab.draft
        s.camera = tab.camera != .none
        s.microphone = tab.microphone != .none
        s.deaf = tab.deaf
        s.busy = tab.chatBusy?.since
        s.busyWord = tab.chatBusy?.word ?? ""
        s.done = tab.chatDone?.at
        s.doneWord = tab.chatDone?.word ?? ""
        if let tune = tab.tune {
            s.playing = tune.playing
            s.position = tune.position()
            s.duration = tune.duration
            s.streaming = tune.live
        }
        s.weight = tab.weight
        s.canSleep = !tab.isBlank && tab.builtPage != nil
        s.noCalendar = tab.pin != nil && Meetings.isCalendar(tab.address) && Meetings.shared.unconnected
        s.item = LiveSeen.item(tab.live?.key ?? LiveText.thing(tab.address), news: tab.live?.news == true)
        s.words = tab.live?.words ?? s.item?.words
        s.now = now
        return make(s)
    }
}

/// A GitHub pull request's page, any of its pages, as its tab names it.
struct PullPage: Equatable {
    var base: URL
    var number: Int
    var title: String
    var author: String?

    init?(_ url: URL?, label: String) {
        guard let url, LiveFolder.key(url) != nil else { return nil }
        let parts = url.path.split(separator: "/")
        guard let number = Int(parts[3]), var root = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        root.path = "/" + parts[0...3].joined(separator: "/")
        root.query = nil
        root.fragment = nil
        guard let base = root.url else { return nil }
        self.base = base
        self.number = number
        title = LiveGitHub.shortTitle(label)
        // "Fix it by anna · Pull Request #12 · acme/yab · GitHub"
        if let by = label.range(of: #"\sby\s([^\s·]+)\s·\s(Pull Request|Pull request) #"#, options: .regularExpression) {
            let words = label[by].split(separator: " ")
            author = words.count > 1 ? String(words[1]) : nil
        }
    }

    /// Where the word sends you: the checks that failed, the files to read.
    func action(for words: LiveWords) -> TabGist.Action? {
        switch words {
        case .failing: return TabGist.Action(label: "Checks", kind: .open(base.appending(path: "checks")))
        case .review, .changes: return TabGist.Action(label: "Files", kind: .open(base.appending(path: "files")))
        default: return nil
        }
    }
}

/// The last thing each live folder read said, by the key of what it is, so
/// a tab showing the same thing has it, wherever the tab is.
@MainActor
enum LiveSeen {
    private(set) static var items: [String: LiveItem] = [:]
    /// What a new-for-you list of a to-do folder said (Linear's mentions),
    /// for the tab it brought: a thing both lists name has two sayings.
    private(set) static var heard: [String: LiveItem] = [:]

    static func note(_ read: [LiveItem], news lists: Set<String> = []) {
        for item in read {
            if lists.contains(item.list ?? "") { heard[item.key] = item } else { items[item.key] = item }
        }
    }

    /// The to-do saying first, unless the tab came from a new-for-you list.
    static func item(_ key: String?, news: Bool = false) -> LiveItem? {
        guard let key else { return nil }
        return news ? heard[key] ?? items[key] : items[key] ?? heard[key]
    }
}

extension LiveText {
    /// The key a live source gives the thing a page shows, any source's:
    /// a GitHub pull request or issue, a Linear issue, a Notion page, a
    /// Google file, a Figma file, a YouTube video.
    static func thing(_ url: URL?) -> String? {
        if let key = key(url) { return key }
        guard let url, let host = url.host()?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        switch host {
        case "linear.app":
            if let at = parts.firstIndex(of: "issue"), at + 1 < parts.count { return "linear/" + parts[at + 1].uppercased() }
        case "www.notion.so", "notion.so":
            if let last = parts.last, let id = notionID(last) { return "notion/" + id }
        case "docs.google.com", "drive.google.com":
            if let at = parts.firstIndex(of: "d"), at + 1 < parts.count { return "drive/" + parts[at + 1] }
        case "www.figma.com", "figma.com":
            if parts.count >= 2, ["file", "design", "board", "proto", "slides"].contains(parts[0]) { return "figma/" + parts[1] }
        case "www.youtube.com", "youtube.com", "m.youtube.com":
            if url.path == "/watch", let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value {
                return "youtube/" + id
            }
        default: break
        }
        return nil
    }

    /// The 32 hex digits a Notion address ends with, as Notion's own ids
    /// write them, with dashes.
    private static func notionID(_ last: String) -> String? {
        let hex = String(last.suffix(32)).lowercased()
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        let c = Array(hex)
        return [c[0..<8], c[8..<12], c[12..<16], c[16..<20], c[20..<32]].map { String($0) }.joined(separator: "-")
    }
}
