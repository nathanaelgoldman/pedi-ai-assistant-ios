//
//  PmhStore.swift
//  DrsMainApp
//
//  Created by yunastic on 11/14/25.
//
import Foundation
import SQLite3
import OSLog

private let pmhLog = Logger(subsystem: "DrsMainApp", category: "PmhStore")

public struct PastMedicalHistory: Equatable {
    public var patientID: Int64
    public var asthma: Int?              // 0/1
    public var otitis: Int?              // 0/1
    public var uti: Int?                 // 0/1
    public var allergies: Int?           // 0/1
    public var allergyDetails: String?
    public var other: String?
    public var updatedAtISO: String?

    public init(
        patientID: Int64,
        asthma: Int? = nil,
        otitis: Int? = nil,
        uti: Int? = nil,
        allergies: Int? = nil,
        allergyDetails: String? = nil,
        other: String? = nil,
        updatedAtISO: String? = nil
    ) {
        self.patientID = patientID
        self.asthma = asthma
        self.otitis = otitis
        self.uti = uti
        self.allergies = allergies
        self.allergyDetails = allergyDetails
        self.other = other
        self.updatedAtISO = updatedAtISO
    }
}

public final class PmhStore {

    public init() {}

    // MARK: - Schema
    public func ensureSchema(dbURL: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db = db else {
            throw NSError(domain: "PmhStore", code: 100, userInfo: [NSLocalizedDescriptionKey: String(localized: "pmhstore.error.open_db", comment: "PmhStore: unable to open database")])
        }
        defer { sqlite3_close(db) }

        let sql = """
        CREATE TABLE IF NOT EXISTS past_medical_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          patient_id INTEGER,
          asthma INTEGER,
          otitis INTEGER,
          uti INTEGER,
          allergies INTEGER,
          other TEXT,
          allergy_details TEXT,
          updated_at TEXT,
          FOREIGN KEY (patient_id) REFERENCES patients(id)
        );
        """

        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "PmhStore", code: 101, userInfo: [NSLocalizedDescriptionKey: "\(String(localized: "pmhstore.error.schema", comment: "PmhStore: schema error")): \(msg)"])
        }
    }

    // MARK: - Fetch
    public func fetch(dbURL: URL, for patientID: Int64) throws -> PastMedicalHistory? {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db = db else {
            throw NSError(domain: "PmhStore", code: 200, userInfo: [NSLocalizedDescriptionKey: String(localized: "pmhstore.error.open_db", comment: "PmhStore: unable to open database")])
        }
        defer { sqlite3_close(db) }

        try ensureSchema(dbURL: dbURL)

        let sql = """
        SELECT asthma, otitis, uti, allergies, other, allergy_details, updated_at
        FROM past_medical_history
        WHERE patient_id = ?
        LIMIT 1;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "PmhStore", code: 201, userInfo: [NSLocalizedDescriptionKey: "\(String(localized: "pmhstore.error.prepare", comment: "PmhStore: prepare statement failed")): \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, patientID)

        if sqlite3_step(stmt) == SQLITE_ROW {
            let asthma = sqlite3_column_type(stmt, 0) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 0)) : nil
            let otitis = sqlite3_column_type(stmt, 1) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 1)) : nil
            let uti = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 2)) : nil
            let allergies = sqlite3_column_type(stmt, 3) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 3)) : nil

            let other = sqlite3_column_type(stmt, 4) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 4))
                : nil

            let allergyDetails = sqlite3_column_type(stmt, 5) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 5))
                : nil

            let updatedAt = sqlite3_column_type(stmt, 6) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 6))
                : nil

            return PastMedicalHistory(
                patientID: patientID,
                asthma: asthma,
                otitis: otitis,
                uti: uti,
                allergies: allergies,
                allergyDetails: allergyDetails,
                other: other,
                updatedAtISO: updatedAt
            )
        }
        return nil
    }

    // MARK: - Upsert (delete then insert)
    public func upsert(dbURL: URL, for patientID: Int64, history: PastMedicalHistory) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db = db else {
            throw NSError(domain: "PmhStore", code: 300, userInfo: [NSLocalizedDescriptionKey: String(localized: "pmhstore.error.open_db", comment: "PmhStore: unable to open database")])
        }
        defer { sqlite3_close(db) }

        try ensureSchema(dbURL: dbURL)

        // Begin transaction
        guard sqlite3_exec(db, "BEGIN;", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "PmhStore", code: 301, userInfo: [NSLocalizedDescriptionKey: "\(String(localized: "pmhstore.error.begin", comment: "PmhStore: begin transaction failed")): \(msg)"])
        }
        defer { _ = sqlite3_exec(db, "COMMIT;", nil, nil, nil) }

        // Delete existing
        do {
            let del = "DELETE FROM past_medical_history WHERE patient_id = ?;"
            var stmtDel: OpaquePointer?
            guard sqlite3_prepare_v2(db, del, -1, &stmtDel, nil) == SQLITE_OK, let stmtDel = stmtDel else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "PmhStore", code: 302, userInfo: [NSLocalizedDescriptionKey: "\(String(localized: "pmhstore.error.prepare_delete", comment: "PmhStore: prepare delete failed")): \(msg)"])
            }
            sqlite3_bind_int64(stmtDel, 1, patientID)
            if sqlite3_step(stmtDel) != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(db))
                sqlite3_finalize(stmtDel)
                throw NSError(domain: "PmhStore", code: 303, userInfo: [NSLocalizedDescriptionKey: "\(String(localized: "pmhstore.error.delete", comment: "PmhStore: delete failed")): \(msg)"])
            }
            sqlite3_finalize(stmtDel)
        }

        // Insert fresh
        do {
            let nowISO = ISO8601DateFormatter().string(from: Date())
            let ins = """
            INSERT INTO past_medical_history (
                patient_id, asthma, otitis, uti, allergies, other, allergy_details, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmtIns: OpaquePointer?
            guard sqlite3_prepare_v2(db, ins, -1, &stmtIns, nil) == SQLITE_OK, let stmtIns = stmtIns else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "PmhStore", code: 304, userInfo: [NSLocalizedDescriptionKey: "\(String(localized: "pmhstore.error.prepare_insert", comment: "PmhStore: prepare insert failed")): \(msg)"])
            }
            defer { sqlite3_finalize(stmtIns) }

            sqlite3_bind_int64(stmtIns, 1, patientID)
            if let v = history.asthma { sqlite3_bind_int(stmtIns, 2, Int32(v)) } else { sqlite3_bind_null(stmtIns, 2) }
            if let v = history.otitis { sqlite3_bind_int(stmtIns, 3, Int32(v)) } else { sqlite3_bind_null(stmtIns, 3) }
            if let v = history.uti { sqlite3_bind_int(stmtIns, 4, Int32(v)) } else { sqlite3_bind_null(stmtIns, 4) }
            if let v = history.allergies { sqlite3_bind_int(stmtIns, 5, Int32(v)) } else { sqlite3_bind_null(stmtIns, 5) }

            if let other = history.other {
                other.withCString { cstr in sqlite3_bind_text(stmtIns, 6, cstr, -1, SQLITE_TRANSIENT) }
            } else { sqlite3_bind_null(stmtIns, 6) }

            if let allergy = history.allergyDetails {
                allergy.withCString { cstr in sqlite3_bind_text(stmtIns, 7, cstr, -1, SQLITE_TRANSIENT) }
            } else { sqlite3_bind_null(stmtIns, 7) }

            nowISO.withCString { cstr in sqlite3_bind_text(stmtIns, 8, cstr, -1, SQLITE_TRANSIENT) }

            if sqlite3_step(stmtIns) != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "PmhStore", code: 305, userInfo: [NSLocalizedDescriptionKey: "\(String(localized: "pmhstore.error.insert", comment: "PmhStore: insert failed")): \(msg)"])
            }
        }
    }
}

// SQLite binding helper for text lifetimes
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
