import Foundation

/// The bookmark tools use the same model as the bar, menus and extensions.
/// Validate the whole request before changing it: a missing folder is never
/// silently replaced by the root, and moving a folder cannot lose its tree.
@MainActor
enum AgentBookmarks {
    private struct Failure: Error { let message: String }
    private struct Place {
        let node: Bookmark
        let parent: UUID?
    }

    private static func find(_ id: UUID, in nodes: [Bookmark], parent: UUID? = nil) -> Place? {
        for node in nodes {
            if node.id == id { return Place(node: node, parent: parent) }
            if let found = find(id, in: node.children ?? [], parent: node.id) { return found }
        }
        return nil
    }

    private static func id(_ raw: Any?, field: String = "id") throws -> UUID {
        guard let raw = raw as? String, let id = UUID(uuidString: raw) else {
            throw Failure(message: "\(field) needs an exact id from bookmarks")
        }
        return id
    }

    private static func place(_ raw: Any?, in roots: [Bookmark]) throws -> Place {
        let id = try id(raw)
        guard let found = find(id, in: roots) else {
            throw Failure(message: "No bookmark or folder with that id. Read bookmarks again.")
        }
        return found
    }

    /// Empty means the root. New tools take folder IDs; bookmark_add also
    /// keeps its existing convenience of accepting an unambiguous name.
    private static func folder(_ raw: Any?, in roots: [Bookmark]) throws -> UUID? {
        guard let raw else { return nil }
        guard let value = raw as? String else { throw Failure(message: "folder needs a folder id or an empty string for the root") }
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let id = try id(value, field: "folder")
        guard let found = find(id, in: roots), found.node.isFolder else {
            throw Failure(message: "No folder with that id. Read bookmarks again.")
        }
        return id
    }

    private static func webURL(_ raw: Any?) throws -> URL {
        guard let raw = raw as? String, let url = URL(string: raw), Bookmark.keepable(url),
              let host = url.host, !host.isEmpty else { throw Failure(message: "url needs an http(s) web address") }
        return url
    }

    private static func title(_ raw: Any?) throws -> String {
        guard let raw = raw as? String else { throw Failure(message: "title needs a name") }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw Failure(message: "title cannot be empty") }
        return value
    }

    private static func answer(_ work: () throws -> [String: Any]) -> [String: Any] {
        do { return try work() }
        catch let error as Failure { return ["error": error.message] }
        catch { return ["error": error.localizedDescription] }
    }

    private static func record(_ node: Bookmark, parent: UUID?, verb: String) -> [String: Any] {
        let kind = node.isFolder ? "folder" : "bookmark"
        let parent = parent?.uuidString ?? "root"
        var result: [String: Any] = ["id": node.id.uuidString, "parent": parent, "title": node.title,
                                   "text": "\(verb) \"\(node.title)\" (\(kind) \(node.id.uuidString)). Parent: \(parent)."]
        if let url = node.url {
            result["url"] = url
            result["text"] = (result["text"] as? String ?? "") + "\n" + url
        }
        return result
    }

    static func text(_ roots: [Bookmark], query: String = "") -> String {
        list(["query": query], roots: roots)["text"] as? String ?? ""
    }

    static func list(_ request: [String: Any], roots: [Bookmark]) -> [String: Any] {
        answer {
            let offset = request["offset"] as? Int ?? 0
            let limit = request["limit"] as? Int ?? 100
            guard (request["offset"] == nil || request["offset"] as? Int != nil), offset >= 0,
                  (request["limit"] == nil || request["limit"] as? Int != nil), (1...400).contains(limit) else {
                throw Failure(message: "offset must be a nonnegative integer and limit an integer from 1 to 400")
            }
            let parent = try folder(request["folder"], in: roots)
            let nodes = parent.map { find($0, in: roots)?.node.children ?? [] } ?? roots
            let words = (request["query"] as? String ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            var rows: [String] = []
            func walk(_ nodes: [Bookmark], parent: UUID?, depth: Int) {
                for node in nodes {
                    if words.isEmpty || node.title.lowercased().contains(words) || (node.url ?? "").lowercased().contains(words) {
                        let indent = String(repeating: "  ", count: words.isEmpty ? depth : 0)
                        let kind = node.isFolder ? "folder" : "bookmark"
                        var line = "\(indent)- \(node.title)\(node.isFolder ? "/" : "") (\(kind) \(node.id.uuidString)); parent: \(parent?.uuidString ?? "root")"
                        if let url = node.url { line += "\n\(indent)  \(url)" }
                        rows.append(line)
                    }
                    walk(node.children ?? [], parent: node.id, depth: depth + 1)
                }
            }
            walk(nodes, parent: parent, depth: 0)
            let start = min(offset, rows.count)
            let end = start + min(limit, rows.count - start)
            var result: [String: Any] = ["offset": offset, "total": rows.count, "has_more": end < rows.count]
            if rows.isEmpty {
                result["text"] = words.isEmpty ? "No bookmarks yet." : "No bookmark matches that."
            } else {
                let range = start == end ? "No entries at offset \(offset)" : "Showing \(start + 1)–\(end)"
                let next = end < rows.count ? " Next offset: \(end)." : " End of list."
                result["text"] = "The user's bookmarks and folders with their ids. \(range) of \(rows.count).\(next)\n" + rows[start..<end].joined(separator: "\n")
                if end < rows.count { result["next_offset"] = end }
            }
            return result
        }
    }

    static func add(_ request: [String: Any], to bookmarks: Bookmarks) -> [String: Any] {
        answer {
            let url = try webURL(request["url"])
            let name = (request["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var parent: UUID?
            var newFolder: String?
            if let raw = request["folder"] {
                guard let raw = raw as? String else { throw Failure(message: "folder needs a name or id") }
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if UUID(uuidString: value) != nil { parent = try folder(value, in: bookmarks.roots) }
                else if !value.isEmpty {
                    let matches = Bookmarks.folders(bookmarks.roots).map(\.node).filter { $0.title.caseInsensitiveCompare(value) == .orderedSame }
                    guard matches.count <= 1 else { throw Failure(message: "Several folders have that name. Use the exact folder id from bookmarks.") }
                    if let found = matches.first { parent = found.id } else { newFolder = value }
                }
            }
            if let id = bookmarks.id(for: url), let existing = find(id, in: bookmarks.roots) {
                return record(existing.node, parent: existing.parent, verb: "Already bookmarked")
            }
            if let newFolder { parent = bookmarks.insert(.folder(newFolder, []), into: nil).id }
            let made = bookmarks.insert(.site(name, url), into: parent)
            return record(made, parent: parent, verb: "Bookmarked")
        }
    }

    static func createFolder(_ request: [String: Any], in bookmarks: Bookmarks) -> [String: Any] {
        answer {
            let name = try title(request["title"])
            let parent = try folder(request["folder"], in: bookmarks.roots)
            let made = bookmarks.insert(.folder(name, []), into: parent)
            return record(made, parent: parent, verb: "Created")
        }
    }

    static func update(_ request: [String: Any], in bookmarks: Bookmarks) -> [String: Any] {
        answer {
            let found = try place(request["id"], in: bookmarks.roots)
            guard request["title"] != nil || request["url"] != nil else { throw Failure(message: "Provide title or url to change") }
            let name = try request["title"].map { try title($0) }
            if found.node.isFolder, request["url"] != nil { throw Failure(message: "A folder has no url to change") }
            let url = try request["url"].map { try webURL($0).absoluteString }
            bookmarks.update(found.node.id, title: name, url: url)
            return record(find(found.node.id, in: bookmarks.roots)!.node, parent: found.parent, verb: "Updated")
        }
    }

    static func move(_ request: [String: Any], in bookmarks: Bookmarks) -> [String: Any] {
        answer {
            let found = try place(request["id"], in: bookmarks.roots)
            guard request["folder"] != nil || request["before"] != nil else { throw Failure(message: "Provide folder or before to move a bookmark") }
            let parent: UUID?
            if request["folder"] != nil { parent = try folder(request["folder"], in: bookmarks.roots) }
            else { parent = found.parent }
            if let parent, find(parent, in: [found.node]) != nil { throw Failure(message: "A folder cannot move into itself or its descendants") }
            let before = try request["before"].map { try id($0, field: "before") }
            if let before {
                guard let sibling = find(before, in: bookmarks.roots), sibling.parent == parent else {
                    throw Failure(message: "before must name a bookmark or folder in the destination folder")
                }
            }
            bookmarks.move(found.node.id, into: parent, before: before)
            return record(found.node, parent: parent, verb: "Moved")
        }
    }

    static func delete(_ request: [String: Any], from bookmarks: Bookmarks) -> [String: Any] {
        answer {
            let found = try place(request["id"], in: bookmarks.roots)
            if found.node.isFolder, !(found.node.children ?? []).isEmpty, request["recursive"] as? Bool != true {
                throw Failure(message: "This folder is not empty. Set recursive to true only if the user asked to delete the folder and everything in it.")
            }
            bookmarks.remove(found.node.id)
            return record(found.node, parent: found.parent, verb: "Deleted")
        }
    }
}
