


//  ReportDataLoader.swift
//  DrsMainApp
//

// REPORT CONTRACT (Well visits)
// - Age gating lives in WellVisitReportRules + ReportDataLoader ONLY.
// - Age gating controls ONLY which fields appear INSIDE the current visit sections.
// - Growth charts, perinatal summary, and previous well visits are NEVER age-gated.
// - ReportBuilder is a dumb renderer: it prints whatever WellReportData gives it.
//- We don't make RTF (that is legacy from previous failed attempts)
//- we don't touch GrowthCharts
//- we work with PDF and Docx.
//- the contract is to filter the age appropriate current visit field to include in the report. Everything else is left unchanged.

import Foundation
import SQLite3

// Ensure ordinal suffixes appear in lowercase (e.g., 1st, 2nd, 3rd, 4th)
private func prettifyOrdinals(_ s: String) -> String {
    do {
        let regex = try NSRegularExpression(
            pattern: "\\b(\\d+)([Ss][Tt]|[Nn][Dd]|[Rr][Dd]|[Tt][Hh])\\b"
        )
        let ns = s as NSString
        var result = ""
        var lastIndex = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let range = match.range
            result += ns.substring(with: NSRange(location: lastIndex, length: range.location - lastIndex))
            let num = ns.substring(with: match.range(at: 1))
            let suf = ns.substring(with: match.range(at: 2)).lowercased()
            result += num + suf
            lastIndex = range.location + range.length
        }
        result += ns.substring(from: lastIndex)
        return result
    } catch {
        return s
    }
}

// MARK: - Visit type mapping (file-scope)
private let VISIT_TITLES: [String:String] = [
    "one_month": "1-month visit",
    "two_month": "2-month visit",
    "four_month": "4-month visit",
    "six_month": "6-month visit",
    "nine_month": "9-month visit",
    "twelve_month": "12-month visit",
    "fifteen_month": "15-month visit",
    "eighteen_month": "18-month visit",
    "twentyfour_month": "24-month visit",
    "thirty_month": "30-month visit",
    "thirtysix_month": "36-month visit",
    "newborn_1st_after_maternity": "Newborn 1st After Maternity",
    "episode": "Sick visit"
]

private func readableVisitType(_ raw: String?) -> String? {
    guard let r = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return nil }
    if let mapped = VISIT_TITLES[r] { return mapped }
    // Fallback: prettify snake_case → Title Case with nice ordinals
    let pretty = r.replacingOccurrences(of: "_", with: " ").capitalized
    return prettifyOrdinals(pretty)
}

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

        // STEP 1: Perinatal Summary (historical; NOT date-gated)
        // Per spec: perinatal_history is considered fixed historical info and should not be cutoff by visit date.
        var perinatalSummary: String? = nil
        if let pid = patientIDForWellVisit(visitID) {
            perinatalSummary = buildPerinatalSummary(patientID: pid, cutoffISO: nil)
        }

        // STEP 2: Findings from previous well visits (aggregated)
        let prevFindings = buildPreviousWellVisitFindings(currentVisitID: visitID, dobISO: meta.dobISO, cutoffISO: meta.visitDateISO)

        // STEP 3: Compute age in months for age-gated CURRENT VISIT sections
        // Use the same convention as growth logic (days / 30.4375) for consistency.
        var ageMonthsDouble: Double? = nil
        if let dobDate = parseDateFlexible(meta.dobISO),
           let visitDate = parseDateFlexible(meta.visitDateISO) {
            let seconds = visitDate.timeIntervalSince(dobDate)
            let days = seconds / 86400.0
            let months = max(0.0, days / 30.4375)
            ageMonthsDouble = months
        }
        // STEP 4: Current visit core fields (type subtitle, parents' concerns, feeding, supplementation, sleep)
        let core = loadCurrentWellCoreFields(visitID: visitID)
        let currentVisitTitle = core.visitType ?? (meta.visitTypeReadable ?? "Well Visit")
        let parentsConcernsRaw = core.parentsConcerns
        let feedingRaw = core.feeding
        let supplementationRaw = core.supplementation
        let sleepRaw = core.sleep
        print("[ReportDataLoader] wellCore: type='\(currentVisitTitle)' parents=\(parentsConcernsRaw?.count ?? 0) feed=\(feedingRaw.count) supp=\(supplementationRaw.count) sleep=\(sleepRaw.count)")

        // STEP 5: Developmental evaluation (M-CHAT / Dev test / Parents' Concerns) + Milestones (for this visit)
        let devPack = loadDevelopmentForWellVisit(visitID: visitID)
        // STEP 6: Measurements (today’s W/L/HC + weight-gain since discharge)
        let measurementsRaw = loadMeasurementsForWellVisit(visitID: visitID)

        // STEP 7: Physical Exam + problem listing / conclusions / guidance / comments / next visit
        let pePack = loadWellPEAndText(visitID: visitID)

        // STEP 8: Apply age-based visibility for CURRENT VISIT sections ONLY.
        // Per REPORT CONTRACT:
        // - Perinatal summary, growth charts, and previous well visits are NEVER age-gated.
        // - Age gating controls only which fields are populated inside the current visit sections.
        
        let rawVisitTypeID = rawVisitTypeIDForWell(visitID: visitID) ?? core.visitType
        let visibility = WellVisitReportRules.visibility(for: rawVisitTypeID, ageMonths: ageMonthsDouble)

        var parentsConcerns = parentsConcernsRaw
        var feeding = feedingRaw
        var supplementation = supplementationRaw
        var sleep = sleepRaw
        var developmental = devPack.dev
        var milestonesAchieved = (devPack.achieved, devPack.total)
        var milestoneFlags = devPack.flags
        var measurements = measurementsRaw
        var physicalExamGroups = pePack.groups
        var problemListing = pePack.problem
        var conclusions = pePack.conclusions
        var anticipatoryGuidance = pePack.anticipatory
        var clinicianComments = pePack.comments
        var nextVisitDate = pePack.nextVisitDate

        // Use matrix visibility as the single source of truth for CURRENT VISIT sections.
        // If there's no visibility profile, we hide all current-visit sections instead of
        // inferring visibility from whether fields are filled.
        if let visibility = visibility {
            if !visibility.showParentsConcerns {
                parentsConcerns = nil
            }
            if !visibility.showFeeding {
                feeding = [:]
            }
            if !visibility.showSupplementation {
                supplementation = [:]
            }
            if !visibility.showSleep {
                sleep = [:]
            }
            if !visibility.showDevelopment {
                developmental = [:]
            }
            if !visibility.showMilestones {
                milestonesAchieved = (0, 0)
                milestoneFlags = []
            }
            if !visibility.showMeasurements {
                measurements = [:]
            }
            if !visibility.showPhysicalExam {
                physicalExamGroups = []
            }
            if !visibility.showProblemListing {
                problemListing = nil
            }
            if !visibility.showConclusions {
                conclusions = nil
            }
            if !visibility.showAnticipatoryGuidance {
                anticipatoryGuidance = nil
            }
            if !visibility.showClinicianComments {
                clinicianComments = nil
            }
            if !visibility.showNextVisit {
                nextVisitDate = nil
            }
        } else {
            // No visibility profile defined for this visit type/age → hide all current-visit sections.
            parentsConcerns = nil
            feeding = [:]
            supplementation = [:]
            sleep = [:]
            developmental = [:]
            milestonesAchieved = (0, 0)
            milestoneFlags = []
            measurements = [:]
            physicalExamGroups = []
            problemListing = nil
            conclusions = nil
            anticipatoryGuidance = nil
            clinicianComments = nil
            nextVisitDate = nil
        }

        // Header + perinatal summary stay untouched; age gating only affects current visit sections above.
        return WellReportData(
            meta: meta,
            perinatalSummary: perinatalSummary,
            previousVisitFindings: prevFindings,
            currentVisitTitle: currentVisitTitle,
            parentsConcerns: parentsConcerns,
            feeding: feeding,
            supplementation: supplementation,
            sleep: sleep,
            developmental: developmental,
            milestonesAchieved: milestonesAchieved,
            milestoneFlags: milestoneFlags,
            measurements: measurements,
            physicalExamGroups: physicalExamGroups,
            problemListing: problemListing,
            conclusions: conclusions,
            anticipatoryGuidance: anticipatoryGuidance,
            clinicianComments: clinicianComments,
            nextVisitDate: nextVisitDate,
            growthCharts: [],
            visibility: visibility
        )
    }

    // Resolve patient_id for a WELL visit by introspecting the well table and FK column.
    private func patientIDForWellVisit(_ visitID: Int) -> Int64? {
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

                // Decide which table holds well visits
                let table = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"
                let cols = columns(in: table)
                let fkCandidates = ["patient_id","patientId","patientID"]
                guard let fk = fkCandidates.first(where: { cols.contains($0) }) else { return nil }

                let sql = "SELECT \(fk) FROM \(table) WHERE id = ? LIMIT 1;"
                var stmt: OpaquePointer?
                var val: Int64 = -1
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(visitID))
                    if sqlite3_step(st) == SQLITE_ROW, sqlite3_column_type(st, 0) != SQLITE_NULL {
                        val = sqlite3_column_int64(st, 0)
                    }
                }
                return val > 0 ? val : nil
            }
        } catch {
            // ignore and fall back
        }
        return nil
    }

    // Build a single-line perinatal summary from perinatal_summary (latest row for the patient, with optional cutoff)
    private func buildPerinatalSummary(patientID: Int64, cutoffISO: String?) -> String? {
        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                func dbg(_ msg: String) { print("[ReportDataLoader] buildPerinatalSummary(pid:\(patientID)): \(msg)") }

                // 1) List tables
                var tables: [String] = []
                var tStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table';", -1, &tStmt, nil) == SQLITE_OK, let s = tStmt {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let c = sqlite3_column_text(s, 0) { tables.append(String(cString: c)) }
                    }
                }
                dbg("tables: \(tables)")

                // 2) Pick perinatal table
                let candidates = ["perinatal_summary","perinatal","perinatal_summaries","perinatal_info","perinatal_history"]
                guard let table = candidates.first(where: { tables.contains($0) }) else {
                    dbg("no perinatal table found"); return nil
                }
                dbg("using table: \(table)")

                // 3) Columns for the chosen table
                var cols = Set<String>()
                var stmtCols: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let cName = sqlite3_column_text(s, 1) { cols.insert(String(cString: cName)) }
                    }
                }
                dbg("columns: \(Array(cols).sorted())")
                if cols.isEmpty { return nil }

                // 4) Patient FK
                let patientFK = ["patient_id","patientId","patientID"].first(where: { cols.contains($0) }) ?? "patient_id"
                dbg("patient FK: \(patientFK)")

                // Helper to bind text
                func bindText(_ st: OpaquePointer, _ index: Int32, _ str: String) {
                    _ = str.withCString { cstr in
                        sqlite3_bind_text(st, index, cstr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                }

                // 5) Helper to fetch one value (first existing column)
                func val(_ keys: [String]) -> String? {
                    guard let col = keys.first(where: { cols.contains($0) }) else { return nil }
                    let orderField = cols.contains("updated_at") ? "updated_at" : "id"
                    dbg("ordering by \(orderField)")
                    var whereClause = "\(patientFK) = ?"
                    var needsDate = false
                    if let cut = cutoffISO, cols.contains("updated_at") {
                        whereClause += " AND date(updated_at) <= date(?)"
                        needsDate = true
                    }
                    let sql = "SELECT \(col) FROM \(table) WHERE \(whereClause) ORDER BY \(orderField) DESC LIMIT 1;"
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                        defer { sqlite3_finalize(st) }
                        sqlite3_bind_int64(st, 1, patientID)
                        if needsDate, let cut = cutoffISO { bindText(st, 2, cut) }
                        if sqlite3_step(st) == SQLITE_ROW, sqlite3_column_type(st, 0) != SQLITE_NULL, let c = sqlite3_column_text(st, 0) {
                            let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            return s.isEmpty ? nil : s
                        }
                    }
                    return nil
                }

                // Integer-value helper
                func ival(_ keys: [String]) -> Int? {
                    guard let col = keys.first(where: { cols.contains($0) }) else { return nil }
                    let orderField = cols.contains("updated_at") ? "updated_at" : "id"
                    var whereClause = "\(patientFK) = ?"
                    var needsDate = false
                    if let cut = cutoffISO, cols.contains("updated_at") {
                        whereClause += " AND date(updated_at) <= date(?)"
                        needsDate = true
                    }
                    var stmt: OpaquePointer?
                    let sql = "SELECT \(col) FROM \(table) WHERE \(whereClause) ORDER BY \(orderField) DESC LIMIT 1;"
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                        defer { sqlite3_finalize(st) }
                        sqlite3_bind_int64(st, 1, patientID)
                        if needsDate, let cut = cutoffISO { bindText(st, 2, cut) }
                        if sqlite3_step(st) == SQLITE_ROW, sqlite3_column_type(st, 0) != SQLITE_NULL {
                            return Int(sqlite3_column_int(st, 0))
                        }
                    }
                    return nil
                }

                // 6) Build parts using whatever columns exist
                var parts: [String] = []

                if let v = val(["pregnancy_risk"]) { parts.append("Pregnancy risk: \(v)") }
                if let v = val(["birth_mode"]) { parts.append("Birth mode: \(v)") }
                if let w = ival(["birth_term_weeks"]) { parts.append("GA: \(w) w") }
                if let v = val(["resuscitation"]) { parts.append("Resuscitation: \(v)") }
                if let n = ival(["nicu_stay"]), n != 0 { parts.append("NICU: yes") }
                if let v = val(["infection_risk"]) { parts.append("Infection risk: \(v)") }

                if let v = val(["birth_weight_g"]) { parts.append("BW: \(v)\u{00A0}g") }
                if let v = val(["birth_length_cm"]) { parts.append("BL: \(v)\u{00A0}cm") }
                if let v = val(["birth_head_circumference_cm"]) { parts.append("HC: \(v)\u{00A0}cm") }

                if let v = val(["maternity_stay_events"]) { parts.append("Maternity stay: \(v)") }
                if let v = val(["maternity_vaccinations"]) { parts.append("Maternity vacc: \(v)") }
                if let k = ival(["vitamin_k"]) { parts.append("Vitamin K: \(k != 0 ? "yes" : "no")") }
                if let v = val(["feeding_in_maternity"]) { parts.append("Feeding: \(v)") }
                if let m = ival(["passed_meconium_24h"]) { parts.append("Meconium 24h: \(m != 0 ? "yes" : "no")") }
                if let u = ival(["urination_24h"]) { parts.append("Urination 24h: \(u != 0 ? "yes" : "no")") }

                if let v = val(["heart_screening"]) { parts.append("Heart: \(v)") }
                if let v = val(["metabolic_screening"]) { parts.append("Metabolic: \(v)") }
                if let v = val(["hearing_screening"]) { parts.append("Hearing: \(v)") }

                if let v = val(["mother_vaccinations"]) { parts.append("Mother vacc: \(v)") }
                if let v = val(["family_vaccinations"]) { parts.append("Family vacc: \(v)") }

                if let v = val(["maternity_discharge_date"]) { parts.append("Discharge date: \(v)") }
                if let v = val(["discharge_weight_g"]) { parts.append("Discharge Wt: \(v)\u{00A0}g") }

                if let v = val(["illnesses_after_birth"]) { parts.append("After birth: \(v)") }
                if let v = val(["evolution_since_maternity"]) { parts.append("Since discharge: \(v)") }

                let summary = parts.joined(separator: "; ")
                dbg("summary: \(summary)")
                return summary.isEmpty ? nil : summary
            }
        } catch {
            print("[ReportDataLoader] buildPerinatalSummary error: \(error)")
        }
        return nil
    }

    // Aggregate concise findings from prior well visits for the same patient, up to a cutoff date
    private func buildPreviousWellVisitFindings(currentVisitID: Int, dobISO: String, cutoffISO: String) -> [(title: String, date: String, findings: String?)] {
        var results: [(title: String, date: String, findings: String?)] = []
        guard let patientID = patientIDForWellVisit(currentVisitID) else {
            print("[ReportDataLoader] previousWell: no patient for visit \(currentVisitID)")
            return results
        }
        // Ensure we have a DOB that can be parsed; if not, fetch from patients table
        var effectiveDobISO = dobISO
        if parseDateFlexible(effectiveDobISO) == nil || effectiveDobISO == "—" {
            if let fetchedDOB = fetchDOBFromPatients(patientID: Int64(patientID)) {
                effectiveDobISO = fetchedDOB
            }
        }
        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Ensure table exists and discover columns
                var cols = Set<String>()
                var stmtCols: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(well_visits);", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let cName = sqlite3_column_text(s, 1) {
                            cols.insert(String(cString: cName))
                        }
                    }
                }
                if cols.isEmpty {
                    print("[ReportDataLoader] previousWell: no well_visits table")
                    return results
                }

                // Columns we will try to read
                let dateCol = cols.contains("visit_date") ? "visit_date" : (cols.contains("created_at") ? "created_at" : nil)
                let typeCol = cols.contains("visit_type") ? "visit_type" : nil

                let sql = """
                SELECT
                    id,
                    \(dateCol ?? "''") as visit_date,
                    \(typeCol ?? "''") as visit_type,
                    COALESCE(problem_listing,'') as problem_listing,
                    COALESCE(conclusions,'') as conclusions,
                    COALESCE(parents_concerns,'') as parents_concerns,
                    COALESCE(issues_since_last,'') as issues_since_last,
                    COALESCE(comments,'') as comments
                FROM well_visits
                WHERE patient_id = ? AND id <> ?
                \(dateCol != nil ? "AND date(\(dateCol!)) <= date(?)" : "")
                ORDER BY date(\(dateCol ?? "''")) DESC, id DESC
                LIMIT 5;
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, patientID)
                    sqlite3_bind_int64(st, 2, Int64(currentVisitID))
                    if dateCol != nil {
                        _ = cutoffISO.withCString { cstr in
                            sqlite3_bind_text(st, 3, cstr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        }
                    }

                    while sqlite3_step(st) == SQLITE_ROW {
                        func col(_ i: Int32) -> String {
                            guard let c = sqlite3_column_text(st, i) else { return "" }
                            return String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                        }

                        var idx: Int32 = 0
                        let _ = sqlite3_column_int64(st, idx); idx += 1 // id (unused in title)
                        let visitDateISO = col(idx); idx += 1
                        let visitTypeRaw = col(idx); idx += 1
                        let problems = col(idx); idx += 1
                        let conclusions = col(idx); idx += 1
                        let parents = col(idx); idx += 1
                        let issues = col(idx); idx += 1
                        let comments = col(idx); idx += 1

                        // Title: Date · Visit Type · Age
                        let visitLabel = visitTypeRaw.isEmpty ? "Well Visit" : (readableVisitType(visitTypeRaw) ?? visitTypeRaw)
                        let age = visitDateISO.isEmpty ? "" : ageString(dobISO: effectiveDobISO, onDateISO: visitDateISO)
                        let dateShort = visitDateISO.isEmpty ? "—" : visitDateISO
                        let title = [dateShort, visitLabel, age.isEmpty ? nil : "Age \(age)"]
                            .compactMap { $0 }
                            .joined(separator: " · ")

                        // Lines (short, prioritized)
                        var lines: [String] = []
                        if !issues.isEmpty { lines.append("Issues since last: \(issues)") }
                        if !problems.isEmpty { lines.append("Problems: \(problems)") }
                        if !conclusions.isEmpty { lines.append("Conclusions: \(conclusions)") }
                        if !parents.isEmpty { lines.append("Parents’ concerns: \(parents)") }
                        if !comments.isEmpty { lines.append("Comments: \(comments)") }

                        // Keep it concise
                        if lines.count > 3 { lines = Array(lines.prefix(3)) }

                        let dateOut = visitDateISO.isEmpty ? "—" : visitDateISO
                        let findingsStr: String? = lines.isEmpty ? nil : lines.joined(separator: " • ")
                        if !title.isEmpty {
                            results.append((title: title, date: dateOut, findings: findingsStr))
                        }
                    }
                }
            }
        } catch {
            print("[ReportDataLoader] previousWell error: \(error)")
        }
        print("[ReportDataLoader] previousWell: \(results.count) items for visit \(currentVisitID)")
        return results
    }

    // Fetch patient's DOB (ISO-like string) from patients table, trying common column names.
    private func fetchDOBFromPatients(patientID: Int64) -> String? {
        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Discover columns in patients
                var cols = Set<String>()
                var stmtCols: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(patients);", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
                    }
                }

                // Prefer an existing DOB-like column
                let dobCol = ["dob","date_of_birth","dob_iso","dobISO","birth_date"].first(where: { cols.contains($0) }) ?? "dob"

                let sql = "SELECT \(dobCol) FROM patients WHERE id = ? LIMIT 1;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, patientID)
                    if sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) {
                        var s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)

                        // Normalize variants → "yyyy-MM-dd"
                        if s.contains("/") || s.contains(".") {
                            s = s.replacingOccurrences(of: "/", with: "-")
                                 .replacingOccurrences(of: ".", with: "-")
                        }
                        // Strip any time component
                        if let t = s.firstIndex(of: "T") { s = String(s[..<t]) }
                        if let sp = s.firstIndex(of: " ") { s = String(s[..<sp]) }

                        return s.isEmpty ? nil : s
                    }
                }
            }
        } catch { }
        return nil
    }

    // Load Developmental section for a WELL visit:
    // - From well_visits: mchat/dev test + (optionally) parent_concerns
    // - From well_visit_milestones: achieved/total + flags (non-achieved with optional notes)
    private func loadDevelopmentForWellVisit(visitID: Int) -> (dev: [String:String], achieved: Int, total: Int, flags: [String]) {
        var dev: [String:String] = [:]
        var achieved = 0
        var total = 0
        var flags: [String] = []

        func nonEmpty(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }

        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // -------- well_visits row (M-CHAT / Dev Test / Parent Concerns) --------
                // Discover which table is used for well visits
                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
                        }
                    }
                    return cols
                }
                let wellTable = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"

                // Pull entire row
                var stmtWell: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT * FROM \(wellTable) WHERE id = ? LIMIT 1;", -1, &stmtWell, nil) == SQLITE_OK, let st = stmtWell {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(visitID))
                    if sqlite3_step(st) == SQLITE_ROW {
                        var row: [String:String] = [:]
                        let n = sqlite3_column_count(st)
                        for i in 0..<n {
                            guard let cname = sqlite3_column_name(st, i) else { continue }
                            let key = String(cString: cname)
                            if sqlite3_column_type(st, i) != SQLITE_NULL, let cval = sqlite3_column_text(st, i) {
                                let val = String(cString: cval).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !val.isEmpty { row[key] = val }
                            }
                        }

                        // M-CHAT
                        let mScore = nonEmpty(row["mchat_score"])
                        let mRes   = nonEmpty(row["mchat_result"])
                        if let s = mScore, let r = mRes {
                            dev["M-CHAT"] = "\(s) (\(r))"
                        } else if let s = mScore {
                            dev["M-CHAT"] = s
                        } else if let r = mRes {
                            dev["M-CHAT"] = r
                        }

                        // Developmental test
                        let dScore = nonEmpty(row["devtest_score"])
                        let dRes   = nonEmpty(row["devtest_result"])
                        if let s = dScore, let r = dRes {
                            dev["Developmental Test"] = "\(s) (\(r))"
                        } else if let s = dScore {
                            dev["Developmental Test"] = s
                        } else if let r = dRes {
                            dev["Developmental Test"] = r
                        }

                        // Optional: a separate parent concerns string specifically under Development
                        if let pc = nonEmpty(row["parent_concerns"]) ?? nonEmpty(row["parents_concerns"]) {
                            dev["Parent Concerns"] = pc
                        }
                    }
                }

                // -------- well_visit_milestones (by visit id) --------
                // Ensure table exists
                var milestoneCols = Set<String>()
                var stmtCols: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(well_visit_milestones);", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let c = sqlite3_column_text(s, 1) { milestoneCols.insert(String(cString: c)) }
                    }
                }

                if !milestoneCols.isEmpty {
                    // Identify FK column for visit linkage
                    let fk = ["well_visit_id","visit_id","visitId","visitID"].first(where: { milestoneCols.contains($0) }) ?? "visit_id"

                    // Identify text columns (be robust)
                    let codeCol   = milestoneCols.contains("code") ? "code" : (milestoneCols.contains("milestone_code") ? "milestone_code" : nil)
                    let labelCol  = milestoneCols.contains("label") ? "label" : (milestoneCols.contains("milestone_label") ? "milestone_label" : nil)
                    let statusCol = milestoneCols.contains("status") ? "status" : (milestoneCols.contains("result") ? "result" : nil)
                    let noteCol   = milestoneCols.contains("note") ? "note" : (milestoneCols.contains("notes") ? "notes" : nil)

                    var colsList: [String] = []
                    colsList.append(codeCol ?? "'' as code")
                    colsList.append(labelCol ?? "'' as label")
                    colsList.append(statusCol ?? "'' as status")
                    colsList.append(noteCol ?? "'' as note")

                    let sql = """
                    SELECT \(colsList.joined(separator: ",")) FROM well_visit_milestones
                    WHERE \(fk) = ?
                    ORDER BY id ASC;
                    """
                    var st: OpaquePointer?
                    if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let stmt = st {
                        defer { sqlite3_finalize(stmt) }
                        sqlite3_bind_int64(stmt, 1, Int64(visitID))
                        while sqlite3_step(stmt) == SQLITE_ROW {
                            func col(_ i: Int32) -> String {
                                guard let c = sqlite3_column_text(stmt, i) else { return "" }
                                return String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            let code   = col(0)
                            let label  = col(1)
                            let status = col(2)
                            let note   = col(3)
                            total += 1

                            let statusL = status.lowercased()
                            let isAchieved = ["achieved","done","passed","ok","normal","complete","completed"].contains(statusL)
                            if isAchieved {
                                achieved += 1
                            } else {
                                let title = !label.isEmpty ? label : (!code.isEmpty ? code : "Milestone")
                                var line = title
                                if !status.isEmpty { line += " (\(status))" }
                                if !note.isEmpty { line += " — \(note)" }
                                flags.append(line)
                            }
                        }
                    }
                }
            }
        } catch {
            // swallow; leave defaults
        }

        return (dev, achieved, total, flags)
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

    // Fetch patient MRN for a SICK episode from the bundle DB (patients.mrn)
    private func fetchMRNForEpisode(_ episodeID: Int) -> String? {
        do {
            let dbPath = try currentBundleDBPath()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Discover patient FK on episodes
                var epCols = Set<String>()
                var stmtCols: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(episodes);", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let c = sqlite3_column_text(s, 1) { epCols.insert(String(cString: c)) }
                    }
                }
                let fk = ["patient_id","patientId","patientID"].first(where: { epCols.contains($0) }) ?? "patient_id"

                let sql = """
                SELECT p.mrn
                FROM patients p
                JOIN episodes e ON p.id = e.\(fk)
                WHERE e.id = ? LIMIT 1;
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(episodeID))
                    if sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) {
                        let val = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !val.isEmpty { return val }
                    }
                }
            }
        } catch { }
        return nil
    }

    // Fetch patient MRN for a WELL visit from the bundle DB (patients.mrn)
    private func fetchMRNForWellVisit(_ visitID: Int) -> String? {
        do {
            let dbPath = try currentBundleDBPath()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
                        }
                    }
                    return cols
                }
                let wellTable = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"
                let cols = columns(in: wellTable)
                let fk = ["patient_id","patientId","patientID"].first(where: { cols.contains($0) }) ?? "patient_id"

                let sql = """
                SELECT p.mrn
                FROM patients p
                JOIN \(wellTable) w ON p.id = w.\(fk)
                WHERE w.id = ? LIMIT 1;
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(visitID))
                    if sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) {
                        let val = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !val.isEmpty { return val }
                    }
                }
            }
        } catch { }
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

    // MARK: - Meta builders (WELL)

    // NOTE: keep this NON-@MainActor to match current call sites and avoid actor churn.
    // We also avoid calling the @MainActor debug helper; we use currentBundleDBPath().
    private func buildMetaForWell(visitID: Int) throws -> ReportMeta {
        let (patientName, alias, mrn, dobISO, sex) = basicPatientStrings()
        let properPatientName = fetchPatientNameForWellVisit(visitID) ?? patientName
        let mrnResolved = fetchMRNForWellVisit(visitID) ?? mrn

        // Defaults (kept exactly as before, then overridden by DB fields if present)
        var visitDateISO: String = appState.visits.first(where: { $0.id == visitID })?.dateISO
            ?? ISO8601DateFormatter().string(from: Date())
        var visitTypeReadable: String? = nil
        var createdISO: String? = nil
        var updatedISO: String? = nil

        do {
            let dbPath = try currentBundleDBPath()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Discover columns for a table
                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
                        }
                    }
                    return cols
                }

                // Decide which table holds well visits
                let wellTable = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"
                let cols = columns(in: wellTable)

                // Build a resilient SELECT that returns strings (or '') for each field
                let vtype = cols.contains("visit_type") ? "visit_type" : "''"
                let vdate = cols.contains("visit_date") ? "visit_date" : "''"
                let cAt   = cols.contains("created_at") ? "created_at" : "''"
                let uAt   = cols.contains("updated_at") ? "updated_at" : "''"

                let sql = """
                SELECT \(vtype) as visit_type,
                       \(vdate) as visit_date,
                       \(cAt)   as created_at,
                       \(uAt)   as updated_at
                FROM \(wellTable)
                WHERE id = ?
                LIMIT 1;
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
                        // Pull values if present
                        if let vt = col(0) { visitTypeReadable = readableVisitType(vt) ?? vt }
                        let dbVisitDate = col(1)       // visit_date
                        let dbCreated    = col(2)      // created_at
                        let dbUpdated    = col(3)      // updated_at

                        createdISO = dbCreated
                        updatedISO = dbUpdated

                        // Prefer visit_date, else created_at, else keep existing default
                        if let vd = dbVisitDate, !vd.isEmpty {
                            visitDateISO = vd
                        } else if let c = dbCreated, !c.isEmpty {
                            visitDateISO = c
                        }
                    }
                }
            }
        } catch {
            // leave defaults; ReportBuilder will still show "Report Generated"
        }

        let clinicianName = fetchClinicianNameForWellVisit(visitID) ?? activeClinicianName()
        let age = ageString(dobISO: dobISO, onDateISO: visitDateISO)
        let nowISO = ISO8601DateFormatter().string(from: Date())

        return ReportMeta(
            alias: alias,
            mrn: mrnResolved,
            name: properPatientName,
            dobISO: dobISO,
            sex: sex,
            visitDateISO: visitDateISO,
            ageAtVisit: age,
            clinicianName: clinicianName,
            visitTypeReadable: visitTypeReadable,
            createdAtISO: createdISO,     // "Created"
            updatedAtISO: updatedISO,     // "Last Edited"
            generatedAtISO: nowISO        // "Report Generated"
        )
    }

    @MainActor
    private func buildMetaForSick(episodeID: Int) throws -> ReportMeta {
        let (patientName, alias, mrn, dobISO, sex) = basicPatientStrings()
        let properPatientName = fetchPatientNameForEpisode(episodeID) ?? patientName
        let mrnResolved = fetchMRNForEpisode(episodeID) ?? mrn

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
            mrn: mrnResolved,
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
    /// Load the most recent AI assistant entry for a given sick episode, if any.
    /// Reads from the `ai_inputs` table in the current patient bundle DB.
    func loadLatestAIInputForEpisode(_ episodeID: Int) -> LatestAIInput? {
        do {
            let dbPath = try currentBundleDBPath()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Ensure the ai_inputs table exists
                var checkStmt: OpaquePointer?
                if sqlite3_prepare_v2(
                    db,
                    "SELECT name FROM sqlite_master WHERE type='table' AND name='ai_inputs' LIMIT 1;",
                    -1,
                    &checkStmt,
                    nil
                ) == SQLITE_OK, let st = checkStmt {
                    defer { sqlite3_finalize(st) }
                    // If no row, the table is missing
                    if sqlite3_step(st) != SQLITE_ROW {
                        return nil
                    }
                } else {
                    return nil
                }

                // Fetch the most recent row for this episode
                let sql = """
                SELECT model, response, created_at
                FROM ai_inputs
                WHERE episode_id = ?
                ORDER BY datetime(created_at) DESC, id DESC
                LIMIT 1;
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(episodeID))

                    if sqlite3_step(st) == SQLITE_ROW {
                        func colString(_ idx: Int32) -> String {
                            guard let c = sqlite3_column_text(st, idx) else { return "" }
                            return String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                        }

                        let model     = colString(0)
                        let response  = colString(1)
                        let createdAt = colString(2)

                        // Require at least some response text to consider this valid
                        guard !response.isEmpty else { return nil }

                        let finalModel = model.isEmpty ? "Unknown" : model
                        return LatestAIInput(
                            model: finalModel,
                            createdAt: createdAt,
                            response: response
                        )
                    }
                }
            }
        } catch {
            print("[ReportDataLoader] loadLatestAIInputForEpisode error: \(error)")
        }
        return nil
    }

    
    // MARK: - Helpers

    // Returns a list of previous well visits for the same patient (excluding the current visit),
    // with robust date/age handling and patient DOB from DB if available.
    func previousWellVisits(for currentVisitID: Int) -> [(title: String, date: String, findings: String?)] {
        var results: [(title: String, date: String, findings: String?)] = []
        do {
            let dbPath = try currentBundleDBPath()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Discover columns for a table
                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
                        }
                    }
                    return cols
                }
                let wellTable = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"

                // --- Begin block: resolve patient ID and DOB from patients table if possible ---
                // Resolve patient ID for the current visit and fetch a reliable DOB from patients
                var effectiveDobISO = basicPatientStrings().dobISO
                var currentPatientID: Int64 = -1

                do {
                    // Determine FK column name for patient linkage
                    func columns(in table: String) -> Set<String> {
                        var cols = Set<String>()
                        var stmtCols: OpaquePointer?
                        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(wellTable));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                            defer { sqlite3_finalize(s) }
                            while sqlite3_step(s) == SQLITE_ROW {
                                if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
                            }
                        }
                        return cols
                    }
                    let wcols = columns(in: wellTable)
                    let patientFK = ["patient_id","patientId","patientID"].first(where: { wcols.contains($0) }) ?? "patient_id"

                    // Fetch patient id for the current visit
                    var stmtPID: OpaquePointer?
                    if sqlite3_prepare_v2(db, "SELECT \(patientFK) FROM \(wellTable) WHERE id = ? LIMIT 1;", -1, &stmtPID, nil) == SQLITE_OK, let stp = stmtPID {
                        defer { sqlite3_finalize(stp) }
                        sqlite3_bind_int64(stp, 1, Int64(currentVisitID))
                        if sqlite3_step(stp) == SQLITE_ROW {
                            currentPatientID = sqlite3_column_int64(stp, 0)
                        }
                    }

                    // If we resolved a patient id, prefer DOB from patients table
                    if currentPatientID > 0, let dobFromDB = fetchDOBFromPatients(patientID: currentPatientID) {
                        effectiveDobISO = dobFromDB
                    }
                } // swallow errors; we'll keep the appState DOB fallback if needed
                // --- End block ---

                // Determine FK column name for patient linkage (again for the SQL)
                let wcols = columns(in: wellTable)
                let patientFK = ["patient_id","patientId","patientID"].first(where: { wcols.contains($0) }) ?? "patient_id"

                // Build SQL for previous visits, coalescing visit_date and fallbacks, and extracting normalized date for age calculation
                let sqlPrev = """
SELECT
    id,
    COALESCE(visit_date, created_at, updated_at, date) AS visit_date_raw,
    CASE
        WHEN visit_date LIKE '____-__-__%' THEN substr(visit_date,1,10)
        WHEN created_at LIKE '____-__-__%' THEN substr(created_at,1,10)
        WHEN updated_at LIKE '____-__-__%' THEN substr(updated_at,1,10)
        WHEN date       LIKE '____-__-__%' THEN substr(date,1,10)
        ELSE COALESCE(visit_date, created_at, updated_at, date)
    END AS visit_date_for_age,
    visit_type,
    problem_listing,
    conclusions,
    parents_concerns,
    issues_since_last,
    comments
FROM \(wellTable)
WHERE \(patientFK) = ? AND id <> ?
ORDER BY visit_date_raw DESC;
"""
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sqlPrev, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, currentPatientID)
                    sqlite3_bind_int64(st, 2, Int64(currentVisitID))
                    while sqlite3_step(st) == SQLITE_ROW {
                        var idx: Int32 = 0
                        func col(_ i: Int32) -> String {
                            guard let c = sqlite3_column_text(st, i) else { return "" }
                            return String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        let _ = sqlite3_column_int64(st, idx); idx += 1 // id (unused in title)
                        let visitDateRaw = col(idx); idx += 1          // visit_date_raw
                        let visitDateForAge = col(idx); idx += 1       // visit_date_for_age
                        let visitTypeRaw = col(idx); idx += 1
                        let problems = col(idx); idx += 1
                        let conclusions = col(idx); idx += 1
                        let parents = col(idx); idx += 1
                        let issues = col(idx); idx += 1
                        let comments = col(idx); idx += 1

                        // Title: Date · Visit Type · Age
                        let visitLabel = visitTypeRaw.isEmpty ? "Well Visit" : (readableVisitType(visitTypeRaw) ?? visitTypeRaw)

                        // Compute age using an age-safe ISO-like date (YYYY-MM-DD when available); fallback to raw if needed.
                        let ageCalc = visitDateForAge.isEmpty ? "—" : ageString(dobISO: effectiveDobISO, onDateISO: visitDateForAge)
                        let age = (ageCalc == "—") ? "" : ageCalc

                        // Keep the raw (possibly pretty) date for display; ReportBuilder may reformat if needed.
                        let dateShort = visitDateRaw.isEmpty ? "—" : visitDateRaw

                        let title = [dateShort, visitLabel, age.isEmpty ? nil : "Age \(age)"]
                            .compactMap { $0 }
                            .joined(separator: " · ")

                        // Lines (short, prioritized)
                        var lines: [String] = []
                        if !issues.isEmpty { lines.append("Issues since last: \(issues)") }
                        if !problems.isEmpty { lines.append("Problems: \(problems)") }
                        if !conclusions.isEmpty { lines.append("Conclusions: \(conclusions)") }
                        if !parents.isEmpty { lines.append("Parents’ concerns: \(parents)") }
                        if !comments.isEmpty { lines.append("Comments: \(comments)") }

                        // Keep it concise
                        if lines.count > 3 { lines = Array(lines.prefix(3)) }

                        let dateOut = visitDateRaw.isEmpty ? "—" : visitDateRaw
                        let findingsStr: String? = lines.isEmpty ? nil : lines.joined(separator: " • ")
                        if !title.isEmpty {
                            results.append((title: title, date: dateOut, findings: findingsStr))
                        }
                    }
                }
            }
        } catch {
            print("[ReportDataLoader] previousWell error: \(error)")
        }
        print("[ReportDataLoader] previousWell: \(results.count) items for visit \(currentVisitID)")
        return results
    }

    

        struct LatestAIInput {
            let model: String
            let createdAt: String
            let response: String
        }
    // MARK: - Growth data for WELL visit (points only; rendering is done elsewhere)
    

        struct ReportGrowthSeries {
            let wfa: [ReportGrowth.Point]   // kg vs age (months)
            let lhfa: [ReportGrowth.Point]  // cm vs age (months)
            let hcfa: [ReportGrowth.Point]  // cm vs age (months)
            let sex: ReportGrowth.Sex
            let dobISO: String
            let visitDateISO: String
        }
        private func ensureGrowthSchema(_ db: OpaquePointer?) {
                guard let db = db else { return }

                @discardableResult
                func exec(_ sql: String) -> Int32 {
                    var err: UnsafeMutablePointer<Int8>?
                    let rc = sqlite3_exec(db, sql, nil, nil, &err)
                    if rc != SQLITE_OK {
                        let msg = err.flatMap { String(cString: $0) } ?? "unknown"
                        NSLog("Growth schema exec failed: \(msg)")
                        if let e = err { sqlite3_free(e) }
                    }
                    return rc
                }

                // Manual user-entered points (broad columns for compatibility across earlier schemas)
                let createManual = """
                CREATE TABLE IF NOT EXISTS manual_growth (
                  id INTEGER PRIMARY KEY,
                  patient_mrn TEXT,
                  patient_id INTEGER,
                  date TEXT NOT NULL,
                  age_months REAL,
                  weight_kg REAL,
                  length_cm REAL,
                  height_cm REAL,
                  head_circumference_cm REAL,
                  unit TEXT
                );
                """

                // Visit-linked vitals (again, broad superset of common names)
                let createVitals = """
                CREATE TABLE IF NOT EXISTS vitals (
                  id INTEGER PRIMARY KEY,
                  visit_id TEXT,
                  patient_id INTEGER,
                  date TEXT,
                  recorded_at TEXT,
                  measured_at TEXT,
                  created_at TEXT,
                  updated_at TEXT,
                  weight_kg REAL,
                  length_cm REAL,
                  height_cm REAL,
                  head_circ_cm REAL,
                  head_circumference_cm REAL,
                  wt_kg REAL,
                  stature_cm REAL
                );
                """

                _ = exec(createManual)
                _ = exec(createVitals)
            }
        
        
        /// Collect patient growth points up to and including the WELL visit date.
        /// Sources: perinatal_history (birth/discharge), vitals, manual_growth.
        /// Units normalized to kg / cm. Ages expressed in months (days / 30.4375).
    @MainActor
    func loadGrowthSeriesForWell(visitID: Int) -> ReportGrowthSeries? {
        // Resolve db path
        guard let dbPath = try? bundleDBPathWithDebug() else { return nil }

        // Try RW+CREATE so we can create missing tables; fall back to RO if needed.
        var dbHandle: OpaquePointer?
        var openedRW = false
        if sqlite3_open_v2(dbPath, &dbHandle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, dbHandle != nil {
            openedRW = true
        } else if sqlite3_open_v2(dbPath, &dbHandle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, dbHandle != nil {
            openedRW = false
        } else {
            return nil
        }
        guard let db = dbHandle else { return nil }
        defer { sqlite3_close(db) }

        // If writable, ensure growth schema exists (idempotent).
        if openedRW { ensureGrowthSchema(db) }

            // Helper: read columns of a table
            func columns(in table: String) -> Set<String> {
                var cols = Set<String>()
                var st: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &st, nil) == SQLITE_OK, let s = st {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
                    }
                }
                return cols
            }

            // Choose well table and FK to patients
            let wellTable = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"
            let wcols = columns(in: wellTable)
            let patientFK = ["patient_id","patientId","patientID"].first(where: { wcols.contains($0) }) ?? "patient_id"

            // Resolve patient id, visit date
            var patientID: Int64 = -1
            var visitDateISO: String = ""
            do {
                var st: OpaquePointer?
                // Pull whole row so we can be robust on date columns
                if sqlite3_prepare_v2(db, "SELECT * FROM \(wellTable) WHERE id = ? LIMIT 1;", -1, &st, nil) == SQLITE_OK, let s = st {
                    defer { sqlite3_finalize(s) }
                    sqlite3_bind_int64(s, 1, Int64(visitID))
                    if sqlite3_step(s) == SQLITE_ROW {
                        // Map row into dictionary
                        var row: [String:String] = [:]
                        let n = sqlite3_column_count(s)
                        for i in 0..<n {
                            guard let cname = sqlite3_column_name(s, i) else { continue }
                            let key = String(cString: cname)
                            if sqlite3_column_type(s, i) != SQLITE_NULL, let cval = sqlite3_column_text(s, i) {
                                let val = String(cString: cval).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !val.isEmpty { row[key] = val }
                            }
                        }
                        if let pidStr = row[patientFK], let pid = Int64(pidStr) {
                            patientID = pid
                        } else if let pid = row[patientFK] { patientID = (pid as NSString).longLongValue }

                        // visit_date precedence: visit_date → created_at → updated_at → date
                        visitDateISO =
                            row["visit_date"] ??
                            row["created_at"] ??
                            row["updated_at"] ??
                            row["date"] ?? ""
                    }
                }
            }

            guard patientID > 0 else { return nil }

            // Resolve DOB & SEX from patients (prefer DB value over appState)
            var dobISO = basicPatientStrings().dobISO
            var sexStr = basicPatientStrings().sex
            do {
                var st: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT first_name,last_name,dob,sex FROM patients WHERE id = ? LIMIT 1;", -1, &st, nil) == SQLITE_OK, let s = st {
                    defer { sqlite3_finalize(s) }
                    sqlite3_bind_int64(s, 1, patientID)
                    if sqlite3_step(s) == SQLITE_ROW {
                        if let c = sqlite3_column_text(s, 2) {
                            let v = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !v.isEmpty { dobISO = v }
                        }
                        if let c = sqlite3_column_text(s, 3) {
                            let v = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !v.isEmpty { sexStr = v }
                        }
                    }
                }
            }

            // Parse DOB and visit date to bound points (if no visitDate, allow all)
            guard let dobDate = parseDateFlexible(dobISO) else { return nil }
            let visitCut = parseDateFlexible(visitDateISO)

            // Helpers
            func months(from dob: Date, to d: Date) -> Double {
                let seconds = d.timeIntervalSince(dob)
                let days = seconds / 86400.0
                return max(0.0, days / 30.4375)
            }
            func withinVisit(_ d: Date) -> Bool {
                guard let cut = visitCut else { return true }
                return d <= cut
            }

            var wfa: [ReportGrowth.Point] = []
            var lhfa: [ReportGrowth.Point] = []
            var hcfa: [ReportGrowth.Point] = []

            // -------- PERINATAL: birth / discharge --------
            if columns(in: "perinatal_history").isEmpty == false {
                // Single most recent row per patient
                let sqlP = """
                SELECT birth_weight_g, birth_length_cm, birth_head_circumference_cm,
                       maternity_discharge_date, discharge_weight_g, updated_at
                FROM perinatal_history
                WHERE patient_id = ?
                ORDER BY COALESCE(updated_at, id) DESC
                LIMIT 1;
                """
                var st: OpaquePointer?
                if sqlite3_prepare_v2(db, sqlP, -1, &st, nil) == SQLITE_OK, let s = st {
                    defer { sqlite3_finalize(s) }
                    sqlite3_bind_int64(s, 1, patientID)
                    if sqlite3_step(s) == SQLITE_ROW {
                        func colStr(_ i: Int32) -> String? {
                            guard let c = sqlite3_column_text(s, i) else { return nil }
                            let v = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            return v.isEmpty ? nil : v
                        }
                        // Birth (age = 0m)
                        if let g = colStr(0), let gw = Double(g) { wfa.append(.init(ageMonths: 0.0, value: gw / 1000.0)) }
                        if let l = colStr(1), let lc = Double(l) { lhfa.append(.init(ageMonths: 0.0, value: lc)) }
                        if let h = colStr(2), let hc = Double(h) { hcfa.append(.init(ageMonths: 0.0, value: hc)) }

                        // Discharge
                        let discDateStr = colStr(3)
                        let discWtStr   = colStr(4)
                        if let ds = discDateStr, let d = parseDateFlexible(ds), withinVisit(d) {
                            let ageM = months(from: dobDate, to: d)
                            if let s = discWtStr, let g = Double(s) {
                                wfa.append(.init(ageMonths: ageM, value: g / 1000.0))
                            }
                        }
                    }
                }
            }

            // -------- VITALS table --------
            if columns(in: "vitals").isEmpty == false {
                // Try to find linkage and common column names
                let vcols = columns(in: "vitals")
                let pidCol = vcols.contains("patient_id") ? "patient_id" :
                             (vcols.contains("patientId") ? "patientId" :
                             (vcols.contains("patientID") ? "patientID" : nil))
                // Date columns to try
                let dateCols = ["date","recorded_at","measured_at","created_at","updated_at"]

                // Build SELECT dynamically
                let pidWhere = pidCol != nil ? "WHERE \(pidCol!) = ?" : ""
                let sqlV = "SELECT * FROM vitals \(pidWhere);"
                var st: OpaquePointer?
                if sqlite3_prepare_v2(db, sqlV, -1, &st, nil) == SQLITE_OK, let s = st {
                    defer { sqlite3_finalize(s) }
                    if pidCol != nil { sqlite3_bind_int64(s, 1, patientID) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        // Row dict
                        var row: [String:String] = [:]
                        let n = sqlite3_column_count(s)
                        for i in 0..<n {
                            guard let cname = sqlite3_column_name(s, i) else { continue }
                            let key = String(cString: cname)
                            if sqlite3_column_type(s, i) != SQLITE_NULL, let cval = sqlite3_column_text(s, i) {
                                let val = String(cString: cval).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !val.isEmpty { row[key] = val }
                            }
                        }
                        // Date
                        let dateRaw = dateCols.compactMap { row[$0] }.first
                        guard let dateStr = dateRaw, let d = parseDateFlexible(dateStr), withinVisit(d) else { continue }
                        let ageM = months(from: dobDate, to: d)

                        // Weights
                        if let w = row["weight_kg"] ?? row["weight"] ?? row["wt_kg"], let dv = Double(w) {
                            wfa.append(.init(ageMonths: ageM, value: dv))
                        }
                        // Length/Height
                        if let l = row["length_cm"] ?? row["height_cm"] ?? row["length"] ?? row["stature_cm"], let dv = Double(l) {
                            lhfa.append(.init(ageMonths: ageM, value: dv))
                        }
                        // Head circumference
                        if let h = row["head_circumference_cm"] ?? row["hc_cm"] ?? row["head_circ_cm"], let dv = Double(h) {
                            hcfa.append(.init(ageMonths: ageM, value: dv))
                        }
                    }
                }
            }

            // -------- MANUAL_GROWTH table (optional) --------
            if columns(in: "manual_growth").isEmpty == false {
                let gcols = columns(in: "manual_growth")
                let pidCol = gcols.contains("patient_id") ? "patient_id" :
                             (gcols.contains("patientId") ? "patientId" :
                             (gcols.contains("patientID") ? "patientID" : nil))
                let dateCols = ["date","recorded_at","created_at","updated_at"]
                let sqlG = "SELECT * FROM manual_growth \(pidCol != nil ? "WHERE \(pidCol!) = ?" : "");"
                var st: OpaquePointer?
                if sqlite3_prepare_v2(db, sqlG, -1, &st, nil) == SQLITE_OK, let s = st {
                    defer { sqlite3_finalize(s) }
                    if pidCol != nil { sqlite3_bind_int64(s, 1, patientID) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        var row: [String:String] = [:]
                        let n = sqlite3_column_count(s)
                        for i in 0..<n {
                            guard let cname = sqlite3_column_name(s, i) else { continue }
                            let key = String(cString: cname)
                            if sqlite3_column_type(s, i) != SQLITE_NULL, let cval = sqlite3_column_text(s, i) {
                                let val = String(cString: cval).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !val.isEmpty { row[key] = val }
                            }
                        }
                        // If table stores age_months directly, prefer that; else compute from date
                        let ageM: Double? = {
                            if let a = row["age_months"], let dv = Double(a) { return dv }
                            if let ds = dateCols.compactMap({ row[$0] }).first, let d = parseDateFlexible(ds) {
                                return withinVisit(d) ? months(from: dobDate, to: d) : nil
                            }
                            return nil
                        }()
                        guard let age = ageM else { continue }

                        if let w = row["weight_kg"] ?? row["weight"], let dv = Double(w) {
                            wfa.append(.init(ageMonths: age, value: dv))
                        }
                        if let l = row["length_cm"] ?? row["height_cm"] ?? row["length"], let dv = Double(l) {
                            lhfa.append(.init(ageMonths: age, value: dv))
                        }
                        if let h = row["head_circumference_cm"] ?? row["hc_cm"] ?? row["head_circ_cm"], let dv = Double(h) {
                            hcfa.append(.init(ageMonths: age, value: dv))
                        }
                    }
                }
            }

            // Sort by age and return (no dedup beyond stable sort)
            func sortPts(_ pts: inout [ReportGrowth.Point]) {
                pts.sort { $0.ageMonths < $1.ageMonths }
            }
            sortPts(&wfa); sortPts(&lhfa); sortPts(&hcfa)

            let sex = (sexStr.uppercased().hasPrefix("F")) ? ReportGrowth.Sex.female : .male
            return ReportGrowthSeries(wfa: wfa, lhfa: lhfa, hcfa: hcfa, sex: sex, dobISO: dobISO, visitDateISO: visitDateISO)
        }
    }

extension ReportDataLoader {

    /// Age at the given WELL visit, expressed in months (used for WellVisitReportRules age gating).
    /// Returns nil if DOB or visit date cannot be parsed.
    func wellVisitAgeMonths(visitID: Int) -> Double? {
        do {
            let meta = try buildMetaForWell(visitID: visitID)
            guard let dob = parseDateFlexible(meta.dobISO),
                  let visit = parseDateFlexible(meta.visitDateISO) else {
                return nil
            }
            let seconds = visit.timeIntervalSince(dob)
            let days = seconds / 86400.0
            // Use the same month length convention as growth logic (30.4375 days)
            let months = days / 30.4375
            return max(0.0, months)
        } catch {
            return nil
        }
    }

    // MARK: - Date parsing helpers (SQLite & ISO tolerant)
    private static let _posix: Locale = Locale(identifier: "en_US_POSIX")
    private static let _gmt: TimeZone = TimeZone(secondsFromGMT: 0)!

    // Reuse formatters to avoid allocation churn
    private static let _dfYMD_HMS: DateFormatter = {
        let df = DateFormatter()
        df.locale = _posix
        df.timeZone = _gmt
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }()

    private static let _dfYMD_HM: DateFormatter = {
        let df = DateFormatter()
        df.locale = _posix
        df.timeZone = _gmt
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()

    private static let _dfYMD: DateFormatter = {
        let df = DateFormatter()
        df.locale = _posix
        df.timeZone = _gmt
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private static let _dfYMD_T_HMS: DateFormatter = {
        let df = DateFormatter()
        df.locale = _posix
        df.timeZone = _gmt
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return df
    }()

    private func parseDateFlexible(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // 1) ISO8601 fast path if 'T' or 'Z' present
        if s.contains("T") || s.hasSuffix("Z") {
            if let d = ISO8601DateFormatter().date(from: s) { return d }
            if let d = ReportDataLoader._dfYMD_T_HMS.date(from: s) { return d }
        }

        // 2) Common SQLite / TEXT timestamps
        if let d = ReportDataLoader._dfYMD_HMS.date(from: s) { return d }
        if let d = ReportDataLoader._dfYMD_HM.date(from: s)  { return d }
        if let d = ReportDataLoader._dfYMD.date(from: s)     { return d }

        // 3) If there's a space, try the date-only part
        if let sp = s.firstIndex(of: " ") {
            let dateOnly = String(s[..<sp])
            if let d = ReportDataLoader._dfYMD.date(from: dateOnly) { return d }
        }

        return nil
    }

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
        guard let dob = parseDateFlexible(dobISO),
              let ref = parseDateFlexible(onDateISO),
              ref >= dob else { return "—" }

        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day], from: dob, to: ref)
        let y = comps.year ?? 0
        let m = comps.month ?? 0
        let d = comps.day ?? 0

        // < 1 month: days only
        if y == 0 && m == 0 { return "\(max(d, 0))d" }

        // < 6 months: months + days
        if y == 0 && m < 6 {
            return d > 0 ? "\(m)m \(d)d" : "\(m)m"
        }

        // 6–11 months: months only
        if y == 0 { return "\(m)m" }

        // ≥ 12 months: years + months
        return m > 0 ? "\(y)y \(m)m" : "\(y)y"
    }
}

extension ReportDataLoader {
    /// Load Physical Examination (grouped) and trailing text fields for a WELL visit.
    /// Reads from `well_visits` (or fallback `visits`) and returns grouped PE lines and summary strings.
    @MainActor
    fileprivate func loadWellPEAndText(visitID: Int) -> (groups: [(String,[String])],
                                                         problem: String?,
                                                         conclusions: String?,
                                                         anticipatory: String?,
                                                         comments: String?,
                                                         nextVisitDate: String?) {
        var groupsOut: [(String,[String])] = []
        var problem: String?
        var conclusions: String?
        var anticipatory: String?
        var comments: String?
        var nextVisitDate: String?

        func nonEmpty(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        func yn(_ raw: String?) -> String? {
            guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            let l = s.lowercased()
            if ["1","true","yes","y"].contains(l) { return "yes" }
            if ["0","false","no","n"].contains(l) { return "no" }
            return s
        }
        func isYes(_ raw: String?) -> Bool? {
            guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            let l = s.lowercased()
            if ["1","true","yes","y"].contains(l) { return true }
            if ["0","false","no","n"].contains(l) { return false }
            return nil
        }

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
                            if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
                        }
                    }
                    return cols
                }
                let table = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"

                // Pull full row as dictionary
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT * FROM \(table) WHERE id = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(visitID))
                    if sqlite3_step(st) == SQLITE_ROW {
                        var row: [String:String] = [:]
                        let n = sqlite3_column_count(st)
                        for i in 0..<n {
                            guard let cname = sqlite3_column_name(st, i) else { continue }
                            let key = String(cString: cname)
                            if sqlite3_column_type(st, i) != SQLITE_NULL, let cval = sqlite3_column_text(st, i) {
                                let val = String(cString: cval).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !val.isEmpty { row[key] = val }
                            }
                        }

                        // --- Build grouped PE lines ---
                        var groups: [String:[String]] = [:]
                        func add(_ group: String, _ line: String) {
                            groups[group, default: []].append(line)
                        }
                        func addNormal(_ group: String, _ label: String, normalKey: String, commentKey: String?) {
                            let norm = isYes(row[normalKey])
                            let comment = nonEmpty(row[commentKey ?? ""])
                            if norm != nil || comment != nil {
                                var line = "\(label): "
                                if let n = norm { line += n ? "normal" : "abnormal" }
                                else { line += "—" }
                                if let c = comment { line += " — \(c)" }
                                add(group, line)
                            }
                        }

                        // General
                        addNormal("General", "Trophic", normalKey: "pe_trophic_normal", commentKey: "pe_trophic_comment")
                        addNormal("General", "Hydration", normalKey: "pe_hydration_normal", commentKey: "pe_hydration_comment")
                        if let color = nonEmpty(row["pe_color"]) ?? nonEmpty(row["pe_color_comment"]) {
                            add("General", "Color: \(color)")
                        }
                        addNormal("General", "Tone", normalKey: "pe_tone_normal", commentKey: "pe_tone_comment")
                        addNormal("General", "Breathing", normalKey: "pe_breathing_normal", commentKey: "pe_breathing_comment")
                        addNormal("General", "Wakefulness", normalKey: "pe_wakefulness_normal", commentKey: "pe_wakefulness_comment")

                        // Head & Eyes
                        addNormal("Head & Eyes", "Fontanelle", normalKey: "pe_fontanelle_normal", commentKey: "pe_fontanelle_comment")
                        addNormal("Head & Eyes", "Pupils RR", normalKey: "pe_pupils_rr_normal", commentKey: "pe_pupils_rr_comment")
                        addNormal("Head & Eyes", "Ocular motility", normalKey: "pe_ocular_motility_normal", commentKey: "pe_ocular_motility_comment")

                        // Cardio / Pulses
                        addNormal("Cardio / Pulses", "Heart sounds", normalKey: "pe_heart_sounds_normal", commentKey: "pe_heart_sounds_comment")
                        addNormal("Cardio / Pulses", "Femoral pulses", normalKey: "pe_femoral_pulses_normal", commentKey: "pe_femoral_pulses_comment")

                        // Abdomen
                        if let massYes = isYes(row["pe_abd_mass"]) {
                            if massYes { add("Abdomen", "Abdominal mass: present") }
                        }
                        addNormal("Abdomen", "Liver/Spleen", normalKey: "pe_liver_spleen_normal", commentKey: "pe_liver_spleen_comment")
                        addNormal("Abdomen", "Umbilic", normalKey: "pe_umbilic_normal", commentKey: "pe_umbilic_comment")

                        // Genitalia
                        if let gen = nonEmpty(row["pe_genitalia"]) {
                            add("Genitalia", "Genitalia: \(gen)")
                        }
                        if let desc = isYes(row["pe_testicles_descended"]) {
                            add("Genitalia", "Testicles descended: \(desc ? "yes" : "no")")
                        }

                        // Spine & Hips
                        addNormal("Spine & Hips", "Spine", normalKey: "pe_spine_normal", commentKey: "pe_spine_comment")
                        addNormal("Spine & Hips", "Hips", normalKey: "pe_hips_normal", commentKey: "pe_hips_comment")

                        // Skin
                        addNormal("Skin", "Marks", normalKey: "pe_skin_marks_normal", commentKey: "pe_skin_marks_comment")
                        addNormal("Skin", "Integrity", normalKey: "pe_skin_integrity_normal", commentKey: "pe_skin_integrity_comment")
                        addNormal("Skin", "Rash", normalKey: "pe_skin_rash_normal", commentKey: "pe_skin_rash_comment")

                        // Neuro / Development
                        addNormal("Neuro / Development", "Moro", normalKey: "pe_moro_normal", commentKey: "pe_moro_comment")
                        addNormal("Neuro / Development", "Hands in fist", normalKey: "pe_hands_fist_normal", commentKey: "pe_hands_fist_comment")
                        addNormal("Neuro / Development", "Symmetry", normalKey: "pe_symmetry_normal", commentKey: "pe_symmetry_comment")
                        addNormal("Neuro / Development", "Follows midline", normalKey: "pe_follows_midline_normal", commentKey: "pe_follows_midline_comment")

                        // Emit groups in a stable order
                        let order = ["General","Head & Eyes","Cardio / Pulses","Abdomen","Genitalia","Spine & Hips","Skin","Neuro / Development"]
                        for g in order {
                            if let lines = groups[g], !lines.isEmpty {
                                groupsOut.append((g, lines))
                            }
                        }

                        // --- Trailing text sections ---
                        problem        = nonEmpty(row["problem_listing"])
                        conclusions    = nonEmpty(row["conclusions"])
                        anticipatory   = nonEmpty(row["anticipatory_guidance"])
                        comments       = nonEmpty(row["comments"])
                        nextVisitDate  = nonEmpty(row["next_visit_date"])
                    }
                }
            }
        } catch {
            // leave defaults
        }

        return (groupsOut, problem, conclusions, anticipatory, comments, nextVisitDate)
    }
}

extension ReportDataLoader {
    // Read current WELL visit core fields from the bundle DB (robust to column name variants)
    private func loadCurrentWellCoreFields(visitID: Int) -> (visitType: String?, parentsConcerns: String?, feeding: [String:String], supplementation: [String:String], sleep: [String:String]) {
        var visitType: String?
        var parents: String?
        var feeding: [String:String] = [:]
        var supplementation: [String:String] = [:]
        var sleep: [String:String] = [:]

        func nonEmpty(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        func put(_ key: String, _ raw: String?) {
            if let v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                feeding[key] = v
            }
        }
        func ynify(_ raw: String?) -> String? {
            guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            let l = s.lowercased()
            if ["1","true","yes","y"].contains(l) { return "yes" }
            if ["0","false","no","n"].contains(l) { return "no" }
            return s
        }
        func addNumber(_ key: String, _ raw: String?, unit: String? = nil) {
            guard let r = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return }
            if let d = Double(r) {
                let s = d.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(d)) : String(d)
                feeding[key] = unit != nil ? "\(s) \(unit!)" : s
            } else {
                feeding[key] = r
            }
        }

        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Discover well visit table and column names
                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
                        }
                    }
                    return cols
                }
                let table = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"
                let cols = columns(in: table)

                // Pull the entire row so we can map flexible column names
                let sql = "SELECT * FROM \(table) WHERE id = ? LIMIT 1;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(visitID))
                    if sqlite3_step(st) == SQLITE_ROW {
                        // build dictionary: columnName -> string value
                        var row: [String:String] = [:]
                        let n = sqlite3_column_count(st)
                        for i in 0..<n {
                            guard let cname = sqlite3_column_name(st, i) else { continue }
                            let key = String(cString: cname)
                            if sqlite3_column_type(st, i) != SQLITE_NULL, let cval = sqlite3_column_text(st, i) {
                                let val = String(cString: cval).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !val.isEmpty { row[key] = val }
                            }
                        }

                        // Visit type subtitle
                        let vtRaw = nonEmpty(row["visit_type"]) ?? nonEmpty(row["type"]) ?? nonEmpty(row["milestone"]) ?? nonEmpty(row["title"])
                        visitType = readableVisitType(vtRaw) ?? vtRaw

                        // Parents' concerns
                        parents = nonEmpty(row["parents_concerns"]) ?? nonEmpty(row["parent_concerns"]) ?? nonEmpty(row["concerns"])

                        // Feeding
                        if let v = nonEmpty(row["feeding"]) { feeding["Notes"] = v }
                        let bf = nonEmpty(row["breastfeeding"]) ?? nonEmpty(row["feeding_breast"]) ?? nonEmpty(row["breast_milk"]) ?? nonEmpty(row["nursing"])
                        if let v = bf { feeding["Breastfeeding"] = v }
                        let ff = nonEmpty(row["formula"]) ?? nonEmpty(row["feeding_formula"])
                        if let v = ff { feeding["Formula"] = v }
                        let solids = nonEmpty(row["solids"]) ?? nonEmpty(row["feeding_solids"]) ?? nonEmpty(row["complementary_feeding"]) ?? nonEmpty(row["weaning"])
                        if let v = solids { feeding["Solids"] = v }

                        // --- Extra Feeding fields from well_visits (print only if non-empty) ---
                        put("Feeding Comment", row["feeding_comment"])
                        put("Milk Types", row["milk_types"])
                        put("Food Variety / Quantity", row["food_variety_quality"])
                        put("Dairy Amount", row["dairy_amount_text"])
                        put("Feeding Issue", row["feeding_issue"])

                        // Frequency & volumes
                        put("Feeds / 24h", row["feed_freq_per_24h"] ?? row["feeds_per_24h"] ?? row["feeds_per_day"])
                        addNumber("Feed Volume (ml)", row["feed_volume_ml"], unit: "ml")
                        addNumber("Estimated Total (ml/24h)", row["est_total_ml"], unit: "ml")
                        addNumber("Estimated (ml/kg/24h)", row["est_ml_per_kg_24h"], unit: "ml/kg/24h")

                        // Booleans
                        if let r = ynify(row["regurgitation"]) { feeding["Regurgitation"] = r }
                        if let w = ynify(row["wakes_for_feeds"] ?? row["night_feeds"] ?? row["wakes_to_feed"]) {
                            feeding["Wakes for Feeds"] = w
                        }
                        if let ebm = ynify(row["expressed_bm"]) { feeding["Expressed BM"] = ebm }

                        // Solid foods
                        if let started = ynify(row["solid_food_started"]) { feeding["Solid Foods Started"] = started }
                        put("Solid Food Start", row["solid_food_start_date"]) // raw date; builder will render as-is
                        put("Solid Food Quality", row["solid_food_quality"])
                        put("Solid Food Notes", row["solid_food_comment"])

                        // Supplementation
                        if let v = nonEmpty(row["supplementation"]) ?? nonEmpty(row["supplements"]) { supplementation["Notes"] = v }
                        let vitd = nonEmpty(row["vitamin_d"]) ?? nonEmpty(row["vit_d"]) ?? nonEmpty(row["vit_d_supplement"]) ?? nonEmpty(row["vitamin_d_iu"])
                        if let v = vitd { supplementation["Vitamin D"] = v }
                        let iron = nonEmpty(row["iron"]) ?? nonEmpty(row["ferrous"])
                        if let v = iron { supplementation["Iron"] = v }
                        if let other = nonEmpty(row["others"]) ?? nonEmpty(row["other_supplements"]) { supplementation["Other"] = other }
                        if let given = ynify(row["vitamin_d_given"]) { supplementation["Vitamin D Given"] = given }

                        // Sleep
                        if let v = nonEmpty(row["sleep"]) { sleep["Notes"] = v }
                        let hours = nonEmpty(row["sleep_hours"]) ?? nonEmpty(row["sleep_total_hours"]) ?? nonEmpty(row["sleep_total"])
                        if let v = hours { sleep["Total hours"] = v }
                        let naps = nonEmpty(row["naps"]) ?? nonEmpty(row["daytime_naps"])
                        if let v = naps { sleep["Naps"] = v }
                        let wakes = nonEmpty(row["night_wakings"]) ?? nonEmpty(row["night_wakes"]) ?? nonEmpty(row["night_awakenings"])
                        if let v = wakes { sleep["Night wakings"] = v }
                        if let qual = nonEmpty(row["sleep_quality"]) { sleep["Quality"] = qual }

                        // Additional sleep-related fields
                        if let v = nonEmpty(row["sleep_hours_text"]) { sleep["Total hours"] = v } // override with text if present
                        if let v = nonEmpty(row["sleep_regular"]) { sleep["Regular"] = v }
                        if let sn = ynify(row["sleep_snoring"]) { sleep["Snoring"] = sn }

                        // Optional: parent concerns (only if not already captured above) — use 'parents_concerns'
                        if parents == nil, let pc = nonEmpty(row["parents_concerns"]) {
                            sleep["Parent Concerns"] = pc
                        }

                        // Sleep issue flags
                        if let rep = ynify(row["sleep_issue_reported"]) { sleep["Issue Reported"] = rep }
                        if let txt = nonEmpty(row["sleep_issue_text"]) { sleep["Issue Notes"] = txt }
                    }
                }
            }
        } catch {
            // leave nil/empty dicts, renderer will show "—" or skip lines
        }

        return (visitType, parents, feeding, supplementation, sleep)
    }
}

extension ReportDataLoader {
    // Load Measurements for the current WELL visit from well_visits (or visits) table.
    // Maps:
    //  - weight_today_kg        -> "Weight"              (kg)
    //  - length_today_cm        -> "Length"              (cm)
    //  - head_circ_today_cm     -> "Head Circumference"  (cm)
    //  - delta_weight_g         -> part of "Weight gain since discharge"
    //  - delta_days_since_discharge -> appended as "over N days"
    @MainActor
    private func loadMeasurementsForWellVisit(visitID: Int) -> [String:String] {
        var out: [String:String] = [:]

        func nonEmpty(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        func fmtNumber(_ raw: String?, unit: String) -> String? {
            guard let t = nonEmpty(raw) else { return nil }
            if let d = Double(t) {
                let asInt = d.truncatingRemainder(dividingBy: 1) == 0
                return asInt ? "\(Int(d)) \(unit)" : String(format: "%.1f %@", d, unit)
            }
            return "\(t) \(unit)"
        }
        func fmtInt(_ raw: String?) -> Int? {
            guard let t = nonEmpty(raw) else { return nil }
            if let i = Int(t) { return i }
            if let d = Double(t) { return Int(d.rounded()) }
            return nil
        }

        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Determine table that holds well visits
                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
                        }
                    }
                    return cols
                }
                let table = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"

                // Fetch the row
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT * FROM \(table) WHERE id = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(visitID))
                    if sqlite3_step(st) == SQLITE_ROW {
                        // Build dictionary of all non-null, non-empty stringified values
                        var row: [String:String] = [:]
                        let n = sqlite3_column_count(st)
                        for i in 0..<n {
                            guard let cname = sqlite3_column_name(st, i) else { continue }
                            let key = String(cString: cname)
                            if sqlite3_column_type(st, i) != SQLITE_NULL, let cval = sqlite3_column_text(st, i) {
                                let val = String(cString: cval).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !val.isEmpty { row[key] = val }
                            }
                        }

                        // Core measurements
                        if let s = fmtNumber(row["weight_today_kg"], unit: "kg") {
                            out["Weight"] = s
                        }
                        if let s = fmtNumber(row["length_today_cm"], unit: "cm") {
                            out["Length"] = s
                        }
                        if let s = fmtNumber(row["head_circ_today_cm"], unit: "cm") {
                            out["Head Circumference"] = s
                        }

                        // Weight gain since discharge
                        let dW = fmtInt(row["delta_weight_g"])
                        let dD = fmtInt(row["delta_days_since_discharge"])
                        if let dw = dW {
                            let sign = dw > 0 ? "+" : ""
                            if let dd = dD {
                                out["Weight gain since discharge"] = "\(sign)\(dw) g over \(dd) days"
                            } else {
                                out["Weight gain since discharge"] = "\(sign)\(dw) g"
                            }
                        }
                    }
                }
            }
        } catch {
            // leave empty; builder will skip section if empty
        }

        return out
    }
}


extension ReportDataLoader {

    /// Resolve the raw internal visit_type ID for a WELL visit from the bundle DB.
    /// This should return canonical IDs such as "one_month", "nine_month", etc.
    /// Returns nil if the row or column cannot be found.
    private func rawVisitTypeIDForWell(visitID: Int) -> String? {
        do {
            let dbPath = try currentBundleDBPath()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Discover which table is used for well visits
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

                let table = ["well_visits", "visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"
                let cols = columns(in: table)

                // If there is no visit_type column, we cannot resolve a canonical ID
                guard cols.contains("visit_type") else { return nil }

                let sql = "SELECT visit_type FROM \(table) WHERE id = ? LIMIT 1;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(visitID))
                    if sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) {
                        let raw = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                        return raw.isEmpty ? nil : raw
                    }
                }
            }
        } catch {
            // fall through to nil
        }
        return nil
    }

    /// Returns the resolved WellVisitVisibility for a given WELL visit, using the raw
    /// visit_type from the DB plus the computed age in months.
    /// Returns nil if we cannot determine a canonical visit_type.
    func wellVisitVisibility(visitID: Int) -> WellVisitReportRules.WellVisitVisibility? {
        let age = wellVisitAgeMonths(visitID: visitID)
        let rawVisitTypeID = rawVisitTypeIDForWell(visitID: visitID)
        let visibility = WellVisitReportRules.visibility(for: rawVisitTypeID, ageMonths: age)

        #if DEBUG
        if let vis = visibility {
            let ageStr = age.map { String(format: "%.2f", $0) } ?? "nil"
            let typeStr = rawVisitTypeID ?? "nil"
            print("[ReportDataLoader] wellVisibility visitID=\(visitID) typeID='\(typeStr)' ageMonths=\(ageStr) " +
                  "sections: feed=\(vis.showFeeding) supp=\(vis.showSupplementation) sleep=\(vis.showSleep) dev=\(vis.showDevelopment)")
        } else {
            let ageStr = age.map { String(format: "%.2f", $0) } ?? "nil"
            let typeStr = rawVisitTypeID ?? "nil"
            print("[ReportDataLoader] wellVisibility visitID=\(visitID) typeID='\(typeStr)' ageMonths=\(ageStr) -> nil")
        }
        #endif

        return visibility
    }
}

extension WellVisitReportRules.WellVisitVisibility {
    /// Section-level visibility used by ReportBuilder for the
    /// "Current Visit — …" block. This is the only place where
    /// age/visit-type gating for current-visit sections lives.
    ///
    /// Contract:
    /// - Perinatal summary, previous well visits, and growth charts
    ///   are never gated here (they are handled elsewhere).
    /// - These booleans only control the *current visit* sections.
    /// - Fine-grained, field-level logic remains in WellVisitReportRules
    ///   (e.g. via the flags and any per-field helpers).

    // MARK: - Subjective / global fields (always relevant)

    /// Parents' concerns are relevant at any age.
    var showParentsConcerns: Bool { true }

    /// Problem listing is always useful when present.
    var showProblemListing: Bool { true }

    /// Conclusions / assessment are always shown for the current visit.
    var showConclusions: Bool { true }

    /// Anticipatory guidance is part of every well visit.
    var showAnticipatoryGuidance: Bool { true }

    /// Free-text clinician comments are always allowed.
    var showClinicianComments: Bool { true }

    /// Planned next visit is always allowed when provided.
    var showNextVisit: Bool { true }

    // MARK: - Feeding & supplementation

    /// Feeding block: shown whenever any age-group defines structured
    /// feeding content (milk only, under-12m structure, solids, older feeding).
    var showFeeding: Bool {
        let f = flags
        return f.isEarlyMilkOnlyVisit
            || f.isStructuredFeedingUnder12
            || f.isSolidsVisit
            || f.isOlderFeedingVisit
    }

    /// Supplementation block: mirrors the broader feeding window; in practice
    /// we show this for any visit where structured feeding is part of the layout.
    var showSupplementation: Bool {
        let f = flags
        return f.isStructuredFeedingUnder12
            || f.isSolidsVisit
            || f.isOlderFeedingVisit
    }

    // MARK: - Sleep

    /// Sleep block: we keep this available for all well visits so that
    /// any recorded sleep details (including very early visits such as
    /// the 1‑month visit) are always rendered in the report. Age‑specific
    /// content is handled by the form/rules rather than by hiding the
    /// entire section.
    var showSleep: Bool { true }

    // MARK: - Development / screening

    /// Developmental screening / tests: reserved for visits where we actually
    /// run Dev tests and/or M-CHAT according to the age matrix.
    var showDevelopment: Bool {
        let f = flags
        return f.isDevTestScoreVisit
            || f.isDevTestResultVisit
            || f.isMCHATVisit
    }

    /// Milestones summary: we keep this enabled for all milestone-based visits;
    /// detailed age-filtering is handled by the milestone engine itself.
    var showMilestones: Bool { true }

    // MARK: - Measurements & physical examination

    /// Measurements (weight/length/head circ, weight delta, etc.) are core
    /// to all well visits and are not age-gated at the section level.
    var showMeasurements: Bool { true }

    /// Physical exam is always present; age-specific details (e.g. fontanelle,
    /// primitive reflexes) are governed by the underlying form/rules, not by
    /// hiding the entire PE block.
    var showPhysicalExam: Bool { true }
}
