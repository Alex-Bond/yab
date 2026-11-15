import Foundation
import SQLite3
import Testing
import YabStore

/// Independent storage/read oracles: a symmetric truncation must not pass
/// as a successful round trip. Every connection is a private in-memory DB.
struct SQLiteTextRetentionTests {
    private func hex(_ text: String) -> String {
        text.utf8.map { String(format: "%02X", $0) }.joined()
    }

    @Test(arguments: ["left\u{0}right", "\u{0}leading", "trailing\u{0}", "a\u{0}b\u{0}c", "привет\u{0}世界", "", "ordinary"])
    func bindingStoresEveryUTF8Byte(_ text: String) throws {
        let db = try #require(SQLiteConnection(path: nil))
        #expect(db.exec("CREATE TABLE t(value TEXT)"))
        #expect(db.run("INSERT INTO t(value) VALUES(?)", [text]))
        // Hex has no NUL of its own, so this checks binding independently
        // of the connection's potentially incorrect TEXT reader.
        #expect(db.string("SELECT hex(CAST(value AS BLOB)) FROM t") == hex(text))
        #expect(db.string("SELECT typeof(value) FROM t") == "text")
    }

    @Test func readingStoredTextDoesNotStopAtNUL() throws {
        let db = try #require(SQLiteConnection(path: nil))
        #expect(db.exec("""
            CREATE TABLE t(value TEXT);
            INSERT INTO t VALUES(CAST(X'6C656674007269676874' AS TEXT));
            """))
        // SQL inserts literal bytes, bypassing the Swift String binder.
        let expected = "left\u{0}right"
        #expect(db.string("SELECT value FROM t") == expected)
        #expect(db.strings("SELECT value FROM t") == [expected])
        let row = try #require(db.query("SELECT value FROM t").first)
        #expect(row.string("value") == expected)
        #expect(row.string(0) == expected)
    }

    @Test func callerOwnedPreparedStatementUsesTheFullValue() throws {
        let db = try #require(SQLiteConnection(path: nil))
        let text = "é\u{0}猫\u{0}end"
        let statement = try #require(db.prepare("SELECT hex(CAST(? AS BLOB))", [text]))
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        let actual = try #require(sqlite3_column_text(statement, 0))
        #expect(String(cString: actual) == hex(text))
    }

    @Test func reusedStatementsKeepEmptyAndNullValuesDistinct() throws {
        let db = try #require(SQLiteConnection(path: nil))
        #expect(db.exec("CREATE TABLE t(value TEXT)"))
        let values = ["long\u{0}tail\u{0}after", "x", "", "\u{0}", "終\u{0}é"]
        for text in values {
            #expect(db.run("DELETE FROM t"))
            #expect(db.run("INSERT INTO t(value) VALUES(?)", [text]))
            #expect(db.string("SELECT value FROM t") == text)
            #expect(db.string("SELECT hex(CAST(value AS BLOB)) FROM t") == hex(text))
        }
        #expect(db.run("DELETE FROM t"))
        #expect(db.run("INSERT INTO t(value) VALUES(?)", [NSNull()]))
        #expect(db.string("SELECT value FROM t") == nil)
        #expect(db.string("SELECT typeof(value) FROM t") == "null")
    }

    @Test func emptyNullAndInvalidUTF8StorageKeepTheirExistingMeaning() throws {
        let db = try #require(SQLiteConnection(path: nil))
        #expect(db.string("SELECT CAST(X'' AS TEXT)") == "")
        #expect(db.string("SELECT NULL") == nil)
        // Swift's UTF-8 decoding still replaces invalid byte sequences.
        #expect(db.string("SELECT CAST(X'FF' AS TEXT)") == "\u{FFFD}")
    }
}
