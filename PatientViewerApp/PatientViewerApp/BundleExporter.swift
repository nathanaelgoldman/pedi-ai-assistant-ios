//
//  BundleExporter.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/14/25.
//



import Foundation
import SQLite

struct BundleExporter {
    private static func removeIfExists(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) } catch {
                print("[WARN] Could not remove existing item at \(url.path): \(error)")
            }
        }
    }
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
            print("[DEBUG] Attempting to open database at: \(dbURL.path)")
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
            print("[ERROR] Failed to read patient info from db: \(error)")
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

        var includesDocs = false
        if FileManager.default.fileExists(atPath: docsURL.path) {
            let targetDocs = bundleFolder.appendingPathComponent("docs")
            try FileManager.default.copyItem(at: docsURL, to: targetDocs)
            includesDocs = true
        }

        let manifest: [String: Any] = [
            "format": "peMR",
            "version": 1,
            "encrypted": false,
            "exported_at": timestamp,
            "source": "patient_viewer_app",
            "includes_docs": includesDocs,
            "patient_id": pid,
            "patient_alias": aliasLabel,
            "dob": dob,
            "patient_sex": sex ?? ""
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
        print("[DEBUG] Export zip ready at: \(zipOutputURL.path)")

        return zipOutputURL
    }
}
