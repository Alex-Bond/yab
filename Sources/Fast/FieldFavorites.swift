import Foundation

// Favorites in ⌘T's field, kept in its root (feedback #67):
// ⇧⌘F on a row keeps it under Favorites in the empty field, right after
// Now, in your order (⌥⌘↑ and ⌥⌘↓ move it), until ⇧⌘F again takes it out.
// A place of the field's own, a page, a Quick Action, a command or a page of
// Settings; nothing there only for now (Now's rows, a sum, a clip, an
// answer, the page's own actions under ⌘L). Kept in the settings under one
// key, so Sync carries the list as it carries any setting (SyncShapes).

/// A row kept among Favorites, by what it is rather than where it was.
struct FieldFavorite: Equatable {
    /// "place:history", "page:https://github.com/", "quick:new-document",
    /// "do:privateTab", "set:appearance".
    let id: String
    /// What a page was called when it was kept: its name in the list,
    /// whatever its tab or the history call it since. Empty for the rest,
    /// whose names are their own.
    var name = ""

    enum What: Equatable {
        case place(FieldPlace), page(URL), quickAction(String), command(Command), setting(SettingsPage), menuTarget(String)
    }

    var what: What? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        let rest = String(id[id.index(after: colon)...])
        switch id[..<colon] {
        case "place": return FieldPlace(rawValue: rest).map(What.place)
        case "page": return URL(string: rest).map(What.page)
        case "quick": return .quickAction(rest)
        case "do": return Command(rawValue: rest).map { What.command($0.kept) }
        case "set": return SettingsPage(rawValue: rest).map(What.setting)
        case "menu": return .menuTarget(rest)
        default: return nil
        }
    }

    /// What two favorites are one by: a page by its address as the field
    /// writes it, port, query and all, without the scheme or www, so
    /// http://github.com and https://www.github.com/ are the same page; a
    /// command by its pair (Command.kept).
    var same: String {
        switch what {
        case .page(let url)?: return "page:" + Self.page(url)
        case .command(let command)?: return "do:" + command.rawValue
        default: return id
        }
    }

    /// Only the host is any case: a path, a query or a fragment can be an
    /// id that tells pages apart by case alone (a video's, a document's).
    static func page(_ url: URL) -> String {
        let whole = Address.whole(url)
        guard url.host() != nil else { return whole }
        let end = whole.firstIndex { "/?#".contains($0) } ?? whole.endIndex
        var host = whole[..<end].lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host + whole[end...]
    }

    /// The favorite a row of the field would be; nil for one there only
    /// for now, or that names nothing lasting. An open tab is its page.
    @MainActor static func of(_ offer: Suggestion) -> FieldFavorite? {
        if let id = offer.menuTargetID { return FieldFavorite(id: "menu:" + id) }
        switch offer.kind {
        case .place(let place):
            return place.keeps ? FieldFavorite(id: "place:" + place.rawValue) : nil
        case .open, .visited, .known, .address:
            guard let url = offer.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return FieldFavorite(id: "page:" + url.absoluteString, name: name(of: offer, at: url))
        case .quickAction(let id):
            return QuickActions.shared.action(id) == nil ? nil : FieldFavorite(id: "quick:" + id)
        case .command(let command):
            // Not New Tab, which ⌘T's field already is, or Make Yab the
            // Default Browser, gone for good once done.
            guard command != .newTab, command != .makeDefault else { return nil }
            return FieldFavorite(id: "do:" + command.kept.rawValue)
        case .setting(let page):
            return FieldFavorite(id: "set:" + page.rawValue)
        default:
            return nil
        }
    }

    /// A page row's own name: its key where that is the page's title (an
    /// open tab's, Frequent's), else its title (what typed words find,
    /// whose key is the address). Nothing when it has only its address.
    private static func name(of offer: Suggestion, at url: URL) -> String {
        let address: Set<String> = [Address.pretty(url).lowercased(), Address.pretty(url, port: true).lowercased(), page(url)]
        if offer.kind != .known, !offer.key.isEmpty, !address.contains(offer.key.lowercased()) { return offer.key }
        return address.contains(offer.title.lowercased()) ? "" : offer.title
    }
}

extension Command {
    /// The commands offered only in the state they change (Query.swift),
    /// each under the name of what it would do: a favorite keeps a pair as
    /// one, its row the half there to do now, so Hide Sidebar run from
    /// Favorites is Show Sidebar there next time rather than gone.
    static let pairs: [(Command, Command)] = [(.showBar, .hideBar), (.showShelf, .hideShelf), (.showSidebar, .hideSidebar),
                                              (.showStrip, .hideStrip), (.newYork, .sanFrancisco), (.devModeOn, .devModeOff), (.pinTab, .unpinTab),
                                              (.checkUpdates, .restartUpdate), (.splitView, .separate), (.jsonText, .jsonTree),
                                              (.hideSiteButtons, .showSiteButtons), (.showFullURL, .showSiteURL),
                                              (.muteTab, .unmuteTab), (.muteSite, .unmuteSite),
                                              (.keepSiteAwake, .allowSiteSleep), (.keepTab, .releaseTab),
                                              (.fullScreen, .exitFullScreen), (.measurePage, .hideRulers), (.showChat, .hideChat),
                                              (.customizationOn, .customizationOff), (.hideAIRows, .showAIRows)]

    /// What a favorite keeps it as: its pair's first half, or itself.
    var kept: Command {
        if self == .showOriginalPage || self == .stopTranslation { return .translatePage }
        return Self.pairs.first { $0.1 == self }?.0 ?? self
    }

    /// Its pair's two halves, the one kept first; itself alone for the rest.
    var halves: [Command] {
        if kept == .translatePage { return [.translatePage, .showOriginalPage, .stopTranslation] }
        return Self.pairs.first { $0.0 == kept }.map { [$0.0, $0.1] } ?? [self]
    }
}

/// The favorites, in your order, kept in the settings.
@MainActor
final class FieldFavorites {
    static let shared = FieldFavorites()
    static let key = "field.favorites"

    let defaults: UserDefaults

    init(defaults: UserDefaults = Store.settings) {
        self.defaults = defaults
    }

    /// Each as {"id", "name"}, the name left out where it has none; once
    /// there were some, an empty list rather than none, so taking the last
    /// one out reaches the other Macs too.
    var all: [FieldFavorite] {
        get {
            (defaults.array(forKey: Self.key) ?? []).compactMap { item in
                guard let entry = item as? [String: Any], let id = entry["id"] as? String else { return nil }
                return FieldFavorite(id: id, name: entry["name"] as? String ?? "")
            }
        }
        set {
            var seen = Set<String>()
            let list = newValue.filter { seen.insert($0.same).inserted }
            defaults.set(list.map { $0.name.isEmpty ? ["id": $0.id] : ["id": $0.id, "name": $0.name] }, forKey: Self.key)
        }
    }

    func has(_ favorite: FieldFavorite) -> Bool {
        all.contains { $0.same == favorite.same }
    }

    /// Kept, last, or taken out if it is kept already. True when kept.
    @discardableResult
    func toggle(_ favorite: FieldFavorite) -> Bool {
        var list = all
        if let at = list.firstIndex(where: { $0.same == favorite.same }) {
            list.remove(at: at)
            all = list
            return false
        }
        list.append(favorite)
        all = list
        return true
    }

    /// One place up (-1) or down (1) among `shown`, the favorites the
    /// empty field lists now, by `same`: one it can't list at the moment
    /// (Mail off, a command with nothing to do here) is stepped over
    /// rather than swapped with unseen. False when there is nowhere to go.
    @discardableResult
    func move(_ favorite: FieldFavorite, by step: Int, among shown: [String]? = nil) -> Bool {
        var list = all
        let order = shown ?? list.map(\.same)
        guard let at = list.firstIndex(where: { $0.same == favorite.same }),
              let spot = order.firstIndex(of: favorite.same), order.indices.contains(spot + step),
              list.contains(where: { $0.same == order[spot + step] }) else { return false }
        let moved = list.remove(at: at)
        guard let other = list.firstIndex(where: { $0.same == order[spot + step] }) else { return false }
        list.insert(moved, at: step < 0 ? other : other + 1)
        all = list
        return true
    }
}

extension Browser {
    /// Favorites as the empty field lists them, in your order, each as the
    /// row it is anywhere else, so ↩, ⌘↩ and ⌥↩ take it as they take that
    /// row: a place goes in as its name and Tab do, a page open in a tab
    /// here is that tab, switched to. One that can't be listed now waits
    /// unlisted: Mail before an account is in, a command with nothing to do
    /// here, a Quick Action turned off.
    func favoriteRows(now: Date) -> [Suggestion] {
        favorites.all.compactMap { favoriteRow($0, now: now) }
    }

    private func favoriteRow(_ favorite: FieldFavorite, now: Date) -> Suggestion? {
        switch favorite.what {
        case .place(let place)?:
            guard place.keeps, place.offered else { return nil }
            // Downloads says what is coming in, as Now's row would have.
            let detail = place == .downloads ? downloadNews(now: now) ?? placeDetail(place) : placeDetail(place)
            return Suggestion(key: place.title, title: detail, url: nil, kind: .place(place), favorite: true)
        case .page(let url)?:
            let name = favorite.name.isEmpty ? history.title(of: url) ?? Address.pretty(url) : favorite.name
            let page = FieldFavorite.page(url)
            // Split View's field: only a tab that can go beside the page.
            // Never a private tab: one kept is a page of yours, not of one.
            let open = tabs.filter { $0.id != activeID && !$0.isBlank && !$0.bench && !$0.shy && $0.address.map(FieldFavorite.page) == page }
                .filter { asked != .split || splitTakes($0) }
                .max { $0.touched < $1.touched }
            if let open, let address = open.address {
                return Suggestion(key: name, title: Tab.place(address), url: address, kind: .open, tab: open.id, favorite: true)
            }
            return Suggestion(key: name, title: Address.pretty(url), url: url, kind: .visited, favorite: true)
        case .quickAction(let id)?:
            guard let action = QuickActions.shared.action(id), action.enabled, let url = action.destination else { return nil }
            return Suggestion(key: action.name, title: action.host, url: url, kind: .quickAction(id), favorite: true)
        case .command(let pair)?:
            guard let command = pair.halves.first(where: { $0.available(in: self) }) else { return nil }
            return Suggestion(key: command.title(in: self), title: command.keys, url: nil, kind: .command(command), favorite: true)
        case .setting(let page)?:
            return Suggestion(key: page.title, title: "Settings", url: nil, kind: .setting(page), favorite: true)
        case .menuTarget(let id)?:
            guard let target = MenuCommands.targets(in: self).first(where: { $0.id == id }) else { return nil }
            var row = target.offer
            row.favorite = true
            return row
        case nil:
            return nil
        }
    }

    /// The favorites the field lists now, in order, by `same`.
    private var shownFavorites: [String] {
        offers.filter(\.favorite).compactMap { FieldFavorite.of($0)?.same }
    }

    /// ⇧⌘F's action for a row that can be a favorite, and on one under
    /// Favorites ⌥⌘↑'s and ⌥⌘↓'s where it can go, before what takes
    /// something away (Close Tab, Remove). A page kept is not
    /// one to forget from here: its row has no Forget. Nothing from a
    /// private tab: not from the field over one, whose empty field lists
    /// none, nor a private tab's row in Recent Tabs, whose page and name
    /// would be kept and go to the other Macs.
    func favoriting(_ offer: Suggestion, _ actions: [FieldAction]) -> [FieldAction] {
        guard !privateBrowsing, !shyRow(offer), let favorite = FieldFavorite.of(offer) else { return actions }
        var out = offer.favorite ? actions.filter { $0.id != "forget" } : actions
        var own = [FieldAction(id: "favorite", title: favorites.has(favorite) ? "Remove from Favorites" : "Add to Favorites",
                               keys: Keymap.shared.text(.fieldFavorite), symbol: favorites.has(favorite) ? "yab.star.minus" : "star", group: 2) {
            let kept = self.favorites.toggle(favorite)
            // Where no row moves (typed words' rows, History's or Bookmarks'
            // list), the corner says it, or a second press would undo the
            // first unseen.
            if !self.settleFavorites(favorite) {
                self.announce(kept ? "Added to Favorites" : "Removed from Favorites", mark: "star")
            }
        }]
        let shown = shownFavorites
        if offer.favorite, let spot = shown.firstIndex(of: favorite.same) {
            if spot > 0 {
                own.append(FieldAction(id: "moveup", title: "Move Up", keys: Keymap.shared.text(.fieldFavoriteUp), symbol: "yab.up", group: 2) {
                    if self.favorites.move(favorite, by: -1, among: shown) { self.settleFavorites(favorite) }
                })
            }
            if spot < shown.count - 1 {
                own.append(FieldAction(id: "movedown", title: "Move Down", keys: Keymap.shared.text(.fieldFavoriteDown), symbol: "yab.down", group: 2) {
                    if self.favorites.move(favorite, by: 1, among: shown) { self.settleFavorites(favorite) }
                })
            }
        }
        out.insert(contentsOf: own, at: out.firstIndex { Self.takesAway.contains($0.id) } ?? out.count)
        return out
    }

    /// Whether a row is a private tab's, in this window or another; one
    /// whose tab is gone is taken for one, to be sure.
    private func shyRow(_ offer: Suggestion) -> Bool {
        guard let id = offer.tab else { return false }
        let tab = tabs.first { $0.id == id } ?? BrowserWindows.shared.browsers.flatMap(\.tabs).first { $0.id == id }
        return tab?.shy != false
    }

    /// A page in History's or Bookmarks' list: ⇧⌘F keeps it as a page,
    /// under the name it has there.
    func favoriting(_ url: URL, named name: String, _ actions: [FieldAction]) -> [FieldAction] {
        favoriting(Suggestion(key: name, title: Address.pretty(url), url: url, kind: .visited), actions)
    }

    /// What takes something away, which Favorites' actions go before, as
    /// ⌘K's list keeps its line over them (FieldActionsPanel).
    private static let takesAway: Set<String> = ["closetab", "forget", "delete", "forgetsite", "clear", "trash"]

    /// ⇧⌘F, ⌥⌘↑ or ⌥⌘↓ on the chosen row, ⌘K's list up over it or not:
    /// the list goes, as when one of its rows is taken. False when the row
    /// has no such action, and the key goes on.
    func favoriteKey(_ id: String) -> Bool {
        if query.acting != nil, query.choosingAbout || query.choosingFilter || query.choosingModel { return false }
        guard let action = rowActions.first(where: { $0.id == id }) else { return false }
        query.acting = nil
        action.run()
        return true
    }

    /// The empty field's rows again after Favorites changed, the row it
    /// changed still chosen where it went, or, gone from the list, the row
    /// now in its place: the row moving is what says it was done. Typed
    /// words' rows stay as they are, and History's and Bookmarks' lists:
    /// false there, where nothing on screen has changed.
    @discardableResult
    private func settleFavorites(_ favorite: FieldFavorite) -> Bool {
        guard typed.isEmpty, query.place == nil, query.scope == nil, untouched == nil else { return false }
        let was = query.current
        typed = ""
        let rows = offers
        let at = rows.firstIndex { $0.favorite && FieldFavorite.of($0)?.same == favorite.same }
            ?? rows.firstIndex { FieldFavorite.of($0)?.same == favorite.same }
            ?? was.map { min($0, rows.count - 1) }
        if let at, rows.indices.contains(at) { picked = at == query.lead ? nil : at }
        return true
    }
}
