import Foundation
import OSLog
import SQLite3

// One SQLite connection, as the stores here use it (MailStore, MailMemory,
// Diary): opened with a busy timeout, statements bound from Swift values,
// rows read by place or by column name, and the statements asked again and
// again kept compiled. Not safe to share between threads: the store that
// owns one calls it from its own serial queue only.

public final class SQLiteConnection: @unchecked Sendable {
    public let handle: OpaquePointer
    /// What a failed statement is called in the log ("mail store"); with no
    /// log, a failure is only answered (false, no rows).
    private let name: String
    private let log: Logger?

    /// Compiled statements by their SQL, the least lately used let go first.
    /// A statement is reset after each use, so none holds a read open.
    private var kept: [String: (statement: OpaquePointer, used: UInt64)] = [:]
    private var tick: UInt64 = 0
    static let keptMost = 64

    public static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `path` nil or ":memory:" for a database in memory.
    public init?(path: String?, flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, busyTimeout: Int32 = 5000,
          name: String = "sqlite", log: Logger? = nil) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path ?? ":memory:", &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        handle = db
        self.name = name
        self.log = log
        if busyTimeout > 0 { sqlite3_busy_timeout(db, busyTimeout) }
    }

    deinit {
        for (_, one) in kept { sqlite3_finalize(one.statement) }
        sqlite3_close_v2(handle)
    }

    public var lastError: String { String(cString: sqlite3_errmsg(handle)) }
    public var changes: Int { Int(sqlite3_changes(handle)) }
    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// A statement that failed: said in the log, never silently.
    public func failed(_ sql: String) {
        guard let log else { return }
        let head = sql.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)
        log.error("\(self.name, privacy: .public): \(head, privacy: .public)… failed: \(self.lastError, privacy: .public)")
    }

    /// SQL as it is, one statement or many, nothing bound: true when all of
    /// it went. Not logged; the caller says what a failure means.
    @discardableResult
    public func exec(_ sql: String) -> Bool {
        sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }

    /// A statement of its own, bound, for a caller that steps it itself and
    /// finalizes it. Logged when it doesn't compile.
    public func prepare(_ sql: String, _ args: [Any] = []) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            failed(sql)
            sqlite3_finalize(statement)
            return nil
        }
        SQLiteConnection.bind(statement, args)
        return statement
    }

    /// Values bound in order: text, whole numbers (Int, Int64, Int32, Bool as
    /// 0 or 1), Double and Float, Data as a blob; anything else, nil
    /// included, as NULL.
    public static func bind(_ statement: OpaquePointer, _ args: [Any]) {
        for (index, arg) in args.enumerated() {
            let at = Int32(index + 1)
            switch arg {
            case let value as String:
                // A negative length stops at an embedded NUL. Keep every
                // UTF-8 byte, including what follows it, until SQLite copies it.
                value.withCString { bytes in
                    _ = sqlite3_bind_text64(statement, at, bytes, UInt64(value.utf8.count), transient, UInt8(SQLITE_UTF8))
                }
            case let value as Int64: sqlite3_bind_int64(statement, at, value)
            case let value as Int: sqlite3_bind_int64(statement, at, Int64(value))
            case let value as Int32: sqlite3_bind_int64(statement, at, Int64(value))
            case let value as Bool: sqlite3_bind_int64(statement, at, value ? 1 : 0)
            case let value as Double: sqlite3_bind_double(statement, at, value)
            case let value as Swift.Float: sqlite3_bind_double(statement, at, Double(value))
            case let value as Data:
                _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, at, $0.baseAddress, Int32(value.count), transient) }
            default: sqlite3_bind_null(statement, at)
            }
        }
    }

    /// A kept statement for this SQL, compiled the first time, bound.
    private func reused(_ sql: String, _ args: [Any]) -> OpaquePointer? {
        tick += 1
        if let one = kept[sql] {
            kept[sql] = (one.statement, tick)
            SQLiteConnection.bind(one.statement, args)
            return one.statement
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            failed(sql)
            sqlite3_finalize(statement)
            return nil
        }
        if kept.count >= SQLiteConnection.keptMost, let oldest = kept.min(by: { $0.value.used < $1.value.used }) {
            sqlite3_finalize(oldest.value.statement)
            kept[oldest.key] = nil
        }
        kept[sql] = (statement, tick)
        SQLiteConnection.bind(statement, args)
        return statement
    }

    /// A kept statement back for its next use: no read left open, nothing
    /// bound held.
    private func done(_ statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    /// One statement run through: true when it went, logged when not.
    @discardableResult
    public func run(_ sql: String, _ args: [Any] = []) -> Bool {
        guard let statement = reused(sql, args) else { return false }
        defer { done(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE || step == SQLITE_ROW else { failed(sql); return false }
        return true
    }

    /// Every row a statement gives.
    public func query(_ sql: String, _ args: [Any] = []) -> [SQLiteRow] {
        guard let statement = reused(sql, args) else { return [] }
        defer { done(statement) }
        let count = sqlite3_column_count(statement)
        let columns = SQLiteRow.Columns(statement, count: count)
        var rows: [SQLiteRow] = []
        while true {
            let step = sqlite3_step(statement)
            guard step == SQLITE_ROW else {
                if step != SQLITE_DONE { failed(sql) }
                break
            }
            var values: [Any?] = []
            values.reserveCapacity(Int(count))
            for column in 0..<count { values.append(SQLiteConnection.value(statement, column)) }
            rows.append(SQLiteRow(values: values, columns: columns))
        }
        return rows
    }

    /// A column of the current row as Swift has it: Int64, Double, String,
    /// Data, or nil.
    public static func value(_ statement: OpaquePointer, _ column: Int32) -> Any? {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: return sqlite3_column_int64(statement, column)
        case SQLITE_FLOAT: return sqlite3_column_double(statement, column)
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, column) else { return nil }
            let length = Int(sqlite3_column_bytes(statement, column))
            return String(decoding: UnsafeBufferPointer(start: text, count: length), as: UTF8.self)
        case SQLITE_BLOB:
            let length = Int(sqlite3_column_bytes(statement, column))
            guard length > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: length)
        default: return nil
        }
    }

    public func string(_ sql: String, _ args: [Any] = []) -> String? { query(sql, args).first?.first as? String }
    public func int(_ sql: String, _ args: [Any] = []) -> Int64? { query(sql, args).first?.first as? Int64 }
    public func double(_ sql: String, _ args: [Any] = []) -> Double? { query(sql, args).first?.double(0) }
    public func strings(_ sql: String, _ args: [Any] = []) -> [String] { query(sql, args).compactMap { $0.first as? String } }
}

/// A row's values in the statement's order, also found by column name (the
/// name SQLite gives it: a column's own, or what AS calls it).
public struct SQLiteRow: RandomAccessCollection {
    public let values: [Any?]
    public let columns: Columns

    /// One statement's column names, shared by all its rows.
    public final class Columns: @unchecked Sendable {
        public let names: [String]
        public let at: [String: Int]

        init(_ statement: OpaquePointer, count: Int32) {
            names = (0..<count).map { sqlite3_column_name(statement, $0).map { String(cString: $0) } ?? "" }
            var at: [String: Int] = [:]
            // The first of two with one name is the one found.
            for (index, name) in names.enumerated() where at[name] == nil { at[name] = index }
            self.at = at
        }

        init(_ names: [String]) {
            self.names = names
            var at: [String: Int] = [:]
            for (index, name) in names.enumerated() where at[name] == nil { at[name] = index }
            self.at = at
        }
    }

    public var startIndex: Int { values.startIndex }
    public var endIndex: Int { values.endIndex }
    public subscript(position: Int) -> Any? { values[position] }

    /// A column by name. A name the statement hasn't is a mistake in the
    /// caller's SQL: caught in a debug build, nil in a shipped one.
    public subscript(name: String) -> Any? {
        guard let index = columns.at[name] else {
            assertionFailure("no column \(name) in \(columns.names)")
            return nil
        }
        return values[index]
    }

    public func string(_ name: String) -> String? { self[name] as? String }
    public func int64(_ name: String) -> Int64? { self[name] as? Int64 }
    public func int(_ name: String) -> Int? { int64(name).map(Int.init) }
    /// A whole number reads as a Double too: SQLite keeps 3.0 as 3 at times.
    public func double(_ name: String) -> Double? { SQLiteRow.number(self[name]) }
    /// Nonzero is true.
    public func bool(_ name: String) -> Bool? { int64(name).map { $0 != 0 } }
    public func data(_ name: String) -> Data? { self[name] as? Data }

    public func string(_ index: Int) -> String? { values[index] as? String }
    public func int64(_ index: Int) -> Int64? { values[index] as? Int64 }
    public func double(_ index: Int) -> Double? { SQLiteRow.number(values[index]) }

    private static func number(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? Int64).map(Double.init)
    }
}
