//
//  ReportDataLoader.swift
//  DrsMainApp
//

import Foundation
import SQLite3

@MainActor
final class ReportDataLoader {
    private let appState: AppState
    private let clinicianStore: ClinicianStore

    init(appState: AppState, clinicianStore: ClinicianStore) {
        self.appState = appState
        self.clinicianStore = clinicianStore
    }

    // MARK: - Public entry points

    func loadWell(visitID: Int) throws -> WellReportData {
        let meta = try buildMetaForWell(visitID: visitID)
        // Header-only for now; sections filled in later steps.
        return WellReportData(
            meta: meta,
            perinatalSummary: nil,
            previousVisitFindings: [],
            currentVisitTitle: meta.visitTypeReadable ?? "Well Visit",
            parentsConcerns: nil,
            feeding: [:],
            supplementation: [:],
            sleep: [:],
            developmental: [:],
            milestonesAchieved: (0, 0),
            milestoneFlags: [],
            measurements: [:],
            physicalExamGroups: [],
            problemListing: nil,
            conclusions: nil,
            anticipatoryGuidance: nil,
            clinicianComments: nil,
            nextVisitDate: nil,
            growthCharts: []
        )
    }

    func loadSick(episodeID: Int) throws -> SickReportData {
        let meta = try buildMetaForSick(episodeID: episodeID)

        // Core fields
        var mainComplaint: String?
        var hpi: String?
        var duration: String?
        var basics: [String: String] = [:] // Feeding / Urination / Breathing / Pain / Context

        // Additional sections
        var pmhText: String?
        var vaccinationText: String?
        var vitalsFlags: [String] = []   // (to be wired later)
        var peGroups: [(group: String, lines: [String])] = []
        var problemListing: String?
        var investigations: [String] = []
        var workingDx: String?
        var icd10Tuple: (code: String, label: String)?
        var meds: [String] = []
        var planGuidance: String?
        var clinicianComments: String?
        var nextVisitDate: String?

        do {
            let dbPath = try currentBundleDBPath()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // --- EPISODE ROW ---
                let sqlEp = """
                SELECT
                    patient_id,
                    main_complaint, hpi, duration, feeding, urination, breathing, pain, context,
                    problem_listing, complementary_investigations, diagnosis, icd10, medications,
                    anticipatory_guidance, comments,
                    general_appearance, hydration, color, skin,
                    ent, right_ear, left_ear, right_eye, left_eye,
                    heart, lungs,
                    abdomen, peristalsis,
                    genitalia,
                    neurological, musculoskeletal, lymph_nodes
                FROM episodes
                WHERE id = ?
                LIMIT 1;
                """
                var stmtEp: OpaquePointer?
                var patientID: Int64 = -1
                if sqlite3_prepare_v2(db, sqlEp, -1, &stmtEp, nil) == SQLITE_OK, let stmt = stmtEp {
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_int64(stmt, 1, Int64(episodeID))
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        func col(_ i: Int32) -> String? {
                            guard let cstr = sqlite3_column_text(stmt, i) else { return nil }
                            let s = String(cString: cstr).trimmingCharacters(in: .whitespacesAndNewlines)
                            return s.isEmpty ? nil : s
                        }
                        var i: Int32 = 0
                        patientID      = sqlite3_column_int64(stmt, i); i += 1
                        mainComplaint  = col(i); i += 1
                        hpi            = col(i); i += 1
                        duration       = col(i); i += 1
                        if let v = col(i) { basics["Feeding"] = v }; i += 1
                        if let v = col(i) { basics["Urination"] = v }; i += 1
                        if let v = col(i) { basics["Breathing"] = v }; i += 1
                        if let v = col(i) { basics["Pain"] = v }; i += 1
                        if let v = col(i) { basics["Context"] = v }; i += 1

                        problemListing = col(i); i += 1
                        let investigationsRaw = col(i); i += 1
                        workingDx      = col(i); i += 1
                        let icdRaw     = col(i); i += 1
                        let medsRaw    = col(i); i += 1
                        planGuidance   = col(i); i += 1
                        clinicianComments = col(i); i += 1

                        // PE fields
                        let peNames = [
                            "General appearance","Hydration","Color","Skin",
                            "ENT","Right ear","Left ear","Right eye","Left eye",
                            "Heart","Lungs",
                            "Abdomen","Peristalsis",
                            "Genitalia",
                            "Neurological","Musculoskeletal","Lymph nodes"
                        ]
                        var valuesByName: [String:String] = [:]
                        for name in peNames {
                            if let v = col(i), !v.isEmpty { valuesByName[name] = v }
                            i += 1
                        }
                        let groupMap: [(String,[String])] = [
                            ("General", ["General appearance","Hydration","Color","Skin"]),
                            ("ENT", ["ENT","Right ear","Left ear","Right eye","Left eye"]),
                            ("Cardiorespiratory", ["Heart","Lungs"]),
                            ("Abdomen", ["Abdomen","Peristalsis"]),
                            ("Genitalia", ["Genitalia"]),
                            ("Neuro / MSK / Lymph", ["Neurological","Musculoskeletal","Lymph nodes"])
                        ]
                        for (group, names) in groupMap {
                            let lines = names.compactMap { n -> String? in
                                guard let v = valuesByName[n] else { return nil }
                                return "\(n): \(v)"
                            }
                            if !lines.isEmpty { peGroups.append((group: group, lines: lines)) }
                        }

                        // split multi-line lists
                        if let raw = investigationsRaw {
                            investigations = raw
                                .replacingOccurrences(of: "\r", with: "\n")
                                .components(separatedBy: .newlines)
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                        }
                        if let raw = medsRaw {
                            meds = raw
                                .replacingOccurrences(of: "\r", with: "\n")
                                .components(separatedBy: .newlines)
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                        }
                        if let raw = icdRaw, !raw.isEmpty {
                            let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
                            if parts.count == 2 {
                                icd10Tuple = (code: parts[0], label: parts[1])
                            } else {
                                icd10Tuple = (code: parts.first ?? "", label: raw)
                            }
                        }
                    }
                }

                // --- PATIENT: vaccination_status ---
                if patientID > 0 {
                    let sqlPt = "SELECT vaccination_status FROM patients WHERE id = ? LIMIT 1;"
                    var stmtPt: OpaquePointer?
                    if sqlite3_prepare_v2(db, sqlPt, -1, &stmtPt, nil) == SQLITE_OK, let stmt = stmtPt {
                        defer { sqlite3_finalize(stmt) }
                        sqlite3_bind_int64(stmt, 1, patientID)
                        if sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) {
                            let s = String(cString: cstr).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !s.isEmpty { vaccinationText = s }
                        }
                    }
                }

                // --- PMH from past_medical_history ---
                if patientID > 0 {
                    let sqlPMH = """
                    SELECT asthma, otitis, uti, allergies, other
                    FROM past_medical_history
                    WHERE patient_id = ?
                    LIMIT 1;
                    """
                    var stmtPMH: OpaquePointer?
                    if sqlite3_prepare_v2(db, sqlPMH, -1, &stmtPMH, nil) == SQLITE_OK, let stmt = stmtPMH {
                        defer { sqlite3_finalize(stmt) }
                        sqlite3_bind_int64(stmt, 1, patientID)
                        if sqlite3_step(stmt) == SQLITE_ROW {
                            var items: [String] = []
                            func f(_ idx: Int32, _ label: String) {
                                let isNull = sqlite3_column_type(stmt, idx) == SQLITE_NULL
                                let val = isNull ? 0 : sqlite3_column_int(stmt, idx)
                                if val == 1 { items.append(label) }
                            }
                            f(0,"Asthma"); f(1,"Otitis"); f(2,"UTI"); f(3,"Allergies")
                            if let cstr = sqlite3_column_text(stmt, 4) {
                                let s = String(cString: cstr).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !s.isEmpty { items.append(s) }
                            }
                            if !items.isEmpty { pmhText = items.joined(separator: "; ") }
                        }
                    }
                }
            }
        } catch {
            // leave optionals nil; renderer will print "—"
        }

        return SickReportData(
            meta: meta,
            mainComplaint: mainComplaint,
            hpi: hpi,
            duration: duration,
            basics: basics,
            pmh: pmhText,
            vaccination: vaccinationText,
            vitalsSummary: vitalsFlags,
            physicalExamGroups: peGroups,
            problemListing: problemListing,
            investigations: investigations,
            workingDiagnosis: workingDx,
            icd10: icd10Tuple,
            planGuidance: planGuidance,
            medications: meds,
            clinicianComments: clinicianComments,
            nextVisitDate: nextVisitDate
        )
    }
    
    // Prefer clinician name stored in Golden.db for the specific episode
    private func fetchClinicianNameForEpisode(_ episodeID: Int) -> String? {
        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Columns on episodes
                var cols = Set<String>()
                var stmtCols: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(episodes);", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let c = sqlite3_column_text(s, 1) {
                            cols.insert(String(cString: c))
                        }
                    }
                }

                // Prefer FK → users join (to get first_name + last_name)
                let fkCandidates = [
                    "clinician_user_id","user_id","clinician_id",
                    "physician_user_id","physician_id",
                    "doctor_user_id","doctor_id",
                    "provider_id",
                    "created_by","author_id","entered_by","owner_id"
                ]
                if let fk = fkCandidates.first(where: { cols.contains($0) }) {
                    let sql = """
                    SELECT u.first_name, u.last_name
                    FROM users u
                    JOIN episodes e ON u.id = e.\(fk)
                    WHERE e.id = ? LIMIT 1;
                    """
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                        defer { sqlite3_finalize(st) }
                        sqlite3_bind_int64(st, 1, Int64(episodeID))
                        if sqlite3_step(st) == SQLITE_ROW {
                            func col(_ i: Int32) -> String? {
                                guard let c = sqlite3_column_text(st, i) else { return nil }
                                let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                                return s.isEmpty ? nil : s
                            }
                            if let f = col(0), let l = col(1) {
                                let full = "\(f) \(l)".trimmingCharacters(in: .whitespaces)
                                if !full.isEmpty { return full }
                            }
                        }
                    }
                }

                // Last-resort: direct text on episodes row
                for direct in ["clinician_name","clinician","doctor","physician"] where cols.contains(direct) {
                    let sql = "SELECT \(direct) FROM episodes WHERE id = ? LIMIT 1;"
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                        defer { sqlite3_finalize(st) }
                        sqlite3_bind_int64(st, 1, Int64(episodeID))
                        if sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) {
                            let name = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !name.isEmpty { return name }
                        }
                    }
                }
            }
        } catch { /* ignore */ }
        return nil
    }

    // Fetch patient first+last name for a SICK episode from the bundle DB
    private func fetchPatientNameForEpisode(_ episodeID: Int) -> String? {
        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Discover columns on episodes to find the patient FK
                var epCols = Set<String>()
                var stmtCols: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(episodes);", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let cName = sqlite3_column_text(s, 1) {
                            epCols.insert(String(cString: cName))
                        }
                    }
                }

                let fkCandidates = ["patient_id","patientId","patientID"]
                guard let fk = fkCandidates.first(where: { epCols.contains($0) }) else { return nil }

                let sql = """
                SELECT p.first_name, p.last_name
                FROM patients p
                JOIN episodes e ON p.id = e.\(fk)
                WHERE e.id = ? LIMIT 1;
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(episodeID))
                    if sqlite3_step(st) == SQLITE_ROW {
                        func col(_ i: Int32) -> String? {
                            guard let c = sqlite3_column_text(st, i) else { return nil }
                            let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            return s.isEmpty ? nil : s
                        }
                        if let first = col(0), let last = col(1) {
                            let full = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
                            if !full.isEmpty { return full }
                        }
                    }
                }
            }
        } catch {
            // ignore and fall back
        }
        return nil
    }

    // Fetch patient first+last name for a WELL visit from the bundle DB
    private func fetchPatientNameForWellVisit(_ visitID: Int) -> String? {
        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let cName = sqlite3_column_text(s, 1) {
                                cols.insert(String(cString: cName))
                            }
                        }
                    }
                    return cols
                }

                // Choose well table
                let table = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"
                let cols = columns(in: table)
                let fkCandidates = ["patient_id","patientId","patientID"]
                guard let fk = fkCandidates.first(where: { cols.contains($0) }) else { return nil }

                let sql = """
                SELECT p.first_name, p.last_name
                FROM patients p
                JOIN \(table) w ON p.id = w.\(fk)
                WHERE w.id = ? LIMIT 1;
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(visitID))
                    if sqlite3_step(st) == SQLITE_ROW {
                        func col(_ i: Int32) -> String? {
                            guard let c = sqlite3_column_text(st, i) else { return nil }
                            let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            return s.isEmpty ? nil : s
                        }
                        if let first = col(0), let last = col(1) {
                            let full = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
                            if !full.isEmpty { return full }
                        }
                    }
                }
            }
        } catch {
            // ignore and fall back
        }
        return nil
    }

    // Prefer clinician name stored in Golden.db for the specific WELL visit
    private func fetchClinicianNameForWellVisit(_ visitID: Int) -> String? {
        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let c = sqlite3_column_text(s, 1) {
                                cols.insert(String(cString: c))
                            }
                        }
                    }
                    return cols
                }

                // Pick table used for well visits
                let table = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"
                let cols = columns(in: table)

                // Prefer FK → users join (to get first_name + last_name)
                let fkCandidates = [
                    "clinician_user_id","user_id","clinician_id",
                    "physician_user_id","physician_id",
                    "doctor_user_id","doctor_id",
                    "provider_id",
                    "created_by","author_id","entered_by","owner_id"
                ]
                if let fk = fkCandidates.first(where: { cols.contains($0) }) {
                    let sql = """
                    SELECT u.first_name, u.last_name
                    FROM users u
                    JOIN \(table) w ON u.id = w.\(fk)
                    WHERE w.id = ? LIMIT 1;
                    """
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                        defer { sqlite3_finalize(st) }
                        sqlite3_bind_int64(st, 1, Int64(visitID))
                        if sqlite3_step(st) == SQLITE_ROW {
                            func col(_ i: Int32) -> String? {
                                guard let c = sqlite3_column_text(st, i) else { return nil }
                                let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                                return s.isEmpty ? nil : s
                            }
                            if let f = col(0), let l = col(1) {
                                let full = "\(f) \(l)".trimmingCharacters(in: .whitespaces)
                                if !full.isEmpty { return full }
                            }
                        }
                    }
                }

                // Last-resort: direct text on the visit row
                for direct in ["clinician_name","clinician","doctor","physician"] where cols.contains(direct) {
                    let sql = "SELECT \(direct) FROM \(table) WHERE id = ? LIMIT 1;"
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                        defer { sqlite3_finalize(st) }
                        sqlite3_bind_int64(st, 1, Int64(visitID))
                        if sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) {
                            let name = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !name.isEmpty { return name }
                        }
                    }
                }
            }
        } catch { /* ignore */ }
        return nil
    }
    
    // Debug helper to ensure we're using the patient's bundle DB (ActiveBundle/db.sqlite)
    @MainActor
    private func bundleDBPathWithDebug() throws -> String {
        let path = try currentBundleDBPath()
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: path)
        let attrs = try? fm.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        let parent = url.deletingLastPathComponent().lastPathComponent

        print("[ReportDataLoader] Using DB: \(path)")
        print("[ReportDataLoader] Exists: \(exists)  Size: \(size) bytes  File: \(url.lastPathComponent)  Parent: \(parent)")
        if url.lastPathComponent.lowercased() != "db.sqlite" {
            print("[ReportDataLoader][WARN] Expected 'db.sqlite' (patient bundle), but got '\(url.lastPathComponent)'.")
        }
        return path
    }

    // MARK: - Meta builders

    private func buildMetaForWell(visitID: Int) throws -> ReportMeta {
        let (patientName, alias, mrn, dobISO, sex) = basicPatientStrings()
        let properPatientName = fetchPatientNameForWellVisit(visitID) ?? patientName

        // Visit date + readable type (fallbacks keep it resilient)
        let visitDateISO: String = appState.visits.first(where: { $0.id == visitID })?.dateISO
            ?? ISO8601DateFormatter().string(from: Date())
        let visitTypeReadable: String? = "Well Visit" // (wire exact label later)

        let clinicianName = fetchClinicianNameForWellVisit(visitID) ?? activeClinicianName()
        let age = ageString(dobISO: dobISO, onDateISO: visitDateISO)
        let nowISO = ISO8601DateFormatter().string(from: Date())

        return ReportMeta(
            alias: alias,
            mrn: mrn,
            name: properPatientName,
            dobISO: dobISO,
            sex: sex,
            visitDateISO: visitDateISO,
            ageAtVisit: age,
            clinicianName: clinicianName,
            visitTypeReadable: visitTypeReadable,
            createdAtISO: nil,
            updatedAtISO: nil,
            generatedAtISO: nowISO
        )
    }

    @MainActor
    private func buildMetaForSick(episodeID: Int) throws -> ReportMeta {
        let (patientName, alias, mrn, dobISO, sex) = basicPatientStrings()
        let properPatientName = fetchPatientNameForEpisode(episodeID) ?? patientName

        // Keep existing visit date behavior (from appState or now)
        var visitDateISO: String = appState.visits.first(where: { $0.id == episodeID })?.dateISO
            ?? ISO8601DateFormatter().string(from: Date())

        let clinicianName = fetchClinicianNameForEpisode(episodeID) ?? activeClinicianName()
        let age = ageString(dobISO: dobISO, onDateISO: visitDateISO)
        let nowISO = ISO8601DateFormatter().string(from: Date())

        // NEW: pull created_at (+ updated_at if present) from episodes
        var createdISO: String? = nil
        var updatedISO: String? = nil
        do {
            let dbPath = try currentBundleDBPath()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Try both columns first
                let sqlBoth = "SELECT created_at, updated_at FROM episodes WHERE id = ? LIMIT 1;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sqlBoth, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt {
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_int64(stmt, 1, Int64(episodeID))
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        if let c0 = sqlite3_column_text(stmt, 0) {
                            let s = String(cString: c0).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !s.isEmpty { createdISO = s }
                        }
                        if let c1 = sqlite3_column_text(stmt, 1) {
                            let s = String(cString: c1).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !s.isEmpty { updatedISO = s }
                        }
                    }
                } else {
                    // Fallback if updated_at column doesn't exist
                    let sqlCreatedOnly = "SELECT created_at FROM episodes WHERE id = ? LIMIT 1;"
                    var stmt2: OpaquePointer?
                    if sqlite3_prepare_v2(db, sqlCreatedOnly, -1, &stmt2, nil) == SQLITE_OK, let stmt2 = stmt2 {
                        defer { sqlite3_finalize(stmt2) }
                        sqlite3_bind_int64(stmt2, 1, Int64(episodeID))
                        if sqlite3_step(stmt2) == SQLITE_ROW, let c0 = sqlite3_column_text(stmt2, 0) {
                            let s = String(cString: c0).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !s.isEmpty { createdISO = s }
                        }
                    }
                }
            }
        } catch {
            // leave createdISO/updatedISO nil
        }

        // Prefer episodes.created_at for Sick visit date when available
        if let created = createdISO, !created.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            visitDateISO = created
        }

        return ReportMeta(
            alias: alias,
            mrn: mrn,
            name: properPatientName,
            dobISO: dobISO,
            sex: sex,
            visitDateISO: visitDateISO,
            ageAtVisit: age,
            clinicianName: clinicianName,
            visitTypeReadable: nil,
            createdAtISO: createdISO,   // "Created"
            updatedAtISO: updatedISO,   // "Last Edited" (may be nil)
            generatedAtISO: nowISO      // "Report Generated" = now
        )
    }

    // MARK: - Helpers

    private func currentBundleDBPath() throws -> String {
        guard let root = appState.currentBundleURL else {
            throw NSError(domain: "ReportDataLoader", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "No active patient bundle opened"])
        }
        return root.appendingPathComponent("db.sqlite").path
    }

    private func activeClinicianName() -> String {
        guard let uid = appState.activeUserID,
              let c = clinicianStore.users.first(where: { $0.id == uid }) else {
            return "—"
        }
        let first = reflectString(c, keys: ["firstName", "first_name"])
        let last  = reflectString(c, keys: ["lastName", "last_name"])
        let name  = [first, last].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "User #\(c.id)" : name
    }

    private func basicPatientStrings() -> (name: String, alias: String, mrn: String, dobISO: String, sex: String) {
        var patientName = "—", alias = "—", mrn = "—", dobISO = "—", sex = "—"
        if let p = appState.selectedPatient {
            if let dn = reflectString(p, keys: ["displayName", "name"]) {
                patientName = dn
            } else {
                let first = reflectString(p, keys: ["firstName", "first_name"])
                let last  = reflectString(p, keys: ["lastName", "last_name"])
                let combined = [first, last].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !combined.isEmpty { patientName = combined }
                else if let a = reflectString(p, keys: ["alias", "alias_label"]) { patientName = a }
            }
            alias  = reflectString(p, keys: ["alias", "alias_label"]) ?? alias
            mrn    = reflectString(p, keys: ["mrn"]) ?? mrn
            dobISO = reflectString(p, keys: ["dobISO", "dateOfBirth", "dob"]) ?? dobISO
            sex    = reflectString(p, keys: ["sex", "gender"]) ?? sex
        }
        return (patientName, alias, mrn, dobISO, sex)
    }

    private func reflectString(_ any: Any, keys: [String]) -> String? {
        let m = Mirror(reflecting: any)
        for c in m.children {
            if let label = c.label, keys.contains(label),
               let val = c.value as? String,
               !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return val
            }
        }
        return nil
    }

    private func ageString(dobISO: String, onDateISO: String) -> String {
        let f = ISO8601DateFormatter()
        guard let dob = f.date(from: dobISO), let ref = f.date(from: onDateISO) else { return "—" }
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day], from: dob, to: ref)
        let y = comps.year ?? 0, m = comps.month ?? 0, d = comps.day ?? 0
        var parts: [String] = []
        if y > 0 { parts.append("\(y)y") }
        if m > 0 { parts.append("\(m)m") }
        if d > 0 || parts.isEmpty { parts.append("\(d)d") }
        return parts.joined(separator: " ")
    }
}
