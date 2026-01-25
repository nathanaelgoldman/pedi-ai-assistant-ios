//
//  WHOGrowthEvaluator.swift
//  DrsMainApp
//
//  Created by Nathanael on 1/22/26.
//

import Foundation

// MARK: - Localization helpers
private func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

private func LF(_ formatKey: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(formatKey, comment: ""), arguments: args)
}



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
        
        /// Localization key for the human-friendly name of this measure.
        var nameKey: String {
            switch self {
            case .wfa:   return "who.growth.kind.weight"
            case .lhfa:  return "who.growth.kind.length_height"
            case .hcfa:  return "who.growth.kind.head_circumference"
            case .bmifa: return "who.growth.kind.bmi"
            }
        }

        /// Localized, human-friendly name (e.g., "Weight", "Length/Height").
        func displayName(bundle: Bundle = .main) -> String {
            NSLocalizedString(nameKey, bundle: bundle, comment: "")
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
            let kindName = kind.displayName()
            return "\(kindName) \(String(format: "%.2f", value)) \(kind.unitLabel) @ \(String(format: "%.2f", ageMonths)) mo → z=\(z), p=\(p)"
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
            case .resourceNotFound(let s):
                return LF("who_growth.error.resource_not_found", s)
            case .malformedCSV(let s):
                return LF("who_growth.error.malformed_csv", s)
            case .noLMSForAge:
                return L("who_growth.error.no_lms_for_age")
            case .invalidValue:
                return L("who_growth.error.invalid_value")
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
                narrative: L("well_visit_form.growth_trend.only_one_point")
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
        let significantZShift = abs(delta) >= thresholdZ

        #if DEBUG
        let ageText = String(format: "%.2f", currentRes.ageMonths)
        let valText = String(format: "%.2f", currentRes.value)
        let zText   = String(format: "%.3f", currentRes.zScore)
        print("WHO TREND \(kind.rawValue): current ageMo=\(ageText) value=\(valText) z=\(zText)")

        let medText = String(format: "%.3f", med)
        let dText   = String(format: "%.3f", delta)
        let thTextD = String(format: "%.2f", thresholdZ)
        print("WHO TREND \(kind.rawValue): priorCount=\(priorZ.count) medianZ=\(medText) deltaZ=\(dText) thresholdZ=\(thTextD)")
        #endif

        // --- Extra: robust trajectory deviation check (Theil–Sen + MAD) ---
        // Runs for all measures when we have enough prior points.
        var trajectoryConcern = false
        var trajectoryMsg: String? = nil
        #if DEBUG
        print("WHO TREND \(kind.rawValue): cleanedPrior.count=\(cleanedPrior.count)")
        #endif
        if cleanedPrior.count >= 3 {
            var priorPoints: [(ageMonths: Double, z: Double)] = []
            priorPoints.reserveCapacity(cleanedPrior.count)
            for i in 0..<cleanedPrior.count {
                priorPoints.append((ageMonths: cleanedPrior[i].ageMonths, z: priorZ[i]))
            }

            if let traj = assessTrajectoryDeviation(
                prior: priorPoints,
                currentAgeMonths: currentRes.ageMonths,
                currentZ: currentRes.zScore,
                scoreThreshold: 2.5,
                sigmaFloor: trajectorySigmaFloor(for: kind)
            ) {
                trajectoryConcern = traj.isConcern
                if traj.isConcern {
                    let dir = traj.residual >= 0 ? L("well_visit_form.growth_trend.higher") : L("well_visit_form.growth_trend.lower")
                    let scoreText = String(format: "%.2f", traj.score)
                    let thText = String(format: "%.2f", traj.threshold)
                    trajectoryMsg = LF("well_visit_form.growth_trend.trajectory_deviation", dir, scoreText, thText)
                }

                #if DEBUG
                let expText  = String(format: "%.3f", traj.expectedZ)
                let resText  = String(format: "%.3f", traj.residual)
                let sigText  = String(format: "%.3f", traj.sigma)
                let scoreTxt = String(format: "%.2f", traj.score)
                let thTxt    = String(format: "%.2f", traj.threshold)
                print("WHO TRAJ \(kind.rawValue): expectedZ=\(expText) residual=\(resText) sigma=\(sigText) score=\(scoreTxt) th=\(thTxt)")
                #endif
            }
        }

        // Small narrative for clinicians.
        let dir = delta >= 0 ? L("well_visit_form.growth_trend.higher") : L("well_visit_form.growth_trend.lower")
        let dzText = String(format: "%.2f", abs(delta))
        let thText = String(format: "%.2f", thresholdZ)
        let pText = String(format: "%.1f", currentRes.percentile)

        // --- Extra: weight-for-age velocity check (WHO median gain vs observed gain) ---
        // Goal: catch visually obvious growth faltering even when Δz-to-median is small.
        var velocityConcern = false
        var velocityMsg: String? = nil
        if kind == .wfa, let first = cleanedPrior.first {
            let durationMonths = max(0.0, current.ageMonths - first.ageMonths)
            // Only evaluate if the window is long enough to be meaningful.
            if durationMonths >= 1.0 {
                do {
                    let table = try loadLMSTable(kind: kind, sex: sex, bundle: bundle)
                    let lmsStart = try table.lms(atAgeMonths: first.ageMonths)
                    let lmsEnd   = try table.lms(atAgeMonths: current.ageMonths)

                    // WHO median (M) is in kg for WFA.
                    let expectedGainKg = lmsEnd.M - lmsStart.M
                    let observedGainKg = current.value - first.value

                    let durText = String(format: "%.1f", durationMonths)
                    let obsText = String(format: "%.2f", observedGainKg)
                    let expText = String(format: "%.2f", expectedGainKg)

                    if observedGainKg < 0 {
                        velocityConcern = true
                        velocityMsg = LF("well_visit_form.growth_trend.wfa_weight_loss", obsText, durText)
                    } else {
                        // Two regimes:
                        // 1) Expected gain is meaningful (infants / active growth): compare ratio.
                        // 2) Expected gain is small (older toddlers): require very small observed gain over a longer window.
                        let meaningfulExpected = expectedGainKg >= 0.10
                        if meaningfulExpected {
                            let ratio = (expectedGainKg > 0) ? (observedGainKg / expectedGainKg) : 1.0
                            // Flag if gain is substantially below WHO-median expectation.
                            if ratio < 0.60 {
                                velocityConcern = true
                                velocityMsg = LF("well_visit_form.growth_trend.wfa_velocity_low", obsText, expText, durText)
                            }
                        } else {
                            // If expected gain is tiny, we only worry if the window is long and gain is almost nil.
                            if durationMonths >= 3.0 && observedGainKg < 0.05 {
                                velocityConcern = true
                                velocityMsg = LF("well_visit_form.growth_trend.wfa_velocity_low", obsText, expText, durText)
                            }
                        }
                    }
                } catch {
                    // Best-effort; if we cannot compute expected gain, skip velocity check.
                    velocityConcern = false
                    velocityMsg = nil
                }
            }
        }

        let overallSignificant = significantZShift || velocityConcern || trajectoryConcern

        // Build a single coherent narrative (avoid contradictions).
        let base: String
        if significantZShift {
            base = LF("well_visit_form.growth_trend.significant", dir, dzText, thText, pText)
        } else if velocityConcern || trajectoryConcern {
            base = L("well_visit_form.growth_trend.concern")
        } else {
            base = LF("well_visit_form.growth_trend.consistent", dzText, thText, pText)
        }

        var extras: [String] = []
        if let m = trajectoryMsg, trajectoryConcern {
            extras.append(m)
        }
        if let m = velocityMsg, velocityConcern {
            extras.append(m)
        }

        let narrative = ([base] + extras).joined(separator: "\n")

        return TrendAssessment(
            current: currentRes,
            previousMedianZ: med,
            deltaZFromMedian: delta,
            isSignificantShift: overallSignificant,
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

        let candidates: [(subdir: String?, label: String)] = [
            ("WHO", "WHO"),
            ("Resources/WHO", "Resources/WHO"),
            (nil, "(root)")
        ]

        var foundURL: URL? = nil
        for c in candidates {
            if let u = bundle.url(forResource: fileStem, withExtension: "csv", subdirectory: c.subdir) {
                foundURL = u
                break
            }
        }

        guard let url = foundURL else {
            throw GrowthError.resourceNotFound("Tried: WHO/\(fileStem).csv, Resources/WHO/\(fileStem).csv, and bundle root \(fileStem).csv")
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

    // MARK: - Robust trajectory helpers (Theil–Sen + MAD)

    /// Minimum noise scale (in z-score units) used by the trajectory model.
    /// Prevents over-flagging when historical scatter (MAD) is extremely small.
    private static func trajectorySigmaFloor(for kind: Kind) -> Double {
        switch kind {
        case .wfa:
            return 0.30
        case .lhfa:
            return 0.35
        case .hcfa:
            return 0.45
        case .bmifa:
            return 0.35
        }
    }

    private struct TrajectoryDeviation {
        let expectedZ: Double
        let residual: Double
        let sigma: Double
        let score: Double
        let threshold: Double
        let isConcern: Bool
    }

    /// Robustly assess how surprising the current z-score is given the prior trajectory.
    /// - Uses Theil–Sen slope (median of pairwise slopes) + median intercept.
    /// - Uses MAD of prior residuals to estimate noise scale.
    /// - Returns nil if we cannot compute a stable fit (e.g., repeated ages only).
    private static func assessTrajectoryDeviation(
        prior: [(ageMonths: Double, z: Double)],
        currentAgeMonths: Double,
        currentZ: Double,
        scoreThreshold: Double,
        sigmaFloor: Double
    ) -> TrajectoryDeviation? {

        // Require >= 3 priors at call site; also ensure we have at least 3 distinct ages.
        let cleaned = prior
            .filter { $0.ageMonths.isFinite && $0.z.isFinite }
            .sorted { $0.ageMonths < $1.ageMonths }

        guard cleaned.count >= 3 else { return nil }

        // Compute Theil–Sen slope: median of all pairwise slopes.
        var slopes: [Double] = []
        slopes.reserveCapacity(cleaned.count * (cleaned.count - 1) / 2)

        for i in 0..<(cleaned.count - 1) {
            for j in (i + 1)..<cleaned.count {
                let dx = cleaned[j].ageMonths - cleaned[i].ageMonths
                if dx == 0 { continue }
                let s = (cleaned[j].z - cleaned[i].z) / dx
                if s.isFinite {
                    slopes.append(s)
                }
            }
        }

        guard !slopes.isEmpty else { return nil }
        let b = median(slopes)

        // Intercept: median(z_i - b*x_i)
        var intercepts: [Double] = []
        intercepts.reserveCapacity(cleaned.count)
        for p in cleaned {
            let a = p.z - b * p.ageMonths
            if a.isFinite {
                intercepts.append(a)
            }
        }
        guard !intercepts.isEmpty else { return nil }
        let a = median(intercepts)

        let expected = a + b * currentAgeMonths
        let residual = currentZ - expected

        // Prior residuals to estimate noise.
        var resids: [Double] = []
        resids.reserveCapacity(cleaned.count)
        for p in cleaned {
            let r = p.z - (a + b * p.ageMonths)
            if r.isFinite {
                resids.append(r)
            }
        }
        guard !resids.isEmpty else { return nil }

        let sigma = max(1.4826 * mad(resids), sigmaFloor)
        let score = abs(residual) / sigma
        let isConcern = score >= scoreThreshold

        return TrajectoryDeviation(
            expectedZ: expected,
            residual: residual,
            sigma: sigma,
            score: score,
            threshold: scoreThreshold,
            isConcern: isConcern
        )
    }

    /// Median Absolute Deviation (MAD).
    private static func mad(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let m = median(xs)
        let absDev = xs.map { abs($0 - m) }
        return median(absDev)
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
