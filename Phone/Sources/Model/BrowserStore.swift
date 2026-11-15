import Foundation
import Observation

/// Spaces and their tabs, the space in front and the tab in front in each:
/// what the column shows and the page and plate follow. Today is one list
/// per space, the same on the Mac (sync makes it so from M7); which tab this
/// iPhone looks at is its own.
@MainActor
@Observable
final class BrowserStore {
    private(set) var spaces: [Space] { didSet { revision &+= 1 } }
    /// The space in front.
    private(set) var spaceID: Space.ID { didSet { revision &+= 1 } }
    /// Counts every change to the spaces and the space in front: what is
    /// worked out from them (New Tab's content, the profile's capture, the
    /// lookups below) keys on it instead of comparing every tab again.
    private(set) var revision = 0
    @ObservationIgnored private var lookup: Lookup?
    /// The ordinary place to return to when opening the eyes in Private.
    private(set) var ordinarySpaceID: Space.ID
    private let fixturesEnabled: Bool
    // AppModel supplies the foreground permission. Raw private records stay in
    // memory so locking never closes a tab or replaces its WebKit session.
    @ObservationIgnored var mayEnterPrivate: (() -> Bool)?
    @ObservationIgnored var requestPrivateEntry: ((@escaping @MainActor () -> Void) -> Void)?
    @ObservationIgnored var didEnterPublic: (() -> Void)?
    /// Provenance only for an actual new insertion, never a URL deduplication.
    @ObservationIgnored var didInsertTab: ((Tab, Space) -> Void)?
    /// The Mac's state, as far as the iPhone knows.
    var macAsleep: Bool
    /// Changes made while the Mac sleeps, said on one quiet line in the column.
    var pendingForMac: Int = 0

    init(world: World, fixturesEnabled: Bool = true) {
        self.fixturesEnabled = fixturesEnabled
        spaces = world.spaces
        spaceID = world.space
        ordinarySpaceID = world.spaces.first(where: { $0.id == world.space && !$0.isPrivate })?.id
            ?? world.spaces.first(where: { !$0.isPrivate })?.id ?? world.space
        macAsleep = world.mac.asleep
        if !fixturesEnabled { _ = ensurePrivateSpace() }
        for i in spaces.indices { Self.normalizePrivacy(&spaces[i]) }
        // A named world shows a tab: its own, else its first row. A person's
        // profile keeps what it saved: nothing in front stays nothing.
        for i in spaces.indices where fixturesEnabled && spaces[i].current == nil {
            spaces[i].current = spaces[i].rows.first?.id ?? spaces[i].visiblePins.first?.id ?? spaces[i].keptTabs.first?.id
        }
        // Restoring a selection must not unfold its saved ancestors.
        // The column shows the current tab below its first closed parent.
    }

    // MARK: - reading

    var space: Space { spaces.first { $0.id == spaceID } ?? spaces[0] }
    var spaceIndex: Int { spaces.firstIndex { $0.id == spaceID } ?? 0 }

    /// The tab in front.
    var tab: Tab? { space.current.flatMap { space.tab($0) } }

    func space(_ id: Space.ID) -> Space? { spaces.first { $0.id == id } }

    /// The space a tab lives in.
    func space(holding id: Tab.ID) -> Space? { spaces.first { $0.tab(id) != nil } }

    func tab(_ id: Tab.ID) -> Tab? { spaces.lazy.compactMap { $0.tab(id) }.first }

    /// Every tab of every space.
    var allTabs: [Tab] { spaces.flatMap(\.allTabs) }

    /// The tab in front on the Mac, in any space.
    var onMac: Tab? { lookups.onMac }

    /// The first public tab showing an address, in `allTabs`' order. New
    /// Tab asks this for each of its rows on every draw; scanning every tab
    /// of every space for each one kept a launch busy until iOS ended it.
    func openTab(at url: String) -> Tab? { lookups.byURL[url] }

    private struct Lookup {
        var revision: Int
        var onMac: Tab?
        var byURL: [String: Tab]
    }

    /// Made once per revision. Reading `revision` keeps a view that asks
    /// this observing the spaces, as reading them did.
    private var lookups: Lookup {
        if let lookup, lookup.revision == revision { return lookup }
        var made = Lookup(revision: revision, onMac: nil, byURL: [:])
        for tab in allTabs {
            if made.onMac == nil, tab.onMac { made.onMac = tab }
            guard !tab.isPrivate, let url = tab.navigationURL?.absoluteString, made.byURL[url] == nil else { continue }
            made.byURL[url] = tab
        }
        lookup = made
        return made
    }

    /// The tabs a swipe on the plate pages through, in the space in front.
    var pagingOrder: [Tab] { space.pagingOrder }

    /// The neighbors of the tab in front: before, after.
    var neighbors: (before: Tab?, after: Tab?) {
        let order = pagingOrder
        guard let id = tab?.id, let i = order.firstIndex(where: { $0.id == id }) else { return (nil, nil) }
        return (i > 0 ? order[i - 1] : nil, i + 1 < order.count ? order[i + 1] : nil)
    }

    // MARK: - going places

    /// Shows a tab, wherever it is: its space comes in front and its folder opens.
    func select(_ id: Tab.ID) {
        Links.trace("select \(id) previous=\(tab?.id ?? "nil")")
        guard let owner = space(holding: id), let i = spaces.firstIndex(where: { $0.id == owner.id }) else { return }
        guard permitEntry(to: owner, then: { [weak self] in self?.select(id) }) else { return }
        spaces[i].current = id
        spaces[i].reveal(id)
        spaceID = owner.id
        if !owner.isPrivate { ordinarySpaceID = owner.id }
    }

    /// Brings a space in front; its own tab with it.
    func showSpace(_ id: Space.ID) {
        guard let target = space(id),
              permitEntry(to: target, then: { [weak self] in self?.showSpace(id) }) else { return }
        spaceID = id
        if space(id)?.isPrivate == false { ordinarySpaceID = id }
    }

    private func permitEntry(to target: Space, then action: @escaping @MainActor () -> Void) -> Bool {
        if target.isPrivate, mayEnterPrivate?() == false {
            requestPrivateEntry?(action)
            return false
        }
        if !target.isPrivate { didEnterPublic?() }
        return true
    }

    func showSpace(at index: Int) {
        guard spaces.indices.contains(index) else { return }
        showSpace(spaces[index].id)
    }

    /// The next or the previous tab in the paging order; false at either end.
    @discardableResult
    func page(by step: Int) -> Bool {
        let order = pagingOrder
        guard let id = tab?.id, let i = order.firstIndex(where: { $0.id == id }) else { return false }
        let j = i + step
        guard order.indices.contains(j) else { return false }
        select(order[j].id)
        return true
    }

    // MARK: - changing

    private func edit(_ id: Space.ID, _ change: (inout Space) -> Void) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        change(&spaces[i])
    }

    /// Metadata changes keep the space's IDs, rows and selected page intact.
    func setSpace(_ id: Space.ID, name: String? = nil, emoji: String? = nil, look: SpaceLook? = nil) {
        guard let space = space(id), !space.isPrivate else { return }
        edit(id) {
            if let name {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { $0.name = trimmed }
            }
            if let emoji, !emoji.isEmpty { $0.emoji = emoji }
            // The look's wash is the space's tint, the same one sync makes of
            // a look from the Mac (SyncMapping.tint): the spaces' cards and
            // everything tinted read it, here at once.
            if let look { $0.look = look; $0.tint = look.wash }
        }
        if macAsleep { pendingForMac += 1 }
    }

    /// Changing sign-ins reloads pages in the same space; it never moves tabs.
    func setSpaceSignIns(_ id: Space.ID, own: Bool) {
        guard let space = space(id), !space.isPrivate, space.ownSignIns != own else { return }
        edit(id) { $0.ownSignIns = own; $0.signInWith = nil }
        if macAsleep { pendingForMac += 1 }
    }

    /// A public space owns a stable UUID before profile or sync sees it.
    @discardableResult
    func createSpace(name: String, emoji: String, look: SpaceLook) -> Space.ID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let made = Space(id: UUID().uuidString, name: name.isEmpty ? "Untitled" : name,
                         emoji: emoji.isEmpty ? "🌐" : emoji, tint: look.primary, look: look)
        spaces.append(made)
        showSpace(made.id)
        if macAsleep { pendingForMac += 1 }
        return made.id
    }

    /// Another public space stays: the browser is never without one.
    func mayDeleteSpace(_ id: Space.ID) -> Bool {
        guard let target = space(id), !target.isPrivate else { return false }
        return spaces.contains { !$0.isPrivate && $0.id != id }
    }

    /// The space and its tabs gone here; the one above it (below, for the
    /// top one) comes on screen in its place. Returns the tabs that went.
    @discardableResult
    func deleteSpace(_ id: Space.ID) -> [Tab.ID] {
        guard mayDeleteSpace(id), let at = spaces.firstIndex(where: { $0.id == id }) else { return [] }
        let gone = spaces[at].allTabs.map(\.id)
        if spaceID == id || ordinarySpaceID == id {
            let shown = spaces.filter { !$0.isPrivate }
            let i = shown.firstIndex { $0.id == id } ?? 0
            let next = shown[i > 0 ? i - 1 : 1]
            if spaceID == id { spaceID = next.id }
            ordinarySpaceID = next.id
        }
        spaces.remove(at: at)
        return gone
    }

    /// The space's privacy also applies to records that omitted the tab flag.
    private static func normalizePrivacy(_ space: inout Space) {
        guard space.isPrivate else { return }
        for i in space.pins.indices { space.pins[i].isPrivate = true }
        for i in space.today.indices { space.today[i].isPrivate = true }
        KeptTree.mapTabs(&space.kept) { $0.isPrivate = true }
    }

    func setFolder(_ folder: Folder.ID, open: Bool, in space: Space.ID) {
        edit(space) { $0.setFolder(folder, open: open) }
    }

    /// A deliberate label never replaces the page metadata used by Reset.
    @discardableResult
    func renameTab(_ id: Tab.ID, to name: String?) -> Bool {
        guard let owner = space(holding: id), !owner.isPrivate,
              var tab = owner.tab(id), !tab.isPrivate, !tab.isMail, tab.place != .today else { return false }
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean == nil || clean?.isEmpty == false else { return false }
        if tab.name == nil { tab.pageTitle = tab.title }
        tab.name = clean
        tab.title = clean ?? tab.pageTitle ?? tab.title
        edit(owner.id) { space in
            if let i = space.pins.firstIndex(where: { $0.id == id }) { space.pins[i] = tab }
            else { KeptTree.replace(id, in: &space.kept, with: tab) }
        }
        return true
    }

    @discardableResult
    func createFolder(name: String, in spaceID: Space.ID, parent: Folder.ID? = nil) -> Folder.ID? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = space(spaceID), !space.isPrivate, !clean.isEmpty else { return nil }
        if let parent {
            guard Self.folderDepth(parent, in: space.kept) < KeptTree.deepest,
                  space.folders.contains(where: { $0.id == parent }) else { return nil }
        }
        let folder = Folder(id: UUID().uuidString, name: clean, open: true, tabs: [])
        edit(spaceID) {
            if let parent { KeptTree.editFolder(parent, in: &$0.kept) { $0.items.append(.folder(folder)) } }
            else { $0.kept.append(.folder(folder)) }
        }
        return folder.id
    }

    @discardableResult
    func renameFolder(_ id: Folder.ID, in spaceID: Space.ID, to name: String) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = space(spaceID), !space.isPrivate, !clean.isEmpty else { return false }
        var changed = false
        edit(spaceID) { changed = KeptTree.editFolder(id, in: &$0.kept) { $0.name = clean } }
        return changed
    }

    /// Dissolve just this folder in place. Its child folders and pages survive.
    @discardableResult
    func deleteFolder(_ id: Folder.ID, in spaceID: Space.ID) -> Bool {
        guard let space = space(spaceID), !space.isPrivate else { return false }
        func dissolve(_ items: inout [KeptItem]) -> Bool {
            for i in items.indices {
                guard case var .folder(folder) = items[i] else { continue }
                if folder.id == id { items.replaceSubrange(i...i, with: folder.items); return true }
                if dissolve(&folder.items) { items[i] = .folder(folder); return true }
            }
            return false
        }
        var changed = false
        edit(spaceID) { changed = dissolve(&$0.kept) }
        return changed
    }

    static func folderDepth(_ id: Folder.ID, in items: [KeptItem]) -> Int {
        for item in items {
            guard case let .folder(folder) = item else { continue }
            if folder.id == id { return 1 }
            let below = folderDepth(id, in: folder.items)
            if below > 0 { return below + 1 }
        }
        return 0
    }

    /// Private is always available on a real launch and remains transient.
    private func privateSpaceID() -> Space.ID {
        if !space.isPrivate { ordinarySpaceID = spaceID }
        return ensurePrivateSpace()
    }

    @discardableResult
    private func ensurePrivateSpace() -> Space.ID {
        if let index = spaces.firstIndex(where: \.isPrivate) {
            if index > 0 { spaces.insert(spaces.remove(at: index), at: 0) }
            return spaces[0].id
        }
        let id = spaces.contains(where: { $0.id == "local.private" })
            ? "local.private-" + UUID().uuidString : "local.private"
        spaces.insert(Space(id: id, name: "Private", emoji: "", tint: RGB(44, 42, 52), isPrivate: true), at: 0)
        return id
    }

    /// A new tab at the top of today's, in front. One page, one row (the
    /// same on the Mac, M7): an address the space already has brings that
    /// row up instead, to the top of today's if it is one of them.
    func open(_ tab: Tab, in space: Space.ID? = nil, deduplicate: Bool = true) {
        Links.trace("open tab=\(tab.id) url=\(tab.address)")
        var target = space ?? spaceID
        var tab = tab
        if tab.isPrivate && self.space(target)?.isPrivate != true { target = privateSpaceID() }
        if self.space(target)?.isPrivate == true { tab.isPrivate = true }
        else { ordinarySpaceID = target }
        func pageAddress(_ tab: Tab) -> String? {
            fixturesEnabled ? tab.url.map(Self.samePage) : tab.navigationURL?.absoluteString
        }
        if deduplicate, !tab.isPrivate, let address = pageAddress(tab), !address.isEmpty,
           let had = self.space(target)?.allTabs.first(where: { !$0.isPrivate && (fixturesEnabled ? $0.url.map(Self.samePage) : $0.navigationURL?.absoluteString) == address }) {
            edit(target) { space in
                if let i = space.today.firstIndex(where: { $0.id == had.id }), i > 0 {
                    space.today.insert(space.today.remove(at: i), at: 0)
                }
                space.current = had.id
                space.reveal(had.id)
            }
            showSpace(target)
            if macAsleep, had.place == .today { pendingForMac += 1 }
            return
        }
        tab.place = .today
        edit(target) {
            $0.today.insert(tab, at: 0)
            $0.current = tab.id
        }
        if let owner = self.space(target) { didInsertTab?(tab, owner) }
        showSpace(target)
        if macAsleep && !tab.isPrivate { pendingForMac += 1 }
    }

    /// A tab behind the one it came from (Open in Background Tab): right
    /// after `source` in today's, or at today's top when the source isn't
    /// one of them. The tab in front stays in front.
    func openBehind(_ tab: Tab, after source: Tab.ID, in space: Space.ID) {
        guard let owner = self.space(space) else { return }
        var tab = tab
        if owner.isPrivate { tab.isPrivate = true }
        tab.place = .today
        edit(space) { space in
            let index = space.today.firstIndex { $0.id == source }.map { $0 + 1 } ?? 0
            space.today.insert(tab, at: index)
        }
        if let owner = self.space(space) { didInsertTab?(tab, owner) }
        if macAsleep && !tab.isPrivate { pendingForMac += 1 }
    }

    /// An address as one page: no scheme, no www., no slash at the end, any case.
    static func samePage(_ address: String) -> String {
        var s = address.trimmingCharacters(in: .whitespaces).lowercased()
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Replaces the tab in front with another page, where it stood.
    func navigate(to tab: Tab) {
        guard let current = self.tab else { return open(tab) }
        edit(spaceID) { space in
            var tab = tab
            tab.place = current.place
            if let i = space.today.firstIndex(where: { $0.id == current.id }) { space.today[i] = tab }
            else if let i = space.pins.firstIndex(where: { $0.id == current.id }) { space.pins[i] = tab }
            else {
                KeptTree.replace(current.id, in: &space.kept, with: tab)
            }
            space.current = tab.id
        }
    }

    /// Another page in the same tab, wherever it stands (pinned, kept, in a
    /// folder, today's): its id, place and row stay; what it shows changes.
    func replace(_ id: Tab.ID, with tab: Tab) {
        guard let owner = space(holding: id), let old = owner.tab(id) else { return }
        var tab = tab
        tab.id = id
        tab.place = old.place
        // Navigation replaces page metadata, never a name or icon chosen on
        // the Mac. Sync adopts complete spaces and can still clear either.
        let pageTitle = tab.name == nil || tab.title != tab.name
            ? tab.title : tab.pageTitle ?? old.pageTitle ?? tab.title
        tab.name = old.name
        tab.customMark = old.customMark
        if let name = old.name {
            tab.pageTitle = pageTitle
            tab.title = name
        } else {
            tab.pageTitle = nil
        }
        edit(owner.id) { space in
            if let i = space.today.firstIndex(where: { $0.id == id }) { space.today[i] = tab }
            else if let i = space.pins.firstIndex(where: { $0.id == id }) { space.pins[i] = tab }
            else {
                KeptTree.replace(id, in: &space.kept, with: tab)
            }
        }
    }

    /// Close: the tab goes; the today's tab after it (or before) comes in
    /// front. With none left nothing does: a pin or a kept tab never steps
    /// forward by itself, the page stands empty with New Tab on the plate.
    func close(_ id: Tab.ID) {
        guard let owner = space(holding: id) else { return }
        // A private tab never reached the Mac: nothing waits for it there.
        let shy = owner.tab(id)?.isPrivate == true
        edit(owner.id) { space in
            let next = Self.heir(of: id, in: space)
            space.remove(id)
            if space.current == id { space.current = next }
        }
        // An empty private space has no page to keep in front. Return to
        // the public space even when it has no tabs of its own (#1501).
        if owner.isPrivate, spaceID == owner.id, space(owner.id)?.allTabs.isEmpty == true {
            showSpace(ordinarySpaceID)
        }
        if macAsleep && !shy { pendingForMac += 1 }
    }

    /// The tab that takes a leaving tab's place in front: only ever a today's.
    private static func heir(of id: Tab.ID, in space: Space) -> Tab.ID? {
        let order = space.pagingOrder
        guard let i = order.firstIndex(where: { $0.id == id }) else { return space.today.first { $0.id != id }?.id }
        let open = { (tab: Tab) in tab.id != id && space.today.contains { $0.id == tab.id } }
        return (order[(i + 1)...].first(where: open) ?? order[..<i].last(where: open))?.id
    }

    /// The tab in front lets go of the page and stays where it is kept:
    /// All Tabs' last card closed on a pin or a kept tab.
    func letGo(of id: Tab.ID) {
        guard let owner = space(holding: id) else { return }
        edit(owner.id) { space in
            if space.current == id { space.current = Self.heir(of: id, in: space) }
        }
    }

    /// Where a tab stands in its space, for Undo after a close.
    enum Spot: Equatable, Sendable {
        case today(Int)
        case pinned(Int)
        /// Among the kept, or inside a folder of them.
        case kept(folder: Folder.ID?, index: Int)
    }

    static func spot(of id: Tab.ID, in space: Space) -> Spot? {
        if let i = space.today.firstIndex(where: { $0.id == id }) { return .today(i) }
        if let i = space.pins.firstIndex(where: { $0.id == id }) { return .pinned(i) }
        if let folder = space.folder(holding: id), let i = folder.items.firstIndex(where: { $0.id == "tab:" + id }) {
            return .kept(folder: folder.id, index: i)
        }
        if let i = space.kept.firstIndex(where: { $0.id == "tab:" + id }) { return .kept(folder: nil, index: i) }
        return nil
    }

    /// Undo of a close: the tab back where it stood, or as near as its list
    /// now allows. Refused while its id is in use again or its space is gone.
    @discardableResult
    func reinsert(_ tab: Tab, in id: Space.ID, at spot: Spot) -> Bool {
        guard space(id) != nil, self.tab(tab.id) == nil else { return false }
        edit(id) { space in
            switch spot {
            case let .today(i): space.today.insert(tab, at: min(max(0, i), space.today.count))
            case let .pinned(i): space.pins.insert(tab, at: min(max(0, i), space.pins.count))
            case let .kept(folder, i):
                let item = KeptItem.tab(tab)
                let placed = folder.map { folder in
                    KeptTree.editFolder(folder, in: &space.kept) { $0.items.insert(item, at: min(max(0, i), $0.items.count)) }
                } ?? false
                // Its folder gone meanwhile: among the kept, where it was.
                if !placed { space.kept.insert(item, at: min(max(0, i), space.kept.count)) }
            }
            space.placeTabs()
        }
        if macAsleep && !tab.isPrivate { pendingForMac += 1 }
        return true
    }

    /// Keep: a today's tab goes above the line, at the end of the kept.
    func keep(_ id: Tab.ID) {
        guard let owner = space(holding: id), owner.tab(id)?.isPrivate != true else { return }
        edit(owner.id) { space in
            guard let i = space.today.firstIndex(where: { $0.id == id }) else { return }
            var tab = space.today.remove(at: i)
            tab.place = .kept
            space.kept.append(.tab(tab))
        }
        if macAsleep { pendingForMac += 1 }
    }

    /// A tab from outside Yab that doesn't come to the front: the share
    /// sheet's Keep for Later (at the end of the kept), or a shared link
    /// waiting behind the one in front (at the top of today's). The tab in
    /// front stays in front. One page, one row: a page the space has already
    /// keeps its row, a today's one going up to the kept for Keep. The row's
    /// tab, or nil for a private space.
    @discardableResult
    func file(_ tab: Tab, as place: Tab.Place, in id: Space.ID) -> Tab? {
        guard let owner = space(id), !owner.isPrivate, place != .pinned else { return nil }
        func pageAddress(_ tab: Tab) -> String? {
            fixturesEnabled ? tab.url.map(Self.samePage) : tab.navigationURL?.absoluteString
        }
        if let address = pageAddress(tab), !address.isEmpty,
           let had = owner.allTabs.first(where: { !$0.isPrivate && pageAddress($0) == address }) {
            if place == .kept, had.place == .today { keep(had.id) }
            return self.tab(had.id)
        }
        var tab = tab
        tab.place = place
        tab.isPrivate = false
        edit(id) { space in
            if place == .kept { space.kept.append(.tab(tab)) } else { space.today.insert(tab, at: 0) }
        }
        if let owner = space(id) { didInsertTab?(tab, owner) }
        if macAsleep { pendingForMac += 1 }
        return tab
    }

    /// Unkeep: a kept tab goes down to the top of today's.
    func unkeep(_ id: Tab.ID) {
        guard let owner = space(holding: id) else { return }
        edit(owner.id) { space in
            guard var tab = space.keptTabs.first(where: { $0.id == id }) else { return }
            space.remove(id)
            tab.place = .today
            space.today.insert(tab, at: 0)
        }
        if macAsleep { pendingForMac += 1 }
    }

    /// Pin: a today's or kept tab goes up to the end of the space's pins,
    /// out of any folder, as the Mac's Pin puts it.
    func pin(_ id: Tab.ID) {
        guard let owner = space(holding: id), !owner.isPrivate, var tab = owner.tab(id),
              !tab.isPrivate, tab.place != .pinned else { return }
        edit(owner.id) { space in
            space.remove(id)
            tab.place = .pinned
            space.pins.append(tab)
        }
        if macAsleep { pendingForMac += 1 }
    }

    /// Unpin: a pin goes down to the top of today's, as on the Mac.
    func unpin(_ id: Tab.ID) {
        guard let owner = space(holding: id), !owner.isPrivate,
              var tab = owner.pins.first(where: { $0.id == id }), !tab.isPrivate, !tab.isMail else { return }
        edit(owner.id) { space in
            space.remove(id)
            tab.place = .today
            space.today.insert(tab, at: 0)
        }
        if macAsleep { pendingForMac += 1 }
    }

    /// Move to Space: the tab goes to the top of the other space's today.
    func move(_ id: Tab.ID, to target: Space.ID) {
        guard let owner = space(holding: id), owner.id != target, var tab = owner.tab(id),
              let destination = space(target), owner.isPrivate == destination.isPrivate else { return }
        edit(owner.id) { space in
            // As Close: a today's neighbor, else nothing in front.
            let next = Self.heir(of: id, in: space)
            space.remove(id)
            if space.current == id { space.current = next }
        }
        tab.place = .today
        edit(target) { $0.today.insert(tab, at: 0) }
        if macAsleep && !tab.isPrivate { pendingForMac += 1 }
    }

    /// Legacy fixture helper. A live caller must use checked native cleanup;
    /// it cannot infer another device's protected tabs from these records.
    @discardableResult
    func clearToday(in id: Space.ID? = nil) -> Int {
        guard fixturesEnabled else { return 0 }
        let target = id ?? spaceID
        var gone = 0
        let front = space(target)?.current
        edit(target) { gone = $0.clearToday(keeping: front) }
        if macAsleep && gone > 0 && space(target)?.isPrivate != true { pendingForMac += 1 }
        return gone
    }

    /// A single local batch, with the complete owner rechecked after native
    /// safety awaits. Never used to remove guessed remote/shared candidates.
    func clearCheckedToday(_ ids: Set<Tab.ID>, expected: Space) -> Bool {
        // Any space, not only the one in front: Clear stands on each space's
        // own page.
        guard !ids.isEmpty, space(expected.id) == expected,
              Set(allTabs.map(\.id)).count == allTabs.count,
              !expected.isPrivate || mayEnterPrivate?() != false,
              expected.current.map({ !ids.contains($0) }) ?? true,
              ids.isSubset(of: Set(expected.today.map(\.id))),
              !expected.allTabs.contains(where: { ids.contains($0.id) && ($0.onMac || $0.place != .today) }) else { return false }
        edit(expected.id) { $0.today.removeAll { ids.contains($0.id) } }
        return true
    }

    /// The receipt owns the exact after-state. Later edits/moves/openings refuse
    /// instead of overwriting somebody else's work or resurrecting reused IDs.
    func restoreCheckedToday(_ original: Space, expected: Space) -> Bool {
        guard original.id == expected.id, space(expected.id) == expected,
              !original.isPrivate || mayEnterPrivate?() != false else { return false }
        let returning = Set(original.today.map(\.id)).subtracting(expected.today.map(\.id))
        guard allTabs.allSatisfy({ !returning.contains($0.id) }),
              original.pins == expected.pins, original.kept == expected.kept, original.current == expected.current else { return false }
        edit(expected.id) { $0.today = original.today }
        return true
    }

    /// Puts a row of today's or of the kept somewhere else in its own list.
    func reorder(_ id: Tab.ID, to index: Int) {
        guard let owner = space(holding: id) else { return }
        edit(owner.id) { space in
            if let i = space.today.firstIndex(where: { $0.id == id }) {
                let tab = space.today.remove(at: i)
                space.today.insert(tab, at: max(0, min(index, space.today.count)))
            } else if let i = space.kept.firstIndex(where: { $0.id == "tab:" + id }) {
                let item = space.kept.remove(at: i)
                space.kept.insert(item, at: max(0, min(index, space.kept.count)))
            }
        }
    }

    /// Spaces as sync has them now, all at once (Sync/SyncBridge). The space
    /// in front stays in front while it is there.
    func adopt(_ spaces: [Space]) {
        guard !spaces.isEmpty else { return }
        var next = spaces
        if !fixturesEnabled {
            // Sync can replace public spaces without replacing this phone's Private.
            let incoming = Set(next.filter(\.isPrivate).map(\.id))
            next += self.spaces.filter { $0.isPrivate && !incoming.contains($0.id) }
        }
        self.spaces = next.filter(\.isPrivate) + next.filter { !$0.isPrivate }
        if !fixturesEnabled { _ = ensurePrivateSpace() }
        for i in self.spaces.indices { Self.normalizePrivacy(&self.spaces[i]) }
        if !self.spaces.contains(where: { $0.id == spaceID }) {
            spaceID = self.spaces.first(where: { !$0.isPrivate })?.id ?? self.spaces[0].id
            if !space.isPrivate { didEnterPublic?() }
        }
        if !self.spaces.contains(where: { $0.id == ordinarySpaceID && !$0.isPrivate }),
           let ordinary = self.spaces.first(where: { !$0.isPrivate }) { ordinarySpaceID = ordinary.id }
    }

    /// Carries a tab to another place in its own list (today's, its folder's
    /// or the kept), before `other`, or to the list's end when other is nil.
    /// A tab never leaves its list this way, and no folder is made.
    func move(_ id: Tab.ID, before other: Tab.ID?) {
        guard let owner = space(holding: id), other != id else { return }
        func place(_ list: inout [Tab]) -> Bool {
            guard let i = list.firstIndex(where: { $0.id == id }) else { return false }
            let tab = list.remove(at: i)
            let j = other.flatMap { o in list.firstIndex { $0.id == o } } ?? list.count
            list.insert(tab, at: j)
            return true
        }
        edit(owner.id) { space in
            if place(&space.today) { return }
            if let folder = space.folder(holding: id) {
                KeptTree.editFolder(folder.id, in: &space.kept) { _ = place(&$0.tabs) }
                return
            }
            guard let i = space.kept.firstIndex(where: { $0.id == "tab:" + id }) else { return }
            let item = space.kept.remove(at: i)
            let j = other.flatMap { o in space.kept.firstIndex { $0.id == "tab:" + o } } ?? space.kept.count
            space.kept.insert(item, at: j)
        }
    }

    @discardableResult
    func moveIntoFolder(_ id: Tab.ID, in spaceID: Space.ID, to folder: Folder.ID?) -> Bool {
        guard let owner = space(holding: id), owner.id == spaceID,
              !owner.isPrivate, owner.tab(id)?.isPrivate == false else { return false }
        var changed = false
        edit(spaceID) { changed = $0.move(id, intoFolder: folder) }
        return changed
    }

    /// A space's pins, all at once (named states and tests ask for many).
    func setPins(_ pins: [Pin], in id: Space.ID) {
        edit(id) {
            $0.pins = pins
            $0.placeTabs()
        }
    }

    func setPinsOpen(_ open: Bool, in id: Space.ID) {
        edit(id) { $0.pinsOpen = open }
    }

    /// The tab in front on the Mac, as the Mac says.
    func setOnMac(_ id: Tab.ID?) {
        for i in spaces.indices {
            func mark(_ tab: inout Tab) { tab.onMac = tab.id == id }
            for j in spaces[i].pins.indices { mark(&spaces[i].pins[j]) }
            for j in spaces[i].today.indices { mark(&spaces[i].today[j]) }
            KeptTree.mapTabs(&spaces[i].kept, mark)
        }
    }
}
