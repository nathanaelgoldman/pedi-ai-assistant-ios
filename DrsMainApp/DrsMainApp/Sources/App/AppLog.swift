//
//  AppLog.swift
//  DrsMainApp
//
//  Centralized logging for DrsMainApp.
//
//  LOGGING CONVENTIONS
//  -------------------
//  ✅ Use `AppLog` everywhere (do not create ad-hoc `Logger(...)` instances in random files).
//
//  Subsystem
//  - Always: `AppLog.subsystem` (Bundle ID fallback to "DrsMainApp").
//
//  Categories
//  - Prefer the shared categories below:
//      - `AppLog.app`     : app lifecycle, high-level flows
//      - `AppLog.auth`    : clinician sign-in / sign-out, credential checks
//      - `AppLog.db`      : database reads/writes, migrations, schema checks
//      - `AppLog.bundle`  : bundle load/decrypt/verify, manifest handling
//      - `AppLog.export`  : export/import actions, file outputs
//      - `AppLog.report`  : report building/rendering/export
//      - `AppLog.ui`      : UI events that help debugging (selection, navigation triggers)
//
//  - If a feature doesn’t fit, use: `AppLog.feature("<category>")`.
//    Example: `let log = AppLog.feature("growth")`.
//
//  Levels (rule of thumb)
//  - `.debug`  : noisy, dev-only details (counts, timings, branch decisions)
//  - `.info`   : important but expected events (user actions, successful operations)
//  - `.notice` : noteworthy state transitions (switching active patient/clinician)
//  - `.error`  : failures that should be investigated
//  - `.fault`  : data corruption, invariants broken, or “this should never happen”
//
//  Privacy
//  - Default to `.private` for file paths, identifiers, and any patient data.
//  - Use `.public` only for non-sensitive, non-identifying values.
//  - Never log raw bundle folder names or full filesystem paths; use `AppLog.bundleRef(...)` / `AppLog.dbRef(...)`.
//
//  Created by Nathanael on 1/17/26.
//
import OSLog
import Foundation
import CryptoKit

enum AppLog {
    // One subsystem for the whole app (stable across files)
    static let subsystem = Bundle.main.bundleIdentifier ?? "DrsMainApp"

    // Common categories (high-signal areas)
    static let app     = Logger(subsystem: subsystem, category: "app")
    static let auth    = Logger(subsystem: subsystem, category: "auth")
    static let db      = Logger(subsystem: subsystem, category: "db")
    static let bundle  = Logger(subsystem: subsystem, category: "bundle")
    static let export  = Logger(subsystem: subsystem, category: "export")
    static let report  = Logger(subsystem: subsystem, category: "report")
    static let ui      = Logger(subsystem: subsystem, category: "ui")

    /// Convenience: make a feature-specific logger with a consistent subsystem
    static func feature(_ name: String) -> Logger {
        Logger(subsystem: subsystem, category: name)
    }


    // MARK: - Redaction helpers (stable, non-identifying references)

    /// Stable short token (hex) for correlating logs without leaking raw identifiers.
    /// NOTE: This is NOT a security feature; it's a log-safety feature.
    static func token(_ raw: String, length: Int = 16) -> String {
        let data = Data(raw.utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(max(4, length)))
    }

    /// A log-safe bundle reference derived from the bundle folder name.
    /// Example: "BUNDLE#20acc340c59be1df"
    static func bundleRef(_ bundleRoot: URL) -> String {
        let name = bundleRoot.lastPathComponent
        return "BUNDLE#\(token(name))"
    }

    /// A log-safe file reference: bundleRef + filename (no full paths).
    /// Example: "BUNDLE#.../db.sqlite"
    static func fileRef(_ fileURL: URL) -> String {
        let bundle = fileURL.deletingLastPathComponent()
        return "\(bundleRef(bundle))/\(fileURL.lastPathComponent)"
    }

    /// A log-safe DB reference for logs like "Using DB: ...".
    static func dbRef(_ dbURL: URL) -> String {
        fileRef(dbURL)
    }

    /// Optional: a short, log-safe alias label token.
    /// Example: "ALIAS#bcdebd14d2ad2930"
    static func aliasRef(_ alias: String) -> String {
        "ALIAS#\(token(alias))"
    }


    // MARK: - Scoped helpers (baseline logging)

    /// A tiny helper to keep logging consistent across UI forms without creating ad-hoc Logger instances.
    ///
    /// Usage (example):
    ///   let log = AppLog.baseline("SickEpisodeForm")
    ///   log.opened(editingID: editingEpisodeID)
    ///   log.saveTapped(pid: appState.selectedPatientID, idLabel: "episodeID", id: editingEpisodeID)
    ///
    struct Baseline {
        let component: String

        init(_ component: String) {
            self.component = component
        }

        // Render optionals in a consistent, non-crashy way.
        private func opt(_ v: Int?) -> String { v.map(String.init) ?? "nil" }
        private func opt(_ v: Int64?) -> String { v.map(String.init) ?? "nil" }

        // MARK: UI events

        func opened(editingID: Int?) {
            AppLog.ui.info("\(component, privacy: .public): opened editingID=\(opt(editingID), privacy: .private)")
        }

        func saveTapped(pid: Int?, idLabel: String, id: Int?) {
            AppLog.ui.info("\(component, privacy: .public): SAVE tapped | pid=\(opt(pid), privacy: .private) \(idLabel, privacy: .public)=\(opt(id), privacy: .private)")
        }

        // MARK: DB / persistence events

        func saveStart(pid: Int?, idLabel: String, id: Int?, editingID: Int?) {
            AppLog.db.debug("\(component, privacy: .public): save start | pid=\(opt(pid), privacy: .private) \(idLabel, privacy: .public)=\(opt(id), privacy: .private) editingID=\(opt(editingID), privacy: .private)")
        }

        func payloadBuilt(idLabel: String, id: Int?, keyCount: Int) {
            AppLog.db.debug("\(component, privacy: .public): payload built | \(idLabel, privacy: .public)=\(opt(id), privacy: .private) keys=\(keyCount, privacy: .public)")
        }

        func dbTarget(_ filename: String) {
            // Keep this non-sensitive; the full path should remain private elsewhere.
            AppLog.db.debug("\(component, privacy: .public): db=\(filename, privacy: .public)")
        }

        func dbTarget(_ dbURL: URL) {
            // Prefer a stable, non-identifying reference rather than a filesystem path.
            AppLog.db.debug("\(component, privacy: .public): db=\(AppLog.dbRef(dbURL), privacy: .public)")
        }

        func saveSuccess(idLabel: String, id: Int, changes: Int?) {
            AppLog.db.info("\(component, privacy: .public): save success | \(idLabel, privacy: .public)=\(id, privacy: .private) changes=\(opt(changes), privacy: .public)")
        }

        func saveFailed(idLabel: String, id: Int?, error: Error) {
            AppLog.db.error("\(component, privacy: .public): save FAILED | \(idLabel, privacy: .public)=\(opt(id), privacy: .private) err=\(String(describing: error), privacy: .private(mask: .hash))")
        }

        // Optional: quick, low-stakes breadcrumb
        func note(_ message: String) {
            AppLog.ui.debug("\(component, privacy: .public): \(message, privacy: .private)")
        }
    }

    /// Convenience constructor for `Baseline`.
    static func baseline(_ component: String) -> Baseline {
        Baseline(component)
    }
}
