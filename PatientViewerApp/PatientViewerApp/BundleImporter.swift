import Foundation
import SQLite3
import SwiftUI
import ZIPFoundation
import UniformTypeIdentifiers

let bundlesDirectoryName = "Bundles"
let activeBundleDirName = "ActiveBundle"
let archiveDirName = "ArchivedZips"

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
        let expectedManifest = tempExtract.appendingPathComponent("docs/manifest.json")
        guard fm.fileExists(atPath: expectedDB.path), fm.fileExists(atPath: expectedManifest.path) else {
            // Cleanup temp items before throwing
            try? fm.removeItem(at: tempZip)
            try? fm.removeItem(at: tempExtract)
            throw NSError(domain: "BundleImporter", code: 3, userInfo: [NSLocalizedDescriptionKey: "❌ Extracted bundle is missing required files."])
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
        print("[DEBUG] ✅ Saved persistent bundle to: \(persistentFolder.path)")

        // Check if a persistent ActiveBundle already exists for this alias
        let persistentBundlePath = docsURL.appendingPathComponent(activeBundleDirName).appendingPathComponent(safeAlias)
        if fm.fileExists(atPath: persistentBundlePath.path), force == false {
            print("[DEBUG] ✅ Found existing ActiveBundle at \(persistentBundlePath.path), skipping re-import.")
            print("[DEBUG] ⛔ Fallback to previously extracted unzipped version triggered (re-import skipped).")
            UserDefaults.standard.set(persistentBundlePath.path, forKey: "lastLoadedBundleZipPath")
            UserDefaults.standard.set(persistentBundlePath.lastPathComponent, forKey: "lastLoadedWorkingFolderName")
            return (persistentBundlePath, alias, dob)
        }

        // Insert debug logs for DB path verification
        print("[🔍DEBUG] Preparing ActiveBundle path for \(safeAlias)")

        // Copy working folder to ActiveBundle/{alias} for app access
        let activeBundleDir = docsURL.appendingPathComponent(activeBundleDirName).appendingPathComponent(safeAlias)
        try? fm.createDirectory(at: activeBundleDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: activeBundleDir.path) {
            try? fm.removeItem(at: activeBundleDir)
        }
        try fm.copyItem(at: tempExtract, to: activeBundleDir)
        print("[DEBUG] Copied extracted folder to persistent ActiveBundle/\(safeAlias)")

        // Temp extract no longer needed after copying to ActiveBundle; remove it.
        try? fm.removeItem(at: tempExtract)

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
            print("[DEBUG] Wrote updated import metadata to: \(metadataURL.lastPathComponent)")
        }

        // Copy the zip into Bundles (overwrite after possibly archiving existing zip)
        if fm.fileExists(atPath: destinationZipPath.path) {
            // if already exists and not identical timestamp, archive existing
            let archiveDir = bundlesDir.appendingPathComponent(archiveDirName)
            try? fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
            let archivedZip = archiveDir.appendingPathComponent("\(UUID().uuidString)-\(destinationZipPath.lastPathComponent)")
            try? fm.moveItem(at: destinationZipPath, to: archivedZip)
            print("[DEBUG] Archived existing ZIP to: \(archivedZip.lastPathComponent)")
        }
        try fm.copyItem(at: zipURL, to: destinationZipPath)

        // Persist last-loaded info in UserDefaults
        UserDefaults.standard.set(destinationZipPath.path, forKey: "lastLoadedBundleZipPath")
        UserDefaults.standard.set(safeAlias, forKey: "lastLoadedWorkingFolderName")

        print("[DEBUG] Imported and activated bundle at: \(activeBundleDir.path)")
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
                        Task {
                            do {
                                let (folder, alias, dob) = try await BundleImporter.importBundle(from: zipURL)
                                DispatchQueue.main.async {
                                    extractedFolderURL = folder
                                    bundleAlias = alias
                                    bundleDOB = dob
                                }
                            } catch {
                                DispatchQueue.main.async {
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
    print("[DEBUG] Read alias: \(alias), dob: \(dob)")
    return (alias, dob)
}

func sanitizeFileName(_ name: String) -> String {
    let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
    let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
}
