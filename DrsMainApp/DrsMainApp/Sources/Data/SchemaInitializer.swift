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
        try? db.execute(sql: "PRAGMA journal_mode=WAL;")
        try? db.execute(sql: "PRAGMA foreign_keys=ON;")

        // Patients — keep names/columns aligned with PatientViewer expectations
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS patients (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            alias TEXT NOT NULL,
            full_name TEXT,
            dob TEXT,
            sex TEXT,
            parent_notes TEXT DEFAULT ''
        );
        """)

        // Visits — generic, category 'well' | 'sick'
        try db.execute(sql: """
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

        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_visits_patient ON visits(patient_id);")
    }
}
