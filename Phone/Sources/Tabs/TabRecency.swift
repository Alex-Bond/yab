import Foundation

/// Which tabs this iPhone had in front, latest first, per space: the order
/// of the tab stack beside the plate and of All Tabs. Each device keeps its
/// own, as it keeps the tab it shows (Space.current); nothing of it syncs.
struct TabRecency: Codable, Equatable, Sendable {
    private(set) var spaces: [Space.ID: [Tab.ID]] = [:]

    /// Enough for any day's tabs; older ones fall off the end.
    static let limit = 200

    /// The tab came in front: first in its space's list.
    mutating func touch(_ id: Tab.ID, in space: Space.ID) {
        var list = spaces[space] ?? []
        list.removeAll { $0 == id }
        list.insert(id, at: 0)
        if list.count > Self.limit { list.removeLast(list.count - Self.limit) }
        spaces[space] = list
    }

    /// A kept or pinned tab closed in All Tabs: it leaves the stack and All
    /// Tabs, and stays where it is kept.
    mutating func drop(_ id: Tab.ID, in space: Space.ID) {
        spaces[space]?.removeAll { $0 == id }
    }

    func recent(in space: Space.ID) -> [Tab.ID] { spaces[space] ?? [] }

    /// Only the tabs that are still there, in spaces that are; with
    /// `publicOnly` nothing private either, for the disk.
    func pruned(to spaces: [Space], publicOnly: Bool = false) -> TabRecency {
        var next = TabRecency()
        for space in spaces where !(publicOnly && space.isPrivate) {
            guard let list = self.spaces[space.id] else { continue }
            let kept = list.filter { id in space.tab(id).map { !(publicOnly && $0.isPrivate) } ?? false }
            if !kept.isEmpty { next.spaces[space.id] = kept }
        }
        return next
    }

    /// The space's open tabs, latest first: the tab in front, then the ones
    /// this iPhone had in front since, kept and pinned ones too (opened here
    /// they count as open pages until closed in All Tabs), then today's never
    /// shown here, newest first. Kept and pinned tabs never opened here stay
    /// out: they are the spaces' rows, not open pages. Mail stays on the Mac,
    /// and an empty tab (an old first launch's about:blank) is no page to go back to.
    static func order(of space: Space, recent: [Tab.ID]) -> [Tab] {
        // Read on every chrome update: one look-up table, not a search per id.
        let tabs = Dictionary(space.allTabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [Tab] = []
        var seen = Set<Tab.ID>()
        func add(_ tab: Tab?, front: Bool = false) {
            guard let tab, !tab.isMail, front || !isEmpty(tab), seen.insert(tab.id).inserted else { return }
            out.append(tab)
        }
        add(space.current.flatMap { tabs[$0] }, front: true)
        for id in recent { add(tabs[id]) }
        for tab in space.today { add(tab) }
        return out
    }

    /// A tab with nothing in it: about:blank, or a world's blank New Tab.
    static func isEmpty(_ tab: Tab) -> Bool {
        if let url = tab.url, !url.isEmpty { return url == "about:blank" }
        return tab.page == "blank"
    }
}

/// The order on disk, beside the profile: public spaces and tabs only, as
/// the profile itself; a private tab's place never leaves this iPhone's memory.
struct TabRecencyFile {
    let url: URL

    private struct File: Codable {
        var version = 1
        var recency: TabRecency
    }

    func read(spaces: [Space]) -> TabRecency {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == 1 else { return TabRecency() }
        return file.recency.pruned(to: spaces, publicOnly: true)
    }

    func write(_ recency: TabRecency, spaces: [Space]) throws {
        let file = File(recency: recency.pruned(to: spaces, publicOnly: true))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(file).write(to: url, options: .atomic)
    }
}
