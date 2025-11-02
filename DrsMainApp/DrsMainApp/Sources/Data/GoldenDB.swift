//
//  GoldenDB.swift
//  DrsMainApp
//
//  Created by yunastic on 11/2/25.
//
import Foundation
import SQLite3

enum GoldenDB {
    /// Copies golden.db into `bundleURL/db.sqlite` if missing. Also runs schema.sql to (re)apply views/triggers.
    static func ensureBundleDB(at bundleURL: URL) throws {
        let fm = FileManager.default
        let dbURL = bundleURL.appendingPathComponent("db.sqlite", isDirectory: false)

        if !fm.fileExists(atPath: dbURL.path) {
            guard let goldenURL = Bundle.main.url(forResource: "golden", withExtension: "db", subdirectory: "Resources/DB")
               ?? Bundle.main.url(forResource: "golden", withExtension: "db") else {
                throw NSError(domain: "GoldenDB", code: 1, userInfo: [NSLocalizedDescriptionKey: "golden.db not found in app bundle"])
            }
            try fm.copyItem(at: goldenURL, to: dbURL)
        }

        // Re-apply schema.sql (idempotent) to ensure views/triggers stay current.
        if let schemaURL = Bundle.main.url(forResource: "schema", withExtension: "sql") {
            try applySQL(from: schemaURL, into: dbURL)
        }
    }

    private static func applySQL(from schemaURL: URL, into dbURL: URL) throws {
        let sql = try String(contentsOf: schemaURL, encoding: .utf8)
        try SQLiteExec.exec(sql: """
            PRAGMA foreign_keys=ON;
            \(sql)
            """, dbPath: dbURL.path)
    }
}

/// Minimal exec utility (no external deps)
enum SQLiteExec {
    static func exec(sql: String, dbPath: String) throws {
        var db: OpaquePointer?
        let rcOpen = sqlite3_open(dbPath, &db)
        guard rcOpen == SQLITE_OK, let db = db else {
            throw NSError(domain: "SQLiteExec", code: 2, userInfo: [NSLocalizedDescriptionKey: "open failed (\(rcOpen))"])
        }
        defer { sqlite3_close(db) }

        var errMsg: UnsafeMutablePointer<Int8>? = nil
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.flatMap { String(cString: $0) } ?? "unknown"
            if errMsg != nil { sqlite3_free(errMsg) }
            throw NSError(domain: "SQLiteExec", code: 3, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}
