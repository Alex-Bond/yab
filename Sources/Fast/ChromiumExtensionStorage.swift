import CryptoKit
import Foundation
import SQLite3
import WebKit
import YabCoreClient

/// What an extension keeps in chrome.storage (its settings, a list of sites, a
/// sign-in it holds there) stays one in both engines: .local and .sync, key by
/// key, each change following to the other side and the side written last
/// taking a key both changed.
///
/// WebKit's side is its SQLite database, read and written here, since at rest
/// no WebKit context exists to ask. A context running then reads the new values
/// on its next get, and hears no onChanged for them. Chromium's side answers
/// only in one of the extension's own pages, so one that is off crosses when it
/// is turned on: Chrome opens no page of it.
///
/// `Shadow` keeps a hash of each key as both sides last agreed, so a key gone
/// from one side reads as removed there rather than new on the other, and the
/// time of each side's files, so nothing opens while neither moved. Hashes only:
/// a password manager's vault is not copied a third time.
@MainActor
enum ChromiumExtensionStorage {
    /// The most one call sets: the helper's wire takes 4 MB.
    nonisolated private static let part = 2 * 1024 * 1024
    /// The most one call reads, in UTF-16 units.
    nonisolated private static let readPart = 900_000
    nonisolated private static let areas = [("local", "LocalStorage.db", "Local Extension Settings"),
                                            ("sync", "SyncStorage.db", "Sync Extension Settings")]

    struct Shadow: Codable, Equatable {
        var areas: [String: [String: String]]?
        var chromiumStamp: Double = 0
        var webKitStamp: Double = 0
        /// The optional grants both engines last agreed on.
        var grants: [String]?
    }

    private static func shadowFile(_ id: String, profile: String) -> URL {
        Store.file("ChromiumImports").appendingPathComponent("storage-" + profile).appendingPathComponent(id + ".json")
    }

    static func shadow(_ id: String, profile: String) -> Shadow {
        (try? Data(contentsOf: shadowFile(id, profile: profile))).flatMap { try? JSONDecoder().decode(Shadow.self, from: $0) } ?? Shadow()
    }

    static func save(_ shadow: Shadow, _ id: String, profile: String) throws {
        let file = shadowFile(id, profile: profile)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(shadow).write(to: file, options: .atomic)
    }

    static func forget(_ id: String, profile: String) {
        try? FileManager.default.removeItem(at: shadowFile(id, profile: profile))
    }

    /// The last write Chromium's files show.
    static func chromiumStamp(_ id: String, profile: String) -> Double {
        let root = Store.file("Chromium").appendingPathComponent("space-" + profile)
        return areas.compactMap { _, _, name in newest(root.appendingPathComponent(name).appendingPathComponent(id)) }.max() ?? 0
    }

    /// The last write WebKit's files show. `folder`: the extension's in its storage root.
    static func webKitStamp(_ folder: URL) -> Double {
        areas.flatMap { _, name, _ in [name, name + "-wal"] }
            .compactMap { stamp(folder.appendingPathComponent($0)) }.max() ?? 0
    }

    nonisolated private static func stamp(_ file: URL) -> Double? {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970
    }

    nonisolated private static func newest(_ folder: URL) -> Double? {
        let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return found.filter { $0.lastPathComponent != "LOCK" }.compactMap(stamp).max()
    }

    /// Whether either side was written since they last agreed.
    static func moved(_ id: String, profile: String, folder: URL) -> Bool {
        let known = shadow(id, profile: profile)
        return known.areas == nil || chromiumStamp(id, profile: profile) != known.chromiumStamp || webKitStamp(folder) != known.webKitStamp
    }

    /// WebKit's rows, each value already JSON text. Nil with no database.
    nonisolated static func rows(_ file: URL) -> [(key: String, value: String)]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        var base: OpaquePointer?
        defer { sqlite3_close(base) }
        guard sqlite3_open_v2(file.path, &base, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        guard sqlite3_prepare_v2(base, "SELECT key, value FROM extension_storage", -1, &query, nil) == SQLITE_OK else { return nil }
        var found: [(key: String, value: String)] = []
        while sqlite3_step(query) == SQLITE_ROW {
            guard let key = sqlite3_column_text(query, 0), let value = sqlite3_column_text(query, 1) else { continue }
            found.append((String(cString: key), String(cString: value)))
        }
        return found
    }

    /// The most text one call takes: a letter JSON escapes as \u00XX is six
    /// bytes on the wire, so 512 KB of any text stays under it.
    nonisolated static let piece = 512 * 1024

    /// `text` in pieces of at most `bytes` of UTF-8, never inside a letter.
    nonisolated static func pieces(_ text: String, bytes: Int = piece) -> [String] {
        var out: [String] = [], current = String.UnicodeScalarView(), held = 0
        for scalar in text.unicodeScalars {
            let size = scalar.value < 0x80 ? 1 : scalar.value < 0x800 ? 2 : scalar.value < 0x10000 ? 3 : 4
            if held + size > bytes, !current.isEmpty {
                out.append(String(current)); current = String.UnicodeScalarView(); held = 0
            }
            current.append(scalar); held += size
        }
        if !current.isEmpty || out.isEmpty { out.append(String(current)) }
        return out
    }

    /// Rows as JSON objects, in text, none over `size` unless one row is.
    nonisolated static func parts(_ rows: [(key: String, value: String)], size: Int = part) -> [String] {
        var out: [String] = [], current: [String] = [], held = 0
        for row in rows {
            guard let name = try? JSONEncoder().encode(row.key), let key = String(data: name, encoding: .utf8),
                  let parsed = row.value.data(using: .utf8), (try? JSONSerialization.jsonObject(with: parsed, options: [.fragmentsAllowed])) != nil else { continue }
            let piece = key + ":" + row.value
            if held + piece.utf8.count > size, !current.isEmpty {
                out.append("{" + current.joined(separator: ",") + "}")
                current = []; held = 0
            }
            current.append(piece); held += piece.utf8.count
        }
        if !current.isEmpty { out.append("{" + current.joined(separator: ",") + "}") }
        return out
    }

    /// One value's identity whichever engine wrote its JSON: the same number,
    /// keys in any order, the same hash. Nil for text that isn't JSON.
    nonisolated static func hash(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let plain = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return SHA256.hash(data: plain).map { String(format: "%02x", $0) }.joined()
    }

    /// Yab's own keys under WebKit: what the shim keeps there stays there.
    nonisolated static func crosses(_ key: String) -> Bool { !key.hasPrefix("__yab") }

    /// A database WebKit reads as its own, for one that never ran there.
    nonisolated private static func created(_ base: OpaquePointer?) -> Bool {
        sqlite3_exec(base, "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS extension_storage (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL); PRAGMA user_version=2;", nil, nil, nil) == SQLITE_OK
    }

    /// `values` written to WebKit's database and `removed` gone from it, at once.
    nonisolated static func write(_ file: URL, values: [(key: String, value: String)], removed: [String]) -> Bool {
        guard !values.isEmpty || !removed.isEmpty else { return true }
        let files = FileManager.default
        let fresh = !files.fileExists(atPath: file.path)
        if fresh { try? files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true) }
        var base: OpaquePointer?
        defer { sqlite3_close(base) }
        guard sqlite3_open_v2(file.path, &base, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { return false }
        sqlite3_busy_timeout(base, 3000)
        if fresh, !created(base) { return false }
        guard sqlite3_exec(base, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func run(_ sql: String, _ bind: (OpaquePointer?) -> Void) -> Bool {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(base, sql, -1, &statement, nil) == SQLITE_OK else { return false }
            bind(statement)
            return sqlite3_step(statement) == SQLITE_DONE
        }
        var fine = true
        for row in values where fine {
            fine = run("INSERT OR REPLACE INTO extension_storage (key, value) VALUES (?, ?)") { statement in
                sqlite3_bind_text(statement, 1, row.key, -1, transient)
                sqlite3_bind_text(statement, 2, row.value, -1, transient)
            }
        }
        for key in removed where fine {
            fine = run("DELETE FROM extension_storage WHERE key = ?") { sqlite3_bind_text($0, 1, key, -1, transient) }
        }
        sqlite3_exec(base, fine ? "COMMIT" : "ROLLBACK", nil, nil, nil)
        return fine
    }

    /// One area of chrome.storage, each value as JSON text. In pieces: the
    /// helper's wire takes 4 MB and a vault can be more.
    private static func read(_ area: String, page: ChromiumExtensionPage) async throws -> [String: String] {
        let length = try await page.run("const s = chrome.storage && chrome.storage[area]; if (!s) return 0; globalThis.__yabDump = JSON.stringify(await s.get(null)); return __yabDump.length;", ["area": area])
        let total = (length as? NSNumber)?.intValue ?? 0
        guard total > 0 else { return [:] }
        var text = ""
        var offset = 0
        while offset < total {
            let piece = try await page.run("return globalThis.__yabDump.slice(at, at + \(readPart));", ["at": offset])
            guard let got = piece as? String, !got.isEmpty else { break }
            text += got
            offset += readPart
        }
        _ = try? await page.run("delete globalThis.__yabDump; return true;")
        guard let data = text.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Crx.Refused.unpack
        }
        var out: [String: String] = [:]
        for (key, value) in object where crosses(key) {
            guard let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
                  let piece = String(data: encoded, encoding: .utf8) else { continue }
            out[key] = piece
        }
        return out
    }

    /// Both areas of one extension brought together. `folder` is its in
    /// WebKit's storage root; the page shows the extension (`show`).
    static func cross(_ id: String, page: ChromiumExtensionPage, folder: URL, profile: String, shadow: inout Shadow) async throws {
        let chromiumNewer = chromiumStamp(id, profile: profile) >= webKitStamp(folder)
        var agreed = shadow.areas ?? [:]
        for (area, database, _) in areas {
            let file = folder.appendingPathComponent(database)
            let webKitRows = await Task.detached(priority: .utility) { (rows(file) ?? []).filter { crosses($0.key) } }.value
            let webKit = Dictionary(webKitRows.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
            let chromium = try await read(area, page: page)
            let webKitHashes = webKit.compactMapValues(hash), chromiumHashes = chromium.compactMapValues(hash)
            let crossing = ExtensionOneList.crossing(chromium: chromiumHashes, webKit: webKitHashes,
                                                     shadow: shadow.areas?[area], chromiumNewer: chromiumNewer)
            if !crossing.toChromium.isEmpty {
                let going = crossing.toChromium.compactMap { key in webKit[key].map { (key: key, value: $0) } }
                // A value of any size crosses in pieces gathered in the page
                // and set once whole: one over the wire was once refused after
                // the parts before it were written.
                for part in parts(going) {
                    _ = try await page.run("globalThis.__yabCarry = ''; return true;")
                    for piece in pieces(part) {
                        _ = try await page.run("globalThis.__yabCarry += text; return true;", ["text": piece])
                    }
                    _ = try await page.run("const text = globalThis.__yabCarry; globalThis.__yabCarry = ''; await chrome.storage[area].set(JSON.parse(text)); return true;", ["area": area])
                }
            }
            if !crossing.removeFromChromium.isEmpty {
                _ = try await page.run("await chrome.storage[area].remove(keys); return true;", ["area": area, "keys": crossing.removeFromChromium])
            }
            let coming = crossing.toWebKit.compactMap { key in chromium[key].map { (key: key, value: $0) } }
            let removed = crossing.removeFromWebKit
            let written = await Task.detached(priority: .utility) { write(file, values: coming, removed: removed) }.value
            guard written else { throw CocoaError(.fileWriteUnknown) }
            var together = chromiumHashes
            for key in crossing.toChromium { together[key] = webKitHashes[key] }
            for key in crossing.removeFromChromium { together[key] = nil }
            agreed[area] = together
        }
        shadow.areas = agreed
        shadow.chromiumStamp = chromiumStamp(id, profile: profile)
        shadow.webKitStamp = webKitStamp(folder)
    }

    /// A page of the extension's own, where chrome.storage answers.
    static func open(_ id: String, profile: String, store: WKWebsiteDataStore?) async throws -> ChromiumExtensionPage {
        try await ChromiumExtensionPage(id, profile: profile, store: store)
    }
}


/// One of an extension's own pages (its manifest, which every extension has)
/// in a tab nobody sees, the way the side panel reads its options: where
/// chrome.storage and chrome.permissions answer for it.
@MainActor
final class ChromiumExtensionPage {
    let tab: Tab
    private let events = ChromiumSidePanel.Events()

    init(_ id: String, profile: String, store: WKWebsiteDataStore?) async throws {
        guard ChromiumExtensions.validID(id), let manifest = URL(string: "chrome-extension://\(id)/manifest.json") else {
            throw Crx.Refused.notAnID
        }
        tab = Tab(configuration: Web.configuration(shy: false, store: store ?? Store.websites), engine: .chromium)
        tab.warmProfile = profile
        tab.delegate = events
        tab.page.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        tab.go(to: manifest)
        for _ in 0..<100 {
            if events.failed { break }
            if events.finished, !tab.page.isLoading, tab.page.url?.host == id { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        tab.close()
        throw EngineStorageError.noDocument
    }

    /// An async function's body, with its arguments, run in the page.
    func run(_ body: String, _ arguments: [String: Any] = [:], gesture: Bool = false) async throws -> Any? {
        try await tab.page.call(body, arguments: arguments, gesture: gesture)
    }

    func close() { tab.close() }
}
