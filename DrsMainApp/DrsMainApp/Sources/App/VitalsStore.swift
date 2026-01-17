//
//  VitalsStore.swift
//  DrsMainApp
//
//  Created by yunastic on 11/15/25.
//
import Foundation
import SQLite3

// File-local SQLITE_TRANSIENT so sqlite makes a private copy of Swift strings.
fileprivate let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct VitalRow: Identifiable, Hashable {
    public let id: Int
    public let patientID: Int
    public let episodeID: Int
    public let weightKg: Double?
    public let heightCm: Double?
    public let headCircumferenceCm: Double?
    public let temperatureC: Double?
    public let heartRate: Int?
    public let respiratoryRate: Int?
    public let spo2: Int?
    public let bpSystolic: Int?
    public let bpDiastolic: Int?
    public let recordedAtISO: String
}

public enum VitalsStore {
    // MARK: - Schema

    /// Create table if missing; add BP columns if absent; add helpful index.
    public static func ensureVitalsSchema(dbURL: URL) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }

        // Table
        let createSQL = """
        CREATE TABLE IF NOT EXISTS vitals (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          patient_id INTEGER,
          episode_id INTEGER,
          weight_kg REAL,
          height_cm REAL,
          head_circumference_cm REAL,
          temperature_c REAL,
          heart_rate INTEGER,
          respiratory_rate INTEGER,
          spo2 INTEGER,
          recorded_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
        """
        _ = sqlite3_exec(db, createSQL, nil, nil, nil)

        // Add BP columns if missing (idempotent)
        let cols = columnSet(of: "vitals", db: db)
        if !cols.contains("bp_systolic") {
            _ = sqlite3_exec(db, "ALTER TABLE vitals ADD COLUMN bp_systolic INTEGER;", nil, nil, nil)
        }
        if !cols.contains("bp_diastolic") {
            _ = sqlite3_exec(db, "ALTER TABLE vitals ADD COLUMN bp_diastolic INTEGER;", nil, nil, nil)
        }

        // Helpful index for timeline queries
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_vitals_ep_time ON vitals(episode_id, recorded_at, id);", nil, nil, nil)
    }

    // MARK: - Writes

    /// Insert a new vitals row; returns row id (or 0 on failure).
    @discardableResult
    public static func insertVitals(
        dbURL: URL,
        patientID: Int,
        episodeID: Int,
        weightKg: Double?,
        heightCm: Double?,
        headCircumferenceCm: Double?,
        temperatureC: Double?,
        heartRate: Int?,
        respiratoryRate: Int?,
        spo2: Int?,
        bpSystolic: Int?,
        bpDiastolic: Int?,
        recordedAtISO: String? = nil
    ) -> Int64 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return 0 }
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO vitals (
            patient_id, episode_id,
            weight_kg, height_cm, head_circumference_cm,
            temperature_c, heart_rate, respiratory_rate, spo2,
            bp_systolic, bp_diastolic, recorded_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE(?, CURRENT_TIMESTAMP));
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }

        // 1-based binding
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))
        sqlite3_bind_int64(stmt, 2, sqlite3_int64(episodeID))

        bindDouble(stmt, 3, weightKg)
        bindDouble(stmt, 4, heightCm)
        bindDouble(stmt, 5, headCircumferenceCm)

        bindDouble(stmt, 6, temperatureC)
        bindInt(stmt,    7, heartRate)
        bindInt(stmt,    8, respiratoryRate)
        bindInt(stmt,    9, spo2)

        bindInt(stmt,   10, bpSystolic)
        bindInt(stmt,   11, bpDiastolic)

        if let s = recordedAtISO, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s.withCString { cstr in
                _ = sqlite3_bind_text(stmt, 12, cstr, -1, SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 12)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Reads

    /// All vitals for an episode, oldest → newest.
    public static func listVitals(dbURL: URL, episodeID: Int) -> [VitalRow] {
        var out: [VitalRow] = []

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return out }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id, patient_id, episode_id,
               weight_kg, height_cm, head_circumference_cm,
               temperature_c, heart_rate, respiratory_rate, spo2,
               bp_systolic, bp_diastolic,
               COALESCE(recorded_at, '')
        FROM vitals
        WHERE episode_id = ?
        ORDER BY datetime(COALESCE(recorded_at, '0001-01-01T00:00:00')) ASC, id ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return out }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sqlite3_int64(episodeID))

        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(rowFromStmt(stmt))
        }
        return out
    }

    /// Latest vitals for an episode (if any).
    public static func latestVitals(dbURL: URL, episodeID: Int) -> VitalRow? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id, patient_id, episode_id,
               weight_kg, height_cm, head_circumference_cm,
               temperature_c, heart_rate, respiratory_rate, spo2,
               bp_systolic, bp_diastolic,
               COALESCE(recorded_at, '')
        FROM vitals
        WHERE episode_id = ?
        ORDER BY datetime(COALESCE(recorded_at, '0001-01-01T00:00:00')) DESC, id DESC
        LIMIT 1;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sqlite3_int64(episodeID))

        if sqlite3_step(stmt) == SQLITE_ROW {
            return rowFromStmt(stmt)
        }
        return nil
    }

    // MARK: - Deletes

    @discardableResult
    public static func deleteVitalsRow(dbURL: URL, id: Int) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return false }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM vitals WHERE id=?;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sqlite3_int64(id))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Bulk-delete all vitals for an episode. Returns number of rows deleted.
    @discardableResult
    public static func deleteAllVitalsForEpisode(dbURL: URL, episodeID: Int) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return 0 }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM vitals WHERE episode_id=?;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sqlite3_int64(episodeID))
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(db))
    }

    // MARK: - Internals

    private static func columnSet(of table: String, db: OpaquePointer) -> Set<String> {
        var cols: Set<String> = []
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &s, nil) == SQLITE_OK {
            while sqlite3_step(s) == SQLITE_ROW {
                if let c = sqlite3_column_text(s, 1) {
                    cols.insert(String(cString: c))
                }
            }
        }
        return cols
    }

    private static func rowFromStmt(_ s: OpaquePointer) -> VitalRow {
        func i(_ idx: Int32) -> Int { Int(sqlite3_column_int64(s, idx)) }
        func io(_ idx: Int32) -> Int? { sqlite3_column_type(s, idx) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, idx)) }
        func d(_ idx: Int32) -> Double? { sqlite3_column_type(s, idx) == SQLITE_NULL ? nil : sqlite3_column_double(s, idx) }
        func t(_ idx: Int32) -> String { (sqlite3_column_text(s, idx).map { String(cString: $0) }) ?? "" }

        return VitalRow(
            id: i(0),
            patientID: i(1),
            episodeID: i(2),
            weightKg: d(3),
            heightCm: d(4),
            headCircumferenceCm: d(5),
            temperatureC: d(6),
            heartRate: io(7),
            respiratoryRate: io(8),
            spo2: io(9),
            bpSystolic: io(10),
            bpDiastolic: io(11),
            recordedAtISO: t(12)
        )
    }

    private static func bindInt(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int?) {
        if let v = value {
            sqlite3_bind_int64(stmt, idx, sqlite3_int64(v))
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }
    private static func bindDouble(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Double?) {
        if let v = value {
            sqlite3_bind_double(stmt, idx, v)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }
}
