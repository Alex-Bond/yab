import Foundation
import WebKit

/// What reached you in Figma, from what its file browser reads with your
/// session: your notifications (a comment on your file or for you, a reply,
/// a file you may now open, someone asking to open yours), every team's at
/// once, and your recent files, one someone else edited since you last
/// opened it, which its versions say (docs/live-folders.md, Figma).
enum LiveFigma {
    static let lists: [(id: String, title: String)] = [
        ("inbox", "Comments and Access"),
        ("changed", "Files Changed by Others"),
    ]
    static let base = "https://www.figma.com/api/"

    /// A file's own address: Figma sends it on to its editor.
    static func fileURL(_ key: String) -> URL? { URL(string: "https://www.figma.com/file/" + key) }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func meta(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["meta"] as? [String: Any]
    }

    /// The unread notifications, the newest first, one a file. The bell's
    /// own list is a team's at a time and leaves out files of teams you're
    /// not in; this one, the older, has them all.
    static func notifications(_ data: Data) -> [LiveItem]? {
        guard let feed = meta(data)?["feed"] as? [[String: Any]] else { return nil }
        var out: [LiveItem] = []
        var files = Set<String>()
        for note in feed {
            let done = ["read_at", "resolved_at", "discarded_at", "rejected_at"].contains { note[$0] != nil && !(note[$0] is NSNull) }
            let locals = note["locals"] as? [String: Any] ?? [:]
            let file = locals["file"] as? [String: Any]
            guard !done, let key = locals["file_key"] as? String ?? file?["key"] as? String, !key.isEmpty,
                  files.insert(key).inserted else { continue }
            let link = (locals["open_url"] as? String).flatMap(URL.init(string:)).flatMap { $0.host()?.hasSuffix("figma.com") == true ? $0 : nil }
            guard let url = link ?? fileURL(key) else { continue }
            out.append(LiveItem(key: "figma/" + key, url: url, title: locals["file_name"] as? String ?? file?["name"] as? String ?? "Untitled",
                                group: "", words: words(note), updated: date(note["created_at"])))
        }
        return out
    }

    /// What a notification says, by the name it is tracked by
    /// ("file_comments_…", "file_role_request_approved_…") and what it
    /// holds: a comment naming you is a mention.
    static func words(_ note: [String: Any]) -> LiveWords {
        let track = (note["track_back"] as? String ?? "").lowercased()
        if track.contains("request_created") { return .request }
        if track.contains("approved") || track.contains("invite") || track.contains("shar") { return .shared }
        let locals = note["locals"] as? [String: Any] ?? [:]
        if let comment = locals["comment"] as? [String: Any] {
            let parts = comment["message_meta"] as? [[String: Any]] ?? []
            if let me = note["user_id"] as? String, parts.contains(where: { $0["user_id"] as? String == me }) { return .mention }
            return .comment
        }
        let batch = note["batch_locals"] as? [String: Any] ?? [:]
        if track.contains("comment") || (batch["comment_count"] as? Int ?? 0) + (batch["reply_count"] as? Int ?? 0) > 0 { return .comment }
        return .new
    }

    /// A file of Recents: when anyone last edited it, when you last opened it.
    struct File: Equatable {
        var key: String
        var name: String
        var url: URL
        var touched: Date
        var accessed: Date?
    }

    static func recent(_ data: Data) -> [File]? {
        guard let files = meta(data)?["recent_files"] as? [[String: Any]] else { return nil }
        return files.compactMap { file in
            guard let key = file["key"] as? String, let touched = date(file["touched_at"]),
                  (file["trashed_at"] ?? NSNull()) is NSNull, (file["deleted_at"] ?? NSNull()) is NSNull,
                  let url = (file["url"] as? String).flatMap(URL.init(string:)) ?? fileURL(key) else { return nil }
            return File(key: key, name: file["name"] as? String ?? "Untitled", url: url, touched: touched, accessed: date(file["accessed_at"]))
        }
    }

    /// Edited after you last opened them, in the last two weeks: the ones
    /// whose versions are asked who it was, six at most.
    static func candidates(_ files: [File], now: Date = Date()) -> [File] {
        let edited = files.filter { file in
            guard let accessed = file.accessed else { return false }
            return file.touched.timeIntervalSince(accessed) > 60 && now.timeIntervalSince(file.touched) < 14 * 24 * 3600
        }
        return Array(edited.sorted { $0.touched > $1.touched }.prefix(6))
    }

    /// Whether a version after `since` is someone else's: its `user_id`
    /// (the people beside it are names, not ids).
    static func others(_ data: Data, since: Date, me: String) -> Bool? {
        guard let versions = meta(data)?["versions"] as? [[String: Any]] else { return nil }
        return versions.contains { version in
            guard let at = date(version["touched_at"]) ?? date(version["created_at"]), at > since,
                  let by = version["user_id"] as? String else { return false }
            return by != me
        }
    }

    /// You, the one signed in.
    static func me(_ data: Data) -> String? {
        ((meta(data)?["users"] as? [[String: Any]])?.first)?["id"] as? String
    }

    /// Who edited a file since you opened it, by file and edit: asked once.
    @MainActor private static var looked: [String: Bool] = [:]

    @MainActor
    static func read(_ live: Live, store: WKWebsiteDataStore) async -> LiveRead {
        var out: [LiveItem] = []
        if live.show.contains("inbox") {
            guard let url = URL(string: base + "user_notifications"), let answer = try? await LiveReader.get(url, store: store) else { return .failed }
            if answer.status == 401 || answer.status == 403 { return .signedOut }
            guard answer.status == 200, let items = notifications(answer.data) else { return .failed }
            out += items
        }
        if live.show.contains("changed") {
            guard let stateURL = URL(string: base + "session/state"), let recentURL = URL(string: base + "recent_files"),
                  let state = try? await LiveReader.get(stateURL, store: store) else { return .failed }
            if state.status == 401 || state.status == 403 { return .signedOut }
            guard state.status == 200, let me = me(state.data),
                  let answer = try? await LiveReader.get(recentURL, store: store), answer.status == 200,
                  let files = recent(answer.data) else { return .failed }
            for file in candidates(files) {
                guard let accessed = file.accessed else { continue }
                let mark = "\(file.key)@\(file.touched.timeIntervalSince1970)"
                if looked[mark] == nil, let url = URL(string: base + "versions/" + file.key),
                   let answer = try? await LiveReader.get(url, store: store), answer.status == 200 {
                    looked[mark] = others(answer.data, since: accessed, me: me)
                }
                guard looked[mark] == true else { continue }
                out.append(LiveItem(key: "figma/" + file.key, url: file.url, title: file.name, group: "", words: .changed, updated: file.touched))
            }
        }
        var seen = Set<String>()
        return .items(out.filter { seen.insert($0.key).inserted }.sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) })
    }
}
