import Foundation

/// A color as the prototype writes it, rgb out of 255; in JSON `[r, g, b]`.
struct RGB: Codable, Hashable, Sendable {
    var r: Int
    var g: Int
    var b: Int

    init(_ r: Int, _ g: Int, _ b: Int) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(from decoder: Decoder) throws {
        var list = try decoder.unkeyedContainer()
        r = try list.decode(Int.self)
        g = try list.decode(Int.self)
        b = try list.decode(Int.self)
    }

    func encode(to encoder: Encoder) throws {
        var list = encoder.unkeyedContainer()
        try list.encode(r)
        try list.encode(g)
        try list.encode(b)
    }
}

/// A tab: a page somewhere in a space, pinned, kept, in a folder, or today's.
/// The same tab on the Mac and the iPhone (its id is the sync record's).
struct Tab: Identifiable, Codable, Hashable, Sendable {
    typealias ID = String

    var id: ID
    /// Its title, "Onboarding v3 · Welcome screens"; the part before " · " is its short name.
    var title: String
    /// The Mac's deliberate label and mark, independent of page metadata.
    var name: String? = nil
    /// The page title underneath a deliberate name, retained for Reset.
    var pageTitle: String? = nil
    var customMark: String? = nil
    /// What the plate says: the site's name, "Figma".
    var site: String
    /// The site's icon, by the prototype's key: "figma", "hn", "mail"…
    var icon: String
    /// Its canonical address. Fixture worlds may carry a bare address.
    var url: String?
    /// The test page drawn for it: Resources/Pages/<page>.html. None: a
    /// generic page in the site's look (blank.html with its words).
    var page: String?
    /// The host its icon may be filed under, when it isn't the key.
    var host: String?
    /// A local server's port, written after the site on the plate: ":5173".
    var port: String?
    /// A pinned site's count (Mail's unread).
    var badge: Int?
    /// The page is dark: the status bar turns light over it.
    var dark: Bool
    /// Private: dark among today's, never kept, never on the Mac, never synced.
    var isPrivate: Bool
    /// The tab in front on the Mac right now ("Mac" on its row).
    var onMac: Bool
    /// Where it lives in its space; set from where the world puts it.
    var place: Place = .today

    enum Place: String, Codable, Sendable {
        case pinned, kept, today
    }

    init(id: ID, title: String, site: String, icon: String, url: String? = nil, page: String? = nil, host: String? = nil,
         port: String? = nil, badge: Int? = nil, dark: Bool = false, isPrivate: Bool = false, onMac: Bool = false, place: Place = .today) {
        self.id = id
        self.title = title
        self.site = site
        self.icon = icon
        self.url = url
        self.page = page
        self.host = host
        self.port = port
        self.badge = badge
        self.dark = dark
        self.isPrivate = isPrivate
        self.onMac = onMac
        self.place = place
    }

    enum CodingKeys: String, CodingKey {
        case id, title, name, pageTitle, customMark, site, icon, url, page, host, port, badge, dark
        case isPrivate = "private"
        case onMac
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        pageTitle = try c.decodeIfPresent(String.self, forKey: .pageTitle)
        customMark = try c.decodeIfPresent(String.self, forKey: .customMark)
        site = try c.decode(String.self, forKey: .site)
        icon = try c.decode(String.self, forKey: .icon)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        page = try c.decodeIfPresent(String.self, forKey: .page)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        port = try c.decodeIfPresent(String.self, forKey: .port)
        badge = try c.decodeIfPresent(Int.self, forKey: .badge)
        dark = try c.decodeIfPresent(Bool.self, forKey: .dark) ?? false
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        onMac = try c.decodeIfPresent(Bool.self, forKey: .onMac) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(pageTitle, forKey: .pageTitle)
        try c.encodeIfPresent(customMark, forKey: .customMark)
        try c.encode(site, forKey: .site)
        try c.encode(icon, forKey: .icon)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(page, forKey: .page)
        try c.encodeIfPresent(host, forKey: .host)
        try c.encodeIfPresent(port, forKey: .port)
        try c.encodeIfPresent(badge, forKey: .badge)
        if dark { try c.encode(dark, forKey: .dark) }
        if isPrivate { try c.encode(isPrivate, forKey: .isPrivate) }
        if onMac { try c.encode(onMac, forKey: .onMac) }
    }

    /// Mail stays in Yab on the Mac: the iPhone has no mail client yet, so a
    /// pinned Mail is hidden here.
    var isMail: Bool { icon == "mail" }

    /// The title's first part, "Onboarding v3".
    var short: String { name ?? title.components(separatedBy: " · ").first ?? title }

    /// Its address as the field shows it: the world's, else the site's name as
    /// a .com, as the prototype makes one up.
    var address: String {
        if let url, !url.isEmpty {
            return navigationURL.map(Address.pretty) ?? url
        }
        let name = site.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return (name.isEmpty ? "site" : name) + ".com"
    }

    /// The exact URL to load. A world's bare address still gets its scheme.
    var navigationURL: URL? {
        guard let url, !url.isEmpty else { return nil }
        // An extension's page is its own address, never read as typed words.
        if let page = URL(string: url), ExtensionHost.isExtensionPage(page) { return page }
        return Words.address(url)
    }

    /// The host its address names, for its icon.
    var addressHost: String {
        if let host { return host }
        if let host = navigationURL?.host() { return host }
        return address.components(separatedBy: "/").first ?? address
    }
}

/// A pinned site is a tab that stays: the same record, its place `.pinned`.
typealias Pin = Tab

/// A folder of tabs shared with the Mac. Either device can make, rename or
/// dissolve it; folding stays local to each device.
struct Folder: Identifiable, Codable, Hashable, Sendable {
    typealias ID = String

    var id: ID
    var name: String
    var open: Bool
    var items: [KeptItem]
    var customMark: String?
    /// Direct tabs only. Older callers retain the order of folder slots.
    var tabs: [Tab] {
        get { items.compactMap { if case let .tab(tab) = $0 { return tab }; return nil } }
        set {
            let prior = Set(tabs.map(\.id))
            let incoming = Set(newValue.map(\.id))
            if prior == incoming {
                var next = newValue.makeIterator()
                items = items.compactMap { item in
                    if case .tab = item { return next.next().map(KeptItem.tab) }
                    return item
                }
            } else {
                let byID = Dictionary(newValue.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                items = items.compactMap { item in
                    if case let .tab(tab) = item { return byID[tab.id].map(KeptItem.tab) }
                    return item
                }
                items += newValue.filter { !prior.contains($0.id) }.map(KeptItem.tab)
            }
        }
    }
    var allTabs: [Tab] { KeptTree.tabs(items) }
    /// A task's folder: its tabs are the ones the Mac opened for it.
    var task: TaskRun.ID?
    /// The color given it on the Mac (SyncFolder.color), kept when it syncs back.
    var color: String?

    init(id: ID, name: String, open: Bool = false, tabs: [Tab], task: TaskRun.ID? = nil) {
        self.id = id
        self.name = name
        self.open = open
        self.items = tabs.map(KeptItem.tab)
        self.customMark = nil
        self.task = task
    }

    init(id: ID, name: String, open: Bool = false, items: [KeptItem], customMark: String? = nil, task: TaskRun.ID? = nil, color: String? = nil) {
        self.id = id; self.name = name; self.open = open
        self.items = items; self.customMark = customMark; self.task = task; self.color = color
    }

    enum CodingKeys: String, CodingKey { case id, name, open, tabs, items, customMark, task, color }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        open = try c.decodeIfPresent(Bool.self, forKey: .open) ?? false
        if let nested = try c.decodeIfPresent([KeptItem].self, forKey: .items) { items = nested }
        else { items = (try c.decodeIfPresent([Tab].self, forKey: .tabs) ?? []).map(KeptItem.tab) }
        customMark = try c.decodeIfPresent(String.self, forKey: .customMark)
        task = try c.decodeIfPresent(TaskRun.ID.self, forKey: .task)
        color = try c.decodeIfPresent(String.self, forKey: .color)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(open, forKey: .open)
        if items.contains(where: { if case .folder = $0 { return true }; return false }) {
            try c.encode(items, forKey: .items)
        } else { try c.encode(tabs, forKey: .tabs) }
        try c.encodeIfPresent(customMark, forKey: .customMark)
        try c.encodeIfPresent(task, forKey: .task)
        try c.encodeIfPresent(color, forKey: .color)
    }
}

/// What a space keeps above its line: a tab, or a folder of them. In JSON
/// `{"tab": {...}}` or `{"folder": {...}}`.
enum KeptItem: Codable, Hashable, Sendable, Identifiable {
    case tab(Tab)
    case folder(Folder)

    var id: String {
        switch self {
        case let .tab(tab): "tab:" + tab.id
        case let .folder(folder): "folder:" + folder.id
        }
    }

    enum CodingKeys: String, CodingKey { case tab, folder }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Profile JSON is not trusted to respect the editor's depth limit.
        // Stop before recursively decoding a corrupt tree, not after copying it.
        if c.contains(.folder), try !c.decodeNil(forKey: .folder),
           decoder.codingPath.filter({ $0.stringValue == CodingKeys.folder.rawValue }).count >= KeptTree.deepest {
            throw DecodingError.dataCorruptedError(forKey: .folder, in: c, debugDescription: "Folder nesting exceeds the supported depth")
        }
        if let folder = try c.decodeIfPresent(Folder.self, forKey: .folder) {
            self = .folder(folder)
        } else {
            self = .tab(try c.decode(Tab.self, forKey: .tab))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .tab(tab): try c.encode(tab, forKey: .tab)
        case let .folder(folder): try c.encode(folder, forKey: .folder)
        }
    }
}
