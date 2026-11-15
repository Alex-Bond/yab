import Foundation
import SQLite3
import Testing
@testable import MailCore
@testable import YabStore

/// The one SQLite connection the stores share: values bound by type, rows
/// read by place and by name, statements kept compiled and let go of.
struct SQLiteConnectionTests {
    @Test func valuesGoInAndComeBackByName() throws {
        let db = try #require(SQLiteConnection(path: nil))
        #expect(db.exec("CREATE TABLE t(id TEXT PRIMARY KEY, n INTEGER, x REAL, flag INTEGER, blob BLOB, none TEXT)"))
        #expect(db.run("INSERT INTO t VALUES(?,?,?,?,?,?)", ["a", 7, 2.5, true, Data([1, 2, 3]), Optional<String>.none as Any]))
        #expect(db.run("INSERT INTO t VALUES(?,?,?,?,?,?)", ["b", Int64(8), 3, false, Data(), NSNull()]))
        let rows = db.query("SELECT id, n AS count, x, flag, blob, none FROM t ORDER BY id")
        #expect(rows.count == 2)
        let a = try #require(rows.first)
        #expect(a.string("id") == "a")
        #expect(a.int("count") == 7)
        #expect(a.double("x") == 2.5)
        #expect(a.bool("flag") == true)
        #expect(a.data("blob") == Data([1, 2, 3]))
        #expect(a["none"] == nil)
        #expect(a[0] as? String == "a", "by place too")
        #expect(a.first as? String == "a")
        // A whole number bound to a REAL column reads back as a Double.
        #expect(rows[1].double("x") == 3)
        #expect(rows[1].bool("flag") == false)
        #expect(db.string("SELECT id FROM t WHERE n = ?", [8]) == "b")
        #expect(db.strings("SELECT id FROM t ORDER BY id") == ["a", "b"])
        #expect(db.int("SELECT count(*) FROM t") == 2)
    }

    @Test func aFailedStatementSaysSo() throws {
        let db = try #require(SQLiteConnection(path: nil))
        #expect(db.exec("CREATE TABLE t(id TEXT PRIMARY KEY)"))
        #expect(db.run("INSERT INTO t VALUES(?)", ["a"]))
        #expect(!db.run("INSERT INTO t VALUES(?)", ["a"]), "a broken constraint")
        #expect(db.lastError.contains("UNIQUE"))
        #expect(!db.run("INSERT INTO nowhere VALUES(1)"), "doesn't compile")
        #expect(db.query("SELECT * FROM nowhere").isEmpty)
        #expect(!db.exec("NOT SQL"))
        // The kept statement that failed goes on working.
        #expect(db.run("INSERT INTO t VALUES(?)", ["b"]))
        #expect(db.changes == 1)
    }

    @Test func keptStatementsHoldNoReadOpen() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
        let writer = try #require(SQLiteConnection(path: file.path))
        #expect(writer.exec("PRAGMA journal_mode=WAL; CREATE TABLE t(n INTEGER)"))
        let reader = try #require(SQLiteConnection(path: file.path, flags: SQLITE_OPEN_READONLY))
        #expect(writer.run("INSERT INTO t VALUES(1)"))
        #expect(reader.int("SELECT count(*) FROM t") == 1)
        // A row left unread in a kept statement must not pin the reader's snapshot.
        _ = reader.query("SELECT n FROM t LIMIT 1")
        #expect(sqlite3_get_autocommit(reader.handle) != 0)
        #expect(writer.run("INSERT INTO t VALUES(2)"))
        #expect(reader.int("SELECT count(*) FROM t") == 2, "the kept statement sees the new commit")
        // And the writer can fold the whole log in: no reader holds a snapshot.
        let folded = writer.query("PRAGMA wal_checkpoint(TRUNCATE)").first
        #expect(folded?.int64(0) == 0, "not busy")
    }

    @Test func moreStatementsThanAreKeptStillRun() throws {
        let db = try #require(SQLiteConnection(path: nil))
        #expect(db.exec("CREATE TABLE t(n INTEGER)"))
        for n in 0..<(SQLiteConnection.keptMost * 2) {
            #expect(db.run("INSERT INTO t VALUES(\(n))"))
        }
        // The first ones again, compiled again after being let go.
        for n in 0..<4 { #expect(db.int("SELECT n FROM t WHERE n = \(n)") == Int64(n)) }
        #expect(db.int("SELECT count(*) FROM t") == Int64(SQLiteConnection.keptMost * 2))
    }

    @Test func aStatementOfItsOwnIsTheCallers() throws {
        let db = try #require(SQLiteConnection(path: nil))
        #expect(db.exec("CREATE TABLE t(n INTEGER); INSERT INTO t VALUES(1), (2), (3)"))
        let statement = try #require(db.prepare("SELECT n FROM t WHERE n >= ? ORDER BY n", [2]))
        var seen: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW { seen.append(sqlite3_column_int64(statement, 0)) }
        sqlite3_finalize(statement)
        #expect(seen == [2, 3])
        #expect(db.prepare("SELECT FROM") == nil)
    }
}
