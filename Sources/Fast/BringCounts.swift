import AppKit
import Foundation
import SQLite3

// Counts and file stamps are available only inside an explicit import.
// Discovery and Settings opening must not even stat credential paths.

/// The parts of a browser that are counted apart, each from its own files.
enum BringPart: String, CaseIterable, Sendable {
    case passwords, wallet, bookmarks, places, cookies, extensions, tabs
}

/// A part's files as they are now: each one's size and the time it was
/// written, the journal SQLite keeps beside it too. Equal stamps, the same
/// count; reading them costs a few stat calls, never the file.
enum BringStamp {
    static func stamps(_ source: Chromium.Source) -> [BringPart: String] {
        guard source.credentialAccess else { return [:] }
        let profiles = source.profiles
        func each(_ names: [String]) -> [URL] {
            profiles.flatMap { profile in names.map { profile.appendingPathComponent($0) } }
        }
        var out: [BringPart: String] = [:]
        out[.passwords] = stamp(each(["Login Data", "Login Data For Account"]), sqlite: true)
        out[.wallet] = stamp(each(["Web Data"]), sqlite: true)
        out[.bookmarks] = stamp(each(Chromium.bookmarkFiles), sqlite: false)
        out[.places] = stamp(each(["History"]), sqlite: true)
        out[.cookies] = stamp(each(["Network/Cookies", "Cookies"]), sqlite: true)
        out[.extensions] = stamp(each(["Preferences", "Secure Preferences", "Extensions"]), sqlite: false)
        // Arc's sidebar and Dia's containers beside the data folder, the
        // profiles' list, Dia's tabs.db and Chromium's sessions.
        let beside = source.root.deletingLastPathComponent()
        var tabs = ["StorableSidebar.json", "StorableProfileContainers.json"].map { beside.appendingPathComponent($0) }
        tabs.append(source.root.appendingPathComponent("Local State"))
        tabs += each(["tabs.db", "Current Session", "Last Session", "Current Tabs", "Last Tabs", "Sessions"])
        tabs += profiles.flatMap { profile -> [URL] in
            let sessions = profile.appendingPathComponent("Sessions")
            return ((try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.path < $1.path }
        }
        out[.tabs] = stamp(tabs, sqlite: true)
        return out
    }

    private static func stamp(_ files: [URL], sqlite: Bool) -> String {
        let suffixes = sqlite ? ["", "-wal", "-journal"] : [""]
        return files.flatMap { file in suffixes.map { file.path + $0 } }.map { path in
            guard let found = try? FileManager.default.attributesOfItem(atPath: path) else { return path + "|-" }
            let size = (found[.size] as? NSNumber)?.int64Value ?? -1
            let date = (found[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            return "\(path)|\(size)|\(date)"
        }.joined(separator: "\n")
    }
}

/// The counts read off the main thread for the parts asked, nil for the
/// rest, which stay as they were.
struct BringTally {
    var passwords: Int?
    var cards: Int?
    var addresses: Int?
    var memory: Int?
    var chats: Int?
    var bookmarks: Int?
    var places: Int?
    var cookies: Int?
    var signIns: Int?
    /// Every extension on there, Yab's own not yet left out.
    var extensions: [Chromium.Extension]?

    static func read(_ source: Chromium.Source, _ parts: Set<BringPart>) -> BringTally {
        var out = BringTally()
        guard source.credentialAccess else { return out }
        if parts.contains(.passwords) { out.passwords = Chromium.loginCount(source) }
        if parts.contains(.wallet) {
            let wallet = Chromium.walletCount(source)
            out.cards = wallet.cards
            out.addresses = wallet.addresses
        }
        if source.bundle == AsideImport.bundle {
            let aside = AsideImport.read()
            out.memory = aside.notes.count
            out.chats = aside.chats.count
        }
        if parts.contains(.bookmarks) { out.bookmarks = Bookmarks.count(Chromium.bookmarks(in: source)) }
        if parts.contains(.places) { out.places = Chromium.placeCount(in: source) }
        if parts.contains(.cookies) {
            let cookies = Chromium.cookieTally(source)
            out.cookies = cookies.live
            out.signIns = cookies.sites
        }
        if parts.contains(.extensions) { out.extensions = Chromium.extensions(in: source).filter(\.enabled) }
        return out
    }

    /// Into what is shown, the parts read only. `fresh` leaves out the
    /// extensions Yab has already.
    func apply(to counts: inout Bringing.Counts, aside: Bool, fresh: ([Chromium.Extension]) -> [Chromium.Extension]) {
        if let passwords { counts.passwords = passwords }
        if let cards { counts.cards = cards }
        if let addresses { counts.addresses = addresses }
        if aside {
            counts.memory = memory
            counts.chats = chats
        }
        if let bookmarks { counts.bookmarks = bookmarks }
        if let places { counts.places = places }
        if let cookies { counts.cookies = cookies }
        if let signIns { counts.signIns = signIns }
        if let extensions { counts.extensions = fresh(extensions) }
    }
}

/// What was found and counted last, on the main thread, for the next
/// Bringing (Settings opened again, or after the welcome).
@MainActor
enum BringCache {
    /// Long enough for Settings to be closed and opened again; the files
    /// are looked at again each time all the same.
    static let lifetime: TimeInterval = 5 * 60

    struct Found {
        var sources: [Chromium.Source]
        var icons: [String: NSImage]
        var used: [String: Date]
        var defaultID: String?
        var at: Date
    }

    struct Entry {
        var counts: Bringing.Counts
        /// The enabled extensions there, before Yab's own were left out.
        var extensions: [Chromium.Extension]?
        var stamps: [BringPart: String]
        var at: Date
    }

    private static var found: Found?
    private static var entries: [String: Entry] = [:]

    static var browsers: Found? {
        guard let found, -found.at.timeIntervalSinceNow < lifetime else { return nil }
        return found
    }

    static func keep(_ found: Found) { self.found = found }

    private static func key(_ source: Chromium.Source) -> String { source.id + "\u{1F}" + source.root.path }

    static func entry(_ source: Chromium.Source) -> Entry? {
        let key = key(source)
        guard let entry = entries[key] else { return nil }
        guard -entry.at.timeIntervalSinceNow < lifetime else {
            entries[key] = nil
            return nil
        }
        return entry
    }

    /// What is shown for it now, with the stamps of the parts just read.
    static func keep(_ source: Chromium.Source, counts: Bringing.Counts, extensions: [Chromium.Extension]? = nil, stamps: [BringPart: String] = [:]) {
        let key = key(source)
        var entry = entries[key] ?? Entry(counts: counts, stamps: [:], at: .now)
        entry.counts = counts
        if let extensions { entry.extensions = extensions }
        entry.stamps.merge(stamps) { _, new in new }
        entry.at = .now
        entries[key] = entry
    }

    /// A test's world starts with nothing kept.
    static func forget() {
        found = nil
        entries = [:]
    }
}

extension Chromium {
    /// How many pages its history holds, as `places(in:)` would list them,
    /// counted by SQLite rather than read row by row into memory.
    static func placeCount(in source: Source) -> Int {
        var total = 0
        for folder in source.profiles {
            let history = folder.appendingPathComponent("History")
            guard FileManager.default.fileExists(atPath: history.path), let temp = try? copyWithLog(history) else { continue }
            defer { removeWithLog(temp) }
            var db: OpaquePointer?
            guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { continue }
            defer { sqlite3_close(db) }
            let sql = """
            SELECT COUNT(*) FROM urls WHERE hidden = 0 AND visit_count > 0
            AND (url LIKE 'http://%' OR url LIKE 'https://%')
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { continue }
            defer { sqlite3_finalize(statement) }
            if sqlite3_step(statement) == SQLITE_ROW { total += Int(sqlite3_column_int64(statement, 0)) }
        }
        return total
    }
}
