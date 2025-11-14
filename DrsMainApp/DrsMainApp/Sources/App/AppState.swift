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
import CryptoKit
import PediaShared

#if os(macOS)
import AppKit   // for NSAlert confirmation dialogs during import
#endif

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
    let parentNotes: String?     // NEW: separate from PMH
}

struct VisitSummary {
    let mainComplaint: String?
    let problems: String?
    let diagnosis: String?
    let icd10: String?
    let conclusions: String?
}

/// Full details for a visit, ready for a detail sheet + export.
struct VisitDetails {
    let visit: VisitRow
    let patientName: String
    let patientDOB: String?
    let patientSex: String?
    let mainComplaint: String?
    let problems: String?
    let diagnosis: String?
    let icd10: String?
    let conclusions: String?
    let vitals: VitalsPoint?
    /// For well visits: "Achieved X/Y; Flags: a, b"
    let milestonesSummary: String?
}

/// One row from the vitals table, normalized for UI display.
struct VitalsPoint: Identifiable, Equatable {
    let id: Int
    let recordedAtISO: String
    let temperatureC: Double?
    let heartRate: Int?
    let respiratoryRate: Int?
    let spo2: Int?
    let bpSystolic: Int?
    let bpDiastolic: Int?
    let weightKg: Double?
    let heightCm: Double?
    let headCircumferenceCm: Double?
}

// C macro for sqlite3 destructor that forces a copy during bind
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal patient profile for header/badge
struct PatientProfile: Equatable {
    var vaccinationStatus: String?
    var pmh: String?                 // cumulative past medical history
    var perinatalHistory: String?    // brief perinatal summary if available
    var parentNotes: String?         // NEW: kept separate from PMH
}

@MainActor
final class AppState: ObservableObject {
    
    // MARK: - Published state
    @Published var selection: SidebarSelection? = .dashboard
    @Published var currentBundleURL: URL? = nil
    @Published var recentBundles: [URL] = []
    @Published var patients: [PatientRow] = []
    @Published var selectedPatientID: Int? {
        didSet {
            self.loadPerinatalHistoryForSelectedPatient()
            self.loadPMHForSelectedPatient()
            self.clearEpisodeEditing()
            if let pid = self.selectedPatientID {
                // Keep the readonly header/summary in sync with selection
                self.loadPatientProfile(for: Int64(pid))
                self.loadPatientSummary(pid)
                self.reloadVisitsForSelectedPatient()
            } else {
                self.currentPatientProfile = nil
                self.patientSummary = nil
            }
        }
    }
    @Published var visits: [VisitRow] = []
    @Published var bundleLocations: [URL] = []
    
    // Summaries populated on demand by views
    @Published var patientSummary: PatientSummary? = nil
    @Published var visitSummary: VisitSummary? = nil
    @Published var visitDetails: VisitDetails? = nil
    @Published var currentPatientProfile: PatientProfile? = nil
    // Selected/active signed-in clinician (optional until sign-in flow is added)
    @Published var activeUserID: Int? = nil
    // Documents (per-bundle)
    @Published var documents: [URL] = []
    @Published var selectedDocumentURL: URL? = nil

    // Episodes (editing context)
    @Published var activeEpisodeID: Int? = nil
    
    /// Default root for all patient bundles (auto-created; sandbox-aware).
    public var bundlesRoot: URL {
        ensureAppSupportSubdir("Bundles")
    }
    
    private let profileLog = Logger(subsystem: "DrsMainApp", category: "PatientProfile")
    // Clinicians: injected at init so AppState and Views share the same instance
    let clinicianStore: ClinicianStore
    
    // The db.sqlite inside the currently selected bundle
    var currentDBURL: URL? {
        currentBundleURL?.appendingPathComponent("db.sqlite")
    }
    /// docs/ folder in the current bundle (created if missing)
    var currentDocsURL: URL? {
        guard let root = currentBundleURL else { return nil }
        let url = root.appendingPathComponent("docs", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        // subfolder for app-imported files (deletable)
        let inbox = url.appendingPathComponent("inbox", isDirectory: true)
        if !fm.fileExists(atPath: inbox.path) {
            try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        }
        return url
    }
    
    func migrateCurrentDBForGrowth() {
        guard let dbURL = currentDBURL, FileManager.default.fileExists(atPath: dbURL.path) else { return }
        ensureGrowthUnificationSchema(at: dbURL)
    }
    
    func loadGrowthForSelectedPatient() -> [GrowthPoint] {
        guard let pid = selectedPatientID,
              let dbURL = currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else { return [] }

        // Ensure the unified growth schema/view/triggers exist for this DB
        migrateCurrentDBForGrowth()

        do {
            let rows = try GrowthStore().fetchPatientGrowth(dbURL: dbURL, patientID: pid)
            if rows.isEmpty {
                log.info("Growth fetch returned 0 rows for patient \(pid)")
            }
            return rows
        } catch {
            log.error("Growth fetch failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }
    
    

    /// Load vitals rows for the currently selected patient from `vitals` table.
    /// Returns newest-first. Safe against NULLs.
    func loadVitalsForSelectedPatient() -> [VitalsPoint] {
        guard let pid = selectedPatientID,
              let dbURL = currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db else {
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT
          id,
          COALESCE(recorded_at, '') AS recorded_at,
          temperature_c,
          heart_rate,
          respiratory_rate,
          spo2,
          bp_systolic,
          bp_diastolic,
          weight_kg,
          height_cm,
          head_circumference_cm
        FROM vitals
        WHERE patient_id = ?
        ORDER BY
          CASE
            WHEN recorded_at IS NULL OR recorded_at = '' THEN 1
            ELSE 0
          END,
          datetime(COALESCE(recorded_at, '0001-01-01T00:00:00Z')) DESC,
          id DESC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(pid))

        func intOpt(_ i: Int32) -> Int? {
            let t = sqlite3_column_type(stmt, i)
            if t == SQLITE_NULL { return nil }
            return Int(sqlite3_column_int64(stmt, i))
        }
        func doubleOpt(_ i: Int32) -> Double? {
            let t = sqlite3_column_type(stmt, i)
            if t == SQLITE_NULL { return nil }
            return sqlite3_column_double(stmt, i)
        }
        func text(_ i: Int32) -> String {
            if let c = sqlite3_column_text(stmt, i) { return String(cString: c) }
            return ""
        }

        var rows: [VitalsPoint] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id          = Int(sqlite3_column_int64(stmt, 0))
            let recordedISO = text(1)
            let tempC       = doubleOpt(2)
            let hr          = intOpt(3)
            let rr          = intOpt(4)
            let sao2        = intOpt(5)
            let sys         = intOpt(6)
            let dia         = intOpt(7)
            let wkg         = doubleOpt(8)
            let hcm         = doubleOpt(9)
            let hccm        = doubleOpt(10)

            rows.append(VitalsPoint(
                id: id,
                recordedAtISO: recordedISO,
                temperatureC: tempC,
                heartRate: hr,
                respiratoryRate: rr,
                spo2: sao2,
                bpSystolic: sys,
                bpDiastolic: dia,
                weightKg: wkg,
                heightCm: hcm,
                headCircumferenceCm: hccm
            ))
        }
        return rows
    }

    /// Refresh the `documents` list for the current bundle.
    func reloadDocuments() {
        documents.removeAll()
        guard let docsRoot = currentDocsURL else { return }
        let fm = FileManager.default
        if let en = fm.enumerator(
            at: docsRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            var items: [URL] = []
            for case let url as URL in en {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                    items.append(url)
                }
            }
            self.documents = items.sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            }
        }
    }

    /// Import (copy) selected files into docs/inbox and refresh list.
    func importDocuments(from urls: [URL]) {
        guard !urls.isEmpty, let docsRoot = currentDocsURL else { return }
        let inbox = docsRoot.appendingPathComponent("inbox", isDirectory: true)
        let fm = FileManager.default
        for src in urls {
            var dest = inbox.appendingPathComponent(src.lastPathComponent)
            var i = 1
            while fm.fileExists(atPath: dest.path) {
                let base = src.deletingPathExtension().lastPathComponent
                let ext  = src.pathExtension
                dest = inbox.appendingPathComponent("\(base)-\(i)" + (ext.isEmpty ? "" : ".\(ext)"))
                i += 1
            }
            do { try fm.copyItem(at: src, to: dest) }
            catch { log.error("Import doc copy failed: \(String(describing: error), privacy: .public)") }
        }
        reloadDocuments()
    }

    /// Delete a document only if it is under docs/inbox/
    func deleteDocument(_ url: URL) {
        guard let docsRoot = currentDocsURL else { return }
        let inbox = docsRoot.appendingPathComponent("inbox", isDirectory: true).standardizedFileURL
        let ok = url.standardizedFileURL.path.hasPrefix(inbox.path)
        guard ok else {
            log.info("Refusing delete (not in inbox): \(url.lastPathComponent, privacy: .public)")
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
            if selectedDocumentURL == url { selectedDocumentURL = nil }
            reloadDocuments()
        } catch {
            log.error("Delete doc failed: \(String(describing: error), privacy: .public)")
        }
    }
    
    // Convenience for the right pane
    var selectedPatient: PatientRow? {
        guard let id = selectedPatientID else { return nil }
        return patients.first { $0.id == id }
    }
    // MARK: - Growth unification objects (VIEW + TRIGGERS + INDEXES)
    // Idempotent creator for:
    // - vitals_to_manual_growth_ai (AFTER INSERT)
    // - vitals_to_manual_growth_au (AFTER UPDATE)
    // - growth_unified view combining manual_growth + vitals + perinatal_history
    // Safe to call after applying bundled schema or at bundle selection time.
    private func ensureGrowthUnificationSchema(at dbURL: URL) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = db else { return }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) {
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                log.error("Growth schema exec failed: \(msg, privacy: .public)")
            }
        }

        // --- Indices (idempotent) ---
        exec("CREATE INDEX IF NOT EXISTS idx_manual_growth_patient ON manual_growth(patient_id, recorded_at);")
        exec("CREATE INDEX IF NOT EXISTS idx_vitals_patient ON vitals(patient_id, recorded_at);")

        // --- Mirror vitals -> manual_growth (after INSERT) ---
        exec("""
        CREATE TRIGGER IF NOT EXISTS vitals_to_manual_growth_ai
        AFTER INSERT ON vitals
        WHEN (NEW.weight_kg IS NOT NULL OR NEW.height_cm IS NOT NULL OR NEW.head_circumference_cm IS NOT NULL)
        BEGIN
          INSERT INTO manual_growth (patient_id, recorded_at, weight_kg, height_cm, head_circumference_cm, source, created_at, updated_at)
          VALUES (
            NEW.patient_id,
            COALESCE(NEW.recorded_at, CURRENT_TIMESTAMP),
            NEW.weight_kg,
            NEW.height_cm,
            NEW.head_circumference_cm,
            'vitals',
            CURRENT_TIMESTAMP,
            CURRENT_TIMESTAMP
          );
        END;
        """)

        // Optional: mirror meaningful updates as a new longitudinal point
        exec("""
        CREATE TRIGGER IF NOT EXISTS vitals_to_manual_growth_au
        AFTER UPDATE ON vitals
        WHEN (
          (NEW.weight_kg IS NOT NULL AND NEW.weight_kg IS NOT OLD.weight_kg) OR
          (NEW.height_cm IS NOT NULL AND NEW.height_cm IS NOT OLD.height_cm) OR
          (NEW.head_circumference_cm IS NOT NULL AND NEW.head_circumference_cm IS NOT OLD.head_circumference_cm)
        )
        BEGIN
          INSERT INTO manual_growth (patient_id, recorded_at, weight_kg, height_cm, head_circumference_cm, source, created_at, updated_at)
          VALUES (
            NEW.patient_id,
            COALESCE(NEW.recorded_at, CURRENT_TIMESTAMP),
            NEW.weight_kg,
            NEW.height_cm,
            NEW.head_circumference_cm,
            'vitals:update',
            CURRENT_TIMESTAMP,
            CURRENT_TIMESTAMP
          );
        END;
        """)

        // --- Unified view (manual_growth + vitals + perinatal birth/discharge) ---
        // Columns: id, patient_id, episode_id, recorded_at, weight_kg, height_cm, head_circumference_cm, source
        exec("""
        CREATE VIEW IF NOT EXISTS growth_unified AS
        SELECT
          mg.id                      AS id,
          mg.patient_id              AS patient_id,
          NULL                       AS episode_id,
          mg.recorded_at             AS recorded_at,
          mg.weight_kg               AS weight_kg,
          mg.height_cm               AS height_cm,
          mg.head_circumference_cm   AS head_circumference_cm,
          COALESCE(mg.source,'manual') AS source
        FROM manual_growth mg

        UNION ALL

        SELECT
          v.id + 1000000             AS id,
          v.patient_id               AS patient_id,
          v.episode_id               AS episode_id,
          COALESCE(v.recorded_at, CURRENT_TIMESTAMP) AS recorded_at,
          v.weight_kg                AS weight_kg,
          v.height_cm                AS height_cm,
          v.head_circumference_cm    AS head_circumference_cm,
          'vitals'                   AS source
        FROM vitals v

        UNION ALL

        SELECT
          p.id + 2000000             AS id,
          p.id                       AS patient_id,
          NULL                       AS episode_id,
          COALESCE(p.dob, '')        AS recorded_at,
          per.birth_weight_g/1000.0  AS weight_kg,
          per.birth_length_cm        AS height_cm,
          per.birth_head_circumference_cm AS head_circumference_cm,
          'birth'                    AS source
        FROM perinatal_history per
        JOIN patients p ON p.id = per.patient_id

        UNION ALL

        SELECT
          p.id + 3000000             AS id,
          p.id                       AS patient_id,
          NULL                       AS episode_id,
          per.maternity_discharge_date AS recorded_at,
          per.discharge_weight_g/1000.0 AS weight_kg,
          NULL                       AS height_cm,
          NULL                       AS head_circumference_cm,
          'discharge'                AS source
        FROM perinatal_history per
        JOIN patients p ON p.id = per.patient_id
        WHERE per.maternity_discharge_date IS NOT NULL;
        """)
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
    
    
    /// Return true if a table exists
    private func sqliteTableExists(db: OpaquePointer?, table: String) -> Bool {
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        _ = table.withCString { c in
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
    
    // MARK: - Private
    private func loadRecentBundles() {
        let paths = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        recentBundles = paths.compactMap { URL(fileURLWithPath: $0) }
    }

    // MARK: - Init
    init(clinicianStore: ClinicianStore) {
        self.clinicianStore = clinicianStore
        self.loadRecentBundles()
        PerinatalStore.dbURLResolver = { [weak self] in self?.currentDBURL }
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
        
        // PMH: Prefer past_medical_history table if present, else fallback to patients.parent_notes
        var pmh: String? = nil
        if sqliteTableExists(db: db, table: "past_medical_history") {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
            SELECT asthma, otitis, uti, allergies, other, allergy_details, updated_at
            FROM past_medical_history
            WHERE patient_id = ?
            ORDER BY id DESC
            LIMIT 1;
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, patientID)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    func intOpt(_ i: Int32) -> Int? {
                        let t = sqlite3_column_type(stmt, i)
                        return t == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, i))
                    }
                    func strOpt(_ i: Int32) -> String? {
                        guard let c = sqlite3_column_text(stmt, i) else { return nil }
                        let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                        return s.isEmpty ? nil : s
                    }
                    var parts: [String] = []
                    if let v = intOpt(0), v != 0 { parts.append("Asthma: Yes") }
                    if let v = intOpt(1), v != 0 { parts.append("Otitis: Yes") }
                    if let v = intOpt(2), v != 0 { parts.append("UTI: Yes") }
                    if let v = intOpt(3), v != 0 { parts.append("Allergies: Yes") }
                    if let v = strOpt(5) { parts.append("Allergy details: \(v)") }
                    if let v = strOpt(4) { parts.append("Other: \(v)") }
                    if let v = strOpt(6) { parts.append("PMH updated: \(v)") }
                    if !parts.isEmpty { pmh = parts.joined(separator: " • ") }
                }
            }
        }
        // Parent notes: always keep separate from PMH
        let parentNotes = sqliteScalarText(db: db,
                                           sql: "SELECT parent_notes FROM patients WHERE id=? LIMIT 1;",
                                           bindID: patientID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Optional perinatal summary (table may or may not exist)
        var peri: String? = nil
        if sqliteTableExists(db: db, table: "perinatal_history") {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            // patient_id is UNIQUE in this table per schema you provided
            let sql = """
            SELECT
              pregnancy_risk,
              birth_mode,
              birth_term_weeks,
              resuscitation,
              nicu_stay,
              infection_risk,
              birth_weight_g,
              birth_length_cm,
              birth_head_circumference_cm,
              maternity_stay_events,
              maternity_vaccinations,
              vitamin_k,
              feeding_in_maternity,
              passed_meconium_24h,
              urination_24h,
              heart_screening,
              metabolic_screening,
              hearing_screening,
              mother_vaccinations,
              family_vaccinations,
              maternity_discharge_date,
              discharge_weight_g,
              illnesses_after_birth,
              updated_at,
              evolution_since_maternity
            FROM perinatal_history
            WHERE patient_id = ?
            LIMIT 1;
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, patientID)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    func str(_ i: Int32) -> String? {
                        guard let c = sqlite3_column_text(stmt, i) else { return nil }
                        let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                        return s.isEmpty ? nil : s
                    }
                    func intOpt(_ i: Int32) -> Int? {
                        let t = sqlite3_column_type(stmt, i)
                        return t == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, i))
                    }
                    func realOpt(_ i: Int32) -> Double? {
                        let t = sqlite3_column_type(stmt, i)
                        return t == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
                    }
                    func yn(_ i: Int32) -> String? {
                        guard let v = intOpt(i) else { return nil }
                        return v == 0 ? "No" : "Yes"
                    }
                    
                    var parts: [String] = []
                    if let v = str(0)  { parts.append("Pregnancy risk: \(v)") }
                    if let v = str(1)  { parts.append("Birth mode: \(v)") }
                    if let v = intOpt(2) { parts.append("Term: \(v) weeks") }
                    if let v = str(3)  { parts.append("Resuscitation: \(v)") }
                    if let v = intOpt(4) { parts.append("NICU stay: \(v) days") }
                    if let v = str(5)  { parts.append("Infection risk: \(v)") }
                    if let v = intOpt(6) { parts.append("Birth weight: \(v) g") }
                    if let v = realOpt(7) { parts.append(String(format: "Birth length: %.1f cm", v)) }
                    if let v = realOpt(8) { parts.append(String(format: "Head circ: %.1f cm", v)) }
                    if let v = str(9)  { parts.append("Maternity events: \(v)") }
                    if let v = str(10) { parts.append("Maternity vaccs: \(v)") }
                    if let v = intOpt(11) { parts.append("Vitamin K: \(v == 0 ? "No" : "Yes")") }
                    if let v = str(12) { parts.append("Feeding in maternity: \(v)") }
                    if let v = yn(13)  { parts.append("Passed meconium 24h: \(v)") }
                    if let v = yn(14)  { parts.append("Urination 24h: \(v)") }
                    if let v = str(15) { parts.append("Heart screening: \(v)") }
                    if let v = str(16) { parts.append("Metabolic screening: \(v)") }
                    if let v = str(17) { parts.append("Hearing screening: \(v)") }
                    if let v = str(18) { parts.append("Mother vaccs: \(v)") }
                    if let v = str(19) { parts.append("Family vaccs: \(v)") }
                    if let v = str(20) { parts.append("Discharge date: \(v)") }
                    if let v = intOpt(21) { parts.append("Discharge weight: \(v) g") }
                    if let v = str(22) { parts.append("Illnesses after birth: \(v)") }
                    if let v = str(23) { parts.append("Updated at: \(v)") }
                    if let v = str(24) { parts.append("Evolution since maternity: \(v)") }

                    if !parts.isEmpty {
                        peri = parts.joined(separator: " • ")
                    }
                    }
                }
            }
            
        let profile = PatientProfile(
            vaccinationStatus: vacc,
            pmh: pmh,
            perinatalHistory: peri,
            parentNotes: (parentNotes?.isEmpty == false ? parentNotes : nil)
        )
            DispatchQueue.main.async { [weak self] in
                self?.currentPatientProfile = profile
            }
        }
        
        // Allow UI to add one or more bundle directories **or .zip files**
        func addBundles(from urls: [URL]) {
            let zips = urls.filter { $0.pathExtension.lowercased() == "zip" }
            if zips.isEmpty {
                log.warning("addBundles: only .zip bundles are supported for import.")
                return
            }
            importZipBundles(from: zips) // This will not change currentBundleURL or selectedPatientID
        }
        // MARK: - Selection / Recents
        func selectBundle(_ url: URL) {
            addToRecents(url)
            currentBundleURL = url
            // Apply golden schema idempotently (column-level) to keep selected bundles aligned
            if let dbURL = dbURLForCurrentBundle() {
                applyGoldenSchemaIdempotent(to: dbURL)
                ensureGrowthUnificationSchema(at: dbURL)
            }
            selectedPatientID = nil
            patients = []
            visits = []
            reloadPatients()
            reloadDocuments()
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
            guard let dbURL = dbURLForCurrentBundle(),
                  FileManager.default.fileExists(atPath: dbURL.path) else {
                return
            }
            
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
            
            // --- Parent notes from patients.parent_notes (always separate from PMH) ---
            var parentNotes: String? = nil
            do {
                let cols = columnSet(of: "patients", db: db)
                if cols.contains("parent_notes") {
                    var stmt: OpaquePointer?
                    defer { sqlite3_finalize(stmt) }
                    let sql = "SELECT parent_notes FROM patients WHERE id=? LIMIT 1;"
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                        sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))
                        if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
                            let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            parentNotes = s.isEmpty ? nil : s
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
            
            self.patientSummary = PatientSummary(
                vaccination: vaccination,
                pmh: pmh,
                perinatal: perinatal,
                parentNotes: parentNotes
            )
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
                let complaintCol  = pickColumn(["main_complaint","chief_complaint","complaint"], available: cols)
                let problemsCol   = pickColumn(["problem_listing","problem_list","problems"], available: cols)
                let diagnosisCol  = pickColumn(["diagnosis","final_diagnosis"], available: cols)
                let icdCol        = pickColumn(["icd10","icd_10","icd"], available: cols)
                let conclusionCol = pickColumn(["conclusions","conclusion","plan"], available: cols)

                if complaintCol != nil || problemsCol != nil || diagnosisCol != nil || icdCol != nil || conclusionCol != nil {
                    var stmt: OpaquePointer?
                    defer { sqlite3_finalize(stmt) }
                    let wanted = [complaintCol, problemsCol, diagnosisCol, icdCol, conclusionCol].compactMap { $0 }
                    let sql = "SELECT " + wanted.joined(separator: ", ") + " FROM visits WHERE id=? LIMIT 1;"
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                        sqlite3_bind_int64(stmt, 1, sqlite3_int64(visit.id))
                        if sqlite3_step(stmt) == SQLITE_ROW {
                            var idx = 0
                            func nextString() -> String? {
                                defer { idx += 1 }
                                if let c = sqlite3_column_text(stmt, Int32(idx)) {
                                    let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                                    return s.isEmpty ? nil : s
                                }
                                return nil
                            }
                            let mc   = complaintCol  != nil ? nextString() : nil
                            let pb   = problemsCol   != nil ? nextString() : nil
                            let dx   = diagnosisCol  != nil ? nextString() : nil
                            let icd  = icdCol        != nil ? nextString() : nil
                            let cons = conclusionCol != nil ? nextString() : nil

                            self.visitSummary = VisitSummary(
                                mainComplaint: mc,
                                problems: pb,
                                diagnosis: dx,
                                icd10: icd,
                                conclusions: cons
                            )
                            return
                        }
                    }
                }
            }
            
            // Else probe episodes / well_visits
            var problems: String? = nil
            var diagnosis: String? = nil
            var conclusions: String? = nil
            var mainComplaint: String? = nil
            var icd10: String? = nil
            
            if tableExists(db, name: "episodes"), rowExists("episodes", id: visit.id, db: db) {
                let cols = columnSet(of: "episodes", db: db)
                let mc  = pickColumn(["main_complaint","chief_complaint","complaint"], available: cols)
                let pb  = pickColumn(["problem_listing","problem_list","problems"], available: cols)
                let dx  = pickColumn(["diagnosis","final_diagnosis"], available: cols)
                let icd = pickColumn(["icd10","icd_10","icd"], available: cols)
                let con = pickColumn(["conclusions","conclusion","plan"], available: cols)

                let wanted = [mc, pb, dx, icd, con].compactMap { $0 }
                if !wanted.isEmpty {
                    var stmt: OpaquePointer?
                    defer { sqlite3_finalize(stmt) }
                    let sql = "SELECT " + wanted.joined(separator: ", ") + " FROM episodes WHERE id=? LIMIT 1;"
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                        sqlite3_bind_int64(stmt, 1, sqlite3_int64(visit.id))
                        if sqlite3_step(stmt) == SQLITE_ROW {
                            var idx = 0
                            func nextString() -> String? {
                                defer { idx += 1 }
                                if let c = sqlite3_column_text(stmt, Int32(idx)) {
                                    let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                                    return s.isEmpty ? nil : s
                                }
                                return nil
                            }
                            mainComplaint = mc  != nil ? nextString() : nil
                            problems      = pb  != nil ? nextString() : nil
                            diagnosis     = dx  != nil ? nextString() : nil
                            icd10         = icd != nil ? nextString() : nil
                            conclusions   = con != nil ? nextString() : nil
                        }
                    }
                }
            } else if tableExists(db, name: "well_visits"), rowExists("well_visits", id: visit.id, db: db) {
                let cols = columnSet(of: "well_visits", db: db)
                let pb  = pickColumn(["problem_listing","problem_list","problems"], available: cols)
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
                            if pb != nil {
                                if let c = sqlite3_column_text(stmt, Int32(idx)) {
                                    let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                                    problems = s.isEmpty ? nil : s
                                }
                                idx += 1
                            }
                            if con != nil {
                                if let c = sqlite3_column_text(stmt, Int32(idx)) {
                                    let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                                    conclusions = s.isEmpty ? nil : s
                                }
                            }
                        }
                    }
                }
            }
            
            self.visitSummary = VisitSummary(
                mainComplaint: mainComplaint,
                problems: problems,
                diagnosis: diagnosis,
                icd10: icd10,
                conclusions: conclusions
            )
        }

        /// Load full details for a selected visit. Uses current bundle DB and the currently selected patient id.
        func loadVisitDetails(for visit: VisitRow) {
            guard let dbURL = currentDBURL,
                  FileManager.default.fileExists(atPath: dbURL.path) else {
                DispatchQueue.main.async { self.visitDetails = nil }
                return
            }
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db else {
                DispatchQueue.main.async { self.visitDetails = nil }
                return
            }
            defer { sqlite3_close(db) }

            // --- Patient snapshot (from current selection) ---
            let pid: Int? = self.selectedPatientID
            var patientName = "Anon Patient"
            var patientDOB: String? = nil
            var patientSex: String? = nil
            if let pid {
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                if sqlite3_prepare_v2(db, "SELECT TRIM(COALESCE(first_name,'')||' '||COALESCE(last_name,'')) AS name, dob, sex FROM patients WHERE id=? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmt, 1, sqlite3_int64(pid))
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        if let c = sqlite3_column_text(stmt, 0) {
                            let s = String(cString: c).trimmingCharacters(in: .whitespaces)
                            if !s.isEmpty { patientName = s }
                        }
                        if let c = sqlite3_column_text(stmt, 1) {
                            let s = String(cString: c).trimmingCharacters(in: .whitespaces)
                            patientDOB = s.isEmpty ? nil : s
                        }
                        if let c = sqlite3_column_text(stmt, 2) {
                            let s = String(cString: c).trimmingCharacters(in: .whitespaces)
                            patientSex = s.isEmpty ? nil : s
                        }
                    }
                }
            }

            // --- Visit core text fields ---
            func tableExists(_ name: String) -> Bool {
                let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=? LIMIT 1;"
                var s: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return false }
                defer { sqlite3_finalize(s) }
                _ = name.withCString { c in sqlite3_bind_text(s, 1, c, -1, SQLITE_TRANSIENT) }
                return sqlite3_step(s) == SQLITE_ROW
            }
            func colSet(_ table: String) -> Set<String> {
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
            func pick(_ cands: [String], _ avail: Set<String>) -> String? {
                for c in cands where avail.contains(c) { return c }
                return nil
            }
            func rowExists(_ table: String, id: Int) -> Bool {
                var s: OpaquePointer?
                defer { sqlite3_finalize(s) }
                guard sqlite3_prepare_v2(db, "SELECT 1 FROM \(table) WHERE id=? LIMIT 1;", -1, &s, nil) == SQLITE_OK else { return false }
                sqlite3_bind_int64(s, 1, sqlite3_int64(id))
                return sqlite3_step(s) == SQLITE_ROW
            }

            var mainComplaint: String? = nil
            var problems: String? = nil
            var diagnosis: String? = nil
            var icd10: String? = nil
            var conclusions: String? = nil
            var milestonesSummary: String? = nil

            // Prefer unified `visits` if present
            if tableExists("visits") {
                let cols = colSet("visits")
                let mc  = pick(["main_complaint","chief_complaint","complaint"], cols)
                let pb  = pick(["problem_listing","problem_list","problems"], cols)
                let dx  = pick(["diagnosis","final_diagnosis"], cols)
                let icd = pick(["icd10","icd_10","icd"], cols)
                let con = pick(["conclusions","conclusion","plan"], cols)
                let sel = [mc,pb,dx,icd,con].compactMap{$0}
                if !sel.isEmpty {
                    var s: OpaquePointer?
                    defer { sqlite3_finalize(s) }
                    let sql = "SELECT " + sel.joined(separator: ", ") + " FROM visits WHERE id=? LIMIT 1;"
                    if sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK {
                        sqlite3_bind_int64(s, 1, sqlite3_int64(visit.id))
                        if sqlite3_step(s) == SQLITE_ROW {
                            var idx: Int32 = 0
                            func nextStr() -> String? {
                                defer { idx += 1 }
                                if let c = sqlite3_column_text(s, idx) {
                                    let v = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                                    return v.isEmpty ? nil : v
                                }
                                return nil
                            }
                            mainComplaint = mc  != nil ? nextStr() : nil
                            problems      = pb  != nil ? nextStr() : nil
                            diagnosis     = dx  != nil ? nextStr() : nil
                            icd10         = icd != nil ? nextStr() : nil
                            conclusions   = con != nil ? nextStr() : nil
                        }
                    }
                }
            } else if tableExists("episodes"), rowExists("episodes", id: visit.id) {
                let cols = colSet("episodes")
                let mc  = pick(["main_complaint","chief_complaint","complaint"], cols)
                let pb  = pick(["problem_listing","problem_list","problems"], cols)
                let dx  = pick(["diagnosis","final_diagnosis"], cols)
                let icd = pick(["icd10","icd_10","icd"], cols)
                let con = pick(["conclusions","conclusion","plan"], cols)
                let sel = [mc,pb,dx,icd,con].compactMap{$0}
                if !sel.isEmpty {
                    var s: OpaquePointer?
                    defer { sqlite3_finalize(s) }
                    let sql = "SELECT " + sel.joined(separator: ", ") + " FROM episodes WHERE id=? LIMIT 1;"
                    if sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK {
                        sqlite3_bind_int64(s, 1, sqlite3_int64(visit.id))
                        if sqlite3_step(s) == SQLITE_ROW {
                            var idx: Int32 = 0
                            func nextStr() -> String? {
                                defer { idx += 1 }
                                if let c = sqlite3_column_text(s, idx) {
                                    let v = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                                    return v.isEmpty ? nil : v
                                }
                                return nil
                            }
                            mainComplaint = mc  != nil ? nextStr() : nil
                            problems      = pb  != nil ? nextStr() : nil
                            diagnosis     = dx  != nil ? nextStr() : nil
                            icd10         = icd != nil ? nextStr() : nil
                            conclusions   = con != nil ? nextStr() : nil
                        }
                    }
                }
            } else if tableExists("well_visits"), rowExists("well_visits", id: visit.id) {
                let cols = colSet("well_visits")
                let pb  = pick(["problem_listing","problem_list","problems"], cols)
                let con = pick(["conclusions","conclusion","plan"], cols)
                let sel = [pb,con].compactMap{$0}
                if !sel.isEmpty {
                    var s: OpaquePointer?
                    defer { sqlite3_finalize(s) }
                    let sql = "SELECT " + sel.joined(separator: ", ") + " FROM well_visits WHERE id=? LIMIT 1;"
                    if sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK {
                        sqlite3_bind_int64(s, 1, sqlite3_int64(visit.id))
                        if sqlite3_step(s) == SQLITE_ROW {
                            var idx: Int32 = 0
                            func nextStr() -> String? {
                                defer { idx += 1 }
                                if let c = sqlite3_column_text(s, idx) {
                                    let v = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                                    return v.isEmpty ? nil : v
                                }
                                return nil
                            }
                            problems    = pb  != nil ? nextStr() : nil
                            conclusions = con != nil ? nextStr() : nil
                        }
                    }
                }
                // Milestones summary if table present
                if tableExists("well_visit_milestones") {
                    var total = 0, achieved = 0
                    var flags: [String] = []
                    var s: OpaquePointer?
                    defer { sqlite3_finalize(s) }
                    if sqlite3_prepare_v2(db, "SELECT status,label FROM well_visit_milestones WHERE visit_id=?", -1, &s, nil) == SQLITE_OK {
                        sqlite3_bind_int64(s, 1, sqlite3_int64(visit.id))
                        while sqlite3_step(s) == SQLITE_ROW {
                            total += 1
                            let status: String = (sqlite3_column_text(s, 0).flatMap { String(cString: $0) }) ?? ""
                            let label:  String = (sqlite3_column_text(s, 1).flatMap { String(cString: $0) }) ?? ""
                            if status == "achieved" { achieved += 1 }
                            else if !label.trimmingCharacters(in: .whitespaces).isEmpty { flags.append(label) }
                        }
                    }
                    if total > 0 {
                        let prefix = "Achieved \(achieved)/\(total)"
                        if !flags.isEmpty {
                            milestonesSummary = prefix + "; Flags: " + flags.prefix(4).joined(separator: ", ")
                        } else {
                            milestonesSummary = prefix
                        }
                    }
                }
            }

            // --- Vitals: latest at or before visit date for this patient ---
            var latestVitals: VitalsPoint? = nil
            if let pid, !visit.dateISO.isEmpty {
                var s: OpaquePointer?
                defer { sqlite3_finalize(s) }
                let sql = """
                SELECT
                  id,
                  COALESCE(recorded_at,'') AS recorded_at,
                  temperature_c, heart_rate, respiratory_rate, spo2,
                  bp_systolic, bp_diastolic, weight_kg, height_cm, head_circumference_cm
                FROM vitals
                WHERE patient_id = ?
                  AND (recorded_at IS NULL OR recorded_at = '' OR datetime(recorded_at) <= datetime(?))
                ORDER BY datetime(COALESCE(recorded_at,'0001-01-01T00:00:00Z')) DESC, id DESC
                LIMIT 1;
                """
                if sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK {
                    sqlite3_bind_int64(s, 1, sqlite3_int64(pid))
                    _ = visit.dateISO.withCString { c in sqlite3_bind_text(s, 2, c, -1, SQLITE_TRANSIENT) }
                    if sqlite3_step(s) == SQLITE_ROW {
                        func intOpt(_ i: Int32) -> Int? {
                            let t = sqlite3_column_type(s, i)
                            return t == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, i))
                        }
                        func dblOpt(_ i: Int32) -> Double? {
                            let t = sqlite3_column_type(s, i)
                            return t == SQLITE_NULL ? nil : sqlite3_column_double(s, i)
                        }
                        func str(_ i: Int32) -> String {
                            if let c = sqlite3_column_text(s, i) { return String(cString: c) }
                            return ""
                        }
                        latestVitals = VitalsPoint(
                            id: Int(sqlite3_column_int64(s, 0)),
                            recordedAtISO: str(1),
                            temperatureC: dblOpt(2),
                            heartRate: intOpt(3),
                            respiratoryRate: intOpt(4),
                            spo2: intOpt(5),
                            bpSystolic: intOpt(6),
                            bpDiastolic: intOpt(7),
                            weightKg: dblOpt(8),
                            heightCm: dblOpt(9),
                            headCircumferenceCm: dblOpt(10)
                        )
                    }
                }
            }

            let details = VisitDetails(
                visit: visit,
                patientName: patientName,
                patientDOB: patientDOB,
                patientSex: patientSex,
                mainComplaint: mainComplaint,
                problems: problems,
                diagnosis: diagnosis,
                icd10: icd10,
                conclusions: conclusions,
                vitals: latestVitals,
                milestonesSummary: milestonesSummary
            )
            DispatchQueue.main.async {
                self.visitDetails = details
            }
        }
        
        @Published var perinatalHistory: PerinatalHistory? = nil

        // MARK: - Perinatal history (helpers wired to currentDBURL)

        /// Load perinatal history for the currently selected patient.
        func loadPerinatalHistoryForSelectedPatient() {
            guard let pid = selectedPatientID else {
                perinatalHistory = nil
                return
            }
            guard let dbURL = currentDBURL,
                  FileManager.default.fileExists(atPath: dbURL.path) else {
                perinatalHistory = nil
                return
            }
            do {
                let hist = try PerinatalStore.fetch(dbURL: dbURL, for: pid)
                self.perinatalHistory = hist
            } catch {
                self.perinatalHistory = nil
                log.error("Perinatal fetch failed: \(String(describing: error), privacy: .public)")
            }
        }

        /// Save (upsert) perinatal history for the currently selected patient, then refresh state.
        @discardableResult
        func savePerinatalHistoryForSelectedPatient(_ history: PerinatalHistory) -> Bool {
            guard let pid = selectedPatientID else { return false }
            guard let dbURL = currentDBURL,
                  FileManager.default.fileExists(atPath: dbURL.path) else { return false }
            do {
                try PerinatalStore.upsert(dbURL: dbURL, for: pid, history: history)
                // Refresh cache
                do {
                    let refreshed = try PerinatalStore.fetch(dbURL: dbURL, for: pid)
                    self.perinatalHistory = refreshed
                } catch {
                    log.warning("Perinatal refresh after upsert failed: \(String(describing: error), privacy: .public)")
                }
                return true
            } catch {
                log.error("Perinatal upsert failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }

        /// Backward-compat alias used elsewhere in AppState.
        func reloadPerinatalForActivePatient() {
            loadPerinatalHistoryForSelectedPatient()
        }

        // Legacy wrapper retained for older call-sites
        @discardableResult
        func savePerinatal(_ history: PerinatalHistory) throws -> Bool {
            if savePerinatalHistoryForSelectedPatient(history) {
                return true
            } else {
                throw NSError(domain: "AppState",
                              code: 500,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to save perinatal history"])
            }
        }

        // MARK: - Past Medical History (PMH)

        @Published var pastMedicalHistory: PastMedicalHistory? = nil

        /// Load PMH for the currently selected patient from the active bundle DB.
        func loadPMHForSelectedPatient() {
            guard let pid = selectedPatientID else {
                pastMedicalHistory = nil
                return
            }
            guard let dbURL = currentDBURL,
                  FileManager.default.fileExists(atPath: dbURL.path) else {
                pastMedicalHistory = nil
                return
            }
            do {
                let pmhStore = PmhStore()
                let pmh = try pmhStore.fetch(dbURL: dbURL, for: Int64(pid))
                self.pastMedicalHistory = pmh
            } catch {
                self.pastMedicalHistory = nil
                log.error("PMH fetch failed: \(String(describing: error), privacy: .public)")
            }
        }

        /// Save (upsert) PMH for the currently selected patient, then refresh cache.
        @discardableResult
        func savePMHForSelectedPatient(_ pmh: PastMedicalHistory) -> Bool {
            guard let pid = selectedPatientID else { return false }
            guard let dbURL = currentDBURL,
                  FileManager.default.fileExists(atPath: dbURL.path) else { return false }
            do {
                let pmhStore = PmhStore()
                try pmhStore.upsert(dbURL: dbURL, for: Int64(pid), history: pmh)
                // Refresh cache
                do {
                    let refreshed = try pmhStore.fetch(dbURL: dbURL, for: Int64(pid))
                    self.pastMedicalHistory = refreshed
                } catch {
                    log.warning("PMH refresh after upsert failed: \(String(describing: error), privacy: .public)")
                }
                return true
            } catch {
                log.error("PMH upsert failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }

        /// Backward-compat alias used elsewhere in AppState.
        func reloadPMHForActivePatient() {
            loadPMHForSelectedPatient()
        }

        /// Legacy wrapper retained for older call-sites.
        @discardableResult
        func savePMH(_ history: PastMedicalHistory) throws -> Bool {
            if savePMHForSelectedPatient(history) {
                return true
            } else {
                throw NSError(domain: "AppState",
                              code: 500,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to save PMH"])
            }
        }

    // MARK: - Vaccination Status (read/write on patients.vaccination_status)

    /// Return the vaccination_status for the currently selected patient (without mutating UI state).
    func getVaccinationStatusForSelectedPatient() -> String? {
        guard let pid = selectedPatientID,
              let dbURL = currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else {
            return nil
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db else {
            return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT vaccination_status FROM patients WHERE id=? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(pid))
        if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
            let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        return nil
    }

    /// Save vaccination_status for the selected patient and refresh profile/summary.
    @discardableResult
    func saveVaccinationStatusForSelectedPatient(_ status: String?) -> Bool {
        guard let pid = selectedPatientID,
              let dbURL = currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else {
            return false
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = db else {
            return false
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "UPDATE patients SET vaccination_status = ? WHERE id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            log.error("vaccination UPDATE prepare failed: \(msg, privacy: .public)")
            return false
        }
        if let status {
            _ = status.withCString { c in sqlite3_bind_text(stmt, 1, c, -1, SQLITE_TRANSIENT) }
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        sqlite3_bind_int64(stmt, 2, sqlite3_int64(pid))
        if sqlite3_step(stmt) != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            log.error("vaccination UPDATE step failed: \(msg, privacy: .public)")
            return false
        }
        // Refresh read-only panels
        self.loadPatientProfile(for: Int64(pid))
        self.loadPatientSummary(pid)
        return true
    }


    // MARK: - Episodes (create + edit window helpers)

    /// Clear any in-progress episode editing state (called on patient switch).
    func clearEpisodeEditing() {
        self.activeEpisodeID = nil
    }

    /// Set the currently active episode id for editing.
    func setActiveEpisode(_ id: Int?) {
        self.activeEpisodeID = id
    }

    /// Return true if the episode can still be edited (within 24 hours of `created_at`).
    /// Falls back to allowing edit when `created_at` is missing or unparsable.
    func canEditEpisode(_ episodeID: Int) -> Bool {
        guard let dbURL = currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else { return false }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db else {
            return false
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT COALESCE(created_at, '') FROM episodes WHERE id=? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(episodeID))

        var createdISO: String = ""
        if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
            createdISO = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if createdISO.isEmpty {
            // No timestamp → allow edit (we cannot enforce the window)
            return true
        }

        // Try to parse common ISO-8601 variants
        func parseISO(_ s: String) -> Date? {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            // Retry without fractional seconds
            let iso2 = ISO8601DateFormatter()
            iso2.formatOptions = [.withInternetDateTime]
            if let d = iso2.date(from: s) { return d }
            // Fallback to common SQLite CURRENT_TIMESTAMP format
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return df.date(from: s)
        }

        guard let createdAt = parseISO(createdISO) else {
            // Unparsable → allow edit rather than blocking
            return true
        }

        let elapsed = Date().timeIntervalSince(createdAt)
        return elapsed <= (24 * 60 * 60)
    }

    /// Create a minimal new episode row for the currently selected patient.
    /// Returns the new episode id on success. If an episode already exists *today* for the same patient+user
    /// and `force == false`, returns `nil` (UI can show a "Save Anyway" path).
    @discardableResult
    func startNewEpisode(force: Bool = false) -> Int? {
        guard let pid = selectedPatientID,
              let dbURL = currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else {
            return nil
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = db else {
            return nil
        }
        defer { sqlite3_close(db) }

        // If not forcing, guard against same-day duplicate for this clinician (if we have one)
        if !force {
            var checkStmt: OpaquePointer?
            defer { sqlite3_finalize(checkStmt) }
            let checkSQL = """
            SELECT id FROM episodes
            WHERE patient_id = ?
              AND (user_id IS NULL OR user_id = ?)
              AND date(COALESCE(created_at, CURRENT_TIMESTAMP)) = date(CURRENT_TIMESTAMP)
            LIMIT 1;
            """
            // If the check statement prepares successfully, enforce the same‑day constraint.
            // If preparation fails, skip the guard and proceed to insert.
            if sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(checkStmt, 1, sqlite3_int64(pid))
                if let uid = activeUserID {
                    sqlite3_bind_int64(checkStmt, 2, sqlite3_int64(uid))
                } else {
                    sqlite3_bind_null(checkStmt, 2)
                }
                if sqlite3_step(checkStmt) == SQLITE_ROW {
                    // Found an episode today; respect the constraint unless forced.
                    return nil
                }
            }
        }

        // Insert minimal row (let created_at default to CURRENT_TIMESTAMP)
        var ins: OpaquePointer?
        defer { sqlite3_finalize(ins) }
        let insertSQL = "INSERT INTO episodes (patient_id, user_id) VALUES (?, ?);"
        guard sqlite3_prepare_v2(db, insertSQL, -1, &ins, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_int64(ins, 1, sqlite3_int64(pid))
        if let uid = activeUserID {
            sqlite3_bind_int64(ins, 2, sqlite3_int64(uid))
        } else {
            sqlite3_bind_null(ins, 2)
        }
        guard sqlite3_step(ins) == SQLITE_DONE else {
            return nil
        }

        let newID = Int(sqlite3_last_insert_rowid(db))
        self.activeEpisodeID = newID
        // Keep the right pane lists fresh
        self.reloadVisitsForSelectedPatient()
        return newID
    }

        // MARK: - Growth data (writes)
        /// Add a manual growth point (one or more metrics) for the selected bundle DB.
        /// Returns the inserted row id in `manual_growth`.
        @discardableResult
        func addGrowthPointManual(
            patientID: Int,
            recordedAtISO: String,
            weightKg: Double?,
            heightCm: Double?,
            headCircumferenceCm: Double?,
            episodeID: Int?
        ) throws -> Int {
            guard let dbURL = currentDBURL,
                  FileManager.default.fileExists(atPath: dbURL.path) else {
                log.error("addGrowthPointManual: no current DB URL")
                throw NSError(domain: "AppState", code: 404, userInfo: [NSLocalizedDescriptionKey: "No active bundle DB"])
            }
            let newID = try GrowthStore().addManualGrowth(
                dbURL: dbURL,
                patientID: patientID,
                recordedAtISO: recordedAtISO,
                weightKg: weightKg,
                heightCm: heightCm,
                headCircumferenceCm: headCircumferenceCm,
                episodeID: episodeID
            )
            refreshGrowthAfterWrite(for: patientID)
            return newID
        }

        /// Delete a manual growth point if the provided `GrowthPoint` was manually entered.
        func deleteGrowthPointIfManual(_ gp: GrowthPoint) throws {
            guard gp.source.lowercased() == "manual" else {
                log.info("deleteGrowthPointIfManual: ignored non-manual source=\(gp.source, privacy: .public)")
                return
            }
            guard let dbURL = currentDBURL,
                  FileManager.default.fileExists(atPath: dbURL.path) else {
                log.error("deleteGrowthPointIfManual: no current DB URL")
                throw NSError(domain: "AppState", code: 404, userInfo: [NSLocalizedDescriptionKey: "No active bundle DB"])
            }
            try GrowthStore().deleteManualGrowth(dbURL: dbURL, id: gp.id)
            if let pid = selectedPatientID {
                refreshGrowthAfterWrite(for: pid)
            }
        }

        /// Light-weight broadcast to let charts re-query growth.
        private func refreshGrowthAfterWrite(for patientID: Int) {
            // If you already have a growth reload path, call it here.
            // This fallback posts a notification many views can observe.
            NotificationCenter.default.post(name: .init("com.pediai.growthDataChanged"),
                                            object: self,
                                            userInfo: ["patientID": patientID])
        }

        // Small safe index helper
        
        /// Import one or more bundle .zip files by unzipping to App Support and then detecting the bundle root (folder with db.sqlite)
        @MainActor
        func importZipBundles(from zipURLs: [URL]) {
            guard !zipURLs.isEmpty else { return }
            let fm = FileManager.default

            // Staging and archive roots
            let stagingRoot = self.ensureAppSupportSubdir("ImportedStaging")
            let archiveRoot = self.ensureAppSupportSubdir("Archive")

            for zipURL in zipURLs {
                do {
                    // Create a unique staging folder for this ZIP
                    let base = zipURL.deletingPathExtension().lastPathComponent
                    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                    let staged = stagingRoot.appendingPathComponent("\(base)-\(stamp)", isDirectory: true)
                    if fm.fileExists(atPath: staged.path) {
                        try fm.removeItem(at: staged)
                    }
                    try fm.createDirectory(at: staged, withIntermediateDirectories: true)

                    // Unzip to staging
                    try fm.unzipItem(at: zipURL, to: staged)

                    // Find the bundle root (folder containing db.sqlite)
                    guard let bundleRoot = self.findBundleRoot(startingAt: staged) else {
                        self.log.warning("ZIP import: no db.sqlite found under \(staged.path, privacy: .public)")
                        continue
                    }

                    // Extract patient identity from the staged bundle
                    guard let identity = self.extractPatientIdentity(from: bundleRoot) else {
                        self.log.warning("ZIP import: no identity (manifest/db) found under \(bundleRoot.path, privacy: .public) — registering as anonymous; duplicate detection skipped.")
                        if !self.bundleLocations.contains(bundleRoot) {
                            self.bundleLocations.append(bundleRoot)
                            self.addToRecents(bundleRoot)
                        }
                        continue
                    }

                    // Try to find an existing bundle that matches (MRN first, else alias+dob)
                    if let existingURL = self.existingBundleMatching(identity: identity) {
                        // Ask what to do when a patient already exists.
                        #if os(macOS)
                        let choice = self.presentImportConflictAlert(identity: identity, existingURL: existingURL)
                        switch choice {
                        case .replace:
                            if let finalURL = self.archiveAndReplace(existing: existingURL,
                                                                with: bundleRoot,
                                                                identity: identity,
                                                                archiveRoot: archiveRoot) {
                                if let idx = self.bundleLocations.firstIndex(of: existingURL) {
                                    self.bundleLocations[idx] = finalURL
                                }
                                self.addToRecents(finalURL)
                                self.log.info("Replaced existing bundle for \(self.identityString(identity), privacy: .public) at \(finalURL.path, privacy: .public)")
                            } else {
                                self.log.error("Failed to replace existing bundle for \(self.identityString(identity), privacy: .public)")
                            }

                        case .keepBoth:
                            // Register staged incoming as a separate bundle; no auto-select.
                            if !self.bundleLocations.contains(bundleRoot) {
                                self.bundleLocations.append(bundleRoot)
                            }
                            self.addToRecents(bundleRoot)
                            self.log.info("Kept both bundles for \(self.identityString(identity), privacy: .public). New at \(bundleRoot.path, privacy: .public)")

                        case .cancel:
                            // Drop this staged import.
                            try? fm.removeItem(at: bundleRoot)
                            self.log.info("Cancelled import for \(self.identityString(identity), privacy: .public)")
                            continue
                        }
                        #else
                        // Non-macOS fallback: keep previous behavior (replace).
                        if let finalURL = self.archiveAndReplace(existing: existingURL,
                                                            with: bundleRoot,
                                                            identity: identity,
                                                            archiveRoot: archiveRoot) {
                            if let idx = self.bundleLocations.firstIndex(of: existingURL) {
                                self.bundleLocations[idx] = finalURL
                            }
                            self.addToRecents(finalURL)
                        }
                        #endif
                    } else {
                        // New patient bundle: register it but DO NOT auto-select
                        if !self.bundleLocations.contains(bundleRoot) {
                            self.bundleLocations.append(bundleRoot)
                        }
                        self.addToRecents(bundleRoot)
                        self.log.info("Imported new bundle (no auto-select): \(self.identityString(identity), privacy: .public) at \(bundleRoot.path, privacy: .public)")
                    }

                    // Cleanup: remove staging parent if it is empty (best-effort)
                    do {
                        let contents = try fm.contentsOfDirectory(atPath: staged.path)
                        if contents.isEmpty {
                            try fm.removeItem(at: staged)
                        }
                    } catch {
                        // benign
                    }
                } catch {
                    self.log.error("ZIP import failed for \(zipURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            // IMPORTANT: We do NOT change currentBundleURL or selectedPatientID here.
            // The UI remains on the current patient/bundle to avoid confusing focus changes.
        }
        
        #if os(macOS)
        private enum ImportChoice { case replace, keepBoth, cancel }

        @MainActor
        private func presentImportConflictAlert(identity: PatientIdentity, existingURL: URL) -> ImportChoice {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Patient already exists"
            alert.informativeText = "Found an existing bundle for \(identityString(identity)).\nWhat would you like to do?"
            alert.addButton(withTitle: "Replace")   // 1
            alert.addButton(withTitle: "Keep Both") // 2
            alert.addButton(withTitle: "Cancel")    // 3
            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:  return .replace
            case .alertSecondButtonReturn: return .keepBoth
            default:                       return .cancel
            }
        }
        #endif

        // MARK: - Import reconciliation helpers (MRN-first; alias+dob fallback)

        private struct PatientIdentity: Equatable {
            let mrn: String?
            let alias: String?
            let dobISO: String?

            // Equality: prefer MRN if present on both; else alias+dob; else alias
            static func == (lhs: PatientIdentity, rhs: PatientIdentity) -> Bool {
                let lmrn = lhs.mrn?.trimmingCharacters(in: .whitespacesAndNewlines)
                let rmrn = rhs.mrn?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let l = lmrn, !l.isEmpty, let r = rmrn, !r.isEmpty {
                    return l.caseInsensitiveCompare(r) == .orderedSame
                }
                let la = (lhs.alias ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let ra = (rhs.alias ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var ldob = (lhs.dobISO ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var rdob = (rhs.dobISO ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // Normalize YYYY-MM-DD if possible (tolerate full ISO)
                if let t = ldob.split(separator: "T").first { ldob = String(t) }
                if let t = rdob.split(separator: "T").first { rdob = String(t) }
                if !la.isEmpty, !ra.isEmpty, !ldob.isEmpty, !rdob.isEmpty {
                    return la.caseInsensitiveCompare(ra) == .orderedSame && ldob == rdob
                }
                if !la.isEmpty, !ra.isEmpty {
                    return la.caseInsensitiveCompare(ra) == .orderedSame
                }
                return false
            }
        }

        private func identityString(_ id: PatientIdentity) -> String {
            if let mrn = id.mrn, !mrn.isEmpty { return "MRN \(mrn)" }
            var parts: [String] = []
            if let a = id.alias, !a.isEmpty { parts.append(a) }
            if let d = id.dobISO, !d.isEmpty {
                let day = d.split(separator: "T").first.map(String.init) ?? d
                parts.append(day)
            }
            return parts.isEmpty ? "UnknownPatient" : parts.joined(separator: " • ")
        }

    private func extractPatientIdentity(from bundleRoot: URL) -> PatientIdentity? {
        let fm = FileManager.default

        // 1) Prefer manifest.json at bundle root
        let manifestURL = bundleRoot.appendingPathComponent("manifest.json")
        if fm.fileExists(atPath: manifestURL.path) {
            do {
                let data = try Data(contentsOf: manifestURL)
                if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // v2 schema (preferred): explicit identity fields
                    let hasV2 = ((obj["format"] as? String)?.lowercased() == "pemr") || (obj["schema_version"] != nil)
                    if hasV2 {
                        let mrn = (obj["mrn"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let alias = ((obj["patient_alias"] as? String)
                                  ?? (obj["alias_label"] as? String)
                                  ?? (obj["alias"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines)
                        var dob = ((obj["dob"] as? String)
                                ?? (obj["date_of_birth"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let d = dob, let day = d.split(separator: "T").first { dob = String(day) }
                        if (mrn?.isEmpty == false) || (alias?.isEmpty == false) || (dob?.isEmpty == false) {
                            return PatientIdentity(mrn: mrn, alias: alias, dobISO: dob)
                        }
                    }
                    // Legacy "file list" manifest (v0/v1) without identity
                    if obj["files"] != nil {
                        self.log.info("extractPatientIdentity: legacy file-list manifest without identity at \(manifestURL.lastPathComponent, privacy: .public)")
                    }
                }
            } catch {
                self.log.warning("extractPatientIdentity: manifest.json parse failed at \(manifestURL.lastPathComponent, privacy: .public)")
            }
        }

        // 2) Folder-name heuristic as a last-resort identity (alias only)
        //    Examples: "Teal_Robin_-bundle.peMR-7-2025-11-13T01-49-38Z" or "Silver_Unicorn_🦊-2025-11-12_19-47-55.peMR"
        func aliasFromFolderName(_ name: String) -> String? {
            var cand = name
            // Strip extension marker like ".peMR" and anything after it
            if let r = cand.range(of: ".peMR", options: [.caseInsensitive]) {
                cand = String(cand[..<r.lowerBound])
            }
            // If a timestamp pattern is present (e.g., -2025-11-12...), chop from the first "-20"
            if let r = cand.range(of: "-20") { // crude but effective for our exported names
                cand = String(cand[..<r.lowerBound])
            }
            cand = cand.replacingOccurrences(of: "_", with: " ")
                       .trimmingCharacters(in: .whitespacesAndNewlines)
            // Keep something reasonable
            return cand.isEmpty ? nil : cand
        }
        if let guess = aliasFromFolderName(bundleRoot.lastPathComponent) {
            // Return minimal identity so we can still de-duplicate by alias if needed
            return PatientIdentity(mrn: nil, alias: guess, dobISO: nil)
        }

        // 3) Fallback: probe db.sqlite for identity (works even if manifest is missing)
        let dbURL = bundleRoot.appendingPathComponent("db.sqlite")
        guard fm.fileExists(atPath: dbURL.path) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        let cols = columnSet(of: "patients", db: db)
        guard !cols.isEmpty else { return nil }

        let mrnCol = cols.contains("mrn") ? "mrn" : nil
        let aliasCol = cols.contains("alias_label") ? "alias_label" : (cols.contains("alias") ? "alias" : nil)
        let dobCol = cols.contains("dob") ? "dob" : nil

        var sql = "SELECT "
        var wanted: [String] = []
        if let mrnCol { wanted.append(mrnCol) }
        if let aliasCol { wanted.append(aliasCol) }
        if let dobCol { wanted.append(dobCol) }
        if wanted.isEmpty { return nil }
        sql += wanted.joined(separator: ", ")
        sql += " FROM patients ORDER BY id LIMIT 1;"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        var idx: Int32 = 0
        func nextStr() -> String? {
            defer { idx += 1 }
            if let c = sqlite3_column_text(stmt, idx) {
                let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? nil : s
            }
            return nil
        }
        let mrn  = mrnCol  != nil ? nextStr() : nil
        let alias = aliasCol != nil ? nextStr() : nil
        var dob  = dobCol  != nil ? nextStr() : nil
        if let d = dob, let day = d.split(separator: "T").first { dob = String(day) }

        return PatientIdentity(mrn: mrn, alias: alias, dobISO: dob)
    }

        private func existingBundleMatching(identity: PatientIdentity) -> URL? {
            for url in bundleLocations {
                guard let other = extractPatientIdentity(from: url) else { continue }
                if other == identity { return url }
            }
            return nil
        }

        private func safeName(from id: PatientIdentity) -> String {
            var raw = identityString(id)
            if raw.isEmpty { raw = "UnknownPatient" }
            // sanitize for file system
            let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            return raw.components(separatedBy: illegal).joined(separator: "_")
        }

        /// Archive `existing` bundle into Archive/<patient>/ (keeping only one copy),
        /// then replace it with `incoming` bundle contents at the same path.
        private func archiveAndReplace(existing: URL,
                                       with incoming: URL,
                                       identity: PatientIdentity,
                                       archiveRoot: URL) -> URL? {
            let fm = FileManager.default
            do {
                let patientFolder = archiveRoot.appendingPathComponent(safeName(from: identity), isDirectory: true)
                if !fm.fileExists(atPath: patientFolder.path) {
                    try fm.createDirectory(at: patientFolder, withIntermediateDirectories: true)
                }
                // Keep only one archived copy: clear any existing content in that folder
                if let listed = try? fm.contentsOfDirectory(at: patientFolder, includingPropertiesForKeys: nil) {
                    for u in listed { try? fm.removeItem(at: u) }
                }
                // Move existing bundle into Archive/<patient>/previous.bundle
                let archivedURL = patientFolder.appendingPathComponent("previous.bundle", isDirectory: true)
                if fm.fileExists(atPath: archivedURL.path) {
                    try? fm.removeItem(at: archivedURL)
                }
                try fm.moveItem(at: existing, to: archivedURL)

                // Move incoming bundle into the *original* location (same parent / name as `existing`)
                let dest = existing
                if fm.fileExists(atPath: dest.path) {
                    try? fm.removeItem(at: dest)
                }
                try fm.moveItem(at: incoming, to: dest)
                return dest
            } catch {
                log.error("archiveAndReplace failed: \(String(describing: error), privacy: .public)")
                return nil
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
        let hasDB = fm.fileExists(atPath: start.appendingPathComponent("db.sqlite").path)
        let hasManifest = fm.fileExists(atPath: start.appendingPathComponent("manifest.json").path)
        if hasDB || hasManifest { return start }

        // Search subfolders
        if let en = fm.enumerator(at: start, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in en {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    let hasDB = fm.fileExists(atPath: url.appendingPathComponent("db.sqlite").path)
                    let hasManifest = fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path)
                    if hasDB || hasManifest { return url }
                }
            }
        }
        return nil
    }
        
        /// Add a new bundle root, make it selected, and refresh patients.
        @MainActor
        private func addBundleRootAndSelect(_ root: URL) {
            selectBundle(root.standardizedFileURL)
            PerinatalStore.dbURLResolver = { [weak self] in self?.currentDBURL }
            // Refresh perinatal and pmh cache for the newly selected bundle/patient context
            self.reloadPerinatalForActivePatient()
            self.loadPMHForSelectedPatient()
        }
        // MARK: - Create new patient/bundle
        /// Creates a new bundle folder with `db.sqlite`, `docs/`, and `manifest.json`,
        /// initializes the SQLite schema (minimal), seeds the initial patient row, and selects it.
        func createNewPatient(
            into parentFolder: URL,
            alias: String,
            firstName: String?,
            lastName: String?,
            fullName: String?,
            dob: Date?,
            sex: String?,
            aliasLabel overrideAliasLabel: String? = nil,
            aliasID overrideAliasID: String? = nil,
            mrnOverride: String? = nil
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
            // 3) Create and initialize SQLite from bundled mother DB if available; fall back to minimal schema.
            let dbURL = bundleURL.appendingPathComponent("db.sqlite")
            do {
                try copyGoldenDB(to: dbURL, overwrite: false)
                applyGoldenSchemaIdempotent(to: dbURL)     // idempotent migration pass
            } catch {
                // Fallback: create minimal schema then overlay schema.sql
                try initializeMinimalSchema(at: dbURL)
                applyGoldenSchemaIdempotent(to: dbURL)
            }
            // Ensure growth view/triggers exist (idempotent)
            ensureGrowthUnificationSchema(at: dbURL)


            // 4) Generate (or use provided) alias + MRN, then seed initial patient row
            //    We allow the sheet to preview and pass alias/mrn so what the user sees matches what gets saved.
            let generated: (label: String, id: String) = {
                if let l = overrideAliasLabel, let i = overrideAliasID, !l.isEmpty, !i.isEmpty {
                    return (l, i)
                }
                return AliasGenerator.generate()
            }()
            let aliasLabel = generated.label
            let aliasID    = generated.id

            // ISO DOB string for MRN & manifest
            let dobStr = dob.map {
                let df = DateFormatter()
                df.calendar = Calendar(identifier: .iso8601)
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = TimeZone(secondsFromGMT: 0)
                df.dateFormat = "yyyy-MM-dd"
                return df.string(from: $0)
            } ?? "0000-00-00"

            // If a precomputed MRN is provided, use it; else compute here
            let mrnValue = (mrnOverride?.isEmpty == false)
                ? mrnOverride!
                : MRNGenerator.generate(dobYYYYMMDD: dobStr, sex: (sex ?? ""), aliasID: aliasID)

            // Compose full_name if not provided, from first/last
            let composedFullName: String? = {
                if let fn = firstName?.trimmingCharacters(in: .whitespacesAndNewlines), !fn.isEmpty,
                   let ln = lastName?.trimmingCharacters(in: .whitespacesAndNewlines), !ln.isEmpty {
                    return "\(fn) \(ln)"
                }
                return fullName
            }()

            let insertedID = try insertInitialPatient(
                dbURL: dbURL,
                aliasLabel: aliasLabel,
                aliasID: aliasID,
                mrn: mrnValue,
                firstName: firstName,
                lastName: lastName,
                fullName: composedFullName,
                dob: dob,
                sex: sex
            )

            // 5) Compute integrity fields and write manifest v2 at root (no copy in docs/)
            // 5a) Determine inserted patient id to include in manifest
            let insertedPatientID = insertedID

            // 5b) Compute db.sqlite SHA-256
            let dbSha256 = sha256OfFile(at: dbURL)

            // 5c) Build docs manifest (relative paths under 'docs/')
            let docsManifest = buildDocsManifest(docsRoot: docsURL, bundleRoot: bundleURL)

            // 5d) Compose manifest (schema v2 as in PatientViewerApp)
            let iso = ISO8601DateFormatter()
            let nowISO = iso.string(from: Date())

            let manifest: [String: Any] = [
                "format": "peMR",
                "version": 1,                 // legacy key for older importers
                "schema_version": 2,          // hashes present
                "encrypted": false,
                "exported_at": nowISO,
                "source": "DrsMainApp",
                "includes_docs": !docsManifest.isEmpty,
                "patient_id": insertedPatientID,
                "patient_alias": aliasLabel,
                "mrn": mrnValue,
                "dob": dobStr,
                "patient_sex": sex ?? "",
                // Integrity fields
                "db_sha256": dbSha256,
                "docs_manifest": docsManifest  // array of { path, sha256 }
            ]

            let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try manifestData.write(to: bundleURL.appendingPathComponent("manifest.json"), options: .atomic)

            log.info("Created new bundle for \(safeAlias, privacy: .public) at \(bundleURL.path, privacy: .public)")

            // 6) Activate
            selectBundle(bundleURL)
            PerinatalStore.dbURLResolver = { [weak self] in self?.currentDBURL }
            self.loadPMHForSelectedPatient()
            return bundleURL
        }
    // MARK: - Golden schema idempotent helper

    /// Apply only idempotent, column-level fixes against the current DB to avoid duplicate-column spam.
    /// This is a strict no-op for bundle DBs; see rationale below.
    private func applyGoldenSchemaIdempotent(to dbURL: URL) {
        // Intentionally do nothing here.
        // Rationale:
        // - The patient bundle DB (golden schema) must remain decoupled from DrsMainApp private clinician data.
        // - Columns like title/email/societies/... belong in the separate internal clinicians DB managed by ClinicianStore.
        // - Any growth-related schema alignment is handled elsewhere by `ensureGrowthUnificationSchema(at:)`.
        return
    }

    // MARK: - Bundled Mother DB (golden.db) + schema.sql helpers

    /// Return the URL of the bundled golden.db inside Resources/DB if present.
    private func bundledGoldenDBURL() -> URL? {
        // Preferred path: Resources/DB/golden.db
        if let url = Bundle.main.url(forResource: "DB/golden", withExtension: "db") {
            return url
        }
        // Fallback if resources are flattened
        if let url = Bundle.main.url(forResource: "golden", withExtension: "db") {
            return url
        }
        return nil
    }

    /// Return the URL of the bundled schema.sql inside Resources/DB if present.
    private func bundledSchemaSQLURL() -> URL? {
        if let url = Bundle.main.url(forResource: "DB/schema", withExtension: "sql") {
            return url
        }
        if let url = Bundle.main.url(forResource: "schema", withExtension: "sql") {
            return url
        }
        return nil
    }

    /// Copy the bundled golden.db to a target db.sqlite path, overwriting if requested.
    private func copyGoldenDB(to targetDBURL: URL, overwrite: Bool = false) throws {
        let fm = FileManager.default
        guard let src = bundledGoldenDBURL() else {
            throw NSError(domain: "AppState", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "golden.db not found in bundle"])
        }
        if fm.fileExists(atPath: targetDBURL.path) {
            if overwrite {
                try fm.removeItem(at: targetDBURL)
            } else {
                return
            }
        }
        try fm.copyItem(at: src, to: targetDBURL)
    }

    /// Execute a .sql file (UTF-8) against a SQLite file on disk.
    private func applySQLFile(_ sqlURL: URL, to dbURL: URL) {
        guard let sqlText = try? String(contentsOf: sqlURL, encoding: .utf8) else { return }
        var db: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
            if let db { sqlite3_close(db) }
            return
        }
        defer { sqlite3_close(db) }

        // Split on semicolons, tolerate whitespace/comments.
        let statements = sqlText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("--") && !$0.hasPrefix("/*") }

        for stmt in statements {
            _ = sqlite3_exec(db, stmt + ";", nil, nil, nil)
        }
    }

    /// Convenience: apply bundled schema.sql to the given db (no-op if missing).
    private func applyBundledSchemaIfPresent(to dbURL: URL) {
        if let url = bundledSchemaSQLURL() {
            applySQLFile(url, to: dbURL)
        }
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
            // Also try to apply any bundled schema.sql for parity with the mother DB
            if let schemaURL = bundledSchemaSQLURL() {
                applySQLFile(schemaURL, to: dbURL)
            }
        }
        
        /// Insert the first patient row using a prepared statement.
        @discardableResult private func insertInitialPatient(
            dbURL: URL,
            aliasLabel: String,
            aliasID: String,
            mrn: String,
            firstName: String?,
            lastName: String?,
            fullName: String?,
            dob: Date?,
            sex: String?
        ) throws -> Int {
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
                        INSERT INTO patients (alias_label, alias_id, mrn, first_name, last_name, full_name, dob, sex)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                        """

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "SQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: "Prepare failed: \(msg)"])
            }
            defer { sqlite3_finalize(stmt) }

            // Bind parameters (1-based)
            _ = aliasLabel.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }  // alias_label
            _ = aliasID.withCString    { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }  // alias_id
            _ = mrn.withCString        { sqlite3_bind_text(stmt, 3, $0, -1, SQLITE_TRANSIENT) }  // mrn

            if let fn = firstName, !fn.isEmpty {
                _ = fn.withCString { sqlite3_bind_text(stmt, 4, $0, -1, SQLITE_TRANSIENT) }      // first_name
            } else {
                sqlite3_bind_null(stmt, 4)
            }

            if let ln = lastName, !ln.isEmpty {
                _ = ln.withCString { sqlite3_bind_text(stmt, 5, $0, -1, SQLITE_TRANSIENT) }      // last_name
            } else {
                sqlite3_bind_null(stmt, 5)
            }

            if let full = fullName, !full.isEmpty {
                _ = full.withCString { sqlite3_bind_text(stmt, 6, $0, -1, SQLITE_TRANSIENT) }    // full_name
            } else {
                sqlite3_bind_null(stmt, 6)
            }

            if let ds = dobStr {
                _ = ds.withCString { sqlite3_bind_text(stmt, 7, $0, -1, SQLITE_TRANSIENT) }      // dob
            } else {
                sqlite3_bind_null(stmt, 7)
            }

            if let sx = sex, !sx.isEmpty {
                _ = sx.withCString { sqlite3_bind_text(stmt, 8, $0, -1, SQLITE_TRANSIENT) }      // sex
            } else {
                sqlite3_bind_null(stmt, 8)
            }

            if let dobStr = dobStr {
                sqlite3_bind_text(stmt, 7, dobStr, -1, SQLITE_TRANSIENT)  // dob
            } else {
                sqlite3_bind_null(stmt, 7)
            }

            if let sex = sex, !sex.isEmpty {
                sqlite3_bind_text(stmt, 8, sex, -1, SQLITE_TRANSIENT)     // sex
            } else {
                sqlite3_bind_null(stmt, 8)
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "SQLite", code: 3, userInfo: [NSLocalizedDescriptionKey: "Insert failed: \(msg)"])
            }
            let newID = Int(sqlite3_last_insert_rowid(db))
            return newID
        }

        // MARK: - Manifest helpers

        /// Return SHA-256 hex of a file (empty string on error).
        private func sha256OfFile(at url: URL) -> String {
            guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
            defer { try? fh.close() }
            var hasher = SHA256()
            while autoreleasepool(invoking: {
                let chunk = fh.readData(ofLength: 64 * 1024)
                if chunk.count > 0 {
                    hasher.update(data: chunk)
                    return true
                } else {
                    return false
                }
            }) {}
            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        }

        /// Build docs manifest entries with relative paths (under 'docs/') and sha256.
        private func buildDocsManifest(docsRoot: URL, bundleRoot: URL) -> [[String: String]] {
            var entries: [[String: String]] = []
            let fm = FileManager.default
            guard fm.fileExists(atPath: docsRoot.path) else { return entries }
            if let en = fm.enumerator(at: docsRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in en {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                        let rel = url.path.replacingOccurrences(of: bundleRoot.path + "/", with: "")
                        entries.append([
                            "path": rel,
                            "sha256": sha256OfFile(at: url)
                        ])
                    }
                }
            }
            return entries
        }

        ///
        /// Write/refresh a v2 peMR manifest.json at the given bundle root.
        /// Safe to call before exporting a bundle; idempotent and tolerant of missing bits.
        @discardableResult
        func writeManifestV2(bundleRoot: URL) -> Bool {
            let fm = FileManager.default
            let dbURL = bundleRoot.appendingPathComponent("db.sqlite")
            let docsURL = bundleRoot.appendingPathComponent("docs", isDirectory: true)

            // Probe identity from DB if available
            var patientID: Int? = nil
            var mrn: String? = nil
            var aliasLabel: String? = nil
            var dobStr: String? = nil
            var sexStr: String? = nil

            if fm.fileExists(atPath: dbURL.path) {
                var db: OpaquePointer?
                if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                    defer { sqlite3_close(db) }
                    // Determine which columns exist
                    let cols = columnSet(of: "patients", db: db)
                    if !cols.isEmpty {
                        var wanted: [String] = ["id"]
                        if cols.contains("mrn") { wanted.append("mrn") }
                        if cols.contains("alias_label") { wanted.append("alias_label") }
                        else if cols.contains("alias") { wanted.append("alias AS alias_label") }
                        if cols.contains("dob") { wanted.append("dob") }
                        if cols.contains("sex") { wanted.append("sex") }
                        let sql = "SELECT " + wanted.joined(separator: ", ") + " FROM patients ORDER BY id LIMIT 1;"
                        var stmt: OpaquePointer?
                        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt {
                            defer { sqlite3_finalize(stmt) }
                            if sqlite3_step(stmt) == SQLITE_ROW {
                                var col = Int32(0)
                                patientID = Int(sqlite3_column_int64(stmt, col)); col += 1
                                if wanted.contains(where: { $0.hasPrefix("mrn") }) {
                                    if let c = sqlite3_column_text(stmt, col) { mrn = String(cString: c) }; col += 1
                                }
                                if wanted.contains(where: { $0.contains("alias_label") }) {
                                    if let c = sqlite3_column_text(stmt, col) { aliasLabel = String(cString: c) }; col += 1
                                }
                                if wanted.contains("dob") {
                                    if let c = sqlite3_column_text(stmt, col) { dobStr = String(cString: c) }; col += 1
                                }
                                if wanted.contains("sex") {
                                    if let c = sqlite3_column_text(stmt, col) { sexStr = String(cString: c) }; col += 1
                                }
                            }
                        }
                    }
                }
            }

            // Hash DB and build docs manifest
            let dbSha256 = fm.fileExists(atPath: dbURL.path) ? sha256OfFile(at: dbURL) : ""
            let docsManifest = buildDocsManifest(docsRoot: docsURL, bundleRoot: bundleRoot)

            // Compose v2 manifest
            let iso = ISO8601DateFormatter()
            let nowISO = iso.string(from: Date())

            var out: [String: Any] = [
                "format": "peMR",
                "version": 1,
                "schema_version": 2,
                "encrypted": false,
                "exported_at": nowISO,
                "source": "DrsMainApp",
                "includes_docs": !docsManifest.isEmpty,
                "db_sha256": dbSha256,
                "docs_manifest": docsManifest
            ]
            if let patientID { out["patient_id"] = patientID }
            if let mrn = mrn, !mrn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out["mrn"] = mrn }
            if let alias = aliasLabel, !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out["patient_alias"] = alias }
            if let dobStr = dobStr, !dobStr.isEmpty { out["dob"] = dobStr }
            if let sexStr = sexStr, !sexStr.isEmpty { out["patient_sex"] = sexStr }

            do {
                let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: bundleRoot.appendingPathComponent("manifest.json"), options: .atomic)
                return true
            } catch {
                log.error("writeManifestV2 failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }

        /// Convenience: refresh manifest.json for the currently selected bundle, if any.
        func refreshManifestV2ForCurrentBundle() {
            if let root = currentBundleURL { _ = writeManifestV2(bundleRoot: root) }
        }

        /// Get last inserted patient id from this DB (or throw).
        private func fetchLastInsertedPatientID(dbURL: URL) throws -> Int {
            var db: OpaquePointer?
            let path = dbURL.path
            if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
                let code = sqlite3_errcode(db)
                defer { sqlite3_close(db) }
                throw NSError(domain: "SQLite", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Open failed"])
            }
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT id FROM patients ORDER BY id DESC LIMIT 1;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "SQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: "Prepare failed: \(msg)"])
            }
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw NSError(domain: "SQLite", code: 3, userInfo: [NSLocalizedDescriptionKey: "No patient row found"])
            }
            return Int(sqlite3_column_int64(stmt, 0))
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
        @MainActor
        func importBundles(from urls: [URL]) {
            // Legacy wrapper: funnel all imports through the MRN-aware, prompt-enabled path.
            let zips = urls.filter { $0.pathExtension.lowercased() == "zip" }
            guard !zips.isEmpty else { return }
            self.importZipBundles(from: zips)
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

