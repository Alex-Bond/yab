import Foundation

// A page the blocker broke. Someone reloading the same site three times in
// twenty seconds, on a page the blocker took something off, is most likely
// looking at a player that won't start or a checkout that won't finish: the
// corner asks "Page not working?" and offers "Allow Ads Here", Shield's own
// pause for the site (the switch in Site Controls), and the page loads again
// without the lists. DuckDuckGo's Mac browser counts reloads the same way
// (PageRefreshMonitor) and holds its prompt back the same way.
//
// Once a visit to a site at most. Let go three times in a row, it keeps
// quiet for a week. Only reloads you asked for count, ⌘R and the button,
// never a page reloading itself, and they are counted in memory only.

/// Your reloads of one site in a tab.
struct ReloadWatch: Equatable {
    static let reloads = 3
    static let window: TimeInterval = 20

    private(set) var site: String?
    private(set) var stamps: [Date] = []
    /// The corner asked on this visit already.
    var asked = false

    /// The tab is on `site` now: another site is another visit, counted from
    /// nothing.
    mutating func visit(_ site: String?) {
        guard site != self.site else { return }
        self = ReloadWatch()
        self.site = site
    }

    /// You reloaded `site` at `now`: whether that makes three inside the
    /// window, this one included.
    mutating func reloaded(_ site: String, at now: Date) -> Bool {
        visit(site)
        stamps = stamps.filter { now.timeIntervalSince($0) < Self.window } + [now]
        return stamps.count >= Self.reloads
    }

    /// Asked: counted again from nothing, should it come to that.
    mutating func ask() {
        asked = true
        stamps = []
    }
}

/// How often the corner may ask, whatever the site: an offer let go three
/// times in a row keeps it quiet for a week. Each one shown counts as let go
/// until its button is pressed.
struct UnbreakLimit: Equatable, Codable {
    static let streak = 3
    static let quiet: TimeInterval = 7 * 86_400

    private(set) var ignored = 0
    private(set) var quietUntil: Date?

    func allows(at now: Date) -> Bool { quietUntil.map { now >= $0 } ?? true }

    mutating func shown(at now: Date) {
        if let until = quietUntil, now >= until { quietUntil = nil }
        ignored += 1
        if ignored >= Self.streak {
            quietUntil = now.addingTimeInterval(Self.quiet)
            ignored = 0
        }
    }

    /// "Allow Ads Here" pressed: the streak is broken.
    mutating func taken() {
        ignored = 0
        quietUntil = nil
    }
}

@MainActor
final class Unbreak {
    static let shared = Unbreak()

    static let words = "Page not working?"
    static let act = "Allow Ads Here"

    /// The clock, handed in by tests.
    var now: () -> Date = Date.init

    private var watches: [Tab.ID: ReloadWatch] = [:]
    /// The page each tab's blocker last took something off, by its address
    /// less any fragment: a reload is the same page, a link another.
    private var blockedOn: [Tab.ID: String] = [:]

    private static let key = "unbreak.limit"

    var limit: UnbreakLimit {
        get { Store.settings.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(UnbreakLimit.self, from: $0) } ?? UnbreakLimit() }
        set { Store.settings.set(try? JSONEncoder().encode(newValue), forKey: Self.key) }
    }

    nonisolated static func page(_ url: URL?) -> String? {
        guard let url else { return nil }
        let whole = url.absoluteString
        return whole.split(separator: "#", maxSplits: 1).first.map(String.init) ?? whole
    }

    /// The blocker kept something from this tab's page.
    func blocked(_ tab: Tab, on url: URL?) {
        guard let page = Self.page(url), blockedOn[tab.id] != page else { return }
        blockedOn[tab.id] = page
    }

    /// Whether the blocker kept something from the page the tab shows now.
    func blockedPage(_ tab: Tab, at url: URL?) -> Bool {
        Self.page(url).map { blockedOn[tab.id] == $0 } ?? false
    }

    /// A new page in the tab: what was kept from the last one is forgotten,
    /// unless it is the same page again, and another site is a new visit.
    func committed(_ tab: Tab, at url: URL?) {
        if let page = blockedOn[tab.id], page != Self.page(url) { blockedOn[tab.id] = nil }
        guard var watch = watches[tab.id] else { return }
        watch.visit(WindowGate.site(of: url))
        watches[tab.id] = watch
    }

    /// You reloaded the tab. The third time in the window, on a page the
    /// blocker took something off, with the blocker on for the site: asked.
    func reloaded(_ tab: Tab, in browser: Browser) {
        guard !tab.bench, let url = tab.builtPage?.url ?? tab.address, let site = WindowGate.site(of: url) else { return }
        let now = self.now()
        var watch = watches[tab.id] ?? ReloadWatch()
        let three = watch.reloaded(site, at: now)
        defer { watches[tab.id] = watch }
        guard three, !watch.asked, blockedPage(tab, at: url),
              browser.prefs.shielded, Shield.shared.trouble == nil, !Shield.shared.isPaused(on: site)
        else { return }
        var limit = self.limit
        guard limit.allows(at: now) else { return }
        watch.ask()
        limit.shown(at: now)
        self.limit = limit
        browser.toaster.pop(Self.words, mark: "shield", undo: { [weak self, weak browser, weak tab] in
            self?.taken()
            guard let browser, let tab else { return }
            browser.pauseShield(site, true)
            browser.reloadForChange(tab, .blocking)
        }, act: Self.act)
    }

    private func taken() {
        var limit = self.limit
        limit.taken()
        self.limit = limit
    }
}
