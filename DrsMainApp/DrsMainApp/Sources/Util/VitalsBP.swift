//
//  VitalsBP.swift
//  DrsMainApp
//
//  Created by yunastic on 11/15/25.
//

import Foundation

// MARK: - Localization (file-local)
@inline(__always)
private func L(_ key: String, _ comment: String = "") -> String {
    NSLocalizedString(key, comment: comment)
}

@inline(__always)
private func Lf(_ key: String, _ comment: String = "", _ args: CVarArg...) -> String {
    String(format: L(key, comment), locale: Locale.current, arguments: args)
}

// MARK: - Public API

public enum BPCategory: String, Codable {
    case normal, elevated, low, stage1, stage2, unknown
}

public struct BPClassification {
    public let category: BPCategory
    public let message: String?
    public init(category: BPCategory, message: String? = nil) {
        self.category = category
        self.message = message
    }
}

public enum VitalsBP {
    /// Classify pediatric BP using AAP 2017 thresholds.
    /// - Parameters:
    ///   - sex: "M"/"F" (case-insensitive; anything starting with "m" → boys table).
    ///   - ageYears: Age in years (fractional).
    ///   - heightCm: Optional height in cm; improves matching if the table has height_cm.
    ///   - sys: Systolic BP (mmHg).
    ///   - dia: Diastolic BP (mmHg).
    /// - Returns: (category, optional explanatory message).
    public static func classify(
        sex: String,
        ageYears: Double?,
        heightCm: Double?,
        sys: Double?,
        dia: Double?
    ) -> BPClassification {
        guard let age = ageYears, let s = sys, let d = dia else {
            return BPClassification(category: .unknown, message: nil)
        }
        // Pediatric hypotension (PALS) — systolic thresholds
        let lowThresh = hypotensionThresholdSystolic(ageYears: age)
        if s < lowThresh {
            let msg = Lf(
                "bp.msg.low",
                "Hypotension classification message.",
                Int(s),
                Int(d),
                categoryLabel(.low),
                Int(lowThresh)
            )
            return BPClassification(category: .low, message: msg)
        }
        // For infants < 1 year, we only apply PALS hypotension thresholds;
        // AAP 2017 hypertension tables are not intended for this age group.
        if age < 1.0 {
            let msg = Lf(
                "bp.msg.infant_ok",
                "Infant BP acceptable range message.",
                Int(s),
                Int(d),
                Int(lowThresh)
            )
            return BPClassification(category: .normal, message: msg)
        }
        guard let rows = loadRows(for: sex), !rows.isEmpty else {
            return BPClassification(category: .unknown, message: L("bp.msg.table_missing", "BP reference table missing."))
        }
        guard let ref = nearestRow(in: rows, ageYears: age, heightCm: heightCm) else {
            return BPClassification(category: .unknown, message: L("bp.msg.no_row", "No matching BP reference row."))
        }

        // Stage 2 thresholds: explicit if present; otherwise p95 + 12 rule.
        let s2Sys = ref.p95_sys_plus_12 ?? (ref.p95_sys.map { $0 + 12.0 })
        let s2Dia = ref.p95_dia_plus_12 ?? (ref.p95_dia.map { $0 + 12.0 })

        var category: BPCategory = .unknown
        if let p95s = ref.p95_sys, let p95d = ref.p95_dia,
           let p90s = ref.p90_sys, let p90d = ref.p90_dia {

            if (s2Sys != nil && s >= s2Sys!) || (s2Dia != nil && d >= s2Dia!) {
                category = .stage2
            } else if s >= p95s || d >= p95d {
                category = .stage1
            } else if s >= p90s || d >= p90d {
                category = .elevated
            } else {
                category = .normal
            }
        }

        let label = categoryLabel(category)

        let msg = (category == .unknown)
            ? nil
            : Lf(
                "bp.msg.classified",
                "BP classification message.",
                Int(s),
                Int(d),
                label
            )

        return BPClassification(category: category, message: msg)
    }

    private static func categoryLabel(_ category: BPCategory) -> String {
        switch category {
        case .normal:
            return L("bp.label.normal", "BP category label: Normal")
        case .elevated:
            return L("bp.label.elevated", "BP category label: Elevated")
        case .low:
            return L("bp.label.low", "BP category label: Low")
        case .stage1:
            return L("bp.label.stage1", "BP category label: Stage 1")
        case .stage2:
            return L("bp.label.stage2", "BP category label: Stage 2")
        case .unknown:
            return L("bp.label.unknown", "BP category label: Unknown")
        }
    }
}

// MARK: - Internal Row & Loader

private struct BPRow {
    let age_years: Double
    let height_cm: Double?
    let height_p: Double?
    let p90_sys: Double?
    let p95_sys: Double?
    let p90_dia: Double?
    let p95_dia: Double?
    let p95_sys_plus_12: Double?
    let p95_dia_plus_12: Double?
}

private enum Loader {
    // Cache by "boys"/"girls"
    static var cache: [String: [BPRow]] = [:]
}

private extension VitalsBP {
    /// Load and parse the appropriate CSV for sex.
    /// Accepts either blue-folder "BP/..." or plain resources.
    static func loadRows(for sex: String) -> [BPRow]? {
        let key = sex.lowercased().hasPrefix("m") ? "boys" : "girls"
        if let cached = Loader.cache[key] { return cached }

        let filename = key == "boys" ? "aap2017_bp_boys" : "aap2017_bp_girls"

        // Try common bundle locations first
        let candidates: [URL?] = [
            Bundle.main.url(forResource: filename, withExtension: "csv", subdirectory: "BP"),
            Bundle.main.url(forResource: "BP/\(filename)", withExtension: "csv"),
            Bundle.main.url(forResource: filename, withExtension: "csv")
        ]

        var data: Data?
        for url in candidates {
            if let u = url, let d = try? Data(contentsOf: u) {
                data = d
                break
            }
        }
        // Fallback: search all CSVs in bundle and pick matching name
        if data == nil, let urls = Bundle.main.urls(forResourcesWithExtension: "csv", subdirectory: nil) {
            if let u = urls.first(where: { $0.lastPathComponent.lowercased().contains(filename) }) {
                data = try? Data(contentsOf: u)
            }
        }
        guard let raw = data, let csv = String(data: raw, encoding: .utf8) else {
            Loader.cache[key] = []
            return Loader.cache[key]
        }

        let rows = parseCSV(csv)
        Loader.cache[key] = rows
        return rows
    }

    /// Minimal CSV parser for simple, tidy tables (commas, optional quotes).
    static func parseCSV(_ csv: String) -> [BPRow] {
        var lines = csv.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard !lines.isEmpty else { return [] }

        let headerLine = lines.removeFirst()
        let headers = splitCSVLine(headerLine).map { normalizeHeader($0) }

        var out: [BPRow] = []
        for line in lines {
            let cols = splitCSVLine(line)
            if cols.isEmpty { continue }
            let dict = Dictionary(uniqueKeysWithValues: zip(headers, cols.map { $0.trimmingCharacters(in: .whitespaces) }))

            func dbl(_ key: String) -> Double? {
                if let s = dict[key], !s.isEmpty { return Double(s) }
                return nil
            }

            // age_years is required
            guard let age = dbl("age_years") else { continue }

            let row = BPRow(
                age_years: age,
                height_cm: dbl("height_cm"),
                height_p: dbl("height_p"),
                p90_sys: dbl("p90_sys"),
                p95_sys: dbl("p95_sys"),
                p90_dia: dbl("p90_dia"),
                p95_dia: dbl("p95_dia"),
                p95_sys_plus_12: dbl("p95_sys_plus_12"),
                p95_dia_plus_12: dbl("p95_dia_plus_12")
            )
            out.append(row)
        }

        // Sort for a stable "nearest" selection.
        out.sort {
            if $0.age_years == $1.age_years {
                // Prefer rows with height_cm, then height_p close to 50
                if let a = $0.height_cm, let b = $1.height_cm {
                    return a < b
                } else if $0.height_cm != nil {
                    return true
                } else if $1.height_cm != nil {
                    return false
                } else {
                    let a = abs(($0.height_p ?? 50.0) - 50.0)
                    let b = abs(($1.height_p ?? 50.0) - 50.0)
                    return a < b
                }
            }
            return $0.age_years < $1.age_years
        }
        return out
    }

    /// Split a CSV line handling very basic quoted fields.
    static func splitCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var field = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
                continue
            }
            if char == "," && !inQuotes {
                result.append(field)
                field.removeAll(keepingCapacity: true)
            } else {
                field.append(char)
            }
        }
        result.append(field)
        return result
    }

    /// Map header variants → normalized tidy keys.
    static func normalizeHeader(_ raw: String) -> String {
        let h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")

        let map: [String: String] = [
            "age": "age_years", "age_year": "age_years", "age_years": "age_years",

            "height": "height_cm", "height_cm": "height_cm", "stature_cm": "height_cm",
            "height_p": "height_p", "height_pct": "height_p", "height_percentile": "height_p",

            "p90_sys": "p90_sys", "p90_systolic": "p90_sys", "sys_p90": "p90_sys",
            "p90_dia": "p90_dia", "p90_diastolic": "p90_dia", "dia_p90": "p90_dia",

            "p95_sys": "p95_sys", "p95_systolic": "p95_sys", "sys_p95": "p95_sys",
            "p95_dia": "p95_dia", "p95_diastolic": "p95_dia", "dia_p95": "p95_dia",

            "p95_sys_plus_12": "p95_sys_plus_12", "p95+12_sys": "p95_sys_plus_12",
            "p95_dia_plus_12": "p95_dia_plus_12", "p95+12_dia": "p95_dia_plus_12",

            "stage1_sys": "p95_sys", // tolerate alternate labeled tables by folding into p95
            "stage1_dia": "p95_dia",
            "stage2_sys": "p95_sys_plus_12",
            "stage2_dia": "p95_dia_plus_12",
        ]
        return map[h] ?? h
    }

    /// Choose nearest row by age; refine by height (cm if present; else height percentile nearest 50).
    static func nearestRow(in rows: [BPRow], ageYears: Double, heightCm: Double?) -> BPRow? {
        guard !rows.isEmpty else { return nil }
        // Nearest-by-age first
        let byAge = rows.sorted { abs($0.age_years - ageYears) < abs($1.age_years - ageYears) }
        // If we have height_cm both in table and as a value → refine among top-N
        if let h = heightCm {
            let top = byAge.prefix(20)
            let withHeight = top.compactMap { r -> (BPRow, Double)? in
                if let rc = r.height_cm { return (r, abs(rc - h)) }
                return nil
            }
            if let best = withHeight.min(by: { $0.1 < $1.1 })?.0 { return best }
        }
        // Else if height percentile available → pick closest to 50th among nearest-by-age subset
        let top = byAge.prefix(20)
        let withPct = top.compactMap { r -> (BPRow, Double)? in
            if let p = r.height_p { return (r, abs(p - 50.0)) }
            return nil
        }
        if let best = withPct.min(by: { $0.1 < $1.1 })?.0 { return best }
        // Fallback: closest by age only
        return byAge.first
    }
}

// MARK: - Hypotension (PALS) helper
private extension VitalsBP {
    /// Pediatric hypotension threshold (systolic) per PALS:
    ///  < 1 month:   &lt; 60
    ///  1–12 months: &lt; 70
    ///  1–10 years:  &lt; 70 + 2*age (years)
    ///  ≥ 10 years:  &lt; 90
    static func hypotensionThresholdSystolic(ageYears: Double) -> Double {
        // Neonate: strictly less than 1 month
        let months = ageYears * 12.0
        if months < 1.0 { return 60.0 }
        if ageYears < 1.0 { return 70.0 }
        if ageYears < 10.0 {
            let yearsInt = Double(Int(floor(ageYears)))
            return 70.0 + 2.0 * yearsInt
        }
        return 90.0
    }
}
