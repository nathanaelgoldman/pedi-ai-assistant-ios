import Foundation
import SQLite
import os

// Keep this single definition in the project to avoid redeclarations elsewhere.
public struct GrowthDataPoint {
    public let ageMonths: Swift.Double
    public let value: Swift.Double
}

final class GrowthDataFetcher {

    // MARK: - Logging
    private static let log = Logger(subsystem: "com.yunastic.PatientViewerApp", category: "GrowthDataFetcher")

    // MARK: - Constants
    private static let secondsPerDay: Swift.Double = 86_400.0
    private static let daysPerMonth: Swift.Double = 30.4375

    // MARK: - Date parsing (shared, cached formatters)
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let fallbackFormatters: [DateFormatter] = {
        let posix = Locale(identifier: "en_US_POSIX")
        let tz = TimeZone(secondsFromGMT: 0)
        let fmts = ["yyyy-MM-dd'T'HH:mm:ss",
                    "yyyy-MM-dd HH:mm:ss",
                    "yyyy-MM-dd",
                    "yyyy-MM-dd HH:mm:ss.SSS"]
        return fmts.map {
            let df = DateFormatter()
            df.locale = posix
            df.timeZone = tz
            df.dateFormat = $0
            return df
        }
    }()

    private static func parseDate(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = isoFormatter.date(from: trimmed) { return d }
        if let d = isoFormatterNoFrac.date(from: trimmed) { return d }
        for df in fallbackFormatters {
            if let d = df.date(from: trimmed) { return d }
        }
        return nil
    }

    // MARK: - Public API

    static func getPatientId(from dbPath: String) -> Int64? {
        do {
            let db = try Connection(dbPath)
            let patients = Table("patients")
            let idCol = Expression<Int64>("id")
            if let row = try db.pluck(patients) {
                let pid = try row.get(idCol)
                log.debug("getPatientId: returning \(pid, privacy: .public)")
                return pid
            } else {
                log.error("getPatientId: patients table is empty")
            }
        } catch {
            log.error("getPatientId: failed to read DB: \(String(describing: error), privacy: .public)")
        }
        return nil
    }

    /// Fetch growth datapoints for a single measurement ("weight" | "height" | "head_circ")
    static func fetchGrowthData(dbPath: String, patientID: Int64, measurement: String) -> [GrowthDataPoint] {

        // Map measurement -> column name in `vitals`
        let colMap: [String: String] = [
            "weight": "weight_kg",
            "height": "height_cm",
            "head_circ": "head_circumference_cm"
        ]
        guard let vitalsColumn = colMap[measurement] else {
            log.error("fetchGrowthData: invalid measurement '\(measurement, privacy: .public)'")
            return []
        }

        // Open DB
        let db: Connection
        do {
            db = try Connection(dbPath)
        } catch {
            log.error("fetchGrowthData: failed to connect DB: \(String(describing: error), privacy: .public)")
            return []
        }

        // --- Obtain DOB from patients row ---
        let patients = Table("patients")
        let idCol = Expression<Int64>("id")
        let dobCol = Expression<String>("dob")

        guard
            let patientRow = try? db.pluck(patients.filter(idCol == patientID)),
            let rawDOB = try? patientRow.get(dobCol)
        else {
            log.error("fetchGrowthData: could not fetch DOB for patient \(patientID, privacy: .public)")
            return []
        }

        log.debug("fetchGrowthData: raw DOB string for \(patientID, privacy: .public) = '\(rawDOB, privacy: .public)'")

        guard let dob = parseDate(rawDOB) else {
            log.error("fetchGrowthData: failed to parse DOB '\(rawDOB, privacy: .public)'")
            return []
        }

        var results: [GrowthDataPoint] = []

        // --- Step 1: manual_growth rows for this patient / measurement ---
        let manualGrowth = Table("manual_growth")
        let recAtCol = Expression<String>("recorded_at")
        let valueCol = Expression<Swift.Double?>(vitalsColumn) // allow NULLs
        let pidCol = Expression<Int64>("patient_id")

        do {
            for row in try db.prepare(manualGrowth.filter(pidCol == patientID && valueCol != nil)) {
                guard let value = row[valueCol] else {
                    log.warning("fetchGrowthData: nil value for \(measurement, privacy: .public)")
                    continue
                }
                // Filter out non-sensical/invalid numeric values early
                guard value.isFinite, value > 0 else {
                    log.warning("fetchGrowthData: invalid value \(value, privacy: .public) for \(measurement, privacy: .public); skipping")
                    continue
                }

                let rawWhen = row[recAtCol]
                guard let when = parseDate(rawWhen) else {
                    log.warning("fetchGrowthData: unparseable date '\(rawWhen, privacy: .public)'")
                    continue
                }

                let ageDays = when.timeIntervalSince(dob) / secondsPerDay
                var ageMonths = ageDays / daysPerMonth

                if ageMonths < 0 {
                    log.warning("fetchGrowthData: negative age \(ageMonths, privacy: .public) for date '\(rawWhen, privacy: .public)'; clamping to 0.0")
                    ageMonths = 0.0
                }

                results.append(GrowthDataPoint(ageMonths: ageMonths, value: value))
            }
        } catch {
            log.error("fetchGrowthData: query manual_growth failed: \(String(describing: error), privacy: .public)")
        }

        // Helper to avoid double-counting obvious duplicates when adding perinatal baselines.
        func hasPoint(nearAge targetAge: Swift.Double, value targetValue: Swift.Double,
                      ageTolerance: Swift.Double = 0.02,
                      valueTolerance: Swift.Double = 0.001) -> Bool {
            results.contains { point in
                abs(point.ageMonths - targetAge) <= ageTolerance &&
                abs(point.value - targetValue) <= valueTolerance
            }
        }

        // --- Step 2: Perinatal history (optional baseline points) ---
        let perinatal = Table("perinatal_history")
        let perinatalPID = Expression<Int64>("patient_id")

        // Always read as optional columns to handle both NULL and non-NULL schemas
        let bwGCol   = Expression<Int?>("birth_weight_g")
        let dwGCol   = Expression<Int?>("discharge_weight_g")
        let blCmCol  = Expression<Swift.Double?>("birth_length_cm")
        let bhcCmCol = Expression<Swift.Double?>("birth_head_circumference_cm")

        if let row = try? db.pluck(perinatal.filter(perinatalPID == patientID)) {
            switch measurement {
            case "weight":
                let birthG: Int? = (try? row.get(bwGCol)) ?? nil
                if let g = birthG, g > 0 {
                    let valKg = Swift.Double(g) / 1000.0
                    if !hasPoint(nearAge: 0.0, value: valKg) {
                        results.append(GrowthDataPoint(ageMonths: 0.0, value: valKg))
                    }
                }
                let dischargeG: Int? = (try? row.get(dwGCol)) ?? nil
                if let g = dischargeG, g > 0 {
                    let valKg = Swift.Double(g) / 1000.0
                    // ~2 days ~ 0.07 months for a visible baseline before first check
                    if !hasPoint(nearAge: 0.07, value: valKg) {
                        results.append(GrowthDataPoint(ageMonths: 0.07, value: valKg))
                    }
                }

            case "height":
                let birthLen: Swift.Double? = (try? row.get(blCmCol)) ?? nil
                if let cm = birthLen, cm > 0 {
                    results.append(GrowthDataPoint(ageMonths: 0.0, value: cm))
                }

            case "head_circ":
                let birthHC: Swift.Double? = (try? row.get(bhcCmCol)) ?? nil
                if let cm = birthHC, cm > 0 {
                    results.append(GrowthDataPoint(ageMonths: 0.0, value: cm))
                }

            default:
                break
            }
        }

        let sorted = results.sorted(by: { $0.ageMonths < $1.ageMonths })
        log.debug("fetchGrowthData: returning \(sorted.count, privacy: .public) point(s) for \(measurement, privacy: .public)")
        return sorted
    }

    /// Fetch sex and all measurement series. If `patientID` is nil, the first row in `patients` is used.
    static func fetchAllGrowthData(dbPath: String, patientID: Int64? = nil) -> (patientSex: String, allData: [String: [GrowthDataPoint]]) {

        let db: Connection
        do {
            db = try Connection(dbPath)
        } catch {
            log.error("fetchAllGrowthData: failed to connect DB: \(String(describing: error), privacy: .public)")
            return ("M", [:])
        }

        let patients = Table("patients")
        let idCol = Expression<Int64>("id")
        let sexCol = Expression<String>("sex")

        var resolvedPID: Int64?
        var sexRaw: String?

        if let pid = patientID {
            resolvedPID = pid
            // Try to read sex for the specific patientID; fall back later if needed
            if let row = try? db.pluck(patients.filter(idCol == pid)) {
                sexRaw = try? row.get(sexCol)
            }
        } else if let row = try? db.pluck(patients) {
            resolvedPID = try? row.get(idCol)
            sexRaw = try? row.get(sexCol)
        }

        guard let pid = resolvedPID else {
            log.error("fetchAllGrowthData: could not resolve patient ID")
            return ("M", [:])
        }

        let normalizedSex = (sexRaw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let patientSex = (normalizedSex == "female" || normalizedSex == "f") ? "F" : "M"

        let measurements = ["weight", "height", "head_circ"]
        var allData: [String: [GrowthDataPoint]] = [:]

        for m in measurements {
            let pts = fetchGrowthData(dbPath: dbPath, patientID: pid, measurement: m)
            allData[m] = pts
        }

        log.debug("fetchAllGrowthData: built series for patient \(pid, privacy: .public) sex=\(patientSex, privacy: .public)")
        return (patientSex, allData)
    }
}
