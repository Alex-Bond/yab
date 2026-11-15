import CryptoKit
import Foundation

// Anti-phishing, opt-in (Settings › Privacy): a list of bad hosts kept on
// this Mac, checked before a page comes up. What the list holds is the
// whole SHA-256 of each host, not the host, and a warning needs the whole
// hash to match: a four-byte prefix alone would stop about one host in
// ten thousand that was never listed, and asking a server to confirm it
// would tell that server where you were going. Nothing
// about a page or a visit leaves the Mac: the list is downloaded whole,
// like a content blocker's rules, and the answer is Yab's own. Off by
// default, as everything that reaches the network is; on, it is fetched
// once a day and a flagged site asks before it loads, in the tab, once a
// session: going on keeps it until Yab quits.
//
// The check fails open. No list, no feed, a broken file: pages load as
// they always did; this is a warning before a page, not a wall.

/// The site Yab stopped for, for the page that stands in its place.
struct Flagged: Equatable {
    let host: String
    let url: URL
}

@MainActor
enum SafeBrowsing {
    /// Settings' own key, read by @AppStorage (Settings › Privacy) and by
    /// the extension shim's chrome "privacy.services.safeBrowsingEnabled".
    static let key = "safe.browsing"

    static var on: Bool {
        Store.settings.bool(forKey: key)
    }

    // MARK: - the list

    /// Beside the rest of what the app keeps; the tests point it elsewhere.
    static var file = Store.file("phishing-hashes.json")
    /// A day between fetches, as the update check's own rhythm goes.
    static let stale: TimeInterval = 24 * 3600

    /// The hashes as loaded, nil until read (or found absent).
    private static var kept: (hashes: Set<String>, at: Date)?

    static func load() -> (hashes: Set<String>, at: Date)? {
        if let kept { return kept }
        guard let data = try? Data(contentsOf: file) else { return nil }
        let read = decode(data)
        kept = read
        return read
    }

    /// `{"updated": <unix seconds>, "hashes": ["64 hex characters", …]}`,
    /// each the SHA-256 of a listed host. Anything else, a list of bare
    /// prefixes included, and the file is refused rather than half-read:
    /// a prefix can't be told from the hosts that share it.
    static func decode(_ data: Data) -> (hashes: Set<String>, at: Date)? {
        guard let read = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hashes = read["hashes"] as? [String] else { return nil }
        let kept = Set(hashes.filter { $0.count == 64 && $0.allSatisfy { $0.isHexDigit } }.map { $0.lowercased() })
        guard !kept.isEmpty else { return nil }
        let at = Date(timeIntervalSince1970: (read["updated"] as? Double) ?? 0)
        return (kept, at)
    }

    /// The one address the check ever goes to: the list itself, whole, from
    /// the feed's own site. Nothing about a page, a visit or an address is
    /// ever asked of anyone, a look in `bad(_:)` is a look in what is
    /// already on this Mac. Over anything but https (in a real copy): no
    /// list, and the check fails open.
    static func listURL(site: URL) -> URL? {
        guard var parts = URLComponents(url: site, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(),
              scheme == "https" || Store.testing,
              !(parts.host ?? "").isEmpty else { return nil }
        // The one address, whatever page or feed it came by: the list,
        // whole, no query, no fragment.
        parts.path = (parts.path.hasSuffix("/") ? parts.path : parts.path + "/") + "lists/phishing.json"
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    /// The list from Yab's site, when the feed names one, when stale, kept
    /// beside the rest of what the app keeps. An empty or broken answer
    /// leaves the last good list alone.
    static func refresh() async {
        guard on, let site = Updater.site, let url = listURL(site: site) else { return }
        let held = load()
        if let held, Date().timeIntervalSince(held.at) < stale { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        guard let (reply, _) = try? await URLSession.shared.data(for: request),
              let fresh = decode(reply) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? reply.write(to: file, options: .atomic)
        kept = fresh
    }

    /// The list kept fresh while the app runs: asked every hour, fetched
    /// when the day since the last one is up, so a Yab up for days has
    /// yesterday's bad sites too. A fetch that fails tries again the next
    /// hour; the list it already has is served meanwhile.
    private static var clock: Timer?
    static func startClock() {
        guard clock == nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
    }

    /// The timer's own turn on the main thread, asking after the list.
    private static func tick() { Task { await refresh() } }

    // MARK: - the check

    /// The hosts a host is asked under: itself (without a leading "www."
    /// too), and the shapes it hangs under, deepest first, so a domain
    /// listed in the list holds its subdomains however deep, as Safe
    /// Browsing asks of a host. An IP address asks as itself, however
    /// long: no label of it belongs to anyone.
    static func asking(host: String) -> [String] {
        let host = host.lowercased()
        if host.contains(":") || host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            return [host]
        }
        var asks = [host]
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if bare != host { asks.append(bare) }
        let labels = bare.split(separator: ".").map(String.init)
        if labels.count > 2 {
            for deep in 2...min(labels.count - 1, 5) {
                let shape = labels.suffix(deep).joined(separator: ".")
                if !asks.contains(shape) { asks.append(shape) }
            }
        }
        return asks
    }

    /// What the list holds of a host: its whole SHA-256, as 64 hex
    /// characters.
    static func hash(_ host: String) -> String {
        SHA256.hash(data: Data(host.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the loaded list holds this address's host. False when the
    /// list is off, missing or empty: the page loads, as failing open.
    static func bad(_ url: URL) -> Bool {
        guard on, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host(), !host.isEmpty,
              let held = load() else { return false }
        return asking(host: host).contains { held.hashes.contains(hash($0)) }
    }

    /// The stop itself: what the tab is told, when the address should not
    /// come up without a word from you. Nil, go ahead, for a host you
    /// already went on to this session, or one under it: going on to
    /// login.evil.example excuses that host and its own subdomains, not
    /// evil.example or its other ones, which still warn.
    static func flag(_ url: URL) -> Flagged? {
        guard bad(url), let host = url.host() else { return nil }
        guard !asking(host: host).contains(where: admitted.contains) else { return nil }
        return Flagged(host: host, url: url)
    }

    /// The sites gone on with, until Yab quits.
    @MainActor private static var admitted: Set<String> = []
    static func admit(_ host: String) { admitted.insert(host.lowercased()) }

    /// What was kept is read again on next use, as at a launch (tests).
    static func reload() {
        kept = nil
        admitted = []
    }

    /// What the list holds now, as Settings' row says of it (tests too).
    static var holding: Int? { load()?.hashes.count }
}

extension Tab {
    /// "Continue to" on the flagged page: the site excused for this
    /// session, and the page again.
    func continuePastFlagged() {
        guard let flagged else { return }
        SafeBrowsing.admit(flagged.host)
        self.flagged = nil
        go(to: flagged.url)
    }

    /// "Go Back" on the flagged page. The flagged page never loaded, so
    /// the page you were on is still the one shown: the warning goes and
    /// that page stays, its address and title again. A tab that never
    /// showed a page (opened for the flagged address) has nothing to go
    /// back to and closes, to the tab it came from when a link opened it.
    func backFromFlagged() {
        guard flagged != nil else { return }
        flagged = nil
        if settleOnShown() { return }
        if onBackAtStart?(self) == true { return }
        onCloseUnshown?(self)
    }
}

extension Browser {
    /// A tab with no page of its own closing from the flagged page, as a
    /// link's window or a peek closes, or as ⌘W closes a tab.
    func closeUnshown(_ tab: Tab) {
        if let link = LinkWindow.all.first(where: { $0.tab === tab }) {
            link.close()
        } else if peeking === tab {
            closePeek()
        } else {
            close(tab)
        }
    }
}
