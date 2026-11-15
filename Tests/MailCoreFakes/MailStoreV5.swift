import Foundation
import SQLite3

// Mail stores as older Yabs wrote them, and plain SQLite on the file, for
// the migration tests and the app's tests of what they keep.

/// A store file as Yab 0.0.2 and 0.0.3 wrote it ("version" 5), with
/// `count` messages in threads of two, every other one with its body.
public enum MailStoreV5 {
    public static let shape = """
    CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT);
    CREATE TABLE messages(
      id TEXT PRIMARY KEY, thread TEXT NOT NULL, from_name TEXT NOT NULL, from_addr TEXT NOT NULL,
      recipients TEXT NOT NULL, cc TEXT NOT NULL, subject TEXT NOT NULL, snippet TEXT NOT NULL,
      at REAL NOT NULL, labels TEXT NOT NULL, rfc_id TEXT NOT NULL, in_reply_to TEXT NOT NULL,
      refs TEXT NOT NULL, bulk INTEGER NOT NULL);
    CREATE INDEX messages_thread ON messages(thread);
    CREATE INDEX messages_at ON messages(at);
    CREATE TABLE bodies(id TEXT PRIMARY KEY, text TEXT NOT NULL, html TEXT, fetched REAL NOT NULL);
    CREATE TABLE ops(
      seq INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, thread TEXT NOT NULL, label TEXT NOT NULL,
      tries INTEGER NOT NULL DEFAULT 0, not_before REAL NOT NULL, made REAL NOT NULL, taken REAL);
    CREATE TABLE drafts(
      id TEXT PRIMARY KEY, thread TEXT NOT NULL, recipients TEXT NOT NULL, cc TEXT NOT NULL, subject TEXT NOT NULL,
      body TEXT NOT NULL, in_reply_to TEXT NOT NULL, refs TEXT NOT NULL, message_id TEXT NOT NULL, updated REAL NOT NULL);
    CREATE TABLE sense(
      thread TEXT PRIMARY KEY, message TEXT NOT NULL, needs INTEGER NOT NULL, gist TEXT NOT NULL, due REAL,
      kind TEXT NOT NULL, by_model INTEGER NOT NULL, at REAL NOT NULL);
    CREATE TABLE ahead(thread TEXT NOT NULL, message TEXT NOT NULL, n INTEGER NOT NULL, body TEXT NOT NULL,
      PRIMARY KEY(thread, n));
    CREATE TABLE snoozes(thread TEXT PRIMARY KEY, until REAL, why TEXT NOT NULL, message TEXT NOT NULL, at REAL NOT NULL);
    CREATE VIRTUAL TABLE words USING fts5(
      id UNINDEXED, subject, sender, body, tokenize='unicode61 remove_diacritics 2');
    """

    public static func write(_ file: URL, count: Int = 50) {
        var db: OpaquePointer?
        sqlite3_open(file.path, &db)
        defer { sqlite3_close(db) }
        SQL.exec(db, "PRAGMA journal_mode=WAL; " + shape)
        SQL.exec(db, "INSERT INTO meta VALUES('version', '5'), ('me', 'me@example.com'), ('history', '4242'), ('synced', '1790000000')")
        let now = Date().timeIntervalSince1970
        SQL.exec(db, "BEGIN")
        for n in 0..<count {
            let id = "m\(n)", thread = "t\(n / 2)", subject = "Quarterly numbers \(n / 2)"
            let mine = n % 2 == 1
            SQL.run(db, "INSERT INTO messages VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                id, thread, mine ? "" : "Anna Lindqvist", mine ? "me@example.com" : "anna\(n / 2)@fold.studio",
                mine ? "anna\(n / 2)@fold.studio" : "me@example.com", "", subject, "The snippet of \(id)",
                now - Double(count - n) * 3600, mine ? "|SENT|" : "|INBOX|UNREAD|", "<\(id)@fold.studio>", "", "", 0,
            ])
            // The index as 0.0.3 kept it: its own rowids, by id.
            let body = n % 2 == 0 ? "Revenue for \(thread) is in the deck, page \(n)." : nil
            if let body { SQL.run(db, "INSERT INTO bodies VALUES(?,?,?,?)", [id, body, "<p>\(body)</p>", now]) }
            SQL.run(db, "INSERT INTO words(id, subject, sender, body) VALUES(?,?,?,?)", [id, subject, "Anna Lindqvist", body ?? "The snippet of \(id)"])
        }
        SQL.run(db, "INSERT INTO ops(kind, thread, label, not_before, made) VALUES('archive', 't3', '', ?, ?)", [now + 600, now])
        SQL.run(db, "INSERT INTO ops(kind, thread, label, not_before, made) VALUES('send', 'd1', '', ?, ?)", [now + 86_400, now])
        SQL.run(db, "INSERT INTO drafts VALUES('d1', 't1', 'anna1@fold.studio', '', 'Re: Quarterly numbers 1', 'Sending them Friday.', '', '', '<yab-1@example.com>', ?)", [now])
        SQL.run(db, "INSERT INTO snoozes VALUES('t2', ?, 'Tomorrow, 9:00', 'm4', ?)", [now + 86_400, now])
        SQL.run(db, "INSERT INTO sense VALUES('t0', 'm0', 1, 'Wants the numbers', NULL, 'person', 0, ?)", [now])
        SQL.run(db, "INSERT INTO ahead VALUES('t0', 'm0', 0, 'Friday works.')", [])
        SQL.exec(db, "COMMIT")
    }
}

/// Plain SQLite for the tests: the file as it is on disk.
public enum SQL {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    @discardableResult
    public static func exec(_ db: OpaquePointer?, _ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    public static func run(_ db: OpaquePointer?, _ sql: String, _ args: [Any]) {
        _ = rows(db, sql, args)
    }

    public static func rows(_ db: OpaquePointer?, _ sql: String, _ args: [Any] = []) -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        for (index, arg) in args.enumerated() {
            let at = Int32(index + 1)
            switch arg {
            case let value as String: sqlite3_bind_text(statement, at, value, -1, transient)
            case let value as Int: sqlite3_bind_int64(statement, at, Int64(value))
            case let value as Double: sqlite3_bind_double(statement, at, value)
            default: sqlite3_bind_null(statement, at)
            }
        }
        var out: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_type(statement, column) == SQLITE_NULL ? "NULL" : String(cString: sqlite3_column_text(statement, column))
            })
        }
        return out
    }

    /// Everything a file holds, to tell two moments of it apart.
    public static func snapshot(_ file: URL) -> [String] {
        var db: OpaquePointer?
        sqlite3_open(file.path, &db)
        defer { sqlite3_close(db) }
        var out = rows(db, "SELECT type, name, tbl_name, coalesce(sql, '') FROM sqlite_master ORDER BY name").map { $0.joined(separator: " ") }
        for table in ["meta", "messages", "bodies", "ops", "drafts", "snoozes", "sense", "ahead"] {
            out += rows(db, "SELECT * FROM \(table) ORDER BY 1").map { table + ": " + $0.joined(separator: "|") }
        }
        out += rows(db, "SELECT rowid, id, body FROM words ORDER BY rowid").map { "words: " + $0.joined(separator: "|") }
        return out
    }

    /// Its tables, indexes and their columns, however their SQL was written.
    public static func shape(_ file: URL) -> [String] {
        var db: OpaquePointer?
        sqlite3_open(file.path, &db)
        defer { sqlite3_close(db) }
        var out: [String] = []
        for object in rows(db, "SELECT type, name, tbl_name FROM sqlite_master ORDER BY name") {
            out.append(object.joined(separator: " "))
            let pragma = object[0] == "index" ? "index_info" : "table_info"
            out += rows(db, "PRAGMA \(pragma)(\(object[1]))").map { "  " + $0.joined(separator: "|") }
        }
        return out
    }

    public static func columns(_ file: URL, _ table: String) -> [String] {
        var db: OpaquePointer?
        sqlite3_open(file.path, &db)
        defer { sqlite3_close(db) }
        return rows(db, "PRAGMA table_info(\(table))").map { $0[1] }
    }

    public static func on(_ file: URL, _ sql: String) {
        var db: OpaquePointer?
        sqlite3_open(file.path, &db)
        defer { sqlite3_close(db) }
        exec(db, sql)
    }
}
