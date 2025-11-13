//
//  PerinatalStore.swift
//  DrsMainApp
//
//  Created by yunastic on 11/13/25.
//
//
//  PerinatalStore.swift
//  DrsMainApp
//
//  Created by you, today ☺
//

import Foundation
import SQLite3

// MARK: - Model

public struct PerinatalHistory: Identifiable, Equatable {
    public var id: Int?                    // row id (optional)
    public var patientID: Int              // unique per patient

    public var pregnancyRisk: String?
    public var birthMode: String?
    public var birthTermWeeks: Int?
    public var resuscitation: String?
    public var nicuStay: Bool?
    public var infectionRisk: String?
    public var birthWeightG: Int?
    public var birthLengthCM: Double?
    public var birthHeadCircumferenceCM: Double?
    public var maternityStayEvents: String?
    public var maternityVaccinations: String?
    public var vitaminK: Bool?
    public var feedingInMaternity: String?
    public var passedMeconium24h: Bool?
    public var urination24h: Bool?
    public var heartScreening: String?
    public var metabolicScreening: String?
    public var hearingScreening: String?
    public var motherVaccinations: String?
    public var familyVaccinations: String?
    /// Store as ISO-8601 "yyyy-MM-dd" (or datetime) string to match table TEXT
    public var maternityDischargeDate: String?
    public var dischargeWeightG: Int?
    public var illnessesAfterBirth: String?
    public var updatedAt: String?
    public var evolutionSinceMaternity: String?

    public init(
        id: Int? = nil,
        patientID: Int,
        pregnancyRisk: String? = nil,
        birthMode: String? = nil,
        birthTermWeeks: Int? = nil,
        resuscitation: String? = nil,
        nicuStay: Bool? = nil,
        infectionRisk: String? = nil,
        birthWeightG: Int? = nil,
        birthLengthCM: Double? = nil,
        birthHeadCircumferenceCM: Double? = nil,
        maternityStayEvents: String? = nil,
        maternityVaccinations: String? = nil,
        vitaminK: Bool? = nil,
        feedingInMaternity: String? = nil,
        passedMeconium24h: Bool? = nil,
        urination24h: Bool? = nil,
        heartScreening: String? = nil,
        metabolicScreening: String? = nil,
        hearingScreening: String? = nil,
        motherVaccinations: String? = nil,
        familyVaccinations: String? = nil,
        maternityDischargeDate: String? = nil,
        dischargeWeightG: Int? = nil,
        illnessesAfterBirth: String? = nil,
        updatedAt: String? = nil,
        evolutionSinceMaternity: String? = nil
    ) {
        self.id = id
        self.patientID = patientID
        self.pregnancyRisk = pregnancyRisk
        self.birthMode = birthMode
        self.birthTermWeeks = birthTermWeeks
        self.resuscitation = resuscitation
        self.nicuStay = nicuStay
        self.infectionRisk = infectionRisk
        self.birthWeightG = birthWeightG
        self.birthLengthCM = birthLengthCM
        self.birthHeadCircumferenceCM = birthHeadCircumferenceCM
        self.maternityStayEvents = maternityStayEvents
        self.maternityVaccinations = maternityVaccinations
        self.vitaminK = vitaminK
        self.feedingInMaternity = feedingInMaternity
        self.passedMeconium24h = passedMeconium24h
        self.urination24h = urination24h
        self.heartScreening = heartScreening
        self.metabolicScreening = metabolicScreening
        self.hearingScreening = hearingScreening
        self.motherVaccinations = motherVaccinations
        self.familyVaccinations = familyVaccinations
        self.maternityDischargeDate = maternityDischargeDate
        self.dischargeWeightG = dischargeWeightG
        self.illnessesAfterBirth = illnessesAfterBirth
        self.updatedAt = updatedAt
        self.evolutionSinceMaternity = evolutionSinceMaternity
    }
}

// MARK: - UI Bridging (Bool <-> Int) for form bindings
public extension PerinatalHistory {
    /// Bridge for UI that prefers 0/1 integers
    var nicuStayInt: Int? {
        get { nicuStay.map { $0 ? 1 : 0 } }
        set { nicuStay = newValue.map { $0 != 0 } }
    }
    var vitaminKInt: Int? {
        get { vitaminK.map { $0 ? 1 : 0 } }
        set { vitaminK = newValue.map { $0 != 0 } }
    }
    var passedMeconium24hInt: Int? {
        get { passedMeconium24h.map { $0 ? 1 : 0 } }
        set { passedMeconium24h = newValue.map { $0 != 0 } }
    }
    var urination24hInt: Int? {
        get { urination24h.map { $0 ? 1 : 0 } }
        set { urination24h = newValue.map { $0 != 0 } }
    }
}

// MARK: - Store

public final class PerinatalStore {
    private let dbURL: URL

    public init(dbURL: URL) {
        self.dbURL = dbURL
    }

    // MARK: Static convenience for call-sites that pass dbURL explicitly
    public static func ensureSchema(dbURL: URL) throws {
        try PerinatalStore(dbURL: dbURL).ensureSchema()
    }

    public static func fetch(dbURL: URL? = nil, for patientID: Int) throws -> PerinatalHistory? {
        let resolvedURL: URL
        if let u = dbURL {
            resolvedURL = u
        } else if let u = PerinatalStore.dbURLResolver?() {
            resolvedURL = u
        } else {
            throw NSError(domain: "PerinatalStore", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "No dbURL provided or resolvable (PerinatalStore.dbURLResolver not set)"])
        }
        return try PerinatalStore(dbURL: resolvedURL).fetchPerinatal(for: patientID)
    }

    public static func fetchOrBlank(dbURL: URL? = nil, for patientID: Int) throws -> PerinatalHistory {
        if let h = try fetch(dbURL: dbURL, for: patientID) {
            return h
        }
        return PerinatalHistory(patientID: patientID)
    }

    public static func upsert(dbURL: URL? = nil, for patientID: Int, history: PerinatalHistory) throws {
        let resolvedURL: URL
        if let u = dbURL {
            resolvedURL = u
        } else if let u = PerinatalStore.dbURLResolver?() {
            resolvedURL = u
        } else {
            throw NSError(domain: "PerinatalStore", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "No dbURL provided or resolvable (PerinatalStore.dbURLResolver not set)"])
        }
        var h = history
        if h.patientID != patientID { h.patientID = patientID }
        try PerinatalStore(dbURL: resolvedURL).upsertPerinatal(h)
    }

    // MARK: Instance convenience aliases (for older call sites)
    public func fetch(for patientID: Int) throws -> PerinatalHistory? {
        try fetchPerinatal(for: patientID)
    }

    public func upsert(for patientID: Int, history: PerinatalHistory) throws {
        var h = history
        if h.patientID != patientID { h.patientID = patientID }
        try upsertPerinatal(h)
    }

    // MARK: Schema

    public func ensureSchema() throws {
        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }
        try openDB(&db)

        let sql = """
        PRAGMA foreign_keys = ON;

        CREATE TABLE IF NOT EXISTS perinatal_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          patient_id INTEGER UNIQUE,
          pregnancy_risk TEXT,
          birth_mode TEXT,
          birth_term_weeks INTEGER,
          resuscitation TEXT,
          nicu_stay INTEGER,
          infection_risk TEXT,
          birth_weight_g INTEGER,
          birth_length_cm REAL,
          birth_head_circumference_cm REAL,
          maternity_stay_events TEXT,
          maternity_vaccinations TEXT,
          vitamin_k INTEGER,
          feeding_in_maternity TEXT,
          passed_meconium_24h INTEGER,
          urination_24h INTEGER,
          heart_screening TEXT,
          metabolic_screening TEXT,
          hearing_screening TEXT,
          mother_vaccinations TEXT,
          family_vaccinations TEXT,
          maternity_discharge_date TEXT,
          discharge_weight_g INTEGER,
          illnesses_after_birth TEXT,
          updated_at TEXT,
          evolution_since_maternity TEXT,
          FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE
        );

        CREATE UNIQUE INDEX IF NOT EXISTS idx_perinatal_patient ON perinatal_history(patient_id);
        """

        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw sqliteError(db, prefix: "ensureSchema")
        }
    }

    // MARK: CRUD

    public func fetchPerinatal(for patientID: Int) throws -> PerinatalHistory? {
        try ensureSchema()
        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }
        try openDB(&db)

        let q = """
        SELECT
            id, patient_id,
            pregnancy_risk, birth_mode, birth_term_weeks, resuscitation,
            nicu_stay, infection_risk, birth_weight_g, birth_length_cm, birth_head_circumference_cm,
            maternity_stay_events, maternity_vaccinations, vitamin_k, feeding_in_maternity,
            passed_meconium_24h, urination_24h, heart_screening, metabolic_screening, hearing_screening,
            mother_vaccinations, family_vaccinations, maternity_discharge_date, discharge_weight_g,
            illnesses_after_birth, updated_at, evolution_since_maternity
        FROM perinatal_history
        WHERE patient_id=? LIMIT 1;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError(db, prefix: "fetchPerinatal.prepare")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(patientID))

        if sqlite3_step(stmt) == SQLITE_ROW {
            var i: Int32 = 0
            func col() -> Int32 { defer { i += 1 }; return i }

            let id = intCol(stmt, col())
            let pid = intCol(stmt, col()) ?? patientID

            return PerinatalHistory(
                id: id,
                patientID: pid,
                pregnancyRisk: stringCol(stmt, col()),
                birthMode: stringCol(stmt, col()),
                birthTermWeeks: intCol(stmt, col()),
                resuscitation: stringCol(stmt, col()),
                nicuStay: boolCol(stmt, col()),
                infectionRisk: stringCol(stmt, col()),
                birthWeightG: intCol(stmt, col()),
                birthLengthCM: doubleCol(stmt, col()),
                birthHeadCircumferenceCM: doubleCol(stmt, col()),
                maternityStayEvents: stringCol(stmt, col()),
                maternityVaccinations: stringCol(stmt, col()),
                vitaminK: boolCol(stmt, col()),
                feedingInMaternity: stringCol(stmt, col()),
                passedMeconium24h: boolCol(stmt, col()),
                urination24h: boolCol(stmt, col()),
                heartScreening: stringCol(stmt, col()),
                metabolicScreening: stringCol(stmt, col()),
                hearingScreening: stringCol(stmt, col()),
                motherVaccinations: stringCol(stmt, col()),
                familyVaccinations: stringCol(stmt, col()),
                maternityDischargeDate: stringCol(stmt, col()),
                dischargeWeightG: intCol(stmt, col()),
                illnessesAfterBirth: stringCol(stmt, col()),
                updatedAt: stringCol(stmt, col()),
                evolutionSinceMaternity: stringCol(stmt, col())
            )
        }
        return nil
    }

    public func upsertPerinatal(_ ph: PerinatalHistory) throws {
        try ensureSchema()
        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }
        try openDB(&db)

        let sql = """
        INSERT INTO perinatal_history (
            patient_id,
            pregnancy_risk, birth_mode, birth_term_weeks, resuscitation,
            nicu_stay, infection_risk, birth_weight_g, birth_length_cm, birth_head_circumference_cm,
            maternity_stay_events, maternity_vaccinations, vitamin_k, feeding_in_maternity,
            passed_meconium_24h, urination_24h, heart_screening, metabolic_screening, hearing_screening,
            mother_vaccinations, family_vaccinations, maternity_discharge_date, discharge_weight_g,
            illnesses_after_birth, evolution_since_maternity, updated_at
        ) VALUES (
            ?,?,?,?,?, ?,?,?,?,?,
            ?,?,?,?,
            ?,?,?,?,?,
            ?,?,?,?,?,
            ?, CURRENT_TIMESTAMP
        )
        ON CONFLICT(patient_id) DO UPDATE SET
            pregnancy_risk=excluded.pregnancy_risk,
            birth_mode=excluded.birth_mode,
            birth_term_weeks=excluded.birth_term_weeks,
            resuscitation=excluded.resuscitation,
            nicu_stay=excluded.nicu_stay,
            infection_risk=excluded.infection_risk,
            birth_weight_g=excluded.birth_weight_g,
            birth_length_cm=excluded.birth_length_cm,
            birth_head_circumference_cm=excluded.birth_head_circumference_cm,
            maternity_stay_events=excluded.maternity_stay_events,
            maternity_vaccinations=excluded.maternity_vaccinations,
            vitamin_k=excluded.vitamin_k,
            feeding_in_maternity=excluded.feeding_in_maternity,
            passed_meconium_24h=excluded.passed_meconium_24h,
            urination_24h=excluded.urination_24h,
            heart_screening=excluded.heart_screening,
            metabolic_screening=excluded.metabolic_screening,
            hearing_screening=excluded.hearing_screening,
            mother_vaccinations=excluded.mother_vaccinations,
            family_vaccinations=excluded.family_vaccinations,
            maternity_discharge_date=excluded.maternity_discharge_date,
            discharge_weight_g=excluded.discharge_weight_g,
            illnesses_after_birth=excluded.illnesses_after_birth,
            evolution_since_maternity=excluded.evolution_since_maternity,
            updated_at=CURRENT_TIMESTAMP;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError(db, prefix: "upsertPerinatal.prepare")
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        func bString(_ s: String?) { bindText(stmt, idx, s); idx += 1 }
        func bInt(_ v: Int?) { bindInt(stmt, idx, v); idx += 1 }
        func bDouble(_ v: Double?) { bindDouble(stmt, idx, v); idx += 1 }
        func bBool(_ b: Bool?) { bindInt(stmt, idx, b.map { $0 ? 1 : 0 }); idx += 1 }

        // 1. patient_id
        bInt(ph.patientID)

        // 2-5
        bString(ph.pregnancyRisk)
        bString(ph.birthMode)
        bInt(ph.birthTermWeeks)
        bString(ph.resuscitation)

        // 6-10
        bBool(ph.nicuStay)
        bString(ph.infectionRisk)
        bInt(ph.birthWeightG)
        bDouble(ph.birthLengthCM)
        bDouble(ph.birthHeadCircumferenceCM)

        // 11-14
        bString(ph.maternityStayEvents)
        bString(ph.maternityVaccinations)
        bBool(ph.vitaminK)
        bString(ph.feedingInMaternity)

        // 15-19
        bBool(ph.passedMeconium24h)
        bBool(ph.urination24h)
        bString(ph.heartScreening)
        bString(ph.metabolicScreening)
        bString(ph.hearingScreening)

        // 20-24
        bString(ph.motherVaccinations)
        bString(ph.familyVaccinations)
        bString(ph.maternityDischargeDate)
        bInt(ph.dischargeWeightG)
        bString(ph.illnessesAfterBirth)

        // 25 (evolution_since_maternity)
        bString(ph.evolutionSinceMaternity)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqliteError(db, prefix: "upsertPerinatal.step")
        }
    }

    // MARK: - SQLite helpers

    private func openDB(_ db: inout OpaquePointer?) throws {
        let path = dbURL.path
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw sqliteError(db, prefix: "open")
        }
    }

    private func sqliteError(_ db: OpaquePointer?, prefix: String) -> NSError {
        let code = sqlite3_errcode(db)
        let msg = String(cString: sqlite3_errmsg(db))
        return NSError(domain: "PerinatalStore", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(prefix): \(msg)"])
    }
}

// MARK: - Column readers

private func stringCol(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
    if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return nil }
    guard let c = sqlite3_column_text(stmt, idx) else { return nil }
    return String(cString: c)
}

private func intCol(_ stmt: OpaquePointer?, _ idx: Int32) -> Int? {
    if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return nil }
    return Int(sqlite3_column_int64(stmt, idx))
}

private func doubleCol(_ stmt: OpaquePointer?, _ idx: Int32) -> Double? {
    if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return nil }
    return sqlite3_column_double(stmt, idx)
}

private func boolCol(_ stmt: OpaquePointer?, _ idx: Int32) -> Bool? {
    if let v = intCol(stmt, idx) { return v != 0 }
    return nil
}

// Add definition for SQLITE_TRANSIENT to ensure sqlite3_bind_text compiles safely
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Binders

private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
    if let v = value {
        sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
    } else {
        sqlite3_bind_null(stmt, idx)
    }
}

private func bindInt(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int?) {
    if let v = value {
        sqlite3_bind_int64(stmt, idx, sqlite3_int64(v))
    } else {
        sqlite3_bind_null(stmt, idx)
    }
}

private func bindDouble(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Double?) {
    if let v = value {
        sqlite3_bind_double(stmt, idx, v)
    } else {
        sqlite3_bind_null(stmt, idx)
    }
}

// MARK: - Legacy convenience (resolver-based)
// Allows legacy call-sites to omit dbURL safely.

public extension PerinatalStore {
    /// AppState should set this to: `{ [weak app] in app?.currentDBURL }`
    static var dbURLResolver: (() -> URL?)?

    // Resolver-backed statics so call-sites can just call `PerinatalStore.fetch(for:)`
    static func fetch(for patientID: Int) throws -> PerinatalHistory? {
        guard let url = PerinatalStore.dbURLResolver?() else {
            throw NSError(domain: "PerinatalStore", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "No dbURL provided and PerinatalStore.dbURLResolver is not set"])
        }
        return try PerinatalStore.fetch(dbURL: url, for: patientID)
    }

    static func upsert(for patientID: Int, history: PerinatalHistory) throws {
        guard let url = PerinatalStore.dbURLResolver?() else {
            throw NSError(domain: "PerinatalStore", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "No dbURL provided and PerinatalStore.dbURLResolver is not set"])
        }
        try PerinatalStore.upsert(dbURL: url, for: patientID, history: history)
    }
}
