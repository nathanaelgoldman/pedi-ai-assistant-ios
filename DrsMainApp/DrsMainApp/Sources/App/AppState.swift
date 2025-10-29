//
//  AppState.swift
//  DrsMainApp
//
//  Created by yunastic on 10/26/25.
//

//
//  AppState.swift
//  DrsMainApp
//
//  Created by yunastic on 10/26/25.
//

import Foundation
import SwiftUI
import OSLog
import SQLite3
import ZIPFoundation
import PediaShared

struct PatientRow: Identifiable, Equatable {
    let id: Int
    let alias: String
    let fullName: String
    let dobISO: String
    let sex: String
}


struct VisitRow: Identifiable, Equatable {
    let id: Int
    let dateISO: String
    let category: String
}

// Lightweight summaries for UI
struct PatientSummary {
    let vaccination: String?
    let pmh: String?
    let perinatal: String?
}

struct VisitSummary {
    let problems: String?
    let diagnosis: String?
    let conclusions: String?
}

// C macro for sqlite3 destructor that forces a copy during bind
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal patient profile for header/badge
struct PatientProfile: Equatable {
    var vaccinationStatus: String?
    var pmh: String?                 // cumulative past medical history
    var perinatalHistory: String?    // brief perinatal summary if available
}

@MainActor
final class AppState: ObservableObject {

    // MARK: - Published state
    @Published var selection: SidebarSelection? = .dashboard
    @Published var currentBundleURL: URL? = nil
    @Published var recentBundles: [URL] = []
    @Published var patients: [PatientRow] = []
    @Published var selectedPatientID: Int?
    @Published var visits: [VisitRow] = []
    @Published var bundleLocations: [URL] = []

    // Summaries populated on demand by views
    @Published var patientSummary: PatientSummary? = nil
    @Published var visitSummary: VisitSummary? = nil
    @Published var currentPatientProfile: PatientProfile? = nil

    private let profileLog = Logger(subsystem: "DrsMainApp", category: "PatientProfile")
    
    // The db.sqlite inside the currently selected bundle
    var currentDBURL: URL? {
        currentBundleURL?.appendingPathComponent("db.sqlite")
    }

    // Convenience for the right pane
    var selectedPatient: PatientRow? {
        guard let id = selectedPatientID else { return nil }
        return patients.first { $0.id == id }
    }
    
    // MARK: - Patient profile (badge) helpers

    /// Try to locate the SQLite DB inside the currently-selected bundle.
    /// We look for `<bundle>/db.sqlite`, then `<bundle>/db/db.sqlite`.
    private func dbURLForCurrentBundle() -> URL? {
        guard let root = currentBundleURL else { return nil }
        let c1 = root.appendingPathComponent("db.sqlite")
        if FileManager.default.fileExists(atPath: c1.path) { return c1 }
        let c2 = root.appendingPathComponent("db").appendingPathComponent("db.sqlite")
        if FileManager.default.fileExists(atPath: c2.path) { return c2 }
        return nil
    }

    /// Provide SQLITE_TRANSIENT for Swift bindings
    private var SQLITE_TRANSIENT: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    /// Return true if a table exists
    private func sqliteTableExists(db: OpaquePointer?, table: String) -> Bool {
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        table.withCString { c in
            sqlite3_bind_text(stmt, 1, c, -1, SQLITE_TRANSIENT)
        }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Run a scalar-text query with a single Int64 bind and return column 0 as String
    private func sqliteScalarText(db: OpaquePointer?, sql: String, bindID: Int64) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, bindID)
        if sqlite3_step(stmt) == SQLITE_ROW, let cStr = sqlite3_column_text(stmt, 0) {
            return String(cString: cStr)
        }
        return nil
    }
    
    // MARK: - Private
    private let recentsKey = "recentBundlePaths"
    private let log = Logger(subsystem: "com.pediai.DrsMainApp", category: "AppState")

    // MARK: - Init
    init() {
        loadRecentBundles()
    }
    
    /// Load vaccination status, cumulative PMH, and (optionally) perinatal summary for a patient.
    func loadPatientProfile(for patientID: Int64) {
        // clear while loading
        DispatchQueue.main.async { [weak self] in self?.currentPatientProfile = nil }

        guard let dbURL = dbURLForCurrentBundle() else {
            profileLog.debug("No db.sqlite found in current bundle")
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            profileLog.error("sqlite3_open failed for \(dbURL.path, privacy: .public)")
            return
        }
        defer { sqlite3_close(db) }

        // From patients table
        let vacc = sqliteScalarText(db: db,
                                    sql: "SELECT vaccination_status FROM patients WHERE id=? LIMIT 1;",
                                    bindID: patientID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let pmh  = sqliteScalarText(db: db,
                                    sql: "SELECT parent_notes FROM patients WHERE id=? LIMIT 1;",
                                    bindID: patientID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Optional perinatal summary (table may or may not exist)
        var peri: String? = nil
        if sqliteTableExists(db: db, table: "perinatal_history") {
            // Prefer a 'summary' column; fall back to 'notes' if summary missing
            peri = sqliteScalarText(db: db,
                                    sql: "SELECT summary FROM perinatal_history WHERE patient_id=? ORDER BY id DESC LIMIT 1;",
                                    bindID: patientID)
            ?? sqliteScalarText(db: db,
                                sql: "SELECT notes FROM perinatal_history WHERE patient_id=? ORDER BY id DESC LIMIT 1;",
                                bindID: patientID)
            peri = peri?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let profile = PatientProfile(vaccinationStatus: vacc, pmh: pmh, perinatalHistory: peri)
        DispatchQueue.main.async { [weak self] in
            self?.currentPatientProfile = profile
        }
    }

    // Allow UI to add one or more bundle directories **or .zip files**
    func addBundles(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        let fm = FileManager.default

        var addedSomething = false
        var zips: [URL] = []

        for url in urls {
            // Directory?
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                // Accept either an exact bundle root (has db.sqlite) or a parent folder that contains one
                if let root = findBundleRoot(startingAt: url) {
                    addBundleRootAndSelect(root)       // selects & loads patients
                    addedSomething = true
                } else {
                    log.warning("Folder does not contain a bundle (no db.sqlite): \(url.path, privacy: .public)")
                }
                continue
            }

            // ZIP?
            if url.pathExtension.lowercased() == "zip" {
                zips.append(url)
                continue
            }

            log.warning("Unsupported selection: \(url.lastPathComponent, privacy: .public)")
        }

        // Process any ZIPs (unzips then selects the discovered bundle roots)
        if !zips.isEmpty {
            importZipBundles(from: zips)
            addedSomething = true
        }

        if !addedSomething {
            log.warning("No valid bundles were added from the chosen items.")
        }
    }
    // MARK: - Selection / Recents
    func selectBundle(_ url: URL) {
        currentBundleURL = url
        selectedPatientID = nil
        patients = []
        visits = []
        reloadPatients()
    }

    private func addToRecents(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        let path = url.path
        // de-dupe, most-recent first
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        // cap at 10
        if paths.count > 10 { paths = Array(paths.prefix(10)) }
        UserDefaults.standard.set(paths, forKey: recentsKey)
        recentBundles = paths.compactMap { URL(fileURLWithPath: $0) }
    }

    private func loadRecentBundles() {
        let paths = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        recentBundles = paths.compactMap { URL(fileURLWithPath: $0) }
    }

    func reloadPatients() {
        guard let dbURL = currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else {
            patients = []
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            patients = []
            return
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT
          id,
          COALESCE(alias_label, '') AS alias,
          TRIM(COALESCE(first_name,'') || ' ' || COALESCE(last_name,'')) AS fullName,
          COALESCE(dob, '')  AS dobISO,
          COALESCE(sex, '')  AS sex
        FROM patients
        ORDER BY id;
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            log.error("reloadPatients prepare failed: \(msg, privacy: .public)")
            patients = []
            return
        }

        var rows: [PatientRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            func text(_ i: Int32) -> String {
                if let c = sqlite3_column_text(stmt, i) { return String(cString: c) }
                return ""
            }
            let alias    = text(1)
            let fullName = text(2)
            let dobISO   = text(3)
            let sex      = text(4)

            rows.append(PatientRow(id: id, alias: alias, fullName: fullName, dobISO: dobISO, sex: sex))
        }

        self.patients = rows
        if self.selectedPatientID == nil, let first = rows.first {
            self.selectedPatientID = first.id
        }
    }

    // MARK: - Visits (read-only listing for current bundle)

    /// Reload visits for the currently selected patient (safe to call when no selection).
    func reloadVisitsForSelectedPatient() {
        guard let pid = selectedPatientID else {
            visits.removeAll()
            return
        }
        loadVisits(for: pid)
    }

    /// Check if a table exists in the opened SQLite database.
    private func tableExists(_ db: OpaquePointer?, name: String) -> Bool {
        guard let db = db else { return false }
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=? LIMIT 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Return the set of column names for a table.
    private func columnSet(of table: String, db: OpaquePointer?) -> Set<String> {
        guard let db = db else { return [] }
        var cols: Set<String> = []
        let sql = "PRAGMA table_info(\(table));"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 1) {
                cols.insert(String(cString: cStr))
            }
        }
        return cols
    }

    /// Pick the first available name from `candidates` that is present in `available`.
    private func pickColumn(_ candidates: [String], available: Set<String>) -> String? {
        for c in candidates where available.contains(c) { return c }
        return nil
    }

    /// Load visits for a patient by *probing* the schema. It will:
    /// 1) Prefer a unified `visits` table if present (and columns exist)
    /// 2) Else, union any tables that look like visit tables (episodes / well_visits / encounters)
    ///    by finding a patient-id column and a date-like column in each.
    func loadVisits(for patientID: Int) {
        visits.removeAll()
        guard let bundle = currentBundleURL else { return }
        let dbURL = bundle.appendingPathComponent("db.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return
        }
        defer { sqlite3_close(db) }

        // Candidate tables to try in order.
        let tableCandidates = ["visits", "episodes", "well_visits", "encounters"]

        // Common column name variants.
        let pidCandidates  = ["patient_id", "patient", "pid", "patientId", "patientID"]
        let dateCandidates = [
            "visit_date", "date", "created_at", "updated_at",
            "encounter_date", "timestamp", "visited_at", "recorded_at"
        ]
        let categoryCandidates = ["category", "kind", "type", "visit_type"]

        // 1) If a unified `visits` table exists and has required columns, use it.
        if tableExists(db, name: "visits") {
            let cols = columnSet(of: "visits", db: db)
            if let pidCol = pickColumn(pidCandidates, available: cols),
               let dateCol = pickColumn(dateCandidates, available: cols) {

                let catCol = pickColumn(categoryCandidates, available: cols) // optional
                var sql = """
                          SELECT id, \(dateCol) AS dateISO
                          """
                if let catCol { sql += ", \(catCol) AS category" } else { sql += ", '' AS category" }
                sql += """
                       FROM visits
                       WHERE \(pidCol) = ?
                       ORDER BY dateISO DESC;
                       """

                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))

                var rows: [VisitRow] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = Int(sqlite3_column_int64(stmt, 0))
                    func text(_ i: Int32) -> String {
                        if let c = sqlite3_column_text(stmt, i) { return String(cString: c) }
                        return ""
                    }
                    let dateISO = text(1)
                    let category = text(2)
                    rows.append(VisitRow(id: id, dateISO: dateISO, category: category))
                }
                self.visits = rows
                if rows.isEmpty {
                    log.info("visits table present but no rows for patient \(patientID)")
                }
                return
            }
        }

        // 2) Else, dynamically union any visit-like tables that have (pid + date) columns.
        struct Part { let table: String; let pidCol: String; let dateCol: String; let categoryExpr: String }
        var parts: [Part] = []

        for t in tableCandidates where tableExists(db, name: t) {
            let cols = columnSet(of: t, db: db)
            guard let pidCol = pickColumn(pidCandidates, available: cols),
                  let dateCol = pickColumn(dateCandidates, available: cols) else { continue }

            let catCol = pickColumn(categoryCandidates, available: cols)
            let categoryExpr = catCol ?? (t == "episodes" ? "'episode'" : (t == "well_visits" ? "'well'" : "''"))
            parts.append(Part(table: t, pidCol: pidCol, dateCol: dateCol, categoryExpr: categoryExpr))
        }

        guard !parts.isEmpty else {
            let bundleName = dbURL.deletingLastPathComponent().lastPathComponent
            log.warning("No visit-like tables found for bundle at \(bundleName, privacy: .public)")
            return
        }

        // Build UNION ALL with placeholders.
        let unionSQL = parts.map {
            """
            SELECT id, \($0.dateCol) AS dateISO, \($0.categoryExpr) AS category
            FROM \($0.table)
            WHERE \($0.pidCol) = ?
            """
        }.joined(separator: "\nUNION ALL\n") + "\nORDER BY dateISO DESC;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, unionSQL, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            log.error("prepare visits-union failed: \(msg, privacy: .public)")
            return
        }
        defer { sqlite3_finalize(stmt) }

        // Bind the same patientID for each UNION leg.
        var index: Int32 = 1
        for _ in parts { sqlite3_bind_int64(stmt, index, sqlite3_int64(patientID)); index += 1 }

        var rows: [VisitRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            func text(_ i: Int32) -> String {
                if let c = sqlite3_column_text(stmt, i) { return String(cString: c) }
                return ""
            }
            let dateISO  = text(1)
            let category = text(2)
            rows.append(VisitRow(id: id, dateISO: dateISO, category: category))
        }
        self.visits = rows

        if rows.isEmpty {
            let tablesStr = parts.map { $0.table }.joined(separator: ", ")
            log.info("Visit-like tables exist but no rows matched patient \(patientID). Checked: \(tablesStr, privacy: .public)")
        }
    }

    // MARK: - Summaries (patient + visit)

    /// Quick existence check for a row id in a table.
    private func rowExists(_ table: String, id: Int, db: OpaquePointer?) -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT 1 FROM \(table) WHERE id=? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(id))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Load a concise summary for the given patient id.
    func loadPatientSummary(_ patientID: Int) {
        guard let dbURL = currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else {
            patientSummary = nil
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            patientSummary = nil
            return
        }
        defer { sqlite3_close(db) }

        // --- Vaccination status from patients.vaccination_status (if present) ---
        var vaccination: String? = nil
        do {
            let cols = columnSet(of: "patients", db: db)
            if cols.contains("vaccination_status") {
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                let sql = "SELECT vaccination_status FROM patients WHERE id=? LIMIT 1;"
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))
                    if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
                        let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                        vaccination = s.isEmpty ? nil : s
                    }
                }
            }
        }

        // --- PMH from patients.(past_medical_history|pmh_summary|pmh) if present ---
        var pmh: String? = nil
        do {
            let cols = columnSet(of: "patients", db: db)
            if let pmhCol = pickColumn(["past_medical_history","pmh_summary","pmh"], available: cols) {
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                let sql = "SELECT \(pmhCol) FROM patients WHERE id=? LIMIT 1;"
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))
                    if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
                        let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                        pmh = s.isEmpty ? nil : s
                    }
                }
            }
        }

        // --- Perinatal summary (if perinatal_summary or perinatal table exists) ---
        var perinatal: String? = nil
        do {
            let candidateTables = ["perinatal_summary","perinatal"]
            var chosen: String? = nil
            for t in candidateTables where tableExists(db, name: t) {
                chosen = t; break
            }
            if let table = chosen {
                let cols = columnSet(of: table, db: db)
                // Try to assemble a small readable line from any available columns
                let tryCols = [
                    "birth_weight","birth_length","birth_head_circumference",
                    "delivery","apgar1","apgar5","notes","summary"
                ]
                // Pick the first 3-5 with content
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                // Find a linking column to patients: commonly patient_id
                let pidCol = pickColumn(["patient_id","pid","patient","patientId","patientID"], available: cols) ?? "patient_id"
                let selectCols = tryCols.filter { cols.contains($0) }
                if !selectCols.isEmpty {
                    let sql = "SELECT " + selectCols.joined(separator: ", ") + " FROM \(table) WHERE \(pidCol)=? LIMIT 1;"
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                        sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))
                        if sqlite3_step(stmt) == SQLITE_ROW {
                            var parts: [String] = []
                            for i in 0..<selectCols.count {
                                if let c = sqlite3_column_text(stmt, Int32(i)) {
                                    let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !s.isEmpty {
                                        parts.append("\(selectCols[i]): \(s)")
                                    }
                                }
                            }
                            if !parts.isEmpty { perinatal = parts.joined(separator: " • ") }
                        }
                    }
                }
            }
        }

        self.patientSummary = PatientSummary(vaccination: vaccination, pmh: pmh, perinatal: perinatal)
    }

    /// Load a concise summary for a specific visit row by probing likely tables/columns.
    func loadVisitSummary(for visit: VisitRow) {
        guard let dbURL = currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else {
            visitSummary = nil
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            visitSummary = nil
            return
        }
        defer { sqlite3_close(db) }

        // Preferred unified table
        if tableExists(db, name: "visits") {
            let cols = columnSet(of: "visits", db: db)
            let problemsCol   = pickColumn(["problem_list","problems"], available: cols)
            let diagnosisCol  = pickColumn(["diagnosis","final_diagnosis"], available: cols)
            let conclusionCol = pickColumn(["conclusions","conclusion","plan"], available: cols)

            if problemsCol != nil || diagnosisCol != nil || conclusionCol != nil {
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                let wanted = [problemsCol, diagnosisCol, conclusionCol].compactMap { $0 }
                let sql = "SELECT " + wanted.joined(separator: ", ") + " FROM visits WHERE id=? LIMIT 1;"
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmt, 1, sqlite3_int64(visit.id))
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        var vals: [String?] = []
                        for i in 0..<wanted.count {
                            if let c = sqlite3_column_text(stmt, Int32(i)) {
                                let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                                vals.append(s.isEmpty ? nil : s)
                            } else { vals.append(nil) }
                        }
                        let problems   = problemsCol != nil   ? vals[safe: 0] : nil
                        let diagnosis  = diagnosisCol != nil  ? vals[safe: problemsCol == nil ? 0 : 1] : nil
                        let conclusions = conclusionCol != nil ? vals.last ?? nil : nil
                        self.visitSummary = VisitSummary(problems: problems ?? nil, diagnosis: diagnosis ?? nil, conclusions: conclusions ?? nil)
                        return
                    }
                }
            }
        }

        // Else probe episodes / well_visits
        var problems: String? = nil
        var diagnosis: String? = nil
        var conclusions: String? = nil

        if tableExists(db, name: "episodes"), rowExists("episodes", id: visit.id, db: db) {
            let cols = columnSet(of: "episodes", db: db)
            let pb  = pickColumn(["problem_list","problems"], available: cols)
            let dx  = pickColumn(["diagnosis","final_diagnosis"], available: cols)
            let con = pickColumn(["conclusions","conclusion","plan"], available: cols)
            if pb != nil || dx != nil || con != nil {
                let wanted = [pb, dx, con].compactMap { $0 }
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                let sql = "SELECT " + wanted.joined(separator: ", ") + " FROM episodes WHERE id=? LIMIT 1;"
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmt, 1, sqlite3_int64(visit.id))
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        var idx = 0
                        if let pb {
                            if let c = sqlite3_column_text(stmt, Int32(idx)) {
                                let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                                problems = s.isEmpty ? nil : s
                            }
                            idx += 1
                        }
                        if let dx {
                            if let c = sqlite3_column_text(stmt, Int32(idx)) {
                                let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                                diagnosis = s.isEmpty ? nil : s
                            }
                            idx += 1
                        }
                        if let con {
                            if let c = sqlite3_column_text(stmt, Int32(idx)) {
                                let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                                conclusions = s.isEmpty ? nil : s
                            }
                        }
                    }
                }
            }
        } else if tableExists(db, name: "well_visits"), rowExists("well_visits", id: visit.id, db: db) {
            let cols = columnSet(of: "well_visits", db: db)
            let pb  = pickColumn(["problem_list","problems"], available: cols)
            let con = pickColumn(["conclusions","conclusion","plan"], available: cols)
            let wanted = [pb, con].compactMap { $0 }
            if !wanted.isEmpty {
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                let sql = "SELECT " + wanted.joined(separator: ", ") + " FROM well_visits WHERE id=? LIMIT 1;"
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmt, 1, sqlite3_int64(visit.id))
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        var idx = 0
                        if let pb {
                            if let c = sqlite3_column_text(stmt, Int32(idx)) {
                                let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                                problems = s.isEmpty ? nil : s
                            }
                            idx += 1
                        }
                        if let con {
                            if let c = sqlite3_column_text(stmt, Int32(idx)) {
                                let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                                conclusions = s.isEmpty ? nil : s
                            }
                        }
                    }
                }
            }
        }

        self.visitSummary = VisitSummary(problems: problems, diagnosis: diagnosis, conclusions: conclusions)
    }

    // Small safe index helper

    /// Import one or more bundle .zip files by unzipping to App Support and then detecting the bundle root (folder with db.sqlite)
    @MainActor
    func importZipBundles(from zipURLs: [URL]) {
        guard !zipURLs.isEmpty else { return }
        let fm = FileManager.default

        for zipURL in zipURLs {
            do {
                // Destination: ~/Library/Application Support/DrsMainApp/Imported/<zip-basename>/
                let base = (zipURL.deletingPathExtension().lastPathComponent)
                let dest = ensureAppSupportSubdir("Imported").appendingPathComponent(base, isDirectory: true)

                // Clear any previous extraction for idempotency
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)

                // Unzip
                try fm.unzipItem(at: zipURL, to: dest)

                // Find the real bundle root (folder containing db.sqlite)
                if let bundleRoot = findBundleRoot(startingAt: dest) {
                    addBundleRootAndSelect(bundleRoot)
                } else {
                    log.warning("ZIP import: no db.sqlite found under \(dest.path, privacy: .public)")
                }
            } catch {
                log.error("ZIP import failed for \(zipURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Returns Application Support/DrsMainApp/<subdir> and creates it if needed.
    private func ensureAppSupportSubdir(_ subdir: String) -> URL {
        let fm = FileManager.default
        let appSupport = try! fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true)
            .appendingPathComponent("DrsMainApp", isDirectory: true)
            .appendingPathComponent(subdir, isDirectory: true)

        if !fm.fileExists(atPath: appSupport.path) {
            try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }
        return appSupport
    }

    /// Scan down from `start` to locate a folder that contains `db.sqlite`.
    private func findBundleRoot(startingAt start: URL) -> URL? {
        let fm = FileManager.default
        // Exact folder root?
        if fm.fileExists(atPath: start.appendingPathComponent("db.sqlite").path) {
            return start
        }
        // Search subfolders (non-recursive depth-first with enumerator is easiest)
        if let en = fm.enumerator(at: start, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in en {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    if fm.fileExists(atPath: url.appendingPathComponent("db.sqlite").path) {
                        return url
                    }
                }
            }
        }
        return nil
    }

    /// Add a new bundle root, make it selected, and refresh patients.
    @MainActor
    private func addBundleRootAndSelect(_ root: URL) {
        selectBundle(root.standardizedFileURL)
    }
    // MARK: - Create new patient/bundle
    /// Creates a new bundle folder with `db.sqlite`, `docs/`, and `manifest.json`,
    /// initializes the SQLite schema (minimal), seeds the initial patient row, and selects it.
    func createNewPatient(
        into parentFolder: URL,
        alias: String,
        fullName: String?,
        dob: Date?,
        sex: String?
    ) throws -> URL {
        let fm = FileManager.default

        // 1) Make a unique, safe folder name
        let safeAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Patient" : alias
        let baseName = safeAlias
            .replacingOccurrences(of: "/", with: "–")
            .replacingOccurrences(of: ":", with: "–")
        var bundleURL = parentFolder.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 1
        while fm.fileExists(atPath: bundleURL.path) {
            suffix += 1
            bundleURL = parentFolder.appendingPathComponent("\(baseName) \(suffix)", isDirectory: true)
        }

        // 2) Create bundle dirs
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let docsURL = bundleURL.appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: docsURL, withIntermediateDirectories: true)

        // 3) Create and initialize SQLite (minimal schema required to seed patients)
        let dbURL = bundleURL.appendingPathComponent("db.sqlite")
        try initializeMinimalSchema(at: dbURL)

        // 4) Seed initial patient row
        try insertInitialPatient(
            dbURL: dbURL,
            alias: safeAlias,
            fullName: fullName,
            dob: dob,
            sex: sex
        )

        // 5) Write a simple manifest at root (and mirror into docs/ for legacy readers)
        let iso = ISO8601DateFormatter()
        let nowISO = iso.string(from: Date())
        let manifest: [String: Any] = [
            "alias": safeAlias,
            "created_at": nowISO,
            "version": 1,
            "docs_count": 0
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: bundleURL.appendingPathComponent("manifest.json"), options: .atomic)
        try manifestData.write(to: docsURL.appendingPathComponent("manifest.json"), options: .atomic)

        log.info("Created new bundle for \(safeAlias, privacy: .public) at \(bundleURL.path, privacy: .public)")

        // 6) Activate
        selectBundle(bundleURL)
        return bundleURL
    }

    // MARK: - Minimal schema & seed helpers (no dependency on external initializers)

    /// Create a minimal schema sufficient to store patients.
    private func initializeMinimalSchema(at dbURL: URL) throws {
        var db: OpaquePointer?
        // Ensure file exists, then open
        let path = dbURL.path
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
            let code = sqlite3_errcode(db)
            defer { sqlite3_close(db) }
            throw NSError(domain: "SQLite", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Failed to open DB at \(path)"])
        }
        defer { sqlite3_close(db) }

        let sql = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS patients (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            -- Canonical names
            first_name TEXT,
            last_name  TEXT,
            dob        TEXT,
            sex        TEXT,
            mrn        TEXT UNIQUE,
            vaccination_status TEXT,
            parent_notes       TEXT,
            alias_id    TEXT,
            alias_label TEXT,
            -- Optional convenience cache
            full_name   TEXT
        );
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: "Schema init failed: \(msg)"])
        }

        // --- Migrations / compatibility with older bundles ---
        // Add any missing columns (ignore errors if they already exist).
        let alterStatements = [
            "ALTER TABLE patients ADD COLUMN first_name TEXT",
            "ALTER TABLE patients ADD COLUMN last_name TEXT",
            "ALTER TABLE patients ADD COLUMN dob TEXT",
            "ALTER TABLE patients ADD COLUMN sex TEXT",
            "ALTER TABLE patients ADD COLUMN mrn TEXT UNIQUE",
            "ALTER TABLE patients ADD COLUMN vaccination_status TEXT",
            "ALTER TABLE patients ADD COLUMN parent_notes TEXT",
            "ALTER TABLE patients ADD COLUMN alias_id TEXT",
            "ALTER TABLE patients ADD COLUMN alias_label TEXT",
            "ALTER TABLE patients ADD COLUMN full_name TEXT"
        ]
        for stmt in alterStatements {
            _ = sqlite3_exec(db, stmt, nil, nil, nil) // ignore duplicate column errors
        }

        // If legacy `alias` exists and alias_label is empty, copy it over.
        _ = sqlite3_exec(db, """
            UPDATE patients
            SET alias_label = COALESCE(alias_label, alias)
            WHERE (alias_label IS NULL OR alias_label = '')
              AND EXISTS (SELECT 1 FROM pragma_table_info('patients') WHERE name='alias');
        """, nil, nil, nil)

        // Seed alias_id from alias_label if empty.
        _ = sqlite3_exec(db, """
            UPDATE patients
            SET alias_id = CASE
                WHEN (alias_id IS NULL OR alias_id = '')
                     AND alias_label IS NOT NULL AND alias_label <> ''
                THEN lower(replace(alias_label, ' ', '_'))
                ELSE alias_id
            END;
        """, nil, nil, nil)
    }

    /// Insert the first patient row using a prepared statement.
    private func insertInitialPatient(
        dbURL: URL,
        alias: String,
        fullName: String?,
        dob: Date?,
        sex: String?
    ) throws {
        var db: OpaquePointer?
        let path = dbURL.path
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
            let code = sqlite3_errcode(db)
            defer { sqlite3_close(db) }
            throw NSError(domain: "SQLite", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Failed to open DB at \(path)"])
        }
        defer { sqlite3_close(db) }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]
        let dobStr = dob.map { iso.string(from: $0) }

        let sql = """
        INSERT INTO patients (alias_label, alias_id, full_name, dob, sex)
        VALUES (?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: "Prepare failed: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }

        // Compute alias_id from alias_label
        let aliasID = alias
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")

        // Bind parameters (1-based)
        sqlite3_bind_text(stmt, 1, alias, -1, SQLITE_TRANSIENT)   // alias_label
        sqlite3_bind_text(stmt, 2, aliasID, -1, SQLITE_TRANSIENT) // alias_id

        if let fullName = fullName, !fullName.isEmpty {
            sqlite3_bind_text(stmt, 3, fullName, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 3)
        }

        if let dobStr = dobStr {
            sqlite3_bind_text(stmt, 4, dobStr, -1, SQLITE_TRANSIENT) // dob
        } else {
            sqlite3_bind_null(stmt, 4)
        }

        if let sex = sex, !sex.isEmpty {
            sqlite3_bind_text(stmt, 5, sex, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }

        if sqlite3_step(stmt) != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SQLite", code: 3, userInfo: [NSLocalizedDescriptionKey: "Insert failed: \(msg)"])
        }
    }
}

// MARK: - Sidebar selection
enum SidebarSelection: Hashable {
    case dashboard
    case patients
    case imports
}
// MARK: - Bundle importing (folders or .zip)


extension AppState {
    func importBundles(from urls: [URL]) {
        var imported: [URL] = []

        for url in urls {
            if url.pathExtension.lowercased() == "zip" {
                if let extracted = extractZipBundle(url),
                   let canonical = canonicalBundleRoot(at: extracted) {
                    imported.append(canonical)
                }
            } else if let canonical = canonicalBundleRoot(at: url) {
                imported.append(canonical)
            }
        }

        guard !imported.isEmpty else { return }

        // Merge + select last
        for u in imported where !bundleLocations.contains(u) {
            bundleLocations.append(u)
        }
        currentBundleURL = imported.last
    }

    private func canonicalBundleRoot(at url: URL) -> URL? {
        let fm = FileManager.default
        let db = url.appendingPathComponent("db.sqlite")
        if fm.fileExists(atPath: db.path) { return url }

        if let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ), contents.count == 1, let only = contents.first {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: only.path, isDirectory: &isDir), isDir.boolValue {
                if fm.fileExists(atPath: only.appendingPathComponent("db.sqlite").path) {
                    return only
                }
            }
        }
        return nil
    }

    private func extractZipBundle(_ zipURL: URL) -> URL? {
        let fm = FileManager.default
        do {
            let appSup = try fm.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: true)
                .appendingPathComponent("DrsMainApp/ImportedBundles", isDirectory: true)
            try fm.createDirectory(at: appSup, withIntermediateDirectories: true)

            let base = zipURL.deletingPathExtension().lastPathComponent
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let target = appSup.appendingPathComponent("\(base)-\(stamp)", isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)

            let archive = try Archive(url: zipURL, accessMode: .read) // throwing initializer

            for entry in archive {
                let destURL = target.appendingPathComponent(entry.path)
                switch entry.type {
                case .directory:
                    try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
                default:
                    try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    _ = try archive.extract(entry, to: destURL)
                }
            }
            return target
        } catch {
            print("Zip extract failed: \(error)")
            return nil
        }
    }
}

// Safe index extension for arrays
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
