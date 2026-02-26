//
//  BundleExported.swift
//  DrsMainApp
//
//  Created by yunastic on 11/9/25.
//

//
//  BundleExporter.swift
//  DrsMainApp
//
//  Pure-Foundation exporter used by MacBundleExporter.run(appState:)
//  Zips a peMR bundle folder into a temporary .pemr
//

import Foundation
import CryptoKit
import SQLite3

// SQLite bind lifetime helper (Swift doesn't expose SQLITE_TRANSIENT by default)
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Errors

enum BundleZipError: Error, LocalizedError {
    case sourceNotDirectory(URL)
    case zipFailed(code: Int, output: String)

    var errorDescription: String? {
        switch self {
        case .sourceNotDirectory(let url):
            return String(format: NSLocalizedString("exporter.bundlezip.error.source_not_directory", comment: "Bundle zip error: source is not a directory"), url.lastPathComponent)
        case .zipFailed(let code, let output):
            return String(format: NSLocalizedString("exporter.bundlezip.error.zip_failed", comment: "Bundle zip error: zip creation failed"), code, output)
        }
    }
}

// MARK: - Exporter

struct BundleExporter {

    /// Create a `.pemr` file from the given bundle folder (ZIP container with custom extension).
    /// Returns the temporary file URL of the created archive.
    static func exportBundle(from src: URL) async throws -> URL {
        // Run on a background thread to avoid blocking the main actor.
        return try await Task.detached(priority: .userInitiated) {
            try makeZip(from: src)
        }.value
    }

    // MARK: - Internal

    private static func makeZip(from src: URL) throws -> URL {
        let fm = FileManager.default

        // 1) Validate source
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else {
            throw BundleZipError.sourceNotDirectory(src)
        }

        // 2) Create a staging dir
        let stageRoot = fm.temporaryDirectory.appendingPathComponent("peMR-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stageRoot, withIntermediateDirectories: true)

        // 3) Copy filtered contents: db.sqlite + docs/**
        //    (skip db.sqlite-wal, db.sqlite-shm, .DS_Store, __MACOSX)
        let dbSrc  = src.appendingPathComponent("db.sqlite", isDirectory: false)
        let docsSrc = src.appendingPathComponent("docs", isDirectory: true)

        // Derive a clean base name for the exported file:
        // prefer the patient alias from db.sqlite if available,
        // otherwise fall back to the source folder name.
        var baseName = src.lastPathComponent
        if fm.fileExists(atPath: dbSrc.path),
           let ident = try? loadPatientIdentity(from: dbSrc),
           let alias = ident.alias,
           !alias.isEmpty {
            baseName = sanitizedSlug(alias)
        }

        if fm.fileExists(atPath: dbSrc.path) {
            // Best-effort: checkpoint WAL so the copied db.sqlite includes latest changes.
            walCheckpointIfNeeded(dbURL: dbSrc)

            let stagedDB = stageRoot.appendingPathComponent("db.sqlite")
            try fm.copyItem(at: dbSrc, to: stagedDB)

            // Remove soft-deleted visits from the *staged* copy only (source bundle DB remains reversible).
            purgeSoftDeletedVisits(in: stagedDB)

            // Ensure the staged DB is upgraded to the latest bundled schema before we encrypt it.
            // This guarantees exported bundles carry the current db schema even if the source bundle
            // hasn't been selected/migrated recently.
            applyBundledSchemaIfPresent(to: stagedDB)
        }
        if fm.fileExists(atPath: docsSrc.path) {
            try copyTreeFiltered(from: docsSrc, to: stageRoot.appendingPathComponent("docs"))
        }

        // 4) Build manifest.json with SHA-256 per file
        try writeManifestV2(at: stageRoot, sourceRoot: src)

        // 5) Zip the staged root (flat), using `<alias>-<timestamp>-drsmain.pemr`.
        let stamp = timestamp()
        let name  = "\(baseName)-\(stamp)-drsmain.pemr"
        let out   = fm.temporaryDirectory.appendingPathComponent(name, isDirectory: false)

        if fm.fileExists(atPath: out.path) { try? fm.removeItem(at: out) }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.currentDirectoryURL = stageRoot
        task.arguments = ["-r", "-y", out.path, ".", "-x", "__MACOSX/*", ".DS_Store", "*/.DS_Store", "*/._*"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = pipe
        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard task.terminationStatus == 0 else {
            // Cleanup staging before throwing
            try? fm.removeItem(at: stageRoot)
            throw BundleZipError.zipFailed(code: Int(task.terminationStatus), output: output)
        }

        // 6) Cleanup staging
        try? fm.removeItem(at: stageRoot)

        return out
    }

    /// Copy a directory tree while filtering out transient/macOS junk.
    private static func copyTreeFiltered(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        let contents = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        for item in contents {
            let name = item.lastPathComponent
            // skip junk
            if name == ".DS_Store" || name == "__MACOSX" || name.hasPrefix("._") { continue }
            // skip sqlite temps just in case
            if name.hasSuffix("-wal") || name.hasSuffix("-shm") { continue }

            let dstItem = dst.appendingPathComponent(name, isDirectory: false)
            let vals = try item.resourceValues(forKeys: [.isDirectoryKey])
            if vals.isDirectory == true {
                try copyTreeFiltered(from: item, to: dstItem)
            } else {
                try fm.copyItem(at: item, to: dstItem)
            }
        }
    }

    /// Write a v2 manifest with bundle identity (MRN, alias, DOB, sex), db checksum, and docs listing.
    /// Step 1: also encrypts db.sqlite → db.sqlite.enc and marks the bundle as encrypted.
    private static func writeManifestV2(at stageRoot: URL, sourceRoot: URL) throws {
        let fm = FileManager.default

        // Collect file metadata for backward compatibility (full flat list)…
        var files: [[String: Any]] = []
        var docsManifest: [[String: Any]] = []

        // db.sqlite checksum if present (plaintext), then encrypt to db.sqlite.enc
        var dbSHA256: String? = nil
        var encrypted = false
        var encryptionScheme: String? = nil

        let dbURL = stageRoot.appendingPathComponent("db.sqlite")
        // Read patient identity from the plaintext db.sqlite before encryption.
        // This gives us stable identity fields even though the staged bundle
        // will only contain db.sqlite.enc.
        let ident = try loadPatientIdentity(from: dbURL)
        if fm.fileExists(atPath: dbURL.path) {
            // Encrypt db.sqlite → db.sqlite.enc
            let encURL = stageRoot.appendingPathComponent("db.sqlite.enc")
            try BundleCrypto.encryptFile(at: dbURL, to: encURL)

            // Remove plaintext db.sqlite from the staged bundle
            try fm.removeItem(at: dbURL)

            // Hash the *shipped* DB file so import-side validation checks what’s actually inside the bundle.
            let encData = try Data(contentsOf: encURL)
            dbSHA256 = sha256Hex(encData)

            encrypted = true
            encryptionScheme = "AES-GCM-v1"
        }

        // Walk stage root (db.sqlite.enc and docs/**)
        let enumerator = fm.enumerator(
            at: stageRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )!

        for case let url as URL in enumerator {
            if url == stageRoot { continue }
            let name = url.lastPathComponent
            if name == ".DS_Store" || name == "manifest.json" || name.hasPrefix("._") { continue }

            let vals = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            if vals.isDirectory == true { continue }

            let relPath = url.path.replacingOccurrences(of: stageRoot.path + "/", with: "")
            let data = try Data(contentsOf: url)
            let sha = sha256Hex(data)
            let entry: [String: Any] = [
                "path": relPath,
                "size": vals.fileSize ?? data.count,
                "modified": ISO8601DateFormatter().string(from: vals.contentModificationDate ?? Date()),
                "sha256": sha
            ]
            files.append(entry)
            if relPath.hasPrefix("docs/") {
                docsManifest.append(entry)
            }
        }

        let manifest: [String: Any?] = [
            "format": "peMR",
            "schema_version": 2,
            "version": 2,
            "created": ISO8601DateFormatter().string(from: Date()),
            "bundle_name": sourceRoot.lastPathComponent,
            // Identity (nullable-safe — importer can fall back if missing)
            "patient_id": ident.id,
            "patient_alias": ident.alias,
            "dob": ident.dob,
            "patient_sex": ident.sex,
            "mrn": ident.mrn,
            // Encryption metadata
            "encrypted": encrypted,
            "encryption_scheme": encryptionScheme,
            // Checksums and listings
            "db_sha256": dbSHA256,
            "docs_manifest": docsManifest,
            // Keep prior "files" for backward compatibility with older importers
            "files": files
        ]

        // Serialize, dropping nils
        let json = try JSONSerialization.data(
            withJSONObject: manifest.compactMapValues { $0 },
            options: [.sortedKeys, .prettyPrinted]
        )
        try json.write(to: stageRoot.appendingPathComponent("manifest.json"), options: .atomic)
    }

    /// Extracts a single-patient identity from db.sqlite (best-effort).
    /// Falls back to nils if table/columns are missing.
    private static func loadPatientIdentity(from dbURL: URL) throws -> (id: Int?, alias: String?, dob: String?, sex: String?, mrn: String?) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbURL.path) else {
            return (nil, nil, nil, nil, nil)
        }

        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }

        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            return (nil, nil, nil, nil, nil)
        }

        // Verify patients table exists
        let tableCheckSQL = "SELECT name FROM sqlite_master WHERE type='table' AND name='patients' LIMIT 1;"
        var chkStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, tableCheckSQL, -1, &chkStmt, nil) == SQLITE_OK,
           sqlite3_step(chkStmt) == SQLITE_ROW {
            // ok
        } else {
            sqlite3_finalize(chkStmt)
            return (nil, nil, nil, nil, nil)
        }
        sqlite3_finalize(chkStmt)

        // Determine which columns exist
        func hasColumn(_ col: String) -> Bool {
            var stmt: OpaquePointer?
            let pragma = "PRAGMA table_info(patients);"
            var exists = false
            if sqlite3_prepare_v2(db, pragma, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let cName = sqlite3_column_text(stmt, 1) {
                        let name = String(cString: cName)
                        if name == col { exists = true; break }
                    }
                }
            }
            sqlite3_finalize(stmt)
            return exists
        }

        // Support both "alias" and "alias_label"
        let hasAlias        = hasColumn("alias")
        let hasAliasLabel   = hasColumn("alias_label")
        let aliasColumnName: String? = {
            if hasAlias { return "alias" }
            if hasAliasLabel { return "alias_label" }
            return nil
        }()

        let hasDOB   = hasColumn("dob")
        let hasSex   = hasColumn("sex")
        let hasMRN   = hasColumn("mrn")

        // Build a safe SELECT only for available columns
        var cols: [String] = ["id"]
        if let aliasColName = aliasColumnName {
            cols.append(aliasColName)
        }
        if hasDOB   { cols.append("dob") }
        if hasSex   { cols.append("sex") }
        if hasMRN   { cols.append("mrn") }

        let sql = "SELECT \(cols.joined(separator: ", ")) FROM patients ORDER BY id LIMIT 1;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            sqlite3_finalize(stmt)
            return (nil, nil, nil, nil, nil)
        }

        var pid: Int? = nil
        var alias: String? = nil
        var dob: String? = nil
        var sex: String? = nil
        var mrn: String? = nil

        if sqlite3_step(stmt) == SQLITE_ROW {
            var colIdx = 0

            // id (always present)
            pid = Int(sqlite3_column_int64(stmt, Int32(colIdx)))
            colIdx += 1

            // alias or alias_label if any
            if aliasColumnName != nil {
                if let c = sqlite3_column_text(stmt, Int32(colIdx)) {
                    alias = String(cString: c)
                }
                colIdx += 1
            }

            if hasDOB {
                if let c = sqlite3_column_text(stmt, Int32(colIdx)) { dob = String(cString: c) }
                colIdx += 1
            }
            if hasSex {
                if let c = sqlite3_column_text(stmt, Int32(colIdx)) { sex = String(cString: c) }
                colIdx += 1
            }
            if hasMRN {
                if let c = sqlite3_column_text(stmt, Int32(colIdx)) { mrn = String(cString: c) }
                colIdx += 1
            }
        }
        sqlite3_finalize(stmt)

        return (pid, alias, dob, sex, mrn)
    }

    // MARK: - Export sanitization (remove soft-deleted visits from staged DB)

    // MARK: - Schema upgrade (export-side)

    /// Best-effort: apply the app-bundled `schema.sql` to the given DB.
    /// Non-fatal: export should continue even if schema application fails.
    private static func applyBundledSchemaIfPresent(to dbURL: URL) {
        // If your schema.sql is packaged as DB/schema.sql in the bundle, use subdirectory: "DB"
        guard let schemaURL = Bundle.main.url(forResource: "schema", withExtension: "sql", subdirectory: "DB") else {
            return
        }
        do {
            let sql = try String(contentsOf: schemaURL, encoding: .utf8)
            applySQL(sql, to: dbURL)
        } catch {
            // Non-fatal: keep export working.
            // (We avoid OSLog privacy args here to keep it portable.)
            print("BundleExporter: schema.sql apply skipped: \(error)")
        }
    }

    /// Apply a SQL script (multiple statements) to a SQLite DB file.
    /// Uses sqlite3_exec which can process multiple statements separated by semicolons.
    private static func applySQL(_ sql: String, to dbURL: URL) {
        var db: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
            if let db { sqlite3_close(db) }
            return
        }
        guard let db = db else { return }
        defer { sqlite3_close(db) }

        _ = sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)

        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            if let errMsg {
                let msg = String(cString: errMsg)
                sqlite3_free(errMsg)
                // Non-fatal
                print("BundleExporter: schema.sql apply error: \(msg)")
            }
        }
    }

    /// Best-effort WAL checkpoint so db.sqlite copies include recent writes.
    private static func walCheckpointIfNeeded(dbURL: URL) {
        var db: OpaquePointer?
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            if let db { sqlite3_close(db) }
            return
        }
        guard let db = db else { return }
        defer { sqlite3_close(db) }
        _ = sqlite3_exec(db, "PRAGMA wal_checkpoint(FULL);", nil, nil, nil)
    }

    /// Remove any visits marked `is_deleted=1` from the staged DB copy.
    /// This keeps the clinician-side DB reversible while guaranteeing the exported bundle is clean.
    private static func purgeSoftDeletedVisits(in stagedDBURL: URL) {
        var db: OpaquePointer?
        if sqlite3_open_v2(stagedDBURL.path, &db, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
            if let db { sqlite3_close(db) }
            return
        }
        guard let db = db else { return }
        defer { sqlite3_close(db) }

        // Keep this resilient across schema versions.
        func tableExists(_ name: String) -> Bool {
            let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_ROW
        }

        func hasColumn(table: String, col: String) -> Bool {
            var stmt: OpaquePointer?
            let pragma = "PRAGMA table_info(\(table));"
            var exists = false
            if sqlite3_prepare_v2(db, pragma, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let cName = sqlite3_column_text(stmt, 1) {
                        if String(cString: cName) == col { exists = true; break }
                    }
                }
            }
            sqlite3_finalize(stmt)
            return exists
        }

        // If the soft-delete column doesn't exist, nothing to purge.
        let episodesHasSoftDelete = tableExists("episodes") && hasColumn(table: "episodes", col: "is_deleted")
        let wellHasSoftDelete = tableExists("well_visits") && hasColumn(table: "well_visits", col: "is_deleted")
        guard episodesHasSoftDelete || wellHasSoftDelete else { return }

        // We do staged cleanup with foreign keys off to avoid failing on older schemas.
        _ = sqlite3_exec(db, "PRAGMA foreign_keys=OFF;", nil, nil, nil)
        _ = sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

        func exec(_ sql: String) {
            _ = sqlite3_exec(db, sql, nil, nil, nil)
        }

        if episodesHasSoftDelete {
            // Remove dependent rows first (no-cascade FKs exist in older schemas).
            if tableExists("vitals") {
                exec("DELETE FROM vitals WHERE episode_id IN (SELECT id FROM episodes WHERE is_deleted=1);")
            }
            if tableExists("ai_inputs") {
                exec("DELETE FROM ai_inputs WHERE episode_id IN (SELECT id FROM episodes WHERE is_deleted=1);")
            }
            if tableExists("visit_addenda") {
                exec("DELETE FROM visit_addenda WHERE episode_id IN (SELECT id FROM episodes WHERE is_deleted=1);")
            }
            exec("DELETE FROM episodes WHERE is_deleted=1;")
        }

        if wellHasSoftDelete {
            if tableExists("well_visit_milestones") {
                exec("DELETE FROM well_visit_milestones WHERE visit_id IN (SELECT id FROM well_visits WHERE is_deleted=1);")
            }
            if tableExists("well_visit_growth_eval") {
                exec("DELETE FROM well_visit_growth_eval WHERE well_visit_id IN (SELECT id FROM well_visits WHERE is_deleted=1);")
            }
            if tableExists("well_ai_inputs") {
                exec("DELETE FROM well_ai_inputs WHERE well_visit_id IN (SELECT id FROM well_visits WHERE is_deleted=1);")
            }
            if tableExists("visit_addenda") {
                exec("DELETE FROM visit_addenda WHERE well_visit_id IN (SELECT id FROM well_visits WHERE is_deleted=1);")
            }
            exec("DELETE FROM well_visits WHERE is_deleted=1;")
        }

        // Commit; ignore failure and rollback.
        if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
        }

        _ = sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizedSlug(_ raw: String) -> String {
        // Normalize and strip diacritics
        let decomposed = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        // Allow only ASCII alphanumerics plus dash/underscore; replace others with "_"
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let mappedScalars = decomposed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        var slug = String(mappedScalars)
        // Collapse multiple underscores
        slug = slug.replacingOccurrences(of: #"_{2,}"#, with: "_", options: .regularExpression)
        // Trim leading/trailing separators
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return slug.isEmpty ? "export" : slug
    }

    private static func timestamp() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return df.string(from: Date())
    }
}
