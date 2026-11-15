import Foundation
import WebKit

/// Your issues in Linear, from the GraphQL its own client asks, with the
/// session's cookies and no token: the web client has none. First you in
/// each workspace (`availableUsers`, the cookies alone, as its switcher
/// asks), then each one's issues and unread notifications with the `user`
/// header the client sends; without it every query is refused as signed
/// out (docs/live-folders.md). Queries only: nothing is marked read.
enum LiveLinear {
    /// Assigned to you, a to-do list; a mention of you or a comment on an
    /// issue of yours, a new-for-you one in the same folder.
    static let lists: [(id: String, title: String)] = [
        ("assigned", "My Issues"),
        ("mentions", "Mentions and Comments"),
    ]

    static let url = URL(string: "https://client-api.linear.app/graphql")!
    /// Where its own page calls from.
    static let origin = "https://linear.app"

    /// You in one workspace: your user there and the workspace's word in
    /// its addresses, "acme" of linear.app/acme.
    struct Account: Equatable {
        var user: String
        var workspace: String
    }

    static var accountsQuery: String {
        body("query { availableUsers { users { id active organization { urlKey } } } }")
    }

    /// Assigned to you, begun or up next, the latest first: not the
    /// backlog, which can hold dozens nobody means to start this week.
    static let assignedPart = "viewer { assignedIssues(first: 30, orderBy: updatedAt, filter: { state: { type: { in: [\"started\", \"unstarted\"] } } }) { nodes { identifier title url dueDate createdAt team { key } } } }"

    /// Mentions and comments of the last week, newest first, read or not
    /// (Linear's filter has no `readAt`): those read are left out here,
    /// never marked so there. Filtered by type on Linear's side, so a
    /// busy workspace's status changes don't crowd them out of the fifty.
    static let notificationsPart = "notifications(first: 50, filter: { type: { in: [\"issueMention\", \"issueCommentMention\", \"issueNewComment\"] }, createdAt: { gt: \"-P7D\" } }) { nodes { type readAt archivedAt snoozedUntilAt createdAt ... on IssueNotification { actor { name } comment { body } issue { identifier title url team { key } assignee { isMe } creator { isMe } } } } }"

    /// The lists shown, asked in one query a workspace.
    static func reading(_ lists: [String]) -> String {
        let parts = (lists.contains("assigned") ? [assignedPart] : []) + (lists.contains("mentions") ? [notificationsPart] : [])
        return body("query { " + parts.joined(separator: " ") + " }")
    }

    static var query: String { reading(["assigned"]) }
    static var notificationsQuery: String { reading(["mentions"]) }

    private static func body(_ text: String) -> String {
        let body = (try? JSONSerialization.data(withJSONObject: ["query": text])) ?? Data()
        return String(decoding: body, as: UTF8.self)
    }

    static func accounts(_ data: Data) -> [Account]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let found = (json["data"] as? [String: Any])?["availableUsers"] as? [String: Any],
              let users = found["users"] as? [[String: Any]] else { return nil }
        return users.compactMap { user in
            guard user["active"] as? Bool != false, let id = user["id"] as? String,
                  let workspace = (user["organization"] as? [String: Any])?["urlKey"] as? String else { return nil }
            return Account(user: id, workspace: workspace)
        }
    }

    static func issues(_ data: Data, now: Date = Date()) -> [LiveItem]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let viewer = (json["data"] as? [String: Any])?["viewer"] as? [String: Any],
              let nodes = (viewer["assignedIssues"] as? [String: Any])?["nodes"] as? [[String: Any]] else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let days = DateFormatter()
        days.dateFormat = "yyyy-MM-dd"
        days.locale = Locale(identifier: "en_US_POSIX")
        return nodes.compactMap { node in
            guard let id = node["identifier"] as? String, let link = node["url"] as? String, let url = URL(string: link) else { return nil }
            let created = (node["createdAt"] as? String).flatMap { fractional.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
            let due = (node["dueDate"] as? String).flatMap(days.date(from:))
            let late = due.map { now.timeIntervalSince($0) > 24 * 3600 } ?? false
            let fresh = created.map { now.timeIntervalSince($0) < 24 * 3600 } ?? false
            let team = (node["team"] as? [String: Any])?["key"] as? String ?? ""
            return LiveItem(key: "linear/" + id, url: url, title: "\(id) \(node["title"] as? String ?? "")", group: team,
                            words: late ? .late : fresh ? .new : nil, updated: created, due: due, list: "assigned")
        }
    }

    /// Unread mentions of you, anywhere, and new comments on issues
    /// assigned to you or made by you: one row an issue, its newest.
    /// Linear's types: issueMention and issueCommentMention, issueNewComment.
    static func notes(_ data: Data, now: Date = Date()) -> [LiveItem]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let found = (json["data"] as? [String: Any])?["notifications"] as? [String: Any],
              let nodes = found["nodes"] as? [[String: Any]] else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date: (Any?) -> Date? = { ($0 as? String).flatMap { fractional.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } }
        var out: [LiveItem] = []
        var seen = Set<String>()
        let sorted = nodes.sorted { (date($0["createdAt"]) ?? .distantPast) > (date($1["createdAt"]) ?? .distantPast) }
        for node in sorted {
            guard node["readAt"] as? String == nil, node["archivedAt"] as? String == nil,
                  date(node["snoozedUntilAt"]).map({ $0 < now }) ?? true,
                  let type = node["type"] as? String, let issue = node["issue"] as? [String: Any],
                  let id = issue["identifier"] as? String, let link = issue["url"] as? String, let url = URL(string: link) else { continue }
            let mine = (issue["assignee"] as? [String: Any])?["isMe"] as? Bool == true
                || (issue["creator"] as? [String: Any])?["isMe"] as? Bool == true
            let words: LiveWords
            if type.hasSuffix("Mention") { words = .mention } else if type == "issueNewComment", mine { words = .comment } else { continue }
            guard seen.insert(id).inserted else { continue }
            let team = (issue["team"] as? [String: Any])?["key"] as? String ?? ""
            let body = (node["comment"] as? [String: Any])?["body"] as? String
            out.append(LiveItem(key: "linear/" + id, url: url, title: "\(id) \(issue["title"] as? String ?? "")", group: team,
                                words: words, updated: date(node["createdAt"]), list: "mentions",
                                quote: body.flatMap(quote), person: (node["actor"] as? [String: Any])?["name"] as? String))
        }
        return out
    }

    /// A comment's first words, for a card's line: its links' text, its
    /// emphasis, quotes and headings unmarked (a "#412" or a snake_case
    /// word kept), one line, cut at a word.
    static func quote(_ body: String) -> String? {
        var text = body.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*(?:>+|#{1,6}(?=\s)|[-*+](?=\s))\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<!\w)(\*\*|__|~~|\*|_|`)(?=\S)(.+?)(?<=\S)\1(?!\w)"#, with: "$2", options: .regularExpression)
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        guard text.count > 60 else { return text }
        let cut = text.prefix(60)
        return String(cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut) + "…"
    }

    /// Refused as nobody: a 401, or GraphQL's authentication error.
    static func refused(_ answer: LiveReader.Answer) -> Bool {
        if answer.status == 401 || answer.status == 403 { return true }
        guard let json = try? JSONSerialization.jsonObject(with: answer.data) as? [String: Any],
              let errors = json["errors"] as? [[String: Any]] else { return false }
        return errors.contains { ($0["extensions"] as? [String: Any])?["code"] as? String == "AUTHENTICATION_ERROR" }
    }

    /// Every workspace's, but those its menu leaves out.
    @MainActor
    static func read(_ live: Live, store: WKWebsiteDataStore) async -> LiveRead {
        guard let answer = try? await LiveReader.post(url, body: accountsQuery, origin: origin, store: store) else { return .failed }
        if refused(answer) { return .signedOut }
        guard answer.status == 200, let accounts = accounts(answer.data) else { return .failed }
        if accounts.isEmpty { return .signedOut }
        let lists = live.shown
        guard lists.contains("assigned") || lists.contains("mentions") else { return .items([]) }
        var mentions: [LiveItem] = []
        var assigned: [LiveItem] = []
        for account in accounts where !live.hidden.contains(account.workspace) {
            guard let answer = try? await LiveReader.post(url, body: reading(lists), origin: origin,
                                                          headers: ["user": account.user], store: store)
            else { return .failed }
            // A workspace that wants its own sign-in (SAML) is left out.
            if refused(answer) { continue }
            guard answer.status == 200 else { return .failed }
            if lists.contains("assigned") {
                guard let items = issues(answer.data) else { return .failed }
                assigned += items
            }
            if lists.contains("mentions") {
                guard let items = notes(answer.data) else { return .failed }
                mentions += items
            }
        }
        return .items(mentions + assigned)
    }
}
