//
//  GrowthStore.swift
//  DrsMainApp
//
//  Created by yunastic on 11/1/25.
//
import Foundation
import SQLite3
import OSLog

struct GrowthPoint: Identifiable, Equatable {
    let id: Int
    let patientID: Int
    let episodeID: Int?
    let recordedAtISO: String      // keep raw ISO string; parse in UI as needed
    let weightKg: Double?
    let heightCm: Double?
    let headCircumferenceCm: Double?
    let source: String             // "manual" | "vitals" | "birth" | "discharge" | ...
}

enum GrowthStoreError: Error, LocalizedError {
    case noDB
    case openFailed

    // Validation
    case invalidRecordedAt
    case missingMeasurements

    // DB operations (keep raw SQLite error for logs/debug only)
    case queryFailed(String)
    case insertFailed(String)
    case deleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDB:
            // Not currently used as a user-facing error, but keep a safe fallback.
            return NSLocalizedString(
                "growth_store.error.query_failed",
                comment: "Generic DB failure shown to the user"
            )
        case .openFailed:
            return NSLocalizedString(
                "growth_store.error.open_failed",
                comment: "Could not open the database"
            )
        case .invalidRecordedAt:
            return NSLocalizedString(
                "growth_store.error.invalid_recorded_at",
                comment: "Validation: recordedAtISO cannot be empty"
            )
        case .missingMeasurements:
            return NSLocalizedString(
                "growth_store.error.missing_measurements",
                comment: "Validation: at least one measurement must be provided"
            )
        case .queryFailed:
            return NSLocalizedString(
                "growth_store.error.query_failed",
                comment: "Database query failed"
            )
        case .insertFailed:
            return NSLocalizedString(
                "growth_store.error.insert_failed",
                comment: "Could not save growth data"
            )
        case .deleteFailed:
            return NSLocalizedString(
                "growth_store.error.delete_failed",
                comment: "Could not delete growth data"
            )
        }
    }
}

final class GrowthStore {
    private let log = Logger(subsystem: "com.pediai.DrsMainApp", category: "GrowthStore")

    /// Read unified growth rows for a patient from `growth_unified`, newest first.
    func fetchPatientGrowth(dbURL: URL, patientID: Int) throws -> [GrowthPoint] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw GrowthStoreError.openFailed
        }
        defer { sqlite3_close(db) }

        // Ensure the view exists (defensive; no-op if already present)
        // If you prefer, you can call AppState.ensureGrowthUnificationSchema earlier instead.
        // This is intentionally not called here to avoid cross-dependency.

        let sql = """
        SELECT
          id,
          patient_id,
          episode_id,
          recorded_at,
          weight_kg,
          height_cm,
          head_circumference_cm,
          source
        FROM growth_unified
        WHERE patient_id = ?
        ORDER BY recorded_at DESC;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw GrowthStoreError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))

        var rows: [GrowthPoint] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            let pid = Int(sqlite3_column_int64(stmt, 1))
            let eid: Int? = (sqlite3_column_type(stmt, 2) == SQLITE_NULL) ? nil : Int(sqlite3_column_int64(stmt, 2))

            func txt(_ i: Int32) -> String? {
                guard let c = sqlite3_column_text(stmt, i) else { return nil }
                let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? nil : s
            }
            func dbl(_ i: Int32) -> Double? {
                sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
            }

            let recorded = txt(3) ?? ""
            let w = dbl(4)
            let h = dbl(5)
            let hc = dbl(6)
            let src = txt(7) ?? ""

            rows.append(GrowthPoint(
                id: id,
                patientID: pid,
                episodeID: eid,
                recordedAtISO: recorded,
                weightKg: w,
                heightCm: h,
                headCircumferenceCm: hc,
                source: src
            ))
        }
        return rows
    }

    /// Insert a manual historical growth point into `manual_growth`.
    /// Returns the newly inserted row id.
    /// - Note: Keep using ISO8601 for `recordedAtISO`, e.g. "2025-01-31T10:22:00Z"
    func addManualGrowth(
        dbURL: URL,
        patientID: Int,
        recordedAtISO: String,
        weightKg: Double?,
        heightCm: Double?,
        headCircumferenceCm: Double?,
        episodeID: Int? = nil
    ) throws -> Int {
        // Ignore episodeID for manual entries; schema has no episode_id column.
        _ = episodeID

        // Basic validation
        guard !recordedAtISO.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GrowthStoreError.invalidRecordedAt
        }
        guard weightKg != nil || heightCm != nil || headCircumferenceCm != nil else {
            throw GrowthStoreError.missingMeasurements
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw GrowthStoreError.openFailed
        }
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO manual_growth
          (patient_id, recorded_at, weight_kg, height_cm, head_circumference_cm, source)
        VALUES (?, ?, ?, ?, ?, 'manual');
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw GrowthStoreError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        // Bind params
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))

        // recordedAtISO as TEXT (use SQLITE_TRANSIENT so SQLite copies the buffer)
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        recordedAtISO.withCString { cstr in
            sqlite3_bind_text(stmt, 2, cstr, -1, SQLITE_TRANSIENT)
        }

        if let w = weightKg {
            sqlite3_bind_double(stmt, 3, w)
        } else {
            sqlite3_bind_null(stmt, 3)
        }

        if let h = heightCm {
            sqlite3_bind_double(stmt, 4, h)
        } else {
            sqlite3_bind_null(stmt, 4)
        }

        if let hc = headCircumferenceCm {
            sqlite3_bind_double(stmt, 5, hc)
        } else {
            sqlite3_bind_null(stmt, 5)
        }


        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            throw GrowthStoreError.insertFailed(msg)
        }

        let newID = Int(sqlite3_last_insert_rowid(db))
        log.info("Inserted manual_growth row \(newID, privacy: .public) for patient \(patientID, privacy: .public)")
        return newID
    }

    /// Delete a manual growth point by its primary key in `manual_growth`.
    /// Call this only for rows where `source == "manual"`.
    func deleteManualGrowth(dbURL: URL, id: Int) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw GrowthStoreError.openFailed
        }
        defer { sqlite3_close(db) }

        let sql = "DELETE FROM manual_growth WHERE id = ?;"

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw GrowthStoreError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sqlite3_int64(id))

        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            throw GrowthStoreError.deleteFailed(msg)
        }

        log.info("Deleted manual_growth row \(id, privacy: .public)")
    }
}
