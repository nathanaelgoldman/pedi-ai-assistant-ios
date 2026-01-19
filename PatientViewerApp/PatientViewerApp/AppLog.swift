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
