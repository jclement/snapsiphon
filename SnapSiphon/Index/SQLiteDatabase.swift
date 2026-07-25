import Foundation
import SQLite3

/// A minimal, synchronous SQLite wrapper over the system `libsqlite3`. Just
/// enough to back the index — prepared statements, binds, and row iteration —
/// without pulling in a full ORM. All access is funnelled through a serial
/// queue by `BackupIndex`, so this type itself stays single-threaded.
final class SQLiteDatabase {
    private var db: OpaquePointer?
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// Sticky by design: once SQLite has rejected an index operation, callers
    /// must stop committing repository metadata until the index is reopened or
    /// rebuilt. Continuing with a partially-updated cache is less safe than
    /// stopping the backup.
    private(set) var lastError: DBError?

    enum DBError: Error, LocalizedError {
        case open(String)
        case prepare(String)
        case step(String)
        var errorDescription: String? {
            switch self {
            case .open(let m): return "Could not open index database: \(m)"
            case .prepare(let m): return "Index query failed to prepare: \(m)"
            case .step(let m): return "Index query failed: \(m)"
            }
        }
    }

    init(path: String) throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DBError.open(msg)
        }
        exec("PRAGMA journal_mode = WAL;")
        exec("PRAGMA synchronous = NORMAL;")
    }

    deinit { if db != nil { sqlite3_close(db) } }

    /// Run a statement with no result rows (DDL, INSERT, UPDATE, DELETE).
    func exec(_ sql: String, _ params: [SQLiteValue] = []) {
        do {
            let stmt = try prepare(sql, params)
            defer { sqlite3_finalize(stmt) }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                throw DBError.step(String(cString: sqlite3_errmsg(db)))
            }
            return
        } catch let error as DBError {
            lastError = error
        } catch {
            lastError = .step(error.localizedDescription)
        }
    }

    /// Like exec, but surfaces failures (used for VACUUM INTO snapshots where
    /// silent failure would mean an empty checkpoint).
    func execThrowing(_ sql: String, _ params: [SQLiteValue] = []) throws {
        do {
            let stmt = try prepare(sql, params)
            defer { sqlite3_finalize(stmt) }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                throw DBError.step(String(cString: sqlite3_errmsg(db)))
            }
        } catch let error as DBError {
            lastError = error
            throw error
        }
    }

    /// A successful, explicit index rebuild is the one operation allowed to
    /// recover this connection from a sticky error. Callers must only use this
    /// after every statement in the rebuild has completed successfully.
    func clearErrorAfterSuccessfulReset() {
        lastError = nil
    }

    /// Run a query and map each row.
    func query<T>(_ sql: String, _ params: [SQLiteValue] = [], _ map: (Row) -> T) throws -> [T] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [T] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            rows.append(map(Row(stmt: stmt)))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else {
            let error = DBError.step(String(cString: sqlite3_errmsg(db)))
            lastError = error
            throw error
        }
        return rows
    }

    /// Single scalar helper (e.g. COUNT/SUM).
    func scalarInt(_ sql: String, _ params: [SQLiteValue] = []) -> Int64 {
        do {
            return try query(sql, params) { $0.int64(0) }.first ?? 0
        } catch let error as DBError {
            lastError = error
            return 0
        } catch {
            lastError = .step(error.localizedDescription)
            return 0
        }
    }

    private func prepare(_ sql: String, _ params: [SQLiteValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let error = DBError.prepare(String(cString: sqlite3_errmsg(db)))
            lastError = error
            throw error
        }
        for (i, value) in params.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, Self.SQLITE_TRANSIENT)
            }
            guard rc == SQLITE_OK else {
                sqlite3_finalize(stmt)
                let error = DBError.prepare(String(cString: sqlite3_errmsg(db)))
                lastError = error
                throw error
            }
        }
        return stmt
    }

    // MARK: Value + Row

    enum SQLiteValue {
        case null
        case int(Int64)
        case double(Double)
        case text(String)
    }

    struct Row {
        let stmt: OpaquePointer
        func int64(_ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }
        func int(_ col: Int32) -> Int { Int(sqlite3_column_int64(stmt, col)) }
        func double(_ col: Int32) -> Double { sqlite3_column_double(stmt, col) }
        func text(_ col: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, col) else { return "" }
            return String(cString: c)
        }
        func textOrNil(_ col: Int32) -> String? {
            guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
                  let c = sqlite3_column_text(stmt, col) else { return nil }
            return String(cString: c)
        }
        func dateOrNil(_ col: Int32) -> Date? {
            guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, col))
        }
    }
}

extension SQLiteDatabase.SQLiteValue {
    static func date(_ d: Date?) -> Self {
        guard let d else { return .null }
        return .double(d.timeIntervalSince1970)
    }
    static func optText(_ s: String?) -> Self {
        guard let s else { return .null }
        return .text(s)
    }
}
