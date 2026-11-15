import Foundation
import SQLite3
import Testing
@testable import Fast

// A browser that is running keeps its newest rows in the write-ahead log
// until it folds them in. A copy of the main file alone misses them; a copy
// with its log beside it doesn't.
struct SqliteLogTests {
    static func exec(_ db: OpaquePointer, _ sql: String) {
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "\(sql)")
    }

    static func count(_ file: URL) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM urls", -1, &statement, nil) == SQLITE_OK, let statement else { return -1 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : -1
    }

    @Test func historyInTheLogIsRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = folder.appendingPathComponent("History")

        // Chromium's table, in WAL mode, with the browser still holding it
        // open and nothing folded in yet.
        var db: OpaquePointer?
        #expect(sqlite3_open(history.path, &db) == SQLITE_OK)
        let live = try #require(db)
        defer { sqlite3_close(live) }
        Self.exec(live, "PRAGMA journal_mode=WAL")
        Self.exec(live, "PRAGMA wal_autocheckpoint=0")
        Self.exec(live, "CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER)")
        Self.exec(live, "PRAGMA wal_checkpoint(TRUNCATE)")
        let now = Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        for index in 0..<25 {
            Self.exec(live, "INSERT INTO urls(url, title, visit_count, typed_count, last_visit_time, hidden) VALUES ('https://site\(index).example/', 'Site \(index)', 2, 0, \(now - Int64(index) * 1_000_000), 0)")
        }
        #expect(FileManager.default.fileExists(atPath: history.path + "-wal"))

        // The main file alone, the way it used to be read.
        let bare = folder.appendingPathComponent("bare.db")
        try FileManager.default.copyItem(at: history, to: bare)
        #expect(Self.count(bare) == 0)

        let places = try Chromium.placeRows(in: history, limit: 100)
        #expect(places.count == 25)
        #expect(places.first?.title == "Site 0")
        // The browser's own files are as they were.
        #expect(FileManager.default.fileExists(atPath: history.path + "-wal"))
    }
}
