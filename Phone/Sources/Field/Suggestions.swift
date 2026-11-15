import Foundation

/// The rows of the empty search sheet: where you are about to go. The Mac's
/// Frequent (History.frecency, a site by all its pages) from the places sync
/// holds, weighed against this iPhone's own visits, under what was left
/// unfinished here. No view or store, so each rule can be checked alone.
enum Suggestions {
    struct Pick: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// Words searched for a moment ago.
            case search(String)
            /// The page itself, left unfinished here.
            case page
            /// A site of habit, its home page.
            case site
        }

        var kind: Kind
        var url: String
        var title: String
        var host: String
    }

    /// How long a page counts as unfinished.
    static let unfinishedHours = 6.0
    static let unfinishedRows = 2
    /// This iPhone's share of a habit at most, one visit in `fullVisits` for
    /// each: with little history of its own the Mac leads.
    static let phoneWeight = 0.6
    static let fullVisits = 150.0
    /// A site at least this share of its visits in this part of the day.
    static let dayPartShare = 0.4
    static let dayPartBoost = 1.6
    /// Shown this often from the Mac and never opened here: it counts for less.
    static let unopenedShows = 5
    static let unopenedCost = 0.5

    struct Input {
        var visits: [BrowserVisit]
        var places: [SyncedPlace]
        var own: String?
        var current: String?
        var engineHost: String?
        var removed: Set<String> = []
        var shown: [String: Int] = [:]
        var now: Date
        var hour: Int
        var limit: Int
    }

    static func make(_ input: Input) -> [Pick] {
        let visits = input.visits.filter { offered($0.url, input) }
        var picks: [Pick] = []
        var used = Set<String>()
        var titles = Set<String>()
        var searched = false
        let since = input.now.addingTimeInterval(-unfinishedHours * 3600)
        for visit in visits.sorted(by: { $0.visitedAt > $1.visitedAt }) where visit.visitedAt >= since {
            guard picks.count < min(unfinishedRows, input.limit), let url = URL(string: visit.url) else { continue }
            if let words = SearchEngine.googleWords(in: url) {
                if !searched { picks.append(Pick(kind: .search(words), url: visit.url, title: words, host: "")) }
                searched = true
                continue
            }
            let host = bare(url)
            // A link from another app is that app's errand, not yours to come back to.
            guard visit.url != input.current, visit.outside != true || visit.count > 1,
                  host != input.engineHost, !used.contains(host), titles.insert(visit.title.lowercased()).inserted else { continue }
            used.insert(host)
            picks.append(Pick(kind: .page, url: visit.url, title: visit.title, host: host))
        }
        let sites = habits(input, visits: visits).filter { !used.contains($0.host) }
        picks += sites.prefix(max(0, input.limit - picks.count))
        return picks
    }

    /// Every site by what it weighs, most first.
    static func habits(_ input: Input, visits: [BrowserVisit]? = nil) -> [Pick] {
        let visits = (visits ?? input.visits.filter { offered($0.url, input) }).filter { $0.outside != true || $0.count > 1 }
        var here: [String: Double] = [:], mac: [String: Double] = [:]
        var parts: [String: [Int]] = [:], root: [String: String] = [:], scheme: [String: String] = [:]
        for visit in visits {
            guard let url = URL(string: visit.url) else { continue }
            let host = bare(url)
            here[host, default: 0] += score(count: visit.count, typed: 0, last: visit.visitedAt, now: input.now)
            for (at, n) in (visit.parts ?? []).enumerated() { parts[host, default: [0, 0, 0, 0]][at] += n }
            if isHome(url) { root[host] = visit.title }
            scheme[host] = url.scheme
        }
        for place in input.places where place.device == nil || place.device != input.own {
            // Each address read once: a Mac's weeks of places are thousands.
            guard let url = URL(string: place.url), offered(url, input) else { continue }
            let host = bare(url)
            mac[host, default: 0] += score(count: 1, typed: place.typed ? 1 : 0,
                                           last: Date(timeIntervalSince1970: place.last), now: input.now)
            if isHome(url), root[host] == nil { root[host] = place.title }
            if scheme[host] == nil { scheme[host] = url.scheme }
        }
        let hereTotal = max(here.values.reduce(0, +), .leastNonzeroMagnitude)
        let macTotal = max(mac.values.reduce(0, +), .leastNonzeroMagnitude)
        let opened = Double(visits.reduce(0) { $0 + $1.count })
        let phone = mac.isEmpty ? 1 : min(phoneWeight, opened / fullVisits)
        let part = dayPart(input.hour)
        let weighed = Set(here.keys).union(mac.keys).filter { $0 != input.engineHost }.map { host -> (Pick, Double) in
            var value = phone * (here[host] ?? 0) / hereTotal + (1 - phone) * (mac[host] ?? 0) / macTotal
            if let counts = parts[host], case let all = counts.reduce(0, +), all > 0,
               Double(counts[part]) / Double(all) >= dayPartShare { value *= dayPartBoost }
            if here[host] == nil, input.shown[host, default: 0] >= unopenedShows { value *= unopenedCost }
            let page = Pick(kind: .site, url: (scheme[host] ?? "https") + "://" + host + "/",
                            title: name(of: host, home: root[host]), host: host)
            return (page, value)
        }
        return weighed.sorted { $0.1 == $1.1 ? $0.0.host < $1.0.host : $0.1 > $1.1 }.map(\.0)
    }

    /// The Mac's History.frecency.
    static func score(count: Int, typed: Int, last: Date, now: Date) -> Double {
        Double(count + 2 * typed) * exp(-max(0, now.timeIntervalSince(last) / 86_400) / 30)
    }

    /// Morning, day, evening, night.
    static func dayPart(_ hour: Int) -> Int {
        switch hour {
        case 5..<11: 0
        case 11..<17: 1
        case 17..<23: 2
        default: 3
        }
    }

    /// Whether a page may be offered at all.
    static func offered(_ url: String, _ input: Input) -> Bool {
        guard let page = URL(string: url) else { return false }
        return offered(page, input)
    }

    static func offered(_ page: URL, _ input: Input) -> Bool {
        guard ["http", "https"].contains(page.scheme?.lowercased() ?? ""), !HistoryList.signInStep(page) else { return false }
        let host = bare(page)
        return !desktopOnly(host) && !input.removed.contains(host) && !host.hasPrefix("login.") && !host.hasPrefix("accounts.")
    }

    /// Addresses that lead nowhere from a phone: this computer, its network.
    static func desktopOnly(_ host: String) -> Bool {
        if host == "localhost" || host.isEmpty { return true }
        if [".localhost", ".local", ".internal", ".lan", ".test"].contains(where: host.hasSuffix) { return true }
        if host.contains(":") { return true }
        return host.split(separator: ".").allSatisfy { Int($0) != nil }
    }

    static func bare(_ url: URL) -> String {
        let host = url.host()?.lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func isHome(_ url: URL) -> Bool { url.path.isEmpty || url.path == "/" }

    /// A site's name: its home page's title up to the tagline ("GitHub: Let's
    /// build from here"), or the word before its domain.
    static func name(of host: String, home: String?) -> String {
        let cut = home?.components(separatedBy: CharacterSet(charactersIn: ":|·/\u{2014}\u{2013}")).first?
            .components(separatedBy: " - ").first?.trimmingCharacters(in: .whitespaces)
        if let cut, !cut.isEmpty, cut.count <= 24 { return cut }
        let labels = host.split(separator: ".").map(String.init)
        let word = labels.count > 1 ? labels[labels.count - 2] : host
        return word.prefix(1).uppercased() + word.dropFirst()
    }
}

/// What the sheet remembers of its rows, on this iPhone only.
@MainActor
enum SuggestionMemory {
    private static let removedKey = "suggestions.removed", shownKey = "suggestions.shown"
    private static var defaults: UserDefaults { .standard }

    static var removed: Set<String> { Set(defaults.stringArray(forKey: removedKey) ?? []) }
    static var shown: [String: Int] { defaults.dictionary(forKey: shownKey) as? [String: Int] ?? [:] }

    static func remove(_ host: String) { defaults.set(Array(removed.union([host])).sorted(), forKey: removedKey) }

    /// A field opening makes its rows more than once: one showing, however often.
    private static var counted = Date.distantPast

    static func count(_ hosts: [String], now: Date = Date()) {
        guard now.timeIntervalSince(counted) > 30 else { return }
        counted = now
        var all = shown
        for host in hosts { all[host, default: 0] += 1 }
        defaults.set(all, forKey: shownKey)
    }
}
