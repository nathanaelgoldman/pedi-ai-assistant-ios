//
//  TerminologyStore.swift
//  DrsMainApp
//
//  Local SNOMED terminology DB access (read-only runtime).
//

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@MainActor
final class TerminologyStore: ObservableObject {

    private let log = AppLog.feature("terminology")

    // MARK: - Version contract
    // Bump this only when the SQLite schema layout changes (tables/columns/indexes).
    private let expectedSchemaVersion = "1"

    // Meta keys we expect in the terminology DB.
    private enum MetaKey {
        static let schemaVersion = "schema_version"
        static let rf2Release    = "rf2_release"
        static let subsetName    = "subset_name"
        static let subsetVersion = "subset_version"
        static let dbBuild       = "db_build"
        static let contentHash   = "content_hash"
    }

    // MARK: - Basic term search (dev / first integration)

    struct TermHit: Identifiable, Hashable {
        let id: Int64            // description_id
        let conceptID: Int64
        let term: String
    }

    /// Simple LIKE search in description.term (active rows only).
    ///
    /// Notes:
    /// - This is intentionally minimal for first wiring.
    /// - Later we’ll upgrade to preferred terms via langrefset and add locale/language handling.
    func searchTerms(_ query: String, limit: Int = 25) -> [TermHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        guard let db = openDBReadOnly() else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT description_id, concept_id, term
        FROM description
        WHERE active = 1
          AND term LIKE ?
        ORDER BY LENGTH(term) ASC
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            log.error("TerminologyStore: searchTerms prepare failed: \(msg, privacy: .public)")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let like = "%\(q)%"
        _ = like.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 2, Int32(max(1, min(limit, 200))))

        var out: [TermHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let descID = sqlite3_column_int64(stmt, 0)
            let conceptID = sqlite3_column_int64(stmt, 1)
            guard let cStr = sqlite3_column_text(stmt, 2) else { continue }
            let term = String(cString: cStr)
            out.append(TermHit(id: descID, conceptID: conceptID, term: term))
        }
        return out
    }

    // MARK: - DB location (local app space, NOT patient bundle)
    /// ~/Library/Application Support/DrsMainApp/Terminology/snomed.sqlite
    private var dbURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ))!
            .appendingPathComponent("DrsMainApp", isDirectory: true)
            .appendingPathComponent("Terminology", isDirectory: true)

        if !fm.fileExists(atPath: base.path) {
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        }

        return base.appendingPathComponent("snomed.sqlite", isDirectory: false)
    }

    /// Name of the bundled DB file in app resources.
    /// You will add "snomed.sqlite" to the Xcode target's Copy Bundle Resources.
    private let bundledDBResourceName = "snomed"
    private let bundledDBResourceExt  = "sqlite"

    // MARK: - Lifecycle
    init() {
        installBundledDBIfNeeded()
        healthCheck()

        #if DEBUG
        // Dev smoke test: proves the DB opens and basic search returns rows.
        // Remove or gate behind a UI debug panel later.
        let hits = searchTerms("fever", limit: 5)
        if hits.isEmpty {
            log.info("TerminologyStore: DEBUG smoke search 'fever' -> 0 hits")
        } else {
            let sample = hits.map { $0.term }.joined(separator: " | ")
            log.info("TerminologyStore: DEBUG smoke search 'fever' -> \(hits.count, privacy: .public) hits: \(sample, privacy: .public)")
        }
        #endif
    }

    // MARK: - Install/copy bundled DB
    private func installBundledDBIfNeeded() {
        let fm = FileManager.default

        // If DB already exists locally, do nothing.
        if fm.fileExists(atPath: dbURL.path) { return }

        guard let src = Bundle.main.url(forResource: bundledDBResourceName, withExtension: bundledDBResourceExt) else {
            log.info("TerminologyStore: no bundled snomed.sqlite found in app resources (ok during dev)")
            return
        }

        do {
            try fm.copyItem(at: src, to: dbURL)
            log.info("TerminologyStore: installed bundled DB -> \(self.dbURL.lastPathComponent, privacy: .public)")
        } catch {
            log.error("TerminologyStore: copy bundled DB failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - SQLite open (READONLY)
    private func openDBReadOnly() -> OpaquePointer? {
        // If the DB file doesn't exist yet (common during dev), don't even attempt sqlite open.
        if !FileManager.default.fileExists(atPath: dbURL.path) {
            log.info("TerminologyStore: snomed.sqlite not present at expected path (ok during dev)")
            return nil
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY

        let rc = sqlite3_open_v2(dbURL.path, &db, flags, nil)
        guard rc == SQLITE_OK, let opened = db else {
            // Avoid calling sqlite APIs on a potentially-invalid pointer.
            if let db { sqlite3_close(db) }
            let msg = String(cString: sqlite3_errstr(rc))
            log.info("TerminologyStore: failed to open snomed.sqlite readonly rc=\(rc, privacy: .public) err=\(msg, privacy: .public)")
            return nil
        }

        return opened
    }

    // MARK: - Health check (cheap smoke test)
    private func healthCheck() {
        guard let db = openDBReadOnly() else { return }
        defer { sqlite3_close(db) }

        // Once the real schema is in place, we expect these core tables to exist.
        // (We keep the check lightweight and only log failures.)
        let expectedTables = [
            "meta",          // schema/version stamp
            "concept",       // SNOMED concepts (subset)
            "description",   // FSN + synonyms (subset)
            "langrefset"     // language refset preferences (subset)
        ]

        func tableExists(_ name: String) -> Bool {
            let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return false
            }
            defer { sqlite3_finalize(stmt) }
            _ = name.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
            return sqlite3_step(stmt) == SQLITE_ROW
        }

        var missing: [String] = []
        for t in expectedTables {
            if !tableExists(t) { missing.append(t) }
        }

        if !missing.isEmpty {
            log.info("TerminologyStore: snomed.sqlite opened, but missing tables: \(missing.joined(separator: ", "), privacy: .public)")
            return
        }

        // Read meta (schema + content) and enforce schema compatibility.
        func readMeta(_ key: String) -> String? {
            let sql = "SELECT value FROM meta WHERE key=? LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
            defer { sqlite3_finalize(stmt) }
            _ = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
            let v = String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }

        let schemaV = readMeta(MetaKey.schemaVersion) ?? "<missing>"
        let rf2Rel  = readMeta(MetaKey.rf2Release) ?? "<missing>"
        let subset  = readMeta(MetaKey.subsetName) ?? "<missing>"
        let subsetV = readMeta(MetaKey.subsetVersion) ?? "<missing>"

        // Optional meta keys: during early development/testing we may ship a mock DB
        // that intentionally omits build/hash stamps. Treat as informational only.
        let dbBuildRaw = readMeta(MetaKey.dbBuild)
        let hashRaw    = readMeta(MetaKey.contentHash)

        let dbBuildInfo = (dbBuildRaw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? " build=\(dbBuildRaw!)"
            : ""
        let hashInfo = (hashRaw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? " hash=\(hashRaw!)"
            : ""

        if schemaV != expectedSchemaVersion {
            // Hard fail (we keep the DB unopened beyond this check, but signal loudly).
            log.info(
                "TerminologyStore: incompatible snomed.sqlite schema_version=\(schemaV, privacy: .public) expected=\(self.expectedSchemaVersion, privacy: .public) rf2=\(rf2Rel, privacy: .public) subset=\(subset, privacy: .public)"
            )
            return
        }

        log.info(
            "TerminologyStore: snomed.sqlite OK schema=\(schemaV, privacy: .public) rf2=\(rf2Rel, privacy: .public) subset=\(subset, privacy: .public) subsetV=\(subsetV, privacy: .public)\(dbBuildInfo, privacy: .public)\(hashInfo, privacy: .public)"
        )
    }
}
