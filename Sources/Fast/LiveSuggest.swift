import Foundation

/// What Live Folders offers first: the sources whose sites this Mac's own
/// history goes to most, and the GitHub repositories opened most. Read only
/// once the person has turned Live Folders on, and never sent anywhere.
enum LiveSuggest {
    struct Use: Equatable {
        let source: String
        let visits: Int
        /// GitHub's repositories or Linear's workspaces, most opened first.
        let groups: [String]
    }

    /// A source is offered first from this many visits in the window.
    static let enough = 10

    /// github.com's own pages, never a repository's owner.
    static let notRepos: Set<String> = [
        "about", "account", "apps", "codespaces", "collections", "contact", "copilot", "customer-stories", "dashboard",
        "enterprise", "explore", "features", "issues", "login", "logout", "marketplace", "new", "notifications",
        "orgs", "organizations", "pricing", "pulls", "search", "security", "sessions", "settings", "signup",
        "site", "sponsors", "stars", "topics", "trending", "users",
    ]

    /// This Mac's visits in the window, as plain pairs of address and count.
    @MainActor
    static func visits(days: Int = 30, now: Date = Date()) -> [(url: String, count: Int)] {
        History.current.visits(since: now.addingTimeInterval(-Double(days) * 86_400)).map { ($0.url, $0.count) }
    }

    /// The sources these visits use, most first. Visits to a repository
    /// already `followed` by a folder of its own are that folder's, so they
    /// neither name nor raise GitHub's pull requests.
    static func uses(_ visits: [(url: String, count: Int)], followed: Set<String> = []) -> [Use] {
        let followed = Set(followed.map { $0.lowercased() })
        var counts: [String: Int] = [:]
        var groups: [String: [String: Int]] = [:]
        for visit in visits {
            guard let url = URL(string: visit.url), let host = url.host()?.lowercased(), visit.count > 0 else { continue }
            let parts = url.path.split(separator: "/").map(String.init)
            if host == "github.com" || host == "www.github.com" {
                // Issues pages count for the issues folder; the rest of
                // GitHub for pull requests, the folder most people want.
                let issues = parts.count >= 3 && parts[2] == "issues" || parts.first == "issues"
                if !issues, let full = repo(parts), followed.contains(full.lowercased()) { continue }
                counts[issues ? "github.issues" : "github.pulls", default: 0] += visit.count
                if let full = repo(parts) { groups["github.pulls", default: [:]][full, default: 0] += visit.count }
                continue
            }
            guard let source = LiveSource.all.first(where: { offered($0.id) && $0.owns(host) }) else { continue }
            counts[source.id, default: 0] += visit.count
            if source.id == "linear", let workspace = parts.first { groups["linear", default: [:]][workspace, default: 0] += visit.count }
        }
        return counts.map { id, visits in
            let named = (groups[id] ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
            return Use(source: id, visits: visits, groups: Array(named.prefix(3)))
        }
        .sorted { $0.visits != $1.visits ? $0.visits > $1.visits : $0.source < $1.source }
    }

    /// The repositories opened most, for following one.
    @MainActor
    static func repos(days: Int = 30, now: Date = Date()) -> [(name: String, visits: Int)] {
        repos(History.current.visits(since: now.addingTimeInterval(-Double(days) * 86_400)).map { ($0.url, $0.count) })
    }

    static func repos(_ visits: [(url: String, count: Int)]) -> [(name: String, visits: Int)] {
        var counts: [String: Int] = [:]
        for visit in visits {
            guard let url = URL(string: visit.url), let host = url.host()?.lowercased(),
                  host == "github.com" || host == "www.github.com",
                  let full = repo(url.path.split(separator: "/").map(String.init)) else { continue }
            counts[full, default: 0] += visit.count
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// The sources a person adds by hand: not a page's feed, a search or a
    /// routine's, which come their own ways.
    static func offered(_ id: String) -> Bool { LiveGitService.of(id) == nil && !["feed", "github.search", "routine"].contains(id) }

    private static func repo(_ parts: [String]) -> String? {
        guard parts.count >= 2, !notRepos.contains(parts[0].lowercased()) else { return nil }
        return parts[0] + "/" + parts[1]
    }
}
