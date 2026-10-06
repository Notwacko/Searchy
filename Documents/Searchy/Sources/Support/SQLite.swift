import Foundation
import SQLite3

nonisolated enum SQLValue: Sendable {
    case int(Int64), double(Double), text(String), blob(Data), null
}

nonisolated struct SQLError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

nonisolated struct SQLRow {
    fileprivate let stmt: OpaquePointer
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func text(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
    func data(_ i: Int32) -> Data {
        guard let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
}

/// Thin wrapper over the system SQLite. Not thread-safe by itself — own it from one queue.
nonisolated final class SQLiteDatabase: @unchecked Sendable {
    private var db: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLError(message: msg)
        }
        sqlite3_busy_timeout(db, 2000)
    }

    deinit { sqlite3_close(db) }

    func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        try run(sql, params) { _ in }
    }

    func query(_ sql: String, _ params: [SQLValue] = [], row: (SQLRow) -> Void) throws {
        try run(sql, params, row)
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN")
        do { try body(); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error }
    }

    private func run(_ sql: String, _ params: [SQLValue], _ row: (SQLRow) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), transient) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(SQLRow(stmt: stmt)) }
            else if rc == SQLITE_DONE { break }
            else { throw SQLError(message: String(cString: sqlite3_errmsg(db))) }
        }
    }
}
