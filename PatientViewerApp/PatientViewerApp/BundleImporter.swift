import Foundation
import SQLite3
import SwiftUI
import ZIPFoundation
import UniformTypeIdentifiers
import CryptoKit
import os


let bundlesDirectoryName = "Bundles"
let activeBundleDirName = "ActiveBundle"
let archiveDirName = "ArchivedZips"

private let log = Logger(subsystem: "Yunastic.PatientViewerApp", category: "BundleImporter")

// MARK: - Integrity utilities

private struct DocsEntry: Codable {
    let path: String
    let sha256: String
}

private struct ManifestV2: Codable {
    let schema_version: Int?
    let db_sha256: String?
    let docs_manifest: [DocsEntry]?
}

private func sha256Hex(ofFile url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func loadManifest(at root: URL) throws -> ManifestV2 {
    let manifestURL = root.appendingPathComponent("manifest.json")
    let data = try Data(contentsOf: manifestURL)
    return try JSONDecoder().decode(ManifestV2.self, from: data)
}

/// Quick header validation to ensure the file really is an SQLite database.
private func validateSQLiteHeader(dbURL: URL) throws {
    let data = try Data(contentsOf: dbURL, options: [.mappedIfSafe])
    guard data.count >= 16 else {
        throw NSError(domain: "DBIntegrity", code: 100, userInfo: [NSLocalizedDescriptionKey: "db.sqlite is too small to be a valid SQLite file."])
    }
    let magic = String(decoding: data.prefix(16), as: UTF8.self)
    if magic != "SQLite format 3\u{0}" {
        throw NSError(domain: "DBIntegrity", code: 101, userInfo: [NSLocalizedDescriptionKey: "db.sqlite header is not 'SQLite format 3\\0' (got: \(magic))"])
    }
}

/// Verify db.sqlite hash (hard fail) and docs hashes (soft-fail with warnings).
/// Returns the decoded manifest for callers that want to use its fields.
@discardableResult
private func verifyExtractedBundle(root: URL, log: (String) -> Void) throws -> ManifestV2 {
    let manifest = try loadManifest(at: root)
    let schema = manifest.schema_version ?? 1
    if schema < 2 {
        log("[WARN] manifest.schema_version=\(schema) (<2). Skipping hash verification (legacy bundle).")
        return manifest
    }

    // Verify db.sqlite
    let dbURL = root.appendingPathComponent("db.sqlite")
    guard FileManager.default.fileExists(atPath: dbURL.path) else {
        throw NSError(domain: "BundleImport", code: 2001,
                      userInfo: [NSLocalizedDescriptionKey: "Bundle is missing db.sqlite"])
    }
    if let expected = manifest.db_sha256 {
        let actual = try sha256Hex(ofFile: dbURL)
        if expected.lowercased() != actual.lowercased() {
            throw NSError(domain: "BundleImport", code: 2002,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "Corrupt bundle: db.sqlite hash mismatch. Expected \(expected.prefix(12))…, got \(actual.prefix(12))…"])
        }
        log("[DEBUG] db.sqlite hash verified.")
    } else {
        log("[WARN] manifest missing db_sha256 despite schema_version ≥ 2.")
    }

    // Verify docs (optional)
    if let docsList = manifest.docs_manifest, !docsList.isEmpty {
        let docsRoot = root.appendingPathComponent("docs")
        var mismatches: [String] = []
        for entry in docsList {
            let fileURL = docsRoot.appendingPathComponent(entry.path)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                mismatches.append("\(entry.path) (missing)")
                continue
            }
            do {
                let actual = try sha256Hex(ofFile: fileURL)
                if actual.lowercased() != entry.sha256.lowercased() {
                    mismatches.append("\(entry.path) (hash mismatch)")
                }
            } catch {
                mismatches.append("\(entry.path) (read error: \(error.localizedDescription))")
            }
        }
        if mismatches.isEmpty {
            log("[DEBUG] docs/ hashes verified (\(docsList.count) items).")
        } else {
            // Soft-fail: continue import but log detail
            log("[WARN] \(mismatches.count) docs didn’t verify: \(mismatches.joined(separator: ", "))")
        }
    }

    return manifest
}

// Centralized cleanup for temp artifacts
private func cleanupTempArtifacts(_ tempZip: URL, _ tempExtract: URL) {
    let fm = FileManager.default
    try? fm.removeItem(at: tempZip)
    try? fm.removeItem(at: tempExtract)
    log.debug("Cleaned temp import artifacts.")
}

struct BundleImporter: View {
    @Binding var extractedFolderURL: URL?
    @Binding var bundleAlias: String?
    @Binding var bundleDOB: String?

    @State private var isImporterPresented = false
    @State private var importError: String?

    // MARK: - Public API
    /// Import a zip bundle and return the working folder URL, alias and dob
    static func importBundle(from zipURL: URL, force: Bool = false) async throws -> (URL, String, String) {
        let fm = FileManager.default
        let start = Date()
        log.info("Import started for \(zipURL.lastPathComponent, privacy: .public)")
        guard let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "BundleImporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "❌ Failed to locate documents directory."])
        }

        // Ensure Bundles folder exists
        let bundlesDir = docsURL.appendingPathComponent(bundlesDirectoryName)
        try? fm.createDirectory(at: bundlesDir, withIntermediateDirectories: true)

        // Copy ZIP into Bundles folder (destination zip) — keep a copy for archival
        let originalZipName = zipURL.lastPathComponent
        let destinationZipPath = bundlesDir.appendingPathComponent(originalZipName)

        // If a file with the same name already exists and same modification date -> signal duplicate
        if fm.fileExists(atPath: destinationZipPath.path), force == false {
            let existingAttributes = try fm.attributesOfItem(atPath: destinationZipPath.path)
            let newAttributes = try fm.attributesOfItem(atPath: zipURL.path)
            if let existingDate = existingAttributes[.modificationDate] as? Date,
               let newDate = newAttributes[.modificationDate] as? Date,
               existingDate == newDate {
                throw NSError(domain: "BundleImporter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bundle with the same name already exists.", "bundleURL": destinationZipPath, "originalZipURL": zipURL])
            }
        }

        // Copy incoming zip to a temp area and unzip to a temporary extraction destination
        let tempZip = docsURL.appendingPathComponent("Imported-\(UUID().uuidString).zip")
        try fm.copyItem(at: zipURL, to: tempZip)

        let tempExtract = docsURL.appendingPathComponent("ExtractedBundle-\(UUID().uuidString)")
        try fm.createDirectory(at: tempExtract, withIntermediateDirectories: true)
        try fm.unzipItem(at: tempZip, to: tempExtract)

        // Validate required files inside extracted bundle
        let expectedDB = tempExtract.appendingPathComponent("db.sqlite")
        let expectedManifest = tempExtract.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: expectedDB.path), fm.fileExists(atPath: expectedManifest.path) else {
            // Cleanup temp items before throwing
            cleanupTempArtifacts(tempZip, tempExtract)
            throw NSError(domain: "BundleImporter", code: 3, userInfo: [NSLocalizedDescriptionKey: "❌ Extracted bundle is missing required files."])
        }

        // Fail fast if db.sqlite isn't an actual SQLite file (magic header check)
        do {
            try validateSQLiteHeader(dbURL: expectedDB)
            log.debug("SQLite header validated for \(expectedDB.path, privacy: .public)")
        } catch {
            // Cleanup temp items before throwing
            cleanupTempArtifacts(tempZip, tempExtract)
            throw NSError(domain: "BundleImporter", code: 11, userInfo: [NSLocalizedDescriptionKey: "❌ Not a valid SQLite file: \(error.localizedDescription)"])
        }

        // Verify manifest/db/docs hashes (throws on db mismatch)
        do {
            _ = try verifyExtractedBundle(root: tempExtract) { msg in
                log.debug("\(msg, privacy: .public)")
            }
        } catch {
            // Cleanup temp items before throwing
            cleanupTempArtifacts(tempZip, tempExtract)
            throw NSError(domain: "BundleImporter", code: 10, userInfo: [NSLocalizedDescriptionKey: "❌ Verification failed: \(error.localizedDescription)"])
        }

        // Run SQLite integrity check on the incoming DB before touching it
        do {
            try runIntegrityCheckOrThrow(dbPath: expectedDB.path)
        } catch {
            // Cleanup temp items before throwing
            cleanupTempArtifacts(tempZip, tempExtract)
            throw NSError(domain: "BundleImporter", code: 9, userInfo: [NSLocalizedDescriptionKey: "❌ Integrity check failed for db.sqlite: \(error.localizedDescription)"])
        }

        do {
            try ensureParentNotesColumn(dbPath: expectedDB.path)
        } catch {
            log.warning("ensureParentNotesColumn(temp) failed: \(error.localizedDescription)")
        }

        // Read alias and dob from the temp db
        let (alias, dob) = try readAliasAndDOB(fromDBAt: expectedDB.path)
        let safeAlias = sanitizeFileName(alias.isEmpty ? "Unknown" : alias)

        // Also copy to persistent folder for permanent updates
        let persistentBundlesDir = docsURL.appendingPathComponent("PersistentBundles")
        try? fm.createDirectory(at: persistentBundlesDir, withIntermediateDirectories: true)
        let persistentFolder = persistentBundlesDir.appendingPathComponent(safeAlias)
        if fm.fileExists(atPath: persistentFolder.path) {
            try? fm.removeItem(at: persistentFolder)
        }
        try? fm.copyItem(at: tempExtract, to: persistentFolder)
        log.debug("Saved persistent bundle to: \(persistentFolder.path, privacy: .public)")
        // Ensure the persistent copy has the migration as well
        let persistentDBPath = persistentFolder.appendingPathComponent("db.sqlite").path
        do {
            try ensureParentNotesColumn(dbPath: persistentDBPath)
        } catch {
            log.warning("ensureParentNotesColumn(persistent) failed: \(error.localizedDescription)")
        }

        // Check if a persistent ActiveBundle already exists for this alias
        let persistentBundlePath = docsURL.appendingPathComponent(activeBundleDirName).appendingPathComponent(safeAlias)
        if fm.fileExists(atPath: persistentBundlePath.path), force == false {
            log.debug("Found existing ActiveBundle at \(persistentBundlePath.path, privacy: .public), skipping re-import.")
            log.debug("Fallback to previously extracted unzipped version triggered (re-import skipped).")
            UserDefaults.standard.set(persistentBundlePath.path, forKey: "lastLoadedBundleZipPath")
            UserDefaults.standard.set(persistentBundlePath.lastPathComponent, forKey: "lastLoadedWorkingFolderName")
            let existingDBPath = persistentBundlePath.appendingPathComponent("db.sqlite").path
            do {
                try ensureParentNotesColumn(dbPath: existingDBPath)
            } catch {
                log.warning("ensureParentNotesColumn(existing ActiveBundle) failed: \(error.localizedDescription)")
            }
            // Cleanup temp artifacts when skipping re-import
            cleanupTempArtifacts(tempZip, tempExtract)
            log.info("Import skipped; using existing ActiveBundle at \(persistentBundlePath.path, privacy: .public). Elapsed=\(Date().timeIntervalSince(start), privacy: .public)s")
            return (persistentBundlePath, alias, dob)
        }

        // Insert debug logs for DB path verification
        log.debug("Preparing ActiveBundle path for \(safeAlias, privacy: .public)")

        // Copy working folder to ActiveBundle/{alias} for app access
        let activeBundleDir = docsURL.appendingPathComponent(activeBundleDirName).appendingPathComponent(safeAlias)
        try? fm.createDirectory(at: activeBundleDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: activeBundleDir.path) {
            try? fm.removeItem(at: activeBundleDir)
        }
        try fm.copyItem(at: tempExtract, to: activeBundleDir)
        log.debug("Copied extracted folder to persistent ActiveBundle/\(safeAlias, privacy: .public)")

        do {
            try ensureParentNotesColumn(dbPath: activeBundleDir.appendingPathComponent("db.sqlite").path)
        } catch {
            log.warning("ensureParentNotesColumn(active copy) failed: \(error.localizedDescription)")
        }

        // Temp extract no longer needed after copying to ActiveBundle; remove it.
        cleanupTempArtifacts(tempZip, tempExtract)

        // Save an import metadata file next to the copied zip
        let importMetadata: [String: Any] = [
            "importedAt": ISO8601DateFormatter().string(from: Date()),
            "sourceZip": zipURL.path,
            "alias": alias,
            "dob": dob
        ]

        // Always update import metadata before copying the zip
        let metadataURL = bundlesDir.appendingPathComponent(destinationZipPath.lastPathComponent + ".import.json")
        if let metadataData = try? JSONSerialization.data(withJSONObject: importMetadata, options: [.prettyPrinted]) {
            try? metadataData.write(to: metadataURL)
            log.debug("Wrote updated import metadata to: \(metadataURL.lastPathComponent, privacy: .public)")
        }

        // Copy the zip into Bundles (overwrite after possibly archiving existing zip)
        if fm.fileExists(atPath: destinationZipPath.path) {
            // if already exists and not identical timestamp, archive existing
            let archiveDir = bundlesDir.appendingPathComponent(archiveDirName)
            try? fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
            let archivedZip = archiveDir.appendingPathComponent("\(UUID().uuidString)-\(destinationZipPath.lastPathComponent)")
            try? fm.moveItem(at: destinationZipPath, to: archivedZip)
            log.debug("Archived existing ZIP to: \(archivedZip.lastPathComponent, privacy: .public)")
        }
        try fm.copyItem(at: zipURL, to: destinationZipPath)

        // Persist last-loaded info in UserDefaults
        UserDefaults.standard.set(destinationZipPath.path, forKey: "lastLoadedBundleZipPath")
        UserDefaults.standard.set(safeAlias, forKey: "lastLoadedWorkingFolderName")

        log.info("Import completed for \(safeAlias, privacy: .public) in \(Date().timeIntervalSince(start), privacy: .public)s")
        log.debug("Imported and activated bundle at: \(activeBundleDir.path, privacy: .public)")
        return (activeBundleDir, alias, dob)
    }

    // MARK: - View
    var body: some View {
        VStack {
            Button("📦 Import .peMR.zip Bundle") {
                isImporterPresented = true
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [UTType.zip],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let zipURL = urls.first {
                        log.info("User selected bundle: \(zipURL.lastPathComponent, privacy: .public)")
                        Task {
                            do {
                                let (folder, alias, dob) = try await BundleImporter.importBundle(from: zipURL)
                                await MainActor.run {
                                    extractedFolderURL = folder
                                    bundleAlias = alias
                                    bundleDOB = dob
                                }
                            } catch {
                                await MainActor.run {
                                    importError = "❌ Import failed: \(error.localizedDescription)"
                                }
                            }
                        }
                    }
                case .failure(let error):
                    importError = "❌ Failed to import: \(error.localizedDescription)"
                }
            }

            if let extracted = extractedFolderURL {
                Text("✅ Bundle extracted to: \(extracted.lastPathComponent)")
                    .font(.caption)
                    .foregroundColor(.green)
            }

            if let error = importError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding()
    }
}


/// Ensure `patients.parent_notes` column exists; add it if missing (self-healing migration).
func ensureParentNotesColumn(dbPath: String) throws {
    var db: OpaquePointer?
    if sqlite3_open(dbPath, &db) != SQLITE_OK {
        let err = db != nil ? String(cString: sqlite3_errmsg(db)) : "unknown"
        if db != nil { sqlite3_close(db) }
        throw NSError(domain: "BundleImporter", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unable to open DB for migration: \(err)"])
    }
    // Avoid transient "database is locked" during quick migrations
    _ = sqlite3_busy_timeout(db, 2000)
    defer { sqlite3_close(db) }

    var hasParentNotes = false
    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(db, "PRAGMA table_info(patients);", -1, &stmt, nil) == SQLITE_OK {
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cName = sqlite3_column_text(stmt, 1) {
                let name = String(cString: cName)
                if name == "parent_notes" {
                    hasParentNotes = true
                    break
                }
            }
        }
    }

    if !hasParentNotes {
        let alterSQL = "ALTER TABLE patients ADD COLUMN parent_notes TEXT NOT NULL DEFAULT '';"
        if sqlite3_exec(db, alterSQL, nil, nil, nil) != SQLITE_OK {
            let errMsg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "BundleImporter", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed adding parent_notes column: \(errMsg)"])
        } else {
            log.debug("Added missing parent_notes column at \(dbPath, privacy: .public)")
        }
    } else {
        // Already present; nothing to do.
        // print("[DEBUG] parent_notes column already present for \(dbPath)")
    }
}


// MARK: - Helper Functions (moved outside BundleImporter)
func readAliasAndDOB(fromDBAt dbPath: String) throws -> (String, String) {
    var db: OpaquePointer?
    var alias = ""
    var dob = ""
    if sqlite3_open(dbPath, &db) == SQLITE_OK {
        defer { sqlite3_close(db) }
        let query = "SELECT alias_label, dob FROM patients LIMIT 1"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                if let cAlias = sqlite3_column_text(stmt, 0) {
                    alias = String(cString: cAlias)
                }
                if let cDOB = sqlite3_column_text(stmt, 1) {
                    dob = String(cString: cDOB)
                }
            }
        }
    } else {
        throw NSError(domain: "BundleImporter", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to open DB at \(dbPath)"])
    }
    log.debug("Read alias: \(alias, privacy: .public), dob: \(dob, privacy: .public)")
    return (alias, dob)
}

func sanitizeFileName(_ name: String) -> String {
    let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
    let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Run PRAGMA integrity_check and throw if the result is not "ok".
func runIntegrityCheckOrThrow(dbPath: String) throws {
    var db: OpaquePointer?
    if sqlite3_open(dbPath, &db) != SQLITE_OK {
        let err = db != nil ? String(cString: sqlite3_errmsg(db)) : "unknown"
        if db != nil { sqlite3_close(db) }
        throw NSError(domain: "DBIntegrity", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to open DB for integrity_check: \(err)"])
    }
    // Avoid transient "database is locked" while checking integrity
    _ = sqlite3_busy_timeout(db, 2000)
    defer { sqlite3_close(db) }

    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &stmt, nil) != SQLITE_OK {
        let err = String(cString: sqlite3_errmsg(db))
        throw NSError(domain: "DBIntegrity", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to run integrity_check: \(err)"])
    }
    defer { sqlite3_finalize(stmt) }

    var results: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        if let cStr = sqlite3_column_text(stmt, 0) {
            results.append(String(cString: cStr))
        }
    }

    // Successful integrity_check returns exactly one row: "ok"
    if results.count != 1 || results.first?.lowercased() != "ok" {
        let msg = results.isEmpty ? "unknown error" : results.joined(separator: "; ")
        throw NSError(domain: "DBIntegrity", code: 3, userInfo: [NSLocalizedDescriptionKey: "integrity_check failed: \(msg)"])
    }
}
