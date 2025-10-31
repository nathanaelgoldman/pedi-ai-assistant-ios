//
//  BundleDetailView.swift
//  DrsMainApp
//
//  Created by yunastic on 10/27/25.
//
import SwiftUI
import OSLog
import PediaShared
import SQLite3

#if os(macOS)
import AppKit
#endif

// Local minimal summary model to decouple UI from shared types
private struct LocalPatientSummary {
    let id: Int
    let alias: String
    let fullName: String
    let dobISO: String
    let sex: String
}

struct BundleDetailView: View {
    @EnvironmentObject var appState: AppState
    private let log = Logger(subsystem: "com.pediai.DrsMainApp", category: "Detail")

    @State private var summary: LocalPatientSummary?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bundle Detail")
                .font(.title2).bold()

            if let url = appState.currentBundleURL {
                Text(url.lastPathComponent)
                    .font(.headline)

                Text(url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack {
                    Button {
                        revealInFinder(url)
                    } label: {
                        Label("Reveal in Finder", systemImage: "finder")
                    }

                    Button {
                        openDB(url)
                    } label: {
                        Label("Open DB", systemImage: "rectangle.and.text.magnifyingglass")
                    }
                    .disabled(!dbExists(at: url))
                }

                Divider().padding(.vertical, 4)

                if let s = summary {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow { Text("Alias").font(.subheadline.weight(.semibold)); Text(s.alias) }
                        GridRow { Text("Full Name").font(.subheadline.weight(.semibold)); Text(s.fullName) }
                        GridRow { Text("DOB").font(.subheadline.weight(.semibold)); Text(s.dobISO) }
                        GridRow { Text("Sex").font(.subheadline.weight(.semibold)); Text(s.sex) }
                        GridRow { Text("Patient ID").font(.subheadline.weight(.semibold)); Text("\(s.id)") }
                    }
                } else if let e = loadError {
                    Text(e).foregroundStyle(.red)
                } else {
                    Text("No patient record found in this bundle.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("No Bundle Selected",
                                       systemImage: "folder",
                                       description: Text("Use “Add Bundles…” or create a new patient."))
            }

            Spacer()
        }
        .padding(16)
        .onChange(of: appState.currentBundleURL) { _, newURL in
            loadSummary(from: newURL)
        }
        .onAppear {
            loadSummary(from: appState.currentBundleURL)
        }
    }

    // MARK: - Loaders

    private func loadSummary(from bundleURL: URL?) {
        summary = nil
        loadError = nil
        guard let bundleURL else { return }

        let dbURL = bundleURL.appendingPathComponent("db.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            log.info("No db.sqlite in bundle at \(dbURL.path, privacy: .public)")
            return
        }

        do {
            summary = try fetchPatientSummary(dbPath: dbURL.path)
        } catch {
            loadError = error.localizedDescription
            log.error("Failed to load summary: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fetchPatientColumns(_ db: OpaquePointer?) throws -> Set<String> {
        var set = Set<String>()
        guard let db else { return set }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(patients);", -1, &stmt, nil) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "DB", code: 10, userInfo: [NSLocalizedDescriptionKey: "PRAGMA table_info failed: \(message)"])
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            // PRAGMA table_info columns: cid, name, type, notnull, dflt_value, pk
            if let cName = sqlite3_column_text(stmt, 1) {
                let name = String(cString: cName).lowercased()
                set.insert(name)
            }
        }
        return set
    }

    private func fetchPatientSummary(dbPath: String) throws -> LocalPatientSummary? {
        var db: OpaquePointer?
        // Open read-only; if you later need write, switch to SQLITE_OPEN_READWRITE
        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown error"
            if let db { sqlite3_close(db) }
            throw NSError(domain: "DB", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to open DB: \(message)"])
        }
        defer { sqlite3_close(db) }

        // Discover actual columns in patients table to avoid "no such column" errors
        let columns = try fetchPatientColumns(db)

        // Build safe SELECT list based on existing columns
        var selectParts: [String] = ["id"]

        // alias
        if columns.contains("alias_label") {
            selectParts.append("alias_label AS alias")
        } else if columns.contains("alias") {
            // legacy fallback only if it truly exists
            selectParts.append("alias AS alias")
        } else {
            selectParts.append("'' AS alias")
        }

        // full name
        if columns.contains("full_name") {
            selectParts.append("full_name")
        } else if columns.contains("first_name") && columns.contains("last_name") {
            selectParts.append("TRIM(COALESCE(first_name,'') || ' ' || COALESCE(last_name,'')) AS full_name")
        } else {
            selectParts.append("'' AS full_name")
        }

        // dob
        if columns.contains("dob") {
            selectParts.append("dob")
        } else if columns.contains("date_of_birth") {
            selectParts.append("date_of_birth AS dob")
        } else {
            selectParts.append("'' AS dob")
        }

        // sex
        if columns.contains("sex") {
            selectParts.append("sex")
        } else {
            selectParts.append("'' AS sex")
        }

        let selectList = selectParts.joined(separator: ",\n       ")

        let sql: String
        if appState.selectedPatientID != nil {
            sql = """
            SELECT
                \(selectList)
            FROM patients
            WHERE id = ?
            LIMIT 1;
            """
        } else {
            sql = """
            SELECT
                \(selectList)
            FROM patients
            ORDER BY id
            LIMIT 1;
            """
        }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "DB", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare statement: \(message)"])
        }
        defer { sqlite3_finalize(stmt) }

        if let selectedID = appState.selectedPatientID {
            sqlite3_bind_int64(stmt, 1, sqlite3_int64(selectedID))
        }

        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))

            func text(_ index: Int32) -> String {
                if let cStr = sqlite3_column_text(stmt, index) {
                    return String(cString: cStr)
                } else {
                    return ""
                }
            }

            let alias = text(1)
            let fullName = text(2)
            let dob = text(3)
            let sex = text(4)
            return LocalPatientSummary(id: id, alias: alias, fullName: fullName, dobISO: dob, sex: sex)
        } else if rc == SQLITE_DONE {
            return nil
        } else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "DB", code: 3, userInfo: [NSLocalizedDescriptionKey: "Query failed: \(message)"])
        }
    }

    // MARK: - Helpers

    private func dbExists(at bundleURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("db.sqlite").path)
    }

    private func revealInFinder(_ url: URL) {
        #if os(macOS)
        FilePicker.revealInFinder(url)
        #endif
    }

    private func openDB(_ bundleURL: URL) {
        #if os(macOS)
        let db = bundleURL.appendingPathComponent("db.sqlite")
        NSWorkspace.shared.open(db)
        #endif
    }
}

