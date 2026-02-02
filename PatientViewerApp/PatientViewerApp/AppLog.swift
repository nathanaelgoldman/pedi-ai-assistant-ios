//
//  AppLog.swift
//  PatientViewerApp
//
//  Created by Nathanael on 1/19/26.
//
//
//
//  AppLog.swift
//  PatientViewerApp
//
//  Centralized logging for PatientViewerApp.
//
//  ✅ Use `AppLog` everywhere (avoid ad-hoc Logger(...) instances).
//  ✅ Default to `.private` for paths, identifiers, and any patient data.
//  ✅ Use `.public` only for non-sensitive info (counts, timings, component names).
//

import OSLog
import Foundation
import CryptoKit

enum AppLog {
    // One subsystem for the whole app (stable across files)
    static let subsystem = Bundle.main.bundleIdentifier ?? "PatientViewerApp"

    // Common categories (high-signal areas)
    static let app     = Logger(subsystem: subsystem, category: "app")
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
    /// Usage:
    ///   let log = AppLog.baseline("BundleExporter")
    ///   log.opened(editingID: editingID)
    ///   log.saveTapped(idLabel: "visitID", id: visitID)
    ///
    struct Baseline {
        let component: String

        init(_ component: String) { self.component = component }

        // Render optionals in a consistent, non-crashy way.
        private func opt(_ v: Int?) -> String { v.map(String.init) ?? "nil" }
        private func opt(_ v: Int64?) -> String { v.map(String.init) ?? "nil" }
        private func opt(_ v: String?) -> String { v ?? "nil" }

        // MARK: UI events

        func opened(editingID: Int?) {
            AppLog.ui.info("\(component, privacy: .public): opened editingID=\(opt(editingID), privacy: .private)")
        }

        func action(_ label: String, id: Int? = nil) {
            AppLog.ui.info("\(component, privacy: .public): \(label, privacy: .public) id=\(opt(id), privacy: .private)")
        }

        // MARK: DB / persistence events

        func dbTarget(_ filename: String) {
            // Filename only, no path.
            AppLog.db.debug("\(component, privacy: .public): db=\(filename, privacy: .public)")
        }
        
        func dbTarget(_ dbURL: URL) {
            // Prefer a stable, non-identifying reference rather than a filesystem path.
            AppLog.db.debug("\(component, privacy: .public): db=\(AppLog.dbRef(dbURL), privacy: .public)")
        }

        func saveFailed(idLabel: String, id: Int?, error: Error) {
            AppLog.db.error("\(component, privacy: .public): save FAILED | \(idLabel, privacy: .public)=\(opt(id), privacy: .private) err=\(String(describing: error), privacy: .private(mask: .hash))")
        }

        // Optional: quick breadcrumb (treat as private by default)
        func note(_ message: String) {
            AppLog.ui.debug("\(component, privacy: .public): \(message, privacy: .private)")
        }
    }

    /// Convenience constructor for `Baseline`.
    static func baseline(_ component: String) -> Baseline {
        Baseline(component)
    }
}
