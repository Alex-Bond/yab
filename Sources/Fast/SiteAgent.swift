import Foundation
import WebKit

/// Sites that keep a feature from Safari by its name though WebKit can run
/// it, told Yab is Chrome. Slack starts huddles only in Chrome and Firefox
/// ("the only browsers that support huddles"): told Safari, it has no
/// huddle button at all. Only these hosts, only their main frames; every
/// other site hears Yab's own Safari agent (Web.userAgentName).
///
/// Sites that offer their Chrome extension only to Chrome (`extensionHosts`)
/// are told more. Yab installs Chrome Web Store extensions, but told Safari
/// these pages offer a Mac app or a Safari extension instead, and they ask
/// in the page, not by the agent alone: Superhuman's download page offers
/// "Add to Chrome" only where `window.chrome` exists and `navigator.vendor`
/// is "Google Inc.", the common test. On them the page's own world also
/// gets Chrome's vendor, `userAgentData` and a `window.chrome`
/// (chrome-like.js, armed by PageScripts).
enum SiteAgent {
    static let chromeHosts: Set<String> = ["app.slack.com"]

    /// Download and sign-up pages that hand out a Chrome extension, by
    /// their host without "www.".
    /// Told Safari, Honey offers only "Add to Safari".
    static let extensionHosts: Set<String> = ["superhuman.com", "joinhoney.com"]

    /// Superhuman's installed extension is insufficient while its mail
    /// app still detects Safari. The app also checks appVersion and the
    /// legacy FileSystem API, supplied through PageScripts.
    static let extensionAppHosts: Set<String> = ["mail.superhuman.com"]

    /// A host as PageScripts' Arming names it (lower case, no "www.") that
    /// is told it is in Chrome down to the page's own globals.
    static func chromeLike(_ host: String?) -> Bool {
        guard let host else { return false }
        return extensionHosts.contains(host) || extensionAppHosts.contains(host)
    }

    /// Chrome on a Mac, at about the version stable Chrome has today: one
    /// every four weeks since 141 on 2025-09-30, so a site that turns old
    /// Chromes away doesn't turn this one away a year on.
    static func chrome(on day: Date = Date()) -> String {
        head + "\(version(on: day)).0.0.0 Safari/537.36"
    }

    /// Chrome's major version in that agent.
    static func version(on day: Date = Date()) -> Int {
        let start = Date(timeIntervalSince1970: 1_759_190_400)  // 2025-09-30
        return 141 + max(0, Int(day.timeIntervalSince(start) / (28 * 86_400)))
    }

    /// The agent a page at this address goes with: Chrome's for the hosts
    /// above, nil (Yab's own) anywhere else.
    static func agent(for url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), url?.scheme?.lowercased() == "https" else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard chromeHosts.contains(host) || chromeLike(bare) else { return nil }
        return chrome()
    }

    /// Before a main frame loads `url`: the view's agent made the one that
    /// address goes with. True when it changed, so the load is asked again
    /// with it in its own request too. Another agent (Developer Mode's
    /// Device) is left as it is.
    @MainActor static func apply(_ web: WKWebView, for url: URL) -> Bool {
        let now = web.customUserAgent ?? ""
        if !now.isEmpty, !isOurs(now) { return false }
        let wanted = agent(for: url) ?? ""
        guard now != wanted else { return false }
        web.customUserAgent = wanted.isEmpty ? nil : wanted
        return true
    }

    static let head = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/"

    static func isOurs(_ agent: String) -> Bool {
        agent.hasPrefix(head) && agent.hasSuffix(".0.0.0 Safari/537.36")
    }
}
