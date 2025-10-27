//
//  SQLiteBridge.swift
//  PediaShared
//
//  Created by yunastic on 10/26/25.
//
import Foundation
import SQLite3

public enum SQLiteError: Error, CustomStringConvertible {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case finalizeFailed(String)

    public var description: String {
        switch self {
        case .openFailed(let s): return "SQLite open failed: \(s)"
        case .execFailed(let s): return "SQLite exec failed: \(s)"
        case .prepareFailed(let s): return "SQLite prepare failed: \(s)"
        case .stepFailed(let s): return "SQLite step failed: \(s)"
        case .finalizeFailed(let s): return "SQLite finalize failed: \(s)"
        }
    }
}

/// Very small, synchronous wrapper suitable for read-mostly usage.
public final class SQLiteDB {
    public let path: String
    private var handle: OpaquePointer?

    public init(path: String, readonly: Bool = true) throws {
        self.path = path
        let flags: Int32 = readonly
            ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = String(cString: sqlite3_errmsg(db) ?? UnsafePointer<Int8>(bitPattern: 0)!)
            sqlite3_close(db)
            throw SQLiteError.openFailed("\(msg) [\(rc)] at \(path)")
        }
        self.handle = db
        _ = try? exec("PRAGMA foreign_keys = ON;")
        _ = try? exec("PRAGMA journal_mode = WAL;")
    }

    deinit {
        if let db = handle { sqlite3_close(db) }
        handle = nil
    }

    @discardableResult
    public func exec(_ sql: String) throws -> Bool {
        guard let db = handle else { throw SQLiteError.execFailed("DB is closed") }
        var errmsg: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            let msg: String
            if let e = errmsg {
                msg = String(cString: e)
                sqlite3_free(e)
            } else if let c = sqlite3_errmsg(db) {
                msg = String(cString: c)
            } else {
                msg = "Unknown SQLite error"
            }
            throw SQLiteError.execFailed("\(msg) [\(rc)] for SQL: \(sql)")
        }
        return true
    }

    /// Back-compat alias so older call sites using `execute` keep working.
    @discardableResult
    public func execute(_ sql: String) throws -> Bool {
        try exec(sql)
    }

    /// Very simple query helper with no bind parameters (sufficient for our immediate use).
    public func queryRows(sql: String) throws -> [[String: Any]] {
        guard let db = handle else { throw SQLiteError.prepareFailed("DB is closed") }
        var stmt: OpaquePointer?
        var rows: [[String: Any]] = []

        // prepare
        var rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db) ?? UnsafePointer<Int8>(bitPattern: 0)!)
            throw SQLiteError.prepareFailed("\(msg) [\(rc)] for SQL: \(sql)")
        }
        defer {
            let fin = sqlite3_finalize(stmt)
            if fin != SQLITE_OK {
                // We avoid throwing in defer; this is non-fatal.
                // In practice finalize errors are rare.
            }
        }

        let colCount = Int(sqlite3_column_count(stmt))
        var colNames: [String] = []
        colNames.reserveCapacity(colCount)
        for i in 0..<colCount {
            if let cName = sqlite3_column_name(stmt, Int32(i)) {
                colNames.append(String(cString: cName))
            } else {
                colNames.append("col\(i)")
            }
        }

        // step
        while true {
            rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                var dict: [String: Any] = [:]
                for i in 0..<colCount {
                    let type = sqlite3_column_type(stmt, Int32(i))
                    switch type {
                    case SQLITE_INTEGER:
                        dict[colNames[i]] = Int64(sqlite3_column_int64(stmt, Int32(i)))
                    case SQLITE_FLOAT:
                        dict[colNames[i]] = sqlite3_column_double(stmt, Int32(i))
                    case SQLITE_TEXT:
                        if let cStr = sqlite3_column_text(stmt, Int32(i)) {
                            dict[colNames[i]] = String(cString: cStr)
                        } else {
                            dict[colNames[i]] = ""
                        }
                    case SQLITE_BLOB:
                        if let bytes = sqlite3_column_blob(stmt, Int32(i)) {
                            let length = Int(sqlite3_column_bytes(stmt, Int32(i)))
                            dict[colNames[i]] = Data(bytes: bytes, count: length)
                        } else {
                            dict[colNames[i]] = Data()
                        }
                    case SQLITE_NULL:
                        dict[colNames[i]] = NSNull()
                    default:
                        dict[colNames[i]] = NSNull()
                    }
                }
                rows.append(dict)
            } else if rc == SQLITE_DONE {
                break
            } else {
                let msg = String(cString: sqlite3_errmsg(db) ?? UnsafePointer<Int8>(bitPattern: 0)!)
                throw SQLiteError.stepFailed("\(msg) [\(rc)] for SQL: \(sql)")
            }
        }
        return rows
    }

    public func tableExists(_ name: String) throws -> Bool {
        let safe = name.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name='\(safe)' LIMIT 1"
        let rows = try queryRows(sql: sql)
        return !rows.isEmpty
    }

    /// Explicit close for callers that want to deterministically release the handle.
    public func close() {
        if let db = handle {
            sqlite3_close(db)
            handle = nil
        }
    }
}
