import Foundation
import WebKit

// claude.ai shows an artifact in a frame of its own site,
// <id>.frame.claudeusercontent.com, one site per artifact (both names are
// on the public suffix list). The frame's first load trades a token for a
// cookie, `Partitioned` (CHIPS), and every script it loads after that is
// answered only with the cookie: without it, 403, and the viewer says
// "This browser isn't supported" (feedback #252).
//
// Safari keeps that cookie: tracking prevention blocks a framed site's
// cookies but lets a partitioned one through, kept for the site framing
// it. Yab has tracking prevention off (LastingSignIns), and with it off
// WebKit takes no partitioned cookie either; the rule left, "allow from
// websites I visit", lets a frame set cookies only for a site that has
// some already, and a site made for one artifact never has.
//
// So, for the hosts below and only in a frame, the host gets a cookie of
// its own just before the frame loads: one that says nothing, ours, for a
// day. The site counts as one with cookies, and the cookie it sets itself
// is kept for it, unpartitioned, which changes nothing here: the host is
// one artifact's and only claude.ai frames it.
// evals/claude-artifacts/run.sh shows each rule's outcome on two local sites.
enum FrameGrants {
    /// Sites that hand a frame its cookie and need it back.
    static let suffixes = [".claudeusercontent.com"]
    static let name = "yab_frame"

    @MainActor private static var seeded: [ObjectIdentifier: Set<String>] = [:]

    /// Whether a frame's load at `url` wants a seed: a frame (not the
    /// page), https, one of the hosts above.
    static func wants(_ url: URL, mainFrame: Bool) -> Bool {
        guard !mainFrame, url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased() else { return false }
        return suffixes.contains { host.hasSuffix($0) } || testHosts.contains(host)
    }

    /// A test world's own framed hosts (evals/claude-artifacts/check.py: a
    /// local site standing in for claudeusercontent.com).
    private static let testHosts: Set<String> = {
        guard Store.testing, let list = Store.settings.string(forKey: "frameGrants.hosts") else { return [] }
        return Set(list.lowercased().split(separator: ",").map(String.init))
    }()

    /// Seeds the host's cookie in `store`, then `then`. Straight to `then`
    /// for a store that keeps WebKit's own rules (a private window's), or
    /// a host seeded already.
    @MainActor static func seed(_ url: URL, in store: WKWebsiteDataStore, then: @escaping () -> Void) {
        guard store.isPersistent, let host = url.host()?.lowercased(),
              !seeded[ObjectIdentifier(store), default: []].contains(host),
              let cookie = HTTPCookie(properties: [
                  .name: name, .value: "1", .domain: host, .path: "/", .secure: "TRUE",
                  .expires: Date().addingTimeInterval(86_400),
              ]) else {
            then()
            return
        }
        seeded[ObjectIdentifier(store), default: []].insert(host)
        store.httpCookieStore.setCookie(cookie) { then() }
    }
}
