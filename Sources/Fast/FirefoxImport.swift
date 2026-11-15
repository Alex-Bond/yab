import AppKit
import Foundation
import SQLite3

// Bookmarks and history from Zen, Firefox, and anything else built on
// Firefox that keeps its profiles the same way.
//
// Each profile is a folder under the browser's own one in Application
// Support, listed by a profiles.ini beside them, and it keeps both its
// bookmarks and its history in one SQLite file, places.sqlite: the pages in
// moz_places, the visits in moz_historyvisits, the bookmark tree in
// moz_bookmarks pointing into moz_places.
//
// Firefox holds that file with an exclusive lock while it runs, so nothing
// else can read it in place: the file and its write-ahead log are copied
// side by side to a folder of yab's own and the copy is read.
//
// Passwords are not read from here. Firefox wraps them with a key of its
// own, and the way to move them is its own export, about:logins' ⋯ ›
// Export Passwords…, a CSV that Vault.take(csv:) reads like any other.

enum Firefox {
    struct Source: Identifiable, Hashable {
        let name: String
        /// Under ~/Library/Application Support.
        let folder: String
        /// The app itself, so a folder left behind by a browser that was
        /// thrown away doesn't count as a browser.
        let bundle: String
        /// A fixture or an explicitly selected data folder.
        var dataRoot: URL? = nil

        var id: String { name }

        var app: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) }

        var root: URL {
            if let dataRoot { return dataRoot }
            return FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(folder, isDirectory: true)
        }

        /// The profiles with a places.sqlite, the one in use first: the
        /// install's own default from profiles.ini, then the one marked
        /// Default=1, then the rest in the order listed. Without a
        /// profiles.ini, every folder under Profiles.
        var profiles: [URL] {
            let files = FileManager.default
            let ini = root.appendingPathComponent("profiles.ini")
            var listed: [URL] = []
            var first: [URL] = []
            if let text = try? String(contentsOf: ini, encoding: .utf8) {
                for section in Firefox.sections(of: text) {
                    if section.name.hasPrefix("Install"), let path = section.values["Default"] {
                        first.append(Firefox.folder(path, relative: true, in: root))
                    }
                    guard section.name.hasPrefix("Profile"), let path = section.values["Path"] else { continue }
                    let folder = Firefox.folder(path, relative: section.values["IsRelative"] != "0", in: root)
                    if section.values["Default"] == "1" { first.append(folder) }
                    listed.append(folder)
                }
            } else {
                let under = root.appendingPathComponent("Profiles", isDirectory: true)
                listed = ((try? files.contentsOfDirectory(at: under, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
            var seen = Set<String>()
            return (first + listed).filter { folder in
                files.fileExists(atPath: folder.appendingPathComponent("places.sqlite").path)
                    && seen.insert(folder.standardizedFileURL.path).inserted
            }
        }

        /// When it was last browsed in: the newest of its profiles'
        /// places.sqlite or its log, which it writes as it goes.
        var lastUsed: Date? {
            profiles
                .flatMap { [$0.appendingPathComponent("places.sqlite"), $0.appendingPathComponent("places.sqlite-wal")] }
                .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                .max()
        }

        /// The app's own icon, the one in the Dock.
        var icon: NSImage? {
            guard let app else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 64, height: 64)
            return icon
        }
    }

    static let known: [Source] = [
        Source(name: "Zen", folder: "zen", bundle: "app.zen-browser.zen"),
        Source(name: "Firefox", folder: "Firefox", bundle: "org.mozilla.firefox"),
    ]

    /// Fixture folders standing in for the browsers on this Mac, in a test
    /// world only.
    nonisolated(unsafe) static var standIns: [Source] = []

    /// Only the browsers actually on this Mac with a profile to read, the
    /// one browsed in last first.
    static func installed() -> [Source] {
        if Store.testing, !standIns.isEmpty { return standIns }
        return known.filter { $0.app != nil && !$0.profiles.isEmpty }
            .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    }

    // MARK: - profiles.ini

    struct Section {
        let name: String
        var values: [String: String]
    }

    /// An INI file's sections, "[Profile0]" and its "Key=Value" lines.
    static func sections(of text: String) -> [Section] {
        var out: [Section] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                out.append(Section(name: String(line.dropFirst().dropLast()), values: [:]))
            } else if let equals = line.firstIndex(of: "="), !out.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("#") {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                out[out.count - 1].values[key] = value
            }
        }
        return out
    }

    static func folder(_ path: String, relative: Bool, in root: URL) -> URL {
        relative ? root.appendingPathComponent(path, isDirectory: true) : URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - reading a profile

    /// places.sqlite and its log, copied side by side into a folder of their
    /// own, the copy opened. Nil when it can't be copied or opened. The
    /// folder goes when `body` returns.
    static func withCopy<T>(of profile: URL, _ body: (OpaquePointer) -> T?) -> T? {
        let files = FileManager.default
        let source = profile.appendingPathComponent("places.sqlite")
        let temp = files.temporaryDirectory.appendingPathComponent("yab-firefox-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: temp) }
        do {
            try files.createDirectory(at: temp, withIntermediateDirectories: true)
            let copy = temp.appendingPathComponent("places.sqlite")
            try files.copyItem(at: source, to: copy)
            let wal = URL(fileURLWithPath: source.path + "-wal")
            if files.fileExists(atPath: wal.path) {
                try files.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
            }
            var db: OpaquePointer?
            // Read and write: SQLite folds the copied log into the copy.
            guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }
                return nil
            }
            defer { sqlite3_close(db) }
            return body(db)
        } catch {
            return nil
        }
    }

    /// Microseconds since 1970, Firefox's idea of a date. Nil for none.
    static func date(_ stamp: Int64) -> Date? {
        stamp > 0 ? Date(timeIntervalSince1970: Double(stamp) / 1_000_000) : nil
    }

    // MARK: - what they kept

    /// The bookmarks toolbar first, as Chromium's bar is, then the
    /// Bookmarks Menu, Other Bookmarks and Mobile as folders of their own.
    /// Tags, which Firefox keeps in the same tree, are left out. Profiles
    /// after the first are merged in by address, as Chromium's are.
    static func bookmarks(in source: Source) -> [Bookmark] {
        var out: [Bookmark] = []
        var earlier = Set<String>()
        for folder in source.profiles {
            guard let profile = withCopy(of: folder, { bookmarks(in: $0) }) else { continue }
            Bookmarks.merge(profile, into: &out, skipping: earlier, fresh: true)
            earlier.formUnion(Bookmarks.addresses(profile))
        }
        return out
    }

    private struct Mark {
        let id: Int64
        let type: Int32
        let parent: Int64
        let title: String
        let url: String?
        let added: Date?
        let guid: String
    }

    static func bookmarks(in db: OpaquePointer) -> [Bookmark]? {
        let sql = """
        SELECT b.id, b.type, b.parent, COALESCE(b.title, ''), p.url, b.dateAdded, COALESCE(b.guid, '')
        FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk
        ORDER BY b.parent, b.position
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        var children: [Int64: [Mark]] = [:]
        var roots: [String: Int64] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let mark = Mark(
                id: sqlite3_column_int64(statement, 0),
                type: sqlite3_column_int(statement, 1),
                parent: sqlite3_column_int64(statement, 2),
                title: sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "",
                url: sqlite3_column_text(statement, 4).map { String(cString: $0) },
                added: date(sqlite3_column_int64(statement, 5)),
                guid: sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? ""
            )
            children[mark.parent, default: []].append(mark)
            roots[mark.guid] = mark.id
        }

        // 1 a page, 2 a folder, 3 a separator. A folder is walked once, so a
        // broken tree that loops can't hang the read.
        var walked = Set<Int64>()
        func nodes(under id: Int64) -> [Bookmark] {
            guard walked.insert(id).inserted else { return [] }
            return (children[id] ?? []).compactMap { mark in
                switch mark.type {
                case 2:
                    return .folder(mark.title, nodes(under: mark.id), added: mark.added)
                case 1:
                    guard let text = mark.url, let url = URL(string: text), Bookmark.keepable(url) else { return nil }
                    return .site(mark.title, url, added: mark.added)
                default:
                    return nil
                }
            }
        }

        var out: [Bookmark] = []
        if let bar = roots["toolbar_____"] { out += nodes(under: bar) }
        for (guid, name) in [("menu________", "Bookmarks Menu"), ("unfiled_____", "Other"), ("mobile______", "Mobile")] {
            guard let id = roots[guid] else { continue }
            let kids = nodes(under: id)
            if !kids.isEmpty { out.append(.folder(name, kids)) }
        }
        return out
    }

    // MARK: - where they have been

    /// The places visited, newest first, as Chromium's are, typed counted
    /// from the visits made by typing (visit_type 2). Only web pages, left
    /// out in the query itself so a limit counts only those.
    static func places(in source: Source, limit: Int? = nil) -> [Chromium.Place] {
        var out: [Chromium.Place] = []
        for folder in source.profiles {
            out += withCopy(of: folder) { places(in: $0, limit: limit) } ?? []
        }
        let sorted = out.sorted { $0.last > $1.last }
        return limit.map { Array(sorted.prefix(max(0, $0))) } ?? sorted
    }

    static func places(in db: OpaquePointer, limit: Int? = nil) -> [Chromium.Place]? {
        let sql = """
        SELECT p.url, COALESCE(p.title, ''), p.visit_count, p.last_visit_date,
               (SELECT COUNT(*) FROM moz_historyvisits v WHERE v.place_id = p.id AND v.visit_type = 2)
        FROM moz_places p
        WHERE p.hidden = 0 AND p.visit_count > 0 AND p.last_visit_date > 0
          AND (p.url LIKE 'https://%' OR p.url LIKE 'http://%')
        ORDER BY p.last_visit_date DESC \(limit.map { "LIMIT \(max(0, $0))" } ?? "")
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        var out: [Chromium.Place] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0), let url = URL(string: String(cString: raw)),
                  Bookmark.keepable(url)
            else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let count = Int(sqlite3_column_int(statement, 2))
            let last = date(sqlite3_column_int64(statement, 3)) ?? Date()
            let typed = Int(sqlite3_column_int(statement, 4))
            out.append(Chromium.Place(url: url, title: title, count: max(1, count), typed: max(0, typed), last: last))
        }
        return out
    }
}
