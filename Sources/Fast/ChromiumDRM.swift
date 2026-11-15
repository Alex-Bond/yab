import Foundation

/// A deliberately bounded list: never match arbitrary substrings or all Amazon pages.
/// FairPlay availability still depends on the service and the installed WebKit.
enum ChromiumDRM {
    static let domains = ["spotify.com", "netflix.com", "disneyplus.com", "primevideo.com",
                          "tv.apple.com", "music.apple.com", "max.com", "hbomax.com", "hbo.com",
                          "hulu.com", "peacocktv.com", "paramountplus.com"]

    static func matches(host: String, domain: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == domain || host.hasSuffix("." + domain)
    }

    static func requiresWebKit(_ url: URL?) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host else { return false }
        return (domains + testDomains).contains { matches(host: host, domain: $0) }
    }

    /// Isolated acceptance only: a local host standing in for a service on the list.
    private static var testDomains: [String] {
        Store.testing ? (Store.settings.stringArray(forKey: "drm.test.domains") ?? []) : []
    }
}
