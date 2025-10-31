//
//  ClinicianStore.swift
//  DrsMainApp
//
//  Created by yunastic on 10/30/25.
//

import Foundation
import OSLog
import SQLite3
import SwiftUI

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Lightweight model for a clinician (physician) who uses the app locally.
/// Stored in an app-private SQLite DB (NOT inside the patient bundle).
struct Clinician: Identifiable, Equatable {
    let id: Int
    let firstName: String
    let lastName: String

    // Optional profile fields
    var title: String?          // e.g., MD, FAAP
    var email: String?
    var societies: String?      // free text or comma-separated memberships
    var website: String?
    var twitter: String?
    var wechat: String?
    var instagram: String?
    var linkedin: String?

    var fullName: String { "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces) }
}

@MainActor
final class ClinicianStore: ObservableObject {
    @Published private(set) var users: [Clinician] = []
    @Published private(set) var activeUser: Clinician? = nil

    private let log = Logger(subsystem: "com.pediai.DrsMainApp", category: "ClinicianStore")
    private let activeUserKey = "activeClinicianID"

    // MARK: - DB location
    /// ~/Library/Application Support/DrsMainApp/Clinicians/clinicians.sqlite
    private var dbURL: URL {
        let fm = FileManager.default
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
    }

    // MARK: - SQLite helpers
    private func openDB() -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
            if let db { sqlite3_close(db) }
            log.error("Failed to open clinicians DB at \(self.dbURL.path, privacy: .public)")
            return nil
        }
        return db
    }

    private func ensureSchema() {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }

        let sql = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            first_name TEXT NOT NULL,
            last_name  TEXT NOT NULL,
            title      TEXT,
            email      TEXT,
            societies  TEXT,
            website    TEXT,
            twitter    TEXT,
            wechat     TEXT,
            instagram  TEXT,
            linkedin   TEXT,
            created_at TEXT
        );
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            log.error("Clinician schema init failed: \(msg, privacy: .public)")
        }

        _ = sqlite3_exec(db, """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_users_name_nocase
            ON users (lower(trim(first_name)), lower(trim(last_name)));
        """, nil, nil, nil)

        // Safe migrations for older DBs: add missing columns if needed
        let alterStmts = [
            "ALTER TABLE users ADD COLUMN title TEXT",
            "ALTER TABLE users ADD COLUMN email TEXT",
            "ALTER TABLE users ADD COLUMN societies TEXT",
            "ALTER TABLE users ADD COLUMN website TEXT",
            "ALTER TABLE users ADD COLUMN twitter TEXT",
            "ALTER TABLE users ADD COLUMN wechat TEXT",
            "ALTER TABLE users ADD COLUMN instagram TEXT",
            "ALTER TABLE users ADD COLUMN linkedin TEXT"
        ]
        for stmt in alterStmts {
            _ = sqlite3_exec(db, stmt, nil, nil, nil) // ignore errors if column already exists
        }
    }

    // MARK: - Lifecycle
    init() {
        ensureSchema()
        reloadUsers()
        restoreActiveUser()
    }

    // MARK: - CRUD
    func reloadUsers() {
        guard let db = openDB() else {
            users = []
            return
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id,
               TRIM(first_name) AS first_name,
               TRIM(last_name)  AS last_name,
               title, email, societies, website, twitter, wechat, instagram, linkedin
        FROM users
        ORDER BY last_name, first_name, id;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            log.error("reloadUsers prepare failed: \(msg, privacy: .public)")
            users = []
            return
        }

        func s(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            let v = String(cString: c)
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        var out: [Clinician] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            let fn = s(1) ?? ""
            let ln = s(2) ?? ""
            let user = Clinician(
                id: id,
                firstName: fn,
                lastName: ln,
                title: s(3),
                email: s(4),
                societies: s(5),
                website: s(6),
                twitter: s(7),
                wechat: s(8),
                instagram: s(9),
                linkedin: s(10)
            )
            out.append(user)
        }
        self.users = out
    }

    @discardableResult
    func createUser(firstName: String,
                    lastName: String,
                    title: String? = nil,
                    email: String? = nil,
                    societies: String? = nil,
                    website: String? = nil,
                    twitter: String? = nil,
                    wechat: String? = nil,
                    instagram: String? = nil,
                    linkedin: String? = nil) -> Clinician? {
        let fnClean = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lnClean = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fnClean.isEmpty, !lnClean.isEmpty else { return nil }
        guard let db = openDB() else { return nil }
        defer { sqlite3_close(db) }

        let iso = ISO8601DateFormatter().string(from: Date())
        let sql = """
        INSERT INTO users (first_name, last_name, title, email, societies, website, twitter, wechat, instagram, linkedin, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            log.error("createUser prepare failed: \(msg, privacy: .public)")
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        func bindOpt(_ index: Int32, _ value: String?) {
            if let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, index)
            }
        }

        sqlite3_bind_text(stmt, 1, fnClean, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, lnClean, -1, SQLITE_TRANSIENT)
        bindOpt(3, title)
        bindOpt(4, email)
        bindOpt(5, societies)
        bindOpt(6, website)
        bindOpt(7, twitter)
        bindOpt(8, wechat)
        bindOpt(9, instagram)
        bindOpt(10, linkedin)
        sqlite3_bind_text(stmt, 11, iso, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            log.error("createUser step failed: \(msg, privacy: .public)")
            return nil
        }

        let newID = Int(sqlite3_last_insert_rowid(db))
        let user = Clinician(id: newID,
                             firstName: fnClean,
                             lastName: lnClean,
                             title: title,
                             email: email,
                             societies: societies,
                             website: website,
                             twitter: twitter,
                             wechat: wechat,
                             instagram: instagram,
                             linkedin: linkedin)
        reloadUsers()
        return user
    }

    func updateUser(id: Int,
                    firstName: String? = nil,
                    lastName: String? = nil,
                    title: String? = nil,
                    email: String? = nil,
                    societies: String? = nil,
                    website: String? = nil,
                    twitter: String? = nil,
                    wechat: String? = nil,
                    instagram: String? = nil,
                    linkedin: String? = nil) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }

        let sql = """
        UPDATE users SET
          first_name = COALESCE(?, first_name),
          last_name  = COALESCE(?, last_name),
          title      = COALESCE(?, title),
          email      = COALESCE(?, email),
          societies  = COALESCE(?, societies),
          website    = COALESCE(?, website),
          twitter    = COALESCE(?, twitter),
          wechat     = COALESCE(?, wechat),
          instagram  = COALESCE(?, instagram),
          linkedin   = COALESCE(?, linkedin)
        WHERE id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        func bindOpt(_ idx: Int32, _ value: String?) {
            if let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, idx)
            }
        }

        bindOpt(1, firstName)
        bindOpt(2, lastName)
        bindOpt(3, title)
        bindOpt(4, email)
        bindOpt(5, societies)
        bindOpt(6, website)
        bindOpt(7, twitter)
        bindOpt(8, wechat)
        bindOpt(9, instagram)
        bindOpt(10, linkedin)
        sqlite3_bind_int64(stmt, 11, sqlite3_int64(id))

        _ = sqlite3_step(stmt)
        reloadUsers()

        // keep activeUser in sync if necessary
        if let active = activeUser, active.id == id {
            activeUser = users.first(where: { $0.id == id })
        }
    }

    func deleteUser(id: Int) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        let sql = "DELETE FROM users WHERE id=?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(id))
        _ = sqlite3_step(stmt)

        // clear active if it was this one
        if activeUser?.id == id {
            setActiveUser(nil)
        }
        reloadUsers()
    }

    /// Convenience overload to delete by model
    func deleteUser(_ user: Clinician) {
        deleteUser(id: user.id)
    }

    // MARK: - Active user (simple local "login")
    func setActiveUser(_ user: Clinician?) {
        if let u = user {
            UserDefaults.standard.set(u.id, forKey: activeUserKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeUserKey)
        }
        activeUser = user
    }

    private func restoreActiveUser() {
        let id = UserDefaults.standard.integer(forKey: activeUserKey)
        guard id != 0 else {
            activeUser = nil
            return
        }
        if let match = users.first(where: { $0.id == id }) {
            activeUser = match
        } else {
            activeUser = nil
            UserDefaults.standard.removeObject(forKey: activeUserKey)
        }
    }
}
