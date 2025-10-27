//
//  BundleCoordinator.swift
//  PediaShared
//
//  Created by yunastic on 10/26/25.
//
import Foundation

#if os(macOS)
import AppKit
#endif

/// Minimal, cross-app coordinator that knows where files live inside a patient bundle.
public struct PediaBundleCoordinator: Sendable {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    // MARK: Well-known paths

    public var databaseURL: URL {
        baseURL.appendingPathComponent("db.sqlite", isDirectory: false)
    }

    public var docsURL: URL {
        baseURL.appendingPathComponent("docs", isDirectory: true)
    }

    public var manifestURL: URL {
        baseURL.appendingPathComponent("manifest.json", isDirectory: false)
    }

    // MARK: Validation

    /// Quick existence check (+ optionally ensure docs dir exists).
    @discardableResult
    public func preflight(ensureDocsDir: Bool = false) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: databaseURL.path) else { return false }
        if ensureDocsDir, !fm.fileExists(atPath: docsURL.path) {
            try fm.createDirectory(at: docsURL, withIntermediateDirectories: true)
        }
        return true
    }

    // MARK: Database

    /// Open `db.sqlite` (read-only by default).
    public func openDatabase(readonly: Bool = true) throws -> SQLiteDB {
        try SQLiteDB(path: databaseURL.path, readonly: readonly)
    }

    // MARK: Convenience (schema-agnostic)

    /// Generic helper to see if a table is present.
    public func tableExists(_ name: String, using db: SQLiteDB) -> Bool {
        (try? db.tableExists(name)) ?? false
    }

    // Example domain-type we can fetch without pulling the whole schema in here.
    public struct PatientSummary: Hashable, Sendable {
        public let id: Int64
        public let alias: String
        public let dobISO: String?
        public let sex: String?
    }

    /// Non-fatal helper: if a `patients` table exists with typical columns, return summaries.
    public func listPatientSummaries(using db: SQLiteDB) -> [PatientSummary] {
        guard (try? db.tableExists("patients")) == true else { return [] }
        let sql = """
        SELECT id,
               COALESCE(alias, '') AS alias,
               dob,
               sex
        FROM patients
        ORDER BY id ASC
        """
        do {
            return try db.queryRows(sql: sql).compactMap { row in
                guard
                    let id = row["id"] as? Int64
                else { return nil }
                let alias = (row["alias"] as? String) ?? ""
                let dob = row["dob"] as? String
                let sex = row["sex"] as? String
                return PatientSummary(id: id, alias: alias, dobISO: dob, sex: sex)
            }
        } catch {
            return []
        }
    }

    // MARK: Creation / Scaffolding

    /// Lightweight manifest stored beside the database (optional).
    public struct BundleManifest: Codable, Sendable {
        public var alias: String?
        public var createdAtISO8601: String
        public var schemaVersion: Int
        public var patientFullName: String?
        public var dobISO8601: String?
        public var sex: String?

        public init(
            alias: String? = nil,
            createdAtISO8601: String = ISO8601DateFormatter().string(from: Date()),
            schemaVersion: Int = 1,
            patientFullName: String? = nil,
            dobISO8601: String? = nil,
            sex: String? = nil
        ) {
            self.alias = alias
            self.createdAtISO8601 = createdAtISO8601
            self.schemaVersion = schemaVersion
            self.patientFullName = patientFullName
            self.dobISO8601 = dobISO8601
            self.sex = sex
        }
    }

    public enum BundleScaffoldError: Error {
        case alreadyExists(URL)
        case notDirectory(URL)
        case cannotCreate(URL, underlying: Error)
        case cannotWriteManifest(URL, underlying: Error)
        case cannotCreateDatabase(URL, underlying: Error)
    }

    /// Create a brand-new bundle on disk at `bundleURL`, optionally writing a manifest
    /// and initializing the SQLite schema.
    ///
    /// - Parameters:
    ///   - bundleURL: Folder to create (e.g. `~/Documents/Pedia/Bundles/Aqua Fox`).
    ///   - manifest: Optional `BundleManifest` to serialize to `manifest.json`.
    ///   - initializeSchema: Optional callback where the caller creates tables/indexes.
    ///                       The callback receives a *writable* `SQLiteDB`.
    /// - Returns: A ready-to-use coordinator pointing at the new bundle.
    @discardableResult
    public static func create(
        at bundleURL: URL,
        manifest: BundleManifest? = nil,
        initializeSchema: ((SQLiteDB) throws -> Void)? = nil
    ) throws -> PediaBundleCoordinator {

        let fm = FileManager.default

        // Ensure folder exists (create it if missing). Fail if an item exists that is not a directory.
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: bundleURL.path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw BundleScaffoldError.notDirectory(bundleURL)
            }
        } else {
            do {
                try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            } catch {
                throw BundleScaffoldError.cannotCreate(bundleURL, underlying: error)
            }
        }

        let coordinator = PediaBundleCoordinator(baseURL: bundleURL)

        // Ensure docs/ exists
        if !fm.fileExists(atPath: coordinator.docsURL.path, isDirectory: &isDir) {
            do {
                try fm.createDirectory(at: coordinator.docsURL, withIntermediateDirectories: true)
            } catch {
                throw BundleScaffoldError.cannotCreate(coordinator.docsURL, underlying: error)
            }
        }

        // Create database if missing and run initializer
        if !fm.fileExists(atPath: coordinator.databaseURL.path) {
            do {
                // Opening read-write will create the file in our SQLite wrapper; close immediately.
                let db = try coordinator.openDatabase(readonly: false)
                try initializeSchema?(db)
            } catch {
                throw BundleScaffoldError.cannotCreateDatabase(coordinator.databaseURL, underlying: error)
            }
        } else if let initializeSchema {
            // If db already exists and the caller provided an initializer, let them run migrations.
            do {
                let db = try coordinator.openDatabase(readonly: false)
                try initializeSchema(db)
            } catch {
                throw BundleScaffoldError.cannotCreateDatabase(coordinator.databaseURL, underlying: error)
            }
        }

        // Write manifest if provided (overwrite safely)
        if let manifest {
            do {
                let data = try JSONEncoder().encode(manifest)
                try data.write(to: coordinator.manifestURL, options: .atomic)
            } catch {
                throw BundleScaffoldError.cannotWriteManifest(coordinator.manifestURL, underlying: error)
            }
        }

        return coordinator
    }

    /// Convenience: write (or rewrite) a manifest.
    public func writeManifest(_ manifest: BundleManifest) throws {
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            throw BundleScaffoldError.cannotWriteManifest(manifestURL, underlying: error)
        }
    }

    /// Convenience: read manifest if present.
    public func loadManifest() -> BundleManifest? {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: manifestURL)
            return try JSONDecoder().decode(BundleManifest.self, from: data)
        } catch {
            return nil
        }
    }
}

#if os(macOS)
public enum PediaBundlePicker {
    /// Open-panel for selecting a patient bundle folder (not a file).
    public static func selectBundleDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Select Patient Bundle"
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        let result = panel.runModal()
        return (result == .OK) ? panel.urls.first : nil
    }
}
#endif
