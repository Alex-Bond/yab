import Foundation

/// A space, the same as on the Mac: its name and emoji, its color, pinned
/// sites, kept tabs and folders above the line, today's tabs under it.
/// Today is one list on every device (the Mac's and the iPhone's), per space.
struct Space: Identifiable, Codable, Hashable, Sendable {
    typealias ID = String

    var id: ID
    var name: String
    var emoji: String
    /// The space's wash: the column's glass and the plate's tint (the
    /// prototype's `glass`).
    var tint: RGB
    /// The complete Mac look; nil keeps the earlier iPhone appearance.
    var look: SpaceLook?
    /// Metadata only until this iPhone has per-space website stores.
    var ownSignIns: Bool
    var pins: [Pin]
    var kept: [KeptItem]
    var today: [Tab]
    /// The tab this iPhone shows in this space; each device has its own.
    var current: Tab.ID?
    /// Past three rows the last pin says "+N more"; a tap shows them all for the day.
    var pinsOpen: Bool
    /// The Private place: no pins, nothing kept, its tabs never leave this iPhone.
    var isPrivate: Bool

    init(id: ID, name: String, emoji: String, tint: RGB, pins: [Pin] = [], kept: [KeptItem] = [], today: [Tab] = [],
         current: Tab.ID? = nil, pinsOpen: Bool = false, isPrivate: Bool = false,
         look: SpaceLook? = nil, ownSignIns: Bool = false) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.tint = tint
        self.look = look
        self.ownSignIns = ownSignIns
        self.pins = pins
        self.kept = kept
        self.today = today
        self.current = current
        self.pinsOpen = pinsOpen
        self.isPrivate = isPrivate
        placeTabs()
    }

    enum CodingKeys: String, CodingKey {
        case id, name, emoji, tint, pins, kept, today, current, pinsOpen, look, ownSignIns
        case isPrivate = "private"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? ""
        tint = try c.decode(RGB.self, forKey: .tint)
        look = try c.decodeIfPresent(SpaceLook.self, forKey: .look)
        ownSignIns = try c.decodeIfPresent(Bool.self, forKey: .ownSignIns) ?? false
        pins = try c.decodeIfPresent([Pin].self, forKey: .pins) ?? []
        kept = try c.decodeIfPresent([KeptItem].self, forKey: .kept) ?? []
        today = try c.decodeIfPresent([Tab].self, forKey: .today) ?? []
        current = try c.decodeIfPresent(Tab.ID.self, forKey: .current)
        pinsOpen = try c.decodeIfPresent(Bool.self, forKey: .pinsOpen) ?? false
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        placeTabs()
    }

    /// Each tab told where it lives.
    mutating func placeTabs() {
        for i in pins.indices { pins[i].place = .pinned }
        KeptTree.mapTabs(&kept) { $0.place = .kept }
        for i in today.indices { today[i].place = .today }
    }

    // MARK: - reading

    /// Pins as the iPhone shows them: Mail stays on the Mac.
    var visiblePins: [Pin] { pins.filter { !$0.isMail } }

    var folders: [Folder] { KeptTree.folders(kept) }

    /// Kept tabs at every depth, in the actual tree's order.
    var keptTabs: [Tab] { KeptTree.tabs(kept) }

    /// Every tab of the space: pins, kept, today.
    var allTabs: [Tab] { pins + keptTabs + today }

    /// The rows the column shows, in order: kept tabs (an open folder's
    /// inside it), then today's. Pins are above them, not rows.
    var rows: [Tab] { KeptTree.visible(kept, current: current) + today }

    /// The order a swipe on the plate pages through: the rows, with the tab
    /// in front first when it isn't one of them (a pin, a closed folder's).
    var pagingOrder: [Tab] {
        var out = rows
        if let current, !out.contains(where: { $0.id == current }), let tab = tab(current) {
            out.insert(tab, at: 0)
        }
        return out
    }

    /// Without joining pins, kept and today into one array first: every
    /// SwiftUI update of the page asks this of each space (crash #104).
    func tab(_ id: Tab.ID) -> Tab? {
        pins.first { $0.id == id } ?? KeptTree.tab(id, in: kept) ?? today.first { $0.id == id }
    }

    /// The folder holding a tab, if one does.
    func folder(holding id: Tab.ID) -> Folder? { KeptTree.path(to: id, in: kept).last }

    /// The tab in front on the Mac, if it is in this space.
    var onMac: Tab? { allTabs.first { $0.onMac } }

    // MARK: - changing

    mutating func setFolder(_ id: Folder.ID, open: Bool) {
        KeptTree.editFolder(id, in: &kept) { $0.open = open }
    }

    /// Every parent opens for an explicit tab selection; folding one later
    /// still leaves the current tab peeking beneath its first shut parent.
    mutating func reveal(_ id: Tab.ID) {
        for folder in KeptTree.path(to: id, in: kept) { setFolder(folder.id, open: true) }
    }

    @discardableResult
    mutating func remove(_ id: Tab.ID) -> Tab? {
        if let i = today.firstIndex(where: { $0.id == id }) { return today.remove(at: i) }
        if let i = pins.firstIndex(where: { $0.id == id }) { return pins.remove(at: i) }
        return KeptTree.remove(id, from: &kept)
    }

    /// Kept-only transfer. Both folders stay, including newly empty ones.
    @discardableResult
    mutating func move(_ id: Tab.ID, intoFolder destination: Folder.ID?) -> Bool {
        guard !isPrivate, let tab = tab(id), !tab.isPrivate, tab.place == .kept,
              destination == nil || folders.contains(where: { $0.id == destination }),
              folder(holding: id)?.id != destination else { return false }
        guard let removed = KeptTree.remove(id, from: &kept) else { return false }
        if let destination { KeptTree.editFolder(destination, in: &kept) { $0.items.append(.tab(removed)) } }
        else { kept.append(.tab(removed)) }
        return true
    }

    /// Clear: today's go, here and on the Mac, except the tab in front.
    /// Returns how many went.
    @discardableResult
    mutating func clearToday(keeping front: Tab.ID?) -> Int {
        let before = today.count
        today.removeAll { $0.id != front }
        return before - today.count
    }
}
