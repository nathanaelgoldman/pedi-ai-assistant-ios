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
        // Patients — keep names/columns aligned with PatientViewer expectations
        try db.execute("""
        CREATE TABLE IF NOT EXISTS patients (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            alias TEXT,                          -- legacy compatibility
            alias_label TEXT,
            alias_id TEXT,
            full_name TEXT,
            dob TEXT,
            sex TEXT,
            parent_notes TEXT DEFAULT ''
        );
        """)

        // --- Migration for legacy 'alias' column -> 'alias_label' / 'alias_id'
        do { try db.execute("ALTER TABLE patients ADD COLUMN alias_label TEXT;") } catch { /* ignore if already exists */ }
        do { try db.execute("ALTER TABLE patients ADD COLUMN alias_id TEXT;") } catch { /* ignore if already exists */ }
        // Ensure legacy 'alias' column still exists for older queries and backfill it.
        do { try db.execute("ALTER TABLE patients ADD COLUMN alias TEXT;") } catch { /* ignore if already exists */ }
        // Backfill alias from alias_label when missing
        do { try db.execute("UPDATE patients SET alias = COALESCE(alias, alias_label) WHERE alias IS NULL OR alias = ''") } catch { /* ignore */ }

        // If an older 'alias' column exists, copy it into alias_label (ignore if 'alias' doesn't exist)
        do { try db.execute("UPDATE patients SET alias_label = alias WHERE (alias_label IS NULL OR alias_label = '')") } catch { /* ignore if 'alias' column doesn't exist */ }

        // Generate a simple alias_id from alias_label if missing (lowercased, spaces -> underscores)
        do { try db.execute("UPDATE patients SET alias_id = lower(replace(alias_label, ' ', '_')) WHERE (alias_id IS NULL OR alias_id = '') AND alias_label IS NOT NULL AND alias_label <> ''") } catch { /* ignore */ }
        // --- End migration

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
