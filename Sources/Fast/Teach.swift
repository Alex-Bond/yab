import AppKit
import CryptoKit

// What yab can do, said at the moment it would have helped, and never again
// once you do it yourself.
//
// Kept on this Mac only, in its settings, like every other hint: what you
// have used, how often each thing was said and when. Nothing leaves it.
//
// Two kinds. A key after an act yab already answers in the corner: "Link
// copied" from a menu gets its ⇧⌘C, up to three times, until the key is
// pressed once. And a thing yab noticed you could do better, Peek after
// links opened and shut again, Split View after going back and forth, a
// space each for two accounts on one site: rare, one at a time, never in a
// session's first minutes or anyone's first day, never over typing, a call,
// an agent at work or a card, and gone for good once you use the thing.
// Settings › Tabs › "Suggestions under the field" silences these; the keys
// after an act stay, they only finish a notice already there.
//
// Prototype: https://claude.ai/artifact/4HMkJ8aMkwCm2aDShETyGy

@MainActor
final class Teach {
    static let shared = Teach()

    enum Lesson: String, CaseIterable {
        // A key after the act.
        case copyAddress, markdownLink, bookmark
        // Noticed.
        case peek, split, spaces

        /// How many times it may be said, ever.
        var most: Int {
            switch self {
            case .copyAddress, .markdownLink, .bookmark: return 3
            case .peek, .spaces: return 2
            case .split: return 3
            }
        }

        /// How long it waits before it may be said again.
        var again: TimeInterval {
            switch self {
            case .split: return Teach.day
            default: return 7 * Teach.day
            }
        }
    }

    static let day: TimeInterval = 24 * 60 * 60
    /// Between any two things noticed.
    static let apart: TimeInterval = 2 * day
    /// Nothing noticed this early in a session, or in anyone's first day.
    static let settling: TimeInterval = 10 * 60

    private let store = Store.settings
    private let launched = Date()
    /// For the bench: the waits off, so a lesson can be seen in a minute.
    /// What was used and how often it was said still count.
    var hurried = false

    private init() {
        if store.object(forKey: "teach.since") == nil { store.set(Date().timeIntervalSince1970, forKey: "teach.since") }
    }

    // MARK: - the ledger

    func uses(_ lesson: Lesson) -> Int { store.integer(forKey: "teach.used.\(lesson.rawValue)") }
    func told(_ lesson: Lesson) -> Int { store.integer(forKey: "teach.told.\(lesson.rawValue)") }
    private func toldAt(_ lesson: Lesson) -> Date? {
        (store.object(forKey: "teach.toldAt.\(lesson.rawValue)") as? Double).map(Date.init(timeIntervalSince1970:))
    }

    /// Done by hand, or by its key: nothing more to say about it.
    func used(_ lesson: Lesson) {
        store.set(uses(lesson) + 1, forKey: "teach.used.\(lesson.rawValue)")
    }

    private func say(_ lesson: Lesson) {
        let now = Date().timeIntervalSince1970
        store.set(told(lesson) + 1, forKey: "teach.told.\(lesson.rawValue)")
        store.set(now, forKey: "teach.toldAt.\(lesson.rawValue)")
        if ![.copyAddress, .markdownLink, .bookmark].contains(lesson) { store.set(now, forKey: "teach.last") }
    }

    /// Forgets everything, for the bench.
    func reset() {
        for key in store.dictionaryRepresentation().keys where key.hasPrefix("teach.") { store.removeObject(forKey: key) }
        store.set(Date().timeIntervalSince1970, forKey: "teach.since")
        quick = []
        switches = []
        waiting?.cancel()
    }

    var state: [String: Any] {
        var out: [String: Any] = ["hurried": hurried]
        for lesson in Lesson.allCases { out[lesson.rawValue] = ["used": uses(lesson), "told": told(lesson)] }
        out["quick"] = quick.count
        out["switches"] = switches.count
        return out
    }

    // MARK: - a key after the act

    /// The act done where nothing in the corner answers it: only its key
    /// is counted.
    func pressed(_ lesson: Lesson) {
        if NSApp.currentEvent?.type == .keyDown { used(lesson) }
    }

    /// The keys to set after a notice already on its way, "Link copied ⇧⌘C":
    /// only when the act came some other way than its key, and only until
    /// the key has been pressed once. The key pressed is counted here.
    func keys(after lesson: Lesson, action: Shortcut.Action) -> [String] {
        if NSApp.currentEvent?.type == .keyDown {
            used(lesson)
            return []
        }
        guard uses(lesson) == 0, told(lesson) < lesson.most, let caps = Keymap.shared.keys(action)?.caps else { return [] }
        say(lesson)
        return caps
    }

    // MARK: - noticed

    /// Whether a noticed thing may be said now.
    func may(_ lesson: Lesson, in browser: Browser) -> Bool {
        guard Hints.shared.suggesting, uses(lesson) == 0, told(lesson) < lesson.most else { return false }
        if lesson == .spaces, browser.prefs.usesSpaces { return false }
        if !hurried {
            let now = Date()
            let since = store.double(forKey: "teach.since")
            if now.timeIntervalSince1970 - since < Self.day { return false }
            if now.timeIntervalSince(launched) < Self.settling { return false }
            if now.timeIntervalSince1970 - store.double(forKey: "teach.last") < Self.apart { return false }
            if let at = toldAt(lesson), now.timeIntervalSince(at) < lesson.again { return false }
        }
        return quiet(browser)
    }

    /// Nothing else has the person's attention: no typing, no call, no
    /// agent at work in front of them, no card asking, nothing in the corner.
    private func quiet(_ browser: Browser) -> Bool {
        guard !browser.editing, !browser.toaster.shown, browser.calls.live.isEmpty, SpaceTray.shown == nil,
              let active = browser.active, !active.isBlank, active.worker == nil, active.offer == nil
        else { return false }
        return Links.window?.isKeyWindow == true
    }

    private func offer(_ lesson: Lesson, in browser: Browser, _ words: String, mark: String,
                       keys: [String] = [], act: String? = nil, doing: (() -> Void)? = nil) {
        say(lesson)
        browser.toaster.pop(words, mark: mark, keys: keys, undo: doing, act: act, feedback: .offer)
    }

    // Peek: a link opened in a tab of its own and shut again within
    // seconds, a third time in a day. Said once you are back on your page.

    static let glance: TimeInterval = 15
    private var quick: [Date] = []

    func shutSoon(in browser: Browser) {
        let now = Date()
        quick = quick.filter { now.timeIntervalSince($0) < Self.day } + [now]
        guard quick.count >= 3 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak browser] in
            guard let self, let browser, self.may(.peek, in: browser) else { return }
            self.quick = []
            self.offer(.peek, in: browser, "Peek at links with", mark: "eye", keys: ["⇧Click"])
        }
    }

    // Split View: back and forth between the same two tabs, four times in
    // a minute. The notice offers the pair itself.

    static let bounces = 4
    static let bouncing: TimeInterval = 60
    private var switches: [(pair: Set<Tab.ID>, at: Date)] = []

    func switched(from: Tab.ID?, to tab: Tab, in browser: Browser) {
        guard let from, from != tab.id else { return }
        let now = Date()
        let pair: Set<Tab.ID> = [from, tab.id]
        // Only the run of this one pair counts: going elsewhere starts over.
        if switches.last?.pair != pair { switches = [] }
        switches = switches.filter { now.timeIntervalSince($0.at) < Self.bouncing } + [(pair, now)]
        guard switches.count >= Self.bounces,
              let other = browser.tabs.first(where: { $0.id == from }),
              browser.canPair(other, tab), may(.split, in: browser)
        else { return }
        switches = []
        offer(.split, in: browser, "Both at once?", mark: "rectangle.split.2x1", act: "Split View") { [weak browser, weak other, weak tab] in
            guard let browser, let other, let tab else { return }
            browser.split(other, with: tab)
        }
    }

    // Spaces: a second account signed in to on the same site within a week,
    // with Spaces off. A space with its own sign-ins keeps both signed in.
    // The accounts are kept as short hashes, never the names.

    private var waiting: DispatchWorkItem?

    func signedIn(_ tab: Tab, host: String, user: String, in browser: Browser) {
        guard !browser.prefs.usesSpaces, !tab.shy, !tab.bench, !user.isEmpty, uses(.spaces) == 0, told(.spaces) < Lesson.spaces.most else { return }
        let site = Browser.site(host)
        let now = Date().timeIntervalSince1970
        let who = SHA256.hash(data: Data((site + "\u{0}" + user.lowercased()).utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        var sites = store.dictionary(forKey: "teach.accounts") as? [String: [String: Double]] ?? [:]
        var seen = (sites[site] ?? [:]).filter { now - $0.value < 7 * Self.day }
        seen[who] = now
        sites[site] = seen
        sites = sites.filter { !$0.value.isEmpty && $0.value.values.contains { now - $0 < 7 * Self.day } }
        store.set(sites, forKey: "teach.accounts")
        guard seen.count >= 2 else { return }
        // The page is still signing in, and the password card may be up:
        // said once the tab is quiet, or not at all.
        waitForQuiet(tries: 30, in: browser) { [weak self, weak browser] in
            guard let self, let browser else { return }
            self.offer(.spaces, in: browser, "Two accounts here? One space each", mark: "person.2", act: "Set Up") { [weak browser] in
                guard let browser else { return }
                browser.prefs.usesSpaces = true
                // The spaces' capsule comes with the next layout: the tray
                // opens from it, its own sign-ins already chosen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { SpaceTray.open(browser, ownSignIns: true) }
            }
        }
    }

    private func waitForQuiet(tries: Int, in browser: Browser, _ then: @escaping () -> Void) {
        waiting?.cancel()
        let work = DispatchWorkItem { [weak self, weak browser] in
            guard let self, let browser else { return }
            if self.may(.spaces, in: browser) { then() }
            else if tries > 1 { self.waitForQuiet(tries: tries - 1, in: browser, then) }
        }
        waiting = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}
