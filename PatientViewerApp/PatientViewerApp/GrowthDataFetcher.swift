import Foundation
import SQLite

struct GrowthDataPoint {
    let ageMonths: Double
    let value: Double
}

class GrowthDataFetcher {
    static func getPatientId(from dbPath: String) -> Int64? {
        do {
            let db = try Connection(dbPath)
            let patients = Table("patients")
            let patientIdCol = Expression<Int64>("id")
            if let row = try db.pluck(patients) {
                return try row.get(patientIdCol)
            }
        } catch {
            print("[ERROR] Could not retrieve patient ID: \(error)")
        }
        return nil
    }
    static func fetchGrowthData(dbPath: String, patientID: Int64, measurement: String) -> [GrowthDataPoint] {
        let db: Connection
        do {
            db = try Connection(dbPath)
        } catch {
            print("[ERROR] Failed to connect to database: \(error)")
            return []
        }

        let colMap: [String: String] = [
            "weight": "weight_kg",
            "height": "height_cm",
            "head_circ": "head_circumference_cm"
        ]

        guard let column = colMap[measurement] else {
            print("[ERROR] Invalid measurement type: \(measurement)")
            return []
        }

        var results: [GrowthDataPoint] = []

        // --- Fetch patient DOB ---
        let patients = Table("patients")
        let patientIdCol = Expression<Int64>("id")
        let dobCol = Expression<String>("dob")
        guard let patientRow = try? db.pluck(patients.filter(patientIdCol == patientID)) else {
            print("[ERROR] Failed to locate patient row for ID \(patientID)")
            return []
        }

        guard let dobStr = try? patientRow.get(dobCol) else {
            print("[ERROR] Patient row found but failed to retrieve DOB string")
            return []
        }

        print("[DEBUG] Raw DOB string from DB (ID \(patientID)): '\(dobStr)'")

        // Clean up dob string before parsing
        let dobStringCleaned = dobStr.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try multiple formatters
        let isoFormatter = ISO8601DateFormatter()
        let fallbackFormatters: [DateFormatter] = [
            {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                return df
            }(),
            {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd HH:mm:ss"
                return df
            }(),
            {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                return df
            }(),
            {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
                return df
            }()
        ]

        var parsedDOB: Date? = isoFormatter.date(from: dobStringCleaned)
        if parsedDOB == nil {
            for formatter in fallbackFormatters {
                if let date = formatter.date(from: dobStringCleaned) {
                    parsedDOB = date
                    break
                }
            }
        }

        guard let dob = parsedDOB else {
            print("[ERROR] Failed to parse DOB from '\(dobStr)' after trying all formatters")
            return []
        }

        // --- Step 1: Vitals ---
        let vitals = Table("vitals")
        let recordedAt = Expression<String>("recorded_at")
        let valueCol = Expression<Double?>(column)
        let pidCol = Expression<Int64>("patient_id")

        do {
            let rows = try db.prepare(vitals.filter(pidCol == patientID && valueCol != nil))
            for row in rows {
                guard let value = row[valueCol] else {
                    print("[WARN] Missing value for \(measurement)")
                    continue
                }

                let rawDate = row[recordedAt]
                let isoFormatter = ISO8601DateFormatter()
                let fallbackFormatter1 = DateFormatter()
                fallbackFormatter1.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                let fallbackFormatter2 = DateFormatter()
                fallbackFormatter2.dateFormat = "yyyy-MM-dd HH:mm:ss"

                guard let date = isoFormatter.date(from: rawDate)
                    ?? fallbackFormatter1.date(from: rawDate)
                    ?? fallbackFormatter2.date(from: rawDate) else {
                    print("[WARN] Could not parse date '\(rawDate)' for measurement \(measurement)")
                    continue
                }
                let ageDays = date.timeIntervalSince(dob) / 86400.0
                let ageMonths = ageDays / 30.4375
                results.append(GrowthDataPoint(ageMonths: ageMonths, value: value))
            }
        } catch {
            print("[ERROR] Failed to fetch vitals: \(error)")
        }

        // --- Step 2: Perinatal History ---
        let perinatal = Table("perinatal_history")
        let pid = Expression<Int64>("patient_id")
        let bw = Expression<Int?>("birth_weight_g")
        let dw = Expression<Int?>("discharge_weight_g")
        let bl = Expression<Double?>("birth_length_cm")
        let bhc = Expression<Double?>("birth_head_circumference_cm")

        if let row = try? db.pluck(perinatal.filter(pid == patientID)) {
            switch measurement {
            case "weight":
                if let birthWeight = try? row.get(bw), birthWeight > 0 {
                    results.append(GrowthDataPoint(ageMonths: 0.0, value: Double(birthWeight) / 1000))
                }
                if let dischargeWeight = try? row.get(dw), dischargeWeight > 0 {
                    results.append(GrowthDataPoint(ageMonths: 0.07, value: Double(dischargeWeight) / 1000))
                }
            case "height":
                if let birthLength = try? row.get(bl), birthLength > 0 {
                    results.append(GrowthDataPoint(ageMonths: 0.0, value: birthLength))
                }
            case "head_circ":
                if let birthHC = try? row.get(bhc), birthHC > 0 {
                    results.append(GrowthDataPoint(ageMonths: 0.0, value: birthHC))
                }
            default:
                break
            }
        }

        return results.sorted(by: { $0.ageMonths < $1.ageMonths })
    }

    static func fetchAllGrowthData(dbPath: String, patientID: Int64? = nil) -> (patientSex: String, allData: [String: [GrowthDataPoint]]) {
        let db: Connection
        do {
            db = try Connection(dbPath)
        } catch {
            print("[ERROR] Failed to connect to database: \(error)")
            return ("M", [:])
        }

        let patients = Table("patients")
        let patientIdCol = Expression<Int64>("id")
        let sexCol = Expression<String>("sex")

        guard let row = try? db.pluck(patients),
              let pid = try? row.get(patientIdCol),
              let rawSex = try? row.get(sexCol).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            print("[ERROR] Failed to retrieve patient ID and sex")
            return ("M", [:])
        }

        let patientSex = (rawSex == "female") ? "F" : "M"

        let measurements = ["weight", "height", "head_circ"]
        var allData: [String: [GrowthDataPoint]] = [:]

        for measurement in measurements {
            let dataPoints = fetchGrowthData(dbPath: dbPath, patientID: pid, measurement: measurement)
            allData[measurement] = dataPoints
        }

        return (patientSex, allData)
    }
}//
//  GrowthDataFetcher.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/12/25.
//

