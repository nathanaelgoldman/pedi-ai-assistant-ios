//
//  SchemaInitializer.swift
//  DrsMainApp
//
//  Created by yunastic on 10/26/25.
//
// DrsMainApp/Sources/Data/SchemaInitializer.swift
import Foundation
import PediaShared

enum Schema {
    /// Creates the minimal DB structure expected by our apps.
    static func initializePediaSchema(db: SQLiteDB) throws {
        // Safe defaults
        _ = try? db.execute("PRAGMA journal_mode=WAL;")
        _ = try? db.execute("PRAGMA foreign_keys=ON;")
        // Patients — aligned with PatientViewer (no legacy `alias` column).
        try db.execute("""
        CREATE TABLE IF NOT EXISTS patients (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            alias_label TEXT,
            alias_id TEXT,
            full_name TEXT,
            dob TEXT,
            sex TEXT,
            parent_notes TEXT DEFAULT ''
        );
        """)

        // Visits — generic, category 'well' | 'sick'
        try db.execute("""
        CREATE TABLE IF NOT EXISTS visits (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            patient_id INTEGER NOT NULL,
            category TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
            updated_at TEXT,
            title TEXT,
            summary TEXT,
            FOREIGN KEY(patient_id) REFERENCES patients(id) ON DELETE CASCADE
        );
        """)

        try db.execute("CREATE INDEX IF NOT EXISTS idx_visits_patient ON visits(patient_id);")
    }
}
