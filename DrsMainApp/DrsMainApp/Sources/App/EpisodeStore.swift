
//
//  EpisodeStore.swift
//  DrsMainApp
//
//  Created by yunastic on 11/14/25.
//

import Foundation
import SQLite3

/// Lightweight header row for listing episodes.
public struct EpisodeHeader: Identifiable, Equatable {
    public let id: Int64
    public let createdAtISO: String
}

/// Full episode record (matches DB columns we read).
public struct Episode: Identifiable, Equatable {
    public let id: Int64
    public let patientID: Int64
    public let userID: Int64?
    public let createdAtISO: String?

    // Core
    public var mainComplaint: String?
    public var hpi: String?
    public var duration: String?

    // Structured HPI
    public var appearance: String?
    public var feeding: String?
    public var breathing: String?
    public var urination: String?
    public var pain: String?
    public var stools: String?
    public var context: String?

    // Physical Exam
    public var generalAppearance: String?
    public var hydration: String?
    public var color: String?
    public var skin: String?
    public var ent: String?
    public var rightEar: String?
    public var leftEar: String?
    public var rightEye: String?
    public var leftEye: String?
    public var heart: String?
    public var lungs: String?
    public var abdomen: String?
    public var peristalsis: String?
    public var genitalia: String?
    public var neurological: String?
    public var musculoskeletal: String?
    public var lymphNodes: String?

    // Plan
    public var problemListing: String?
    public var complementaryInvestigations: String?
    public var diagnosis: String?
    public var icd10: String?
    public var medications: String?
    public var anticipatoryGuidance: String?
    public var comments: String?
}

/// Payload for insert/update (no ids).
public struct EpisodePayload: Equatable {
    // Core
    public var mainComplaint: String? = nil
    public var hpi: String? = nil
    public var duration: String? = nil

    // Structured HPI
    public var appearance: String? = nil
    public var feeding: String? = nil
    public var breathing: String? = nil
    public var urination: String? = nil
    public var pain: String? = nil
    public var stools: String? = nil
    public var context: String? = nil

    // Physical Exam
    public var generalAppearance: String? = nil
    public var hydration: String? = nil
    public var color: String? = nil
    public var skin: String? = nil
    public var ent: String? = nil
    public var rightEar: String? = nil
    public var leftEar: String? = nil
    public var rightEye: String? = nil
    public var leftEye: String? = nil
    public var heart: String? = nil
    public var lungs: String? = nil
    public var abdomen: String? = nil
    public var peristalsis: String? = nil
    public var genitalia: String? = nil
    public var neurological: String? = nil
    public var musculoskeletal: String? = nil
    public var lymphNodes: String? = nil

    // Plan
    public var problemListing: String? = nil
    public var complementaryInvestigations: String? = nil
    public var diagnosis: String? = nil
    public var icd10: String? = nil
    public var medications: String? = nil
    public var anticipatoryGuidance: String? = nil
    public var comments: String? = nil
}

/// Data access for the `episodes` table. Mirrors the schema you shared.
/// NOTE: This layer does NOT create tables; it assumes the schema exists.
public struct EpisodeStore {

    // MARK: - Public API

    /// Return most-recent-first list of episode headers for a patient.
    public func fetchList(dbURL: URL, for patientID: Int64) throws -> [EpisodeHeader] {
        let db = try openDB(dbURL)
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id,
               COALESCE(created_at, '') as created_at
        FROM episodes
        WHERE patient_id = ?
        ORDER BY datetime(COALESCE(created_at, '1970-01-01T00:00:00')) DESC, id DESC;
        """

        var stmt: OpaquePointer?
        try prepare(db, sql, &stmt)
        defer { sqlite3_finalize(stmt) }

        try bindInt64(stmt, index: 1, value: patientID)

        var items: [EpisodeHeader] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let created = columnText(stmt, 1) ?? ""
            items.append(EpisodeHeader(id: id, createdAtISO: created))
        }
        return items
    }

    /// Fetch a full episode by id.
    public func fetch(dbURL: URL, id: Int64) throws -> Episode? {
        let db = try openDB(dbURL)
        defer { sqlite3_close(db) }

        let sql = """
        SELECT
            id, patient_id, user_id, created_at,
            main_complaint, hpi, duration,
            appearance, feeding, breathing, urination, pain, stools, context,
            general_appearance, hydration, color, skin,
            ent, right_ear, left_ear, right_eye, left_eye,
            heart, lungs, abdomen, peristalsis, genitalia,
            neurological, musculoskeletal, lymph_nodes,
            problem_listing, complementary_investigations,
            diagnosis, icd10, medications, anticipatory_guidance,
            comments
        FROM episodes
        WHERE id = ?
        LIMIT 1;
        """

        var stmt: OpaquePointer?
        try prepare(db, sql, &stmt)
        defer { sqlite3_finalize(stmt) }

        try bindInt64(stmt, index: 1, value: id)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        return Episode(
            id: sqlite3_column_int64(stmt, 0),
            patientID: sqlite3_column_int64(stmt, 1),
            userID: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 2),
            createdAtISO: columnText(stmt, 3),

            // Core
            mainComplaint: columnText(stmt, 4),
            hpi: columnText(stmt, 5),
            duration: columnText(stmt, 6),

            // Structured HPI
            appearance: columnText(stmt, 7),
            feeding: columnText(stmt, 8),
            breathing: columnText(stmt, 9),
            urination: columnText(stmt, 10),
            pain: columnText(stmt, 11),
            stools: columnText(stmt, 12),
            context: columnText(stmt, 13),

            // Physical Exam
            generalAppearance: columnText(stmt, 14),
            hydration: columnText(stmt, 15),
            color: columnText(stmt, 16),
            skin: columnText(stmt, 17),
            ent: columnText(stmt, 18),
            rightEar: columnText(stmt, 19),
            leftEar: columnText(stmt, 20),
            rightEye: columnText(stmt, 21),
            leftEye: columnText(stmt, 22),
            heart: columnText(stmt, 23),
            lungs: columnText(stmt, 24),
            abdomen: columnText(stmt, 25),
            peristalsis: columnText(stmt, 26),
            genitalia: columnText(stmt, 27),
            neurological: columnText(stmt, 28),
            musculoskeletal: columnText(stmt, 29),
            lymphNodes: columnText(stmt, 30),

            // Plan
            problemListing: columnText(stmt, 31),
            complementaryInvestigations: columnText(stmt, 32),
            diagnosis: columnText(stmt, 33),
            icd10: columnText(stmt, 34),
            medications: columnText(stmt, 35),
            anticipatoryGuidance: columnText(stmt, 36),
            comments: columnText(stmt, 37)
        )
    }

    /// Insert a new episode. Returns the new row id.
    /// `created_at` is left to the DB default.
    public func insert(dbURL: URL,
                       for patientID: Int64,
                       userID: Int64,
                       payload: EpisodePayload) throws -> Int64 {
        let db = try openDB(dbURL)
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO episodes (
            patient_id, user_id,
            main_complaint, hpi, duration,
            appearance, feeding, breathing, urination, pain, stools, context,
            general_appearance, hydration, color, skin,
            ent, right_ear, left_ear, right_eye, left_eye,
            heart, lungs, abdomen, peristalsis, genitalia,
            neurological, musculoskeletal, lymph_nodes,
            problem_listing, complementary_investigations,
            diagnosis, icd10, medications, anticipatory_guidance,
            comments
        )
        VALUES (
            ?, ?,
            ?, ?, ?,
            ?, ?, ?, ?, ?, ?, ?,
            ?, ?, ?, ?,
            ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?,
            ?, ?, ?,
            ?, ?,
            ?, ?, ?, ?,
            ?
        );
        """

        var stmt: OpaquePointer?
        try prepare(db, sql, &stmt)
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        try bindInt64(stmt, index: idx, value: patientID); idx += 1
        try bindInt64(stmt, index: idx, value: userID); idx += 1

        // Core
        bindText(stmt, index: idx, value: payload.mainComplaint); idx += 1
        bindText(stmt, index: idx, value: payload.hpi); idx += 1
        bindText(stmt, index: idx, value: payload.duration); idx += 1

        // Structured HPI
        bindText(stmt, index: idx, value: payload.appearance); idx += 1
        bindText(stmt, index: idx, value: payload.feeding); idx += 1
        bindText(stmt, index: idx, value: payload.breathing); idx += 1
        bindText(stmt, index: idx, value: payload.urination); idx += 1
        bindText(stmt, index: idx, value: payload.pain); idx += 1
        bindText(stmt, index: idx, value: payload.stools); idx += 1
        bindText(stmt, index: idx, value: payload.context); idx += 1

        // Physical Exam
        bindText(stmt, index: idx, value: payload.generalAppearance); idx += 1
        bindText(stmt, index: idx, value: payload.hydration); idx += 1
        bindText(stmt, index: idx, value: payload.color); idx += 1
        bindText(stmt, index: idx, value: payload.skin); idx += 1

        bindText(stmt, index: idx, value: payload.ent); idx += 1
        bindText(stmt, index: idx, value: payload.rightEar); idx += 1
        bindText(stmt, index: idx, value: payload.leftEar); idx += 1
        bindText(stmt, index: idx, value: payload.rightEye); idx += 1
        bindText(stmt, index: idx, value: payload.leftEye); idx += 1

        bindText(stmt, index: idx, value: payload.heart); idx += 1
        bindText(stmt, index: idx, value: payload.lungs); idx += 1
        bindText(stmt, index: idx, value: payload.abdomen); idx += 1
        bindText(stmt, index: idx, value: payload.peristalsis); idx += 1
        bindText(stmt, index: idx, value: payload.genitalia); idx += 1

        bindText(stmt, index: idx, value: payload.neurological); idx += 1
        bindText(stmt, index: idx, value: payload.musculoskeletal); idx += 1
        bindText(stmt, index: idx, value: payload.lymphNodes); idx += 1

        // Plan
        bindText(stmt, index: idx, value: payload.problemListing); idx += 1
        bindText(stmt, index: idx, value: payload.complementaryInvestigations); idx += 1
        bindText(stmt, index: idx, value: payload.diagnosis); idx += 1
        bindText(stmt, index: idx, value: payload.icd10); idx += 1
        bindText(stmt, index: idx, value: payload.medications); idx += 1
        bindText(stmt, index: idx, value: payload.anticipatoryGuidance); idx += 1
        bindText(stmt, index: idx, value: payload.comments); idx += 1

        try stepDone(stmt)

        let rowID = sqlite3_last_insert_rowid(db)
        return rowID
    }

    /// Update a row by id.
    public func update(dbURL: URL, id: Int64, payload: EpisodePayload) throws -> Bool {
        let db = try openDB(dbURL)
        defer { sqlite3_close(db) }

        let sql = """
        UPDATE episodes SET
            main_complaint = ?,
            hpi = ?,
            duration = ?,
            appearance = ?,
            feeding = ?,
            breathing = ?,
            urination = ?,
            pain = ?,
            stools = ?,
            context = ?,
            general_appearance = ?,
            hydration = ?,
            color = ?,
            skin = ?,
            ent = ?,
            right_ear = ?,
            left_ear = ?,
            right_eye = ?,
            left_eye = ?,
            heart = ?,
            lungs = ?,
            abdomen = ?,
            peristalsis = ?,
            genitalia = ?,
            neurological = ?,
            musculoskeletal = ?,
            lymph_nodes = ?,
            problem_listing = ?,
            complementary_investigations = ?,
            diagnosis = ?,
            icd10 = ?,
            medications = ?,
            anticipatory_guidance = ?,
            comments = ?
        WHERE id = ?;
        """

        var stmt: OpaquePointer?
        try prepare(db, sql, &stmt)
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1

        // Core
        bindText(stmt, index: idx, value: payload.mainComplaint); idx += 1
        bindText(stmt, index: idx, value: payload.hpi); idx += 1
        bindText(stmt, index: idx, value: payload.duration); idx += 1

        // Structured HPI
        bindText(stmt, index: idx, value: payload.appearance); idx += 1
        bindText(stmt, index: idx, value: payload.feeding); idx += 1
        bindText(stmt, index: idx, value: payload.breathing); idx += 1
        bindText(stmt, index: idx, value: payload.urination); idx += 1
        bindText(stmt, index: idx, value: payload.pain); idx += 1
        bindText(stmt, index: idx, value: payload.stools); idx += 1
        bindText(stmt, index: idx, value: payload.context); idx += 1

        // Physical Exam
        bindText(stmt, index: idx, value: payload.generalAppearance); idx += 1
        bindText(stmt, index: idx, value: payload.hydration); idx += 1
        bindText(stmt, index: idx, value: payload.color); idx += 1
        bindText(stmt, index: idx, value: payload.skin); idx += 1
        bindText(stmt, index: idx, value: payload.ent); idx += 1
        bindText(stmt, index: idx, value: payload.rightEar); idx += 1
        bindText(stmt, index: idx, value: payload.leftEar); idx += 1
        bindText(stmt, index: idx, value: payload.rightEye); idx += 1
        bindText(stmt, index: idx, value: payload.leftEye); idx += 1
        bindText(stmt, index: idx, value: payload.heart); idx += 1
        bindText(stmt, index: idx, value: payload.lungs); idx += 1
        bindText(stmt, index: idx, value: payload.abdomen); idx += 1
        bindText(stmt, index: idx, value: payload.peristalsis); idx += 1
        bindText(stmt, index: idx, value: payload.genitalia); idx += 1
        bindText(stmt, index: idx, value: payload.neurological); idx += 1
        bindText(stmt, index: idx, value: payload.musculoskeletal); idx += 1
        bindText(stmt, index: idx, value: payload.lymphNodes); idx += 1

        // Plan
        bindText(stmt, index: idx, value: payload.problemListing); idx += 1
        bindText(stmt, index: idx, value: payload.complementaryInvestigations); idx += 1
        bindText(stmt, index: idx, value: payload.diagnosis); idx += 1
        bindText(stmt, index: idx, value: payload.icd10); idx += 1
        bindText(stmt, index: idx, value: payload.medications); idx += 1
        bindText(stmt, index: idx, value: payload.anticipatoryGuidance); idx += 1
        bindText(stmt, index: idx, value: payload.comments); idx += 1

        try bindInt64(stmt, index: idx, value: id)

        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            throw sqliteError(db, context: "episodes update step rc=\(rc)")
        }
        return sqlite3_changes(db) > 0
    }

    /// (Optional) Edit window logic hook — currently always editable.
    public func canEdit(dbURL: URL, id: Int64) -> Bool {
        // You can later wire a time-based restriction here.
        return true
    }

    // MARK: - SQLite helpers

    private func openDB(_ url: URL) throws -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        if rc != SQLITE_OK {
            throw sqliteError(db, context: "open \(url.path)")
        }
        return db
    }

    private func prepare(_ db: OpaquePointer?, _ sql: String, _ stmt: inout OpaquePointer?) throws {
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            throw sqliteError(db, context: "prepare: \(sql)")
        }
    }

    private func stepDone(_ stmt: OpaquePointer?) throws {
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            throw sqliteError(nil, context: "step rc=\(rc)")
        }
    }

    private func bindInt64(_ stmt: OpaquePointer?, index: Int32, value: Int64) throws {
        let rc = sqlite3_bind_int64(stmt, index, value)
        if rc != SQLITE_OK {
            throw sqliteError(nil, context: "bind int64 @\(index)")
        }
    }

    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String?) {
        if let value = value, !value.isEmpty {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cstr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cstr)
    }

    private func sqliteError(_ db: OpaquePointer?, context: String) -> NSError {
        let code = sqlite3_errcode(db)
        if let cmsg = sqlite3_errmsg(db) {
            let msg = String(cString: cmsg)
            return NSError(domain: "EpisodeStore", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(context): \(msg)"])
        }
        return NSError(domain: "EpisodeStore", code: Int(code), userInfo: [NSLocalizedDescriptionKey: context])
    }
}

// Required by SQLite C-API for transient text bindings
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
