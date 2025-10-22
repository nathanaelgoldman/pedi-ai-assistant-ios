import Foundation
import SQLite3

func loadVitalsData(from dbURL: URL) -> [String: [GrowthDataPoint]] {
    var db: OpaquePointer?
    var result: [String: [GrowthDataPoint]] = [
        "weight": [],
        "height": [],
        "head_circ": []
    ]

    if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
        print("❌ Failed to open database")
        return result
    }

    defer {
        sqlite3_close(db)
    }

    let query = "SELECT age_months, weight, height, head_circ FROM vitals WHERE weight IS NOT NULL OR height IS NOT NULL OR head_circ IS NOT NULL"
    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
        while sqlite3_step(stmt) == SQLITE_ROW {
            let age = sqlite3_column_double(stmt, 0)
            let weight = sqlite3_column_double(stmt, 1)
            let height = sqlite3_column_double(stmt, 2)
            let headCirc = sqlite3_column_double(stmt, 3)

            if weight > 0 {
                result["weight"]?.append(GrowthDataPoint(ageMonths: age, value: weight))
            }
            if height > 0 {
                result["height"]?.append(GrowthDataPoint(ageMonths: age, value: height))
            }
            if headCirc > 0 {
                result["head_circ"]?.append(GrowthDataPoint(ageMonths: age, value: headCirc))
            }
        }
        sqlite3_finalize(stmt)
    } else {
        print("❌ Failed to prepare query")
    }

    return result
}

func loadPatientSex(from dbURL: URL) -> String {
    var db: OpaquePointer?
    var sex: String = "M"

    if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
        print("❌ Failed to open DB for sex check")
        return sex
    }

    defer {
        sqlite3_close(db)
    }

    let query = "SELECT sex FROM patients LIMIT 1"
    var stmt: OpaquePointer?

    if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let sexCStr = sqlite3_column_text(stmt, 0) {
                sex = String(cString: sexCStr).uppercased()
                if sex != "M" && sex != "F" {
                    sex = "M"  // fallback
                }
            }
        }
        sqlite3_finalize(stmt)
    }

    return sex
}//
//  db.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/12/25.
//

