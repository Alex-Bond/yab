import Foundation
import WebKit

/// Explicit repository/tracker adapters. Only GitLab documents REST access
/// with a browser session; other APIs are read without the space's cookies.
/// This is backend preparation, not an additional source offered by the UI.
enum LiveGitService: String, CaseIterable {
    case gitlab, bitbucket, codeberg, sourcehut, gitee, gitea

    var sourceID: String { rawValue + (self == .sourcehut ? ".tickets" : ".pulls") }
    static func of(_ id: String) -> Self? { allCases.first { $0.sourceID == id } }
    var site: String {
        switch self {
        case .gitlab: return "gitlab.com"
        case .bitbucket: return "bitbucket.org"
        case .codeberg: return "codeberg.org"
        case .sourcehut: return "todo.sr.ht"
        case .gitee: return "gitee.com"
        case .gitea: return "gitea.com"
        }
    }
    var name: String {
        switch self {
        case .gitlab: return "GitLab"
        case .bitbucket: return "Bitbucket"
        case .codeberg: return "Codeberg"
        case .sourcehut: return "SourceHut"
        case .gitee: return "Gitee"
        case .gitea: return "Gitea"
        }
    }
    var allowsSessionCookies: Bool { self == .gitlab }
    private var selfHosted: Bool { [.gitlab, .gitee, .gitea].contains(self) }

    /// A repository, not a credential-bearing URL or a link into its pages.
    /// Nested GitLab namespaces are preserved; other services use owner/name.
    func repository(_ raw: String) -> URL? {
        guard let parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(), !host.isEmpty,
              !host.hasSuffix("."), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, selfHosted || host == site,
              selfHosted || parts.port == nil || parts.port == 443 else { return nil }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        let names = Array(path.last == "" ? path.dropLast() : path[...])
        guard self == .gitlab ? names.count >= 2 : names.count == 2 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        guard names.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }),
              self != .sourcehut || (names[0].hasPrefix("~") && names[0].count > 1) else { return nil }
        var clean = parts
        clean.scheme = "https"
        clean.host = host
        clean.path = "/" + names.joined(separator: "/")
        if clean.port == 443 { clean.port = nil }
        return clean.url
    }

    struct Request {
        let url: URL
        var body: String? = nil
    }

    func request(for repository: URL) -> Request? {
        guard let page = self.repository(repository.absoluteString),
              var parts = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
        let names = page.path.split(separator: "/").map(String.init)
        switch self {
        case .gitlab:
            let segment = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
            guard let project = names.joined(separator: "/").addingPercentEncoding(withAllowedCharacters: segment) else { return nil }
            parts.percentEncodedPath = "/api/v4/projects/" + project + "/merge_requests"
            parts.queryItems = [.init(name: "state", value: "opened"), .init(name: "per_page", value: "50"), .init(name: "page", value: "1")]
        case .gitea, .codeberg, .gitee:
            parts.path = "/api/\(self == .gitee ? "v5" : "v1")/repos/\(names[0])/\(names[1])/pulls"
            parts.queryItems = [.init(name: "state", value: "open"), .init(name: self == .gitee ? "per_page" : "limit", value: "50"), .init(name: "page", value: "1")]
        case .bitbucket:
            parts.host = "api.bitbucket.org"
            parts.path = "/2.0/repositories/\(names[0])/\(names[1])/pullrequests"
            parts.queryItems = [.init(name: "state", value: "OPEN"), .init(name: "pagelen", value: "50")]
        case .sourcehut:
            parts.path = "/query"
            let query = "query($u: String!, $t: String!, $c: Cursor) { user(username: $u) { tracker(name: $t) { tickets(cursor: $c) { results { id subject updated status } cursor } } } }"
            let body: [String: Any] = ["query": query, "variables": ["u": String(names[0].dropFirst()), "t": names[1], "c": NSNull()]]
            guard let url = parts.url, let data = try? JSONSerialization.data(withJSONObject: body), let text = String(data: data, encoding: .utf8) else { return nil }
            return Request(url: url, body: text)
        }
        return parts.url.map { Request(url: $0) }
    }

    private static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host()?.lowercased() == b.host()?.lowercased()
            && (a.port ?? 443) == (b.port ?? 443) && a.user == nil && a.password == nil
    }

    /// Incomplete or malformed answers must never look like an empty folder.
    /// A full first page is conservatively incomplete until pagination exists.
    func parse(_ data: Data, status: Int, finalURL: URL?, repository: URL, more: Bool = false) -> LiveRead {
        guard let page = self.repository(repository.absoluteString), let request = request(for: page),
              let finalURL, Self.sameOrigin(finalURL, request.url), finalURL.path == request.url.path else { return .failed }
        if status == 401 || status == 403 { return allowsSessionCookies ? .signedOut : .failed }
        guard status == 200, !more, let json = try? JSONSerialization.jsonObject(with: data) else { return .failed }
        let rows: [[String: Any]]
        switch self {
        case .bitbucket:
            guard let payload = json as? [String: Any], let values = payload["values"] as? [[String: Any]],
                  payload["next"] == nil || payload["next"] is NSNull else { return .failed }
            rows = values
        case .sourcehut:
            guard let payload = json as? [String: Any], payload["errors"] == nil,
                  let root = payload["data"] as? [String: Any], let user = root["user"] as? [String: Any],
                  let tracker = user["tracker"] as? [String: Any], let tickets = tracker["tickets"] as? [String: Any],
                  let values = tickets["results"] as? [[String: Any]], tickets["cursor"] is NSNull else { return .failed }
            rows = values
        default:
            guard let values = json as? [[String: Any]] else { return .failed }
            rows = values
        }
        guard rows.count < 50 else { return .failed }
        var items: [LiveItem] = [], seen = Set<String>()
        for row in rows {
            let numberField = self == .gitlab ? "iid" : (self == .sourcehut || self == .bitbucket ? "id" : "number")
            guard let number = row[numberField] as? Int, number > 0,
                  let title = row[self == .sourcehut ? "subject" : "title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let state = row[self == .sourcehut ? "status" : "state"] as? String else { return .failed }
            let open: Set<String> = self == .sourcehut ? ["REPORTED", "CONFIRMED", "IN_PROGRESS", "PENDING"]
                : self == .bitbucket ? ["OPEN"] : self == .gitlab ? ["opened"] : ["open"]
            let closed: Set<String> = self == .sourcehut ? ["RESOLVED"] : self == .bitbucket ? ["MERGED", "DECLINED", "SUPERSEDED"] : ["closed", "merged", "locked"]
            guard open.contains(state) || closed.contains(state) else { return .failed }
            let suffix = self == .gitlab ? "/-/merge_requests/" : self == .bitbucket ? "/pull-requests/" : self == .sourcehut ? "/" : "/pulls/"
            guard let expected = URL(string: page.absoluteString + suffix + String(number)) else { return .failed }
            var url = expected
            if self != .sourcehut {
                let raw: String?
                if self == .bitbucket {
                    raw = (((row["links"] as? [String: Any])?["html"] as? [String: Any])?["href"]) as? String
                } else { raw = row[self == .gitlab ? "web_url" : "html_url"] as? String }
                guard let raw, let given = URL(string: raw), Self.sameOrigin(given, page), given.path == expected.path,
                      given.query == nil, given.fragment == nil else { return .failed }
                url = given
            }
            guard open.contains(state) else { continue }
            let key = "git/" + expected.absoluteString
            guard seen.insert(key).inserted else { continue }
            let dateField = self == .gitlab || self == .gitee || self == .gitea || self == .codeberg ? "updated_at" : self == .bitbucket ? "updated_on" : "updated"
            let updated = (row[dateField] as? String).flatMap(Self.date)
            items.append(LiveItem(key: key, url: url, title: title, group: String(page.path.dropFirst()), words: nil, updated: updated))
        }
        return .items(items)
    }

    /// Identity shared with already-open tabs, without inventing GitHub IDs.
    static func itemKey(_ url: URL) -> String? {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let names = url.path.split(separator: "/")
        let pull = names.count == 4 && ["pulls", "pull-requests"].contains(String(names[2])) && Int(names[3]) != nil
        let merge = names.count >= 5 && names[names.count - 3] == "-" && names[names.count - 2] == "merge_requests" && Int(names.last!) != nil
        let ticket = url.host() == "todo.sr.ht" && names.count == 3 && names[0].hasPrefix("~") && Int(names[2]) != nil
        guard pull || merge || ticket else { return nil }
        var clean = parts
        clean.query = nil
        clean.fragment = nil
        clean.host = clean.host?.lowercased()
        if clean.port == 443 { clean.port = nil }
        return clean.url.map { "git/" + $0.absoluteString }
    }

    private static func date(_ raw: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    @MainActor
    func read(_ live: Live, store: WKWebsiteDataStore) async -> LiveRead {
        guard let repository = repository(live.host), let request = request(for: repository) else { return .failed }
        let readStore = allowsSessionCookies ? store : WKWebsiteDataStore.nonPersistent()
        let answer: LiveReader.Answer?
        if let body = request.body {
            answer = try? await LiveReader.post(request.url, body: body, store: readStore, redirects: false)
        } else {
            answer = try? await LiveReader.get(request.url, store: readStore, redirects: false)
        }
        guard let answer else { return .failed }
        return await LiveText.off("live.parse") { parse(answer.data, status: answer.status, finalURL: answer.url, repository: repository, more: answer.more) }
    }
}
