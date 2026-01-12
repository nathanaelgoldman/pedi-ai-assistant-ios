
//
//  PatientHeaderLoader.swift
//  PatientViewerApp
//
//  Created by Nathanael on 1/12/26.
//

import Foundation
import SQLite
import os

/// Small DB helper used by `ContentView` to render the active bundle patient badge.
/// Keeps SQLite reads out of SwiftUI views and avoids mixing with growth-related loaders.
struct PatientHeaderLoader {
    private static let log = Logger(subsystem: "Yunastic.PatientViewerApp", category: "PatientHeaderLoader")

    /// Returns the first patient's full name as "First Last" from the `patients` table.
    /// Bundles are expected to contain a single patient, so we take the first row.
    static func fetchPatientFullName(dbPath: String) -> String? {
        do {
            let db = try Connection(dbPath)
            let patients = Table("patients")

            let firstName = Expression<String>("first_name")
            let lastName  = Expression<String>("last_name")

            guard let row = try db.pluck(patients.limit(1)) else {
                Self.log.debug("No patient row found in patients table.")
                return nil
            }

            let fn = row[firstName].trimmingCharacters(in: .whitespacesAndNewlines)
            let ln = row[lastName].trimmingCharacters(in: .whitespacesAndNewlines)
            let full = ([fn, ln].filter { !$0.isEmpty }).joined(separator: " ")

            return full.isEmpty ? nil : full
        } catch {
            Self.log.error("fetchPatientFullName failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

