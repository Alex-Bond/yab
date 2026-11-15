import Foundation

/// Tabs for addresses, searches and Frequent. A named test world maps them
/// to bundled pages; ordinary browsing keeps the exact URL and native metadata.
@MainActor
enum PageFixtures {
    struct Entry: Decodable {
        let stem: String
        let fav: String
        let title: String
        let site: String
        let url: String
        let dark: Bool
        let theme: String?
    }

    static let entries: [Entry] = {
        guard let url = PageSchemeHandler.resources?.appendingPathComponent("Pages/pages.json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }()

    /// The page drawn for an address, by its address, then by its host.
    static func entry(for address: String) -> Entry? {
        let bare = address.lowercased()
        if let exact = entries.first(where: { $0.url.lowercased() == bare }) { return exact }
        let host = bare.components(separatedBy: "/").first ?? bare
        return entries.first { ($0.url.lowercased().components(separatedBy: "/").first ?? "") == host && PageSchemeHandler.hasPage($0.stem) }
    }

    /// A new tab for an address: its own page if the app carries one,
    /// else the generic page with the host's name.
    static func tab(for url: URL, id: Tab.ID = newID(), isPrivate: Bool = false, in world: World? = nil,
                    fixturesEnabled: Bool = true) -> Tab {
        if !fixturesEnabled { return liveTab(for: url, id: id, isPrivate: isPrivate) }
        let address = Address.pretty(url)
        // A tab of the world at the same address lends its page and names.
        if let known = world?.spaces.lazy.flatMap(\.allTabs).first(where: { $0.address.lowercased() == address.lowercased() }) {
            var tab = known
            tab.id = id
            tab.isPrivate = isPrivate
            tab.onMac = false
            tab.badge = nil
            return tab
        }
        if let entry = entry(for: address) {
            return Tab(id: id, title: entry.title, site: entry.site, icon: entry.fav, url: address,
                       page: entry.stem, dark: entry.dark, isPrivate: isPrivate)
        }
        let host = url.host()?.replacingOccurrences(of: "www.", with: "") ?? address
        let name = host.components(separatedBy: ".").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? host
        return Tab(id: id, title: name, site: name, icon: name.lowercased(), url: address, host: host, isPrivate: isPrivate)
    }

    /// Live searches use the selected engine. Fixture worlds keep their
    /// prototype Google pages and never depend on an external service.
    static func search(_ words: String, id: Tab.ID = newID(), isPrivate: Bool = false, fixturesEnabled: Bool = true,
                       selection: SearchEngine.Selection = .standard) -> Tab {
        let query = words.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fixturesEnabled {
            // Empty words never become a provider request.
            guard let url = selection.url(for: query) else {
                return liveTab(for: URL(string: "about:blank")!, id: id, isPrivate: isPrivate)
            }
            var tab = liveTab(for: url, id: id, isPrivate: isPrivate)
            tab.title = "\(query) · \(selection.name) Search"
            tab.site = selection.name
            tab.icon = selection.engine == .google ? "google" : "magnifyingglass"
            return tab
        }
        let title = "\(query) · Google Search"
        let drawn = entries.first { $0.title.lowercased() == title.lowercased() }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics)?.replacingOccurrences(of: "%20", with: "+") ?? query
        let address = "google.com/search?q=" + encoded
        return Tab(id: id, title: title, site: "Google", icon: "google", url: address, page: drawn?.stem,
                   host: "google.com", isPrivate: isPrivate)
    }

    /// A site of Frequent as a new tab: its own page when the app has one
    /// (the prototype's picks), else the generic page.
    static func site(_ site: SiteCandidate, id: Tab.ID = newID(), fixturesEnabled: Bool = true) -> Tab {
        if !fixturesEnabled, let url = Words.address(site.host) {
            return liveTab(for: url, id: id)
        }
        let pages = ["lumen": "lumen", "nordbutik": "nordbutik", "figma": "figma", "ledger": "ledger", "github": "github"]
        let stem = pages[site.key]
        let entry = stem.flatMap { s in entries.first { $0.stem == s } }
        return Tab(id: id, title: entry?.title ?? site.name, site: site.name, icon: site.key,
                   url: entry?.url ?? site.host, page: stem, host: site.host)
    }

    /// A real address never borrows a fixture's title, page or identity.
    static func liveTab(for url: URL, id: Tab.ID = newID(), isPrivate: Bool = false, title: String? = nil) -> Tab {
        let host = url.host()?.lowercased()
        let site = host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "New Tab"
        let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? site
        return Tab(id: id, title: name, site: site, icon: host ?? "globe",
                   url: url.absoluteString, host: host, port: url.port.map(String.init), isPrivate: isPrivate)
    }

    nonisolated static func newID() -> Tab.ID { "new-" + UUID().uuidString.prefix(8).lowercased() }

    /// The page's top color, the theme the page says.
    static func theme(for tab: Tab) -> RGB? {
        guard let stem = tab.page, let theme = entries.first(where: { $0.stem == stem })?.theme else { return nil }
        let numbers = theme.components(separatedBy: CharacterSet(charactersIn: "0123456789").inverted).compactMap(Int.init)
        guard numbers.count >= 3 else { return nil }
        return RGB(numbers[0], numbers[1], numbers[2])
    }
}
