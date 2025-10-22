//
//  BundleLibraryView.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/15/25.
//


import SwiftUI
import Foundation
import ZIPFoundation
import SQLite3
import UniformTypeIdentifiers
import CryptoKit

// Single source of truth for the currently active bundle location.
struct ActiveBundleLocator {
    private static let key = "ActiveBundleBaseURL"
    static func setCurrentBaseURL(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: key)
    }
    static func currentBaseURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

enum BundleIO {

    struct Identity {
        let alias: String
        let name: String?
        let dob: String?
        let patientId: Int?
        let patientKey: String
        let slug: String
    }

    struct Pending {
        let zipURL: URL
        let tempRoot: URL
        let identity: Identity
        let destinationURL: URL
        let existingURL: URL
    }

    struct Activation {
        let activeBase: URL
        let alias: String
        let dob: String?
    }

    enum Outcome {
        case needsOverwrite(Pending)
        case activated(Activation)
    }

    enum ImportService {

        // MARK: Public API

        /// Call this from .fileImporter in any view (e.g., ContentView).
        static func handleZipImport(_ url: URL) throws -> Outcome {
            let fm = FileManager.default
            ensureBaseDirectories()
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            let tempDir = docs.appendingPathComponent("ImportTemp", isDirectory: true)

            if fm.fileExists(atPath: tempDir.path) { try? fm.removeItem(at: tempDir) }
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

            // SAFETY: Work on a local COPY of the ZIP so we never touch/delete the user's original file.
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            let localZipCopy = tempDir.appendingPathComponent("_import-\(UUID().uuidString).zip")
            try fm.copyItem(at: url, to: localZipCopy)
            try fm.unzipItem(at: localZipCopy, to: tempDir)

            // Determine the extracted root that actually contains the bundle
            let root = findExtractedRoot(in: tempDir, zipURL: url)
            print("[DEBUG] 📂 Selected extracted root: \(root.path)")

            let identity = try extractIdentity(from: root)
            try validateBundleDB(at: root)
            let persistentBase = docs.appendingPathComponent("PersistentBundles", isDirectory: true)
            let dest = persistentBase.appendingPathComponent(identity.slug, isDirectory: true)

            if let existing = existingBundleForPatientKey(identity.patientKey) {
                return .needsOverwrite(Pending(zipURL: url, tempRoot: root, identity: identity, destinationURL: dest, existingURL: existing))
            }

            // New patient: copy in and activate
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: root, to: dest)
            writeBundleMeta(to: dest, from: url, rootExtractedURL: root, identity: identity)
            let activation = try activatePersistentBundle(at: dest)
            // cleanup only our ImportTemp
            safelyRemoveImportTemp(for: root)
            return .activated(activation)
        }

        /// Call this after user confirms overwrite in the duplicate dialog.
        static func confirmOverwrite(_ pending: Pending) throws -> Activation {
            try archiveExistingAndReplace(existingURL: pending.existingURL,
                                          newRoot: pending.tempRoot,
                                          dest: pending.destinationURL,
                                          zipURL: pending.zipURL,
                                          identity: pending.identity)
        }

        /// Call this if user cancels overwrite.
        static func cancelOverwrite(_ pending: Pending) {
            safelyRemoveImportTemp(for: pending.tempRoot)
        }

        // MARK: Shared helpers (ported from BundleLibraryView)

        private static func ensureBaseDirectories() {
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            for name in ["PersistentBundles", "ActiveBundle", "PersistentBundlesArchive"] {
                let dir = docs.appendingPathComponent(name, isDirectory: true)
                if !fm.fileExists(atPath: dir.path) {
                    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                }
            }
        }

        // Heuristic to pick the correct extracted root that actually contains the bundle (db.sqlite + docs)
        private static func findExtractedRoot(in tempDir: URL, zipURL: URL) -> URL {
            let fm = FileManager.default

            // 0) If db.sqlite is directly under tempDir, use tempDir
            if fm.fileExists(atPath: tempDir.appendingPathComponent("db.sqlite").path) {
                return tempDir
            }

            // 1) Collect immediate subdirectories (skip hidden)
            let items = (try? fm.contentsOfDirectory(
                at: tempDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let dirs: [URL] = items.filter { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }

            // Helper to test whether a folder contains db.sqlite anywhere inside it
            func folderContainsDB(_ url: URL) -> Bool {
                if fm.fileExists(atPath: url.appendingPathComponent("db.sqlite").path) { return true }
                if let e = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                    for case let u as URL in e where u.lastPathComponent == "db.sqlite" { return true }
                }
                return false
            }

            // 2) Prefer a folder that actually contains db.sqlite (directly or nested)
            if let hit = dirs.first(where: { folderContainsDB($0) }) {
                return hit
            }

            // 3) Prefer a folder whose name matches the zip's basename
            let baseName = zipURL.deletingPathExtension().lastPathComponent
            if let match = dirs.first(where: { $0.lastPathComponent.localizedCaseInsensitiveContains(baseName) }) {
                return match
            }

            // 4) If there is exactly one directory, take it
            if dirs.count == 1, let only = dirs.first { return only }

            // 5) As a last resort, try to find db.sqlite anywhere under tempDir and return its parent
            if let e = fm.enumerator(at: tempDir, includingPropertiesForKeys: nil) {
                for case let u as URL in e where u.lastPathComponent == "db.sqlite" { return u.deletingLastPathComponent() }
            }

            // 6) Fallback to tempDir (validation will fail with a clear error if this is wrong)
            return tempDir
        }

        // Validate that the imported bundle contains a usable db.sqlite with a patients table and at least one row.
        private static func validateBundleDB(at root: URL) throws {
            let fm = FileManager.default
            var dbURL = root.appendingPathComponent("db.sqlite")
            if !fm.fileExists(atPath: dbURL.path) {
                if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
                    for case let u as URL in e where u.lastPathComponent == "db.sqlite" {
                        dbURL = u
                        break
                    }
                }
            }
            guard fm.fileExists(atPath: dbURL.path) else {
                throw NSError(domain: "BundleIO", code: 100, userInfo: [NSLocalizedDescriptionKey: "db.sqlite not found in imported bundle"])
            }

            var db: OpaquePointer?
            guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
                throw NSError(domain: "BundleIO", code: 101, userInfo: [NSLocalizedDescriptionKey: "Unable to open SQLite database"])
            }
            defer { sqlite3_close(db) }

            // Check that the patients table exists
            var stmt: OpaquePointer?
            let tableQuery = "SELECT name FROM sqlite_master WHERE type='table' AND name='patients' LIMIT 1;"
            guard sqlite3_prepare_v2(db, tableQuery, -1, &stmt, nil) == SQLITE_OK else {
                throw NSError(domain: "BundleIO", code: 102, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare validation query"])
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw NSError(domain: "BundleIO", code: 103, userInfo: [NSLocalizedDescriptionKey: "Invalid bundle: missing 'patients' table"])
            }

            // Ensure there is at least one row
            var stmt2: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM patients;", -1, &stmt2, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt2) }
                if sqlite3_step(stmt2) == SQLITE_ROW {
                    let count = sqlite3_column_int(stmt2, 0)
                    if count <= 0 {
                        throw NSError(domain: "BundleIO", code: 104, userInfo: [NSLocalizedDescriptionKey: "Invalid bundle: empty 'patients' table"])
                    }
                }
            }
        }

        // MARK: - Identity helpers
        private static func computePatientKey(alias: String?, dob: String?, patientId: Int?) -> String {
            if let pid = patientId { return "pid:\(pid)" }
            let a = (alias ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let d = (dob ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = "\(a)|\(d)"
            let digest = Insecure.SHA1.hash(data: Data(raw.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }

        private static func sanitizedAlias(_ input: String) -> String {
            let allowed = CharacterSet.alphanumerics
                .union(.whitespacesAndNewlines)
                .union(CharacterSet(charactersIn: "-_()"))
            let filteredScalars = input.unicodeScalars.filter { allowed.contains($0) }
            var s = String(String.UnicodeScalarView(filteredScalars))
            // Collapse runs of whitespace to a single space
            s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            // Trim surrounding whitespace
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            // Trim leading/trailing underscores or dashes
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
            // Collapse repeated separators like "__" or "--"
            s = s.replacingOccurrences(of: "[\\-_]{2,}", with: "-", options: .regularExpression)
            return s.isEmpty ? "Patient" : s
        }

        private static func extractIdentity(from root: URL) throws -> Identity {
            let (alias, name, dob, pid) = try readIdentity(from: root)
            let key = computePatientKey(alias: alias, dob: dob, patientId: pid)
            let slug = sanitizedAlias(alias.isEmpty ? root.lastPathComponent : alias)
            return Identity(alias: alias, name: name, dob: dob, patientId: pid, patientKey: key, slug: slug)
        }

        private static func existingBundleForPatientKey(_ key: String) -> URL? {
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            let base = docs.appendingPathComponent("PersistentBundles", isDirectory: true)
            guard let contents = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                return nil
            }
            for folder in contents {
                let isDir = (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                // Prefer sidecar key match first
                let metaURL = folder.appendingPathComponent(".bundle-meta.json")
                if let data = try? Data(contentsOf: metaURL),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let k = json["patientKey"] as? String, k == key {
                    return folder
                }
                // Fallback: compute from this folder's DB
                if let info = try? readIdentity(from: folder) {
                    let k2 = computePatientKey(alias: info.alias, dob: info.dob, patientId: info.patientId)
                    if k2 == key { return folder }
                }
            }
            return nil
        }

        private static func readIdentity(from folder: URL) throws -> (alias: String, name: String?, dob: String?, patientId: Int?) {
            let fm = FileManager.default
            var dbURL = folder.appendingPathComponent("db.sqlite")
            if !fm.fileExists(atPath: dbURL.path) {
                if let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil) {
                    for case let u as URL in e where u.lastPathComponent == "db.sqlite" { dbURL = u; break }
                }
            }
            guard fm.fileExists(atPath: dbURL.path) else {
                throw NSError(domain: "BundleIO", code: 2, userInfo: [NSLocalizedDescriptionKey: "db.sqlite not found in imported bundle"]) }

            var db: OpaquePointer?
            var alias = ""
            var dob: String? = nil
            var first: String? = nil
            var last: String? = nil
            var pid: Int32 = -1

            if sqlite3_open(dbURL.path, &db) == SQLITE_OK {
                defer { sqlite3_close(db) }
                let wideQuery = "SELECT id, alias_label, dob, first_name, last_name FROM patients LIMIT 1;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, wideQuery, -1, &stmt, nil) == SQLITE_OK {
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        pid = sqlite3_column_int(stmt, 0)
                        if let aliasC = sqlite3_column_text(stmt, 1) { alias = String(cString: aliasC) }
                        if let dobC = sqlite3_column_text(stmt, 2) { dob = String(cString: dobC) }
                        if let fC = sqlite3_column_text(stmt, 3) { first = String(cString: fC) }
                        if let lC = sqlite3_column_text(stmt, 4) { last = String(cString: lC) }
                    }
                    sqlite3_finalize(stmt)
                } else {
                    let fallback = "SELECT id, alias_label, dob FROM patients LIMIT 1;"
                    if sqlite3_prepare_v2(db, fallback, -1, &stmt, nil) == SQLITE_OK {
                        if sqlite3_step(stmt) == SQLITE_ROW {
                            pid = sqlite3_column_int(stmt, 0)
                            if let aliasC = sqlite3_column_text(stmt, 1) { alias = String(cString: aliasC) }
                            if let dobC = sqlite3_column_text(stmt, 2) { dob = String(cString: dobC) }
                        }
                        sqlite3_finalize(stmt)
                    }
                }
            }

            var name: String? = nil
            if let f = first, let l = last, !(f.isEmpty && l.isEmpty) {
                name = [f, l].compactMap { $0 }.joined(separator: " ")
            } else if let f = first, !f.isEmpty {
                name = f
            } else if let l = last, !l.isEmpty {
                name = l
            }
            let idOpt: Int? = pid >= 0 ? Int(pid) : nil
            return (alias, name, dob, idOpt)
        }

        private static func writeBundleMeta(to persistentFolder: URL, from zipURL: URL, rootExtractedURL: URL, identity: Identity) {
            func isoString(_ date: Date) -> String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return f.string(from: date)
            }

            func parseISODateLoose(_ s: String) -> Date? {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = iso.date(from: s) { return d }
                let iso2 = ISO8601DateFormatter()
                iso2.formatOptions = [.withInternetDateTime]
                if let d = iso2.date(from: s) { return d }
                let fmts = [
                    "yyyy-MM-dd'T'HH:mm:ssXXXXX",
                    "yyyy-MM-dd'T'HH:mm:ss",
                    "yyyy-MM-dd"
                ]
                for f in fmts {
                    let df = DateFormatter()
                    df.locale = Locale(identifier: "en_US_POSIX")
                    df.dateFormat = f
                    if let d = df.date(from: s) { return d }
                }
                return nil
            }

            func parseDateFromZipBasename(_ basename: String) -> Date? {
                // Expect pattern like  Alias-YYYYMMDD-HHMMSS-patientviewer.peMR.zip[.import.json]
                let pattern = "-([0-9]{8})-([0-9]{6})-"
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
                let range = NSRange(basename.startIndex..<basename.endIndex, in: basename)
                guard let match = regex.firstMatch(in: basename, options: [], range: range) else { return nil }
                guard let r1 = Range(match.range(at: 1), in: basename),
                      let r2 = Range(match.range(at: 2), in: basename) else { return nil }
                let datePart = String(basename[r1])
                let timePart = String(basename[r2])
                let combined = "\(datePart)-\(timePart)"
                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.dateFormat = "yyyyMMdd-HHmmss"
                return fmt.date(from: combined)
            }

            var meta: [String: Any] = [:]
            meta["patientKey"] = identity.patientKey
            meta["alias"] = identity.alias
            if let name = identity.name { meta["name"] = name }
            if let dob = identity.dob { meta["dob"] = dob }
            if let pid = identity.patientId { meta["patientId"] = pid }

            meta["importedAt"] = isoString(Date())
            meta["originalZipName"] = zipURL.lastPathComponent

            let manifestURL = rootExtractedURL.appendingPathComponent("docs").appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: manifestURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let keys = ["bundleCreatedAt", "createdAt", "creationDate", "exportedAt", "created", "timestamp"]
                for key in keys {
                    if let s = json[key] as? String, let d = parseISODateLoose(s) { meta["createdAt"] = isoString(d); break }
                    if let n = json[key] as? NSNumber { meta["createdAt"] = isoString(Date(timeIntervalSince1970: n.doubleValue)); break }
                }
                if meta["createdAt"] == nil, let metaObj = json["metadata"] as? [String: Any] {
                    let keys2 = ["createdAt", "creationDate", "exportedAt", "timestamp"]
                    for key in keys2 {
                        if let s = metaObj[key] as? String, let d = parseISODateLoose(s) { meta["createdAt"] = isoString(d); break }
                        if let n = metaObj[key] as? NSNumber { meta["createdAt"] = isoString(Date(timeIntervalSince1970: n.doubleValue)); break }
                    }
                }
            }
            if meta["createdAt"] == nil, let d = parseDateFromZipBasename(zipURL.lastPathComponent) {
                meta["createdAt"] = isoString(d)
            }

            let metaURL = persistentFolder.appendingPathComponent(".bundle-meta.json")
            if let out = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) {
                try? out.write(to: metaURL, options: .atomic)
            }
        }

        private static func activatePersistentBundle(at url: URL) throws -> Activation {
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            let activeBundleURL = docs.appendingPathComponent("ActiveBundle", isDirectory: true)
            let activeAliasURL = activeBundleURL.appendingPathComponent(url.lastPathComponent, isDirectory: true)

            // Ensure base directories
            ensureBaseDirectories()

            // Clean previous ActiveBundle contents for this alias but keep the parent folder
            if fm.fileExists(atPath: activeAliasURL.path) {
                try? fm.removeItem(at: activeAliasURL)
            }

            // Determine the directory inside the persistent bundle that actually contains db.sqlite
            var sourceBase = url
            if !fm.fileExists(atPath: url.appendingPathComponent("db.sqlite").path) {
                if let e = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                    for case let u as URL in e where u.lastPathComponent == "db.sqlite" {
                        sourceBase = u.deletingLastPathComponent()
                        break
                    }
                }
            }

            // Copy ONLY the directory that contains db.sqlite so that db.sqlite ends up at ActiveBundle/<alias>/db.sqlite
            try fm.copyItem(at: sourceBase, to: activeAliasURL)

            // Verify db.sqlite is at the root of ActiveBundle/<alias>
            var activeDBBase = activeAliasURL
            if !fm.fileExists(atPath: activeAliasURL.appendingPathComponent("db.sqlite").path) {
                // Fallback: locate it and point base there if it is still nested for any reason
                if let e = fm.enumerator(at: activeAliasURL, includingPropertiesForKeys: nil) {
                    for case let u as URL in e where u.lastPathComponent == "db.sqlite" {
                        activeDBBase = u.deletingLastPathComponent()
                        break
                    }
                }
            }
            guard fm.fileExists(atPath: activeDBBase.appendingPathComponent("db.sqlite").path) else {
                throw NSError(domain: "BundleIO", code: 200, userInfo: [NSLocalizedDescriptionKey: "Active bundle missing db.sqlite"])
            }

            // Persist active base for the app to use
            ActiveBundleLocator.setCurrentBaseURL(activeDBBase)

            // read alias/dob to return
            let (alias, _, dob, _) = try readIdentity(from: activeDBBase)
            print("[DEBUG] 📌 Active base set to: \(activeDBBase.path)")
            return Activation(activeBase: activeDBBase, alias: alias, dob: dob)
        }

        private static func safelyRemoveImportTemp(for candidate: URL) {
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            let importTemp = docs.appendingPathComponent("ImportTemp", isDirectory: true)
            // Only delete if we're sure the path lives under Documents/ImportTemp
            if candidate.path.hasPrefix(importTemp.path) {
                try? fm.removeItem(at: importTemp)
            }
        }

        private static func archiveExistingAndReplace(existingURL: URL, newRoot: URL, dest: URL, zipURL: URL, identity: Identity) throws -> Activation {
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            let archiveBase = docs.appendingPathComponent("PersistentBundlesArchive", isDirectory: true)
            if !fm.fileExists(atPath: archiveBase.path) {
                try fm.createDirectory(at: archiveBase, withIntermediateDirectories: true)
            }

            // 1) Stage the new content inside PersistentBundles (atomic swap).
            let staging = dest.deletingLastPathComponent()
                .appendingPathComponent(".staging-\(identity.slug)--\(timestampNowString())", isDirectory: true)
            if fm.fileExists(atPath: staging.path) { try? fm.removeItem(at: staging) }
            try fm.copyItem(at: newRoot, to: staging)
            // Write sidecar metadata into the staged folder (not the original).
            writeBundleMeta(to: staging, from: zipURL, rootExtractedURL: newRoot, identity: identity)

            // 2) Archive the existing bundle.
            let archiveFolder = archiveBase.appendingPathComponent("\(existingURL.lastPathComponent)--\(timestampNowString())", isDirectory: true)
            if fm.fileExists(atPath: archiveFolder.path) { try? fm.removeItem(at: archiveFolder) }
            try fm.moveItem(at: existingURL, to: archiveFolder)

            // 3) Move staged folder into place.
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) } // defensive
            try fm.moveItem(at: staging, to: dest)

            // 4) Activate and return Activation payload.
            let activation = try activatePersistentBundle(at: dest)

            // 5) Clean our own ImportTemp directory only (guarded).
            safelyRemoveImportTemp(for: newRoot)

            // 6) Keep only the most-recent archive per slug.
            let slug = dest.lastPathComponent
            if let archived = try? fm.contentsOfDirectory(at: archiveBase, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                let matching = archived.filter { $0.lastPathComponent.hasPrefix("\(slug)--") }
                if matching.count > 1 {
                    let sorted = matching.sorted { (a, b) -> Bool in
                        let am = ((try? fm.attributesOfItem(atPath: a.path)[.modificationDate]) as? Date) ?? .distantPast
                        let bm = ((try? fm.attributesOfItem(atPath: b.path)[.modificationDate]) as? Date) ?? .distantPast
                        return am > bm
                    }
                    for old in sorted.dropFirst(1) { try? fm.removeItem(at: old) }
                }
            }

            return activation
        }

        private static func timestampNowString() -> String {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyyMMdd-HHmmss"
            return df.string(from: Date())
        }
    }
}

struct SavedBundle: Identifiable, Hashable {
    let id = UUID()
    let folderURL: URL
    let alias: String
    let name: String?
    let dob: String?
    let created: Date?
    let imported: Date?
    let lastSaved: Date?
}

struct PatientIdentity {
    let alias: String
    let name: String?
    let dob: String?
    let patientId: Int?
    let patientKey: String
    let slug: String
}

private struct PendingImport {
    let zipURL: URL
    let tempRoot: URL
    let identity: PatientIdentity
    let destinationURL: URL
    let existingURL: URL
}

struct BundleLibraryView: View {
    @Binding var extractedFolderURL: URL?
    @Binding var bundleAlias: String
    @Binding var bundleDOB: String

    @Environment(\.dismiss) private var dismiss

    @State private var savedBundles: [SavedBundle] = []
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var isImportingZip = false
    @State private var isBusy = false
    @State private var showDeleteConfirm = false
    @State private var pendingDeletion: SavedBundle? = nil
    @State private var showDuplicateImportDialog = false
    @State private var pendingImport: PendingImport? = nil

    var body: some View {
        VStack(alignment: .leading) {
            Text("📚 Saved Patient Bundles")
                .font(.title2)
                .padding(.bottom, 8)

            HStack {
                Button(action: { isImportingZip = true }) {
                    Label("Import .peMR.zip", systemImage: "tray.and.arrow.down")
                }
                .disabled(isBusy)
                Spacer()
            }
            .padding(.bottom, 8)

            if savedBundles.isEmpty {
                Text("No saved bundles found.")
                    .foregroundColor(.gray)
            } else {
                List {
                    ForEach(savedBundles) { bundle in
                        Button(action: {
                            let fileManager = FileManager.default
                            guard fileManager.fileExists(atPath: bundle.folderURL.path) else {
                                alertMessage = "The folder \"\(bundle.folderURL.lastPathComponent)\" no longer exists."
                                showAlert = true
                                return
                            }
                            do {
                                try activatePersistentBundle(at: bundle.folderURL)
                            } catch {
                                alertMessage = "Failed to load bundle: \(error.localizedDescription)"
                                showAlert = true
                            }
                        }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(bundle.alias)
                                    .font(.headline)
                                if let name = bundle.name, !name.isEmpty {
                                    Text(name)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                if let dob = bundle.dob, !dob.isEmpty {
                                    Text("DOB: \(dob)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Text(metaLine(for: bundle))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                pendingDeletion = bundle
                                showDeleteConfirm = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .onAppear { ensureBaseDirectories(); loadPersistentBundles() }
        .fileImporter(isPresented: $isImportingZip, allowedContentTypes: [UTType.zip], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let first = urls.first {
                    handleZipImport(url: first)
                }
            case .failure(let error):
                alertMessage = "Import failed: \(error.localizedDescription)"
                showAlert = true
            }
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text("Error"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog("Delete this saved bundle?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                if let bundle = pendingDeletion {
                    deleteBundle(bundle)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            if let b = pendingDeletion {
                Text("Permanently remove “\(b.alias)”. This deletes it from Saved Bundles and any active copy in ActiveBundle.")
            } else {
                Text("Permanently remove this saved bundle.")
            }
        }
        .confirmationDialog("A bundle for this patient already exists.", isPresented: $showDuplicateImportDialog, titleVisibility: .visible) {
            Button("Overwrite (archive previous)", role: .destructive) {
                guard let pending = pendingImport else { return }
                do {
                    try archiveExistingAndReplace(existingURL: pending.existingURL, newRoot: pending.tempRoot, dest: pending.destinationURL, zipURL: pending.zipURL, identity: pending.identity)
                    pendingImport = nil
                } catch {
                    alertMessage = "Overwrite failed: \(error.localizedDescription)"
                    showAlert = true
                }
            }
            Button("Cancel", role: .cancel) {
                if let pending = pendingImport {
                    safelyRemoveImportTemp(for: pending.tempRoot)
                }
                pendingImport = nil
            }
        } message: {
            if let p = pendingImport {
                Text("Patient: \(p.identity.alias)\nDOB: \(p.identity.dob ?? "—")\nAn existing saved bundle will be archived and replaced if you continue.")
            } else {
                Text("An existing saved bundle will be archived and replaced if you continue.")
            }
        }
    }

    private func loadPersistentBundles() {
        ensureBaseDirectories()
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("PersistentBundles", isDirectory: true)

        guard let contents = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            print("[DEBUG] ⚠️ Failed to list PersistentBundles; keeping previous list.")
            return
        }

        var bundles: [SavedBundle] = []
        for folder in contents {
            let isDir = (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let folderName = folder.lastPathComponent
            guard isDir, !folderName.hasPrefix(".") else { continue }

            let created: Date? = getBundleCreationDate(for: folder)
            let imported = getImportDate(for: folder)

            let dbURL = folder.appendingPathComponent("db.sqlite")
            var lastSaved: Date? = nil
            if let attrs = try? fileManager.attributesOfItem(atPath: dbURL.path), let mod = attrs[.modificationDate] as? Date {
                lastSaved = mod
            }

            // Read alias, name (if available), and DOB from db
            var alias = folder.lastPathComponent
            var name: String? = nil
            var dob: String? = nil
            if let info = try? readAliasDOBAndName(from: folder) {
                alias = info.alias.isEmpty ? alias : info.alias
                name = info.name
                dob = info.dob
            }

            bundles.append(SavedBundle(
                folderURL: folder,
                alias: alias,
                name: name,
                dob: dob,
                created: created,
                imported: imported,
                lastSaved: lastSaved
            ))
        }

        // Sort by lastSaved, then imported, then created (most recent first)
        savedBundles = bundles.sorted { a, b in
            let aKey = a.lastSaved ?? a.imported ?? a.created ?? .distantPast
            let bKey = b.lastSaved ?? b.imported ?? b.created ?? .distantPast
            return aKey > bKey
        }
    }

    private func ensureBaseDirectories() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let persistent = docs.appendingPathComponent("PersistentBundles", isDirectory: true)
        let active = docs.appendingPathComponent("ActiveBundle", isDirectory: true)
        if !fm.fileExists(atPath: persistent.path) {
            try? fm.createDirectory(at: persistent, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: active.path) {
            try? fm.createDirectory(at: active, withIntermediateDirectories: true)
        }
    }

    private func activatePersistentBundle(at url: URL) throws {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let activeBundleURL = documentsURL.appendingPathComponent("ActiveBundle", isDirectory: true)
        let activeAliasURL = activeBundleURL.appendingPathComponent(url.lastPathComponent, isDirectory: true)

        // Ensure base directories
        ensureBaseDirectories()

        // Clean previous ActiveBundle contents for this alias but keep the parent folder
        if fileManager.fileExists(atPath: activeAliasURL.path) {
            try fileManager.removeItem(at: activeAliasURL)
        }

        // Determine the directory inside the persistent bundle that actually contains db.sqlite
        var sourceBase = url
        if !fileManager.fileExists(atPath: url.appendingPathComponent("db.sqlite").path) {
            if let e = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let u as URL in e where u.lastPathComponent == "db.sqlite" {
                    sourceBase = u.deletingLastPathComponent()
                    break
                }
            }
        }

        // Copy ONLY the directory that contains db.sqlite so that db.sqlite ends up at ActiveBundle/<alias>/db.sqlite
        try fileManager.copyItem(at: sourceBase, to: activeAliasURL)

        // Verify/compute the actual active DB base (root that contains db.sqlite)
        var activeDBBase = activeAliasURL
        if !fileManager.fileExists(atPath: activeAliasURL.appendingPathComponent("db.sqlite").path) {
            if let e = fileManager.enumerator(at: activeAliasURL, includingPropertiesForKeys: nil) {
                for case let u as URL in e where u.lastPathComponent == "db.sqlite" {
                    activeDBBase = u.deletingLastPathComponent()
                    break
                }
            }
        }

        guard fileManager.fileExists(atPath: activeDBBase.appendingPathComponent("db.sqlite").path) else {
            throw NSError(domain: "BundleLibraryView", code: 200, userInfo: [NSLocalizedDescriptionKey: "Active bundle missing db.sqlite"])
        }

        // Persist the active base and log
        ActiveBundleLocator.setCurrentBaseURL(activeDBBase)
        print("[DEBUG] 📌 Active base set to: \(activeDBBase.path)")

        // Force UI refresh even if the user re-selects the same patient; then dismiss the sheet.
        extractedFolderURL = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            extractedFolderURL = activeDBBase
            extractPatientInfo(from: activeDBBase)
            dismiss()
        }
    }


    private func getImportDate(for folderURL: URL) -> Date? {
        // 0) Prefer per-bundle sidecar metadata if present
        let sidecar = bundleMetaURL(for: folderURL)
        if let data = try? Data(contentsOf: sidecar),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let s = json["importedAt"] as? String, let d = parseISODateLoose(s) { return d }
            if let n = json["importedAt"] as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        }
        // Prefer a matching .zip.import.json record anywhere under Documents
        let alias = folderURL.lastPathComponent
        if let jsonURL = findImportJSON(near: folderURL.deletingLastPathComponent(), matchingAlias: alias)
            ?? findImportJSONInDocuments(matchingAlias: alias) {
            if let data = try? Data(contentsOf: jsonURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let s = json["importedAt"] as? String, let d = parseISODateLoose(s) { return d }
                if let n = json["importedAt"] as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
            }
        }
        // Fallback: folder creation date
        return try? folderURL.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    private func getBundleCreationDate(for folderURL: URL) -> Date? {
        // 0) Prefer per-bundle sidecar metadata if present
        let sidecar = bundleMetaURL(for: folderURL)
        if let data = try? Data(contentsOf: sidecar),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let s = json["createdAt"] as? String, let d = parseISODateLoose(s) { return d }
            if let n = json["createdAt"] as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        }
        // 1) Try docs/manifest.json inside the bundle
        let manifestURL = folderURL.appendingPathComponent("docs").appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // probe common keys
            let keys = ["bundleCreatedAt", "createdAt", "creationDate", "exportedAt", "created", "timestamp"]
            for key in keys {
                if let s = json[key] as? String, let d = parseISODateLoose(s) { return d }
                if let n = json[key] as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
            }
            // also probe nested values like metadata.createdAt
            if let meta = json["metadata"] as? [String: Any] {
                let keys2 = ["createdAt", "creationDate", "exportedAt", "timestamp"]
                for key in keys2 {
                    if let s = meta[key] as? String, let d = parseISODateLoose(s) { return d }
                    if let n = meta[key] as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
                }
            }
        }

        // 2) Try a nearby *.zip.import.json for this alias (content or filename)
        let alias = folderURL.lastPathComponent
        let parent = folderURL.deletingLastPathComponent()
        if let importFile = findImportJSON(near: parent, matchingAlias: alias) {
            // (a) try reading explicit dates inside JSON
            if let data = try? Data(contentsOf: importFile),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let keys = ["zipCreatedAt", "bundleCreatedAt", "createdAt", "exportedAt"]
                for key in keys {
                    if let s = json[key] as? String, let d = parseISODateLoose(s) { return d }
                    if let n = json[key] as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
                }
                if let name = json["originalZipName"] as? String, let d = parseDateFromZipBasename(name) { return d }
            }
            // (b) fall back to parsing timestamp from the import file's basename
            if let d = parseDateFromZipBasename(importFile.lastPathComponent) { return d }
        }

        // 2b) If not found near the folder, search anywhere under Documents
        if let importFile = findImportJSONInDocuments(matchingAlias: alias) {
            if let data = try? Data(contentsOf: importFile),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let keys = ["zipCreatedAt", "bundleCreatedAt", "createdAt", "exportedAt"]
                for key in keys {
                    if let s = json[key] as? String, let d = parseISODateLoose(s) { return d }
                    if let n = json[key] as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
                }
                if let name = json["originalZipName"] as? String, let d = parseDateFromZipBasename(name) { return d }
            }
            if let d = parseDateFromZipBasename(importFile.lastPathComponent) { return d }
        }

        // 3) Fallback to the folder's own creation date
        return try? folderURL.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    private func findImportJSON(near directory: URL, matchingAlias alias: String) -> URL? {
        let fm = FileManager.default
        let sanitized = sanitizedAlias(alias)
        let candidates = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        // Look for files like   <alias>-YYYYMMDD-HHMMSS-patientviewer.peMR.zip.import.json
        let hits = candidates.filter { url in
            let name = url.lastPathComponent
            return name.hasSuffix(".zip.import.json") && (name.contains(alias) || name.contains(sanitized))
        }
        if hits.isEmpty { return nil }
        // Prefer the one with the newest modification date
        func modDate(_ url: URL) -> Date {
            ((try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date) ?? .distantPast
        }
        return hits.sorted { modDate($0) > modDate($1) }.first
    }

    private func findImportJSONInDocuments(matchingAlias alias: String) -> URL? {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let sanitized = sanitizedAlias(alias)
        var bestURL: URL? = nil
        var bestDate: Date = .distantPast
        if let enumerator = fm.enumerator(at: docs, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                if name.hasSuffix(".zip.import.json") && (name.contains(alias) || name.contains(sanitized)) {
                    let mod = ((try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date) ?? .distantPast
                    if mod > bestDate { bestDate = mod; bestURL = url }
                }
            }
        }
        return bestURL
    }

    private func parseDateFromZipBasename(_ basename: String) -> Date? {
        // Expect pattern like  Alias-YYYYMMDD-HHMMSS-patientviewer.peMR.zip[.import.json]
        let pattern = "-([0-9]{8})-([0-9]{6})-"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(basename.startIndex..<basename.endIndex, in: basename)
        guard let match = regex.firstMatch(in: basename, options: [], range: range) else { return nil }
        guard let r1 = Range(match.range(at: 1), in: basename),
              let r2 = Range(match.range(at: 2), in: basename) else { return nil }
        let datePart = String(basename[r1])
        let timePart = String(basename[r2])
        let combined = "\(datePart)-\(timePart)"
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return fmt.date(from: combined)
    }

    private func parseISODateLoose(_ s: String) -> Date? {
        // Try ISO8601 with and without fractional seconds/time zone
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]
        if let d = iso2.date(from: s) { return d }
        // Fallbacks for common formats
        let fmts = [
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd"
        ]
        for f in fmts {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = f
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
    // Heuristic to pick the correct extracted root that actually contains the bundle (db.sqlite + docs)
    private func findExtractedRoot(in tempDir: URL, zipURL: URL) -> URL {
        let fm = FileManager.default

        // 0) If db.sqlite is directly under tempDir, use tempDir
        if fm.fileExists(atPath: tempDir.appendingPathComponent("db.sqlite").path) {
            return tempDir
        }

        // 1) Collect immediate subdirectories (skip hidden)
        let items = (try? fm.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let dirs: [URL] = items.filter { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }

        // Helper to test whether a folder contains db.sqlite anywhere inside it
        func folderContainsDB(_ url: URL) -> Bool {
            if fm.fileExists(atPath: url.appendingPathComponent("db.sqlite").path) { return true }
            if let e = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let u as URL in e where u.lastPathComponent == "db.sqlite" { return true }
            }
            return false
        }

        // 2) Prefer a folder that actually contains db.sqlite (directly or nested)
        if let hit = dirs.first(where: { folderContainsDB($0) }) {
            return hit
        }

        // 3) Prefer a folder whose name matches the zip's basename
        let baseName = zipURL.deletingPathExtension().lastPathComponent
        if let match = dirs.first(where: { $0.lastPathComponent.localizedCaseInsensitiveContains(baseName) }) {
            return match
        }

        // 4) If there is exactly one directory, take it
        if dirs.count == 1, let only = dirs.first { return only }

        // 5) As a last resort, try to find db.sqlite anywhere under tempDir and return its parent
        if let e = fm.enumerator(at: tempDir, includingPropertiesForKeys: nil) {
            for case let u as URL in e where u.lastPathComponent == "db.sqlite" { return u.deletingLastPathComponent() }
        }

        // 6) Fallback to tempDir (validation will fail with a clear error if this is wrong)
        return tempDir
    }

    // Validate that the imported bundle contains a usable db.sqlite with a patients table and at least one row.
    private func validateBundleDB(at root: URL) throws {
        let fm = FileManager.default
        var dbURL = root.appendingPathComponent("db.sqlite")
        if !fm.fileExists(atPath: dbURL.path) {
            if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let u as URL in enumerator where u.lastPathComponent == "db.sqlite" {
                    dbURL = u
                    break
                }
            }
        }
        guard fm.fileExists(atPath: dbURL.path) else {
            throw NSError(domain: "BundleLibraryView", code: 100, userInfo: [NSLocalizedDescriptionKey: "db.sqlite not found in imported bundle"])
        }

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            throw NSError(domain: "BundleLibraryView", code: 101, userInfo: [NSLocalizedDescriptionKey: "Unable to open SQLite database"])
        }
        defer { sqlite3_close(db) }

        // Check that the patients table exists
        var stmt: OpaquePointer?
        let tableQuery = "SELECT name FROM sqlite_master WHERE type='table' AND name='patients' LIMIT 1;"
        guard sqlite3_prepare_v2(db, tableQuery, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "BundleLibraryView", code: 102, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare validation query"])
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw NSError(domain: "BundleLibraryView", code: 103, userInfo: [NSLocalizedDescriptionKey: "Invalid bundle: missing 'patients' table"])
        }

        // Ensure there is at least one row
        var stmt2: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM patients;", -1, &stmt2, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt2) }
            if sqlite3_step(stmt2) == SQLITE_ROW {
                let count = sqlite3_column_int(stmt2, 0)
                if count <= 0 {
                    throw NSError(domain: "BundleLibraryView", code: 104, userInfo: [NSLocalizedDescriptionKey: "Invalid bundle: empty 'patients' table"])
                }
            }
        }
    }
    // MARK: - Identity helpers

    private func normalizeDOB(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private func computePatientKey(alias: String?, dob: String?, patientId: Int?) -> String {
        if let pid = patientId { return "pid:\(pid)" }
        let a = (alias ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let d = normalizeDOB(dob) ?? ""
        let raw = "\(a)|\(d)"
        let digest = Insecure.SHA1.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func slugify(alias: String?, dob: String?) -> String {
        // Canonical folder name: sanitized alias only (no DOB appended).
        return sanitizedAlias(alias ?? "Patient")
    }

    private func extractPatientIdentity(from root: URL) throws -> PatientIdentity {
        let info = try readIdentity(from: root)
        let key = computePatientKey(alias: info.alias, dob: info.dob, patientId: info.patientId)
        let slug = slugify(alias: info.alias.isEmpty ? root.lastPathComponent : info.alias, dob: info.dob)
        return PatientIdentity(alias: info.alias, name: info.name, dob: info.dob, patientId: info.patientId, patientKey: key, slug: slug)
    }

    private func existingBundleForPatientKey(_ key: String) -> URL? {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let base = docs.appendingPathComponent("PersistentBundles", isDirectory: true)
        guard let contents = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        for folder in contents {
            let isDir = (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            // Prefer sidecar key match first
            let metaURL = bundleMetaURL(for: folder)
            if let data = try? Data(contentsOf: metaURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let k = json["patientKey"] as? String, k == key {
                return folder
            }
            // Fallback: compute from this folder's DB
            if let info = try? readIdentity(from: folder) {
                let k2 = computePatientKey(alias: info.alias, dob: info.dob, patientId: info.patientId)
                if k2 == key { return folder }
            }
        }
        return nil
    }

    private func timestampNowString() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss"
        return df.string(from: Date())
    }
    
    private func safelyRemoveImportTemp(for candidate: URL) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let importTemp = docs.appendingPathComponent("ImportTemp", isDirectory: true)
        // Only delete if we're sure the path lives under Documents/ImportTemp
        if candidate.path.hasPrefix(importTemp.path) {
            try? fm.removeItem(at: importTemp)
        }
    }

    private func archiveExistingAndReplace(existingURL: URL, newRoot: URL, dest: URL, zipURL: URL, identity: PatientIdentity) throws {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let archiveBase = docs.appendingPathComponent("PersistentBundlesArchive", isDirectory: true)
        if !fm.fileExists(atPath: archiveBase.path) {
            try fm.createDirectory(at: archiveBase, withIntermediateDirectories: true)
        }

        // 1) Stage the new content inside PersistentBundles (atomic swap).
        let staging = dest.deletingLastPathComponent()
            .appendingPathComponent(".staging-\(identity.slug)--\(timestampNowString())", isDirectory: true)
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try fm.copyItem(at: newRoot, to: staging)
        // Write sidecar metadata into the staged folder (not the original).
        writeBundleMeta(to: staging, from: zipURL, rootExtractedURL: newRoot, identity: identity)

        // 2) Archive the existing bundle.
        let archiveFolder = archiveBase.appendingPathComponent("\(existingURL.lastPathComponent)--\(timestampNowString())", isDirectory: true)
        if fm.fileExists(atPath: archiveFolder.path) { try? fm.removeItem(at: archiveFolder) }
        try fm.moveItem(at: existingURL, to: archiveFolder)

        // 3) Move staged folder into place.
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) } // defensive
        try fm.moveItem(at: staging, to: dest)

        // 4) Activate and refresh.
        try activatePersistentBundle(at: dest)
        loadPersistentBundles()

        // 5) Clean our own ImportTemp directory only (guarded).
        safelyRemoveImportTemp(for: newRoot)

        // 6) Keep only the most-recent archive per slug.
        let slug = dest.lastPathComponent
        if let archived = try? fm.contentsOfDirectory(at: archiveBase, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let matching = archived.filter { $0.lastPathComponent.hasPrefix("\(slug)--") }
            if matching.count > 1 {
                let sorted = matching.sorted { (a, b) -> Bool in
                    let am = ((try? fm.attributesOfItem(atPath: a.path)[.modificationDate]) as? Date) ?? .distantPast
                    let bm = ((try? fm.attributesOfItem(atPath: b.path)[.modificationDate]) as? Date) ?? .distantPast
                    return am > bm
                }
                for old in sorted.dropFirst(1) { try? fm.removeItem(at: old) }
            }
        }
    }

    // MARK: - Per-bundle sidecar metadata

    private func bundleMetaURL(for folderURL: URL) -> URL {
        folderURL.appendingPathComponent(".bundle-meta.json")
    }

    private func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func writeBundleMeta(to persistentFolder: URL, from zipURL: URL, rootExtractedURL: URL, identity: PatientIdentity) {
        var meta: [String: Any] = [:]
        meta["patientKey"] = identity.patientKey
        meta["alias"] = identity.alias
        if let name = identity.name { meta["name"] = name }
        if let dob = identity.dob { meta["dob"] = dob }
        if let pid = identity.patientId { meta["patientId"] = pid }

        meta["importedAt"] = isoString(Date())
        meta["originalZipName"] = zipURL.lastPathComponent

        let manifestURL = rootExtractedURL.appendingPathComponent("docs").appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let keys = ["bundleCreatedAt", "createdAt", "creationDate", "exportedAt", "created", "timestamp"]
            for key in keys {
                if let s = json[key] as? String, let d = parseISODateLoose(s) { meta["createdAt"] = isoString(d); break }
                if let n = json[key] as? NSNumber { meta["createdAt"] = isoString(Date(timeIntervalSince1970: n.doubleValue)); break }
            }
            if meta["createdAt"] == nil, let metaObj = json["metadata"] as? [String: Any] {
                let keys2 = ["createdAt", "creationDate", "exportedAt", "timestamp"]
                for key in keys2 {
                    if let s = metaObj[key] as? String, let d = parseISODateLoose(s) { meta["createdAt"] = isoString(d); break }
                    if let n = metaObj[key] as? NSNumber { meta["createdAt"] = isoString(Date(timeIntervalSince1970: n.doubleValue)); break }
                }
            }
        }
        if meta["createdAt"] == nil, let d = parseDateFromZipBasename(zipURL.lastPathComponent) {
            meta["createdAt"] = isoString(d)
        }

        let metaURL = bundleMetaURL(for: persistentFolder)
        if let out = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) {
            try? out.write(to: metaURL, options: .atomic)
        }
    }
    private func readIdentity(from folder: URL) throws -> (alias: String, name: String?, dob: String?, patientId: Int?) {
        let fm = FileManager.default
        var dbURL = folder.appendingPathComponent("db.sqlite")
        if !fm.fileExists(atPath: dbURL.path) {
            if let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: nil) {
                for case let u as URL in enumerator where u.lastPathComponent == "db.sqlite" { dbURL = u; break }
            }
        }
        guard fm.fileExists(atPath: dbURL.path) else {
            throw NSError(domain: "BundleLibraryView", code: 2, userInfo: [NSLocalizedDescriptionKey: "db.sqlite not found in imported bundle"]) }

        var db: OpaquePointer?
        var alias = ""
        var dob: String? = nil
        var first: String? = nil
        var last: String? = nil
        var pid: Int32 = -1

        if sqlite3_open(dbURL.path, &db) == SQLITE_OK {
            defer { sqlite3_close(db) }
            let wideQuery = "SELECT id, alias_label, dob, first_name, last_name FROM patients LIMIT 1;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, wideQuery, -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    pid = sqlite3_column_int(stmt, 0)
                    if let aliasC = sqlite3_column_text(stmt, 1) { alias = String(cString: aliasC) }
                    if let dobC = sqlite3_column_text(stmt, 2) { dob = String(cString: dobC) }
                    if let fC = sqlite3_column_text(stmt, 3) { first = String(cString: fC) }
                    if let lC = sqlite3_column_text(stmt, 4) { last = String(cString: lC) }
                }
                sqlite3_finalize(stmt)
            } else {
                let fallback = "SELECT id, alias_label, dob FROM patients LIMIT 1;"
                if sqlite3_prepare_v2(db, fallback, -1, &stmt, nil) == SQLITE_OK {
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        pid = sqlite3_column_int(stmt, 0)
                        if let aliasC = sqlite3_column_text(stmt, 1) { alias = String(cString: aliasC) }
                        if let dobC = sqlite3_column_text(stmt, 2) { dob = String(cString: dobC) }
                    }
                    sqlite3_finalize(stmt)
                }
            }
        }

        var name: String? = nil
        if let f = first, let l = last, !(f.isEmpty && l.isEmpty) {
            name = [f, l].compactMap { $0 }.joined(separator: " ")
        } else if let f = first, !f.isEmpty {
            name = f
        } else if let l = last, !l.isEmpty {
            name = l
        }
        let idOpt: Int? = pid >= 0 ? Int(pid) : nil
        return (alias, name, dob, idOpt)
    }

    private func metaLine(for bundle: SavedBundle) -> String {
        var parts: [String] = []
        if let c = bundle.created { parts.append("Created: \(formattedDate(c))") }
        if let i = bundle.imported { parts.append("Imported: \(formattedDate(i))") }
        if let s = bundle.lastSaved { parts.append("Last save: \(formattedDate(s))") }
        return parts.joined(separator: " • ")
    }

    private func readAliasDOBAndName(from folder: URL) throws -> (alias: String, name: String?, dob: String?) {
        let fm = FileManager.default
        var dbURL = folder.appendingPathComponent("db.sqlite")
        if !fm.fileExists(atPath: dbURL.path) {
            if let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: nil) {
                for case let u as URL in enumerator where u.lastPathComponent == "db.sqlite" { dbURL = u; break }
            }
        }
        guard fm.fileExists(atPath: dbURL.path) else { return ("", nil, nil) }

        var db: OpaquePointer?
        var alias = ""
        var dob: String? = nil
        var first: String? = nil
        var last: String? = nil

        if sqlite3_open(dbURL.path, &db) == SQLITE_OK {
            defer { sqlite3_close(db) }
            // Try wide query (includes optional columns). If it fails, fall back.
            let wideQuery = "SELECT alias_label, dob, first_name, last_name FROM patients LIMIT 1;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, wideQuery, -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if let aliasC = sqlite3_column_text(stmt, 0) { alias = String(cString: aliasC) }
                    if let dobC = sqlite3_column_text(stmt, 1) { dob = String(cString: dobC) }
                    if let fC = sqlite3_column_text(stmt, 2) { first = String(cString: fC) }
                    if let lC = sqlite3_column_text(stmt, 3) { last = String(cString: lC) }
                }
                sqlite3_finalize(stmt)
            } else {
                let fallback = "SELECT alias_label, dob FROM patients LIMIT 1;"
                if sqlite3_prepare_v2(db, fallback, -1, &stmt, nil) == SQLITE_OK {
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        if let aliasC = sqlite3_column_text(stmt, 0) { alias = String(cString: aliasC) }
                        if let dobC = sqlite3_column_text(stmt, 1) { dob = String(cString: dobC) }
                    }
                    sqlite3_finalize(stmt)
                }
            }
        }

        var name: String? = nil
        if let f = first, let l = last, !(f.isEmpty && l.isEmpty) {
            name = [f, l].compactMap { $0 }.joined(separator: " ")
        } else if let f = first, !f.isEmpty {
            name = f
        } else if let l = last, !l.isEmpty {
            name = l
        }
        return (alias, name, dob)
    }

    private func deleteBundle(_ bundle: SavedBundle) {
        let fm = FileManager.default
        do {
            // Remove persistent folder
            if fm.fileExists(atPath: bundle.folderURL.path) {
                try fm.removeItem(at: bundle.folderURL)
            }
            // Also remove any active copy with the same alias (folder name)
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            let active = docs.appendingPathComponent("ActiveBundle", isDirectory: true)
            let activeAlias = active.appendingPathComponent(bundle.folderURL.lastPathComponent, isDirectory: true)
            if fm.fileExists(atPath: activeAlias.path) {
                try? fm.removeItem(at: activeAlias)
            }
            // If we just deleted the active bundle, clear the recorded active location.
            if let current = ActiveBundleLocator.currentBaseURL(),
               current.lastPathComponent == bundle.folderURL.lastPathComponent {
                ActiveBundleLocator.clear()
            }
            // Refresh list
            loadPersistentBundles()
        } catch {
            alertMessage = "Failed to delete bundle: \(error.localizedDescription)"
            showAlert = true
        }
    }

    private func unzipAndSetActiveBundle(from zipURL: URL) throws {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let activeBundleURL = documentsURL.appendingPathComponent("ActiveBundle", isDirectory: true)
        let jsonPath = zipURL.deletingPathExtension().appendingPathExtension("zip.import.json")

        // Derive folder name from sidecar JSON or ZIP basename, but ALWAYS sanitize it.
        let persistentFolderName: String
        if let data = try? Data(contentsOf: jsonPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let alias = json["alias"] as? String {
            persistentFolderName = sanitizedAlias(alias)
        } else {
            persistentFolderName = sanitizedAlias(zipURL.deletingPathExtension().lastPathComponent)
        }

        let activeAliasURL = activeBundleURL.appendingPathComponent(persistentFolderName, isDirectory: true)
        let persistentBundleURL = documentsURL
            .appendingPathComponent("PersistentBundles", isDirectory: true)
            .appendingPathComponent(persistentFolderName, isDirectory: true)

        print("[DEBUG] 📦 Using existing persistent bundle at: \(persistentBundleURL.path)")

        guard fileManager.fileExists(atPath: persistentBundleURL.path) else {
            throw NSError(domain: "BundleLibraryView", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Persistent bundle not found for selected ZIP."])
        }

        if !fileManager.fileExists(atPath: activeBundleURL.path) {
            try fileManager.createDirectory(at: activeBundleURL, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: activeAliasURL.path) {
            try fileManager.removeItem(at: activeAliasURL)
        }

        // Determine the subfolder of the persistent bundle that actually contains db.sqlite
        var sourceBase = persistentBundleURL
        if !fileManager.fileExists(atPath: persistentBundleURL.appendingPathComponent("db.sqlite").path) {
            if let e = fileManager.enumerator(at: persistentBundleURL, includingPropertiesForKeys: nil) {
                for case let u as URL in e where u.lastPathComponent == "db.sqlite" {
                    sourceBase = u.deletingLastPathComponent()
                    break
                }
            }
        }

        // Copy only that folder so db.sqlite is at ActiveBundle/<alias>/db.sqlite
        try fileManager.copyItem(at: sourceBase, to: activeAliasURL)

        // After flattening, the active base is the alias folder itself
        let baseForDB = activeAliasURL
        guard fileManager.fileExists(atPath: baseForDB.appendingPathComponent("db.sqlite").path) else {
            // Fallback: locate nested db.sqlite just in case
            var fallback = baseForDB
            if let e = fileManager.enumerator(at: baseForDB, includingPropertiesForKeys: nil) {
                for case let u as URL in e where u.lastPathComponent == "db.sqlite" {
                    fallback = u.deletingLastPathComponent()
                    break
                }
            }
            guard fileManager.fileExists(atPath: fallback.appendingPathComponent("db.sqlite").path) else {
                throw NSError(domain: "BundleLibraryView", code: 200, userInfo: [NSLocalizedDescriptionKey: "Active bundle missing db.sqlite"])
            }
            extractedFolderURL = fallback
            ActiveBundleLocator.setCurrentBaseURL(fallback)
            print("[DEBUG] 📌 Active base set to: \(fallback.path)")
            UserDefaults.standard.set(zipURL.path, forKey: "SavedBundlePath")
            extractPatientInfo(from: fallback)
            return
        }

        extractedFolderURL = baseForDB
        ActiveBundleLocator.setCurrentBaseURL(baseForDB)
        print("[DEBUG] 📌 Active base set to: \(baseForDB.path)")
        UserDefaults.standard.set(zipURL.path, forKey: "SavedBundlePath")
        extractPatientInfo(from: baseForDB)
        // IMPORTANT: We never delete or modify the original ZIP or its .zip.import.json.
    }

    private func extractPatientInfo(from bundleURL: URL) {
        print("[DEBUG] 🔍 Starting extractPatientInfo from: \(bundleURL.path)")
        let dbPath = bundleURL.appendingPathComponent("db.sqlite").path
        var db: OpaquePointer?

        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            defer { sqlite3_close(db) }
            let query = "SELECT alias_label, dob FROM patients LIMIT 1;"
            var stmt: OpaquePointer?

            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if let aliasCStr = sqlite3_column_text(stmt, 0) {
                        bundleAlias = String(cString: aliasCStr)
                    }
                    if let dobCStr = sqlite3_column_text(stmt, 1) {
                        bundleDOB = String(cString: dobCStr)
                    }
                    print("[DEBUG] ✅ Extracted alias: \(bundleAlias), DOB: \(bundleDOB)")
                }
                sqlite3_finalize(stmt)
            }
        }
    }

    private func handleZipImport(url: URL) {
        isBusy = true
        let fm = FileManager.default
        ensureBaseDirectories()
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let tempDir = docs.appendingPathComponent("ImportTemp", isDirectory: true)
        do {
            if fm.fileExists(atPath: tempDir.path) { try fm.removeItem(at: tempDir) }
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

            // SAFETY: Work on a local COPY of the ZIP so we never touch/delete the user's original file.
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            let localZipCopy = tempDir.appendingPathComponent("_import-\(UUID().uuidString).zip")
            try fm.copyItem(at: url, to: localZipCopy)
            try fm.unzipItem(at: localZipCopy, to: tempDir)

            // Determine the extracted root that actually contains the bundle
            let root = findExtractedRoot(in: tempDir, zipURL: url)
            print("[DEBUG] 📂 Selected extracted root: \(root.path)")

            let identity = try extractPatientIdentity(from: root)
            try validateBundleDB(at: root)
            let persistentBase = docs.appendingPathComponent("PersistentBundles", isDirectory: true)
            let dest = persistentBase.appendingPathComponent(identity.slug, isDirectory: true)

            if let existing = existingBundleForPatientKey(identity.patientKey) {
                pendingImport = PendingImport(zipURL: url, tempRoot: root, identity: identity, destinationURL: dest, existingURL: existing)
                showDuplicateImportDialog = true
                isBusy = false
                return
            }

            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: root, to: dest)
            writeBundleMeta(to: dest, from: url, rootExtractedURL: root, identity: identity)
            try activatePersistentBundle(at: dest)
            loadPersistentBundles()

            // Clean only our own temporary working dir (and the local zip copy inside it).
            try? fm.removeItem(at: tempDir)
            // NOTE: The original ZIP (url) and any .zip.import.json next to it are left untouched.
        } catch {
            alertMessage = "Import failed: \(error.localizedDescription)"
            showAlert = true
            try? fm.removeItem(at: tempDir)
        }
        isBusy = false
    }

    private func readAliasDOB(from folder: URL) throws -> (String, String) {
        let fm = FileManager.default
        // Find db.sqlite (root or nested)
        var dbURL = folder.appendingPathComponent("db.sqlite")
        if !fm.fileExists(atPath: dbURL.path) {
            if let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: nil) {
                for case let u as URL in enumerator {
                    if u.lastPathComponent == "db.sqlite" { dbURL = u; break }
                }
            }
        }
        guard fm.fileExists(atPath: dbURL.path) else {
            throw NSError(domain: "BundleLibraryView", code: 2, userInfo: [NSLocalizedDescriptionKey: "db.sqlite not found in imported bundle"]) }

        var db: OpaquePointer?
        var alias = ""
        var dob = ""
        if sqlite3_open(dbURL.path, &db) == SQLITE_OK {
            defer { sqlite3_close(db) }
            let query = "SELECT alias_label, dob FROM patients LIMIT 1;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if let aliasC = sqlite3_column_text(stmt, 0) { alias = String(cString: aliasC) }
                    if let dobC = sqlite3_column_text(stmt, 1) { dob = String(cString: dobC) }
                }
                sqlite3_finalize(stmt)
            }
        }
        return (alias, dob)
    }

    private func sanitizedAlias(_ input: String) -> String {
        // Keep letters, numbers, spaces, dashes, underscores, and parentheses.
        // DROP everything else (e.g., emojis) instead of replacing with "_",
        // then collapse whitespace and trim dangling separators.
        let allowed = CharacterSet.alphanumerics
            .union(.whitespacesAndNewlines)
            .union(CharacterSet(charactersIn: "-_()"))
        let filteredScalars = input.unicodeScalars.filter { allowed.contains($0) }
        var s = String(String.UnicodeScalarView(filteredScalars))
        // Collapse runs of whitespace to a single space
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        // Trim surrounding whitespace
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Trim leading/trailing underscores or dashes
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        // Collapse repeated separators like "__" or "--"
        s = s.replacingOccurrences(of: "[\\-_]{2,}", with: "-", options: .regularExpression)
        if s.isEmpty { return "Patient" }
        return s
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview {
    BundleLibraryView(extractedFolderURL: .constant(nil), bundleAlias: .constant(""), bundleDOB: .constant(""))
}
