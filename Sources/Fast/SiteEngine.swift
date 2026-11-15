import Foundation

/// Exact HTTP(S) hosts, like the host-keyed permissions in Store.settings.
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
        guard let host = Self.host(url), let raw = store.string(forKey: "site.engine." + host) else { return .recommended }
        return SiteEngineChoice(rawValue: raw) ?? .recommended
    }

    @discardableResult
    func set(_ choice: SiteEngineChoice, for url: URL) -> Bool {
        guard let host = Self.host(url) else { return false }
        let key = "site.engine." + host
        if choice == .recommended { store.removeObject(forKey: key) }
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
        if let engineHeld { return engineHeld == .webKit }
        switch engineFactory.sites.choice(for: url) {
        case .chromium: return false
        case .webKit: return true
        case .recommended:
            if let builtIn = engineFactory.sites.builtIn(for: url) { return builtIn.kind == .webKit }
            return emeFailure
        }
    }

    /// App navigation policy allowed this main-frame request, but WebKit has
    /// not supplied native beforeunload approval. Reserve the original document
    /// through the same transaction as an explicit engine selection.
    func routeSiteEngine(_ request: URLRequest) async throws -> Bool {
        guard engineFactory.kinds.contains(.chromium), engineHeld == nil, let target = request.url,
              let old = builtPage, old.engine == .webKit,
              engineFactory.resolved(.webKit, at: target) == .chromium else { return false }
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
                self?.engineFactory.sites.set(choice, for: target)
            })
        ])
    }
}

enum SiteEngineError: Error {
    case noHost, unavailable, profileChanged
}
