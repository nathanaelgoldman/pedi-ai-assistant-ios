//
//  GrowthDataFetcher.swift
//  DrsMainApp
//
//  Created by yunastic on 11/1/25.
//
import Foundation
import SQLite3
import OSLog

public struct GrowthDataPoint {
    public let ageMonths: Double
    public let value: Double
}

public enum GrowthMeasure: String {
    case weight      = "weight_kg"
    case height      = "height_cm"
    case headCirc    = "head_circumference_cm"
}

enum GDFErr: Error { case openDB, dobMissing }

public enum GrowthDataFetcher {

    // MARK: - Logger
    private static let log = AppLog.feature("growth.fetcher")

    // MARK: - Date helpers
    private static let secondsPerDay: Double = 86_400.0
    private static let daysPerMonth: Double = 30.4375

    private static let iso8601FS: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static let fallbacks: [DateFormatter] = {
        let posix = Locale(identifier: "en_US_POSIX")
        let tz = TimeZone(secondsFromGMT: 0)
        let fmts = [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd",
            "yyyy-MM-dd HH:mm:ss.SSS"
        ]
        return fmts.map {
            let df = DateFormatter()
            df.locale = posix
            df.timeZone = tz
            df.dateFormat = $0
            return df
        }
    }()

    private static func parseDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = iso8601FS.date(from: t) { return d }
        for df in fallbacks { if let d = df.date(from: t) { return d } }
        return nil
    }

    // MARK: - Public API

    /// Fetches a single series for weight/height/head circumference.
    /// Reads from: `vitals` (value & recorded_at), `manual_growth` (value & recorded_at),
    /// and baseline from `perinatal_history` (birth/discharge as applicable).
    public static func fetchSeries(dbPath: String, patientID: Int64, measure: GrowthMeasure) -> [GrowthDataPoint] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            let safeDB = URL(fileURLWithPath: dbPath).lastPathComponent
            let msg = String(
                format: NSLocalizedString("growthdatafetcher.log.open_db_failed", comment: "GrowthDataFetcher log"),
                safeDB
            )
            log.error("\(msg, privacy: .public)")
            return []
        }
        defer { sqlite3_close(db) }

        // 1) DOB
        guard let dob = readDOB(db: db, patientID: patientID) else {
            let msg = NSLocalizedString(
                "growthdatafetcher.log.dob_missing",
                comment: "GrowthDataFetcher log"
            )
            log.error("\(msg, privacy: .public) patientID=\(patientID, privacy: .private(mask: .hash))")
            return []
        }

        var points: [GrowthDataPoint] = []

        // 2) vitals: patient_id, recorded_at, <measure.rawValue>
        appendFromVitals(db: db, pid: patientID, column: measure.rawValue, dob: dob, into: &points)

        // 3) manual_growth: patient_id, recorded_at, <measure.rawValue>
        appendFromManualGrowth(db: db, pid: patientID, column: measure.rawValue, dob: dob, into: &points)

        // 4) perinatal_history baselines (birth_* and discharge_weight_g)
        appendPerinatalBaselines(db: db, pid: patientID, measure: measure, into: &points)

        points.sort { $0.ageMonths < $1.ageMonths }
        return points
    }

    public static func fetchAll(dbPath: String, patientID: Int64) -> [GrowthMeasure: [GrowthDataPoint]] {
        var out: [GrowthMeasure: [GrowthDataPoint]] = [:]
        out[.weight]   = fetchSeries(dbPath: dbPath, patientID: patientID, measure: .weight)
        out[.height]   = fetchSeries(dbPath: dbPath, patientID: patientID, measure: .height)
        out[.headCirc] = fetchSeries(dbPath: dbPath, patientID: patientID, measure: .headCirc)
        return out
    }

    // MARK: - Internals

    private static func readDOB(db: OpaquePointer, patientID: Int64) -> Date? {
        let sql = "SELECT dob FROM patients WHERE id=? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, patientID)
        if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
            let s = String(cString: c)
            return parseDate(s)
        }
        return nil
    }

    private static func appendFromVitals(db: OpaquePointer, pid: Int64, column: String, dob: Date, into arr: inout [GrowthDataPoint]) {
        // recorded_at is TEXT, value can be REAL/NULL
        let sql = """
        SELECT recorded_at, \(column)
        FROM vitals
        WHERE patient_id = ? AND \(column) IS NOT NULL;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, pid)

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let cDate = sqlite3_column_text(stmt, 0),
                let when = parseDate(String(cString: cDate))
            else { continue }

            // value (col 1) may be REAL or INTEGER depending on schema; coerce as double if not NULL
            let t = sqlite3_column_type(stmt, 1)
            let value: Double? = (t == SQLITE_NULL) ? nil : sqlite3_column_double(stmt, 1)
            guard let v = value, v.isFinite, v > 0 else { continue }

            let ageM = when.timeIntervalSince(dob) / secondsPerDay / daysPerMonth
            guard ageM >= 0 else { continue }
            arr.append(GrowthDataPoint(ageMonths: ageM, value: v))
        }
    }

    private static func appendFromManualGrowth(db: OpaquePointer, pid: Int64, column: String, dob: Date, into arr: inout [GrowthDataPoint]) {
        let sql = """
        SELECT recorded_at, \(column)
        FROM manual_growth
        WHERE patient_id = ? AND \(column) IS NOT NULL;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, pid)

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let cDate = sqlite3_column_text(stmt, 0),
                let when = parseDate(String(cString: cDate))
            else { continue }

            let t = sqlite3_column_type(stmt, 1)
            let value: Double? = (t == SQLITE_NULL) ? nil : sqlite3_column_double(stmt, 1)
            guard let v = value, v.isFinite, v > 0 else { continue }

            let ageM = when.timeIntervalSince(dob) / secondsPerDay / daysPerMonth
            guard ageM >= 0 else { continue }
            arr.append(GrowthDataPoint(ageMonths: ageM, value: v))
        }
    }

    private static func appendPerinatalBaselines(db: OpaquePointer, pid: Int64, measure: GrowthMeasure, into arr: inout [GrowthDataPoint]) {
        let sql = """
        SELECT birth_weight_g, discharge_weight_g, birth_length_cm, birth_head_circumference_cm
        FROM perinatal_history
        WHERE patient_id = ?
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, pid)

        if sqlite3_step(stmt) == SQLITE_ROW {
            switch measure {
            case .weight:
                let bwG = sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 0)
                let dwG = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 1)
                if let g = bwG, g > 0 { arr.append(GrowthDataPoint(ageMonths: 0.0, value: Double(g) / 1000.0)) }
                if let g = dwG, g > 0 { arr.append(GrowthDataPoint(ageMonths: 0.07, value: Double(g) / 1000.0)) } // ~2 days
            case .height:
                let bl = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2)
                if let cm = bl, cm > 0 { arr.append(GrowthDataPoint(ageMonths: 0.0, value: cm)) }
            case .headCirc:
                let hc = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3)
                if let cm = hc, cm > 0 { arr.append(GrowthDataPoint(ageMonths: 0.0, value: cm)) }
            }
        }
    }
}
