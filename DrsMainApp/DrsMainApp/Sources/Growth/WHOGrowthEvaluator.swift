//
//  WHOGrowthEvaluator.swift
//  DrsMainApp
//
//  Created by Nathanael on 1/22/26.
//

import Foundation

/// Local evaluator for WHO growth using LMS tables.
///
/// This reads LMS rows from `Resources/WHO/<measure>_0_5y_<sex>_lms.csv`.
/// - Column 1: age_months (Double)
/// - Column 2: L (Double)
/// - Column 3: M (Double)
/// - Column 4: S (Double)
/// - Columns 5..11 may contain z-score reference columns (ignored by this evaluator)
///
/// We compute z-score locally from LMS, and percentile from z.
enum WHOGrowthEvaluator {

    // MARK: - Public types

    enum Sex: String {
        case male = "M"
        case female = "F"
    }

    /// WHO measurement kinds supported by the LMS files.
    /// File stems should match these raw values.
    enum Kind: String {
        /// Weight-for-age
        case wfa
        /// Length/height-for-age
        case lhfa
        /// Head circumference-for-age
        case hcfa
        /// BMI-for-age
        case bmifa

        var unitLabel: String {
            switch self {
            case .wfa: return "kg"
            case .lhfa: return "cm"
            case .hcfa: return "cm"
            case .bmifa: return "kg/m²"
            }
        }
    }

    struct Result: Equatable {
        let kind: Kind
        let sex: Sex
        let ageMonths: Double
        let value: Double
        let zScore: Double
        /// 0...100
        let percentile: Double

        /// Convenience: formatted, clinician-friendly one-liner.
        var summaryLine: String {
            let p = String(format: "%.1f", percentile)
            let z = String(format: "%.2f", zScore)
            return "\(kind.rawValue.uppercased()) \(String(format: "%.2f", value)) \(kind.unitLabel) @ \(String(format: "%.2f", ageMonths)) mo → z=\(z), p=\(p)" 
        }
    }

    /// Simple trend assessment using z-scores.
    ///
    /// Intended for: “is the current point deviating meaningfully from prior trend?”
    struct TrendAssessment: Equatable {
        /// z-score at the visit.
        let current: Result

        /// Robust central tendency of previous z-scores (median). Nil if no previous.
        let previousMedianZ: Double?

        /// current.z - previousMedianZ
        let deltaZFromMedian: Double?

        /// True if abs(deltaZFromMedian) >= threshold (default 0.67 ≈ 1 centile band).
        let isSignificantShift: Bool

        /// Number of prior points used.
        let priorCount: Int

        /// Plain English summary for UI/notes.
        let narrative: String
    }

    enum GrowthError: Error, LocalizedError {
        case resourceNotFound(String)
        case malformedCSV(String)
        case noLMSForAge
        case invalidValue

        var errorDescription: String? {
            switch self {
            case .resourceNotFound(let s): return "WHO LMS file not found: \(s)"
            case .malformedCSV(let s): return "WHO LMS CSV malformed: \(s)"
            case .noLMSForAge: return "WHO LMS: no reference row for this age"
            case .invalidValue: return "WHO LMS: invalid measurement value"
            }
        }
    }

    // MARK: - Public API

    /// Evaluate a single measurement to z-score + percentile.
    /// - Parameter ageMonths: Age in months (can be fractional). Use the visit age.
    static func evaluate(
        kind: Kind,
        sex: Sex,
        ageMonths: Double,
        value: Double,
        bundle: Bundle = .main
    ) throws -> Result {
        guard ageMonths.isFinite, ageMonths >= 0 else { throw GrowthError.invalidValue }
        guard value.isFinite, value > 0 else { throw GrowthError.invalidValue }

        let table = try loadLMSTable(kind: kind, sex: sex, bundle: bundle)
        let lms = try table.lms(atAgeMonths: ageMonths)
        let z = zScore(value: value, L: lms.L, M: lms.M, S: lms.S)
        let p = percentileFromZ(z)

        return Result(
            kind: kind,
            sex: sex,
            ageMonths: ageMonths,
            value: value,
            zScore: z,
            percentile: p
        )
    }

    /// Evaluate a visit-point against prior points.
    ///
    /// - Parameters:
    ///   - prior: previous points for the same kind, each tuple is (ageMonths, value).
    ///            Provide in any order; we will sort by age.
    ///   - current: current point (ageMonths, value).
    ///   - thresholdZ: recommended 0.67 (≈ 25→50→75 centile band width),
    ///                or 1.0 (stricter), or 1.33 (~2 major centile bands).
    static func assessTrend(
        kind: Kind,
        sex: Sex,
        prior: [(ageMonths: Double, value: Double)],
        current: (ageMonths: Double, value: Double),
        thresholdZ: Double = 2.0,
        bundle: Bundle = .main
    ) throws -> TrendAssessment {

        let currentRes = try evaluate(
            kind: kind,
            sex: sex,
            ageMonths: current.ageMonths,
            value: current.value,
            bundle: bundle
        )

        let cleanedPrior = prior
            .filter { $0.ageMonths.isFinite && $0.ageMonths >= 0 && $0.value.isFinite && $0.value > 0 }
            .sorted { $0.ageMonths < $1.ageMonths }

        // No priors? Just return a basic assessment.
        guard !cleanedPrior.isEmpty else {
            return TrendAssessment(
                current: currentRes,
                previousMedianZ: nil,
                deltaZFromMedian: nil,
                isSignificantShift: false,
                priorCount: 0,
                narrative: "Only one measurement available (no prior trend to compare)."
            )
        }

        // Evaluate priors to z.
        var priorZ: [Double] = []
        priorZ.reserveCapacity(cleanedPrior.count)
        for p in cleanedPrior {
            let r = try evaluate(kind: kind, sex: sex, ageMonths: p.ageMonths, value: p.value, bundle: bundle)
            priorZ.append(r.zScore)
        }

        let med = median(priorZ)
        let delta = currentRes.zScore - med
        let significant = abs(delta) >= thresholdZ

        // Small narrative for clinicians.
        let dir = delta >= 0 ? "higher" : "lower"
        let dzText = String(format: "%.2f", abs(delta))
        let thText = String(format: "%.2f", thresholdZ)
        let pText = String(format: "%.1f", currentRes.percentile)

        let narrative: String
        if significant {
            narrative = "Current value is \(dir) than prior trend by Δz≈\(dzText) (threshold \(thText)); current ≈ P\(pText)."
        } else {
            narrative = "Current value is consistent with prior trend (Δz≈\(dzText) < \(thText)); current ≈ P\(pText)."
        }

        return TrendAssessment(
            current: currentRes,
            previousMedianZ: med,
            deltaZFromMedian: delta,
            isSignificantShift: significant,
            priorCount: priorZ.count,
            narrative: narrative
        )
    }

    /// Convenience: assess trend using only the last N prior points.
    ///
    /// This is the “simple-but-useful” rule used in the UI:
    /// - Compute z for current point.
    /// - Compute z for prior points.
    /// - Take the median z of the last N prior points (by age).
    /// - Flag if |Δz| >= thresholdZ (default 2.0 SD).
    ///
    /// - Parameters:
    ///   - lastN: How many prior points to consider (most recent by age). Typical 3–6.
    static func assessTrendLastN(
        kind: Kind,
        sex: Sex,
        prior: [(ageMonths: Double, value: Double)],
        current: (ageMonths: Double, value: Double),
        lastN: Int = 5,
        thresholdZ: Double = 2.0,
        bundle: Bundle = .main
    ) throws -> TrendAssessment {

        let cleanedPrior = prior
            .filter { $0.ageMonths.isFinite && $0.ageMonths >= 0 && $0.value.isFinite && $0.value > 0 }
            .sorted { $0.ageMonths < $1.ageMonths }

        // Keep only the last N points (most recent by age).
        let n = max(0, lastN)
        let slicedPrior: [(ageMonths: Double, value: Double)]
        if n == 0 {
            slicedPrior = []
        } else if cleanedPrior.count <= n {
            slicedPrior = cleanedPrior
        } else {
            slicedPrior = Array(cleanedPrior.suffix(n))
        }

        return try assessTrend(
            kind: kind,
            sex: sex,
            prior: slicedPrior,
            current: current,
            thresholdZ: thresholdZ,
            bundle: bundle
        )
    }

    // MARK: - LMS loading

    private struct LMS: Equatable {
        let ageMonths: Double
        let L: Double
        let M: Double
        let S: Double
    }

    private struct LMSTable {
        let rows: [LMS] // sorted by ageMonths

        func lms(atAgeMonths target: Double) throws -> LMS {
            guard !rows.isEmpty else { throw GrowthError.noLMSForAge }

            // Clamp to bounds.
            if target <= rows[0].ageMonths { return rows[0] }
            if target >= rows[rows.count - 1].ageMonths { return rows[rows.count - 1] }

            // Binary search for insertion point.
            var lo = 0
            var hi = rows.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let a = rows[mid].ageMonths
                if a == target { return rows[mid] }
                if a < target {
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }

            // `lo` is first index with age > target; interpolate between lo-1 and lo.
            let upperIdx = max(1, min(lo, rows.count - 1))
            let lowerIdx = upperIdx - 1
            let lower = rows[lowerIdx]
            let upper = rows[upperIdx]

            let span = upper.ageMonths - lower.ageMonths
            if span <= 0 {
                return lower
            }
            let t = (target - lower.ageMonths) / span

            // Linear interpolation on L/M/S is standard and good enough for fractional months.
            let L = lerp(lower.L, upper.L, t)
            let M = lerp(lower.M, upper.M, t)
            let S = lerp(lower.S, upper.S, t)

            return LMS(ageMonths: target, L: L, M: M, S: S)
        }
    }

    // Cache loaded tables to avoid repeated disk IO.
    private static var cache: [String: LMSTable] = [:]
    private static let cacheQueue = DispatchQueue(label: "who.lms.cache.queue", qos: .userInitiated)

    private static func loadLMSTable(kind: Kind, sex: Sex, bundle: Bundle) throws -> LMSTable {
        let fileStem = "\(kind.rawValue)_0_5y_\(sex.rawValue)_lms"
        let cacheKey = fileStem

        if let cached = cacheQueue.sync(execute: { cache[cacheKey] }) {
            return cached
        }

        guard let url = bundle.url(forResource: fileStem, withExtension: "csv", subdirectory: "WHO") else {
            throw GrowthError.resourceNotFound("WHO/\(fileStem).csv")
        }

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw GrowthError.malformedCSV("cannot decode utf8/latin1")
        }

        let table = try parseLMSTable(fromCSV: text)

        cacheQueue.sync {
            cache[cacheKey] = table
        }

        return table
    }

    private static func parseLMSTable(fromCSV text: String) throws -> LMSTable {
        // Handle CRLF and blank lines.
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)

        guard !lines.isEmpty else {
            throw GrowthError.malformedCSV("empty")
        }

        // Determine if first row is header (non-numeric in col1).
        var startIndex = 0
        if let first = lines.first {
            let cols = splitCSVRow(String(first))
            if cols.count >= 4 {
                if Double(cols[0].trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
                    startIndex = 1
                }
            }
        }

        var rows: [LMS] = []
        rows.reserveCapacity(max(0, lines.count - startIndex))

        for i in startIndex..<lines.count {
            let cols = splitCSVRow(String(lines[i]))
            guard cols.count >= 4 else { continue }

            let aStr = cols[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let lStr = cols[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let mStr = cols[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let sStr = cols[3].trimmingCharacters(in: .whitespacesAndNewlines)

            guard let age = Double(aStr), let L = Double(lStr), let M = Double(mStr), let S = Double(sStr) else {
                continue
            }
            // Basic sanity.
            if !age.isFinite || age < 0 { continue }
            if !L.isFinite || !M.isFinite || !S.isFinite { continue }
            if M <= 0 || S <= 0 { continue }

            rows.append(LMS(ageMonths: age, L: L, M: M, S: S))
        }

        guard !rows.isEmpty else {
            throw GrowthError.malformedCSV("no numeric rows")
        }

        rows.sort { $0.ageMonths < $1.ageMonths }
        return LMSTable(rows: rows)
    }

    /// Basic CSV split that respects quoted fields.
    /// We only need it to read numeric columns, but keep it robust.
    private static func splitCSVRow(_ row: String) -> [String] {
        var out: [String] = []
        out.reserveCapacity(12)

        var current = ""
        var inQuotes = false
        var it = row.makeIterator()

        while let ch = it.next() {
            switch ch {
            case "\"":
                inQuotes.toggle()
            case ",":
                if inQuotes {
                    current.append(ch)
                } else {
                    out.append(current)
                    current = ""
                }
            default:
                current.append(ch)
            }
        }
        out.append(current)
        return out
    }

    // MARK: - Math

    /// WHO LMS → z score
    ///
    /// If L == 0: z = ln(value/M) / S
    /// else: z = ((value/M)^L - 1) / (L*S)
    private static func zScore(value: Double, L: Double, M: Double, S: Double) -> Double {
        if L == 0 {
            return log(value / M) / S
        }
        return (pow(value / M, L) - 1.0) / (L * S)
    }

    /// Convert z-score to percentile (0..100) using standard normal CDF.
    private static func percentileFromZ(_ z: Double) -> Double {
        let cdf = normalCDF(z)
        // clamp
        let p = max(0.0, min(1.0, cdf))
        return p * 100.0
    }

    /// Standard normal CDF approximation using erf.
    private static func normalCDF(_ x: Double) -> Double {
        // Φ(x) = 0.5 * (1 + erf(x / sqrt(2)))
        return 0.5 * (1.0 + erfApprox(x / sqrt(2.0)))
    }

    /// Fast erf approximation (Abramowitz & Stegun 7.1.26).
    private static func erfApprox(_ x: Double) -> Double {
        // Constants
        let a1 = 0.254829592
        let a2 = -0.284496736
        let a3 = 1.421413741
        let a4 = -1.453152027
        let a5 = 1.061405429
        let p  = 0.3275911

        let sign: Double = x < 0 ? -1 : 1
        let t = 1.0 / (1.0 + p * abs(x))
        let y = 1.0 - (((((a5 * t + a4) * t + a3) * t + a2) * t + a1) * t) * exp(-x * x)
        return sign * y
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let n = s.count
        if n % 2 == 1 {
            return s[n / 2]
        } else {
            return 0.5 * (s[n/2 - 1] + s[n/2])
        }
    }
}
