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

enum GrowthStoreError: Error {
    case noDB
    case openFailed
    case prepareFailed(String)
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
            throw GrowthStoreError.prepareFailed(msg)
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
}
