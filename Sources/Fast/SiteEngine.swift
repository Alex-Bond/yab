import Foundation

/// HTTP(S) hosts, with the conventional www alias sharing a site's rule.
/// Recommended is represented by absence, so resetting leaves no stale override.
enum SiteEngineChoice: String, Codable, CaseIterable, Sendable {
    case recommended, chromium, webKit
}

@MainActor
struct SiteEngineSettings {
    static let shared = SiteEngineSettings(store: Store.settings)
    let store: UserDefaults

    static func host(_ url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let raw = url.host, !raw.isEmpty else { return nil }
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host.isEmpty ? nil : host
    }

    func choice(for url: URL?) -> SiteEngineChoice {
        guard let host = Self.host(url) else { return .recommended }
        // An exact entry always wins. Settings accepts youtube.com while
        // links and history commonly open www.youtube.com (and vice versa).
        // Do not inherit a rule from any other parent or sibling host.
        let alias = host.hasPrefix("www.") ? String(host.dropFirst(4)) : "www." + host
        for candidate in [host, alias] {
            if let raw = store.string(forKey: "site.engine." + candidate),
               let choice = SiteEngineChoice(rawValue: raw), choice != .recommended { return choice }
        }
        return .recommended
    }

    @discardableResult
    func set(_ choice: SiteEngineChoice, for url: URL) -> Bool {
        guard let host = Self.host(url) else { return false }
        let key = "site.engine." + host
        if choice == .recommended {
            store.removeObject(forKey: key)
            // Auto clears the effective site's rule too, when this page
            // inherited it from the other spelling. Settings' row removal
            // (setOwn) still removes only the exact row the owner selected.
            let alias = host.hasPrefix("www.") ? String(host.dropFirst(4)) : "www." + host
            store.removeObject(forKey: "site.engine." + alias)
        }
        else { store.set(choice.rawValue, forKey: key) }
        return true
    }
}

@MainActor
extension PageEngineFactory {
    /// Own rule, then built-in rule, then the default (EngineRules). A tab
    /// already in fallback keeps it: `current` is the default here. Memory
    /// is Auto's to look at only as a tab opens or wakes (opening(_:)).
    /// Explicit Chromium suppresses both the service list and EME fallback.
    func resolved(_ current: PageEngineKind, at url: URL?) -> PageEngineKind {
        resolved(sites.decide(current, at: url, tight: false).kind)
    }
}

@MainActor
extension Tab {
    var siteEngineChoice: SiteEngineChoice { engineFactory.sites.choice(for: address) }
    var engineProfileMatches: Bool {
        guard siteEngineProfile == chromiumProfile else { return false }
        return (builtPage as? ChromiumPage).map { $0.profile == chromiumProfile } ?? true
    }

    func wantsWebKit(for url: URL, emeFailure: Bool = false) -> Bool {
        if ChromePages.needsChromium(url) { return false }
        if EngineRules.onlyWebKit(url) { return true }
        if let engineHeld { return engineHeld == .webKit }
        switch engineFactory.sites.choice(for: url) {
        case .chromium: return false
        case .webKit: return true
        case .recommended:
            if let builtIn = engineFactory.sites.builtIn(for: url) { return builtIn.kind == .webKit }
            // A player's refusal moves the page under Auto; Chromium picked by
            // name as the default keeps it, as a site's own Chromium does: the
            // built-in rules, listed and overridable, still apply (#1605).
            return (emeFailure && !engineFactory.sites.chromiumByName) || protectsVideo(at: url)
        }
    }

    /// The site of an address as the protected-video move keeps it: its
    /// registrable domain, so a player's own subdomains stay with it.
    static func protectedSite(_ url: URL?) -> String? {
        SiteEngineSettings.host(url).map(Vault.registrable)
    }

    /// Whether `url` is on the site whose player refused Chromium's missing
    /// Widevine in this tab (feedback #1605): WebKit there, and only there.
    func protectsVideo(at url: URL?) -> Bool {
        guard let engineProtectedSite else { return false }
        return Self.protectedSite(url) == engineProtectedSite
    }

    /// Whether a WebKit page's next main-frame navigation goes to Chromium:
    /// a rule says Chromium, or the tab's default is Chromium and nothing
    /// keeps the destination on WebKit (an own or built-in rule, the site
    /// whose protected video moved the tab). Without the second half a tab
    /// Yab moved for one site's video stayed on WebKit for every site after
    /// it, under "Auto (Chromium)" and "For its protected video" (#1605).
    /// The second half takes only a person's GET (`byPerson`): a redirect
    /// is a hop of a flow under way, a sign-in's way out and back, which
    /// stays on the engine it started on. A window another page opened
    /// stays too: the move would cut window.opener.
    func routesToChromium(_ target: URL, byPerson: Bool = true, method: String? = "GET") -> Bool {
        if engineFactory.resolved(.webKit, at: target) == .chromium { return true }
        guard byPerson, (method ?? "GET").uppercased() == "GET", chromiumDRMEnabled, opener == nil,
              SiteEngineSettings.host(target) != nil else { return false }
        return !wantsWebKit(for: target) && engineFactory.resolved(.chromium, at: target) == .chromium
    }

    /// App navigation policy allowed this main-frame request, but WebKit has
    /// not supplied native beforeunload approval. Reserve the original document
    /// through the same transaction as an explicit engine selection.
    func routeSiteEngine(_ request: URLRequest, byPerson: Bool = false) async throws -> Bool {
        // Yab's own load (typed, a bookmark, a link from another app) is a
        // person's too, whatever WebKit's action says of it; its host, as an
        // address typed with http:// may be asked for over https.
        let sent = SiteEngineSettings.host(request.url).map { $0 == SiteEngineSettings.host(engineSent) } ?? false
        if sent { engineSent = nil }
        guard engineFactory.kinds.contains(.chromium), let target = request.url,
              engineHeld == nil || ChromePages.needsChromium(target),
              let old = builtPage, old.engine == .webKit,
              routesToChromium(target, byPerson: byPerson || sent, method: request.httpMethod) else { return false }
        do {
            guard engineProfileMatches else { throw SiteEngineError.profileChanged }
            try await EngineSwitchTransaction.execute([
                .init(tab: self, engine: .chromium, request: ChromiumDRMNavigation.webKitDocument(request))
            ])
        } catch {
            // The navigation is cancelled and the page stays: never without a word.
            engineSwitchFailed(error, to: .chromium)
            throw error
        }
        return engineKind == .chromium
    }

    /// Shared by the future site-menu control and the isolated bench. No UI here.
    /// An asleep tab remembers the choice without starting either engine.
    func setSiteEngineChoice(_ choice: SiteEngineChoice) async throws {
        guard !gone, let target = address, SiteEngineSettings.host(target) != nil else { throw SiteEngineError.noHost }
        guard choice != .chromium || engineFactory.kinds.contains(.chromium) else { throw SiteEngineError.unavailable }
        guard builtPage == nil || engineProfileMatches else { throw SiteEngineError.profileChanged }
        let automatic: PageEngineKind = chromiumDRMEnabled ? .chromium : .webKit
        let wanted: PageEngineKind
        switch choice {
        case .recommended: wanted = engineFactory.resolved(engineFactory.sites.builtIn(for: target)?.kind ?? automatic)
        case .chromium: wanted = .chromium
        case .webKit: wanted = .webKit
        }
        // The rule and the hold go before the destination is built: its first
        // navigation reads them, and would route straight back otherwise.
        try await EngineSwitchTransaction.execute([
            .init(tab: self, engine: wanted, request: URLRequest(url: target), installing: { [weak self] in
                self?.engineHeld = nil
                // A choice made here starts the site afresh, Auto included.
                self?.engineProtectedSite = nil
                self?.engineFactory.sites.set(choice, for: target)
            })
        ])
    }
}

enum SiteEngineError: Error {
    case noHost, unavailable, profileChanged
}
