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
//  Zips a peMR bundle folder into a temporary .peMR.zip
//

import Foundation
import CryptoKit
import SQLite3

// MARK: - Errors

enum BundleZipError: Error, LocalizedError {
    case sourceNotDirectory(URL)
    case zipFailed(code: Int, output: String)

    var errorDescription: String? {
        switch self {
        case .sourceNotDirectory(let url):
            return "Source is not a directory: \(url.path)"
        case .zipFailed(let code, let output):
            return "Failed to create zip (code \(code)). Output:\n\(output)"
        }
    }
}

// MARK: - Exporter

struct BundleExporter {

    /// Create a `.peMR.zip` from the given bundle folder.
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
        if fm.fileExists(atPath: dbSrc.path) {
            try fm.copyItem(at: dbSrc, to: stageRoot.appendingPathComponent("db.sqlite"))
        }
        if fm.fileExists(atPath: docsSrc.path) {
            try copyTreeFiltered(from: docsSrc, to: stageRoot.appendingPathComponent("docs"))
        }

        // 4) Build manifest.json with SHA-256 per file
        try writeManifestV2(at: stageRoot, sourceRoot: src)

        // 5) Zip the staged root (flat)
        let stamp = timestamp()
        let name  = "\(src.lastPathComponent)-\(stamp).peMR.zip"
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
    private static func writeManifestV2(at stageRoot: URL, sourceRoot: URL) throws {
        let fm = FileManager.default

        // Collect file metadata for backward compatibility (full flat list)…
        var files: [[String: Any]] = []
        var docsManifest: [[String: Any]] = []

        // db.sqlite checksum if present
        var dbSHA256: String? = nil
        let dbURL = stageRoot.appendingPathComponent("db.sqlite")
        if fm.fileExists(atPath: dbURL.path) {
            let data = try Data(contentsOf: dbURL)
            dbSHA256 = sha256Hex(data)
        }

        // Walk stage root (db.sqlite and docs/**)
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

        // Read patient identity from db.sqlite if possible
        let ident = try loadPatientIdentity(from: dbURL)

        let manifest: [String: Any?] = [
            "version": 2,
            "created": ISO8601DateFormatter().string(from: Date()),
            "bundle_name": sourceRoot.lastPathComponent,
            // Identity (nullable-safe — importer can fall back if missing)
            "patient_id": ident.id,
            "patient_alias": ident.alias,
            "dob": ident.dob,
            "patient_sex": ident.sex,
            "mrn": ident.mrn,
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

        let hasAlias = hasColumn("alias")
        let hasDOB   = hasColumn("dob")
        let hasSex   = hasColumn("sex")
        let hasMRN   = hasColumn("mrn")

        // Build a safe SELECT only for available columns
        var cols: [String] = ["id"]
        if hasAlias { cols.append("alias") }
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
            // id
            pid = Int(sqlite3_column_int64(stmt, Int32(colIdx))); colIdx += 1
            if hasAlias {
                if let c = sqlite3_column_text(stmt, Int32(colIdx)) { alias = String(cString: c) }
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

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func timestamp() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return df.string(from: Date())
    }
}
