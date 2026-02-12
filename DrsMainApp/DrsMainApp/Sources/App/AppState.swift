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

// MARK: - User-facing error surface (release testing)

struct AppUserError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Convenience alias so other files can reference the sidebar summary
/// type without qualifying it with `AppState.`.
typealias BundleSidebarSummary = AppState.BundleSidebarSummary

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

    /// Source table name used to disambiguate visit origin (episodes vs well_visits vs visits).
    /// This is critical for safe operations like soft-delete.
    let sourceTable: String

    /// Soft-delete flag from source table (0/1). Used for “Show deleted” + restore UI.
    let isDeleted: Bool

    /// Convenience initializer to keep call sites simple.
    init(id: Int, dateISO: String, category: String, sourceTable: String = "", isDeleted: Bool = false) {
        self.id = id
        self.dateISO = dateISO
        self.category = category
        self.sourceTable = sourceTable
        self.isDeleted = isDeleted
    }
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
        willSet {
            let oldID = self.selectedPatientID
            let newID = newValue
            if oldID != newID {
                log.info("selectedPatientID willSet: \(String(describing: oldID), privacy: .public) → \(String(describing: newID), privacy: .public)")
            }
        }
        didSet {
            
            // Avoid redundant work when the value hasn't actually changed.
            guard oldValue != selectedPatientID else {
                log.debug("selectedPatientID didSet: unchanged (\(String(describing: self.selectedPatientID), privacy: .public))")
                return
            }
            
            selectionDrivenProfileLoadDepth += 1
            defer { selectionDrivenProfileLoadDepth -= 1 }

            let t0 = Date()

            self.loadPerinatalHistoryForSelectedPatient()
            self.loadPMHForSelectedPatient()
            self.clearEpisodeEditing()

            if let pid = self.selectedPatientID {
                // Keep the readonly header/summary in sync with selection
                self.loadPatientProfile(for: Int64(pid))
                self.loadPatientSummary(pid)
                self.reloadVisitsForSelectedPatient()

                log.info("selectedPatientID didSet: loaded profile/summary/visits for pid=\(pid, privacy: .public) in \(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms")
            } else {
                self.currentPatientProfile = nil
                self.patientSummary = nil

                log.info("selectedPatientID didSet: cleared patient-specific state in \(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms")
            }
        }
    }
    
    // MARK: - User-facing error surface (release testing)

    enum UserErrorStatus: String {
        case none
        case present
        case seen
    }

    /// Tracks whether a user-facing error has occurred during this session.
    @Published var userErrorStatus: UserErrorStatus = .none

    /// Latest user-visible error (shown as an alert by the App root).
    @Published var lastError: AppUserError? = nil

    /// Log-safe hint about the most recent user-facing error (hashed; safe to include in support logs).
    @Published var lastErrorHint: String? = nil

    /// Dedicated logger for user-facing alert flow.
    private let alertLog = AppLog.feature("ui.alert")

    /// Present a simple user-facing error.
    func presentError(title: String, message: String) {
        // Keep PII out of logs: store only hashed/short tokens.
        let token = AppLog.token("\(title)|\(message)", length: 12)
        self.lastErrorHint = "token=\(token)"

        alertLog.error(
            "Presenting error alert token=\(token, privacy: .public) title=\(title, privacy: .private(mask: .hash)) msg=\(message, privacy: .private(mask: .hash))"
        )

        lastError = AppUserError(title: title, message: message)
        userErrorStatus = .present
    }

    /// Present an error with an optional context label.
    func presentError(_ error: Error, context: String? = nil) {
        let baseTitle = NSLocalizedString("app.error.title", comment: "Generic error alert title")
        let title = context.map { "\(baseTitle): \($0)" } ?? baseTitle
        let message = String(describing: error)

        // Keep PII out of logs: store only hashed/short tokens.
        let token = AppLog.token("\(title)|\(message)", length: 12)
        self.lastErrorHint = "token=\(token)"

        if let ctx = context, !ctx.isEmpty {
            alertLog.error(
                "Presenting error alert token=\(token, privacy: .public) ctx=\(ctx, privacy: .private(mask: .hash)) err=\(message, privacy: .private(mask: .hash))"
            )
        } else {
            alertLog.error(
                "Presenting error alert token=\(token, privacy: .public) err=\(message, privacy: .private(mask: .hash))"
            )
        }

        lastError = AppUserError(title: title, message: message)
        userErrorStatus = .present
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
    
    // Suppress noisy callstack logging when profile loads are triggered by patient selection.
    private var selectionDrivenProfileLoadDepth: Int = 0
    
    // Feature logger for patient profile (badge/header) loading.
    private let profileLog = AppLog.feature("patientProfile")
    // Clinicians: injected at init so AppState and Views share the same instance
    let clinicianStore: ClinicianStore

    // Well-visit data access layer (used by the macOS well-visit form)
    private let wellVisitStore = WellVisitStore()
    
    // The db.sqlite inside the currently selected bundle
    // (supports both <bundle>/db.sqlite and <bundle>/db/db.sqlite)
    var currentDBURL: URL? {
        dbURLForCurrentBundle()
    }
    // Apply schema upgrades at most once per selected bundle (idempotent but avoids extra work).
    private var schemaAppliedForBundlePath: String? = nil
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

    /// Ensure the current app-bundled schema (schema.sql) has been applied to this bundle DB.
    /// Generic: does not hardcode any table names; relies on schema.sql being idempotent.
    private func ensureBundledSchemaAppliedIfNeeded(dbURL: URL) {
        let bundlePath = (currentBundleURL?.standardizedFileURL.resolvingSymlinksInPath().path) ?? ""
        guard !bundlePath.isEmpty else { return }

        // Only apply once per selected bundle.
        if schemaAppliedForBundlePath == bundlePath {
            return
        }

        // Only apply when the DB file exists.
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            log.warning("ensureBundledSchemaAppliedIfNeeded: DB missing at \(dbURL.lastPathComponent, privacy: .public) for bundle \(bundlePath, privacy: .private)")
            return
        }

        schemaAppliedForBundlePath = bundlePath

        log.info("ensureBundledSchemaAppliedIfNeeded: applying bundled schema.sql (if present) to \(dbURL.lastPathComponent, privacy: .public)")

        // Bring older bundle DBs up to the current expected schema (tables + columns).
        // Generic: schema is defined by bundled `schema.sql`.
        applyBundledSchemaIfPresent(to: dbURL)

        // Keep existing idempotent helpers (some are intentional no-ops for bundle DBs).
        applyGoldenSchemaIdempotent(to: dbURL)
        
        // Soft-delete flags for visits (episodes + well_visits)
        ensureSoftDeleteVisitSchema(at: dbURL)

        // Growth unification objects (view + triggers + indexes)
        ensureGrowthUnificationSchema(at: dbURL)
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
    // Feature logger for AppState (bundle selection, patient/visit loading, etc.).
    private let log = AppLog.feature("appstate")
    
    // MARK: - Private
    private func loadRecentBundles() {
        let paths = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        recentBundles = paths.compactMap { URL(fileURLWithPath: $0) }

        // 👻 Kill ghosts at the source: remove dead/non-bundle entries immediately
        pruneRecentBundlesInPlace()
        persistRecentBundles()
    }

    private func refreshRecentBundlesFromDefaults() {
        let paths = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        recentBundles = paths.compactMap { URL(fileURLWithPath: $0) }

        // 👻 Same rule here: every refresh must prune + persist
        pruneRecentBundlesInPlace()
        persistRecentBundles()
    }

    // If you don't already have it:
    private func persistRecentBundles() {
        let paths = recentBundles.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        UserDefaults.standard.set(paths, forKey: recentsKey)
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
        
        profileLog.debug("loadPatientProfile: pid=\(patientID, privacy: .public) db=\(dbURL.lastPathComponent, privacy: .public)")
        #if DEBUG
        // Helps detect unexpected duplicate calls triggered by views (.task/.onAppear/.onChange).
        // Off by default: enable via UserDefaults key `debug.logCallstacks.loadPatientProfile` = true.
        if selectionDrivenProfileLoadDepth == 0,
           UserDefaults.standard.bool(forKey: "debug.logCallstacks.loadPatientProfile") {
            let stack = Thread.callStackSymbols.prefix(12).joined(separator: " | ")
            profileLog.debug("loadPatientProfile callstack: \(stack, privacy: .private)")
        }
        #endif
        let t0 = Date()
        
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            profileLog.error("sqlite3_open failed for \(dbURL.lastPathComponent, privacy: .public)")
            return
        }
        defer { sqlite3_close(db) }
        
        // From patients table
        let vacc = sqliteScalarText(db: db,
                                    sql: "SELECT vaccination_status FROM patients WHERE id=? LIMIT 1;",
                                    bindID: patientID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let yesText = NSLocalizedString("common.yes", comment: "Generic yes label")
        let noText  = NSLocalizedString("common.no", comment: "Generic no label")
        
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
                    if let v = intOpt(0), v != 0 {
                        parts.append(NSLocalizedString("appstate.profile.pmh.asthma_yes", comment: "PMH badge line: asthma present"))
                    }
                    if let v = intOpt(1), v != 0 {
                        parts.append(NSLocalizedString("appstate.profile.pmh.otitis_yes", comment: "PMH badge line: otitis present"))
                    }
                    if let v = intOpt(2), v != 0 {
                        parts.append(NSLocalizedString("appstate.profile.pmh.uti_yes", comment: "PMH badge line: UTI present"))
                    }
                    if let v = intOpt(3), v != 0 {
                        parts.append(NSLocalizedString("appstate.profile.pmh.allergies_yes", comment: "PMH badge line: allergies present"))
                    }
                    if let v = strOpt(5) {
                        parts.append(String(format: NSLocalizedString("appstate.profile.pmh.allergy_details_format", comment: "PMH badge line: allergy details"), v))
                    }
                    if let v = strOpt(4) {
                        parts.append(String(format: NSLocalizedString("appstate.profile.pmh.other_format", comment: "PMH badge line: other PMH"), v))
                    }
                    if let v = strOpt(6) {
                        parts.append(String(format: NSLocalizedString("appstate.profile.pmh.updated_format", comment: "PMH badge line: PMH last updated"), v))
                    }
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
                        return v == 0 ? noText : yesText
                    }

                    var parts: [String] = []
                    if let v = str(0)  { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.pregnancy_risk_format", comment: "Perinatal badge line: pregnancy risk"), v)) }
                    if let v = str(1)  { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.birth_mode_format", comment: "Perinatal badge line: birth mode"), v)) }
                    if let v = intOpt(2) { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.term_weeks_format", comment: "Perinatal badge line: term in weeks"), v)) }
                    if let v = str(3)  { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.resuscitation_format", comment: "Perinatal badge line: resuscitation"), v)) }
                    if let v = yn(4) {
                        parts.append(String(format: NSLocalizedString(
                            "appstate.profile.perinatal.nicu_stay_format",
                            comment: "Perinatal badge line: NICU stay (yes/no)"
                        ), v))
                    }
                    if let v = str(5)  { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.infection_risk_format", comment: "Perinatal badge line: infection risk"), v)) }
                    if let v = intOpt(6) { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.birth_weight_g_format", comment: "Perinatal badge line: birth weight in grams"), v)) }
                    if let v = realOpt(7) { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.birth_length_cm_format", comment: "Perinatal badge line: birth length in cm"), v)) }
                    if let v = realOpt(8) { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.birth_hc_cm_format", comment: "Perinatal badge line: birth head circumference in cm"), v)) }
                    if let v = str(9)  { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.maternity_events_format", comment: "Perinatal badge line: maternity stay events"), v)) }
                    if let v = str(10) { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.maternity_vaccinations_format", comment: "Perinatal badge line: maternity vaccinations"), v)) }
                    if let v = intOpt(11) {
                        let ynText = (v == 0) ? noText : yesText
                        parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.vitamin_k_format", comment: "Perinatal badge line: vitamin K given"), ynText))
                    }
                    if let v = str(12) { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.feeding_in_maternity_format", comment: "Perinatal badge line: feeding in maternity"), v)) }
                    if let v = yn(13)  { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.passed_meconium_24h_format", comment: "Perinatal badge line: passed meconium within 24h"), v)) }
                    if let v = yn(14)  { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.urination_24h_format", comment: "Perinatal badge line: urination within 24h"), v)) }
                    if let v = str(15) { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.heart_screening_format", comment: "Perinatal badge line: heart screening"), v)) }
                    if let v = str(16) { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.metabolic_screening_format", comment: "Perinatal badge line: metabolic screening"), v)) }
                    if let v = str(17) { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.hearing_screening_format", comment: "Perinatal badge line: hearing screening"), v)) }
                    if let v = str(18) { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.mother_vaccinations_format", comment: "Perinatal badge line: mother vaccinations"), v)) }
                    if let v = str(19) { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.family_vaccinations_format", comment: "Perinatal badge line: family vaccinations"), v)) }
                    if let v = str(20) { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.discharge_date_format", comment: "Perinatal badge line: maternity discharge date"), v)) }
                    if let v = intOpt(21) { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.discharge_weight_g_format", comment: "Perinatal badge line: discharge weight in grams"), v)) }
                    if let v = str(22) { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.illnesses_after_birth_format", comment: "Perinatal badge line: illnesses after birth"), v)) }
                    if let v = str(23) { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.updated_at_format", comment: "Perinatal badge line: updated at"), v)) }
                    if let v = str(24) { parts.append(String(format: NSLocalizedString("appstate.profile.perinatal.evolution_since_maternity_format", comment: "Perinatal badge line: evolution since maternity"), v)) }

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
            profileLog.debug("loadPatientProfile: pid=\(patientID, privacy: .public) done in \(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms")
        
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
        refreshRecentBundlesFromDefaults()
        let t0 = Date()

        let fm = FileManager.default
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        self.log.info("selectBundle: requested=\(AppLog.bundleRef(standardized))")

        guard fm.fileExists(atPath: standardized.path),
              let chosen = canonicalBundleRoot(at: standardized)?
                .standardizedFileURL
                .resolvingSymlinksInPath()
        else {
            self.log.info("selectBundle: dropping missing/non-bundle url \(AppLog.bundleRef(standardized))")
            self.recentBundles.removeAll { $0.standardizedFileURL.resolvingSymlinksInPath().path == standardized.path }
            pruneRecentBundlesInPlace()
            persistRecentBundles()
            self.presentError(
                title: NSLocalizedString("bundle.select.failed.title", comment: "User-facing title when bundle selection fails"),
                message: NSLocalizedString("bundle.select.failed.message", comment: "User-facing message when the selected bundle is missing or invalid")
            )
            self.log.info("selectBundle: finished (invalid selection) in \(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms")
            return
        }

        // `chosen` is already canonical because the guard unwraps via `canonicalBundleRoot(...)`.
        let canonicalRoot = chosen

        // ✅ Persist the canonical bundle root (not a wrapper folder)
        addToRecents(canonicalRoot)

        // ✅ Use canonical root everywhere
        currentBundleURL = canonicalRoot
        self.log.info("selectBundle: chosen=\(AppLog.bundleRef(canonicalRoot))")

        // Apply schema upgrades once per bundle, when the DB path is resolvable.
        if let dbURL = dbURLForCurrentBundle() {
            ensureBundledSchemaAppliedIfNeeded(dbURL: dbURL)
        } else {
            self.log.warning("selectBundle: no db.sqlite found yet under bundle \(AppLog.bundleRef(canonicalRoot))")
        }

        selectedPatientID = nil
        patients = []
        visits = []
        reloadPatients()
        reloadDocuments()
        self.log.info("selectBundle: loaded patients=\(self.patients.count, privacy: .public) docs=\(self.documents.count, privacy: .public) in \(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms")
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
        // If the DB disappeared, also clear selection.
        if selectedPatientID != nil {
            selectedPatientID = nil
        }
        return
    }
    ensureBundledSchemaAppliedIfNeeded(dbURL: dbURL)

    let previousSelection = selectedPatientID
    let t0 = Date()

    var db: OpaquePointer?
    guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        if let db { sqlite3_close(db) }
        patients = []
        if selectedPatientID != nil {
            selectedPatientID = nil
        }
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
        if selectedPatientID != nil {
            selectedPatientID = nil
        }
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

    // Keep selection stable:
    // - If there was no selection, auto-select first patient (if any).
    // - If there was a selection but it no longer exists, fall back to first (or nil).
    if let prev = previousSelection {
        let stillExists = rows.contains(where: { $0.id == prev })
        if !stillExists {
            let newSel = rows.first?.id
            if newSel != prev {
                self.selectedPatientID = newSel
            }
        }
    } else {
        if let first = rows.first {
            self.selectedPatientID = first.id
        } else if self.selectedPatientID != nil {
            self.selectedPatientID = nil
        }
    }

    log.debug("reloadPatients: rows=\(rows.count, privacy: .public) (prevSel=\(String(describing: previousSelection), privacy: .public)) in \(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms")
}
        
        // MARK: - Visits (read-only listing for current bundle)
        
        /// Reload visits for the currently selected patient (safe to call when no selection).
    func reloadVisitsForSelectedPatient() {
        guard let pid = selectedPatientID else {
            visits.removeAll()
            log.debug("reloadVisitsForSelectedPatient: no selected patient")
            return
        }
        let t0 = Date()
        loadVisits(for: pid)
        log.debug("reloadVisitsForSelectedPatient: pid=\(pid, privacy: .public) visits=\(self.visits.count, privacy: .public) in \(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms")
    }
    
    // MARK: - Soft delete visit (episodes / well_visits)

    /// Soft-delete a visit so it disappears from UI lists and exports.
    /// This only marks the row as deleted (is_deleted=1) and keeps data reversible.
    func softDeleteVisit(_ visit: VisitRow, reason: String? = nil) {
        // IMPORTANT: soft-delete is only supported for source tables that actually carry the columns.
        let table = visit.sourceTable
        guard table == "episodes" || table == "well_visits" else {
            log.error("softDeleteVisit: unsupported sourceTable=\(table, privacy: .public) id=\(visit.id, privacy: .public)")
            presentError(
                title: NSLocalizedString("visit.delete.failed.title", comment: "User-facing title when soft delete fails"),
                message: NSLocalizedString("visit.delete.failed.unsupported", comment: "User-facing message when soft delete is not supported for a visit")
            )
            return
        }

        guard let dbURL = currentDBURL, FileManager.default.fileExists(atPath: dbURL.path) else {
            log.error("softDeleteVisit: missing currentDBURL")
            presentError(
                title: NSLocalizedString("visit.delete.failed.title", comment: "User-facing title when soft delete fails"),
                message: NSLocalizedString("visit.delete.failed.no_db", comment: "User-facing message when no database is available")
            )
            return
        }

        // Ensure columns exist on older bundle DBs.
        // (Idempotent; safe to call.)
        ensureSoftDeleteVisitSchema(at: dbURL)

        var db: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
            if let db { sqlite3_close(db) }
            log.error("softDeleteVisit: sqlite open failed for \(dbURL.lastPathComponent, privacy: .public)")
            presentError(
                title: NSLocalizedString("visit.delete.failed.title", comment: "User-facing title when soft delete fails"),
                message: NSLocalizedString("visit.delete.failed.db_open", comment: "User-facing message when the database cannot be opened")
            )
            return
        }
        guard let db = db else { return }
        defer { sqlite3_close(db) }

        let sql = """
        UPDATE \(table)
        SET is_deleted = 1,
            deleted_at = CURRENT_TIMESTAMP,
            deleted_reason = ?
        WHERE id = ?;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            log.error("softDeleteVisit: prepare failed err=\(msg, privacy: .public)")
            presentError(
                title: NSLocalizedString("visit.delete.failed.title", comment: "User-facing title when soft delete fails"),
                message: msg
            )
            return
        }
        defer { sqlite3_finalize(stmt) }

        if let reason {
            sqlite3_bind_text(stmt, 1, reason, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        sqlite3_bind_int64(stmt, 2, sqlite3_int64(visit.id))

        if sqlite3_step(stmt) != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            log.error("softDeleteVisit: update failed err=\(msg, privacy: .public)")
            presentError(
                title: NSLocalizedString("visit.delete.failed.title", comment: "User-facing title when soft delete fails"),
                message: msg
            )
            return
        }

        log.info("softDeleteVisit: marked deleted table=\(table, privacy: .public) id=\(visit.id, privacy: .public)")

        // Refresh in-memory visit list so UI updates immediately.
        reloadVisitsForSelectedPatient()
    }

    /// Restore a previously soft-deleted visit.
    /// Inverse of `softDeleteVisit`: sets is_deleted=0 and clears deleted metadata.
    func restoreVisit(_ visit: VisitRow) {
        let table = visit.sourceTable
        guard table == "episodes" || table == "well_visits" else {
            log.error("restoreVisit: unsupported sourceTable=\(table, privacy: .public) id=\(visit.id, privacy: .public)")
            presentError(
                title: NSLocalizedString("visit.restore.failed.title", comment: "User-facing title when restore fails"),
                message: NSLocalizedString("visit.restore.failed.unsupported", comment: "User-facing message when restore is not supported for a visit")
            )
            return
        }

        guard let dbURL = currentDBURL, FileManager.default.fileExists(atPath: dbURL.path) else {
            log.error("restoreVisit: missing currentDBURL")
            presentError(
                title: NSLocalizedString("visit.restore.failed.title", comment: "User-facing title when restore fails"),
                message: NSLocalizedString("visit.restore.failed.no_db", comment: "User-facing message when no database is available")
            )
            return
        }

        // Ensure columns exist on older bundle DBs (idempotent).
        ensureSoftDeleteVisitSchema(at: dbURL)

        var db: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
            if let db { sqlite3_close(db) }
            log.error("restoreVisit: sqlite open failed for \(dbURL.lastPathComponent, privacy: .public)")
            presentError(
                title: NSLocalizedString("visit.restore.failed.title", comment: "User-facing title when restore fails"),
                message: NSLocalizedString("visit.restore.failed.db_open", comment: "User-facing message when the database cannot be opened")
            )
            return
        }
        guard let db = db else { return }
        defer { sqlite3_close(db) }

        let sql = """
        UPDATE \(table)
        SET is_deleted = 0,
            deleted_at = NULL,
            deleted_reason = NULL
        WHERE id = ?;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            log.error("restoreVisit: prepare failed err=\(msg, privacy: .public)")
            presentError(
                title: NSLocalizedString("visit.restore.failed.title", comment: "User-facing title when restore fails"),
                message: msg
            )
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sqlite3_int64(visit.id))

        if sqlite3_step(stmt) != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            log.error("restoreVisit: update failed err=\(msg, privacy: .public)")
            presentError(
                title: NSLocalizedString("visit.restore.failed.title", comment: "User-facing title when restore fails"),
                message: msg
            )
            return
        }

        log.info("restoreVisit: restored table=\(table, privacy: .public) id=\(visit.id, privacy: .public)")
        reloadVisitsForSelectedPatient()
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
        func loadVisits(for patientID: Int, includeDeleted: Bool = false) {
        
            visits.removeAll()
            guard let dbURL = dbURLForCurrentBundle(),
                  FileManager.default.fileExists(atPath: dbURL.path) else {
                return
            }
            let t0 = Date()
            log.debug("loadVisits: pid=\(patientID, privacy: .public) start db=\(dbURL.lastPathComponent, privacy: .public)")
            
            
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
            let categoryCandidates = ["category", "kind", "type"]
            let wellTypeCandidates = [
                "visit_type", "well_visit_type", "milestone_key", "visit_key", "visitCode", "visit_code"
            ]
            
            // 1) If a unified `visits` table exists and has required columns, use it.
            if tableExists(db, name: "visits") {
                let cols = columnSet(of: "visits", db: db)
                if let pidCol = pickColumn(pidCandidates, available: cols),
                   let dateCol = pickColumn(dateCandidates, available: cols) {
                    
                    let catCol  = pickColumn(categoryCandidates, available: cols) // optional
                    let typeCol = pickColumn(wellTypeCandidates, available: cols) // optional

                    let notDeletedClause = (!includeDeleted && cols.contains("is_deleted")) ? " AND is_deleted = 0" : ""

                    let deletedExpr = cols.contains("is_deleted") ? "COALESCE(is_deleted,0)" : "0"

                    var sql = """
                          SELECT id, \(dateCol) AS dateISO,
                          """
                    
                    // Prefer visit_type for well visits (so list shows one_month/two_month/...).
                    // Keep episode rows as "episode" when category-like column says so.
                    if let typeCol {
                        // If category exists and explicitly says episode, keep it; otherwise prefer type.
                        if let catCol {
                            sql += "CASE WHEN LOWER(TRIM(\(catCol))) = 'episode' THEN 'episode' ELSE COALESCE(NULLIF(TRIM(\(typeCol)),''), COALESCE(NULLIF(TRIM(\(catCol)),''), '')) END AS category"
                        } else {
                            sql += "COALESCE(NULLIF(TRIM(\(typeCol)),''), '') AS category"
                        }
                    } else if let catCol {
                        sql += "COALESCE(NULLIF(TRIM(\(catCol)),''), '') AS category"
                    } else {
                        sql += "'' AS category"
                    }

                    sql += ", \(deletedExpr) AS isDeleted"
                    
                    sql += """
                       FROM visits
                       WHERE \(pidCol) = ?\(notDeletedClause)
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
                        let isDeleted = (Int(sqlite3_column_int64(stmt, 3)) != 0)
                        rows.append(VisitRow(id: id, dateISO: dateISO, category: category, sourceTable: "visits", isDeleted: isDeleted))
                    }
                    // Debug: surface unexpected categories (e.g., "test") without dumping sensitive content.
                    #if DEBUG
                    if !rows.isEmpty {
                        let cats = rows.map { $0.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                        let uniq = Array(Set(cats)).sorted()
                        if uniq.contains("test") {
                            // Log the first matching row to identify origin in the unified `visits` table.
                            if let r = rows.first(where: { $0.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "test" }) {
                                log.warning("loadVisits: found category=test in visits table | id=\(r.id, privacy: .public) date=\(r.dateISO, privacy: .public)")
                            } else {
                                log.warning("loadVisits: found category=test in visits table")
                            }
                        }
                        log.debug("loadVisits: categories(uniq)=\(uniq.joined(separator: ","), privacy: .public)")
                    }
                    #endif
                    self.visits = rows
                    log.debug("loadVisits: pid=\(patientID, privacy: .public) done rows=\(rows.count, privacy: .public) in \(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms")
                    if rows.isEmpty {
                        log.info("visits table present but no rows for patient \(patientID)")
                    }
                    return
                }
            }
            
            // 2) Else, dynamically union any visit-like tables that have (pid + date) columns.
            struct Part {
                let table: String
                let pidCol: String
                let dateCol: String
                let categoryExpr: String
                let deletedExpr: String
                let notDeletedClause: String
            }
            var parts: [Part] = []
            
            for t in tableCandidates where tableExists(db, name: t) {
                let cols = columnSet(of: t, db: db)
                guard let pidCol = pickColumn(pidCandidates, available: cols),
                      let dateCol = pickColumn(dateCandidates, available: cols) else { continue }

                let catCol  = pickColumn(categoryCandidates, available: cols)
                let typeCol = pickColumn(wellTypeCandidates, available: cols)

                // Always ensure we produce a stable category for downstream usage.
                // Episodes must be "episode".
                // Well visits should preserve their visit_type (one_month/two_month/...) when possible.
                let defaultCat = (t == "episodes") ? "'episode'" : ((t == "well_visits") ? "'well'" : "''")

                let categoryExpr: String
                if t == "well_visits", let typeCol {
                    categoryExpr = "COALESCE(NULLIF(TRIM(\(typeCol)),''), \(defaultCat))"
                } else if let catCol {
                    categoryExpr = "COALESCE(NULLIF(TRIM(\(catCol)),''), \(defaultCat))"
                } else {
                    categoryExpr = defaultCat
                }
                let notDeletedClause = (!includeDeleted && cols.contains("is_deleted")) ? " AND is_deleted = 0" : ""
                let deletedExpr = cols.contains("is_deleted") ? "COALESCE(is_deleted,0)" : "0"
                parts.append(Part(
                    table: t,
                    pidCol: pidCol,
                    dateCol: dateCol,
                    categoryExpr: categoryExpr,
                    deletedExpr: deletedExpr,
                    notDeletedClause: notDeletedClause
                ))
            }
            
            guard !parts.isEmpty else {
                let bundleName = dbURL.deletingLastPathComponent().lastPathComponent
                log.warning("No visit-like tables found for bundle at \(bundleName, privacy: .public)")
                return
            }
            
            // Build UNION ALL with placeholders.
            log.debug("loadVisits: using union over tables: \(parts.map{$0.table}.joined(separator: ","), privacy: .public)")
            let unionSQL = parts.map {
            """
            SELECT id, \($0.dateCol) AS dateISO, \($0.categoryExpr) AS category, \($0.deletedExpr) AS isDeleted, '\($0.table)' AS src
            FROM \($0.table)
            WHERE \($0.pidCol) = ?\($0.notDeletedClause)
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
                let isDeleted = (Int(sqlite3_column_int64(stmt, 3)) != 0)
                let srcTable = text(4)

                #if DEBUG
                let catNorm = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if catNorm == "test" {
                    log.warning("loadVisits: found category=test | src=\(srcTable, privacy: .public) id=\(id, privacy: .public) date=\(dateISO, privacy: .public)")
                }
                #endif

                rows.append(VisitRow(id: id, dateISO: dateISO, category: category, sourceTable: srcTable, isDeleted: isDeleted))
            }
            self.visits = rows
            log.debug("loadVisits: pid=\(patientID, privacy: .public) done rows=\(rows.count, privacy: .public) in \(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms")
            if rows.isEmpty {
                let tablesStr = parts.map { $0.table }.joined(separator: ", ")
                log.info("Visit-like tables exist but no rows matched patient \(patientID). Checked: \(tablesStr, privacy: .public)")
            }
        }
        
        // MARK: - Well visits (store-backed helpers)
        
        /// List well visits for the currently selected patient.
        /// Returns newest-first headers using WellVisitStore.
        func fetchWellVisitHeadersForSelectedPatient() -> [WellVisitHeader] {
            guard let pid = selectedPatientID,
                  let dbURL = currentDBURL,
                  FileManager.default.fileExists(atPath: dbURL.path) else {
                return []
            }
        
            do {
                return try wellVisitStore.fetchList(dbURL: dbURL, for: Int64(pid))
            } catch {
                log.error("WellVisitStore.fetchList failed: \(String(describing: error), privacy: .public)")
                return []
            }
        }
        
        /// Load a single well visit by id for editing.
        func loadWellVisit(id: Int64) -> WellVisit? {
            guard let dbURL = currentDBURL,
                  FileManager.default.fileExists(atPath: dbURL.path) else {
                return nil
            }
        
            do {
                return try wellVisitStore.fetch(dbURL: dbURL, id: id)
            } catch {
                log.error("WellVisitStore.fetch failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        
        /// Insert or update a well visit using a payload from the SwiftUI form.
        /// - If `existingID` is nil → INSERT and return new id
        /// - If `existingID` is non-nil → UPDATE and return same id if successful
        @discardableResult
        func upsertWellVisit(
            existingID: Int64?,
            payload: WellVisitPayload
        ) -> Int64? {
            guard let pid = selectedPatientID,
                  let dbURL = currentDBURL,
                  FileManager.default.fileExists(atPath: dbURL.path) else {
                return nil
            }
        
            do {
                let userID = activeUserID.map(Int64.init)
        
                if let id = existingID {
                    let ok = try wellVisitStore.update(dbURL: dbURL, id: id, payload: payload)
                    if ok {
                        // Keep the generic visits list in sync (episodes + well_visits)
                        reloadVisitsForSelectedPatient()
                        return id
                    } else {
                        return nil
                    }
                } else {
                    let newID = try wellVisitStore.insert(
                        dbURL: dbURL,
                        for: Int64(pid),
                        userID: userID,
                        payload: payload
                    )
                    // New row → refresh visit listing as well
                    reloadVisitsForSelectedPatient()
                    return newID
                }
            } catch {
                let message = String(describing: error)
                log.error("Save failed: \(message, privacy: .public)")
                return nil
            }
        }
        // MARK: - Visit kind helpers (avoid episodes vs well_visits id collisions)

        private let wellVisitTypeKeys: Set<String> = [
            "well",
            "one_month",
            "two_month",
            "four_month",
            "six_month",
            "nine_month",
            "twelve_month",
            "fifteen_month",
            "eighteen_month",
            "twentyfour_month",
            "thirty_month",
            "thirtysix_month",
            // Already used by the app even if not in VISIT_TITLES yet.
            "newborn_first",
            "four_year",
            "five_year"
        ]

        /// True if the list-category string should be treated as coming from `well_visits`.
        /// Accepts both the generic kind (`well`) and specific milestone keys.
        private func looksLikeWellVisitCategory(_ cat: String) -> Bool {
            if wellVisitTypeKeys.contains(cat) { return true }
            if cat.hasSuffix("_month") { return true }
            if cat.hasSuffix("_year") { return true }
            return false
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

        /// Safer existence check: if a patient-id-like column exists and a patientID is provided,
        /// require it to match to avoid cross-table id collisions (episodes vs well_visits).
        private func rowExistsForPatient(_ table: String, id: Int, patientID: Int?, db: OpaquePointer?) -> Bool {
            guard let db = db else { return false }

            // If we don't know the patient, fall back to id-only.
            guard let patientID = patientID else {
                return rowExists(table, id: id, db: db)
            }

            // If the table has a patient-id column, enforce it.
            let cols = columnSet(of: table, db: db)
            if let pidCol = pickColumn(["patient_id", "patient", "pid", "patientId", "patientID"], available: cols) {
                let sql = "SELECT 1 FROM \(table) WHERE id=? AND \(pidCol)=? LIMIT 1;"
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
                sqlite3_bind_int64(stmt, 1, sqlite3_int64(id))
                sqlite3_bind_int64(stmt, 2, sqlite3_int64(patientID))
                return sqlite3_step(stmt) == SQLITE_ROW
            }

            // Otherwise, fall back to id-only.
            return rowExists(table, id: id, db: db)
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
            let t0 = Date()
            log.debug("loadPatientSummary: pid=\(patientID, privacy: .public)")
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
                let perinatalKVFormat = NSLocalizedString(
                    "appstate.summary.perinatal.kv_format",
                    comment: "Patient summary: perinatal item like 'birth_weight: 3200'"
                )
                let perinatalSeparator = NSLocalizedString(
                    "appstate.summary.perinatal.separator",
                    comment: "Patient summary: separator between items in perinatal summary"
                )
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
                                            parts.append(String(format: perinatalKVFormat, selectCols[i], ": ", s))
                                        }
                                    }
                                }
                                if !parts.isEmpty { perinatal = parts.joined(separator: perinatalSeparator) }
                            }
                        }
                    }
                }
            }
            log.debug("loadPatientSummary: pid=\(patientID, privacy: .public) done in \(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms")
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
                            log.debug("loadVisits: using unified visits table")
                            return
                        }
                    }
                }
            }

            // New probe logic
            let cat = visit.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isWell = looksLikeWellVisitCategory(cat)
            let pid = selectedPatientID

            var problems: String? = nil
            var diagnosis: String? = nil
            var conclusions: String? = nil
            var mainComplaint: String? = nil
            var icd10: String? = nil

            if isWell {
                if tableExists(db, name: "well_visits"), rowExistsForPatient("well_visits", id: visit.id, patientID: pid, db: db) {
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
            } else if cat == "episode" {
                if tableExists(db, name: "episodes"), rowExistsForPatient("episodes", id: visit.id, patientID: pid, db: db) {
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
                }
            } else {
                // Unknown category (legacy): probe both, but patient-safe.
                if tableExists(db, name: "episodes"), rowExistsForPatient("episodes", id: visit.id, patientID: pid, db: db) {
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
                } else if tableExists(db, name: "well_visits"), rowExistsForPatient("well_visits", id: visit.id, patientID: pid, db: db) {
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
            let anonPatientName = NSLocalizedString(
                "appstate.visitdetails.patient.anonymous",
                comment: "Default patient name placeholder shown in visit details"
            )
            var patientName = anonPatientName
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
            func rowExists(_ table: String, id: Int, patientID: Int?) -> Bool {
                // If the table has a patient-id column, enforce it to avoid id collisions across tables.
                let cols = colSet(table)
                let pidCol = pick(["patient_id","patient","pid","patientId","patientID"], cols)

                var s: OpaquePointer?
                defer { sqlite3_finalize(s) }

                if let pidCol, let patientID {
                    let sql = "SELECT 1 FROM \(table) WHERE id=? AND \(pidCol)=? LIMIT 1;"
                    guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return false }
                    sqlite3_bind_int64(s, 1, sqlite3_int64(id))
                    sqlite3_bind_int64(s, 2, sqlite3_int64(patientID))
                    return sqlite3_step(s) == SQLITE_ROW
                } else {
                    let sql = "SELECT 1 FROM \(table) WHERE id=? LIMIT 1;"
                    guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return false }
                    sqlite3_bind_int64(s, 1, sqlite3_int64(id))
                    return sqlite3_step(s) == SQLITE_ROW
                }
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
            } else {
                let cat = visit.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let isWell = self.looksLikeWellVisitCategory(cat)

                if cat == "episode" {
                    if tableExists("episodes"), rowExists("episodes", id: visit.id, patientID: pid) {
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
                    }
                } else if isWell {
                    if tableExists("well_visits"), rowExists("well_visits", id: visit.id, patientID: pid) {
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
                                let achievedFormat = NSLocalizedString(
                                    "appstate.visitdetails.milestones.achieved_format",
                                    comment: "Milestones summary: achieved count format, e.g. 'Achieved 3/5'"
                                )
                                let flagsLabel = NSLocalizedString(
                                    "appstate.visitdetails.milestones.flags_label",
                                    comment: "Milestones summary label for flagged items, e.g. 'Flags:'"
                                )
                                let withFlagsFormat = NSLocalizedString(
                                    "appstate.visitdetails.milestones.summary_with_flags_format",
                                    comment: "Milestones summary: full line when flags exist. Example '%@; %@ %@'"
                                )
                                let flagsSeparator = NSLocalizedString(
                                    "appstate.visitdetails.milestones.flags_list_separator",
                                    comment: "Milestones summary: separator between flagged milestone labels"
                                )

                                let achievedText = String(format: achievedFormat, achieved, total)
                                if !flags.isEmpty {
                                    let joinedFlags = flags.prefix(4).joined(separator: flagsSeparator)
                                    milestonesSummary = String(format: withFlagsFormat, achievedText, flagsLabel, joinedFlags)
                                } else {
                                    milestonesSummary = achievedText
                                }
                            }
                        }
                    }
                } else {
                    // Unknown category (legacy): probe both, but patient-safe.
                    if tableExists("episodes"), rowExists("episodes", id: visit.id, patientID: pid) {
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
                    } else if tableExists("well_visits"), rowExists("well_visits", id: visit.id, patientID: pid) {
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
                                let achievedFormat = NSLocalizedString(
                                    "appstate.visitdetails.milestones.achieved_format",
                                    comment: "Milestones summary: achieved count format, e.g. 'Achieved 3/5'"
                                )
                                let flagsLabel = NSLocalizedString(
                                    "appstate.visitdetails.milestones.flags_label",
                                    comment: "Milestones summary label for flagged items, e.g. 'Flags:'"
                                )
                                let withFlagsFormat = NSLocalizedString(
                                    "appstate.visitdetails.milestones.summary_with_flags_format",
                                    comment: "Milestones summary: full line when flags exist. Example '%@; %@ %@'"
                                )
                                let flagsSeparator = NSLocalizedString(
                                    "appstate.visitdetails.milestones.flags_list_separator",
                                    comment: "Milestones summary: separator between flagged milestone labels"
                                )

                                let achievedText = String(format: achievedFormat, achieved, total)
                                if !flags.isEmpty {
                                    let joinedFlags = flags.prefix(4).joined(separator: flagsSeparator)
                                    milestonesSummary = String(format: withFlagsFormat, achievedText, flagsLabel, joinedFlags)
                                } else {
                                    milestonesSummary = achievedText
                                }
                            }
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
                let msg = NSLocalizedString(
                    "appstate.perinatal.save_failed",
                    comment: "Error message when saving perinatal history fails"
                )
                throw NSError(domain: "AppState",
                              code: 500,
                              userInfo: [NSLocalizedDescriptionKey: msg])
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
                let msg = NSLocalizedString(
                    "appstate.pmh.save_failed",
                    comment: "Error message when saving past medical history (PMH) fails"
                )
                throw NSError(domain: "AppState",
                              code: 500,
                              userInfo: [NSLocalizedDescriptionKey: msg])
            }
        }
    
        /// Convenience wrapper for AI context: return the patient's perinatal summary
        /// (if present) without mutating any UI state.
        func perinatalSummaryForSelectedPatient() -> String? {
            // 1) Prefer the legacy summary string if it exists and is non-empty.
            if let s = patientSummary?.perinatal?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty {
                return s
            }

            // 2) Otherwise, fall back to the structured perinatal cache (if loaded).
            // We intentionally use a best-effort string representation here to avoid
            // duplicating formatting logic; if PerinatalHistory later gains a dedicated
            // `summary`/`text` field, we can switch to that.
            if let hist = perinatalHistory {
                let s = String(describing: hist).trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? nil : s
            }

            return nil
        }

        /// Build a lightweight, human-readable PMH summary for AI/guideline use.
        /// Uses the boolean flags on `PastMedicalHistory` plus the free-text fields.
        func pmhSummaryForSelectedPatient() -> String? {
            guard let pmh = pastMedicalHistory else {
                return nil
            }

            // Localized labels and formats (used for AI/guideline context text)
            let condAsthma = NSLocalizedString(
                "appstate.ai.pmh.condition.asthma",
                comment: "PMH summary: condition label 'asthma'"
            )
            let condOtitis = NSLocalizedString(
                "appstate.ai.pmh.condition.recurrent_otitis",
                comment: "PMH summary: condition label 'recurrent otitis'"
            )
            let condUTI = NSLocalizedString(
                "appstate.ai.pmh.condition.uti",
                comment: "PMH summary: condition label 'urinary tract infection'"
            )
            let condAllergies = NSLocalizedString(
                "appstate.ai.pmh.condition.allergies",
                comment: "PMH summary: condition label 'allergies'"
            )

            let conditionsSeparator = NSLocalizedString(
                "appstate.ai.pmh.conditions.separator",
                comment: "PMH summary: separator between condition labels, e.g. '; '"
            )
            let partsSeparator = NSLocalizedString(
                "appstate.ai.pmh.parts.separator",
                comment: "PMH summary: separator between sentences/parts, e.g. ' '"
            )

            let pmhLineFormat = NSLocalizedString(
                "appstate.ai.pmh.line.pmh_format",
                comment: "PMH summary: full PMH line format, e.g. 'Past medical history: %@.'"
            )
            let allergyDetailsFormat = NSLocalizedString(
                "appstate.ai.pmh.line.allergy_details_format",
                comment: "PMH summary: allergy details line format, e.g. 'Allergy details: %@.'"
            )
            let otherPMHFormat = NSLocalizedString(
                "appstate.ai.pmh.line.other_pmh_format",
                comment: "PMH summary: other PMH line format, e.g. 'Other PMH: %@.'"
            )

            var conditions: [String] = []

            // Boolean flags → localized condition labels
            if (pmh.asthma ?? 0) != 0 {
                conditions.append(condAsthma)
            }
            if (pmh.otitis ?? 0) != 0 {
                conditions.append(condOtitis)
            }
            if (pmh.uti ?? 0) != 0 {
                conditions.append(condUTI)
            }
            if (pmh.allergies ?? 0) != 0 {
                conditions.append(condAllergies)
            }

            var parts: [String] = []

            if !conditions.isEmpty {
                let joined = conditions.joined(separator: conditionsSeparator)
                parts.append(String(format: pmhLineFormat, joined))
            }

            // Free-text allergy details (if present)
            if let allergyDetails = pmh.allergyDetails?.trimmingCharacters(in: .whitespacesAndNewlines),
               !allergyDetails.isEmpty {
                parts.append(String(format: allergyDetailsFormat, allergyDetails))
            }

            // Free-text 'other' PMH (if present)
            if let other = pmh.other?.trimmingCharacters(in: .whitespacesAndNewlines),
               !other.isEmpty {
                parts.append(String(format: otherPMHFormat, other))
            }

            let summary = parts.joined(separator: partsSeparator)

            return summary.isEmpty ? nil : summary
        }

        /// Convenience wrapper for AI context: return the patient's vaccination status
        /// (if present) without mutating any UI state.
        func vaccinationSummaryForSelectedPatient() -> String? {
            return getVaccinationStatusForSelectedPatient()
        }

        // MARK: - AI assistance (per-episode; stub state)

        /// Guideline flags derived for the active episode (local JSON rules will be wired later).
        @Published var aiGuidelineFlagsForActiveEpisode: [String] = []

        /// AI summaries per provider label (e.g., "OpenAI", "UpToDate"), for the active episode.
        /// For now this is populated by a local stub.
        @Published var aiSummariesForActiveEpisode: [String: String] = [:]
        /// AI summaries per provider/model for the active well visit (preventive context).
        /// Keys are provider/model labels (e.g. "gpt-4.1-mini", "local-stub").
        @Published var aiSummariesForActiveWellVisit: [String: String] = [:]
        /// Per-well-visit AI summaries, keyed by well_visit_id.
        @Published private(set) var aiSummariesByWellVisit: [Int: [String: String]] = [:]
        /// Optional ICD-10 code suggestion for the active episode (from AI/guidelines).
        /// This is not persisted yet; the clinician can choose to apply it into the episode form.
        @Published var icd10SuggestionForActiveEpisode: String? = nil
        /// All ICD-10-like codes detected in the latest AI summary for the active episode.
        /// Used by the UI to let the clinician pick one or more codes into the ICD-10 field.
        @Published var aiICD10CandidatesForActiveEpisode: [String] = []

        /// Optional resolver that lets the host app provide clinician-specific sick-visit JSON rules.
        /// This keeps AppState decoupled from ClinicianStore while still allowing per-doctor config.
        var sickRulesJSONResolver: (() -> String?)?

        /// Optional resolver that lets the host app provide the clinician-specific sick-visit AI prompt.
        /// This is typically bound to the active user's `aiSickPrompt` field.
        var sickPromptResolver: (() -> String?)?

        /// Optional resolver for clinician-specific well-visit AI prompt.
        /// This can be bound to a future `aiWellPrompt` field on the user profile.
        var wellPromptResolver: (() -> String?)?

        /// Optional resolver that yields an AI provider for sick episodes (per active clinician).
        /// This keeps AppState decoupled from concrete implementations like OpenAIProvider.
        var episodeAIProviderResolver: (() -> EpisodeAIProvider?)?

        /// Lightweight snapshot of the clinically relevant data we want to feed into
        /// guideline rules and AI prompts for a single sick visit.
        struct EpisodeAIContext {
            let patientID: Int
            let episodeID: Int
            let problemListing: String
            let complementaryInvestigations: String
            let vaccinationStatus: String?
            let perinatalSummary: String? = nil
            let pmhSummary: String?

            /// Patient age in days at the time of the episode (if known).
            /// This allows JSON rules to express age bands like 0–28d, 29–90d, etc.
            let patientAgeDays: Int? = nil

            /// Patient sex, normalized if possible to "male"/"female".
            /// JSON rules can then use `sex_in: ["male"]`, etc.
            let patientSex: String? = nil

            /// Maximum recorded temperature in °C around this episode (if available).
            /// Enables rules like `min_temp_c: 38.0` or `requires_fever: true`.
            let maxTempC: Double? = nil
        }
        /// Lightweight snapshot of the clinically relevant data we want to feed into
        /// AI prompts for a single *well* visit (preventive check).
        struct WellVisitAIContext {
            let patientID: Int
            let wellVisitID: Int
            let visitType: String          // e.g. "one_month", "six_month", "first_postnatal"
            let ageDays: Int?              // from well_visits.age_days, if available
            let problemListing: String     // snapshot from well_visits.problem_listing
            let perinatalSummary: String?  // consolidated perinatal history
            let pmhSummary: String?        // past medical history summary
            let vaccinationStatus: String? // vaccination summary

            // Optional, locally-computed growth trend evaluation (provided by the UI).
            let growthTrendSummary: String?      // human-readable summary (e.g., weight-for-age trend)
            let growthTrendIsFlagged: Bool?      // true if concerning / needs attention
            let growthTrendWindow: String?       // e.g. "from 4 months onward" or similar
            
            init(
                patientID: Int,
                wellVisitID: Int,
                visitType: String,
                ageDays: Int?,
                problemListing: String,
                perinatalSummary: String?,
                pmhSummary: String?,
                vaccinationStatus: String?,
                growthTrendSummary: String? = nil,
                growthTrendIsFlagged: Bool? = nil,
                growthTrendWindow: String? = nil
            ) {
                self.patientID = patientID
                self.wellVisitID = wellVisitID
                self.visitType = visitType
                self.ageDays = ageDays
                self.problemListing = problemListing
                self.perinatalSummary = perinatalSummary
                self.pmhSummary = pmhSummary
                self.vaccinationStatus = vaccinationStatus
                self.growthTrendSummary = growthTrendSummary
                self.growthTrendIsFlagged = growthTrendIsFlagged
                self.growthTrendWindow = growthTrendWindow
            }
        }

        /// Sanitize problem listing text before sending to AI:
        ///  - drop lines that look like they contain explicit identity labels (e.g. "Patient: ...")
        ///  - drop lines that contain template field names like "first_name"/"last_name"/"full_name".
        /// The goal is to keep the content clinically rich while avoiding identifiers.
        private func sanitizeProblemListingForAI(_ text: String) -> String {
            guard !text.isEmpty else { return text }

            let lines = text.components(separatedBy: .newlines)
            let filtered = lines.compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return nil }
                let lower = trimmed.lowercased()

                // Drop obvious identity lines
                if lower.hasPrefix("patient:") { return nil }
                if lower.hasPrefix("name:") { return nil }

                // Drop lines that reference raw identity field names from templates
                if lower.contains("first_name") { return nil }
                if lower.contains("last_name") { return nil }
                if lower.contains("full_name") { return nil }

                return trimmed
            }

            return filtered.joined(separator: "\n")
        }

        /// Clear AI state when switching patient, bundle, or active episode.
        func clearAIForEpisodeContext() {
            aiGuidelineFlagsForActiveEpisode = []
            aiSummariesForActiveEpisode = [:]
            icd10SuggestionForActiveEpisode = nil
        }
    
        
        /// Very lightweight heuristic ICD-10 suggestion based on free-text context.
        /// This is a stub used until real AI provider output is wired in.
        private func deriveICD10Suggestion(from context: EpisodeAIContext) -> String? {
            let combined = (context.problemListing + " " + context.complementaryInvestigations)
                .lowercased()

            func contains(_ needle: String) -> Bool {
                combined.contains(needle)
            }

            // Localized display strings (shown to clinicians as suggestions)
            let icdBronchiolitis = NSLocalizedString(
                "appstate.ai.icd10.bronchiolitis",
                comment: "ICD-10 suggestion string for bronchiolitis (code + short description)"
            )
            let icdPneumonia = NSLocalizedString(
                "appstate.ai.icd10.pneumonia",
                comment: "ICD-10 suggestion string for pneumonia (code + short description)"
            )
            let icdOtitis = NSLocalizedString(
                "appstate.ai.icd10.otitis",
                comment: "ICD-10 suggestion string for otitis media (code + short description)"
            )
            let icdAsthma = NSLocalizedString(
                "appstate.ai.icd10.asthma",
                comment: "ICD-10 suggestion string for asthma (code + short description)"
            )
            let icdDiarrhea = NSLocalizedString(
                "appstate.ai.icd10.diarrhea",
                comment: "ICD-10 suggestion string for diarrhea (code + short description)"
            )
            let icdUTI = NSLocalizedString(
                "appstate.ai.icd10.uti",
                comment: "ICD-10 suggestion string for UTI (code + short description)"
            )
            let icdFever = NSLocalizedString(
                "appstate.ai.icd10.fever",
                comment: "ICD-10 suggestion string for fever (code + short description)"
            )

            // NOTE: These are intentionally broad, best-effort mappings for fallback use only.
            if contains("bronchiolitis") {
                return icdBronchiolitis
            }
            if contains("pneumonia") {
                return icdPneumonia
            }
            if contains("otitis") || (contains("ear") && contains("pain")) {
                return icdOtitis
            }
            if contains("asthma") || contains("wheezing") {
                return icdAsthma
            }
            if contains("diarrhea") || contains("diarrhoea") {
                return icdDiarrhea
            }
            if contains("uti") || contains("urinary tract infection") || contains("cystitis") {
                return icdUTI
            }
            if contains("fever") {
                return icdFever
            }

            return nil
        }

        /// Temporary stub for local guideline flags.
        /// This is now intentionally minimal: it only reports that either
        /// no rules are configured or that none matched the current episode.
        func runGuidelineFlagsStub(using context: EpisodeAIContext) {
            // Localized stub messages
            let rulesLoaded = NSLocalizedString(
                "appstate.ai.guidelines.rules_loaded",
                comment: "Guideline stub message when rules JSON is present"
            )
            let noMatchFound = NSLocalizedString(
                "appstate.ai.guidelines.no_match",
                comment: "Guideline stub message when no guideline criteria matched"
            )
            let noRulesConfigured = NSLocalizedString(
                "appstate.ai.guidelines.no_rules_configured",
                comment: "Guideline stub message when no guideline rules are configured"
            )

            // Check whether any clinician-specific rules JSON appears to be configured.
            let hasRulesJSON: Bool = {
                if let raw = sickRulesJSONResolver?()?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !raw.isEmpty {
                    return true
                }
                return false
            }()

            if hasRulesJSON {
                aiGuidelineFlagsForActiveEpisode = [
                    rulesLoaded,
                    noMatchFound
                ]
            } else {
                aiGuidelineFlagsForActiveEpisode = [
                    noRulesConfigured
                ]
            }
        }

        /// Simple JSON-decodable container for guideline rules.
        /// Supports two shapes:
        ///   { "flags": [...], "rules": [ ... ] }
        /// The `flags` array is used as-is; `rules` are evaluated
        /// against the current EpisodeAIContext.
        private struct GuidelineRuleSet: Decodable {
            struct Rule: Decodable {
                struct Conditions: Decodable {
                    // -------- Text-based conditions --------

                    /// Substrings that should appear in the problem listing.
                    let problemContains: [String]?

                    /// Substrings that should appear in the complementary investigations text.
                    let investigationsContains: [String]?

                    /// Substrings that should appear in the PMH summary.
                    let pmhContains: [String]?

                    /// Substrings that should appear in the vaccination summary.
                    let vaccinationContains: [String]?

                    // -------- Numeric / categorical constraints --------
                    // These rely on JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase,
                    // so JSON keys such as `min_age_days` map onto `minAgeDays`, etc.

                    /// Minimum patient age in days (inclusive) for this rule to apply.
                    let minAgeDays: Int?

                    /// Maximum patient age in days (inclusive) for this rule to apply.
                    let maxAgeDays: Int?

                    /// Minimum maximum temperature in °C (inclusive).
                    let minTempC: Double?

                    /// Maximum maximum temperature in °C (inclusive).
                    let maxTempC: Double?

                    /// If true, the patient must be febrile (based on temperature and/or text).
                    let requiresFever: Bool?

                    /// Allowed sex values (case-insensitive), e.g. ["male"], ["female"], or
                    /// ["male","female"]. If nil/empty, sex is not constrained.
                    let sexIn: [String]?
                }

                let id: String?
                let description: String?
                let flag: String?
                let conditions: Conditions?
            }

            let flags: [String]?
            let rules: [Rule]?
        }
    
        /// Best-effort age parser from the problem listing text.
        /// Supports formats like:
        ///   "Age: 19 d"
        ///   "Age: 3 mo"
        ///   "Age: 1 y 4 mo"
        ///   "Age: 10 y"
        private func parseAgeDays(fromProblemListing listing: String) -> Int? {
            // Look for a line starting with "Age:"
            guard let ageLine = listing
                .split(separator: "\n")
                .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Age:") })
            else { return nil }

            let s = ageLine
                .replacingOccurrences(of: "Age:", with: "")
                .trimmingCharacters(in: .whitespaces)

            // 1) "19 d"
            if let r = s.range(of: "d") {
                let numStr = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                if let v = Int(numStr) { return v }
            }

            // 2) "3 mo"  → approx months → days
            if let r = s.range(of: "mo") {
                let numStr = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                if let m = Int(numStr) {
                    return m * 30
                }
            }

            // 3) "1 y 4 mo" or "10 y"
            if let rY = s.range(of: "y") {
                let yearsPart = s[..<rY.lowerBound].trimmingCharacters(in: .whitespaces)
                var totalDays = 0
                if let y = Int(yearsPart) {
                    totalDays += y * 365
                }
                if let rMo = s.range(of: "mo") {
                    let between = s[rY.upperBound..<rMo.lowerBound]
                    let moStr = between
                        .replacingOccurrences(of: "mo", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if let m = Int(moStr) {
                        totalDays += m * 30
                    }
                }
                return totalDays > 0 ? totalDays : nil
            }

            return nil
        }

        /// Best-effort max temperature parser from the "Abnormal vitals" line,
        /// expecting something like: "Abnormal vitals: T 38.5°C, HR ..."
        private func parseMaxTempC(fromProblemListing listing: String) -> Double? {
            guard let vitalsLine = listing
                .split(separator: "\n")
                .first(where: { $0.contains("Abnormal vitals:") })
            else { return nil }

            let s = String(vitalsLine)

            guard let rStart = s.range(of: "T "),
                  let rEnd = s.range(of: "°C", range: rStart.upperBound..<s.endIndex)
            else { return nil }

            let numStr = s[rStart.upperBound..<rEnd.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ",", with: ".")

            return Double(numStr)
        }

        /// Evaluate whether a rule's conditions match the given episode context.
        /// Empty/nil condition arrays are treated as "no constraint" for that field.
        private func ruleConditionsMatch(_ cond: GuidelineRuleSet.Rule.Conditions?, context: EpisodeAIContext) -> Bool {
            guard let cond = cond else {
                // No conditions at all → always match
                return true
            }

            func fieldContainsAny(_ needles: [String]?, in haystack: String?) -> Bool {
                // If there are no needles for this field, treat as unconstrained (pass-through).
                guard let needles = needles, !needles.isEmpty else { return true }
                guard let haystack = haystack?.lowercased(), !haystack.isEmpty else { return false }

                for raw in needles {
                    let needle = raw
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        .lowercased()
                    if !needle.isEmpty, haystack.contains(needle) {
                        return true
                    }
                }
                return false
            }

            // --- Derived numeric context (with fallbacks from text) ---

            // Prefer explicitly-populated values from EpisodeAIContext if ever
            // provided; otherwise derive them from the problemListing text.
            let effectiveAgeDays: Int? = {
                if let d = context.patientAgeDays {
                    return d
                }
                return parseAgeDays(fromProblemListing: context.problemListing)
            }()

            let effectiveMaxTempC: Double? = {
                if let t = context.maxTempC {
                    return t
                }
                return parseMaxTempC(fromProblemListing: context.problemListing)
            }()

            // --- 1) Text constraints ---
            let problemOK = fieldContainsAny(cond.problemContains, in: context.problemListing)
            let invOK     = fieldContainsAny(cond.investigationsContains, in: context.complementaryInvestigations)
            let pmhOK     = fieldContainsAny(cond.pmhContains, in: context.pmhSummary)
            let vaccOK    = fieldContainsAny(cond.vaccinationContains, in: context.vaccinationStatus)

            // --- 2) Age constraints (in days) ---
            let ageOK: Bool = {
                if cond.minAgeDays == nil && cond.maxAgeDays == nil {
                    // No age bounds at all → unconstrained.
                    return true
                }
                guard let ageDays = effectiveAgeDays else {
                    // Rule requires age info but we don't have it → rule cannot match.
                    return false
                }
                if let min = cond.minAgeDays, ageDays < min { return false }
                if let max = cond.maxAgeDays, ageDays > max { return false }
                return true
            }()

            // --- 3) Temperature constraints (max temp in °C) ---
            let tempOK: Bool = {
                if cond.minTempC == nil && cond.maxTempC == nil {
                    return true
                }
                guard let t = effectiveMaxTempC else {
                    // Rule requires temperature but none is available → no match.
                    return false
                }
                if let minT = cond.minTempC, t < minT { return false }
                if let maxT = cond.maxTempC, t > maxT { return false }
                return true
            }()

            // --- 4) Fever flag (requires_fever) ---
            let feverOK: Bool = {
                guard let requires = cond.requiresFever else {
                    // No explicit requirement → unconstrained.
                    return true
                }
                // Compute a simple fever flag:
                let hasFeverFromTemp: Bool = {
                    if let t = effectiveMaxTempC {
                        return t >= 38.0
                    }
                    return false
                }()
                let hasFeverFromText: Bool = {
                    let lower = context.problemListing.lowercased()
                    return lower.contains("fever") || lower.contains("febrile")
                }()
                let hasFever = hasFeverFromTemp || hasFeverFromText

                return requires ? hasFever : !hasFever
            }()

            // --- 5) Sex constraints ---
            let sexOK: Bool = {
                guard let allowed = cond.sexIn, !allowed.isEmpty else {
                    // No constraint on sex.
                    return true
                }

                // Try to get sex from context first, then fall back to parsing the problem listing
                // line "Sex: F" / "Sex: M" / "Sex: Male" / "Sex: Female".
                func parseSex(from listing: String) -> String? {
                    guard let sexLine = listing
                        .split(separator: "\n")
                        .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Sex:") })
                    else {
                        return nil
                    }

                    let raw = sexLine
                        .replacingOccurrences(of: "Sex:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if raw.isEmpty { return nil }

                    let lower = raw.lowercased()
                    if lower.hasPrefix("m") { return "male" }
                    if lower.hasPrefix("f") { return "female" }
                    return lower
                }

                // 1) Prefer any explicit sex passed in the context
                var candidate: String? = nil
                if let sexRaw = context.patientSex?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !sexRaw.isEmpty {
                    candidate = sexRaw
                } else {
                    // 2) Else, derive it from the problem listing
                    candidate = parseSex(from: context.problemListing)
                }

                guard let c = candidate, !c.isEmpty else {
                    // Rule constrains sex but we still don't know it → no match.
                    return false
                }

                // Normalize to "male"/"female" if possible
                let normSex: String = {
                    let lower = c.lowercased()
                    if lower.hasPrefix("m") { return "male" }
                    if lower.hasPrefix("f") { return "female" }
                    return lower
                }()

                let normAllowed = allowed.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }

                return normAllowed.contains(normSex)
            }()

            // All constrained dimensions must pass (AND semantics).
            return problemOK && invOK && pmhOK && vaccOK && ageOK && tempOK && feverOK && sexOK
        }

        /// Entry point for JSON-based guideline flags.
        /// - If `rulesJSON` is nil or empty, falls back to the stub behavior.
        /// - For now we support very simple shapes:
        ///     1) ["flag 1", "flag 2"]
        ///     2) { "flags": ["flag 1", "flag 2"] }
        ///   plus the structured GuidelineRuleSet format above.
        func runGuidelineFlags(using context: EpisodeAIContext, rulesJSON: String?) {
            // Determine the effective JSON to use:
            //  1) explicit `rulesJSON` parameter if non-empty
            //  2) else, whatever the host app resolver provides (per-clinician rules)
            let effectiveRaw: String? = {
                if let supplied = rulesJSON?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
                   !supplied.isEmpty {
                    return supplied
                }
                if let resolved = sickRulesJSONResolver?()?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
                   !resolved.isEmpty {
                    return resolved
                }
                return nil
            }()

            // No rules configured anywhere? Use the existing stub so the UI still shows something helpful.
            guard let raw = effectiveRaw else {
                runGuidelineFlagsStub(using: context)
                return
            }

            do {
                let data = Data(raw.utf8)

                // First, try to decode a structured rule set.
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                if let ruleSet = try? decoder.decode(GuidelineRuleSet.self, from: data) {
                    var flags: [String] = []

                    // Optional top-level flags
                    if let baseFlags = ruleSet.flags {
                        flags.append(contentsOf: baseFlags
                            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
                            .filter { !$0.isEmpty })
                    }

                    // Rule-based flags derived from the episode context
                    if let rules = ruleSet.rules {
                        for rule in rules {
                            if ruleConditionsMatch(rule.conditions, context: context) {
                                let primary = rule.flag?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
                                let fallback = rule.description?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
                                let text = primary.isEmpty ? fallback : primary
                                if !text.isEmpty {
                                    flags.append(text)
                                }
                            }
                        }
                    }

                    if !flags.isEmpty {
                        aiGuidelineFlagsForActiveEpisode = flags
                        return
                    } else {
                        // Structured rules present but none matched or produced text → fall back
                        runGuidelineFlagsStub(using: context)
                        return
                    }
                }

                // Fallback: support very simple shapes for backwards compatibility.
                let obj = try JSONSerialization.jsonObject(with: data, options: [])

                var derivedFlags: [String] = []

                // Case 1: array of strings → treat as flags directly
                if let arr = obj as? [String] {
                    derivedFlags = arr
                        .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
                // Case 2: dictionary with "flags": [String]
                else if let dict = obj as? [String: Any],
                        let arr = dict["flags"] as? [String] {
                    derivedFlags = arr
                        .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }

                if derivedFlags.isEmpty {
                    // Structure not recognized yet → fall back to stub for now.
                    runGuidelineFlagsStub(using: context)
                } else {
                    aiGuidelineFlagsForActiveEpisode = derivedFlags
                }
            } catch {
                // JSON parse failed → keep behavior safe and predictable.
                runGuidelineFlagsStub(using: context)
            }
        }

        /// Build a structured JSON snapshot of the current well-visit context.
        /// This is designed to be provider-agnostic and safe to embed directly
        /// into text prompts for LLMs.

        // MARK: - Manual Growth (for AI context)

        private struct ManualGrowthSnapshot {
            let recordedAtISO: String
            let weightKg: Double?
            let heightCm: Double?
            let headCircumferenceCm: Double?
        }

        /// Fetch the most recent manual growth entry for a patient.
        /// Uses `manual_growth.recorded_at` ordering (best-effort ISO date/datetime).
        private func fetchLatestManualGrowthSnapshot(patientID: Int) -> ManualGrowthSnapshot? {
            guard let dbURL = currentDBURL,
                  FileManager.default.fileExists(atPath: dbURL.path) else {
                return nil
            }

            var db: OpaquePointer?
            guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                  let db = db else {
                return nil
            }
            defer { sqlite3_close(db) }

            // Ensure the table exists (some bundles may not include it yet).
            var existsStmt: OpaquePointer?
            defer { sqlite3_finalize(existsStmt) }
            if sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='manual_growth' LIMIT 1;", -1, &existsStmt, nil) != SQLITE_OK {
                return nil
            }
            guard sqlite3_step(existsStmt) == SQLITE_ROW else {
                return nil
            }

            let sql = """
            SELECT
              COALESCE(recorded_at,'') AS recorded_at,
              weight_kg,
              height_cm,
              head_circumference_cm
            FROM manual_growth
            WHERE patient_id = ?
            ORDER BY datetime(COALESCE(recorded_at,'0001-01-01T00:00:00Z')) DESC, id DESC
            LIMIT 1;
            """

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }

            sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }

            func str(_ i: Int32) -> String {
                if let c = sqlite3_column_text(stmt, i) { return String(cString: c) }
                return ""
            }
            func dblOpt(_ i: Int32) -> Double? {
                let t = sqlite3_column_type(stmt, i)
                return t == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
            }

            let recordedAt = str(0).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !recordedAt.isEmpty else {
                return nil
            }

            let w = dblOpt(1)
            let h = dblOpt(2)
            let hc = dblOpt(3)

            // If all values are nil, skip (no useful growth signal).
            if w == nil && h == nil && hc == nil {
                return nil
            }

            return ManualGrowthSnapshot(
                recordedAtISO: recordedAt,
                weightKg: w,
                heightCm: h,
                headCircumferenceCm: hc
            )
        }

        private func buildWellVisitJSON(using context: AppState.WellVisitAIContext) -> String {
            let sanitizedProblems = sanitizeProblemListingForAI(context.problemListing)
            let problemLines = sanitizedProblems
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            var payload: [String: Any] = [
                "well_visit_id": context.wellVisitID,
                "visit_type": context.visitType,
                "problem_listing_raw": context.problemListing,
                "problem_listing_lines": problemLines
            ]

            if let age = context.ageDays {
                payload["age_days"] = age
            }

            if let perinatal = context.perinatalSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !perinatal.isEmpty {
                payload["perinatal_summary"] = perinatal
            }

            if let pmh = context.pmhSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pmh.isEmpty {
                payload["past_medical_history"] = pmh
            }

            if let vacc = context.vaccinationStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
               !vacc.isEmpty {
                payload["vaccination_status"] = vacc
            }

            // ✅ Locally computed growth trend evaluation (if provided by the UI)
            if let trend = context.growthTrendSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trend.isEmpty {
                payload["growth_trend_summary"] = trend
            }
            if let flagged = context.growthTrendIsFlagged {
                payload["growth_trend_flagged"] = flagged
            }
            if let window = context.growthTrendWindow?.trimmingCharacters(in: .whitespacesAndNewlines),
               !window.isEmpty {
                payload["growth_trend_window"] = window
            }

            // ✅ Manual growth snapshot (preferred for well-visit interpretation)
            if let growth = fetchLatestManualGrowthSnapshot(patientID: context.patientID) {
                var g: [String: Any] = [
                    "recorded_at": growth.recordedAtISO
                ]
                if let w = growth.weightKg { g["weight_kg"] = w }
                if let h = growth.heightCm { g["height_cm"] = h }
                if let hc = growth.headCircumferenceCm { g["head_circumference_cm"] = hc }
                payload["manual_growth_snapshot"] = g
            }

            if JSONSerialization.isValidJSONObject(payload),
               let data = try? JSONSerialization.data(withJSONObject: payload,
                                                      options: [.prettyPrinted, .sortedKeys]),
               let jsonString = String(data: data, encoding: .utf8) {
                return jsonString
            } else {
                return "{}"
            }
        }
        
        /// Build a structured JSON snapshot of the current sick-episode context.
        /// This is designed to be provider-agnostic and safe to embed directly
        /// into text prompts for LLMs.
        private func buildSickEpisodeJSON(using context: EpisodeAIContext) -> String {
            // Start from the already-sanitized problem listing text.
            let sanitizedProblems = sanitizeProblemListingForAI(context.problemListing)
            let problemLines = sanitizedProblems
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            var payload: [String: Any] = [
                "episode_id": context.episodeID,
                "problem_listing_raw": context.problemListing,
                "problem_listing_lines": problemLines,
                "complementary_investigations": context.complementaryInvestigations
            ]

            if let vacc = context.vaccinationStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
               !vacc.isEmpty {
                payload["vaccination_status"] = vacc
            }

            if let pmh = context.pmhSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pmh.isEmpty {
                payload["past_medical_history"] = pmh
            }
            
            // ✅ Perinatal summary (prefer context field; fallback to AppState helper)
            let perinatalRaw = (context.perinatalSummary ?? perinatalSummaryForSelectedPatient())
            if let perinatal = perinatalRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
               !perinatal.isEmpty {
                payload["perinatal_summary"] = perinatal
            }

            // Encode as pretty-printed JSON so it is easy to read in debug/preview
            // and easy for LLMs to parse.
            if JSONSerialization.isValidJSONObject(payload),
               let data = try? JSONSerialization.data(withJSONObject: payload,
                                                      options: [.prettyPrinted, .sortedKeys]),
               let jsonString = String(data: data, encoding: .utf8) {
                return jsonString
            } else {
                return "{}"
            }
        }

        /// Build a concrete sick-visit AI prompt by combining:
        ///  - the clinician's configured sick-visit prompt (if any), and
        ///  - a structured patient/episode context.
        ///
        /// This string can be sent as-is to any text-based AI provider.
        func buildSickAIPrompt(using context: EpisodeAIContext) -> String {
            let basePrompt = sickPromptResolver?()?.trimmingCharacters(in: .whitespacesAndNewlines)
            let header: String

            // Localized default prompt + section labels (used when clinician hasn't configured a custom prompt)
            let defaultHeader = NSLocalizedString(
                "appstate.ai.prompt.sick.default_header",
                comment: "Default sick-visit AI prompt header/instructions (multi-line)."
            )

            let sectionContextTitle = NSLocalizedString(
                "appstate.ai.prompt.section.episode_context",
                comment: "Section title line for the sick-visit prompt, e.g. 'Patient/episode context'"
            )
            let sectionStructuredTitle = NSLocalizedString(
                "appstate.ai.prompt.section.structured_episode_json",
                comment: "Section title line for the sick-visit prompt, e.g. 'Structured episode snapshot (JSON)'"
            )

            let labelProblemListing = NSLocalizedString(
                "appstate.ai.prompt.label.problem_listing",
                comment: "Label line for sick-visit prompt, e.g. 'Problem listing:'"
            )
            let labelInvestigations = NSLocalizedString(
                "appstate.ai.prompt.label.complementary_investigations",
                comment: "Label line for sick-visit prompt, e.g. 'Complementary investigations:'"
            )

            let noneProvided = NSLocalizedString(
                "appstate.ai.prompt.placeholder.none_provided",
                comment: "Placeholder when a field has no content, e.g. '(none provided)'"
            )
            let noneDocumented = NSLocalizedString(
                "appstate.ai.prompt.placeholder.none_documented",
                comment: "Placeholder when a field has no content, e.g. '(none documented)'"
            )

            let vaccLineFormat = NSLocalizedString(
                "appstate.ai.prompt.line.vaccination_status_format",
                comment: "Format for vaccination line, e.g. 'Vaccination status: %@'"
            )
            let vaccNotDocumented = NSLocalizedString(
                "appstate.ai.prompt.line.vaccination_status_not_documented",
                comment: "Line when vaccination is missing, e.g. 'Vaccination status: not documented.'"
            )

            let pmhLineFormat = NSLocalizedString(
                "appstate.ai.prompt.line.pmh_format",
                comment: "Format for PMH line, e.g. 'Past medical history: %@'"
            )
            let pmhNotDocumented = NSLocalizedString(
                "appstate.ai.prompt.line.pmh_not_documented",
                comment: "Line when PMH is missing, e.g. 'Past medical history: not documented.'"
            )
            
            let perinatalLineFormat = NSLocalizedString(
                "appstate.ai.prompt.line.perinatal_history_format",
                comment: "Format for perinatal line, e.g. 'Perinatal history: %@'"
            )
            let perinatalNotDocumented = NSLocalizedString(
                "appstate.ai.prompt.line.perinatal_history_not_documented",
                comment: "Line when perinatal history is missing, e.g. 'Perinatal history: not documented.'"
            )


            if let bp = basePrompt, !bp.isEmpty {
                header = bp
            } else {
                header = defaultHeader
            }

            var lines: [String] = []
            lines.append(header)
            lines.append("")
            lines.append("---")
            lines.append(sectionContextTitle)
            lines.append("---")
            lines.append("")
            lines.append(labelProblemListing)
            let sanitizedProblems = sanitizeProblemListingForAI(context.problemListing)
            lines.append(sanitizedProblems.isEmpty ? noneProvided : sanitizedProblems)
            lines.append("")
            lines.append(labelInvestigations)
            lines.append(context.complementaryInvestigations.isEmpty ? noneDocumented : context.complementaryInvestigations)
            lines.append("")
            if let vacc = context.vaccinationStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
               !vacc.isEmpty {
                lines.append(String(format: vaccLineFormat, vacc))
            } else {
                lines.append(vaccNotDocumented)
            }

            // ✅ Perinatal history (prefer context field; fallback to AppState helper)
            let perinatalRaw = (context.perinatalSummary ?? perinatalSummaryForSelectedPatient())
            if let perinatal = perinatalRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
               !perinatal.isEmpty {
                lines.append(String(format: perinatalLineFormat, perinatal))
            } else {
                lines.append(perinatalNotDocumented)
            }

            if let pmh = context.pmhSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pmh.isEmpty {
                lines.append(String(format: pmhLineFormat, pmh))
            } else {
                lines.append(pmhNotDocumented)
            }

            // Append a machine-readable JSON snapshot of the same episode context.
            lines.append("")
            lines.append("---")
            lines.append(sectionStructuredTitle)
            lines.append("---")
            lines.append("")
            let jsonSnapshot = buildSickEpisodeJSON(using: context)
            lines.append(jsonSnapshot)

            return lines.joined(separator: "\n")
        }
    
        /// Build a concrete well-visit AI prompt by combining:
        ///  - the clinician's configured well-visit prompt (if any), and
        ///  - a structured patient/well-visit context.
        ///
        /// This string can be sent as-is to any text-based AI provider.
        func buildWellAIPrompt(using context: AppState.WellVisitAIContext) -> String {
            let basePrompt = wellPromptResolver?()?.trimmingCharacters(in: .whitespacesAndNewlines)
            let header: String

            // Localized default prompt + section labels (used when clinician hasn't configured a custom prompt)
            let defaultHeader = NSLocalizedString(
                "appstate.ai.prompt.well.default_header",
                comment: "Default well-visit AI prompt header/instructions (multi-line)."
            )

            let sectionContextTitle = NSLocalizedString(
                "appstate.ai.prompt.section.well_context",
                comment: "Section title line for the well-visit prompt, e.g. 'Patient/well-visit context'"
            )
            let sectionStructuredTitle = NSLocalizedString(
                "appstate.ai.prompt.section.structured_well_json",
                comment: "Section title line for the well-visit prompt, e.g. 'Structured well-visit snapshot (JSON)'"
            )

            let visitTypeFormat = NSLocalizedString(
                "appstate.ai.prompt.line.visit_type_format",
                comment: "Format for visit type line, e.g. 'Visit type: %@'"
            )
            let ageDaysFormat = NSLocalizedString(
                "appstate.ai.prompt.line.age_days_format",
                comment: "Format for age in days line, e.g. 'Age (days): %d'"
            )
            let ageDaysNotDocumented = NSLocalizedString(
                "appstate.ai.prompt.line.age_days_not_documented",
                comment: "Line when age days is missing, e.g. 'Age (days): not documented.'"
            )

            let labelProblemListing = NSLocalizedString(
                "appstate.ai.prompt.label.problem_listing",
                comment: "Label line for well-visit prompt, e.g. 'Problem listing:'"
            )

            let noneProvided = NSLocalizedString(
                "appstate.ai.prompt.placeholder.none_provided",
                comment: "Placeholder when a field has no content, e.g. '(none provided)'"
            )

            let perinatalLineFormat = NSLocalizedString(
                "appstate.ai.prompt.line.perinatal_history_format",
                comment: "Format for perinatal line, e.g. 'Perinatal history: %@'"
            )
            let perinatalNotDocumented = NSLocalizedString(
                "appstate.ai.prompt.line.perinatal_history_not_documented",
                comment: "Line when perinatal history is missing, e.g. 'Perinatal history: not documented.'"
            )

            let pmhLineFormat = NSLocalizedString(
                "appstate.ai.prompt.line.pmh_format",
                comment: "Format for PMH line, e.g. 'Past medical history: %@'"
            )
            let pmhNotDocumented = NSLocalizedString(
                "appstate.ai.prompt.line.pmh_not_documented",
                comment: "Line when PMH is missing, e.g. 'Past medical history: not documented.'"
            )

            let vaccLineFormat = NSLocalizedString(
                "appstate.ai.prompt.line.vaccination_status_format",
                comment: "Format for vaccination line, e.g. 'Vaccination status: %@'"
            )
            let vaccNotDocumented = NSLocalizedString(
                "appstate.ai.prompt.line.vaccination_status_not_documented",
                comment: "Line when vaccination is missing, e.g. 'Vaccination status: not documented.'"
            )
            
            let growthTrendTitle = NSLocalizedString(
                "appstate.ai.prompt.well.growth_trend_title",
                comment: "Title for the growth trend section in the well-visit AI prompt."
            )
            let growthTrendWindowFormat = NSLocalizedString(
                "appstate.ai.prompt.well.growth_trend.window_format",
                comment: "Format for growth trend window line. %@ is the window description."
            )
            let growthTrendFlaggedYes = NSLocalizedString(
                "appstate.ai.prompt.well.growth_trend.flagged_yes",
                comment: "Growth trend flagged line when flagged is true."
            )
            let growthTrendFlaggedNo = NSLocalizedString(
                "appstate.ai.prompt.well.growth_trend.flagged_no",
                comment: "Growth trend flagged line when flagged is false."
            )

            if let bp = basePrompt, !bp.isEmpty {
                header = bp
            } else {
                header = defaultHeader
            }

            var lines: [String] = []
            lines.append(header)
            lines.append("")
            lines.append("---")
            lines.append(sectionContextTitle)
            lines.append("---")
            lines.append("")

            lines.append(String(format: visitTypeFormat, context.visitType))
            if let age = context.ageDays {
                lines.append(String(format: ageDaysFormat, age))
            } else {
                lines.append(ageDaysNotDocumented)
            }
            lines.append("")

            lines.append(labelProblemListing)
            let sanitizedProblems = sanitizeProblemListingForAI(context.problemListing)
            lines.append(sanitizedProblems.isEmpty ? noneProvided : sanitizedProblems)
            lines.append("")

            if let perinatal = context.perinatalSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !perinatal.isEmpty {
                lines.append(String(format: perinatalLineFormat, perinatal))
            } else {
                lines.append(perinatalNotDocumented)
            }

            if let pmh = context.pmhSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pmh.isEmpty {
                lines.append(String(format: pmhLineFormat, pmh))
            } else {
                lines.append(pmhNotDocumented)
            }

            if let vacc = context.vaccinationStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
               !vacc.isEmpty {
                lines.append(String(format: vaccLineFormat, vacc))
            } else {
                lines.append(vaccNotDocumented)
            }
            
            // ✅ Growth trend evaluation (provided by the UI via WellVisitAIContext)
            if let trend = context.growthTrendSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trend.isEmpty {

                lines.append("")
                lines.append("---")
                lines.append(growthTrendTitle)
                lines.append(trend)

                if let window = context.growthTrendWindow?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !window.isEmpty {
                    lines.append(String(format: growthTrendWindowFormat, window))
                }
                if let flagged = context.growthTrendIsFlagged {
                    lines.append(flagged ? growthTrendFlaggedYes : growthTrendFlaggedNo)
                }
            }
               

            // Append a machine-readable JSON snapshot of the same well-visit context.
            lines.append("")
            lines.append("---")
            lines.append(sectionStructuredTitle)
            lines.append("---")
            lines.append("")
            let jsonSnapshot = buildWellVisitJSON(using: context)
            lines.append(jsonSnapshot)

            return lines.joined(separator: "\n")
        }

        /// Persist an AI interaction for a specific episode into the `ai_inputs` table.
        /// This keeps an audit trail of model, prompt, and response per episode.
        private func saveAIInput(forEpisodeID episodeID: Int, model: String, prompt: String, response: String) {
            guard let dbURL = currentDBURL,
                  FileManager.default.fileExists(atPath: dbURL.path) else {
                log.info("saveAIInput: no DB URL; skipping persist")
                return
            }

            var db: OpaquePointer?
            guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = db else {
                log.error("saveAIInputForActiveEpisode: failed to open DB at \(dbURL.lastPathComponent, privacy: .public)")
                return
            }
            defer { sqlite3_close(db) }

            // Ensure ai_inputs table exists (idempotent).
            let createSQL = """
            CREATE TABLE IF NOT EXISTS ai_inputs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              episode_id INTEGER,
              model TEXT,
              prompt TEXT,
              response TEXT,
              created_at TEXT,
              FOREIGN KEY (episode_id) REFERENCES episodes(id)
            );
            """
            if sqlite3_exec(db, createSQL, nil, nil, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                log.error("saveAIInputForActiveEpisode: ai_inputs CREATE failed: \(msg, privacy: .public)")
                return
            }

            let insertSQL = "INSERT INTO ai_inputs (episode_id, model, prompt, response, created_at) VALUES (?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
                let msg = String(cString: sqlite3_errmsg(db))
                log.error("saveAIInputForActiveEpisode: INSERT prepare failed: \(msg, privacy: .public)")
                return
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, sqlite3_int64(episodeID))
            _ = model.withCString { c in sqlite3_bind_text(stmt, 2, c, -1, SQLITE_TRANSIENT) }
            _ = prompt.withCString { c in sqlite3_bind_text(stmt, 3, c, -1, SQLITE_TRANSIENT) }
            _ = response.withCString { c in sqlite3_bind_text(stmt, 4, c, -1, SQLITE_TRANSIENT) }

            let iso = ISO8601DateFormatter()
            let nowISO = iso.string(from: Date())
            _ = nowISO.withCString { c in sqlite3_bind_text(stmt, 5, c, -1, SQLITE_TRANSIENT) }

            if sqlite3_step(stmt) != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(db))
                log.error("saveAIInputForActiveEpisode: INSERT step failed: \(msg, privacy: .public)")
                return
            }

            // Refresh in-memory AI history for this episode.
            DispatchQueue.main.async {
                self.loadAIInputs(forEpisodeID: episodeID)
            }

            log.info("Saved AI input for episode \(episodeID, privacy: .public) model=\(model, privacy: .public)")
        }
        
        /// Persist an AI interaction for a specific well visit into the `well_ai_inputs` table.
        /// Mirrors `saveAIInput(forEpisodeID:)` but targets well visits.
        private func saveWellAIInput(forWellVisitID wellVisitID: Int, model: String, prompt: String, response: String) {
            guard let dbURL = currentDBURL,
                  FileManager.default.fileExists(atPath: dbURL.path) else {
                log.info("saveWellAIInput: no DB URL; skipping persist")
                return
            }

            var db: OpaquePointer?
            guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = db else {
                log.error("saveWellAIInput: failed to open DB at \(dbURL.lastPathComponent, privacy: .public)")
                return
            }
            defer { sqlite3_close(db) }

            // Ensure well_ai_inputs table exists (idempotent).
            let createSQL = """
            CREATE TABLE IF NOT EXISTS well_ai_inputs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              well_visit_id INTEGER,
              model TEXT,
              prompt TEXT,
              response TEXT,
              created_at TEXT,
              FOREIGN KEY (well_visit_id) REFERENCES well_visits(id)
            );
            """
            if sqlite3_exec(db, createSQL, nil, nil, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                log.error("saveWellAIInput: well_ai_inputs CREATE failed: \(msg, privacy: .public)")
                return
            }

            let insertSQL = "INSERT INTO well_ai_inputs (well_visit_id, model, prompt, response, created_at) VALUES (?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
                let msg = String(cString: sqlite3_errmsg(db))
                log.error("saveWellAIInput: INSERT prepare failed: \(msg, privacy: .public)")
                return
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, sqlite3_int64(wellVisitID))
            _ = model.withCString { c in sqlite3_bind_text(stmt, 2, c, -1, SQLITE_TRANSIENT) }
            _ = prompt.withCString { c in sqlite3_bind_text(stmt, 3, c, -1, SQLITE_TRANSIENT) }
            _ = response.withCString { c in sqlite3_bind_text(stmt, 4, c, -1, SQLITE_TRANSIENT) }

            let iso = ISO8601DateFormatter()
            let nowISO = iso.string(from: Date())
            _ = nowISO.withCString { c in sqlite3_bind_text(stmt, 5, c, -1, SQLITE_TRANSIENT) }

            if sqlite3_step(stmt) != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(db))
                log.error("saveWellAIInput: INSERT step failed: \(msg, privacy: .public)")
                return
            }

            // Refresh in-memory AI history for this well visit.
            DispatchQueue.main.async {
                self.loadWellAIInputs(forWellVisitID: wellVisitID)
            }

            log.info("Saved AI input for well_visit \(wellVisitID, privacy: .public) model=\(model, privacy: .public)")
        }
        
        /// Extract all ICD-10-like codes from a free-text AI summary.
        /// Pattern: a letter A–T or V–Z, followed by two alphanumeric characters,
        /// optionally followed by a dot and 1–4 more alphanumerics (e.g. "A09", "J10.1").
        private func extractICD10Codes(from text: String) -> [String] {
            let pattern = #"\b([A-TV-Z][0-9][0-9A-Z](?:\.[0-9A-Z]{1,4})?)\b"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                return []
            }

            let nsText = text as NSString
            let range = NSRange(location: 0, length: nsText.length)
            let matches = regex.matches(in: text, options: [], range: range)

            var seen = Set<String>()
            var codes: [String] = []

            for match in matches {
                guard match.numberOfRanges >= 2 else { continue }
                let codeRange = match.range(at: 1)
                guard codeRange.location != NSNotFound,
                      let swiftRange = Range(codeRange, in: text) else {
                    continue
                }
                let candidate = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty && !seen.contains(candidate) {
                    seen.insert(candidate)
                    codes.append(candidate)
                }
            }

            return codes
        }
        
        /// Apply a provider-agnostic AI result to state and persistence.
        /// All concrete AI provider clients should funnel through this helper.
        func applyAIResult(_ result: EpisodeAIResult, for context: EpisodeAIContext) {
            // Persist this AI interaction in the ai_inputs table.
            let prompt = buildSickAIPrompt(using: context)
            saveAIInput(
                forEpisodeID: context.episodeID,
                model: result.providerModel,
                prompt: prompt,
                response: result.summary
            )

            // Prefer any provider-supplied ICD-10 suggestion; if absent or blank,
            // fall back to our local heuristic so the clinician still sees something.
            let effectiveICD10: String? = {
                if let code = result.icd10Suggestion,
                   !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return code
                }
                return deriveICD10Suggestion(from: context)
            }()

            // Extract all ICD-10-like codes from the AI summary text so the UI
            // can present them as pickable chips for the clinician.
            let allCandidates = extractICD10Codes(from: result.summary)

            // Publish ICD-10 suggestion, candidate list, and summary for the active episode.
            DispatchQueue.main.async {
                self.icd10SuggestionForActiveEpisode = effectiveICD10
                self.aiICD10CandidatesForActiveEpisode = allCandidates
                // For now keep a single-summary mapping per provider/model.
                self.aiSummariesForActiveEpisode = [result.providerModel: result.summary]
            }
        }
    
        /// Optional resolver that returns the clinician-selected provider id (e.g. "openai", "gemini", "anthropic").
        /// If nil or empty, AppState will fall back to the first non-nil provider resolver.
        var aiProviderIDResolver: (() -> String?)?

        /// Optional provider resolvers (wired by the host app). These return a concrete `EpisodeAIProvider` when configured.
        var openAIProviderResolver: (() -> EpisodeAIProvider?)?
        var geminiProviderResolver: (() -> EpisodeAIProvider?)?
        var anthropicProviderResolver: (() -> EpisodeAIProvider?)?

        /// Normalize provider ids so different UI strings map to the same internal values.
        private func normalizeProviderID(_ raw: String?) -> String? {
            guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            let lower = s.lowercased()
            if lower.contains("openai") { return "openai" }
            if lower.contains("gemini") { return "gemini" }
            if lower.contains("anthropic") || lower.contains("claude") { return "anthropic" }
            return lower
        }

        /// Resolve the currently configured episode-level AI provider.
        /// Priority:
        ///  1) Explicit `episodeAIProviderResolver` (legacy/override)
        ///  2) `aiProviderIDResolver` + matching provider resolver
        ///  3) First non-nil provider resolver in the order: OpenAI → Gemini → Anthropic
        private func resolveEpisodeAIProvider() -> EpisodeAIProvider? {
            // 1) Legacy/override
            if let p = episodeAIProviderResolver?() {
                return p
            }

            // 2) Clinician-selected provider id
            if let pid = normalizeProviderID(aiProviderIDResolver?()) {
                switch pid {
                case "openai":
                    return openAIProviderResolver?()
                case "gemini":
                    return geminiProviderResolver?()
                case "anthropic":
                    return anthropicProviderResolver?()
                default:
                    break
                }
            }

            // 3) First available provider
            if let p = openAIProviderResolver?() { return p }
            if let p = geminiProviderResolver?() { return p }
            if let p = anthropicProviderResolver?() { return p }

            return nil
        }

        /// Entry point used by UI to run AI for a given sick episode context.
        /// For now, this prefers any configured provider (e.g. OpenAI) and falls
        /// back to the local stub when none is available or on error.
        func runAIForEpisode(using context: EpisodeAIContext) {
            if let provider = resolveEpisodeAIProvider() {
                self.log.info("runAIForEpisode: using provider \(String(describing: type(of: provider)), privacy: .public)")
                // Run the provider asynchronously so the UI remains responsive.
                Task {
                    do {
                        let prompt = buildSickAIPrompt(using: context)
                        let result = try await provider.evaluateEpisode(context: context, prompt: prompt)
                        // Funnel all provider output through the common sink.
                        self.applyAIResult(result, for: context)
                    } catch {
                        self.log.error("runAIForEpisode: provider error: \(String(describing: error), privacy: .public)")
                        // Keep things safe and visible to the clinician.
                        DispatchQueue.main.async {
                            let msgFormat = NSLocalizedString(
                                "appstate.ai.provider_error_fallback_format",
                                comment: "Displayed when an AI provider fails; %@ is the provider error description."
                            )
                            let msg = String(format: msgFormat, error.localizedDescription)
                            self.aiSummariesForActiveEpisode = [
                                "error": msg
                            ]
                        }
                        // Fallback: still give a local stub summary and ICD-10 suggestion.
                        self.runAIStub(using: context)
                    }
                }
            } else {
                // No provider configured yet → keep current behavior.
                runAIStub(using: context)
            }
        }

        /// Entry point used by UI to run AI for a given well-visit context.
        /// For now, this prefers any configured provider (e.g. OpenAI) and falls
        /// back to a local stub when none is available or on error. Results are
        /// persisted to `well_ai_inputs`.
        func runAIForWellVisit(using context: AppState.WellVisitAIContext) {
            if let provider = resolveEpisodeAIProvider() {
                self.log.info("runAIForWellVisit: using provider \(String(describing: type(of: provider)), privacy: .public)")
                // Run the provider asynchronously so the UI remains responsive.
                Task {
                    do {
                        let prompt = buildWellAIPrompt(using: context)

                        // Reuse the existing episode provider interface by mapping the
                        // well-visit context into a lightweight EpisodeAIContext.
                        let shimContext = EpisodeAIContext(
                            patientID: context.patientID,
                            episodeID: context.wellVisitID,          // used only for provider internals
                            problemListing: context.problemListing,
                            complementaryInvestigations: "",
                            vaccinationStatus: context.vaccinationStatus,
                            pmhSummary: context.pmhSummary
                        )

                        let result = try await provider.evaluateEpisode(
                            context: shimContext,
                            prompt: prompt
                        )

                        // Persist to the well-specific history table.
                        self.saveWellAIInput(
                            forWellVisitID: context.wellVisitID,
                            model: result.providerModel,
                            prompt: prompt,
                            response: result.summary
                        )

                        // Publish summary for this specific well visit (no ICD-10 on well side for now).
                        DispatchQueue.main.async {
                            // Store per-visit summary
                            self.aiSummariesByWellVisit[context.wellVisitID] = [
                                result.providerModel: result.summary
                            ]
                            // Expose current visit summary to the UI
                            self.aiSummariesForActiveWellVisit =
                                self.aiSummariesByWellVisit[context.wellVisitID] ?? [:]
                        }
                    } catch {
                        self.log.error("runAIForWellVisit: provider error: \(String(describing: error), privacy: .public)")
                        // Keep things safe and visible to the clinician.
                        DispatchQueue.main.async {
                            let msgFormat = NSLocalizedString(
                                "appstate.ai.provider_error_fallback_format",
                                comment: "Displayed when an AI provider fails; %@ is the provider error description."
                            )
                            let msg = String(format: msgFormat, error.localizedDescription)
                            self.aiSummariesForActiveWellVisit = [
                                "error": msg
                            ]
                        }
                        // Fallback: still provide a local stub-style summary.
                        self.runWellAIStub(using: context)
                    }
                }
            } else {
                // No provider configured yet → keep current stub behavior.
                runWellAIStub(using: context)
            }
        }

    /// Temporary stub for a well-visit AI call.
    /// Mirrors `runAIStub(using:)` but targets the well-visit context and
    /// persists into `well_ai_inputs`.
        private func runWellAIStub(using context: AppState.WellVisitAIContext) {
        // Build the full prompt (even for the stub) so we can persist it alongside the response.
        let prompt = buildWellAIPrompt(using: context)

        // --- Localized stub pieces ---
        let pieceProblemListingProvided = NSLocalizedString(
            "appstate.ai.stub.well.piece.problem_listing_provided",
            comment: "Stub well-visit piece: problem listing was provided."
        )
        let piecePerinatalIncluded = NSLocalizedString(
            "appstate.ai.stub.well.piece.perinatal_included",
            comment: "Stub well-visit piece: perinatal history included."
        )
        let piecePMHIncluded = NSLocalizedString(
            "appstate.ai.stub.well.piece.pmh_included",
            comment: "Stub well-visit piece: PMH included."
        )
        let pieceVaccinationIncluded = NSLocalizedString(
            "appstate.ai.stub.well.piece.vaccination_included",
            comment: "Stub well-visit piece: vaccination summary included."
        )
        let pieceAgeDaysFormat = NSLocalizedString(
            "appstate.ai.stub.well.piece.age_days_format",
            comment: "Stub well-visit piece format: age in days. %d is the age in days."
        )
        let pieceCustomPromptConfigured = NSLocalizedString(
            "appstate.ai.stub.well.piece.custom_prompt_configured",
            comment: "Stub well-visit piece: clinician well-visit prompt configured."
        )
        let pieceUsingDefaultPrompt = NSLocalizedString(
            "appstate.ai.stub.well.piece.using_default_prompt",
            comment: "Stub well-visit piece: using default well-visit AI prompt."
        )
        let summaryNoContext = NSLocalizedString(
            "appstate.ai.stub.well.summary.no_context",
            comment: "Stub well-visit summary when no context is provided."
        )
        let summaryFormat = NSLocalizedString(
            "appstate.ai.stub.well.summary.format",
            comment: "Stub well-visit summary format. %@ is the joined bullet list of pieces."
        )

        var pieces: [String] = []

        let trimmedProblems = context.problemListing.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProblems.isEmpty {
            pieces.append(pieceProblemListingProvided)
        }

        if let perinatal = context.perinatalSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !perinatal.isEmpty {
            pieces.append(piecePerinatalIncluded)
        }

        if let pmh = context.pmhSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pmh.isEmpty {
            pieces.append(piecePMHIncluded)
        }

        if let vacc = context.vaccinationStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
           !vacc.isEmpty {
            pieces.append(pieceVaccinationIncluded)
        }

        if let age = context.ageDays {
            pieces.append(String(format: pieceAgeDaysFormat, age))
        }

        let hasCustomPrompt: Bool = {
            if let p = wellPromptResolver?()?.trimmingCharacters(in: .whitespacesAndNewlines),
               !p.isEmpty {
                return true
            }
            return false
        }()
        pieces.append(hasCustomPrompt ? pieceCustomPromptConfigured
                                      : pieceUsingDefaultPrompt)

        let summary: String
        if pieces.isEmpty {
            summary = summaryNoContext
        } else {
            summary = String(format: summaryFormat, pieces.joined(separator: " • "))
        }

        // Persist this stub interaction into well_ai_inputs.
        saveWellAIInput(
            forWellVisitID: context.wellVisitID,
            model: "local-stub",
            prompt: prompt,
            response: summary
        )

        DispatchQueue.main.async {
            // Store per-visit summary for the stub model
            self.aiSummariesByWellVisit[context.wellVisitID] = [
                "local-stub": summary
            ]
            // Expose current visit summary to the UI
            self.aiSummariesForActiveWellVisit =
                self.aiSummariesByWellVisit[context.wellVisitID] ?? [:]
        }
    }
    
    /// Clear AI state for the currently active well visit (summaries + history list).
    func clearAIForWellVisitContext() {
        aiSummariesByWellVisit.removeAll()
        aiSummariesForActiveWellVisit = [:]
        aiInputsForActiveWellVisit = []
    }
        /// Temporary stub for an AI call. This will later dispatch to provider-specific
        /// clients (OpenAI, UpToDate, etc.) based on the clinician's AI setup.
        func runAIStub(using context: EpisodeAIContext) {
            var pieces: [String] = []

            // --- Localized stub pieces ---
            let pieceProblemListingProvided = NSLocalizedString(
                "appstate.ai.stub.episode.piece.problem_listing_provided",
                comment: "Stub sick-visit piece: problem listing was provided."
            )
            let pieceInvestigationsDescribed = NSLocalizedString(
                "appstate.ai.stub.episode.piece.investigations_described",
                comment: "Stub sick-visit piece: investigations described."
            )
            let pieceVaccinationFormat = NSLocalizedString(
                "appstate.ai.stub.episode.piece.vaccination_format",
                comment: "Stub sick-visit piece format: vaccination status. %@ is the vaccination summary text."
            )
            let piecePMHIncluded = NSLocalizedString(
                "appstate.ai.stub.episode.piece.pmh_included",
                comment: "Stub sick-visit piece: PMH included."
            )
            let pieceICD10AvailableFormat = NSLocalizedString(
                "appstate.ai.stub.episode.piece.icd10_available_format",
                comment: "Stub sick-visit piece format: ICD-10 suggestion available. %@ is the suggested code string."
            )
            let pieceCustomPromptConfigured = NSLocalizedString(
                "appstate.ai.stub.episode.piece.custom_prompt_configured",
                comment: "Stub sick-visit piece: clinician sick-visit prompt configured."
            )
            let pieceUsingDefaultPrompt = NSLocalizedString(
                "appstate.ai.stub.episode.piece.using_default_prompt",
                comment: "Stub sick-visit piece: using default sick-visit AI prompt."
            )
            let summaryNoContext = NSLocalizedString(
                "appstate.ai.stub.episode.summary.no_context",
                comment: "Stub sick-visit summary when no episode context is provided."
            )
            let summaryFormat = NSLocalizedString(
                "appstate.ai.stub.episode.summary.format",
                comment: "Stub sick-visit summary format. %@ is the joined bullet list of pieces."
            )

            let trimmedProblems = context.problemListing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedProblems.isEmpty {
                pieces.append(pieceProblemListingProvided)
            }

            let trimmedInv = context.complementaryInvestigations.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedInv.isEmpty {
                pieces.append(pieceInvestigationsDescribed)
            }

            if let vacc = context.vaccinationStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
               !vacc.isEmpty {
                pieces.append(String(format: pieceVaccinationFormat, vacc))
            }

            if let pmh = context.pmhSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pmh.isEmpty {
                pieces.append(piecePMHIncluded)
            }

            // Derive a very simple ICD-10 suggestion from the free-text context (stub only).
            let icdSuggestion = deriveICD10Suggestion(from: context)
            if let icdSuggestion {
                pieces.append(String(format: pieceICD10AvailableFormat, icdSuggestion))
            }

            // Check whether a clinician-specific sick prompt is configured.
            let hasCustomPrompt: Bool = {
                if let p = sickPromptResolver?()?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !p.isEmpty {
                    return true
                }
                return false
            }()
            pieces.append(hasCustomPrompt ? pieceCustomPromptConfigured : pieceUsingDefaultPrompt)

            let summary: String
            if pieces.isEmpty {
                summary = summaryNoContext
            } else {
                summary = String(format: summaryFormat, pieces.joined(separator: " • "))
            }

            // Wrap the stub output into a provider-agnostic result and funnel it
            // through the shared apply helper. This keeps the wiring identical
            // for future real providers.
            let result = EpisodeAIResult(
                providerModel: "local-stub",
                summary: summary,
                icd10Suggestion: icdSuggestion
            )
            applyAIResult(result, for: context)
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


    // MARK: - Episodes (lightweight rows for active patient list)

    /// Minimal row used for the episodes list on PatientDetailView.
    struct EpisodeRow: Identifiable, Hashable {
        let id: Int
        let dateISO: String
        let mainComplaint: String
        let diagnosis: String
    }

    @Published var episodesForActivePatient: [EpisodeRow] = []
        
    // MARK: - AI inputs (per-episode history)

    /// Minimal row representing one AI interaction stored in `ai_inputs`.
    /// Includes both a short preview and the full response text so the UI can
    /// show a compact list and a full read-only viewer per entry.
    struct AIInputRow: Identifiable, Hashable {
        let id: Int
        let createdAtISO: String
        let model: String
        let responsePreview: String
        let fullResponse: String
    }

    /// Provider-agnostic result of an AI evaluation for a sick episode.
    /// All AI providers (OpenAI, UpToDate, local models, etc.) can populate this
    /// and then call `applyAIResult(_:for:)` to update state and persistence.
    struct EpisodeAIResult {
        let providerModel: String
        let summary: String
        let icd10Suggestion: String?
    }

    /// Most recent AI interactions for the currently active episode.
    @Published var aiInputsForActiveEpisode: [AIInputRow] = []
    /// Most recent AI interactions for the currently active well visit.
    /// This will be populated from `well_ai_inputs` once wired.
    @Published var aiInputsForActiveWellVisit: [AIInputRow] = []

    /// Reload the episodes list for the currently selected patient.
    /// Safe to call after inserts/updates; reads from `currentDBURL` and publishes to `episodesForActivePatient`.
    func loadEpisodeRowsForSelectedPatient() {
        guard let pid = selectedPatientID else {
            DispatchQueue.main.async { self.episodesForActivePatient = [] }
            return
        }
        loadEpisodeRows(for: pid)
    }

    /// Internal loader by explicit patient id (Int).
    func loadEpisodeRows(for patientID: Int) {
        guard let dbURL = currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else {
            DispatchQueue.main.async { self.episodesForActivePatient = [] }
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db else {
            DispatchQueue.main.async { self.episodesForActivePatient = [] }
            return
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id,
               COALESCE(created_at, '') AS created_at,
               COALESCE(main_complaint, '') AS main_complaint,
               COALESCE(diagnosis, '') AS diagnosis
        FROM episodes
        WHERE patient_id = ?
        ORDER BY datetime(COALESCE(created_at, '1970-01-01T00:00:00')) DESC, id DESC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            DispatchQueue.main.async { self.episodesForActivePatient = [] }
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))

        var rows: [EpisodeRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let eid = Int(sqlite3_column_int64(stmt, 0))

            // created_at as stored; try to normalize to ISO if it's in "YYYY-MM-DD HH:MM:SS"
            let rawDate = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""
            let dateISO: String = {
                // If there's a space, convert "YYYY-MM-DD HH:MM:SS" -> "YYYY-MM-DDTHH:MM:SSZ" (best-effort)
                if rawDate.contains(" ") && !rawDate.contains("T") {
                    return rawDate.replacingOccurrences(of: " ", with: "T") + "Z"
                }
                return rawDate
            }()

            let mc = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? ""
            let dx = sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) } ?? ""
            rows.append(EpisodeRow(id: eid, dateISO: dateISO, mainComplaint: mc, diagnosis: dx))
        }

        self.log.info("loadEpisodeRows → \(rows.count) rows for pid \(patientID, privacy: .public)")
        DispatchQueue.main.async { self.episodesForActivePatient = rows }
    }
    
    /// Reload the AI inputs list for a given episode id from `ai_inputs`.
    /// Safe to call whenever an episode is selected or a new AI call is recorded.
    func loadAIInputs(forEpisodeID episodeID: Int) {
        guard let dbURL = currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else {
            DispatchQueue.main.async { self.aiInputsForActiveEpisode = [] }
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db else {
            DispatchQueue.main.async { self.aiInputsForActiveEpisode = [] }
            return
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id,
               COALESCE(created_at, '') AS created_at,
               COALESCE(model, '') AS model,
               COALESCE(response, '') AS response
        FROM ai_inputs
        WHERE episode_id = ?
        ORDER BY datetime(COALESCE(created_at, '1970-01-01T00:00:00')) DESC, id DESC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            DispatchQueue.main.async { self.aiInputsForActiveEpisode = [] }
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sqlite3_int64(episodeID))

        var rows: [AIInputRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            let created = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""
            let model = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? ""
            let resp = sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) } ?? ""

            // Build a short, single-line preview of the response.
            let trimmed = resp
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let preview: String = {
                if trimmed.count <= 160 { return trimmed }
                let idx = trimmed.index(trimmed.startIndex, offsetBy: 160)
                return String(trimmed[..<idx]) + "…"
            }()

            rows.append(AIInputRow(id: id,
                                   createdAtISO: created,
                                   model: model,
                                   responsePreview: preview,
                                   fullResponse: resp))
        }

        DispatchQueue.main.async {
            self.aiInputsForActiveEpisode = rows
        }
    }
    
    /// Reload the AI inputs list for a given well visit id from `well_ai_inputs`.
    /// Safe to call whenever a well visit is selected or a new AI call is recorded.
    func loadWellAIInputs(forWellVisitID wellVisitID: Int) {
        // Always reset the in-memory well-visit AI state when switching context.
        DispatchQueue.main.async {
            // Clear current active well-visit AI state for a clean reload.
            self.aiSummariesForActiveWellVisit = [:]
        }
        

        guard let dbURL = currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else {
            DispatchQueue.main.async {
                self.aiInputsForActiveWellVisit = []
            }
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db else {
            return
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id,
               COALESCE(created_at, '') AS created_at,
               COALESCE(model, '') AS model,
               COALESCE(response, '') AS response
        FROM well_ai_inputs
        WHERE well_visit_id = ?
        ORDER BY datetime(COALESCE(created_at, '1970-01-01T00:00:00')) DESC, id DESC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sqlite3_int64(wellVisitID))

        var rows: [AIInputRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            let created = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""
            let model = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? ""
            let resp = sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) } ?? ""

            let trimmed = resp
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let preview: String = {
                if trimmed.count <= 160 { return trimmed }
                let idx = trimmed.index(trimmed.startIndex, offsetBy: 160)
                return String(trimmed[..<idx]) + "…"
            }()

            rows.append(AIInputRow(id: id,
                                   createdAtISO: created,
                                   model: model,
                                   responsePreview: preview,
                                   fullResponse: resp))
        }

        DispatchQueue.main.async {
            // Full history list for the AI history sidebar.
            self.aiInputsForActiveWellVisit = rows

            // Rebuild the per-visit summary map from the most recent AI entry
            // for this well visit (Option A: latest row overall, regardless of model).
            if let latest = rows.first {
                let modelKey = latest.model.isEmpty
                    ? NSLocalizedString(
                        "appstate.ai.inputs.model_unknown",
                        comment: "Fallback model label when an AI input row has an empty model name."
                    )
                    : latest.model
                self.aiSummariesByWellVisit[wellVisitID] = [
                    modelKey: latest.fullResponse
                ]
                // Expose the same mapping as the active-visit summary for the UI.
                self.aiSummariesForActiveWellVisit =
                    self.aiSummariesByWellVisit[wellVisitID] ?? [:]
            } else {
                // No rows at all → clear any previous summary for this visit.
                self.aiSummariesByWellVisit[wellVisitID] = [:]
                self.aiSummariesForActiveWellVisit = [:]
            }
        }
    }

    // MARK: - Episodes (create + edit window helpers)

    /// Clear any in-progress episode editing state (called on patient switch).
    func clearEpisodeEditing() {
        self.activeEpisodeID = nil
    }

    /// Set the currently active episode id for editing.
    func setActiveEpisode(_ id: Int?) {
        self.activeEpisodeID = id
        if let eid = id {
            loadAIInputs(forEpisodeID: eid)
        } else {
            aiInputsForActiveEpisode = []
        }
    }

    /// Return true if the episode can be edited.
    ///
    /// We no longer enforce a time-based edit window for sick episodes.
    /// Any post-visit notes should be captured via addenda (e.g., `visit_addenda`) so
    /// reports can reflect amendments without blocking edits.
    func canEditEpisode(_ episodeID: Int) -> Bool {
        return true
    }

    /// Create a minimal new episode row for the currently selected patient.
    /// Returns the new episode id on success. If an episode already exists *today* for the same patient+user
    /// and `force == false`, returns `nil` (UI can show a "Save Anyway" path).
    @discardableResult
    func startNewEpisode(force: Bool = false) -> Int? {
        // DEBUG: what are we about to use?
        let startDebugFmt = NSLocalizedString(
            "appstate.episode.start.debug_format",
            comment: "Log format for startNewEpisode debug: pid, uid, db path."
        )
        let startDebugMsg = String(
            format: startDebugFmt,
            String(describing: self.selectedPatientID),
            String(describing: self.activeUserID),
            self.currentDBURL?.path ?? "nil"
        )
        log.info("\(startDebugMsg, privacy: .public)")

        guard let pid = selectedPatientID,
              let dbURL = currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else {
            let msg = NSLocalizedString(
                "appstate.episode.start.guard_failed",
                comment: "Log when startNewEpisode guard fails due to missing pid or dbURL."
            )
            log.error("\(msg, privacy: .public)")
            return nil
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = db else {
            let msg = NSLocalizedString(
                "appstate.episode.start.open_failed",
                comment: "Log when startNewEpisode cannot open the bundle database."
            )
            log.error("\(msg, privacy: .public)")
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
            // If the check statement prepares successfully, enforce the same-day constraint.
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
            let msg = String(cString: sqlite3_errmsg(db))
            let fmt = NSLocalizedString(
                "appstate.episode.start.insert_prepare_failed_format",
                comment: "Log when episode INSERT prepare fails; %@ is the sqlite error message."
            )
            let line = String(format: fmt, msg)
            log.error("\(line, privacy: .public)")
            return nil
        }
        sqlite3_bind_int64(ins, 1, sqlite3_int64(pid))
        if let uid = activeUserID {
            sqlite3_bind_int64(ins, 2, sqlite3_int64(uid))
        } else {
            sqlite3_bind_null(ins, 2)
        }
        guard sqlite3_step(ins) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            let fmt = NSLocalizedString(
                "appstate.episode.start.insert_failed_format",
                comment: "Log when episode INSERT step fails; %@ is the sqlite error message."
            )
            let line = String(format: fmt, msg)
            log.error("\(line, privacy: .public)")
            return nil
        }

        let newID = Int(sqlite3_last_insert_rowid(db))
        let insertedFmt = NSLocalizedString(
            "appstate.episode.start.inserted_format",
            comment: "Log when a new episode row is inserted; %d is the new episode id; %@ is the user_id description."
        )
        let insertedMsg = String(format: insertedFmt, newID, String(describing: self.activeUserID))
        log.info("\(insertedMsg, privacy: .public)")

        // Make sure the active clinician exists in this bundle's users table
        self.ensureActiveClinicianMirroredIntoBundleUsers()

        self.activeEpisodeID = newID
        // Keep the right pane lists fresh
        self.reloadVisitsForSelectedPatient()
        return newID
    }
    
    // MARK: - Clinician mirroring into bundle DB (users table)

    /// Ensure the currently active clinician (from the app-local clinicians.sqlite)
    /// is present in the active bundle's db.sqlite `users` table, keyed by the same id.
    /// This keeps PatientViewerApp able to resolve episodes.user_id / well_visits.user_id
    /// to a "first_name + last_name" without leaking all clinician details.
    private func ensureActiveClinicianMirroredIntoBundleUsers() {
        guard let activeUserID = self.activeUserID else {
            let msg = NSLocalizedString(
                "appstate.users_mirror.no_active_user_id",
                comment: "Log when there is no active clinician id; mirroring to bundle users is skipped."
            )
            log.info("\(msg, privacy: .public)")
            return
        }

        // 1) Read the active clinician's name from the app-local clinicians.sqlite
        //    (same path logic as ClinicianStore.dbURL).
        let fm = FileManager.default
        let cliniciansDBURL: URL = {
            let base = try! fm.url(for: .applicationSupportDirectory,
                                   in: .userDomainMask,
                                   appropriateFor: nil,
                                   create: true)
                .appendingPathComponent("DrsMainApp", isDirectory: true)
                .appendingPathComponent("Clinicians", isDirectory: true)
            if !fm.fileExists(atPath: base.path) {
                try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            }
            return base.appendingPathComponent("clinicians.sqlite", isDirectory: false)
        }()

        var cliniciansDB: OpaquePointer?
        guard sqlite3_open_v2(cliniciansDBURL.path, &cliniciansDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let cliniciansDBUnwrapped = cliniciansDB else {
            let fmt = NSLocalizedString(
                "appstate.users_mirror.open_clinicians_db_failed_format",
                comment: "Log when clinicians DB cannot be opened; %@ is the clinicians DB path."
            )
            let line = String(format: fmt, cliniciansDBURL.lastPathComponent)
            log.error("\(line, privacy: .public)")
            return
        }
        defer { sqlite3_close(cliniciansDBUnwrapped) }

        var nameStmt: OpaquePointer?
        defer { sqlite3_finalize(nameStmt) }

        let nameSQL = """
        SELECT TRIM(first_name) AS first_name,
               TRIM(last_name)  AS last_name
        FROM users
        WHERE id = ?
        LIMIT 1;
        """

        guard sqlite3_prepare_v2(cliniciansDBUnwrapped, nameSQL, -1, &nameStmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(cliniciansDBUnwrapped))
            let fmt = NSLocalizedString(
                "appstate.users_mirror.name_select_prepare_failed_format",
                comment: "Log when preparing the clinicians name SELECT fails; %@ is the sqlite error."
            )
            let line = String(format: fmt, msg)
            log.error("\(line, privacy: .public)")
            return
        }

        sqlite3_bind_int64(nameStmt, 1, sqlite3_int64(activeUserID))

        guard sqlite3_step(nameStmt) == SQLITE_ROW else {
            let fmt = NSLocalizedString(
                "appstate.users_mirror.no_clinician_row_found_format",
                comment: "Log when no clinician row exists; %d is the clinician id."
            )
            let line = String(format: fmt, activeUserID)
            log.warning("\(line, privacy: .public)")
            return
        }

        let firstName = sqlite3_column_text(nameStmt, 0).flatMap { String(cString: $0) } ?? ""
        let lastName  = sqlite3_column_text(nameStmt, 1).flatMap { String(cString: $0) } ?? ""
        let trimmedFirst = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLast  = lastName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedFirst.isEmpty || !trimmedLast.isEmpty else {
            let fmt = NSLocalizedString(
                "appstate.users_mirror.empty_name_skip_format",
                comment: "Log when clinician name is empty; %d is the clinician id."
            )
            let line = String(format: fmt, activeUserID)
            log.warning("\(line, privacy: .public)")
            return
        }

        // 2) Open current bundle DB and upsert this clinician into db.sqlite.users
        guard let bundleDBURL = currentDBURL,
              fm.fileExists(atPath: bundleDBURL.path) else {
            let msg = NSLocalizedString(
                "appstate.users_mirror.no_current_db_url",
                comment: "Log when there is no active bundle DB URL; mirroring to bundle users is skipped."
            )
            log.error("\(msg, privacy: .public)")
            return
        }

        var bundleDB: OpaquePointer?
        guard sqlite3_open_v2(bundleDBURL.path, &bundleDB, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let bundleDBUnwrapped = bundleDB else {
            let fmt = NSLocalizedString(
                "appstate.users_mirror.open_bundle_db_failed_format",
                comment: "Log when bundle DB cannot be opened; %@ is the bundle DB path."
            )
            let line = String(format: fmt, bundleDBURL.path)
            log.error("\(line, privacy: .public)")
            return
        }
        defer { sqlite3_close(bundleDBUnwrapped) }

        // Ensure a minimal `users` table exists in the bundle DB.
        let createSQL = """
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY,
            first_name TEXT NOT NULL,
            last_name  TEXT NOT NULL,
            created_at TEXT
        );
        """
        if sqlite3_exec(bundleDBUnwrapped, createSQL, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(bundleDBUnwrapped))
            let fmt = NSLocalizedString(
                "appstate.users_mirror.create_users_table_failed_format",
                comment: "Log when CREATE TABLE users fails; %@ is the sqlite error."
            )
            let line = String(format: fmt, msg)
            log.error("\(line, privacy: .public)")
            return
        }

        // Check if a row already exists for this id.
        var checkStmt: OpaquePointer?
        defer { sqlite3_finalize(checkStmt) }

        let checkSQL = "SELECT 1 FROM users WHERE id = ? LIMIT 1;"
        guard sqlite3_prepare_v2(bundleDBUnwrapped, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(bundleDBUnwrapped))
            let fmt = NSLocalizedString(
                "appstate.users_mirror.check_select_prepare_failed_format",
                comment: "Log when preparing the bundle users check SELECT fails; %@ is the sqlite error."
            )
            let line = String(format: fmt, msg)
            log.error("\(line, privacy: .public)")
            return
        }
        sqlite3_bind_int64(checkStmt, 1, sqlite3_int64(activeUserID))

        let exists = (sqlite3_step(checkStmt) == SQLITE_ROW)

        if exists {
            // UPDATE
            var updStmt: OpaquePointer?
            defer { sqlite3_finalize(updStmt) }

            let updSQL = """
            UPDATE users
            SET first_name = ?, last_name = ?
            WHERE id = ?;
            """
            guard sqlite3_prepare_v2(bundleDBUnwrapped, updSQL, -1, &updStmt, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(bundleDBUnwrapped))
                let fmt = NSLocalizedString(
                    "appstate.users_mirror.update_prepare_failed_format",
                    comment: "Log when preparing UPDATE users fails; %@ is the sqlite error."
                )
                let line = String(format: fmt, msg)
                log.error("\(line, privacy: .public)")
                return
            }

            _ = trimmedFirst.withCString { c in sqlite3_bind_text(updStmt, 1, c, -1, SQLITE_TRANSIENT) }
            _ = trimmedLast.withCString  { c in sqlite3_bind_text(updStmt, 2, c, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int64(updStmt, 3, sqlite3_int64(activeUserID))

            if sqlite3_step(updStmt) != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(bundleDBUnwrapped))
                let fmt = NSLocalizedString(
                    "appstate.users_mirror.update_step_failed_format",
                    comment: "Log when UPDATE users step fails; %@ is the sqlite error."
                )
                let line = String(format: fmt, msg)
                log.error("\(line, privacy: .public)")
                return
            }

            let fmt = NSLocalizedString(
                "appstate.users_mirror.updated_user_format",
                comment: "Log when a clinician is updated in the bundle users table; %d is the clinician id."
            )
            let line = String(format: fmt, activeUserID)
            log.info("\(line, privacy: .public)")
        } else {
            // INSERT
            var insStmt: OpaquePointer?
            defer { sqlite3_finalize(insStmt) }

            let insSQL = """
            INSERT INTO users (id, first_name, last_name, created_at)
            VALUES (?, ?, ?, CURRENT_TIMESTAMP);
            """
            guard sqlite3_prepare_v2(bundleDBUnwrapped, insSQL, -1, &insStmt, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(bundleDBUnwrapped))
                let fmt = NSLocalizedString(
                    "appstate.users_mirror.insert_prepare_failed_format",
                    comment: "Log when preparing INSERT users fails; %@ is the sqlite error."
                )
                let line = String(format: fmt, msg)
                log.error("\(line, privacy: .public)")
                return
            }

            sqlite3_bind_int64(insStmt, 1, sqlite3_int64(activeUserID))
            _ = trimmedFirst.withCString { c in sqlite3_bind_text(insStmt, 2, c, -1, SQLITE_TRANSIENT) }
            _ = trimmedLast.withCString  { c in sqlite3_bind_text(insStmt, 3, c, -1, SQLITE_TRANSIENT) }

            if sqlite3_step(insStmt) != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(bundleDBUnwrapped))
                let fmt = NSLocalizedString(
                    "appstate.users_mirror.insert_step_failed_format",
                    comment: "Log when INSERT users step fails; %@ is the sqlite error."
                )
                let line = String(format: fmt, msg)
                log.error("\(line, privacy: .public)")
                return
            }

            let fmt = NSLocalizedString(
                "appstate.users_mirror.inserted_user_format",
                comment: "Log when a clinician is inserted into the bundle users table; %d is the clinician id."
            )
            let line = String(format: fmt, activeUserID)
            log.info("\(line, privacy: .public)")
        }
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
                let logMsg = NSLocalizedString(
                    "appstate.growth.add_manual.no_current_db_url",
                    comment: "Log when addGrowthPointManual is called without an active bundle DB URL."
                )
                log.error("\(logMsg, privacy: .public)")

                let errMsg = NSLocalizedString(
                    "appstate.growth.no_active_bundle_db",
                    comment: "Error shown when there is no active bundle DB for a growth write operation."
                )
                throw NSError(domain: "AppState", code: 404, userInfo: [NSLocalizedDescriptionKey: errMsg])
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
                let fmt = NSLocalizedString(
                    "appstate.growth.delete_manual.ignored_non_manual_source_format",
                    comment: "Log when deleteGrowthPointIfManual is called with a non-manual growth source. %@ is the source string."
                )
                let line = String(format: fmt, gp.source)
                log.info("\(line, privacy: .public)")
                return
            }
            guard let dbURL = currentDBURL,
                  FileManager.default.fileExists(atPath: dbURL.path) else {
                let logMsg = NSLocalizedString(
                    "appstate.growth.delete_manual.no_current_db_url",
                    comment: "Log when deleteGrowthPointIfManual is called without an active bundle DB URL."
                )
                log.error("\(logMsg, privacy: .public)")

                let errMsg = NSLocalizedString(
                    "appstate.growth.no_active_bundle_db",
                    comment: "Error shown when there is no active bundle DB for a growth write operation."
                )
                throw NSError(domain: "AppState", code: 404, userInfo: [NSLocalizedDescriptionKey: errMsg])
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
                        let fmt = NSLocalizedString(
                            "appstate.zip_import.no_db_found_under_format",
                            comment: "Log when no db.sqlite is found while importing a ZIP. %@ is the staging folder path."
                        )
                        let line = String(format: fmt, staged.path)
                        self.log.warning("\(line, privacy: .public)")
                        continue
                    }

                    // Phase 1 integrity guard: if a v2 manifest with db_sha256 exists,
                    // verify the DB on disk matches before proceeding. This helps catch
                    // tampering/corruption while staying backward‑compatible for older bundles.
                    if !self.validateBundleIntegrity(at: bundleRoot) {
                        let fmt = NSLocalizedString(
                            "appstate.zip_import.integrity_check_failed_format",
                            comment: "Log when bundle integrity validation fails during ZIP import. %@ is the bundle folder name."
                        )
                        let line = String(format: fmt, bundleRoot.lastPathComponent)
                        self.log.error("\(line, privacy: .private)")
                        continue
                    }

                    // Best-effort: upgrade/refresh manifest.json to the current v2 schema so
                    // legacy bundles get re-circulated in a healthy up-to-date format.
                    _ = self.upgradeBundleManifestIfNeeded(at: bundleRoot)

                    // Extract patient identity from the staged bundle
                    guard let identity = self.extractPatientIdentity(from: bundleRoot) else {
                        let fmt = NSLocalizedString(
                            "appstate.zip_import.no_identity_found_format",
                            comment: "Log when no patient identity can be extracted during ZIP import. %@ is the bundle folder name."
                        )
                        let line = String(format: fmt, bundleRoot.lastPathComponent)
                        self.log.warning("\(line, privacy: .private)")
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
                                let fmt = NSLocalizedString(
                                    "appstate.zip_import.replaced_existing_bundle_format",
                                    comment: "Log when an existing bundle is replaced during import. First %@ is the identity string, second %@ is the final path."
                                )
                                let bundleLabel = AppLog.bundleRef(finalURL)
                                let line = String(format: fmt, self.identityStringForLog(identity), bundleLabel)
                                self.log.info("\(line, privacy: .public)")
                            } else {
                                let fmt = NSLocalizedString(
                                    "appstate.zip_import.failed_to_replace_existing_bundle_format",
                                    comment: "Log when replacing an existing bundle fails during import. %@ is the identity string."
                                )
                                let line = String(format: fmt, self.identityString(identity))
                                self.log.error("\(line, privacy: .public)")
                            }

                        case .keepBoth:
                            // Register staged incoming as a separate bundle; no auto-select.
                            if !self.bundleLocations.contains(bundleRoot) {
                                self.bundleLocations.append(bundleRoot)
                            }
                            self.addToRecents(bundleRoot)
                            let fmt = NSLocalizedString(
                                "appstate.zip_import.kept_both_bundles_format",
                                comment: "Log when keeping both bundles during import. First %@ is the identity string, second %@ is the new bundle folder name."
                            )
                            let line = String(format: fmt, self.identityString(identity), bundleRoot.lastPathComponent)
                            self.log.info("\(line, privacy: .private)")

                        case .cancel:
                            // Drop this staged import.
                            try? fm.removeItem(at: bundleRoot)
                            let fmt = NSLocalizedString(
                                "appstate.zip_import.cancelled_import_format",
                                comment: "Log when the user cancels a ZIP import conflict. %@ is the identity string."
                            )
                            let line = String(format: fmt, self.identityString(identity))
                            self.log.info("\(line, privacy: .public)")
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
                        let fmt = NSLocalizedString(
                            "appstate.zip_import.imported_new_bundle_no_autoselect_format",
                            comment: "Log when a new bundle is imported without auto-selecting it. First %@ is the identity string, second %@ is the bundle path."
                        )
                        // Avoid logging full filesystem paths OR raw bundle folder names (they often contain the alias).
                        // Log a stable, non-identifying bundle reference instead.
                        let bundleLabel = AppLog.bundleRef(bundleRoot)
                        let line = String(format: fmt, self.identityStringForLog(identity), bundleLabel)
                        self.log.info("\(line, privacy: .public)")
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
                    let fmt = NSLocalizedString(
                        "appstate.zip_import.failed_for_zip_format",
                        comment: "Log when a ZIP import fails. First %@ is the zip path, second %@ is the error description."
                    )
                    let zipLabel = zipURL.lastPathComponent
                    let line = String(format: fmt, zipLabel, String(describing: error))
                    self.log.error("\(line, privacy: .public)")
                    // Optional deep debug: keep the full path private.
                    self.log.debug("ZIP import failed (full path): \(zipURL.path, privacy: .private)")
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
            alert.messageText = NSLocalizedString(
                "appstate.import_conflict.alert_title",
                comment: "Title for the import conflict alert when a patient already exists."
            )

            let infoFmt = NSLocalizedString(
                "appstate.import_conflict.alert_message_format",
                comment: "Message for the import conflict alert. %@ is the patient identity string."
            )
            alert.informativeText = String(format: infoFmt, identityString(identity))

            alert.addButton(withTitle: NSLocalizedString(
                "appstate.import_conflict.button_replace",
                comment: "Button title to replace the existing patient bundle during import."
            ))   // 1
            alert.addButton(withTitle: NSLocalizedString(
                "appstate.import_conflict.button_keep_both",
                comment: "Button title to keep both bundles during import."
            )) // 2
            alert.addButton(withTitle: NSLocalizedString(
                "appstate.import_conflict.button_cancel",
                comment: "Button title to cancel the import."
            ))    // 3
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
    
        /// Log-safe identity string: avoids leaking raw MRN / alias into logs.
        /// Deterministic and non-reversible (FNV-1a 64-bit).
        private func identityStringForLog(_ id: PatientIdentity) -> String {
            if let mrn = id.mrn?.trimmingCharacters(in: .whitespacesAndNewlines), !mrn.isEmpty {
                return "MRN#\(obfuscatedToken(mrn))"
            }
            if let alias = id.alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
                return "ALIAS#\(obfuscatedToken(alias))"
            }
            if let dob = id.dobISO?.trimmingCharacters(in: .whitespacesAndNewlines), !dob.isEmpty {
                let day = dob.split(separator: "T").first.map(String.init) ?? dob
                return "DOB#\(obfuscatedToken(day))"
            }
            return "UnknownPatient"
        }

        private func obfuscatedToken(_ s: String) -> String {
            var hash: UInt64 = 1469598103934665603
            for b in s.utf8 {
                hash ^= UInt64(b)
                hash &*= 1099511628211
            }
            return String(format: "%08llx", hash)
        }

        /// Lightweight summary used for displaying bundles in the sidebar.
        struct BundleSidebarSummary: Identifiable, Hashable {
            /// Underlying bundle root URL (also used as stable identity).
            let id: URL
            let url: URL
            let alias: String
            let fullName: String
            let dob: String
            let createdOn: String
            let importedOn: String
            let lastSavedOn: String
        }

        /// Build a best-effort sidebar summary for a given bundle root by combining
        /// manifest.json identity info with file-system timestamps. This is read-only
        /// and safe for both DrsMainApp- and PatientViewerApp-origin bundles.
        func buildBundleSidebarSummary(for bundleRoot: URL) -> BundleSidebarSummary {
            let fm = FileManager.default

            // Identity: prefer manifest/db identity via the existing helper.
            let identity = extractPatientIdentity(from: bundleRoot)
            let alias: String = {
                if let a = identity?.alias, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return a
                }
                if let id = identity {
                    return identityString(id)
                }
                return "UnknownPatient"
            }()

            // DOB in a friendlier format (YYYY-MM-DD) if present.
            let dob: String = {
                guard let raw = identity?.dobISO, !raw.isEmpty else { return "—" }
                if let day = raw.split(separator: "T").first {
                    return String(day)
                }
                return raw
            }()

            // For now we don't have full name in the manifest; show alias as the display name.
            let fullName = alias

            // Created-on: try manifest["exported_at"], else folder creationDate.
            var createdOn = "—"
            let manifestURL = bundleRoot.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: manifestURL),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ts = obj["exported_at"] as? String,
               !ts.isEmpty {
                createdOn = formatBundleExportStamp(ts)
            } else if let attrs = try? fm.attributesOfItem(atPath: bundleRoot.path),
                      let cdate = attrs[.creationDate] as? Date {
                createdOn = formatBundleDate(cdate)
            }

            // Imported-on: use folder creationDate as an approximation.
            let importedOn: String = {
                if let attrs = try? fm.attributesOfItem(atPath: bundleRoot.path),
                   let cdate = attrs[.creationDate] as? Date {
                    return formatBundleDate(cdate)
                }
                return "—"
            }()

            // Last-saved: prefer db.sqlite or db.sqlite.enc mtime; else folder mtime.
            let lastSavedOn: String = {
                let dbPlain = bundleRoot.appendingPathComponent("db.sqlite")
                let dbEnc   = bundleRoot.appendingPathComponent("db.sqlite.enc")
                if let attrs = try? fm.attributesOfItem(atPath: dbPlain.path),
                   let m = attrs[.modificationDate] as? Date {
                    return formatBundleDate(m)
                }
                if let attrs = try? fm.attributesOfItem(atPath: dbEnc.path),
                   let m = attrs[.modificationDate] as? Date {
                    return formatBundleDate(m)
                }
                if let attrs = try? fm.attributesOfItem(atPath: bundleRoot.path),
                   let m = attrs[.modificationDate] as? Date {
                    return formatBundleDate(m)
                }
                return "—"
            }()

            let normalizedURL = bundleRoot.standardizedFileURL
            return BundleSidebarSummary(
                id: normalizedURL,
                url: normalizedURL,
                alias: alias,
                fullName: fullName,
                dob: dob,
                createdOn: createdOn,
                importedOn: importedOn,
                lastSavedOn: lastSavedOn
            )
        }

        /// Convert an export timestamp like "yyyyMMdd-HHmmss" into a human-readable
        /// short date/time string using the current locale.
        private func formatBundleExportStamp(_ stamp: String) -> String {
            let input = DateFormatter()
            input.locale = Locale(identifier: "en_US_POSIX")
            input.timeZone = TimeZone(secondsFromGMT: 0)
            input.dateFormat = "yyyyMMdd-HHmmss"

            let display = DateFormatter()
            display.locale = Locale.current
            display.timeZone = TimeZone.current
            display.dateStyle = .short
            display.timeStyle = .short

            if let d = input.date(from: stamp) {
                return display.string(from: d)
            }
            // Fallback to raw stamp if parsing fails.
            return stamp
        }

        /// Convert a Date into a short, locale-aware date + time string.
        private func formatBundleDate(_ date: Date) -> String {
            let df = DateFormatter()
            df.locale = Locale.current
            df.timeZone = TimeZone.current
            df.dateStyle = .short
            df.timeStyle = .short
            return df.string(from: date)
        }

    private func extractPatientIdentity(from bundleRoot: URL) -> PatientIdentity? {
        let fm = FileManager.default

        // Cache manifest info for later heuristics/decryption.
        var manifestObj: [String: Any]? = nil
        var manifestEncryptedFlag = false
        var manifestScheme: String? = nil

        // 1) Prefer manifest.json at bundle root
        let manifestURL = bundleRoot.appendingPathComponent("manifest.json")
        if fm.fileExists(atPath: manifestURL.path) {
            do {
                let data = try Data(contentsOf: manifestURL)
                if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    manifestObj = obj
                    manifestEncryptedFlag = (obj["encrypted"] as? Bool) ?? false
                    manifestScheme = (obj["encryption_scheme"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

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

        // Helper: probe a readable sqlite DB file for identity.
        // NOTE: We keep this READONLY for real bundle DBs to avoid creating sidecar files.
        // For temp decrypted copies we may open READWRITE to allow SQLite to create any needed WAL sidecars.
        func probeIdentityFromSQLite(at dbURL: URL, openFlags: Int32 = SQLITE_OPEN_READONLY) -> PatientIdentity? {
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbURL.path, &db, openFlags, nil) == SQLITE_OK, let db else { return nil }
            defer { sqlite3_close(db) }

            // If we are allowed to open read-write (temp decrypted DB), force rollback journal mode.
            // This prevents noisy failures when a DB header indicates WAL mode but no -wal file exists.
            if (openFlags & SQLITE_OPEN_READWRITE) != 0 {
                _ = sqlite3_exec(db, "PRAGMA journal_mode=DELETE;", nil, nil, nil)
                _ = sqlite3_exec(db, "PRAGMA synchronous=OFF;", nil, nil, nil)
            }

            let cols = columnSet(of: "patients", db: db)
            guard !cols.isEmpty else { return nil }

            let mrnCol = cols.contains("mrn") ? "mrn" : nil
            let aliasCol = cols.contains("alias_label") ? "alias_label" : (cols.contains("alias") ? "alias" : nil)
            let dobCol = cols.contains("dob") ? "dob" : nil

            var wanted: [String] = []
            if let mrnCol { wanted.append(mrnCol) }
            if let aliasCol { wanted.append(aliasCol) }
            if let dobCol { wanted.append(dobCol) }
            if wanted.isEmpty { return nil }

            let sql = "SELECT \(wanted.joined(separator: ", ")) FROM patients ORDER BY id LIMIT 1;"

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
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

            if (mrn?.isEmpty == false) || (alias?.isEmpty == false) || (dob?.isEmpty == false) {
                return PatientIdentity(mrn: mrn, alias: alias, dobISO: dob)
            }
            return nil
        }

        // 2) Probe DB first (preferred fallback), because it preserves exact alias (including emoji/case)
        let plainDBURL = bundleRoot.appendingPathComponent("db.sqlite")
        if fm.fileExists(atPath: plainDBURL.path),
           let id = probeIdentityFromSQLite(at: plainDBURL) {
            return id
        }

        // 2b) If only encrypted DB exists, try decrypting to a temp file just long enough to read identity.
        let encDBURL = bundleRoot.appendingPathComponent("db.sqlite.enc")
        if fm.fileExists(atPath: encDBURL.path) {
            let shouldTryDecrypt = manifestEncryptedFlag || (manifestScheme != nil) || (manifestObj?["files"] != nil) || (manifestObj == nil)
            if shouldTryDecrypt {
                let tmpURL = fm.temporaryDirectory
                    .appendingPathComponent("pemr-\(UUID().uuidString)")
                    .appendingPathExtension("sqlite")
                do {
                    // NOTE: adjust the call name/signature if your BundleCrypto differs.
                    try BundleCrypto.decryptFile(at: encDBURL, to: tmpURL)
                    defer {
                        try? fm.removeItem(at: tmpURL)
                        try? fm.removeItem(at: URL(fileURLWithPath: tmpURL.path + "-wal"))
                        try? fm.removeItem(at: URL(fileURLWithPath: tmpURL.path + "-shm"))
                    }

                    if let id = probeIdentityFromSQLite(at: tmpURL, openFlags: SQLITE_OPEN_READWRITE) {
                        return id
                    }
                } catch {
                    self.log.warning("extractPatientIdentity: failed to decrypt db.sqlite.enc for identity probe (\(String(describing: error), privacy: .public))")
                    try? fm.removeItem(at: tmpURL)
                }
            }
        }

        // 3) Folder-name heuristic as a last-resort identity (alias only)
        func aliasFromFolderName(_ name: String) -> String? {
            var cand = name
            if let r = cand.range(of: ".peMR", options: [.caseInsensitive]) {
                cand = String(cand[..<r.lowerBound])
            }
            if let r = cand.range(of: "-20") {
                cand = String(cand[..<r.lowerBound])
            }
            cand = cand.replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cand.isEmpty ? nil : cand
        }

        if let guess = aliasFromFolderName(bundleRoot.lastPathComponent) {
            return PatientIdentity(mrn: nil, alias: guess, dobISO: nil)
        }

        return nil
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
                let fmt = NSLocalizedString(
                    "appstate.archive_and_replace.failed_format",
                    comment: "Log when archiveAndReplace fails; %@ is the error description."
                )
                let line = String(format: fmt, String(describing: error))
                log.error("\(line, privacy: .public)")
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
            // Ensure bundle DB has the newest tables (idempotent) for well-visit growth evaluation.
            if let dbURL = self.currentDBURL {
                self.ensureWellVisitGrowthEvalSchema(at: dbURL)
            }
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
            let safeAlias: String = {
                let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
                return NSLocalizedString(
                    "appstate.new_patient.default_alias",
                    comment: "Default patient alias used when creating a new patient and the alias field is empty."
                )
            }()
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
            // Ensure well-visit growth evaluation storage exists (idempotent)
            ensureWellVisitGrowthEvalSchema(at: dbURL)


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

            let fmt = NSLocalizedString(
                "appstate.new_patient.created_bundle_format",
                comment: "Log when a new patient bundle is created. First %@ is the patient alias (log-safe), second %@ is the bundle folder name."
            )
            // Avoid logging raw alias or full filesystem paths.
            let aliasToken = obfuscatedToken(safeAlias)
            let bundleLabel = bundleURL.lastPathComponent
            let line = String(format: fmt, "ALIAS#\(aliasToken)", bundleLabel)
            log.info("\(line, privacy: .public)")

            // 6) Activate
            selectBundle(bundleURL)
            PerinatalStore.dbURLResolver = { [weak self] in self?.currentDBURL }
            self.loadPMHForSelectedPatient()
            return bundleURL
        }

        // MARK: - Visit Addenda (DB helpers)

        /// A small, DB-backed addendum attached to either a sick visit (episode) or a well visit.
        struct VisitAddendum: Identifiable, Hashable {
            let id: Int
            let episodeID: Int?
            let wellVisitID: Int?
            let userID: Int?
            let createdAtRaw: String?
            let updatedAtRaw: String?
            let text: String

            /// Best-effort parsed dates (SQLite CURRENT_TIMESTAMP is usually `yyyy-MM-dd HH:mm:ss`).
            var createdAt: Date? { AppState.parseSQLiteDate(createdAtRaw) }
            var updatedAt: Date? { AppState.parseSQLiteDate(updatedAtRaw) }
        }

        /// Best-effort: resolve the active *bundle* DB URL.
        /// We prefer `currentDBURL` when available; otherwise we derive it from the bundle root.
        private func activeBundleDBURL() -> URL? {
            if let u = self.currentDBURL { return u }
            guard let root = self.currentBundleURL else { return nil }
            let plain = root.appendingPathComponent("db.sqlite")
            if FileManager.default.fileExists(atPath: plain.path) { return plain }
            // DrsMainApp typically works with plaintext bundle DBs, but keep a fallback.
            let enc = root.appendingPathComponent("db.sqlite.enc")
            if FileManager.default.fileExists(atPath: enc.path) { return enc }
            return nil
        }
        
        // Expose DB URL to views while keeping the stored property private.
        var bundleDBURL: URL? { activeBundleDBURL() }

        /// List addenda for a sick visit episode.
        func listAddendaForEpisode(_ episodeID: Int) -> [VisitAddendum] {
            guard let dbURL = activeBundleDBURL() else { return [] }
            return fetchAddenda(whereSQL: "episode_id = ?", bindID: episodeID, dbURL: dbURL)
        }

        /// List addenda for a well visit.
        func listAddendaForWellVisit(_ wellVisitID: Int) -> [VisitAddendum] {
            guard let dbURL = activeBundleDBURL() else { return [] }
            return fetchAddenda(whereSQL: "well_visit_id = ?", bindID: wellVisitID, dbURL: dbURL)
        }

        /// Insert an addendum for a sick visit episode.
        /// - Returns: the inserted addendum row id, or nil on failure.
        @discardableResult
        func insertAddendumForEpisode(episodeID: Int, text: String, userID: Int? = nil) -> Int? {
            guard let dbURL = activeBundleDBURL() else { return nil }
            return insertAddendum(episodeID: episodeID, wellVisitID: nil, text: text, userID: userID, dbURL: dbURL)
        }

        /// Insert an addendum for a well visit.
        /// - Returns: the inserted addendum row id, or nil on failure.
        @discardableResult
        func insertAddendumForWellVisit(wellVisitID: Int, text: String, userID: Int? = nil) -> Int? {
            guard let dbURL = activeBundleDBURL() else { return nil }
            return insertAddendum(episodeID: nil, wellVisitID: wellVisitID, text: text, userID: userID, dbURL: dbURL)
        }

        // MARK: - Private addenda helpers

        private func fetchAddenda(whereSQL: String, bindID: Int, dbURL: URL) -> [VisitAddendum] {
            var out: [VisitAddendum] = []
            var db: OpaquePointer?
            if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
                if let db { sqlite3_close(db) }
                return out
            }
            guard let db = db else { return out }
            defer { sqlite3_close(db) }

            let sql = """
            SELECT id, episode_id, well_visit_id, user_id, created_at, updated_at, addendum_text
            FROM visit_addenda
            WHERE \(whereSQL)
            ORDER BY created_at ASC, id ASC;
            """

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                // Table missing or schema not applied yet: treat as empty.
                if let stmt { sqlite3_finalize(stmt) }
                return out
            }
            guard let stmt = stmt else { return out }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, Int64(bindID))

            func colText(_ i: Int32) -> String? {
                guard let c = sqlite3_column_text(stmt, i) else { return nil }
                let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? nil : s
            }
            func colIntOptional(_ i: Int32) -> Int? {
                if sqlite3_column_type(stmt, i) == SQLITE_NULL { return nil }
                return Int(sqlite3_column_int64(stmt, i))
            }

            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int64(stmt, 0))
                let ep = colIntOptional(1)
                let wv = colIntOptional(2)
                let uid = colIntOptional(3)
                let created = colText(4)
                let updated = colText(5)
                let text = colText(6) ?? ""

                out.append(
                    VisitAddendum(
                        id: id,
                        episodeID: ep,
                        wellVisitID: wv,
                        userID: uid,
                        createdAtRaw: created,
                        updatedAtRaw: updated,
                        text: text
                    )
                )
            }

            return out
        }

        private func insertAddendum(episodeID: Int?, wellVisitID: Int?, text: String, userID: Int?, dbURL: URL) -> Int? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            var db: OpaquePointer?
            if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
                if let db { sqlite3_close(db) }
                return nil
            }
            guard let db = db else { return nil }
            defer { sqlite3_close(db) }

            let sql = """
            INSERT INTO visit_addenda (episode_id, well_visit_id, user_id, addendum_text)
            VALUES (?, ?, ?, ?);
            """

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                if let stmt { sqlite3_finalize(stmt) }
                return nil
            }
            guard let stmt = stmt else { return nil }
            defer { sqlite3_finalize(stmt) }

            // Bind episode_id (1)
            if let ep = episodeID {
                sqlite3_bind_int64(stmt, 1, Int64(ep))
            } else {
                sqlite3_bind_null(stmt, 1)
            }

            // Bind well_visit_id (2)
            if let wv = wellVisitID {
                sqlite3_bind_int64(stmt, 2, Int64(wv))
            } else {
                sqlite3_bind_null(stmt, 2)
            }

            // Bind user_id (3)
            if let uid = userID {
                sqlite3_bind_int64(stmt, 3, Int64(uid))
            } else {
                sqlite3_bind_null(stmt, 3)
            }

            // Bind addendum_text (4)
            _ = trimmed.withCString { sqlite3_bind_text(stmt, 4, $0, -1, SQLITE_TRANSIENT) }

            if sqlite3_step(stmt) != SQLITE_DONE {
                return nil
            }

            return Int(sqlite3_last_insert_rowid(db))
        }

        /// Parse a date string coming from SQLite.
        /// Supports `yyyy-MM-dd HH:mm:ss` (CURRENT_TIMESTAMP) and ISO-8601 variants.
        nonisolated private static func parseSQLiteDate(_ raw: String?) -> Date? {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }

            // 1) ISO-8601 (with or without fractional seconds)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: raw) { return d }
            let iso2 = ISO8601DateFormatter()
            iso2.formatOptions = [.withInternetDateTime]
            if let d = iso2.date(from: raw) { return d }

            // 2) SQLite CURRENT_TIMESTAMP default
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let d = df.date(from: raw) { return d }

            // 3) SQLite with fractional seconds
            let df2 = DateFormatter()
            df2.locale = Locale(identifier: "en_US_POSIX")
            df2.timeZone = TimeZone(secondsFromGMT: 0)
            df2.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            return df2.date(from: raw)
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
            let errMsg = NSLocalizedString(
                "appstate.golden_db.not_found_in_bundle",
                comment: "Error shown when the bundled golden.db database resource cannot be found."
            )
            throw NSError(domain: "AppState", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: errMsg])
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
    /// Generic, idempotent-friendly runner:
    /// - Applies the full script from bundled `schema.sql`.
    /// - Does NOT stop at the first statement error (sqlite3_exec would).
    /// - Continues statement-by-statement, ignoring common idempotency errors.
    private func applySQLFile(_ sqlURL: URL, to dbURL: URL) {
        guard var sqlText = try? String(contentsOf: sqlURL, encoding: .utf8) else {
            log.warning("applySQLFile: failed to read sql at \(sqlURL.lastPathComponent, privacy: .public)")
            return
        }

        // Normalize newlines for stable parsing.
        sqlText = sqlText.replacingOccurrences(of: "\r\n", with: "\n")

        // Strip UTF-8 BOM if present (can break sqlite parsing in some cases).
        if sqlText.hasPrefix("\u{FEFF}") {
            sqlText.removeFirst()
        }

        // Make common CREATE statements idempotent to reduce noisy failures.
        // (This is generic and safe for schema overlay use.)
        func injectIfNotExists(_ pattern: String, replacement: String) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            let range = NSRange(location: 0, length: (sqlText as NSString).length)
            sqlText = re.stringByReplacingMatches(in: sqlText, options: [], range: range, withTemplate: replacement)
        }

        // TRIGGERS
        injectIfNotExists(
            "(?i)\\bCREATE\\s+TRIGGER\\s+(?!IF\\s+NOT\\s+EXISTS\\b)",
            replacement: "CREATE TRIGGER IF NOT EXISTS "
        )
        // INDEXES (including UNIQUE)
        injectIfNotExists(
            "(?i)\\bCREATE\\s+UNIQUE\\s+INDEX\\s+(?!IF\\s+NOT\\s+EXISTS\\b)",
            replacement: "CREATE UNIQUE INDEX IF NOT EXISTS "
        )
        injectIfNotExists(
            "(?i)\\bCREATE\\s+INDEX\\s+(?!IF\\s+NOT\\s+EXISTS\\b)",
            replacement: "CREATE INDEX IF NOT EXISTS "
        )
        // VIEWS
        injectIfNotExists(
            "(?i)\\bCREATE\\s+VIEW\\s+(?!IF\\s+NOT\\s+EXISTS\\b)",
            replacement: "CREATE VIEW IF NOT EXISTS "
        )

        var db: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
            if let db { sqlite3_close(db) }
            log.error("applySQLFile: sqlite open failed for \(dbURL.lastPathComponent, privacy: .public)")
            return
        }
        guard let db = db else { return }
        defer { sqlite3_close(db) }

        // Wrap in a transaction for speed and consistency.
        _ = sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

        // IMPORTANT: do NOT split on semicolons.
        // Triggers can contain semicolons inside BEGIN...END blocks.
        // Instead, let SQLite parse the script statement-by-statement via prepare_v2 + tail.
        let bytes = Array(sqlText.utf8CString)
        var idx = 0

        // Generic idempotency errors we can ignore while overlaying schema.
        func isIgnorableSchemaError(_ msg: String) -> Bool {
            let m = msg.lowercased()
            return m.contains("already exists")
                || m.contains("duplicate column")
                || m.contains("duplicate")
        }

        var executedCount = 0
        var ignoredErrorCount = 0

        // Cache PRAGMA table_info results so we don't re-query for every ALTER.
        var tableColsCache: [String: Set<String>] = [:]

        func unquoteIdent(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("`") && t.hasSuffix("`")) {
                t.removeFirst()
                t.removeLast()
            }
            return t
        }

        // Detect "ALTER TABLE <table> ADD COLUMN <col> ..." and skip if the column already exists.
        // This prevents noisy "duplicate column name" errors that can leak into system logs.
        let alterAddColumnRE: NSRegularExpression? = try? NSRegularExpression(
            pattern: "(?i)^\\s*ALTER\\s+TABLE\\s+([A-Za-z0-9_\"`]+)\\s+ADD\\s+COLUMN\\s+([A-Za-z0-9_\"`]+)\\b",
            options: []
        )

        func shouldSkipAlterAddColumn(_ sql: String) -> Bool {
            guard let re = alterAddColumnRE else { return false }
            let ns = sql as NSString
            let full = NSRange(location: 0, length: ns.length)
            guard let m = re.firstMatch(in: sql, options: [], range: full) else { return false }
            if m.numberOfRanges < 3 { return false }

            let tableRaw = ns.substring(with: m.range(at: 1))
            let colRaw   = ns.substring(with: m.range(at: 2))
            let table = unquoteIdent(tableRaw)
            let col   = unquoteIdent(colRaw)

            if table.isEmpty || col.isEmpty { return false }

            let cols: Set<String>
            if let cached = tableColsCache[table] {
                cols = cached
            } else {
                let fetched = Set(columnSet(of: table, db: db).map { $0.lowercased() })
                tableColsCache[table] = fetched
                cols = fetched
            }

            return cols.contains(col.lowercased())
        }

        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }

            while idx < buf.count {
                // Skip leading whitespace.
                while idx < buf.count {
                    let c = base.advanced(by: idx).pointee
                    if c == 0 { return }
                    if c == 32 || c == 9 || c == 10 || c == 13 { // space, tab, \n, \r
                        idx += 1
                        continue
                    }
                    break
                }

                if idx >= buf.count { break }
                if base.advanced(by: idx).pointee == 0 { break }

                var stmt: OpaquePointer?
                var tail: UnsafePointer<CChar>?

                let start = base.advanced(by: idx)
                let prepRC = sqlite3_prepare_v2(db, start, -1, &stmt, &tail)
                if prepRC != SQLITE_OK {
                    // If parsing fails, bail out to avoid infinite loops.
                    // (Bundled schema.sql should be valid.)
                    break
                }

                // If SQLite reports no statement (e.g., only comments/whitespace), we're done.
                guard let stmt = stmt else { break }

                // If this is an ALTER TABLE ... ADD COLUMN ... for a column that already exists,
                // skip executing it entirely to avoid producing system/SQLite error logs.
                if let stmtSQLPtr = sqlite3_sql(stmt) {
                    let stmtSQL = String(cString: stmtSQLPtr)
                    if shouldSkipAlterAddColumn(stmtSQL) {
                        ignoredErrorCount += 1
                        sqlite3_finalize(stmt)

                        // Advance to next statement using the tail pointer.
                        if let tail = tail {
                            let newIdx = Int(tail - base)
                            if newIdx <= idx {
                                idx += 1
                            } else {
                                idx = newIdx
                            }
                        } else {
                            break
                        }
                        continue
                    }
                }

                executedCount += 1

                // Execute statement; some statements may produce rows.
                var stepRC = sqlite3_step(stmt)
                while stepRC == SQLITE_ROW {
                    stepRC = sqlite3_step(stmt)
                }

                if stepRC != SQLITE_DONE {
                    let msg = String(cString: sqlite3_errmsg(db))
                    if isIgnorableSchemaError(msg) {
                        ignoredErrorCount += 1
                    }
                    // Otherwise: non-fatal; continue to next statement.
                }

                sqlite3_finalize(stmt)

                // Advance to next statement using the tail pointer.
                if let tail = tail {
                    let newIdx = Int(tail - base)
                    if newIdx <= idx {
                        // Safety to avoid infinite loops.
                        idx += 1
                    } else {
                        idx = newIdx
                    }
                } else {
                    break
                }
            }
        }

        // Commit; if commit fails, rollback.
        if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            let msg = String(cString: sqlite3_errmsg(db))
            log.error("applySQLFile: commit failed err=\(msg, privacy: .public)")
        } else {
            log.info("applySQLFile: applied \(sqlURL.lastPathComponent, privacy: .public) statements=\(executedCount, privacy: .public) ignored=\(ignoredErrorCount, privacy: .public)")
        }
    }

    /// Convenience: apply bundled schema.sql to the given db (no-op if missing).
    private func applyBundledSchemaIfPresent(to dbURL: URL) {
        guard let url = bundledSchemaSQLURL() else {
            self.log.warning("applyBundledSchemaIfPresent: schema.sql not found in bundle resources")
            return
        }
        self.log.info("applyBundledSchemaIfPresent: applying \(url.lastPathComponent, privacy: .public) to \(dbURL.lastPathComponent, privacy: .public)")
        applySQLFile(url, to: dbURL)
    }
    
    // MARK: - Soft-delete schema for visits (bundle DB)

    /// Ensure soft-delete columns exist on visit tables.
    ///
    /// Targeted + idempotent, so older bundle DBs are upgraded safely.
    /// Deleted visits remain reversible and can be excluded from UI/export by filtering `is_deleted = 0`.
    private func ensureSoftDeleteVisitSchema(at dbURL: URL) {
        var db: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
            if let db { sqlite3_close(db) }
            log.warning("ensureSoftDeleteVisitSchema: sqlite open failed for \(dbURL.lastPathComponent, privacy: .public)")
            return
        }
        guard let db = db else { return }
        defer { sqlite3_close(db) }

        // Best-effort bump user_version to at least 2.
        // Not required for correctness (columns are), but helpful for diagnostics.
        var version: Int32 = 0
        var vStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &vStmt, nil) == SQLITE_OK, let vStmt = vStmt {
            defer { sqlite3_finalize(vStmt) }
            if sqlite3_step(vStmt) == SQLITE_ROW {
                version = sqlite3_column_int(vStmt, 0)
            }
        }
        if version < 2 {
            _ = sqlite3_exec(db, "PRAGMA user_version=2;", nil, nil, nil)
        }

        // Episodes: add soft-delete columns (avoid executing duplicate ALTERs to prevent noisy system logs).
        let epCols = Set(columnSet(of: "episodes", db: db).map { $0.lowercased() })
        if !epCols.contains("is_deleted") {
            _ = sqlite3_exec(db, "ALTER TABLE episodes ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0", nil, nil, nil)
        }
        if !epCols.contains("deleted_at") {
            _ = sqlite3_exec(db, "ALTER TABLE episodes ADD COLUMN deleted_at TEXT", nil, nil, nil)
        }
        if !epCols.contains("deleted_reason") {
            _ = sqlite3_exec(db, "ALTER TABLE episodes ADD COLUMN deleted_reason TEXT", nil, nil, nil)
        }

        // Well visits: add soft-delete columns (avoid executing duplicate ALTERs to prevent noisy system logs).
        let wvCols = Set(columnSet(of: "well_visits", db: db).map { $0.lowercased() })
        if !wvCols.contains("is_deleted") {
            _ = sqlite3_exec(db, "ALTER TABLE well_visits ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0", nil, nil, nil)
        }
        if !wvCols.contains("deleted_at") {
            _ = sqlite3_exec(db, "ALTER TABLE well_visits ADD COLUMN deleted_at TEXT", nil, nil, nil)
        }
        if !wvCols.contains("deleted_reason") {
            _ = sqlite3_exec(db, "ALTER TABLE well_visits ADD COLUMN deleted_reason TEXT", nil, nil, nil)
        }

        // Helpful indexes for filtering.
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_episodes_patient_not_deleted ON episodes(patient_id, is_deleted);", nil, nil, nil)
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_well_visits_patient_not_deleted ON well_visits(patient_id, is_deleted);", nil, nil, nil)
    }

    // MARK: - Well-visit growth evaluation schema (bundle DB)

    /// Ensure the storage table for well-visit growth evaluations exists.
    ///
    /// This is intentionally *idempotent* and safe to run on every app launch / bundle select.
    /// We prefer a targeted migration (just the needed table + columns) instead of applying the
    /// full bundled schema.sql to an existing patient bundle.
    private func ensureWellVisitGrowthEvalSchema(at dbURL: URL) {
        var db: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
            if let db { sqlite3_close(db) }
            log.warning("ensureWellVisitGrowthEvalSchema: sqlite open failed for \(dbURL.lastPathComponent, privacy: .public)")
            return
        }
        guard let db = db else { return }
        defer { sqlite3_close(db) }

        // Create table (safe if it already exists).
        let createSQL = """
        CREATE TABLE IF NOT EXISTS well_visit_growth_eval (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          well_visit_id INTEGER NOT NULL UNIQUE,
          is_flagged INTEGER NOT NULL DEFAULT 0,
          basis TEXT,
          tokens_json TEXT NOT NULL DEFAULT '[]',
          z_summary TEXT,
          nutrition_line TEXT,
          trend_summary TEXT,
          created_at TEXT DEFAULT CURRENT_TIMESTAMP,
          updated_at TEXT
        );
        """

        if sqlite3_exec(db, createSQL, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            log.warning("ensureWellVisitGrowthEvalSchema: create table failed err=\(msg, privacy: .public)")
            return
        }

        // Helpful index for lookups (safe if it already exists).
        _ = sqlite3_exec(
            db,
            "CREATE INDEX IF NOT EXISTS idx_well_visit_growth_eval_well_visit_id ON well_visit_growth_eval(well_visit_id);",
            nil, nil, nil
        )

        // Best-effort add missing columns for older DBs without triggering duplicate-column errors.
        let cols = Set(columnSet(of: "well_visit_growth_eval", db: db).map { $0.lowercased() })

        if !cols.contains("is_flagged") {
            _ = sqlite3_exec(db, "ALTER TABLE well_visit_growth_eval ADD COLUMN is_flagged INTEGER NOT NULL DEFAULT 0", nil, nil, nil)
        }
        if !cols.contains("basis") {
            _ = sqlite3_exec(db, "ALTER TABLE well_visit_growth_eval ADD COLUMN basis TEXT", nil, nil, nil)
        }
        if !cols.contains("tokens_json") {
            _ = sqlite3_exec(db, "ALTER TABLE well_visit_growth_eval ADD COLUMN tokens_json TEXT NOT NULL DEFAULT '[]'", nil, nil, nil)
        }
        if !cols.contains("z_summary") {
            _ = sqlite3_exec(db, "ALTER TABLE well_visit_growth_eval ADD COLUMN z_summary TEXT", nil, nil, nil)
        }
        if !cols.contains("nutrition_line") {
            _ = sqlite3_exec(db, "ALTER TABLE well_visit_growth_eval ADD COLUMN nutrition_line TEXT", nil, nil, nil)
        }
        if !cols.contains("trend_summary") {
            _ = sqlite3_exec(db, "ALTER TABLE well_visit_growth_eval ADD COLUMN trend_summary TEXT", nil, nil, nil)
        }
        if !cols.contains("created_at") {
            _ = sqlite3_exec(db, "ALTER TABLE well_visit_growth_eval ADD COLUMN created_at TEXT DEFAULT CURRENT_TIMESTAMP", nil, nil, nil)
        }
        if !cols.contains("updated_at") {
            _ = sqlite3_exec(db, "ALTER TABLE well_visit_growth_eval ADD COLUMN updated_at TEXT", nil, nil, nil)
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
                let fmt = NSLocalizedString(
                    "appstate.db.open_failed_at_path_format",
                    comment: "Error shown when SQLite cannot open a database file. %@ is the file path."
                )
                let line = String(format: fmt, path)
                throw NSError(domain: "SQLite", code: Int(code), userInfo: [NSLocalizedDescriptionKey: line])
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
                let fmt = NSLocalizedString(
                    "appstate.db.schema_init_failed_format",
                    comment: "Error shown when initializing the minimal SQLite schema fails. %@ is the sqlite error."
                )
                let line = String(format: fmt, msg)
                throw NSError(domain: "SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: line])
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
                let fmt = NSLocalizedString(
                    "appstate.db.open_failed_at_path_format",
                    comment: "Error shown when SQLite cannot open a database file. %@ is the file path."
                )
                let line = String(format: fmt, path)
                throw NSError(domain: "SQLite", code: Int(code), userInfo: [NSLocalizedDescriptionKey: line])
            }
            defer { sqlite3_close(db) }

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withFullDate]
            let dobStr = dob.map { iso.string(from: $0) }

            let sql = """
                        INSERT INTO patients (alias_label, alias_id, mrn, first_name, last_name, dob, sex)
                        VALUES (?, ?, ?, ?, ?, ?, ?);
                        """

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                let fmt = NSLocalizedString(
                    "appstate.db.prepare_failed_format",
                    comment: "Error shown when preparing a SQLite statement fails. %@ is the sqlite error."
                )
                let line = String(format: fmt, msg)
                throw NSError(domain: "SQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: line])
            }
            defer { sqlite3_finalize(stmt) }

            // Bind parameters (1-based)
            _ = aliasLabel.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }  // alias_label
            _ = aliasID.withCString    { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }  // alias_id
            _ = mrn.withCString        { sqlite3_bind_text(stmt, 3, $0, -1, SQLITE_TRANSIENT) }  // mrn

            if let fn = firstName?.trimmingCharacters(in: .whitespacesAndNewlines), !fn.isEmpty {
                _ = fn.withCString { sqlite3_bind_text(stmt, 4, $0, -1, SQLITE_TRANSIENT) }      // first_name
            } else {
                sqlite3_bind_null(stmt, 4)
            }

            if let ln = lastName?.trimmingCharacters(in: .whitespacesAndNewlines), !ln.isEmpty {
                _ = ln.withCString { sqlite3_bind_text(stmt, 5, $0, -1, SQLITE_TRANSIENT) }      // last_name
            } else {
                sqlite3_bind_null(stmt, 5)
            }

            if let ds = dobStr, !ds.isEmpty {
                _ = ds.withCString { sqlite3_bind_text(stmt, 6, $0, -1, SQLITE_TRANSIENT) }      // dob
            } else {
                sqlite3_bind_null(stmt, 6)
            }

            if let sx = sex?.trimmingCharacters(in: .whitespacesAndNewlines), !sx.isEmpty {
                _ = sx.withCString { sqlite3_bind_text(stmt, 7, $0, -1, SQLITE_TRANSIENT) }      // sex
            } else {
                sqlite3_bind_null(stmt, 7)
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(db))
                let fmt = NSLocalizedString(
                    "appstate.db.insert_failed_format",
                    comment: "Error shown when inserting into SQLite fails. %@ is the sqlite error."
                )
                let line = String(format: fmt, msg)
                throw NSError(domain: "SQLite", code: 3, userInfo: [NSLocalizedDescriptionKey: line])
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
        private func relativePath(from base: URL, to target: URL) -> String? {
            let baseC = base.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            let targC = target.standardizedFileURL.resolvingSymlinksInPath().pathComponents

            guard targC.starts(with: baseC) else { return nil }
            return targC.dropFirst(baseC.count).joined(separator: "/")
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
                        guard let rel = relativePath(from: bundleRoot, to: url) else { continue }
                        entries.append([
                            "path": rel,
                            "sha256": sha256OfFile(at: url)
                        ])
                    }
                }
            }
            return entries
        }

        /// Validate bundle integrity against manifest.json (if present).
        ///
        /// - Returns `true` if:
        ///   • There is no manifest, or
        ///   • The manifest has no usable hash fields for the DB payload, or
        ///   • The relevant DB payload hash matches the manifest (docs mismatches are logged but non‑fatal).
        /// - Returns `false` only when a manifest explicitly declares a hash for the DB payload and the
        ///   corresponding DB file on disk does not match or cannot be hashed.
        private func validateBundleIntegrity(at bundleRoot: URL) -> Bool {
            let fm = FileManager.default
            let manifestURL = bundleRoot.appendingPathComponent("manifest.json")

            // No manifest at all → nothing to validate, stay backward‑compatible.
            guard fm.fileExists(atPath: manifestURL.path) else {
                return true
            }

            do {
                let data = try Data(contentsOf: manifestURL)
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    // Malformed manifest → treat as non‑fatal for now, but log.
                    let fmt = NSLocalizedString(
                        "appstate.manifest.validate.not_dictionary_format",
                        comment: "Log when manifest.json is not a dictionary. %@ is the manifest file name."
                    )
                    let line = String(format: fmt, manifestURL.lastPathComponent)
                    log.warning("\(line, privacy: .public)")
                    return true
                }

                let encryptedFlag = (obj["encrypted"] as? Bool) ?? false
                let plainDB = bundleRoot.appendingPathComponent("db.sqlite")
                let encDB   = bundleRoot.appendingPathComponent("db.sqlite.enc")

                // Helper: find a per-file hash inside legacy DrsMainApp manifests that include `files: [{path, sha256}, ...]`.
                func fileHashFromFilesList(for relativePath: String) -> String? {
                    guard let files = obj["files"] as? [[String: Any]] else { return nil }
                    for entry in files {
                        guard let p = (entry["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                              p == relativePath else { continue }
                        let h = (entry["sha256"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        return (h?.isEmpty == false) ? h : nil
                    }
                    return nil
                }

                // Decide which DB payload we can/should validate and which expected hash applies.
                // There are two common patterns:
                //  1) PatientViewerApp-style (schema_version>=2): `db_sha256` hashes the *payload file* present in the bundle
                //     (plain db.sqlite for unencrypted bundles; db.sqlite.enc for encrypted bundles).
                //  2) DrsMainApp encrypted file-list manifests: `db_sha256` hashes the *plaintext* db.sqlite, but the bundle
                //     contains only db.sqlite.enc; the encrypted file's hash is stored in `files[]` under path `db.sqlite.enc`.

                var dbURLToHash: URL?
                var expectedHash: String?

                // Prefer verifying plaintext db.sqlite against db_sha256 when plaintext is present.
                if fm.fileExists(atPath: plainDB.path) {
                    dbURLToHash = plainDB
                    expectedHash = (obj["db_sha256"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if fm.fileExists(atPath: encDB.path) {
                    dbURLToHash = encDB

                    if encryptedFlag {
                        // If the manifest includes a per-file list, prefer the explicit hash for db.sqlite.enc.
                        if let encExpected = fileHashFromFilesList(for: "db.sqlite.enc") {
                            expectedHash = encExpected
                        } else {
                            // Fall back to db_sha256 (PatientViewerApp-style encrypted exports).
                            expectedHash = (obj["db_sha256"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } else {
                        // Manifest says unencrypted but only enc exists → best-effort fallback.
                        // Prefer files[] hash if present; else fall back to db_sha256.
                        expectedHash = fileHashFromFilesList(for: "db.sqlite.enc")
                            ?? (obj["db_sha256"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } else {
                    let fmt = NSLocalizedString(
                        "appstate.manifest.validate.no_db_files_found_under_format",
                        comment: "Log when neither db.sqlite nor db.sqlite.enc is found during manifest validation. %@ is the bundle identifier (folder name), not a full filesystem path."
                    )
                    // Avoid leaking full filesystem paths in logs; keep only the folder name.
                    let bundleRef = bundleRoot.lastPathComponent
                    let line = String(format: fmt, bundleRef)
                    log.error("\(line, privacy: .private)")
                    return false
                }

                // If there is no usable expected hash, we cannot validate DB integrity – accept but log.
                guard let dbURL = dbURLToHash,
                      let expected = expectedHash?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !expected.isEmpty else {
                    let msg = NSLocalizedString(
                        "appstate.manifest.validate.no_db_sha256_skip",
                        comment: "Log when manifest has no db_sha256 (or usable db hash) and DB hash validation is skipped."
                    )
                    log.info("\(msg, privacy: .public)")
                    return true
                }

                let actualHash = sha256OfFile(at: dbURL)
                guard !actualHash.isEmpty else {
                    let fmt = NSLocalizedString(
                        "appstate.manifest.validate.failed_to_compute_db_hash_format",
                        comment: "Log when computing the DB SHA-256 fails. %@ is the DB file path."
                    )
                    let line = String(format: fmt, dbURL.path)
                    log.error("\(line, privacy: .public)")
                    return false
                }

                if actualHash.lowercased() != expected.lowercased() {
                    let fmt = NSLocalizedString(
                        "appstate.manifest.validate.db_hash_mismatch_format",
                        comment: "Log when bundle DB hash mismatches manifest. %@ is bundle identifier (not full path), %@ expected hash, %@ actual hash."
                    )

                    // Avoid leaking full filesystem paths in logs; keep only the folder name.
                    let bundleRef = bundleRoot.lastPathComponent
                    let line = String(format: fmt, bundleRef, expected, actualHash)
                    log.error("\(line, privacy: .private)")
                    return false
                }

                // Optionally validate docs_manifest, but treat mismatches as warnings only.
                if let docsArray = obj["docs_manifest"] as? [[String: Any]], !docsArray.isEmpty {
                    for entry in docsArray {
                        guard let relPath = (entry["path"] as? String)?
                                .trimmingCharacters(in: .whitespacesAndNewlines),
                              !relPath.isEmpty else { continue }
                        let expectedDocHash = (entry["sha256"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                        let docURL = bundleRoot.appendingPathComponent(relPath)
                        guard fm.fileExists(atPath: docURL.path) else {
                            let fmt = NSLocalizedString(
                                "appstate.manifest.validate.docs_entry_missing_format",
                                comment: "Log when a docs_manifest entry is missing on disk. %@ is the relative docs path."
                            )
                            let line = String(format: fmt, relPath)
                            log.warning("\(line, privacy: .public)")
                            continue
                        }

                        let actualDocHash = sha256OfFile(at: docURL)
                        if !expectedDocHash.isEmpty,
                           !actualDocHash.isEmpty,
                           actualDocHash.lowercased() != expectedDocHash.lowercased() {
                            let fmt = NSLocalizedString(
                                "appstate.manifest.validate.docs_hash_mismatch_format",
                                comment: "Log when a docs file hash mismatches the manifest. %@ is relative path, %@ expected hash, %@ actual hash."
                            )
                            let line = String(format: fmt, relPath, expectedDocHash, actualDocHash)
                            log.warning("\(line, privacy: .public)")
                        }
                    }
                }

                // All checks passed or only non‑fatal warnings → accept bundle.
                return true
            } catch {
                let fmt = NSLocalizedString(
                    "appstate.manifest.validate.read_parse_failed_format",
                    comment: "Log when reading/parsing manifest fails. First %@ is manifest path, second %@ is the error."
                )
                let line = String(format: fmt, manifestURL.path, String(describing: error))
                log.warning("\(line, privacy: .public)")
                // Treat manifest read errors as non‑fatal to stay compatible.
                return true
            }
        }

        /// Write/refresh a v2 peMR manifest.json at the given bundle root.
        /// Safe to call before exporting a bundle; idempotent and tolerant of missing bits.
        @discardableResult
        func writeManifestV2(bundleRoot: URL) -> Bool {
            let fm = FileManager.default

            let manifestURL = bundleRoot.appendingPathComponent("manifest.json")
            let dbPlainURL = bundleRoot.appendingPathComponent("db.sqlite")
            let dbEncURL   = bundleRoot.appendingPathComponent("db.sqlite.enc")
            let docsURL    = bundleRoot.appendingPathComponent("docs", isDirectory: true)

            // Determine DB payload present in this bundle.
            let hasPlain = fm.fileExists(atPath: dbPlainURL.path)
            let hasEnc   = fm.fileExists(atPath: dbEncURL.path)

            // If no DB payload at all, we cannot create a meaningful v2 manifest.
            guard hasPlain || hasEnc else {
                let fmt = NSLocalizedString(
                    "appstate.manifest.write_v2.no_db_payload_format",
                    comment: "Log when writeManifestV2 cannot find db.sqlite or db.sqlite.enc. %@ is the bundle identifier (folder name), not a full filesystem path."
                )
                let bundleRef = bundleRoot.lastPathComponent
                let line = String(format: fmt, bundleRef)
                log.warning("\(line, privacy: .private)")
                return false
            }

            // Read existing manifest (if any) to preserve encryption_scheme if already present.
            var existingScheme: String? = nil
            if fm.fileExists(atPath: manifestURL.path),
               let data = try? Data(contentsOf: manifestURL),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                existingScheme = (obj["encryption_scheme"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Identity: prefer DB/manifest via existing helper (handles encrypted bundles too).
            let identity = extractPatientIdentity(from: bundleRoot)

            // Attempt to read patient_id from plaintext DB when available.
            var patientID: Int? = nil
            if hasPlain {
                var db: OpaquePointer?
                if sqlite3_open_v2(dbPlainURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                    defer { sqlite3_close(db) }
                    let cols = columnSet(of: "patients", db: db)
                    if cols.contains("id") {
                        let sql = "SELECT id FROM patients ORDER BY id LIMIT 1;"
                        var stmt: OpaquePointer?
                        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt {
                            defer { sqlite3_finalize(stmt) }
                            if sqlite3_step(stmt) == SQLITE_ROW {
                                patientID = Int(sqlite3_column_int64(stmt, 0))
                            }
                        }
                    }
                }
            }

            // Hash DB payload that actually exists in the bundle.
            let dbPayloadURL: URL = hasPlain ? dbPlainURL : dbEncURL
            let dbSha256 = sha256OfFile(at: dbPayloadURL)

            // Docs manifest entries with relative paths (under 'docs/') and sha256.
            let docsManifest = buildDocsManifest(docsRoot: docsURL, bundleRoot: bundleRoot)

            // Build a backward-friendly flat file list (db payload + docs files).
            let filesList: [[String: Any]] = buildFilesList(bundleRoot: bundleRoot)

            // Compose v2 manifest.
            let iso = ISO8601DateFormatter()
            let nowISO = iso.string(from: Date())

            var out: [String: Any] = [
                "format": "peMR",
                "version": 1,
                "schema_version": 2,
                // Encryption metadata reflects the payload present.
                "encrypted": hasEnc && !hasPlain,
                "exported_at": nowISO,
                "source": "DrsMainApp",
                "includes_docs": !docsManifest.isEmpty,
                // DB payload hash: hashes the file that actually exists (db.sqlite OR db.sqlite.enc).
                "db_sha256": dbSha256,
                "docs_manifest": docsManifest,
                // Keep legacy-style list for older tooling/debuggability.
                "files": filesList
            ]

            if (hasEnc && !hasPlain) {
                // Preserve an existing scheme if we have it; else default to AES-GCM-v1.
                out["encryption_scheme"] = (existingScheme?.isEmpty == false) ? existingScheme! : "AES-GCM-v1"
            }

            if let patientID { out["patient_id"] = patientID }

            if let mrn = identity?.mrn, !mrn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out["mrn"] = mrn
            }
            if let alias = identity?.alias, !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out["patient_alias"] = alias
            }
            if let dob = identity?.dobISO, !dob.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Normalize to YYYY-MM-DD if possible (tolerate full ISO)
                if let day = dob.split(separator: "T").first {
                    out["dob"] = String(day)
                } else {
                    out["dob"] = dob
                }
            }

            do {
                let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: manifestURL, options: .atomic)
                return true
            } catch {
                let fmt = NSLocalizedString(
                    "appstate.manifest.write_v2.failed_format",
                    comment: "Log when writing manifest.json v2 fails. %@ is the error description."
                )
                let line = String(format: fmt, String(describing: error))
                log.error("\(line, privacy: .public)")
                return false
            }
        }

        /// Best-effort upgrade of legacy manifests to the current v2 schema.
        /// Returns true if we wrote a refreshed manifest, false if skipped or failed.
        @discardableResult
        private func upgradeBundleManifestIfNeeded(at bundleRoot: URL) -> Bool {
            let fm = FileManager.default
            let manifestURL = bundleRoot.appendingPathComponent("manifest.json")

            // If there's no manifest at all, write a fresh v2 one.
            guard fm.fileExists(atPath: manifestURL.path) else {
                return writeManifestV2(bundleRoot: bundleRoot)
            }

            // If manifest exists, decide if it already looks like healthy v2.
            if let data = try? Data(contentsOf: manifestURL),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let format = (obj["format"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let schemaVersion = obj["schema_version"] as? Int
                let hasDbSha = ((obj["db_sha256"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                let hasIdentity = (
                    ((obj["patient_alias"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    || ((obj["mrn"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    || ((obj["dob"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                )

                let looksHealthyV2 = (format == "pemr") && ((schemaVersion ?? 0) >= 2) && hasDbSha && hasIdentity
                if looksHealthyV2 {
                    return false
                }
            }

            // Refresh to v2 (non-fatal if it fails).
            return writeManifestV2(bundleRoot: bundleRoot)
        }

        /// Build a flat file list similar to exporter manifests for backward compatibility.
        /// Includes db payload (db.sqlite or db.sqlite.enc) and docs/** files.
        private func buildFilesList(bundleRoot: URL) -> [[String: Any]] {
            let fm = FileManager.default
            var out: [[String: Any]] = []
            let iso = ISO8601DateFormatter()

            guard let enumerator = fm.enumerator(
                at: bundleRoot,
                includingPropertiesForKeys: [
                    URLResourceKey.isDirectoryKey,
                    URLResourceKey.fileSizeKey,
                    URLResourceKey.contentModificationDateKey
                ],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                log.warning("buildFilesList: failed to enumerate bundle root \(bundleRoot.lastPathComponent, privacy: .private)")
                return out
            }

            for case let url as URL in enumerator {
                if url == bundleRoot { continue }
                let name = url.lastPathComponent
                if name == ".DS_Store" || name == "__MACOSX" || name.hasPrefix("._") { continue }
                if name == "manifest.json" { continue }

                let vals = try? url.resourceValues(forKeys: [
                    URLResourceKey.isDirectoryKey,
                    URLResourceKey.fileSizeKey,
                    URLResourceKey.contentModificationDateKey
                ])
                if vals?.isDirectory == true { continue }

                let relPath = url.path.replacingOccurrences(of: bundleRoot.path + "/", with: "")
                let sha = sha256OfFile(at: url)

                out.append([
                    "path": relPath,
                    "size": vals?.fileSize ?? 0,
                    "modified": iso.string(from: vals?.contentModificationDate ?? Date()),
                    "sha256": sha
                ])
            }

            // Stable ordering for deterministic manifests.
            out.sort {
                let a = ($0["path"] as? String) ?? ""
                let b = ($1["path"] as? String) ?? ""
                return a.localizedStandardCompare(b) == .orderedAscending
            }

            return out
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
                let fmt = NSLocalizedString(
                    "appstate.db.open_failed_at_path_format",
                    comment: "Error shown when SQLite cannot open a database file. %@ is the file path."
                )
                let line = String(format: fmt, path)
                throw NSError(domain: "SQLite", code: Int(code), userInfo: [NSLocalizedDescriptionKey: line])
            }
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT id FROM patients ORDER BY id DESC LIMIT 1;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                let fmt = NSLocalizedString(
                    "appstate.db.prepare_failed_format",
                    comment: "Error shown when preparing a SQLite statement fails. %@ is the sqlite error."
                )
                let line = String(format: fmt, msg)
                throw NSError(domain: "SQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: line])
            }
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                let errMsg = NSLocalizedString(
                    "appstate.db.no_patient_row_found",
                    comment: "Error shown when no patient row can be found in the patients table."
                )
                throw NSError(domain: "SQLite", code: 3, userInfo: [NSLocalizedDescriptionKey: errMsg])
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
    // MARK: - Bundle deletion (remove stored bundle from app container)
    /// Deletes a stored bundle folder from the app's container and removes it from recents.
    /// Note: This does NOT delete a patient row from the bundle DB; it removes the whole bundle.
    @MainActor
    func deleteBundle(_ url: URL) {
        let fm = FileManager.default

        // Resolve wrapper -> canonical (best-effort). Always operate on standardized, symlink-resolved paths.
        let canonical0 = canonicalBundleRoot(at: url) ?? url
        let canonical = canonical0.standardizedFileURL.resolvingSymlinksInPath()
        let wrapper   = url.standardizedFileURL.resolvingSymlinksInPath()

        let canonicalPath = canonical.path
        let wrapperPath   = wrapper.path

        // Capture parents BEFORE deletion so we can remove empty wrapper folders afterwards.
        let canonicalParent = canonical.deletingLastPathComponent()
        let wrapperParent   = wrapper.deletingLastPathComponent()

        // Avoid logging raw bundle names or filesystem paths; use log-safe references.
        let canonicalRef = AppLog.bundleRef(canonical)
        let wrapperRef   = AppLog.bundleRef(wrapper)
        AppLog.bundle.info("deleteBundle: requested=\(wrapperRef, privacy: .public) canonical=\(canonicalRef, privacy: .public)")

        // 1) Delete canonical folder (real bundle root)
        if fm.fileExists(atPath: canonical.path) {
            do {
                try fm.removeItem(at: canonical)
                AppLog.bundle.info("deleteBundle: removed canonical \(canonicalRef, privacy: .public)")
            } catch {
                AppLog.bundle.error("deleteBundle: failed removing canonical \(canonicalRef, privacy: .public) — \(String(describing: error), privacy: .private(mask: .hash))")
            }
        } else {
            AppLog.bundle.info("deleteBundle: canonical already missing \(canonicalRef, privacy: .public)")
        }

        // 2) Delete wrapper folder too (if different)
        if wrapperPath != canonicalPath {
            if fm.fileExists(atPath: wrapper.path) {
                do {
                    try fm.removeItem(at: wrapper)
                    AppLog.bundle.info("deleteBundle: removed wrapper \(wrapperRef, privacy: .public)")
                } catch {
                    AppLog.bundle.error("deleteBundle: failed removing wrapper \(wrapperRef, privacy: .public) — \(String(describing: error), privacy: .private(mask: .hash))")
                }
            } else {
                AppLog.bundle.info("deleteBundle: wrapper already missing \(wrapperRef, privacy: .public)")
            }
        }

        // 3) Remove now-empty wrapper parents (common source of “ghost folders”).
        cleanupEmptyParents(startingAt: canonicalParent)
        cleanupEmptyParents(startingAt: wrapperParent)

        // 4) Remove ALL recent/location entries that resolve to the same canonical root or wrapper.
        recentBundles.removeAll { u in
            let su = u.standardizedFileURL.resolvingSymlinksInPath()
            let uCanon = (canonicalBundleRoot(at: su) ?? su).standardizedFileURL.resolvingSymlinksInPath()
            return uCanon.path == canonicalPath || su.path == canonicalPath || su.path == wrapperPath
        }

        bundleLocations.removeAll { u in
            let su = u.standardizedFileURL.resolvingSymlinksInPath()
            let uCanon = (canonicalBundleRoot(at: su) ?? su).standardizedFileURL.resolvingSymlinksInPath()
            return uCanon.path == canonicalPath || su.path == canonicalPath || su.path == wrapperPath
        }

        // 5) If we just deleted the active one, clear selection.
        if let cur = currentBundleURL {
            let sc = cur.standardizedFileURL.resolvingSymlinksInPath()
            let curCanon = (canonicalBundleRoot(at: sc) ?? sc).standardizedFileURL.resolvingSymlinksInPath()
            if curCanon.path == canonicalPath || sc.path == canonicalPath || sc.path == wrapperPath {
                currentBundleURL = nil
                selectedPatientID = nil
                patients = []
            }
        }

        // 6) Final sanity sweep.
        pruneRecentBundlesInPlace()
        persistRecentBundles()
    }

private func pruneRecentBundlesInPlace() {
    let fm = FileManager.default

    // Normalize every entry to its canonical bundle root (e.g., unwrap wrapper folders)
    // and drop entries that no longer exist or no longer contain a DB payload.
    var normalized: [URL] = []
    normalized.reserveCapacity(self.recentBundles.count)

    for u in self.recentBundles {
        // If the path itself is gone, drop it immediately.
        guard fm.fileExists(atPath: u.path) else { continue }

        // Resolve wrapper -> canonical root (must contain db.sqlite or db.sqlite.enc).
        guard let canonical = canonicalBundleRoot(at: u) else { continue }

        normalized.append(canonical.standardizedFileURL)
    }

    // De-duplicate by canonical path
    var seen = Set<String>()
    self.recentBundles = normalized.filter { u in
        let p = u.path
        if seen.contains(p) { return false }
        seen.insert(p)
        return true
    }
}



// Find the function that adds items to recents.
// For the purposes of this patch, let's handle a typical addToRecents(_:) function.
// Insert after the last mutation of recentBundles:

// --- PATCH INSERTION START ---
// (This is a search/replace patch; insert the following lines after mutating recentBundles in addToRecents(_:))
// pruneRecentBundlesInPlace()
// persistRecentBundles()
// --- PATCH INSERTION END ---

private func cleanupEmptyParents(startingAt url: URL) {
    let fm = FileManager.default

    // Application Support/DrsMainApp root (safety boundary)
    let appRoot: URL? = (try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true))
        .map { $0.appendingPathComponent("DrsMainApp", isDirectory: true).standardizedFileURL }

    // If caller passed a path that doesn't exist (common after deleting the leaf),
    // start from its parent.
    var cur = url.standardizedFileURL.resolvingSymlinksInPath()
    if !fm.fileExists(atPath: cur.path) {
        cur = cur.deletingLastPathComponent()
    }

    // Don’t climb forever; just enough to remove typical wrappers/staging folders.
    for _ in 0..<6 {
        // Never remove the app root itself.
        if let root = appRoot, cur.standardizedFileURL.path == root.path { break }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: cur.path, isDirectory: &isDir), isDir.boolValue else { break }

        do {
            let contents = try fm.contentsOfDirectory(
                at: cur,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            if contents.isEmpty {
                try fm.removeItem(at: cur)
                let ref = "FOLDER#\(AppLog.token(cur.lastPathComponent))"
                AppLog.bundle.info("cleanupEmptyParents: removed empty folder \(ref, privacy: .public)")
                cur = cur.deletingLastPathComponent()
            } else {
                break
            }
        } catch {
            break
        }
    }
}

    /// Returns true if `url` is inside Application Support/DrsMainApp (our managed bundle container).
    private func isManagedBundleURL(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                          in: .userDomainMask,
                                          appropriateFor: nil,
                                          create: true)
            .appendingPathComponent("DrsMainApp", isDirectory: true)
            .standardizedFileURL else {
            return false
        }
        return url.standardizedFileURL.path.hasPrefix(appSupport.path)
    }

    @MainActor
    func importBundles(from urls: [URL]) {
        // Legacy wrapper: funnel all imports (ZIP or .peMR) through the MRN-aware, prompt-enabled path.
        let bundleFiles = urls.filter {
            let ext = $0.pathExtension.lowercased()
            return ext == "zip" || ext == "pemr"
        }
        guard !bundleFiles.isEmpty else { return }
        self.importZipBundles(from: bundleFiles)
    }
        
        private func canonicalBundleRoot(at url: URL) -> URL? {
            let fm = FileManager.default

            func hasDBPayload(_ dir: URL) -> Bool {
                fm.fileExists(atPath: dir.appendingPathComponent("db.sqlite").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("db.sqlite.enc").path)
            }

            // If this folder itself contains the DB payload, it's canonical.
            if hasDBPayload(url) { return url }

            // Otherwise, allow a wrapper folder that contains exactly one directory child
            // holding the DB payload. Ignore files like manifest.json.
            guard let children = try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return nil
            }

            let dirs = children.filter { child in
                (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }

            let candidates = dirs.filter { hasDBPayload($0) }
            return (candidates.count == 1) ? candidates[0] : nil
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
                let fmt = NSLocalizedString(
                    "appstate.zip_extract.failed_format",
                    comment: "Log/print when extracting a ZIP bundle fails. %@ is the error description."
                )
                let line = String(format: fmt, String(describing: error))
                AppLog.bundle.error("zip_extract failed: \(line, privacy: .private)")
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

// MARK: - AI input deletion helpers
extension AppState {
    /// Delete a single AI input row by its primary key and update the in-memory
    /// `aiInputsForActiveEpisode` list so the UI stays in sync.
    func deleteAIInputRow(withID id: Int64) {
        guard let dbURL = currentDBURL else {
            return
        }
        do {
            try deleteAIInputRowFromDB(dbURL: dbURL, id: id)
            // Remove the row from the published history list on the main thread.
            DispatchQueue.main.async {
                self.aiInputsForActiveEpisode.removeAll { $0.id == id }
            }
        } catch {
            let fmt = NSLocalizedString(
                "appstate.ai_inputs.delete.failed_format",
                comment: "Log/print when deleting an AI input row fails. %@ is the error description."
            )
            let line = String(format: fmt, String(describing: error))
            print(line)
        }
    }

    /// Low-level SQLite delete for a single `ai_inputs` row.
    private func deleteAIInputRowFromDB(dbURL: URL, id: Int64) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            let msg = String(cString: sqlite3_errmsg(db))
            let fmt = NSLocalizedString(
                "appstate.ai_inputs.delete.open_failed_format",
                comment: "Error when opening the bundle DB for deleting an AI input. %@ is the sqlite error."
            )
            let line = String(format: fmt, msg)
            throw NSError(
                domain: "AppState.DB",
                code: 201,
                userInfo: [NSLocalizedDescriptionKey: line]
            )
        }
        defer { sqlite3_close(db) }

        let sql = "DELETE FROM ai_inputs WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            let fmt = NSLocalizedString(
                "appstate.ai_inputs.delete.prepare_failed_format",
                comment: "Error when preparing the DELETE ai_inputs statement fails. %@ is the sqlite error."
            )
            let line = String(format: fmt, msg)
            throw NSError(
                domain: "AppState.DB",
                code: 202,
                userInfo: [NSLocalizedDescriptionKey: line]
            )
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, id)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            let fmt = NSLocalizedString(
                "appstate.ai_inputs.delete.step_failed_format",
                comment: "Error when executing the DELETE ai_inputs statement fails. %@ is the sqlite error."
            )
            let line = String(format: fmt, msg)
            throw NSError(
                domain: "AppState.DB",
                code: 203,
                userInfo: [NSLocalizedDescriptionKey: line]
            )
        }
    }
}




/// User-facing category label (localized). The stored `category` value remains a stable code.
/// Note: `VisitRow` is a shared model type (not nested in AppState).
extension VisitRow {
    var localizedCategory: String {
        let raw = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch raw {
        case "episode":
            return NSLocalizedString("visit.category.episode", comment: "Visit category label for sick episodes")
        case "well":
            return NSLocalizedString("visit.category.well", comment: "Visit category label for well visits")
        default:
            return category
        }
    }
}

// If there is code that restores recentBundles from UserDefaults, ensure it ends with:
// pruneRecentBundlesInPlace()
