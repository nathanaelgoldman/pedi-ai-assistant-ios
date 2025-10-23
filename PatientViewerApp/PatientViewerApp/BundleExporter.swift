//
//  BundleExporter.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/14/25.
//



import Foundation
import SQLite
import CryptoKit
import ZIPFoundation
import os

struct BundleExporter {
    // Unified logger for this component
    private static let log = Logger(subsystem: "Yunastic.PatientViewerApp", category: "BundleExporter")
    /// Compute SHA-256 hex digest of a file on disk (streaming).
    private static func sha256Hex(ofFile url: URL) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw NSError(domain: "BundleExport", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Unable to open input stream for \(url.path)"])
        }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024 // 1 MB
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read < 0 {
                throw stream.streamError ?? NSError(domain: "BundleExport", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Stream read error for \(url.path)"])
            }
            if read == 0 { break }
            hasher.update(data: Data(buffer[0..<read]))
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    private static func removeIfExists(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) } catch {
                log.warning("Could not remove existing item at \(url, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    /// Return an array of `{ "path": relativePath, "sha256": hex }` entries for all regular files under `folder`.
    private static func docsFileHashes(in folder: URL) throws -> [[String: String]] {
        var results: [[String: String]] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return results
        }
        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }
            let relPath = fileURL.path.replacingOccurrences(of: folder.path + "/", with: "")
            let hex = try sha256Hex(ofFile: fileURL)
            results.append(["path": relPath, "sha256": hex])
        }
        return results
    }

    /// Run PRAGMA integrity_check and return true iff "ok".
    private static func integrityCheckOK(dbPath: String) -> Bool {
        do {
            let db = try Connection(dbPath)
            if let res = try db.scalar("PRAGMA integrity_check") as? String {
                return res.lowercased() == "ok"
            }
        } catch {
            log.warning("PRAGMA integrity_check failed to run: \(error.localizedDescription, privacy: .public)")
        }
        return false
    }

    /// Run PRAGMA foreign_key_check and return true iff there are no violations (no rows returned).
    private static func foreignKeyCheckOK(dbPath: String) -> Bool {
        do {
            let db = try Connection(dbPath)
            // Ensure the pragma is enabled for the session (harmless if already on)
            try? db.execute("PRAGMA foreign_keys = ON")
            var hasViolations = false
            for _ in try db.prepare("PRAGMA foreign_key_check") {
                hasViolations = true
                break
            }
            return !hasViolations
        } catch {
            log.warning("PRAGMA foreign_key_check failed to run: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Attempt a lightweight repair on a SQLite DB (checkpoint WAL and VACUUM).
    private static func attemptRepair(dbPath: String) {
        do {
            let db = try Connection(dbPath)
            // These may fail on small DBs; that's fine.
            try? db.execute("PRAGMA wal_checkpoint(FULL)")
            try? db.execute("VACUUM")
        } catch {
            log.warning("attemptRepair could not open db: \(error.localizedDescription, privacy: .public)")
        }
    }
    /// Replace spaces/emoji/unsafe chars with underscores for a safe file/dir name.
    /// Replace spaces/emoji/unsafe chars with underscores for a safe file/dir name.
    static func sanitizedSlug(_ raw: String) -> String {
        // Normalize and strip diacritics
        let decomposed = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        // Allow only ASCII alphanumerics plus dash/underscore; replace others with "_"
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let mapped = decomposed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        var slug = String(mapped)
        // Collapse multiple underscores
        slug = slug.replacingOccurrences(of: #"_{2,}"#, with: "_", options: .regularExpression)
        // Trim leading/trailing separators
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        // Ensure non-empty
        return slug.isEmpty ? "export" : slug
    }
    static func exportBundle(from folderURL: URL) async throws -> URL {
        let dbURL = folderURL.appendingPathComponent("db.sqlite")
        let docsURL = folderURL.appendingPathComponent("docs")
        let exportsDir = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)

        try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())

        var patientID: Int64?
        var aliasLabel = "Unknown"
        var dob = "Unknown"
        var sex: String? = nil

        do {
            BundleExporter.log.debug("Attempting to open database at: \(dbURL.path, privacy: .public)")
            let db = try Connection(dbURL.path)
            let patients = Table("patients")
            let idCol = Expression<Int64>("id")
            let aliasCol = Expression<String?>("alias_label")
            let dobCol = Expression<String?>("dob")
            let sexCol = Expression<String?>("sex")

            if let row = try db.pluck(patients.limit(1)) {
                patientID = try row.get(idCol)
                aliasLabel = try row.get(aliasCol) ?? "Unknown"
                dob = try row.get(dobCol) ?? "Unknown"
                sex = try row.get(sexCol)
            }
        } catch {
            BundleExporter.log.error("Failed to read patient info from db: \(error.localizedDescription, privacy: .public)")
        }

        guard let pid = patientID else {
            throw NSError(domain: "BundleExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing patient ID"])
        }

        let safeAlias = sanitizedSlug(aliasLabel)
        let bundleFolderName = "\(safeAlias)-\(timestamp)-patientviewer"
        let bundleFolder = exportsDir.appendingPathComponent(bundleFolderName, isDirectory: true)

        // Ensure a clean working folder
        removeIfExists(bundleFolder)
        try FileManager.default.createDirectory(at: bundleFolder, withIntermediateDirectories: true)

        try FileManager.default.copyItem(at: dbURL, to: bundleFolder.appendingPathComponent("db.sqlite"))
        let dbFileInBundle = bundleFolder.appendingPathComponent("db.sqlite")

        // Validate DB health and attempt a safe repair on the export copy
        if !integrityCheckOK(dbPath: dbFileInBundle.path) {
            BundleExporter.log.warning("integrity_check failed on export copy — attempting VACUUM repair…")
            attemptRepair(dbPath: dbFileInBundle.path)
            guard integrityCheckOK(dbPath: dbFileInBundle.path) else {
                throw NSError(domain: "BundleExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "SQLite integrity_check failed for export copy."])
            }
        }

        // Also validate foreign key consistency — this catches orphan rows missed by integrity_check
        if !foreignKeyCheckOK(dbPath: dbFileInBundle.path) {
            BundleExporter.log.error("foreign_key_check failed for export copy — aborting export.")
            throw NSError(domain: "BundleExport", code: 3, userInfo: [NSLocalizedDescriptionKey: "SQLite foreign_key_check failed for export copy."])
        }

        // Compute db.sqlite hash for manifest after normalization
        let dbSha256 = try sha256Hex(ofFile: dbFileInBundle)

        var includesDocs = false
        var docsManifest: [[String: String]] = []
        if FileManager.default.fileExists(atPath: docsURL.path) {
            let targetDocs = bundleFolder.appendingPathComponent("docs")
            try FileManager.default.copyItem(at: docsURL, to: targetDocs)
            includesDocs = true
            // Compute per-file hashes for docs
            docsManifest = try docsFileHashes(in: targetDocs)
        }

        let manifest: [String: Any] = [
            "format": "peMR",
            "version": 1,                      // legacy key for older importers
            "schema_version": 2,               // bumped schema when hashes were added
            "encrypted": false,
            "exported_at": timestamp,
            "source": "patient_viewer_app",
            "includes_docs": includesDocs,
            "patient_id": pid,
            "patient_alias": aliasLabel,
            "dob": dob,
            "patient_sex": sex ?? "",
            // Integrity fields
            "db_sha256": dbSha256,
            "docs_manifest": docsManifest     // array of { path, sha256 } if any
        ]

        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted)
        try manifestData.write(to: bundleFolder.appendingPathComponent("manifest.json"))

        // Prepare zip output
        let zipOutputURL = exportsDir.appendingPathComponent("\(bundleFolderName).peMR.zip")

        // Overwrite old zip if present
        removeIfExists(zipOutputURL)

        // Create zip (no preview/open here)
        try FileManager.default.zipItem(at: bundleFolder, to: zipOutputURL, shouldKeepParent: false)

        // Clean up working directory to avoid clutter
        removeIfExists(bundleFolder)

        // Log without using file:// scheme to keep logs tidy
        BundleExporter.log.info("Export zip ready at: \(zipOutputURL.path, privacy: .public)")

        return zipOutputURL
    }
}
