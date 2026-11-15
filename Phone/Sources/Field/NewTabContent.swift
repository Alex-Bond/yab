import Foundation
#if canImport(SyncKit)
import SyncKit
#endif

/// What New Tab offers before a word is typed: Now (a link on the clipboard,
/// what a brief found, the tab in front on the Mac), Recent Tabs, Frequent.
/// Until the iPhone has history and sync (M7) it comes from the world: mira
/// has the prototype's rows, any other world what its own tabs suggest.
struct NewTabItem: Identifiable, Equatable {
    enum Action: Equatable {
        /// Paste and Go: the link on the clipboard, in a new tab.
        case paste
        /// A page in a new tab.
        case open(Tab)
        /// A tab already open.
        case go(Tab.ID)
        /// Words searched again.
        case search(String)
        /// The tab just closed, back as it was.
        case reopen(UUID)
    }

    var id: String
    var icon: WordRow.Icon
    var title: String
    var subtitle: String
    var action: Action
    /// The site a suggestion may be removed by.
    var removable: String? = nil
}

extension NewTabItem {
    /// The page the row leads to, for its icon.
    var pageURL: URL? {
        if case let .open(tab) = action { return tab.navigationURL }
        if case let .favicon(_, host) = icon, let host { return URL(string: "https://" + host) }
        return nil
    }
}

struct NewTabContent: Equatable {
    var now: [NewTabItem]
    var recent: [NewTabItem]
    /// Frequent: the first five show.
    var frequent: [SiteCandidate]
    /// The search sheet's rows, where a profile has made them (Suggestions).
    var picks: [NewTabItem]? = nil

    var sheetRows: [NewTabItem] { picks ?? recent }

    static let frequentShown = 5
    /// How long a closed tab stands on the sheet.
    static let closedShown: TimeInterval = 120

    /// The prototype's Frequent, its eight sites.
    static let miraSites: [SiteCandidate] = [
        SiteCandidate(key: "daybook", name: "Daybook", host: "daybook.app"),
        SiteCandidate(key: "linear", name: "Linear", host: "linear.app"),
        SiteCandidate(key: "slack", name: "Slack", host: "slack.com"),
        SiteCandidate(key: "figma", name: "Figma", host: "figma.com"),
        SiteCandidate(key: "lumen", name: "Lumen", host: "lumen.events"),
        SiteCandidate(key: "nordbutik", name: "Nordbutik", host: "nordbutik.se"),
        SiteCandidate(key: "ledger", name: "Ledger", host: "ledger.app"),
        SiteCandidate(key: "github", name: "GitHub", host: "github.com"),
    ]

    /// What New Tab's content was made from: cheap to read and compare, so
    /// a draw that finds it unchanged takes the content made before. The
    /// field's draw, its rows, its key and the sheet's height all ask for
    /// the content; making it again for each (every tab scanned per row,
    /// History weighed for the picks) kept the main thread busy at launch
    /// until iOS ended Yab (crash reports of 0.1.33 to 0.1.37).
    struct Inputs: Equatable {
        var browser: Int
        var profile: ObjectIdentifier?
        var visits: Int
        var clipboard: URL?
        var macURL: String?
        var macTitle: String?
        var macTab: String?
        var macSpace: String?
        var macAwake: Bool
        var closed: UUID?
        var picks: Int
        var engine: String
        var engineURL: String?
        var fixtures: Bool
        var world: String
    }

    /// How many times the content was made, for tests.
    @MainActor private(set) static var builds = 0

    @MainActor
    static func make(for app: AppModel) -> NewTabContent {
        // Named states' picks are made from a history of their own, once.
        if app.field.fixturePicks != nil { return build(app) }
        let inputs = inputs(app)
        if let memo = app.field.newTabMemo, memo.inputs == inputs { return memo.content }
        let content = build(app)
        app.field.newTabMemo = (inputs, content)
        return content
    }

    @MainActor
    static func inputs(_ app: AppModel) -> Inputs {
        let front = (app.sync.awakeMac ?? app.sync.macs.first)?.front
        let selection = app.field.searchSettings.searchSelection
        return Inputs(browser: app.browser.revision, profile: app.profile.map(ObjectIdentifier.init), visits: app.profile?.visitsRevision ?? 0,
                      clipboard: app.field.clipboardLink, macURL: front?.url, macTitle: front?.title, macTab: front?.tab, macSpace: front?.tab.flatMap { app.sync.spaceOfMacTab($0) }, macAwake: app.sync.awakeMac != nil,
                      closed: recentlyClosed(app)?.id, picks: app.field.picksRevision, engine: selection.name,
                      engineURL: selection.url(for: "yab")?.absoluteString, fixtures: app.fixturesEnabled, world: app.world.name)
    }

    @MainActor
    private static func build(_ app: AppModel) -> NewTabContent {
        builds += 1
        let paste = app.field.clipboardLink.map { _ in
            NewTabItem(id: "paste", icon: .clipboard, title: "Paste and Go", subtitle: "A link is on the clipboard", action: .paste)
        }
        if !app.fixturesEnabled { return live(app, paste: paste) }
        if let input = app.field.fixturePicks {
            return NewTabContent(now: [], recent: [], frequent: [],
                                 picks: Suggestions.make(input).map { item($0, app: app, engine: "Google") })
        }
        if app.world.name == "mira" { return mira(app, paste: paste) }
        var now = paste.map { [$0] } ?? []
        if let mac = macNow(app) { now.append(mac) }
        let space = app.browser.space
        let recent = space.today.filter { $0.id != app.browser.tab?.id && !$0.isPrivate }.prefix(2).map {
            NewTabItem(id: "recent-" + $0.id, icon: .favicon(key: $0.icon, host: $0.host), title: $0.short,
                       subtitle: "\(space.name) · today", action: .go($0.id))
        }
        let sites = space.visiblePins.map { SiteCandidate(key: $0.icon, name: $0.site, host: $0.addressHost) }
        return NewTabContent(now: now, recent: Array(recent), frequent: sites)
    }

    /// The tab just closed, while the sheet still offers it back.
    @MainActor
    private static func recentlyClosed(_ app: AppModel) -> ClosedTab? {
        app.backStack.closed.flatMap { closed -> ClosedTab? in
            let recent = Date().timeIntervalSince(closed.at) < closedShown
            return recent && !closed.tab.isPrivate && app.browser.space(closed.space)?.isPrivate == false ? closed : nil
        }
    }

    /// Now's tab in front on a Mac. One this iPhone shows (a pin, a kept
    /// tab) is gone to; one of the Mac's own today, which this iPhone keeps
    /// out (docs/sync.md, "Today is each device's own"), opens as a copy
    /// here, from what the Mac's presence says of it.
    /// Only for the space that tab is in on the Mac (row 2603): a space with
    /// sign-ins of its own is another profile, and the page opened in the
    /// wrong one is signed in as somebody else. Made once and handed to
    /// every space's page, it offered the Mac's tab in each of them.
    @MainActor
    static func macNow(_ app: AppModel, in requested: Space.ID? = nil) -> NewTabItem? {
        let space = requested ?? app.browser.spaceID
        guard app.browser.space(space)?.isPrivate == false else { return nil }
        let subtitle = "On your Mac now · open here"
        if let mac = app.browser.onMac, !mac.isPrivate, app.browser.space(holding: mac.id)?.id == space {
            return NewTabItem(id: "mac", icon: .favicon(key: mac.icon, host: mac.host), title: mac.short, subtitle: subtitle, action: .go(mac.id))
        }
        guard let front = (app.sync.awakeMac ?? app.sync.macs.first)?.front,
              let url = front.url, !url.isEmpty else { return nil }
        // Only a Mac tab known to be in another space stays out: an older Mac's
        // presence names no tab, and a new iPhone may not have its record yet.
        if let id = front.tab, let owner = app.sync.spaceOfMacTab(id), owner != space { return nil }
        if let here = app.browser.space(space)?.allTabs.first(where: { !$0.isPrivate && $0.navigationURL?.absoluteString == url }) {
            return NewTabItem(id: "mac", icon: .favicon(key: here.icon, host: here.host), title: here.short, subtitle: subtitle, action: .go(here.id))
        }
        let copy = SyncMapping.tab(SyncTab(space: "", url: url, title: front.title ?? ""), id: PageFixtures.newID(), old: nil,
                                   fixturesEnabled: app.fixturesEnabled)
        return NewTabItem(id: "mac", icon: .favicon(key: copy.icon, host: copy.host), title: copy.short, subtitle: subtitle, action: .open(copy))
    }

    /// Recent and Frequent come from successful visits in this profile,
    /// never a fixture world and never a private page.
    @MainActor
    private static func live(_ app: AppModel, paste: NewTabItem?) -> NewTabContent {
        var now = paste.map { [$0] } ?? []
        if let mac = macNow(app) { now.append(mac) }
        let current = app.browser.tab?.navigationURL?.absoluteString
        // Two addresses of one page (www, a query) read as the same row twice: the newest stands for both.
        var seen = Set<String>()
        let visits = (app.profile?.recent ?? []).filter { $0.url != current && seen.insert(($0.title + "|" + $0.site).lowercased()).inserted }
        let shown = visits.prefix(Metrics.SearchSheet.rows)
        let open = openTabs(app, at: Set(shown.map(\.url)))
        let recent = shown.enumerated().compactMap { index, visit -> NewTabItem? in
            guard let url = URL(string: visit.url) else { return nil }
            let existing = app.browser.openTab(at: visit.url)
            let action: NewTabItem.Action = existing.map { .go($0.id) }
                ?? .open(PageFixtures.liveTab(for: url, title: visit.title))
            return NewTabItem(id: "recent-\(index)", icon: .favicon(key: visit.icon, host: visit.host),
                              title: visit.title, subtitle: visit.site, action: action)
        }
        return NewTabContent(now: now, recent: recent, frequent: liveFrequent(app), picks: picks(app, now: now))
    }

    /// The first tab that isn't private open at each of `addresses`, in one
    /// walk of every tab: an address is worked out from each tab's words
    /// (Tab.navigationURL), and a walk for each recent row was what an iPad
    /// with many tabs spent its launch on (#546, #548, #561).
    @MainActor
    private static func openTabs(_ app: AppModel, at addresses: Set<String>) -> [String: Tab.ID] {
        var found: [String: Tab.ID] = [:]
        guard !addresses.isEmpty else { return found }
        for tab in app.browser.allTabs where !tab.isPrivate {
            guard let address = tab.navigationURL?.absoluteString, addresses.contains(address),
                  found[address] == nil else { continue }
            found[address] = tab.id
            if found.count == addresses.count { break }
        }
        return found
    }

    /// Frequent alone, for what needs only the sites (the field's rows):
    /// without the recent rows, Now and the picks New Tab also makes.
    @MainActor
    static func frequent(for app: AppModel) -> [SiteCandidate] {
        app.fixturesEnabled ? make(for: app).frequent : liveFrequent(app)
    }

    @MainActor
    private static func liveFrequent(_ app: AppModel) -> [SiteCandidate] {
        (app.profile?.frequent ?? []).compactMap { visit -> SiteCandidate? in
            guard var parts = URLComponents(string: visit.url) else { return nil }
            parts.path = ""
            parts.query = nil
            parts.fragment = nil
            parts.user = nil
            parts.password = nil
            guard let origin = parts.url else { return nil }
            return SiteCandidate(key: visit.icon, name: visit.site, host: origin.absoluteString)
        }
    }

    /// The sheet's rows, made once as the field opens: they don't shift under
    /// a finger. What matters this moment first, then Suggestions.
    @MainActor
    private static func picks(_ app: AppModel, now: [NewTabItem]) -> [NewTabItem] {
        let closed = recentlyClosed(app)
        let key = [app.field.clipboardLink?.absoluteString, closed?.id.uuidString, String(app.field.picksRevision)]
            .map { $0 ?? "" }.joined(separator: "|")
        if let held = app.field.heldPicks, held.key == key { return held.items }
        let moment = now.first { $0.id == "paste" }
            ?? (app.sync.awakeMac != nil ? now.first { $0.id == "mac" } : nil)
            ?? closed.map { closed in
                NewTabItem(id: "closed", icon: .favicon(key: closed.tab.icon, host: closed.tab.host), title: closed.tab.title,
                           subtitle: "Just closed", action: .reopen(closed.id))
            }
        let selection = app.field.searchSettings.searchSelection
        var removed = SuggestionMemory.removed
        if let shown = moment?.pageURL.map(Suggestions.bare) { removed.insert(shown) }
        let hour = Calendar.current.component(.hour, from: Date())
        let made = Suggestions.make(Suggestions.Input(
            visits: app.profile?.recent ?? [], places: Array(app.history.synced.values), own: app.history.ownDevice,
            current: app.browser.tab?.navigationURL?.absoluteString,
            engineHost: selection.url(for: "yab").map(Suggestions.bare), removed: removed, shown: SuggestionMemory.shown,
            now: Date(), hour: hour, limit: Metrics.SearchSheet.rows - (moment == nil ? 0 : 1)))
        // Counted after this draw: a view's body writes nothing to disk.
        if app.field.heldPicks == nil {
            let hosts = made.filter { $0.kind == .site }.map(\.host)
            Task { @MainActor in SuggestionMemory.count(hosts) }
        }
        let items = (moment.map { [$0] } ?? []) + made.map { item($0, app: app, engine: selection.name) }
        app.field.heldPicks = (key, items)
        return items
    }

    @MainActor
    private static func item(_ pick: Suggestions.Pick, app: AppModel, engine: String) -> NewTabItem {
        if case let .search(words) = pick.kind {
            return NewTabItem(id: "pick-search", icon: .magnifier, title: words, subtitle: "Search \(engine)", action: .search(words))
        }
        let page = URL(string: pick.url).map { PageFixtures.liveTab(for: $0, title: pick.title) }
        let open = app.browser.openTab(at: pick.url)
        let action: NewTabItem.Action = open.map { .go($0.id) } ?? page.map { .open($0) } ?? .paste
        return NewTabItem(id: "pick-" + pick.host, icon: .favicon(key: page?.icon ?? pick.host, host: pick.host), title: pick.title,
                          subtitle: pick.host, action: action, removable: pick.host)
    }

    /// Mira's New Tab, the prototype's (world.md, "New Tab content").
    @MainActor
    private static func mira(_ app: AppModel, paste: NewTabItem?) -> NewTabContent {
        var now = paste.map { [$0] } ?? []
        let flights = Tab(id: "brief-flights", title: "Stockholm to Lisbon · Flights", site: "Google Flights", icon: "google",
                          url: "google.com/travel/flights?q=ARN-LIS", page: "flights", host: "google.com")
        now.append(NewTabItem(id: "brief", icon: .favicon(key: "google", host: "google.com"),
                              title: "Lisbon: the stay is booked, the flights aren’t",
                              subtitle: "Morning brief · direct flights are filling up", action: .open(flights)))
        if app.browser.tab("work-launch-notes") != nil {
            now.append(NewTabItem(id: "mac", icon: .favicon(key: "paper", host: "paper.so"), title: "Launch notes · Tern 2.0",
                                  subtitle: "On your Mac now · open here", action: .go("work-launch-notes")))
        }
        var recent: [NewTabItem] = []
        if app.browser.tab("work-hn") != nil {
            recent.append(NewTabItem(id: "recent-hn", icon: .favicon(key: "hn", host: nil), title: "Hacker News",
                                     subtitle: "Work · 15 min ago", action: .go("work-hn")))
        }
        if app.browser.tab("work-ledger") != nil {
            recent.append(NewTabItem(id: "recent-ledger", icon: .favicon(key: "ledger", host: nil), title: "Overview · Ledger",
                                     subtitle: "Work · 4 h ago", action: .go("work-ledger")))
        }
        return NewTabContent(now: now, recent: recent, frequent: miraSites)
    }
}
