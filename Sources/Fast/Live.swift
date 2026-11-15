import Foundation
import WebKit

// A live folder: a folder of yours with a source, keeping its tabs up to
// date. What comes in is added, asleep; what is done goes. The first source
// is GitHub's pull requests, read the way GitHub's own page reads them, with
// your cookies and no tab (docs/live-folders.md). This file is the part
// that holds to fixed inputs: what a folder is set to, what a source
// answered, and what that changes in the folder. LiveFolders.swift runs it.

/// What a live folder is set to, saved on each of its tabs (Session) and
/// with it when it is empty (Folders.empties).
struct Live: Codable, Equatable {
    /// Where its tabs come from: "github.pulls".
    var source = "github.pulls"
    /// The site read, with this space's sign-ins: github.com, or an
    /// Enterprise server of its own name.
    var host = "github.com"
    /// The source's lists shown, by the source's own names.
    var show: [String] = LiveGitHub.shownAtFirst
    /// Groups left out: repositories, "owner/name".
    var hidden: [String] = []
    /// A search of your own, in the site's words, for a source that reads
    /// one (github.search): "is:pr is:open label:urgent".
    var query: String? = nil
    /// Extra repositories followed by the Issues folder, in its existing
    /// persisted query. Personal Assigned/Created/Mentioning lists stay on.
    var issueRepositories: [String] {
        guard source == "github.issues", let query else { return [] }
        var seen = Set<String>()
        return query.split(separator: " ").compactMap { word in
            guard word.hasPrefix("repo:"), let repo = LiveFolders.repo(String(word.dropFirst(5))),
                  seen.insert(repo.lowercased()).inserted else { return nil }
            return repo
        }
    }
    /// How far back a followed repository's pull requests come in, in
    /// days of last activity: nil is a week, 0 every open one.
    var days: Int? = nil

    /// The repository a "Add Repository…" search follows, "owner/name".
    var followed: String? {
        guard source == "github.search", let query, query.hasPrefix("is:pr is:open repo:"),
              !query.dropFirst("is:pr is:open repo:".count).contains(" ") else { return nil }
        return String(query.dropFirst("is:pr is:open repo:".count))
    }

    /// The search as read now: a followed repository's only what moved in
    /// its window, so following one doesn't pour in every old pull request.
    func searched(now: Date = Date()) -> String? {
        guard let query else { return nil }
        let window = days ?? 7
        guard followed != nil, window > 0, let since = Calendar(identifier: .gregorian).date(byAdding: .day, value: -window, to: now) else { return query }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        return query + " updated:>=" + day.string(from: since)
    }
}

/// What a tab a live folder holds says at its end, the first that applies,
/// and nothing when nothing needs you.
enum LiveWords: String, Codable, Equatable {
    case review, changes, failing, ready, new
    /// New for you (LiveSources.swift): you're named, a comment for you,
    /// something shared with you, a page someone else changed.
    case mention, comment, shared, changed
    /// To do past its due date (Linear).
    case late
    /// Someone asks you for something of yours: to see a file (Figma).
    case request

    var text: String {
        switch self {
        case .review: return "Review"
        case .changes: return "Changes"
        case .failing: return "Failing"
        case .ready: return "Ready"
        case .new: return "New"
        case .mention: return "Mention"
        case .comment: return "Comment"
        case .shared: return "Shared"
        case .changed: return "Changed"
        case .late: return "Late"
        case .request: return "Request"
        }
    }

    /// Something to do, drawn in ink, and out from under a shut folder.
    var needsYou: Bool {
        switch self {
        case .review, .changes, .failing, .mention, .comment, .late, .request: return true
        default: return false
        }
    }
}

/// What a routine's folder says at a tab's end, in its agent's own words:
/// "$3,800 · −$150", "New", "Rented". Loud is what needs a look, drawn in
/// ink and out from under the shut folder; gone is a thing that left,
/// said once more before the next run takes it away.
struct LiveSaid: Codable, Equatable {
    var text: String
    var loud = false
    var gone = false
}

/// A tab a live folder brought, and what it says.
struct LiveMark: Codable, Equatable {
    /// The thing it is, whatever page of it is open: host/owner/repo/pull/n.
    var key: String
    var words: LiveWords?
    /// What it said when you last opened it: words that need you come out
    /// from under a shut folder until you have seen them.
    var seen: LiveWords?
    /// The folder that brought it, so taking it out by hand keeps that
    /// folder from bringing it back.
    var folder: UUID?
    /// Moved in rather than brought: the pull request you just made. Its
    /// words are kept up to date, but the folder never takes it away.
    var yours: Bool? = nil
    /// When it came, for a new-for-you folder's week.
    var came: Date? = nil
    /// A routine's folder's own words for it (LiveSaid), and the words it
    /// had when you last opened it.
    var said: LiveSaid? = nil
    var heard: LiveSaid? = nil
    /// Brought by a new-for-you list of a to-do folder (Linear's mentions):
    /// it goes by the new-for-you rules, not when the thing is done.
    var news: Bool? = nil

    /// Out from under its folder, shut: it needs you, and you haven't
    /// opened it since it began to.
    var callsOut: Bool {
        (words?.needsYou == true && words != seen) || (said?.loud == true && said?.gone != true && said != heard)
    }
}

/// One thing a source listed.
struct LiveItem: Equatable {
    var key: String
    var url: URL
    var title: String
    /// A repository, "owner/name", for the folder's menu and its card.
    var group: String
    var words: LiveWords?
    var updated: Date?
    /// A routine's folder's words for it.
    var said: LiveSaid? = nil
    /// When it is due (Linear), for its tab's card.
    var due: Date? = nil
    /// The source's list it came from, by the source's name, for a folder
    /// whose lists are of both kinds (LiveSource.listKinds).
    var list: String? = nil
    /// What was said to you, for its tab's card: a comment's first words.
    var quote: String? = nil
    /// Who said it.
    var person: String? = nil
}

/// What a source's answer changes in a folder.
struct LiveDiff: Equatable {
    /// New ones, at the folder's top, in the source's order.
    var add: [LiveItem] = []
    /// Tabs of today's showing one of the new ones: moved in instead of a
    /// second row, by key.
    var adopt: [String: UUID] = [:]
    /// Tabs it brought that are done or no longer listed.
    var remove: [UUID] = []
    /// Words changed on tabs it holds.
    var words: [UUID: LiveWords?] = [:]
    /// A routine's folder's words changed on tabs it holds.
    var said: [UUID: LiveSaid?] = [:]
}

enum LiveFolder {
    /// A folder stops here; the rest are a click away on the site.
    static let most = 30

    /// A tab in the folder, as the diff sees it.
    struct Held: Equatable {
        var id: UUID
        var key: String?
        /// Brought by the folder, rather than put there by you.
        var brought: Bool
        var words: LiveWords?
        /// On screen, holding something typed, or playing: it stays until
        /// you leave it.
        var busy = false
        /// When it came, and when you opened it since (new for you).
        var came: Date? = nil
        var opened: Date? = nil
        var said: LiveSaid? = nil
        /// Brought by a new-for-you list of a to-do folder.
        var news = false
    }

    /// What a folder has shown, once a reading is applied: what its
    /// new-for-you lists brought and, on the first reading, all they listed
    /// (left out as not fresh). Never a to-do thing: one unassigned later
    /// may still come as a mention.
    static func shown(_ items: [LiveItem], kind: LiveKind, news lists: Set<String>, added: [LiveItem],
                      before: Set<String>, first: Bool) -> Set<String> {
        let toDo = Set(items.filter { kind == .toDo && !lists.contains($0.list ?? "") }.map(\.key))
        let reached = Set(items.map(\.key)).subtracting(toDo)
        var now = before.union(added.map(\.key).filter(reached.contains))
        if first { now.formUnion(reached) }
        return now
    }

    /// A to-do folder with new-for-you lists too (Linear's My Issues and
    /// its mentions): each thing by its own list's rules, and each tab by
    /// the rules of the list that brought it. A thing both list is to do;
    /// one a new-for-you tab holds isn't brought twice; like a to-do one,
    /// a mention of a thing open in today's moves that tab in, and one
    /// kept elsewhere stays out.
    static func mixed(_ items: [LiveItem], news lists: Set<String>, held: [Held], today: [String: UUID], elsewhere: Set<String>,
                      hidden: Set<String>, shown: Set<String>, first: Bool, now: Date = Date()) -> LiveDiff {
        let isNews: (LiveItem) -> Bool = { lists.contains($0.list ?? "") }
        let toDo = items.filter { !isNews($0) }
        let heldToDo = held.filter { !$0.news }
        let heldNews = held.filter(\.news)
        var out = diff(toDo, held: heldToDo, today: today, elsewhere: elsewhere.union(heldNews.compactMap(\.key)), hidden: hidden)
        // Kept elsewhere is no thing to bring; open in today's, it moves in.
        let taken = Set(toDo.map(\.key)).union(heldToDo.compactMap(\.key)).union(elsewhere)
        let reached = items.filter { isNews($0) && !taken.contains($0.key) }
        let more = news(reached, held: heldNews, shown: shown, hidden: hidden, first: first, now: now)
        for item in more.add { if let id = today[item.key] { out.adopt[item.key] = id } }
        out.add = more.add + out.add
        out.remove += more.remove
        out.words.merge(more.words) { a, _ in a }
        return out
    }

    /// Only takes away what it brought; never twice the same thing; today's
    /// tab of a thing moves in rather than a copy; hidden ones stay out.
    static func diff(_ items: [LiveItem], held: [Held], today: [String: UUID], elsewhere: Set<String>,
                     hidden: Set<String>) -> LiveDiff {
        var out = LiveDiff()
        let listed = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var have = Set<String>()
        for tab in held {
            guard let key = tab.key else { continue }
            have.insert(key)
            if let item = listed[key], !hidden.contains(key) {
                if item.words != tab.words { out.words[tab.id] = item.words }
                if item.said != tab.said { out.said[tab.id] = item.said }
            } else if tab.brought, !tab.busy {
                out.remove.append(tab.id)
            } else if !tab.brought, tab.said != nil {
                // A tab of yours, no longer listed: it stays, its words go.
                out.said.updateValue(nil, forKey: tab.id)
            }
        }
        var room = most - (held.count - out.remove.count)
        // A thing said gone is never brought in: it left before it came.
        for item in items where room > 0 && !have.contains(item.key) && !hidden.contains(item.key) && !elsewhere.contains(item.key)
            && item.said?.gone != true {
            if let id = today[item.key] { out.adopt[item.key] = id }
            out.add.append(item)
            have.insert(item.key)
            room -= 1
        }
        return out
    }

    /// Any page as a routine's folder knows it: its site and path and what
    /// it asks, not how it was reached (a fragment, a trailing slash, a
    /// tracking word).
    static func page(_ url: URL?) -> String? {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = parts.host?.lowercased() else { return nil }
        parts.queryItems = parts.queryItems?.filter { item in
            !item.name.lowercased().hasPrefix("utm_") && !["ref", "fbclid", "gclid", "si"].contains(item.name.lowercased())
        }.sorted { $0.name < $1.name }
        let path = parts.path.hasSuffix("/") && parts.path.count > 1 ? String(parts.path.dropLast()) : parts.path
        let query = (parts.queryItems ?? []).isEmpty ? "" : "?" + (parts.queryItems ?? []).map { $0.name + "=" + ($0.value ?? "") }.joined(separator: "&")
        return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + path + query
    }

    /// The key of the thing a page shows, for GitHub's pull requests any
    /// page of one: its files, its commits, a comment's anchor.
    static func key(_ url: URL?) -> String? {
        guard let url, let host = url.host()?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 4, parts[2] == "pull", Int(parts[3]) != nil else { return nil }
        return "\(host)/\(parts[0].lowercased())/\(parts[1].lowercased())/pull/\(parts[3])"
    }
}

// MARK: - GitHub

/// GitHub's pull request inbox, the lists its own /pulls page is made of,
/// asked for in JSON (`Accept: application/json`), and the call after it
/// that says each one's checks and review.
enum LiveGitHub {
    /// The lists, by GitHub's names, and what the folder's menu calls them.
    static let lists: [(id: String, title: String)] = [
        ("review-requested", "Review Requests"),
        ("team-review-requested", "Team Reviews"),
        ("needs-action", "Needs Your Action"),
        ("waiting-for-review", "Waiting for Review"),
        ("ready-to-merge", "Ready to Merge"),
        ("your-drafts", "Drafts"),
        ("author", "Created by You"),
        ("assignee", "Assigned to You"),
    ]

    static let shownAtFirst = ["review-requested", "team-review-requested", "needs-action", "waiting-for-review", "ready-to-merge"]

    /// Optional personal lists use the same search reader as GitHub's
    /// issues. @me is resolved by the site's current signed-in account.
    static func personalQuery(_ list: String) -> String? {
        guard list == "author" || list == "assignee" else { return nil }
        return "is:pr is:open archived:false \(list):@me"
    }

    /// The site's own address: its host over https, or, for a test run's
    /// stand-in, the whole of it ("http://127.0.0.1:8123").
    static func base(_ host: String) -> String { host.contains("://") ? host : "https://" + host }

    static func queryURL(host: String, list: String) -> URL? {
        URL(string: base(host) + "/pulls/inbox/queries?filter=\(list)&max_pr_age=1m")
    }

    static func deferredURL(host: String, ids: [String]) -> URL? {
        guard var parts = URLComponents(string: base(host) + "/pulls/inbox/deferred") else { return nil }
        parts.queryItems = [URLQueryItem(name: "page", value: "1")] + ids.map { URLQueryItem(name: "ids[]", value: $0) }
        return parts.url
    }

    /// The page to open for the folder's lists.
    static func page(host: String) -> URL? { URL(string: base(host) + "/pulls") }

    /// A pull request's host as a live folder keeps it: the name alone
    /// over https, the whole of it otherwise (a stand-in, a port).
    static func host(of url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        if url.scheme == "https", url.port == nil { return host }
        return "\(url.scheme ?? "https")://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    /// A pull request's page names itself "Fix it by anna · Pull Request
    /// #12 · acme/yab · GitHub"; its row, only "Fix it".
    static func shortTitle(_ title: String) -> String {
        guard let range = title.range(of: #"\s·\s(Pull Request|Pull request) #\d+\s·.*$"#, options: .regularExpression) else { return title }
        var head = String(title[..<range.lowerBound])
        if let by = head.range(of: #"\sby\s[^\s·]+$"#, options: .regularExpression) { head.removeSubrange(by) }
        return head.isEmpty ? title : head
    }

    /// One pull request as a list gave it.
    struct Pull: Equatable {
        var id: String
        var number: Int
        var title: String
        var url: URL
        var repo: String
        var category: String?
        var draft: Bool
        var read: Bool
        var updated: Date?
    }

    enum Answer: Equatable {
        case pulls([Pull])
        /// GitHub answered with its sign-in page, or said so.
        case signedOut
        /// Anything else: kept as it was, tried again later.
        case failed
    }

    /// A list's answer. Not JSON with the list in it: signed out when the
    /// answer came from a sign-in address, failed otherwise.
    static func pulls(_ data: Data, status: Int, finalURL: URL?) -> Answer {
        let path = finalURL?.path ?? ""
        if status == 401 || path.hasPrefix("/login") || path.hasPrefix("/session") { return .signedOut }
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["payload"] as? [String: Any],
              let route = payload["pullsInboxSurfaceContentRoute"] as? [String: Any],
              let results = route["results"] as? [[String: Any]] else { return .failed }
        let dates = ISO8601DateFormatter()
        return .pulls(results.compactMap { item in
            guard let id = item["id"] as? String, let number = item["number"] as? Int,
                  let link = item["permalink"] as? String, let url = URL(string: link),
                  (item["state"] as? String ?? "OPEN") == "OPEN" else { return nil }
            return Pull(id: id, number: number, title: item["title"] as? String ?? "#\(number)", url: url,
                        repo: item["repoNameWithOwner"] as? String ?? "", category: item["category"] as? String,
                        draft: item["isDraft"] as? Bool ?? false, read: item["isReadByCurrentUser"] as? Bool ?? true,
                        updated: (item["updatedAt"] as? String).flatMap(dates.date(from:)))
        })
    }

    /// What the call after says: review decision and checks, by id.
    struct Status: Equatable {
        var review: String?
        var checks: String?
    }

    static func statuses(_ data: Data) -> [String: Status] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["payload"] as? [String: Any],
              let deferred = payload["pullsInboxSurfaceContentDeferredData"] as? [String: Any],
              let results = deferred["results"] as? [[String: Any]] else { return [:] }
        var out: [String: Status] = [:]
        for item in results {
            guard let id = item["id"] as? String else { continue }
            out[id] = Status(review: item["reviewDecisionState"] as? String,
                             checks: (item["statusCheckRollup"] as? [String: Any])?["state"] as? String)
        }
        return out
    }

    /// The lists put together into one, each pull request once, in the
    /// order they matter, with its words.
    static func items(_ answers: [(list: String, pulls: [Pull])], statuses: [String: Status], hiddenGroups: Set<String>,
                      personal: [LiveItem] = []) -> [LiveItem] {
        var seen = Set<String>()
        var out: [LiveItem] = []
        let order = ["review-requested", "team-review-requested", "needs-action", "ready-to-merge", "waiting-for-review", "your-drafts"]
        for list in order {
            for answer in answers where answer.list == list {
                for pull in answer.pulls where !hiddenGroups.contains(pull.repo) {
                    guard let key = LiveFolder.key(pull.url), seen.insert(key).inserted else { continue }
                    out.append(LiveItem(key: key, url: pull.url, title: pull.title, group: pull.repo,
                                        words: words(pull, list: list, status: statuses[pull.id]), updated: pull.updated))
                }
            }
        }
        // A PR can be authored, assigned and awaiting review at once.
        // Existing inbox status/ordering wins; hidden repositories stay out.
        for item in personal where LiveFolder.key(item.url) == item.key
            && !hiddenGroups.contains(item.group) && seen.insert(item.key).inserted {
            out.append(item)
        }
        return out
    }

    static func words(_ pull: Pull, list: String, status: Status?) -> LiveWords? {
        if list == "review-requested" || list == "team-review-requested" { return .review }
        if status?.review == "CHANGES_REQUESTED" || pull.category == "CHANGES_REQUESTED" { return .changes }
        if pull.category == "CI_FAILING" || status?.checks == "FAILURE" || status?.checks == "ERROR" { return .failing }
        if list == "ready-to-merge" { return .ready }
        if !pull.read { return .new }
        return nil
    }
}

// MARK: - reading

/// A GET as the page would send it, with this space's cookies for the
/// site, the cookies the site answers with kept as a tab keeps them
/// (AgentRead's way), off the main thread but for gathering the cookies.
enum LiveReader {
    struct Answer {
        var status: Int
        var url: URL?
        var data: Data
        var more = false
    }

    /// Pagination is metadata, not a promise that a short page is complete.
    static func answer(_ data: Data, response: HTTPURLResponse?) -> Answer {
        let next = response?.value(forHTTPHeaderField: "X-Next-Page")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let link = response?.value(forHTTPHeaderField: "Link") ?? ""
        let linked = link.range(of: #"\brel\s*=\s*(?:"[^"]*\bnext\b[^"]*"|next\b)"#, options: [.regularExpression, .caseInsensitive]) != nil
        let page = (response?.value(forHTTPHeaderField: "X-Page")).flatMap(Int.init)
        let pages = (response?.value(forHTTPHeaderField: "X-Total-Pages")).flatMap(Int.init)
        let counted = page.flatMap { p in pages.map { p < $0 } } ?? false
        return Answer(status: response?.statusCode ?? 0, url: response?.url, data: data, more: !next.isEmpty || linked || counted)
    }

    @MainActor
    static func get(_ url: URL, accept: String = "application/json", store: WKWebsiteDataStore, redirects: Bool = true) async throws -> Answer {
        // The store answers once its network process is up; a row with no
        // page yet may wait on it a while: five seconds, then read later.
        var request = try await request(url, accept: accept, store: store)
        // As the site's own page asks for JSON: some answer it only then.
        if accept.contains("json") { request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With") }
        return try await send(request, redirects: redirects, store: store)
    }

    /// A POST to a read the page itself makes (Notion's API): JSON in, JSON
    /// out, from the site's own origin, or the page's where its API lives on
    /// another host (Linear's), with the headers the page adds.
    @MainActor
    static func post(_ url: URL, body: String, origin: String? = nil, headers: [String: String] = [:],
                     store: WKWebsiteDataStore, redirects: Bool = true) async throws -> Answer {
        var request = try await request(url, accept: "application/json", store: store)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let origin = origin ?? url.scheme.flatMap({ scheme in url.host().map { "\(scheme)://\($0)" } }) {
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        }
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return try await send(request, redirects: redirects, store: store)
    }

    @MainActor
    private static func request(_ url: URL, accept: String, store: WKWebsiteDataStore) async throws -> URLRequest {
        let cookies: [HTTPCookie] = try await withCheckedThrowingContinuation { done in
            var answered = false
            store.httpCookieStore.getAllCookies { cookies in
                guard !answered else { return }
                answered = true
                done.resume(returning: cookies)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard !answered else { return }
                answered = true
                done.resume(throwing: URLError(.timedOut))
            }
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies.filter { AgentRead.sent($0, to: url) }) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue(AgentRead.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    private static func send(_ request: URLRequest, redirects: Bool = true, store: WKWebsiteDataStore) async throws -> Answer {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: config, delegate: AnswerCookies(store, follow: redirects), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        AgentRead.take(response, of: request, into: store)
        let http = response as? HTTPURLResponse
        return answer(data, response: http)
    }
}
