import Foundation

// What Settings › Boosts lists, and what picking in it does, apart from the
// views that draw it: the boosts and the userscripts of one sign-in as one
// list, On then Off, in the order the person dragged them to; which of them
// are picked; and what Delete asks. Pure, so a test can hold it
// (BoostSettingsTests).

/// One row of Boosts: a boost or a userscript.
struct BoostItem: Identifiable, Equatable {
    enum Kind: Equatable { case boost, userscript }

    /// Why a row has a word of its own.
    enum Trouble: Equatable {
        /// Its page checks failed twice or more.
        case stopped
        /// A newer version asks for more than the kept one may do.
        case asksMore
        /// Its files could not be read.
        case broken
    }

    let kind: Kind
    /// The boost's or the userscript's own id.
    let key: String
    var name: String
    /// The sites it runs on, as written; empty for every site.
    var hosts: [String]
    var enabled: Bool
    var trouble: Trouble?
    var updated: Date

    /// Unique across both kinds: a userscript and a boost may share an id.
    var id: String { (kind == .boost ? "boost:" : "script:") + key }

    var everySite: Bool { kind == .boost && hosts.isEmpty }

    /// The site its mark is taken from, when it has one of its own.
    var markHost: String? { kind == .boost ? hosts.first : nil }

    /// What stands after its name: the site, "Every site" or "userscript".
    /// Two sites of one name are one; more are "first and 2 more".
    @MainActor var place: String {
        guard kind == .boost else { return "userscript" }
        guard !hosts.isEmpty else { return "Every site" }
        var names: [String] = []
        for host in hosts.map(BoostItem.bare) where !names.contains(Browser.site(host)) { names.append(Browser.site(host)) }
        return names.count > 1 ? "\(names[0]) and \(names.count - 1) more" : names.first ?? ""
    }

    /// The row's line: the place, and a newer version's ask beside it.
    @MainActor var detail: String {
        trouble == .asksMore ? place + " \u{00B7} New version asks for more" : place
    }

    /// The word before the switch for a row that is not well.
    var warning: String? {
        switch trouble {
        case .stopped: return "Stopped working"
        case .broken: return "Could not load"
        case .asksMore, nil: return nil
        }
    }

    static func bare(_ host: String) -> String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
}

extension BoostItem {
    /// The list of one sign-in: its boosts and its userscripts, already
    /// as that sign-in runs them (Boosts.records(in:)).
    /// `loaded`: ids whose files were read; `asking`: ids with a newer
    /// version that asks for more.
    static func list(boosts: [BoostRecord], scripts: [Userscripts.Record], sites: [String: [String]],
                     loaded: Set<String>, asking: Set<String>, scriptsLoaded: Set<String>) -> [BoostItem] {
        let fromBoosts = boosts.map { record -> BoostItem in
            let all = record.sites == ["<all_urls>"]
            let trouble: Trouble? = !loaded.contains(record.id) ? .broken : record.failures >= 2 ? .stopped : asking.contains(record.id) ? .asksMore : nil
            return BoostItem(kind: .boost, key: record.id, name: record.name, hosts: all ? [] : record.sites,
                             enabled: record.enabled && trouble != .broken, trouble: trouble, updated: record.updated)
        }
        let fromScripts = scripts.map { record -> BoostItem in
            let trouble: Trouble? = !scriptsLoaded.contains(record.id) ? .broken : record.pending != nil ? .asksMore : nil
            return BoostItem(kind: .userscript, key: record.id, name: record.name, hosts: sites[record.id] ?? [],
                             enabled: record.enabled, trouble: trouble, updated: record.updated)
        }
        return fromBoosts + fromScripts
    }
}

/// The order the person set by dragging a grip: ids, first to last. What
/// was never moved comes after, the newest first.
enum BoostOrder {
    static func sorted(_ items: [BoostItem], by order: [String]) -> [BoostItem] {
        let place = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.sorted { a, b in
            switch (place[a.id], place[b.id]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                if a.updated != b.updated { return a.updated > b.updated }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// The whole order after `id` is dropped at `index` among `group`
    /// (the ids of its own group, as listed): the others keep their places.
    static func moved(_ all: [String], group: [String], id: String, to index: Int) -> [String] {
        guard let from = group.firstIndex(of: id) else { return all }
        var reordered = group
        reordered.remove(at: from)
        reordered.insert(id, at: min(max(0, index), reordered.count))
        let slots = all.indices.filter { group.contains(all[$0]) }
        var out = all
        for (slot, id) in zip(slots, reordered) { out[slot] = id }
        return out
    }
}

/// Which rows are picked in Select, and what the buttons under them may do.
struct BoostPicks: Equatable {
    private(set) var ids: Set<String> = []

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }

    mutating func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// Only what is still in the list stays picked.
    mutating func keep(_ items: [BoostItem]) {
        let there = Set(items.map(\.id))
        ids = ids.intersection(there)
    }

    mutating func clear() { ids = [] }

    func picked(_ items: [BoostItem]) -> [BoostItem] { items.filter { ids.contains($0.id) } }

    /// "3 boosts selected", and "Select boosts" before one is picked.
    var words: String {
        switch count {
        case 0: return "Select boosts"
        case 1: return "1 boost selected"
        default: return "\(count) boosts selected"
        }
    }

    func canTurnOn(_ items: [BoostItem]) -> Bool { picked(items).contains { !$0.enabled && $0.trouble != .broken } }
    func canTurnOff(_ items: [BoostItem]) -> Bool { picked(items).contains(where: \.enabled) }
    func canDelete(_ items: [BoostItem]) -> Bool { !picked(items).isEmpty }
}

/// What Delete… asks, in words.
enum BoostDeletion {
    /// "A", "A and B", "A, B and C".
    static func names(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    static func title(_ items: [BoostItem]) -> String {
        items.count == 1 ? "Delete \(items[0].name)?" : "Delete \(items.count) boosts?"
    }

    static func detail(_ items: [BoostItem]) -> String {
        let one = items.count == 1
        let stops = "\(names(items.map(\.name))) \(one ? "stops" : "stop") changing \(one ? "its site" : "their sites")."
        let boosts = items.contains { $0.kind == .boost }
        let scripts = items.contains { $0.kind == .userscript }
        if scripts && !boosts {
            return "\(names(items.map(\.name))) \(one ? "stops" : "stop") running. \(one ? "It" : "They") can be added again from \(one ? "its file" : "their files")."
        }
        return stops + " A boost from the Store can be kept again from the Store."
    }
}
