//
//  AppState.swift
//  DrsMainApp
//
//  Created by yunastic on 10/26/25.
//

import Foundation
import SwiftUI
import OSLog

// If you put schema helpers in PediaShared instead of the app target,
// change this to: import PediaShared
// and make sure the functions called below exist there.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Published state
    @Published var selection: SidebarSelection? = .dashboard
    @Published var currentBundleURL: URL? = nil
    @Published var recentBundles: [URL] = []

    // MARK: - Private
    private let recentsKey = "recentBundlePaths"
    private let log = Logger(subsystem: "com.pediai.DrsMainApp", category: "AppState")

    // MARK: - Init
    init() {
        loadRecentBundles()
    }

    // MARK: - Selection / Recents
    func selectBundle(_ url: URL) {
        currentBundleURL = url
        addToRecents(url)
        log.info("Selected bundle at \(url.path, privacy: .public)")
    }

    private func addToRecents(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        let path = url.path
        // de-dupe, most-recent first
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        // cap at 10
        if paths.count > 10 { paths = Array(paths.prefix(10)) }
        UserDefaults.standard.set(paths, forKey: recentsKey)
        recentBundles = paths.compactMap { URL(fileURLWithPath: $0) }
    }

    private func loadRecentBundles() {
        let paths = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        recentBundles = paths.compactMap { URL(fileURLWithPath: $0) }
    }

    // MARK: - Create new patient/bundle
    /// Creates a new bundle folder with `db.sqlite`, `docs/`, and `manifest.json`,
    /// initializes the SQLite schema, seeds the initial patient row, and selects it.
    func createNewPatient(
        into parentFolder: URL,
        alias: String,
        fullName: String?,
        dob: Date?,
        sex: String?
    ) throws -> URL {
        let fm = FileManager.default

        // 1) Make a unique, safe folder name
        let safeAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Patient" : alias
        let baseName = safeAlias.replacingOccurrences(of: "/", with: "–").replacingOccurrences(of: ":", with: "–")
        var bundleURL = parentFolder.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 1
        while fm.fileExists(atPath: bundleURL.path) {
            suffix += 1
            bundleURL = parentFolder.appendingPathComponent("\(baseName) \(suffix)", isDirectory: true)
        }

        // 2) Create bundle dirs
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let docsURL = bundleURL.appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: docsURL, withIntermediateDirectories: true)

        // 3) Create and initialize SQLite
        let dbURL = bundleURL.appendingPathComponent("db.sqlite")
        try SchemaInitializer.initializePediaSchema(at: dbURL)

        // 4) Seed initial patient row
        try SchemaInitializer.insertInitialPatient(
            dbURL: dbURL,
            alias: safeAlias,
            fullName: fullName,
            dob: dob,
            sex: sex
        )

        // 5) Write a simple manifest at root (and mirror into docs/ for legacy readers)
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let manifest: [String: Any] = [
            "alias": safeAlias,
            "created_at": nowISO,
            "version": 1,
            "docs_count": 0
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: bundleURL.appendingPathComponent("manifest.json"), options: .atomic)
        try manifestData.write(to: docsURL.appendingPathComponent("manifest.json"), options: .atomic)

        log.info("Created new bundle for \(safeAlias, privacy: .public) at \(bundleURL.path, privacy: .public)")

        // 6) Activate
        selectBundle(bundleURL)
        return bundleURL
    }
}

// MARK: - Sidebar selection
enum SidebarSelection: Hashable {
    case dashboard
    case patients
    case imports
}
