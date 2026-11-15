import Foundation
import WebKit

// Every source a live folder can have, and the two kinds of folder they
// make (docs/live-folders.md, "Every source Arc promised"). Each reads its
// site the way its own page does, with the space's cookies and no tab, and
// is held to saved answers in LiveTests. These are the sites' own
// addresses, not APIs they promise: a shape that stops parsing reads as
// failed, and the folder keeps what it has.

/// To do: things you finish, gone when done. New for you: things that
/// reached you, gone a day after you open them.
enum LiveKind { case toDo, news }

/// What a source's reading came to.
enum LiveRead: Equatable {
    case items([LiveItem])
    case signedOut
    case failed
}

/// A source, as its menus and the folder's clock know it.
struct LiveSource {
    let id: String
    /// The folder's name.
    let name: String
    /// New Live Folder's line: the service's name too.
    var title: String {
        switch id {
        case "github.pulls": return "GitHub Pull Requests"
        case "github.issues": return "GitHub Issues"
        case "youtube": return "YouTube Subscriptions"
        case "linear": return "Linear"
        default: return name
        }
    }

    /// The service it reads, as "Signed out of GitHub" says it.
    var service: String {
        if let git = LiveGitService.of(id) { return git.name }
        switch site {
        case "github.com": return "GitHub"
        case "linear.app": return "Linear"
        case "youtube.com": return "YouTube"
        default: return name
        }
    }

    /// Where Open on the site in a folder's menu goes.
    func page(_ live: Live) -> URL? {
        if let git = LiveGitService.of(id) { return git.repository(live.host) }
        switch id {
        case "github.pulls": return LiveGitHub.page(host: live.host)
        case "github.issues": return URL(string: LiveGitHub.base(live.host) + "/issues")
        case "github.search": return LiveIssues.searchPage(live)
        case "notion": return URL(string: "https://www.notion.so")
        case "linear": return URL(string: "https://linear.app")
        case "drive": return URL(string: "https://drive.google.com/drive/u/\(live.host)/shared-with-me")
        case "figma": return URL(string: "https://www.figma.com/files/recent")
        case "youtube": return URL(string: "https://www.youtube.com/feed/subscriptions")
        default: return URL(string: live.host).flatMap { $0.host() }.flatMap { URL(string: "https://" + $0) }
        }
    }

    /// Where Sign In goes for a folder signed out: GitHub's own sign-in,
    /// else the folder's page, which sends a signed-out visitor to its
    /// site's sign-in (Drive's to Google's, with the right account).
    func signIn(_ live: Live) -> URL? {
        if id.hasPrefix("github.") { return URL(string: LiveGitHub.base(live.host) + "/login") }
        return page(live)
    }

    /// Whether a page on `host` is this source's site.
    func owns(_ host: String, live: Live? = nil) -> Bool {
        let host = host.lowercased()
        if let git = LiveGitService.of(id) {
            return host == (live.flatMap { git.repository($0.host)?.host()?.lowercased() } ?? git.site)
        }
        if let live, URL(string: LiveGitHub.base(live.host))?.host()?.lowercased() == host { return true }
        guard !site.isEmpty else { return false }
        if id == "notion", host == "app.notion.com" || host.hasSuffix("notion.so") { return true }
        return host == site || host.hasSuffix("." + site)
    }
    let kind: LiveKind
    /// The site whose pages its tabs are, for its pin's card and its menu.
    let site: String
    /// Its lists, as its menu ticks them, and those ticked at first.
    let lists: [(id: String, title: String)]
    let shownAtFirst: [String]
    /// How often it is read while yab is active and the folder shut: a
    /// heavy page less often.
    let every: TimeInterval
    /// Lists of the other kind than the folder's, by id: Linear's mentions
    /// are new for you in a to-do folder (LiveFolder.mixed).
    var listKinds: [String: LiveKind] = [:]

    /// The lists that go by the new-for-you rules in a to-do folder.
    var newsLists: Set<String> {
        kind == .news ? [] : Set(listKinds.filter { $0.value == .news }.keys)
    }

    static let all: [LiveSource] = [
        LiveSource(id: "github.pulls", name: "Pull Requests", kind: .toDo, site: "github.com",
                   lists: LiveGitHub.lists, shownAtFirst: LiveGitHub.shownAtFirst, every: 5 * 60),
        LiveSource(id: "github.issues", name: "Issues", kind: .toDo, site: "github.com",
                   lists: LiveIssues.lists, shownAtFirst: LiveIssues.lists.map(\.id), every: 5 * 60),
        LiveSource(id: "github.search", name: "Search", kind: .toDo, site: "github.com",
                   lists: [], shownAtFirst: [], every: 5 * 60),
        LiveSource(id: "linear", name: "My Issues", kind: .toDo, site: "linear.app",
                   lists: LiveLinear.lists, shownAtFirst: LiveLinear.lists.map(\.id), every: 5 * 60,
                   listKinds: ["mentions": .news]),
        LiveSource(id: "notion", name: "Notion", kind: .news, site: "notion.so",
                   lists: LiveNotion.lists, shownAtFirst: LiveNotion.lists.map(\.id), every: 5 * 60),
        LiveSource(id: "drive", name: "Google Drive", kind: .news, site: "drive.google.com",
                   lists: LiveDrive.lists, shownAtFirst: LiveDrive.lists.map(\.id), every: 15 * 60),
        LiveSource(id: "figma", name: "Figma", kind: .news, site: "figma.com",
                   lists: LiveFigma.lists, shownAtFirst: LiveFigma.lists.map(\.id), every: 10 * 60),
        LiveSource(id: "youtube", name: "Subscriptions", kind: .news, site: "youtube.com",
                   lists: [], shownAtFirst: [], every: 30 * 60),
        LiveSource(id: "feed", name: "Feed", kind: .news, site: "",
                   lists: [], shownAtFirst: [], every: 30 * 60),
        // Kept by a routine (Routines.swift): never read on the clock, its
        // run hands the folder what belongs (folder_update). `host` is the
        // routine's id.
        LiveSource(id: "routine", name: "Folder", kind: .toDo, site: "",
                   lists: [], shownAtFirst: [], every: .infinity),
    ] + LiveGitService.allCases.map { service in
        LiveSource(id: service.sourceID, name: service.name + (service == .sourcehut ? " Tickets" : " Pull Requests"),
                   kind: .toDo, site: service.site, lists: [], shownAtFirst: [], every: 5 * 60)
    }

    static func of(_ id: String) -> LiveSource? { all.first { $0.id == id } }

    /// A folder's source read once, whatever it is.
    @MainActor
    static func read(_ live: Live, store: WKWebsiteDataStore) async -> LiveRead {
        switch live.source {
        case "github.pulls": return await LiveGitHub.read(live, store: store)
        case "github.issues": return await LiveIssues.read(live, store: store)
        case "github.search": return await LiveIssues.search(live, store: store)
        case "notion": return await LiveNotion.read(live, store: store)
        case "linear": return await LiveLinear.read(live, store: store)
        case "drive": return await LiveDrive.read(live, store: store)
        case "figma": return await LiveFigma.read(live, store: store)
        case "youtube": return await LiveYouTube.read(live, store: store)
        case "feed": return await LiveFeed.read(live, store: store)
        default:
            if let git = LiveGitService.of(live.source) { return await git.read(live, store: store) }
            return .failed
        }
    }
}

extension Live {
    /// Its source's lists shown: a folder made before its source had any
    /// (Linear's, saved with none) shows those a new one would.
    var shown: [String] {
        show.isEmpty ? LiveSource.of(source)?.shownAtFirst ?? [] : show
    }
}

extension LiveFolder {
    /// A news folder holds this many at most.
    static let fewest = 12

    /// What a new-for-you source's answer changes: what reached you comes in
    /// once, at the top, never again once it has been shown; a tab goes a
    /// day after you opened it, or a week after it came unopened. On the
    /// first reading only what is fresh comes in: a folder made today isn't
    /// filled with last month.
    static func news(_ items: [LiveItem], held: [Held], shown: Set<String>, hidden: Set<String>, first: Bool,
                     now: Date = Date()) -> LiveDiff {
        var out = LiveDiff()
        let listed = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var have = Set<String>()
        for tab in held {
            guard let key = tab.key else { continue }
            have.insert(key)
            if let item = listed[key], item.words != tab.words, !tab.busy, tab.opened == nil { out.words[tab.id] = item.words }
            guard tab.brought, !tab.busy else { continue }
            if hidden.contains(key) { out.remove.append(tab.id); continue }
            if let opened = tab.opened, now.timeIntervalSince(opened) > 24 * 3600 { out.remove.append(tab.id); continue }
            if tab.opened == nil, let came = tab.came, now.timeIntervalSince(came) > 7 * 24 * 3600 { out.remove.append(tab.id) }
        }
        var room = fewest - (held.count - out.remove.count)
        let fresh: (LiveItem, Int) -> Bool = { item, index in
            guard first else { return true }
            if let at = item.updated { return now.timeIntervalSince(at) < 3 * 24 * 3600 }
            return index < 5
        }
        for (index, item) in items.enumerated() where room > 0 {
            guard !have.contains(item.key), !shown.contains(item.key), !hidden.contains(item.key), fresh(item, index) else { continue }
            out.add.append(item)
            have.insert(item.key)
            room -= 1
        }
        return out
    }
}

// MARK: - GitHub's pull requests, read

extension LiveGitHub {
    @MainActor
    static func read(_ live: Live, store: WKWebsiteDataStore) async -> LiveRead {
        var answers: [(list: String, pulls: [Pull])] = []
        var personal: [LiveItem] = []
        for list in live.show {
            if let query = personalQuery(list) {
                let search = Live(source: "github.search", host: live.host, show: [], query: query)
                switch await LiveIssues.search(search, store: store) {
                case .items(let found): personal.append(contentsOf: found)
                case .signedOut: return .signedOut
                case .failed: return .failed
                }
                continue
            }
            guard let url = queryURL(host: live.host, list: list),
                  let answer = try? await LiveReader.get(url, store: store) else { return .failed }
            switch await LiveText.off("live.parse", { pulls(answer.data, status: answer.status, finalURL: answer.url) }) {
            case .pulls(let found): answers.append((list, found))
            case .signedOut: return .signedOut
            case .failed: return .failed
            }
        }
        let ids = Array(Set(answers.flatMap { $0.pulls.map(\.id) })).prefix(90)
        var statuses: [String: Status] = [:]
        if !ids.isEmpty, let url = deferredURL(host: live.host, ids: Array(ids)),
           let answer = try? await LiveReader.get(url, store: store), answer.status == 200 {
            statuses = await LiveText.off("live.parse") { LiveGitHub.statuses(answer.data) }
        }
        return .items(items(answers, statuses: statuses, hiddenGroups: Set(live.hidden), personal: personal))
    }
}

// MARK: - GitHub's issues

/// GitHub's issue search, in JSON as its search page asks for it.
enum LiveIssues {
    static let lists: [(id: String, title: String)] = [
        ("assignee", "Assigned to You"),
        ("author", "Created by You"),
        ("mentions", "Mentioning You"),
    ]

    static func searchURL(host: String, list: String) -> URL? {
        var parts = URLComponents(string: LiveGitHub.base(host) + "/search")
        parts?.queryItems = [URLQueryItem(name: "q", value: "is:issue is:open archived:false \(list):@me"),
                             URLQueryItem(name: "type", value: "issues")]
        return parts?.url
    }

    struct Issue: Equatable {
        var number: Int
        var title: String
        var repo: String
        var created: Date?
        /// A pull request, not an issue: its page is /pull/n.
        var pull = false
    }

    /// A search page's words and kind, when a tab shows one: GitHub's
    /// search, or /pulls and /issues with a query.
    static func search(in url: URL?) -> (query: String, pulls: Bool)? {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = parts.queryItems?.first(where: { $0.name == "q" })?.value, !raw.isEmpty else { return nil }
        // A form's query: "+" is a space.
        let query = raw.replacingOccurrences(of: "+", with: " ")
        let type = parts.queryItems?.first(where: { $0.name == "type" })?.value
        switch url.path {
        case "/search": return type == "pullrequests" || type == "issues" ? (query, type == "pullrequests") : nil
        case "/pulls": return (query, true)
        case "/issues": return (query, false)
        default: return nil
        }
    }

    static func searchPage(_ live: Live) -> URL? {
        guard let query = live.searched() else { return nil }
        var parts = URLComponents(string: LiveGitHub.base(live.host) + "/search")
        parts?.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "type", value: query.contains("is:pr") ? "pullrequests" : "issues")]
        return parts?.url
    }

    /// A search kept as a folder: what it finds now, a pull request's or
    /// an issue's own page each.
    @MainActor
    static func search(_ live: Live, store: WKWebsiteDataStore) async -> LiveRead {
        guard let url = searchPage(live), let answer = try? await LiveReader.get(url, store: store) else { return .failed }
        let (signedOut, found) = await LiveText.off("live.parse") {
            (LiveGitHub.pulls(answer.data, status: answer.status, finalURL: answer.url) == .signedOut,
             issues(answer.data, status: answer.status, finalURL: answer.url))
        }
        if signedOut { return .signedOut }
        guard let found else { return .failed }
        return .items(found.compactMap { issue in
            guard let url = URL(string: LiveGitHub.base(live.host) + "/\(issue.repo)/\(issue.pull ? "pull" : "issues")/\(issue.number)"),
                  let key = LiveText.key(url) else { return nil }
            let fresh = issue.created.map { Date().timeIntervalSince($0) < 24 * 3600 } ?? false
            return LiveItem(key: key, url: url, title: issue.title, group: issue.repo, words: fresh ? .new : nil, updated: issue.created)
        })
    }

    static func issues(_ data: Data, status: Int, finalURL: URL?) -> [Issue]? {
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["payload"] as? [String: Any],
              let route = payload["blackbirdSearchRoute"] as? [String: Any],
              let results = route["results"] as? [[String: Any]] else { return nil }
        let dates = ISO8601DateFormatter()
        return results.compactMap { item in
            guard let number = item["number"] as? Int,
                  let repository = (item["repo"] as? [String: Any])?["repository"] as? [String: Any],
                  let owner = repository["owner_login"] as? String, let name = repository["name"] as? String,
                  (item["state"] as? String ?? "open") == "open" else { return nil }
            let title = (item["hl_title"] as? String ?? "#\(number)").replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            let pull = ((item["issue"] as? [String: Any])?["issue"] as? [String: Any])?["pull_request_id"].map { !($0 is NSNull) } ?? false
            return Issue(number: number, title: LiveText.unescaped(title), repo: "\(owner)/\(name)",
                         created: (item["created"] as? String).flatMap(dates.date(from:)), pull: pull)
        }
    }

    @MainActor
    static func read(_ live: Live, store: WKWebsiteDataStore) async -> LiveRead {
        var out: [LiveItem] = []
        var seen = Set<String>()
        // Mentioning you first: the one that asks for you.
        for list in ["mentions", "assignee", "author"] where live.show.contains(list) {
            guard let url = searchURL(host: live.host, list: list),
                  let answer = try? await LiveReader.get(url, store: store) else { return .failed }
            let (signedOut, issues) = await LiveText.off("live.parse") {
                (LiveGitHub.pulls(answer.data, status: answer.status, finalURL: answer.url) == .signedOut,
                 Self.issues(answer.data, status: answer.status, finalURL: answer.url))
            }
            if signedOut { return .signedOut }
            guard let issues else { return .failed }
            for issue in issues where !live.hidden.contains(issue.repo) {
                guard let url = URL(string: LiveGitHub.base(live.host) + "/\(issue.repo)/issues/\(issue.number)"),
                      let key = LiveText.key(url), seen.insert(key).inserted else { continue }
                let fresh = issue.created.map { Date().timeIntervalSince($0) < 24 * 3600 } ?? false
                out.append(LiveItem(key: key, url: url, title: issue.title, group: issue.repo,
                                    words: list == "mentions" ? .mention : fresh ? .new : nil, updated: issue.created))
            }
        }
        // Add Repository inside Issues extends this same folder. Read its
        // open issues after the personal lists, retaining mention priority
        // and deduplicating an issue that appears in both.
        for repo in live.issueRepositories where !live.hidden.contains(repo) {
            let followed = Live(source: "github.search", host: live.host, show: [],
                                query: "is:issue is:open archived:false repo:\(repo)", days: 0)
            switch await search(followed, store: store) {
            case .items(let items):
                for item in items where item.url.path.contains("/issues/") && !live.hidden.contains(item.group) {
                    if seen.insert(item.key).inserted { out.append(item) }
                }
            case .signedOut: return .signedOut
            case .failed: return .failed
            }
        }
        return .items(out)
    }
}

// MARK: - Notion

/// Notion's inbox and your pages changed by others, from its own API, the
/// one its page calls (POST app.notion.com/api/v3/…).
enum LiveNotion {
    static let lists: [(id: String, title: String)] = [
        ("inbox", "Mentions and Comments"),
        ("changed", "Pages Changed by Others"),
    ]
    static let base = "https://app.notion.com/api/v3/"

    /// The workspaces with something unread in them, from one call.
    static func unread(_ data: Data) -> [String: Int] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [:] }
        var out: [String: Int] = [:]
        for result in results {
            guard let space = result["spaceId"] as? String, let unread = result["unread"] as? [String: Any] else { continue }
            out[space] = (unread["mentions"] as? Int ?? 0) + (unread["nonMentions"] as? Int ?? 0)
        }
        return out
    }

    /// A record in a record map, in the old shape or the new one (a value
    /// inside a value).
    static func record(_ map: [String: Any], _ table: String, _ id: String) -> [String: Any]? {
        guard let entry = (map[table] as? [String: Any])?[id] as? [String: Any],
              let value = entry["value"] as? [String: Any] else { return nil }
        return value["value"] as? [String: Any] ?? value
    }

    /// A block's title, from its rich text: [["Plan", …], [" for Q4"]].
    static func title(_ block: [String: Any]?) -> String? {
        guard let parts = (block?["properties"] as? [String: Any])?["title"] as? [[Any]] else { return nil }
        let text = parts.compactMap { $0.first as? String }.joined()
        return text.isEmpty ? nil : text
    }

    static func pageURL(_ id: String) -> URL? {
        URL(string: "https://www.notion.so/" + id.replacingOccurrences(of: "-", with: ""))
    }

    /// Unread notifications in one workspace's inbox, as items.
    static func inbox(_ data: Data) -> [LiveItem]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = json["recordMap"] as? [String: Any],
              let ids = json["notificationIds"] as? [String] else { return nil }
        var out: [LiveItem] = []
        for id in ids {
            guard let note = record(map, "notification", id), note["read"] as? Bool != true,
                  let block = note["navigable_block_id"] as? String, let url = pageURL(block) else { continue }
            let words = Self.words(note["type"] as? String ?? "")
            let at = (note["end_time"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
            out.append(LiveItem(key: "notion/" + block, url: url, title: title(record(map, "block", block)) ?? "Untitled",
                                group: note["space_id"] as? String ?? "", words: words, updated: at))
        }
        return out
    }

    /// What a notification's type says: invited and access first, since
    /// those come on the mentions channel too.
    static func words(_ type: String) -> LiveWords {
        if type.contains("invite") || type.contains("access") { return .shared }
        if type.contains("comment") || type.contains("reply") { return .comment }
        if type.contains("mention") { return .mention }
        return .new
    }

    /// The titles of pages a notification log names but doesn't hold.
    static func titles(_ data: Data) -> [String: String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = json["recordMap"] as? [String: Any],
              let blocks = map["block"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for id in blocks.keys { if let title = title(record(map, "block", id)) { out[id] = title } }
        return out
    }

    static func titlesBody(_ ids: [(block: String, space: String)]) -> String {
        let requests = ids.map { #"{"pointer":{"table":"block","id":"\#($0.block)","spaceId":"\#($0.space)"},"version":-1}"# }
        return #"{"requests":[\#(requests.joined(separator: ","))]}"#
    }

    /// Pages you visited that someone else edited since.
    static func changed(_ data: Data, me: String?) -> [LiveItem] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let visits = json["pages"] as? [[String: Any]] ?? json["visits"] as? [[String: Any]] ?? json["results"] as? [[String: Any]] ?? []
        let map = json["recordMap"] as? [String: Any] ?? [:]
        var out: [LiveItem] = []
        for visit in visits {
            guard let id = visit["id"] as? String ?? visit["pageId"] as? String, let url = pageURL(id),
                  let visited = visit["visitedAt"] as? Double ?? (visit["visitedAt"] as? String).flatMap(Double.init) else { continue }
            let block = record(map, "block", id)
            guard let edited = block?["last_edited_time"] as? Double, edited > visited + 60_000,
                  let by = block?["last_edited_by_id"] as? String, by != me else { continue }
            out.append(LiveItem(key: "notion/" + id, url: url, title: title(block) ?? visit["name"] as? String ?? "Untitled",
                                group: block?["space_id"] as? String ?? "", words: .changed,
                                updated: Date(timeIntervalSince1970: edited / 1000)))
        }
        return out
    }

    @MainActor
    static func read(_ live: Live, store: WKWebsiteDataStore) async -> LiveRead {
        guard let spacesURL = URL(string: base + "getSpaces"),
              let spaces = try? await LiveReader.post(spacesURL, body: "{}", store: store) else { return .failed }
        if spaces.status == 401 || spaces.status == 403 { return .signedOut }
        guard spaces.status == 200, let all = try? JSONSerialization.jsonObject(with: spaces.data) as? [String: Any] else { return .failed }
        let me = all.keys.first
        let ids = all.values.compactMap { ($0 as? [String: Any])?["space"] as? [String: Any] }.flatMap(\.keys)
        var out: [LiveItem] = []
        if live.show.contains("inbox") {
            guard let countsURL = URL(string: base + "getUserNotificationsInitial"),
                  let counts = try? await LiveReader.post(countsURL, body: #"{"size":1,"isInboxV2":true,"markNotificationsAsReceived":false}"#, store: store)
            else { return .failed }
            for (space, n) in unread(counts.data) where n > 0 && !live.hidden.contains(space) {
                let body = #"{"spaceId":"\#(space)","size":20,"type":"unread_and_read","variant":"no_grouping"}"#
                guard let url = URL(string: base + "getNotificationLogV2"),
                      let answer = try? await LiveReader.post(url, body: body, store: store), var items = inbox(answer.data) else { continue }
                // A page the log names but doesn't hold: its title, asked for.
                let missing = items.filter { $0.title == "Untitled" }.map { (block: String($0.key.dropFirst(7)), space: space) }
                if !missing.isEmpty, let url = URL(string: base + "syncRecordValues"),
                   let answer = try? await LiveReader.post(url, body: titlesBody(missing), store: store), answer.status == 200 {
                    let found = titles(answer.data)
                    items = items.map { item in
                        var item = item
                        if let title = found[String(item.key.dropFirst(7))] { item.title = title }
                        return item
                    }
                }
                out += items
            }
        }
        if live.show.contains("changed") {
            for space in ids.prefix(4) where !live.hidden.contains(space) {
                let now = Int(Date().timeIntervalSince1970 * 1000)
                let body = #"{"spaceId":"\#(space)","limit":30,"beforeTimestamp":\#(now)}"#
                guard let url = URL(string: base + "getRecentPageVisits"),
                      let answer = try? await LiveReader.post(url, body: body, store: store), answer.status == 200 else { continue }
                out += changed(answer.data, me: me)
            }
        }
        var seen = Set<String>()
        return .items(out.filter { seen.insert($0.key).inserted }.sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) })
    }
}

// MARK: - Google Drive

/// Drive's own pages carry their first fifty files as data, an array per
/// file: read by shape, not by trusting every place (docs/live-folders.md).
enum LiveDrive {
    static let lists: [(id: String, title: String)] = [
        ("shared-with-me", "Shared with You"),
        ("recent", "Changed Since You Looked"),
    ]

    struct File: Equatable {
        var id: String
        var title: String
        var mime: String
        var url: URL?
        var modified: Date?
        var viewed: Date?
        var shared: Date?
    }

    /// The files a Drive page's `_DRIVE_ivd` holds.
    static func files(_ html: String) -> [File]? {
        guard let start = html.range(of: "window['_DRIVE_ivd'] = '") ?? html.range(of: "window['_DRIVE_ivd']='") else { return nil }
        guard let end = html.range(of: "';", range: start.upperBound..<html.endIndex) else { return nil }
        let raw = unescape(String(html[start.upperBound..<end.lowerBound]))
        guard let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Any],
              let list = json.first as? [[Any]] else { return nil }
        func date(_ value: Any?) -> Date? {
            guard let ms = (value as? NSNumber)?.doubleValue, ms > 1e12 else { return nil }
            return Date(timeIntervalSince1970: ms / 1000)
        }
        func slot(_ file: [Any], _ index: Int) -> Any? { file.indices.contains(index) && !(file[index] is NSNull) ? file[index] : nil }
        return list.compactMap { file in
            guard let id = slot(file, 0) as? String, id.count >= 20,
                  let title = slot(file, 2) as? String,
                  let mime = slot(file, 3) as? String, mime.contains("/") else { return nil }
            let link = (slot(file, 114) as? String).flatMap(URL.init(string:))
            return File(id: id, title: title, mime: mime, url: link ?? URL(string: "https://drive.google.com/open?id=\(id)"),
                        modified: date(slot(file, 10)), viewed: date(slot(file, 12)), shared: date(slot(file, 22)))
        }
    }

    /// `\x22`, `\/` and friends, as a JavaScript string literal writes them.
    static func unescape(_ text: String) -> String {
        var out = ""
        var chars = Array(text.unicodeScalars)[...]
        while let c = chars.popFirst() {
            guard c == "\\", let next = chars.popFirst() else { out.unicodeScalars.append(c); continue }
            switch next {
            case "x":
                let hex = String(String.UnicodeScalarView(chars.prefix(2)))
                chars = chars.dropFirst(2)
                if let v = UInt32(hex, radix: 16), let s = Unicode.Scalar(v) { out.unicodeScalars.append(s) }
            case "n": out += "\n"
            case "t": out += "\t"
            default: out.unicodeScalars.append(next)
            }
        }
        return out
    }

    @MainActor
    static func read(_ live: Live, store: WKWebsiteDataStore) async -> LiveRead {
        let account = live.host.isEmpty ? "0" : live.host
        var out: [LiveItem] = []
        for list in live.show {
            guard let url = URL(string: "https://drive.google.com/drive/u/\(account)/\(list)"),
                  let answer = try? await LiveReader.get(url, accept: "text/html", store: store) else { return .failed }
            if answer.url?.host() == "accounts.google.com" { return .signedOut }
            guard let files = await LiveText.off("live.parse", { files(String(decoding: answer.data, as: UTF8.self)) }) else { return .failed }
            for file in files where !file.mime.hasSuffix(".folder") {
                guard let url = file.url else { continue }
                if list == "shared-with-me" {
                    out.append(LiveItem(key: "drive/" + file.id, url: url, title: file.title, group: "", words: .shared,
                                        updated: file.shared ?? file.modified))
                } else if let modified = file.modified, let viewed = file.viewed, modified.timeIntervalSince(viewed) > 60 {
                    out.append(LiveItem(key: "drive/" + file.id, url: url, title: file.title, group: "", words: .changed, updated: modified))
                }
            }
        }
        return .items(out)
    }
}

// MARK: - YouTube

/// New videos from your subscriptions, from the page's own data. A heavy
/// page, so read seldom and taken apart off the main thread.
enum LiveYouTube {
    struct Video: Equatable {
        var id: String
        var title: String
        var channel: String
    }

    static func videos(_ html: String) -> [Video]? {
        guard let start = html.range(of: "var ytInitialData = "),
              let end = html.range(of: ";</script>", range: start.upperBound..<html.endIndex),
              let json = try? JSONSerialization.jsonObject(with: Data(html[start.upperBound..<end.lowerBound].utf8)) else { return nil }
        var out: [Video] = []
        func walk(_ value: Any, depth: Int) {
            guard depth < 40, out.count < 60 else { return }
            if let object = value as? [String: Any] {
                if let lockup = object["lockupViewModel"] as? [String: Any] {
                    guard lockup["contentType"] as? String == "LOCKUP_CONTENT_TYPE_VIDEO", let id = lockup["contentId"] as? String,
                          let meta = (lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any],
                          let title = (meta["title"] as? [String: Any])?["content"] as? String else { return }
                    let rows = ((meta["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any])?["metadataRows"] as? [[String: Any]]
                    let parts = rows?.first?["metadataParts"] as? [[String: Any]]
                    let channel = (parts?.first?["text"] as? [String: Any])?["content"] as? String ?? ""
                    out.append(Video(id: id, title: title, channel: channel))
                    return
                }
                for (key, child) in object where key != "frameworkUpdates" { walk(child, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for child in array { walk(child, depth: depth + 1) }
            }
        }
        walk(json, depth: 0)
        return out
    }

    @MainActor
    static func read(_ live: Live, store: WKWebsiteDataStore) async -> LiveRead {
        guard let url = URL(string: "https://www.youtube.com/feed/subscriptions"),
              let answer = try? await LiveReader.get(url, accept: "text/html", store: store) else { return .failed }
        if answer.url?.host() == "accounts.google.com" || answer.url?.path.contains("ServiceLogin") == true { return .signedOut }
        let data = answer.data
        let found = await Task.detached(priority: .utility) { videos(String(decoding: data, as: UTF8.self)) }.value
        guard let found else { return .failed }
        return .items(found.compactMap { video in
            guard let url = URL(string: "https://www.youtube.com/watch?v=\(video.id)") else { return nil }
            return LiveItem(key: "youtube/" + video.id, url: url, title: video.title, group: video.channel, words: .new, updated: nil)
        })
    }
}

// MARK: - a feed

/// RSS or Atom, any site's: newest first.
enum LiveFeed {
    struct Entry: Equatable {
        var title: String
        var link: URL
        var id: String
        var at: Date?
        /// Who it is from, where the feed says (Gmail's does).
        var author = ""
    }

    static func entries(_ data: Data) -> [Entry]? {
        let reader = FeedReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() || !reader.entries.isEmpty else { return nil }
        return reader.entries
    }

    @MainActor
    static func read(_ live: Live, store: WKWebsiteDataStore) async -> LiveRead {
        guard let url = URL(string: live.host),
              let answer = try? await LiveReader.get(url, accept: "application/rss+xml, application/atom+xml, application/xml, text/xml", store: store),
              answer.status == 200, let entries = await LiveText.off("live.parse", { entries(answer.data) }) else { return .failed }
        return .items(entries.prefix(30).map { entry in
            LiveItem(key: "feed/" + entry.id, url: entry.link, title: entry.title, group: url.host() ?? "", words: .new, updated: entry.at)
        })
    }

    final class FeedReader: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        private var inEntry = false
        private var field = ""
        private var text = ""
        private var title = ""
        private var link: URL?
        private var id = ""
        private var date = ""
        private var author = ""
        private var inAuthor = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            let tag = name.lowercased()
            if tag == "item" || tag == "entry" { inEntry = true; title = ""; link = nil; id = ""; date = ""; author = "" }
            if tag == "author" { inAuthor = true }
            // Atom's link is an attribute; the alternate one, or the first.
            if inEntry, tag == "link", let href = attributes["href"], link == nil || attributes["rel"] == "alternate" {
                link = URL(string: href)
            }
            field = tag
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(decoding: block, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let tag = name.lowercased()
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard inEntry else { return }
            switch tag {
            case "name" where inAuthor: author = value
            case "author": inAuthor = false
            case "title": title = LiveText.unescaped(value)
            case "link": if link == nil, !value.isEmpty { link = URL(string: value) }
            case "guid", "id": id = value
            case "pubdate", "published", "updated", "dc:date", "issued", "modified": if date.isEmpty { date = value }
            case "item", "entry":
                inEntry = false
                if let link {
                    entries.append(Entry(title: title.isEmpty ? link.absoluteString : title, link: link,
                                         id: id.isEmpty ? link.absoluteString : id, at: FeedReader.date(date), author: author))
                }
            default: break
            }
            text = ""
        }

        static func date(_ text: String) -> Date? {
            if let iso = ISO8601DateFormatter().date(from: text) { return iso }
            let rfc = DateFormatter()
            rfc.locale = Locale(identifier: "en_US_POSIX")
            for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z"] {
                rfc.dateFormat = format
                if let date = rfc.date(from: text) { return date }
            }
            return nil
        }
    }
}

// MARK: - counts and lists for pins

/// Gmail's unread, from the feed its own notifier reads: how many, and the
/// last twenty, for a mail pin's corner and its card. Primary's, as Gmail's
/// own tab title counts it: the whole inbox's feed counts Promotions and
/// Social too (24,462 against Primary's 10,568 on one account, #314).
enum LiveGmail {
    /// The account a pin is on: /mail/u/1/ is the second.
    static func account(_ url: URL?) -> String {
        let parts = url?.path.split(separator: "/") ?? []
        if let at = parts.firstIndex(of: "u"), parts.indices.contains(at + 1) { return String(parts[at + 1]) }
        return "0"
    }

    static func count(_ data: Data) -> Int? {
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: #"<fullcount>(\d+)</fullcount>"#, options: .regularExpression) else { return nil }
        return Int(text[range].filter(\.isNumber))
    }

    /// Primary's feed: the category's label, `^sq_ig_i_personal`.
    static func feed(account: String) -> URL? {
        URL(string: "https://mail.google.com/mail/u/\(account)/feed/atom/%5Esq_ig_i_personal")
    }

    @MainActor
    static func read(account: String, store: WKWebsiteDataStore) async -> (count: Int, entries: [LiveFeed.Entry])? {
        guard let url = feed(account: account),
              let answer = try? await LiveReader.get(url, accept: "application/atom+xml", store: store),
              answer.status == 200, let count = count(answer.data) else { return nil }
        return (count, LiveFeed.entries(answer.data) ?? [])
    }
}

extension LiveNotion {
    /// Unread in every workspace, as the site's own inbox counts it.
    @MainActor
    static func unreadCount(store: WKWebsiteDataStore) async -> Int? {
        guard let url = URL(string: base + "getUserNotificationsInitial"),
              let answer = try? await LiveReader.post(url, body: #"{"size":1,"isInboxV2":true,"markNotificationsAsReceived":false}"#, store: store),
              answer.status == 200 else { return nil }
        return unread(answer.data).values.reduce(0, +)
    }
}

// MARK: - small things

enum LiveText {
    /// A site's answer read into items off the main thread (JSON, a page's
    /// markup, a feed), the folder getting them ready: the sources run on
    /// the main thread between their requests (docs/main-thread-budget.md).
    static func off<T>(_ name: String, _ work: @escaping () -> T) async -> T {
        nonisolated(unsafe) let work = work
        let made = await Task.detached(priority: .utility) { () -> Box<T> in Box(MainBudget.chunk(name, work)) }.value
        return made.value
    }

    final class Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// `&amp;` and friends out of a title.
    static func unescaped(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }

    /// The key of the thing a page shows, whatever its source: a GitHub
    /// pull request or issue, else the address without its fragment.
    static func key(_ url: URL?) -> String? {
        guard let url, let host = url.host()?.lowercased() else { return nil }
        if let pull = LiveFolder.key(url) { return pull }
        if let git = LiveGitService.itemKey(url) { return git }
        let parts = url.path.split(separator: "/")
        if parts.count >= 4, parts[2] == "issues", Int(parts[3]) != nil {
            return "\(host)/\(parts[0].lowercased())/\(parts[1].lowercased())/issues/\(parts[3])"
        }
        return nil
    }
}
