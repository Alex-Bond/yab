import Foundation

/// Page keys for reusing finished agents' disposable tabs. User tabs are never candidates.
enum TabReuse {
    /// Query keys that only say where a link came from, left out when
    /// telling whether two addresses are the same page.
    static let tracking: Set<String> = ["fbclid", "gclid", "dclid", "msclkid", "igshid", "mc_cid", "mc_eid", "ref_src"]

    /// The site, for "the same site": its host, without www., and its port
    /// when it names one.
    static func site(_ url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host + (url.port.map { ":\($0)" } ?? "")
    }

    /// The page, for "the same page": the site, the path without a slash at
    /// its end, and the query without tracking keys or its order; never the
    /// fragment.
    static func page(_ url: URL?) -> String? {
        guard let url, let site = site(url),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let query = (parts.queryItems ?? [])
            .filter { item in
                let name = item.name.lowercased()
                return !name.hasPrefix("utm_") && !tracking.contains(name)
            }
            .map { "\($0.name)=\($0.value ?? "")" }
            .sorted()
            .joined(separator: "&")
        return site + path + (query.isEmpty ? "" : "?" + query)
    }
}

@MainActor
extension Bench {
    /// A tab a finished agent left on the same page, waiting to be put away
    /// (AgentTabCleanup), that nobody is looking at or using: the next run
    /// takes it over rather than opening another copy beside it, so a check
    /// every few minutes keeps one tab, not a pile of them.
    func leftover(_ url: URL, space: UUID?, session: String?, in browser: Browser) -> Tab? {
        let agents = Agents.shared
        guard let session, session != Agents.script, let page = TabReuse.page(url) else { return nil }
        let store = Spaces.store(for: space ?? browser.spaceID)
        let assistant = agents.session(session)?.assistantID
        let candidates = assistant == nil ? browser.tabs : browser.everyTab
        return candidates.last { tab in
            if let assistant {
                guard agents.session(tab.agent)?.assistantID == assistant,
                      tab.assistantSpace == (space ?? browser.spaceID) else { return false }
            }
            guard tab.bench, !tab.shy, !tab.popup, tab.store === store, let owner = tab.agent,
                  owner != session, owner != Agents.script, agents.session(owner)?.state.live != true,
                  tab.unread == nil, tab.answer == nil, tab.pin == nil, !tab.kept, tab.guest == nil,
                  tab.handoff == nil, tab.permit == nil, !browser.onScreen(tab.id),
                  !tab.draft, !tab.typing, !tab.noisy, !tab.onCall, !tab.pictureInPicture else { return false }
            return TabReuse.page(tab.address ?? tab.pending) == page
        }
    }
}
