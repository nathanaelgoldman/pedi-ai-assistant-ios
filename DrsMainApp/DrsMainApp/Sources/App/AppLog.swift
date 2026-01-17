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
//
//  Created by Nathanael on 1/17/26.
//
import OSLog
import Foundation

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
}
