//
//  WellVisitStore.swift
//  DrsMainApp
//
//  Created by yunastic on 11/20/25.
//

import Foundation
import SQLite3

/// Lightweight header row for listing well visits.
public struct WellVisitHeader: Identifiable, Equatable {
    public let id: Int64
    public let visitDateISO: String
    public let visitType: String
    public let ageDays: Int?
    public let problemListing: String?
}

/// Full (but still simplified) well visit record.
/// We start with the core columns we know we need for the macOS app UI.
/// This can be extended later as more fields are wired in.
public struct WellVisit: Identifiable, Equatable {
    public let id: Int64
    public let patientID: Int64
    public let userID: Int64?

    public var visitDateISO: String
    public var visitType: String
    public var ageDays: Int?

    // Early newborn / stool / feeding bits
    public var poopStatus: String?
    public var poopComment: String?
    public var vitaminD: Int?
    public var milkTypes: String?
    public var expressedBM: Int?   // 0/1 or nil

    // Narrative / summary and comments
    public var problemListing: String?
    public var parentConcerns: String?
    public var feedingComment: String?
    public var sleepIssueText: String?
    public var conclusions: String?
    public var anticipatoryGuidance: String?
    public var nextVisitDateISO: String?
    public var comments: String?
    public var labText: String?
    public var dairyAmountText: String?
    public var vitaminDGiven: Int?
}

/// Payload used by the UI for insert / update.
/// `patientID` and `userID` are supplied separately to `insert(...)` so
/// this stays focused on visit content.
public struct WellVisitPayload: Equatable {
    public var visitDateISO: String = ""      // ISO8601 date (yyyy-MM-dd)
    public var visitType: String = ""         // e.g. "one_month", "six_month", "episode" (if ever reused)
    public var ageDays: Int? = nil

    // Stool / early feeding bits
    public var poopStatus: String? = nil
    public var poopComment: String? = nil
    public var vitaminD: Int? = nil
    public var milkTypes: String? = nil
    public var expressedBM: Int? = nil       // 0/1

    // Narrative / summary and comments
    public var problemListing: String? = nil
    public var parentConcerns: String? = nil
    public var feedingComment: String? = nil
    public var sleepIssueText: String? = nil
    public var conclusions: String? = nil
    public var anticipatoryGuidance: String? = nil
    public var nextVisitDateISO: String? = nil
    public var comments: String? = nil
    public var labText: String? = nil
    public var dairyAmountText: String? = nil
    public var vitaminDGiven: Int? = nil
}

/// Addendum record attached to a well visit.
public struct WellVisitAddendum: Identifiable, Equatable {
    public let id: Int64
    public let wellVisitID: Int64
    public let userID: Int64?
    public let createdAtISO: String?
    public let updatedAtISO: String?
    public var text: String
}

/// Data access layer for the `well_visits` table.
/// NOTE: This layer assumes the table already exists in db.sqlite.
public struct WellVisitStore {

    public init() {}

    // MARK: - Addenda (visit_addenda)

    /// Fetch addenda for a well visit, oldest-first.
    public func fetchAddendaForWellVisit(dbURL: URL, wellVisitID: Int64) throws -> [WellVisitAddendum] {
        let db = try openDB(dbURL)
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id, well_visit_id, user_id, created_at, updated_at, addendum_text
        FROM visit_addenda
        WHERE well_visit_id = ?
        ORDER BY datetime(COALESCE(created_at, '1970-01-01T00:00:00')) ASC, id ASC;
        """

        var stmt: OpaquePointer?
        try prepare(db, sql, &stmt)
        defer { sqlite3_finalize(stmt) }

        try bindInt64(stmt, index: 1, value: wellVisitID)

        var items: [WellVisitAddendum] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let wvID = sqlite3_column_int64(stmt, 1)
            let uID  = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 2)
            let created = columnText(stmt, 3)
            let updated = columnText(stmt, 4)
            let text = columnText(stmt, 5) ?? ""

            items.append(
                WellVisitAddendum(
                    id: id,
                    wellVisitID: wvID,
                    userID: uID,
                    createdAtISO: created,
                    updatedAtISO: updated,
                    text: text
                )
            )
        }
        return items
    }

    /// Insert a new addendum for a well visit. Returns new addendum row id.
    public func insertAddendumForWellVisit(dbURL: URL,
                                          wellVisitID: Int64,
                                          userID: Int64? = nil,
                                          text: String) throws -> Int64 {
        let db = try openDB(dbURL)
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO visit_addenda (episode_id, well_visit_id, user_id, addendum_text)
        VALUES (NULL, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        try prepare(db, sql, &stmt)
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        try bindInt64(stmt, index: idx, value: wellVisitID); idx += 1

        if let uid = userID {
            try bindInt64(stmt, index: idx, value: uid)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
        idx += 1

        bindText(stmt, index: idx, value: text)

        try stepDone(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    /// Update an existing addendum's text and updated_at.
    public func updateWellVisitAddendum(dbURL: URL, addendumID: Int64, newText: String) throws -> Bool {
        let db = try openDB(dbURL)
        defer { sqlite3_close(db) }

        let sql = """
        UPDATE visit_addenda
        SET addendum_text = ?,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = ?;
        """

        var stmt: OpaquePointer?
        try prepare(db, sql, &stmt)
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: newText)
        try bindInt64(stmt, index: 2, value: addendumID)

        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            throw sqliteError(db, key: "wellVisitStore.error.addendaUpdateStep", rc)
        }
        return sqlite3_changes(db) > 0
    }

    /// Delete an addendum.
    public func deleteWellVisitAddendum(dbURL: URL, addendumID: Int64) throws -> Bool {
        let db = try openDB(dbURL)
        defer { sqlite3_close(db) }

        let sql = "DELETE FROM visit_addenda WHERE id = ?;"

        var stmt: OpaquePointer?
        try prepare(db, sql, &stmt)
        defer { sqlite3_finalize(stmt) }

        try bindInt64(stmt, index: 1, value: addendumID)

        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            throw sqliteError(db, key: "wellVisitStore.error.addendaDeleteStep", rc)
        }
        return sqlite3_changes(db) > 0
    }

    // MARK: - Public API

    /// Most-recent-first list of well visits for a patient.
    /// Mirrors the Python `list_well_visits` behaviour using visit_date
    /// and a snippet of the problem listing.
    public func fetchList(dbURL: URL, for patientID: Int64) throws -> [WellVisitHeader] {
        let db = try openDB(dbURL)
        defer { sqlite3_close(db) }

        let sql = """
        SELECT
            id,
            visit_date,
            visit_type,
            age_days,
            problem_listing
        FROM well_visits
        WHERE patient_id = ?
        ORDER BY date(visit_date) DESC, id DESC;
        """

        var stmt: OpaquePointer?
        try prepare(db, sql, &stmt)
        defer { sqlite3_finalize(stmt) }

        try bindInt64(stmt, index: 1, value: patientID)

        var rows: [WellVisitHeader] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let dateISO = columnText(stmt, 1) ?? ""
            let vtype = columnText(stmt, 2) ?? ""
            let age = columnIntOptional(stmt, 3)
            let pl = columnText(stmt, 4)

            rows.append(WellVisitHeader(
                id: id,
                visitDateISO: dateISO,
                visitType: vtype,
                ageDays: age,
                problemListing: pl
            ))
        }
        return rows
    }

    /// Fetch a single well visit by id.
    /// For now we only map a subset of columns that we know are in the schema.
    public func fetch(dbURL: URL, id: Int64) throws -> WellVisit? {
        let db = try openDB(dbURL)
        defer { sqlite3_close(db) }

        let sql = """
        SELECT
            id,
            patient_id,
            user_id,
            visit_date,
            visit_type,
            age_days,
            poop_status,
            poop_comment,
            vitamin_d,
            milk_types,
            expressed_bm,
            problem_listing,
            parent_concerns,
            feeding_comment,
            sleep_issue_text,
            conclusions,
            anticipatory_guidance,
            next_visit_date,
            comments,
            lab_text,
            dairy_amount_text,
            vitamin_d_given
        FROM well_visits
        WHERE id = ?
        LIMIT 1;
        """

        var stmt: OpaquePointer?
        try prepare(db, sql, &stmt)
        defer { sqlite3_finalize(stmt) }

        try bindInt64(stmt, index: 1, value: id)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let rowID = sqlite3_column_int64(stmt, 0)
        let patientID = sqlite3_column_int64(stmt, 1)
        let userID: Int64? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
            ? nil
            : sqlite3_column_int64(stmt, 2)

        let visitDateISO = columnText(stmt, 3) ?? ""
        let visitType = columnText(stmt, 4) ?? ""
        let ageDays = columnIntOptional(stmt, 5)

        let poopStatus = columnText(stmt, 6)
        let poopComment = columnText(stmt, 7)
        let vitaminD = columnIntOptional(stmt, 8)
        let milkTypes = columnText(stmt, 9)
        let expressedBM = columnIntOptional(stmt, 10)

        let problemListing = columnText(stmt, 11)
        let parentConcerns = columnText(stmt, 12)
        let feedingComment = columnText(stmt, 13)
        let sleepIssueText = columnText(stmt, 14)
        let conclusions = columnText(stmt, 15)
        let anticipatoryGuidance = columnText(stmt, 16)
        let nextVisitDate = columnText(stmt, 17)
        let comments = columnText(stmt, 18)
        let labText = columnText(stmt, 19)
        let dairyAmountText = columnText(stmt, 20)
        let vitaminDGiven = columnIntOptional(stmt, 21)

        return WellVisit(
            id: rowID,
            patientID: patientID,
            userID: userID,
            visitDateISO: visitDateISO,
            visitType: visitType,
            ageDays: ageDays,
            poopStatus: poopStatus,
            poopComment: poopComment,
            vitaminD: vitaminD,
            milkTypes: milkTypes,
            expressedBM: expressedBM,
            problemListing: problemListing,
            parentConcerns: parentConcerns,
            feedingComment: feedingComment,
            sleepIssueText: sleepIssueText,
            conclusions: conclusions,
            anticipatoryGuidance: anticipatoryGuidance,
            nextVisitDateISO: nextVisitDate,
            comments: comments,
            labText: labText,
            dairyAmountText: dairyAmountText,
            vitaminDGiven: vitaminDGiven
        )
    }

    /// Insert a new well visit. Returns the new row id.
    /// `created_at` / other columns are left to DB defaults / NULL.
    public func insert(
        dbURL: URL,
        for patientID: Int64,
        userID: Int64?,
        payload: WellVisitPayload
    ) throws -> Int64 {
        let db = try openDB(dbURL)
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO well_visits (
            patient_id,
            user_id,
            visit_date,
            visit_type,
            age_days,
            poop_status,
            poop_comment,
            vitamin_d,
            milk_types,
            expressed_bm,
            problem_listing,
            parent_concerns,
            feeding_comment,
            sleep_issue_text,
            conclusions,
            anticipatory_guidance,
            next_visit_date,
            comments,
            lab_text,
            dairy_amount_text,
            vitamin_d_given
        )
        VALUES ( ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? );
        """

        var stmt: OpaquePointer?
        try prepare(db, sql, &stmt)
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        try bindInt64(stmt, index: idx, value: patientID); idx += 1

        if let uid = userID {
            try bindInt64(stmt, index: idx, value: uid)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
        idx += 1

        // visit_date + type (non-optional in payload)
        bindText(stmt, index: idx, value: payload.visitDateISO); idx += 1
        bindText(stmt, index: idx, value: payload.visitType); idx += 1

        // age_days
        bindOptionalInt64(stmt, index: idx, value: payload.ageDays); idx += 1

        // stool / feeding bits
        bindText(stmt, index: idx, value: payload.poopStatus); idx += 1
        bindText(stmt, index: idx, value: payload.poopComment); idx += 1
        bindOptionalInt64(stmt, index: idx, value: payload.vitaminD); idx += 1
        bindText(stmt, index: idx, value: payload.milkTypes); idx += 1
        bindOptionalInt64(stmt, index: idx, value: payload.expressedBM); idx += 1

        // problem listing + narrative fields
        bindText(stmt, index: idx, value: payload.problemListing); idx += 1
        bindText(stmt, index: idx, value: payload.parentConcerns); idx += 1
        bindText(stmt, index: idx, value: payload.feedingComment); idx += 1
        bindText(stmt, index: idx, value: payload.sleepIssueText); idx += 1
        bindText(stmt, index: idx, value: payload.conclusions); idx += 1
        bindText(stmt, index: idx, value: payload.anticipatoryGuidance); idx += 1
        bindText(stmt, index: idx, value: payload.nextVisitDateISO); idx += 1
        bindText(stmt, index: idx, value: payload.comments); idx += 1
        bindText(stmt, index: idx, value: payload.labText); idx += 1
        bindText(stmt, index: idx, value: payload.dairyAmountText); idx += 1
        bindOptionalInt64(stmt, index: idx, value: payload.vitaminDGiven); idx += 1

        try stepDone(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    /// Update selected fields of a well visit.
    /// We intentionally do not change patient_id / user_id here.
    public func update(
        dbURL: URL,
        id: Int64,
        payload: WellVisitPayload
    ) throws -> Bool {
        let db = try openDB(dbURL)
        defer { sqlite3_close(db) }

        let sql = """
        UPDATE well_visits SET
            visit_date = ?,
            visit_type = ?,
            age_days = ?,
            poop_status = ?,
            poop_comment = ?,
            vitamin_d = ?,
            milk_types = ?,
            expressed_bm = ?,
            problem_listing = ?,
            parent_concerns = ?,
            feeding_comment = ?,
            sleep_issue_text = ?,
            conclusions = ?,
            anticipatory_guidance = ?,
            next_visit_date = ?,
            comments = ?,
            lab_text = ?,
            dairy_amount_text = ?,
            vitamin_d_given = ?
        WHERE id = ?;
        """

        var stmt: OpaquePointer?
        try prepare(db, sql, &stmt)
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1

        bindText(stmt, index: idx, value: payload.visitDateISO); idx += 1
        bindText(stmt, index: idx, value: payload.visitType); idx += 1
        bindOptionalInt64(stmt, index: idx, value: payload.ageDays); idx += 1

        bindText(stmt, index: idx, value: payload.poopStatus); idx += 1
        bindText(stmt, index: idx, value: payload.poopComment); idx += 1
        bindOptionalInt64(stmt, index: idx, value: payload.vitaminD); idx += 1
        bindText(stmt, index: idx, value: payload.milkTypes); idx += 1
        bindOptionalInt64(stmt, index: idx, value: payload.expressedBM); idx += 1

        bindText(stmt, index: idx, value: payload.problemListing); idx += 1
        bindText(stmt, index: idx, value: payload.parentConcerns); idx += 1
        bindText(stmt, index: idx, value: payload.feedingComment); idx += 1
        bindText(stmt, index: idx, value: payload.sleepIssueText); idx += 1
        bindText(stmt, index: idx, value: payload.conclusions); idx += 1
        bindText(stmt, index: idx, value: payload.anticipatoryGuidance); idx += 1
        bindText(stmt, index: idx, value: payload.nextVisitDateISO); idx += 1
        bindText(stmt, index: idx, value: payload.comments); idx += 1
        bindText(stmt, index: idx, value: payload.labText); idx += 1
        bindText(stmt, index: idx, value: payload.dairyAmountText); idx += 1
        bindOptionalInt64(stmt, index: idx, value: payload.vitaminDGiven); idx += 1

        try bindInt64(stmt, index: idx, value: id)

        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            throw sqliteError(db, key: "wellVisitStore.error.updateStep", rc)
        }
        return sqlite3_changes(db) > 0
    }

    // MARK: - SQLite helpers

    private func openDB(_ url: URL) throws -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        if rc != SQLITE_OK {
            throw sqliteError(db, key: "wellVisitStore.error.open", url.path)
        }

        // Avoid transient "database is locked" errors during brief concurrent access.
        // This makes SQLite wait a short time for locks to clear instead of failing immediately.
        if let db {
            sqlite3_busy_timeout(db, 800) // milliseconds
        }

        return db
    }

    private func prepare(_ db: OpaquePointer?, _ sql: String, _ stmt: inout OpaquePointer?) throws {
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            throw sqliteError(db, key: "wellVisitStore.error.prepare", sql)
        }
    }

    private func stepDone(_ stmt: OpaquePointer?) throws {
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            throw sqliteError(nil, key: "wellVisitStore.error.step", rc)
        }
    }

    private func bindInt64(_ stmt: OpaquePointer?, index: Int32, value: Int64) throws {
        let rc = sqlite3_bind_int64(stmt, index, value)
        if rc != SQLITE_OK {
            throw sqliteError(nil, key: "wellVisitStore.error.bindInt64", Int(index))
        }
    }

    private func bindOptionalInt64(_ stmt: OpaquePointer?, index: Int32, value: Int?) {
        if let v = value {
            sqlite3_bind_int64(stmt, index, Int64(v))
        } else {
            sqlite3_bind_null(stmt, index)
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

    private func columnIntOptional(_ stmt: OpaquePointer?, _ index: Int32) -> Int? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, index))
    }

    private func sqliteError(_ db: OpaquePointer?, key: String, _ args: CVarArg...) -> NSError {
        // Be defensive: `db` may be nil in some call sites (e.g. stepDone)
        let code: Int32 = (db != nil) ? sqlite3_errcode(db) : 0

        let base = String(format: NSLocalizedString(key, comment: ""), arguments: args)

        if let db = db, let cmsg = sqlite3_errmsg(db) {
            let sqliteMsg = String(cString: cmsg)
            let full = String(
                format: NSLocalizedString("wellVisitStore.error.withSQLite", comment: ""),
                base,
                sqliteMsg
            )
            return NSError(
                domain: "WellVisitStore",
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: full]
            )
        }

        return NSError(
            domain: "WellVisitStore",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: base]
        )
    }
}

// Required by SQLite C-API for transient text bindings
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
