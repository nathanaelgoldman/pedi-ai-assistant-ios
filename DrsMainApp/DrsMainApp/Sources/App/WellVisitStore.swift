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

    // Plan / summary
    public var problemListing: String?
}

/// Payload used by the UI for insert / update.
/// `patientID` and `userID` are supplied separately to `insert(...)` so
/// this stays focused on visit content.
public struct WellVisitPayload: Equatable {
    public var visitDateISO: String = ""      // ISO8601 date (yyyy-MM-dd)
    public var visitType: String = ""         // e.g. "one_month", "six_month", "episode" (if ever reused)
    public var ageDays: Int? = nil

    public var poopStatus: String? = nil
    public var poopComment: String? = nil
    public var vitaminD: Int? = nil
    public var milkTypes: String? = nil
    public var expressedBM: Int? = nil       // 0/1

    public var problemListing: String? = nil
}

/// Data access layer for the `well_visits` table.
/// NOTE: This layer assumes the table already exists in db.sqlite.
public struct WellVisitStore {

    public init() {}

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
            problem_listing
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
            problemListing: problemListing
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
            problem_listing
        )
        VALUES ( ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? );
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

        // problem listing
        bindText(stmt, index: idx, value: payload.problemListing); idx += 1

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
            problem_listing = ?
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

        try bindInt64(stmt, index: idx, value: id)

        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            throw sqliteError(db, context: "well_visits update step rc=\(rc)")
        }
        return sqlite3_changes(db) > 0
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

    private func sqliteError(_ db: OpaquePointer?, context: String) -> NSError {
        let code = sqlite3_errcode(db)
        if let cmsg = sqlite3_errmsg(db) {
            let msg = String(cString: cmsg)
            return NSError(
                domain: "WellVisitStore",
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "\(context): \(msg)"]
            )
        }
        return NSError(
            domain: "WellVisitStore",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: context]
        )
    }
}

// Required by SQLite C-API for transient text bindings
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
