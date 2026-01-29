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
    // MARK: - Debug logging
    #if DEBUG
    /// Toggle to enable verbose WHO growth debug logs.
    private static let debugLoggingEnabled = true
    #endif
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
        /// Weight-for-length (typically used < 2 years)
        case wfl

        var unitLabel: String {
            switch self {
            case .wfa:   return "kg"
            case .lhfa:  return "cm"
            case .hcfa:  return "cm"
            case .bmifa: return "kg/m²"
            case .wfl:   return "kg"
            }
        }
        
        /// Localization key for the human-friendly name of this measure.
        var nameKey: String {
            switch self {
            case .wfa:   return "who.growth.kind.weight"
            case .lhfa:  return "who.growth.kind.length_height"
            case .hcfa:  return "who.growth.kind.head_circumference"
            case .bmifa: return "who.growth.kind.bmi"
            case .wfl:   return "who.growth.kind.weight_for_length"
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
            let v = String(format: "%.2f", value)
            let a = String(format: "%.2f", ageMonths)
            let kindName = kind.displayName()
            return LF("who_growth.result.summary_line", kindName, v, kind.unitLabel, a, z, p)
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

        /// Threshold used to decide whether a median-based z-shift is significant.
        let thresholdZ: Double

        /// True if abs(deltaZFromMedian) >= thresholdZ.
        let isSignificantShift: Bool

        /// Number of prior points used.
        let priorCount: Int

        /// Plain English summary for UI/notes.
        let narrative: String

        /// Convenience: abs(deltaZFromMedian)
        var absDeltaZFromMedian: Double? {
            guard let d = deltaZFromMedian, d.isFinite else { return nil }
            return abs(d)
        }
    }

    // MARK: - Nutritional status (WHO z-score categories)

    enum NutritionCategory: String, CaseIterable {
        case severeThinness
        case thinness
        case healthy
        case riskOfOverweight
        case overweight
        case obesity

        /// Localization key for display (keep simple; caller can prepend context if desired).
        var labelKey: String {
            switch self {
            case .severeThinness:   return "who_growth.nutrition.severe_thinness"
            case .thinness:         return "who_growth.nutrition.thinness"
            case .healthy:          return "who_growth.nutrition.healthy"
            case .riskOfOverweight: return "who_growth.nutrition.risk_overweight"
            case .overweight:       return "who_growth.nutrition.overweight"
            case .obesity:          return "who_growth.nutrition.obesity"
            }
        }

        /// Whether this should be visually flagged in UI/report.
        var isFlagged: Bool {
            switch self {
            case .healthy:
                return false
            default:
                return true
            }
        }

        func displayLabel(bundle: Bundle = .main) -> String {
            NSLocalizedString(labelKey, bundle: bundle, comment: "")
        }
    }

    struct NutritionAssessment: Equatable {
        /// Which reference drove the assessment.
        /// - <2y: weight-for-length
        /// - >=2y: BMI-for-age
        let basisKind: Kind
        let zScore: Double
        let category: NutritionCategory

        /// Convenience: one-liner for reports/UI.
        func summaryLine(bundle: Bundle = .main) -> String {
            let basis = basisKind.displayName(bundle: bundle)
            let z = String(format: "%.2f", zScore)
            let cat = category.displayLabel(bundle: bundle)
            return LF("who_growth.nutrition.summary_line", basis, z, cat)
        }
    }

    /// Categorize nutritional status from available z-scores.
    /// - For age < 24 months: uses weight-for-length (wfl) z-score if provided.
    /// - For age >= 24 months: uses BMI-for-age (bmifa) z-score if provided.
    /// - Returns nil if the required z-score is missing.
    static func assessNutritionStatus(
        ageMonths: Double,
        wflZ: Double?,
        bmiZ: Double?,
        bundle: Bundle = .main
    ) -> NutritionAssessment? {
        guard ageMonths.isFinite, ageMonths >= 0 else { return nil }

        if ageMonths < 24.0 {
            guard let z = wflZ, z.isFinite else { return nil }
            return NutritionAssessment(basisKind: .wfl, zScore: z, category: nutritionCategoryWHO(z))
        } else {
            guard let z = bmiZ, z.isFinite else { return nil }
            return NutritionAssessment(basisKind: .bmifa, zScore: z, category: nutritionCategoryWHO(z))
        }
    }

    /// WHO preschool-style categories using z-score cutoffs.
    /// Matches the requested scheme for 2–5y BMI and mirrors it for <2y WFL.
    private static func nutritionCategoryWHO(_ z: Double) -> NutritionCategory {
        if z < -3.0 { return .severeThinness }
        if z < -2.0 { return .thinness }
        if z >  3.0 { return .obesity }
        if z >  2.0 { return .overweight }
        if z >  1.0 { return .riskOfOverweight }
        return .healthy
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

    /// Evaluate weight-for-length (WFL) using WHO LMS tables where the independent variable is **length in cm**.
    ///
    /// The official WHO WFL LMS CSVs are keyed by length (cm), e.g. columns:
    /// `Length,L,M,S,...`.
    ///
    /// - Parameters:
    ///   - lengthCM: Recumbent length in cm (typically used < 24 months).
    ///   - weightKG: Measured weight in kg.
    /// - Returns: z-score + percentile for weight-for-length.
    static func evaluateWeightForLength(
        sex: Sex,
        lengthCM: Double,
        weightKG: Double,
        bundle: Bundle = .main
    ) throws -> (zScore: Double, percentile: Double) {
        guard lengthCM.isFinite, lengthCM > 0 else { throw GrowthError.invalidValue }
        guard weightKG.isFinite, weightKG > 0 else { throw GrowthError.invalidValue }

        // NOTE: For WFL, the LMS table x-axis is *length in cm*.
        // We reuse the same LMSTable interpolation machinery by querying with `target = lengthCM`.
        let table = try loadLMSTable(kind: .wfl, sex: sex, bundle: bundle)
        let lms = try table.lms(atAgeMonths: lengthCM)
        let z = zScore(value: weightKG, L: lms.L, M: lms.M, S: lms.S)
        let p = percentileFromZ(z)
        return (zScore: z, percentile: p)
    }

    // MARK: - WFL trend helpers

    /// Trend assessment for weight-for-length (WFL).
    ///
    /// WFL LMS tables are keyed by length (cm). We reuse the existing trend engine by mapping:
    /// - x-axis: lengthCM  (passed through the "ageMonths" slot)
    /// - y-axis: weightKG  (passed through the "value" slot)
    ///
    /// The resulting z-scores are still correct because `.wfl` LMS lookup is performed against the first CSV column
    /// (which is length for WFL tables).
    static func assessTrendWeightForLength(
        sex: Sex,
        prior: [(lengthCM: Double, weightKG: Double)],
        current: (lengthCM: Double, weightKG: Double),
        thresholdZ: Double = 2.0,
        bundle: Bundle = .main
    ) throws -> TrendAssessment {
        let mappedPrior: [(ageMonths: Double, value: Double)] = prior.map { (ageMonths: $0.lengthCM, value: $0.weightKG) }
        let mappedCurrent: (ageMonths: Double, value: Double) = (ageMonths: current.lengthCM, value: current.weightKG)
        return try assessTrend(kind: .wfl, sex: sex, prior: mappedPrior, current: mappedCurrent, thresholdZ: thresholdZ, bundle: bundle)
    }

    // LAME (legacy): "LastN" trend pipeline. Do not use for WellVisitForm/UI or DB.
    // Contract now is: use ALL priors via `assessTrendWeightForLength(...)`.
    @available(*, deprecated, message: "Legacy LastN pipeline. Use assessTrendWeightForLength(...) with ALL priors.")
    /// Convenience: assess WFL trend using only the last N prior points.
    static func assessTrendWeightForLengthLastN(
        sex: Sex,
        prior: [(lengthCM: Double, weightKG: Double)],
        current: (lengthCM: Double, weightKG: Double),
        lastN: Int = 5,
        thresholdZ: Double = 2.0,
        bundle: Bundle = .main
    ) throws -> TrendAssessment {
        let mappedPrior: [(ageMonths: Double, value: Double)] = prior.map { (ageMonths: $0.lengthCM, value: $0.weightKG) }
        let mappedCurrent: (ageMonths: Double, value: Double) = (ageMonths: current.lengthCM, value: current.weightKG)
        return try assessTrendLastN(kind: .wfl, sex: sex, prior: mappedPrior, current: mappedCurrent, lastN: lastN, thresholdZ: thresholdZ, bundle: bundle)
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
                thresholdZ: thresholdZ,
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
        var debugParts: [String] = []
        if debugLoggingEnabled {
            let ageText = String(format: "%.2f", currentRes.ageMonths)
            let valText = String(format: "%.2f", currentRes.value)
            let zText   = String(format: "%.3f", currentRes.zScore)

            let medText = String(format: "%.3f", med)
            let dText   = String(format: "%.3f", delta)
            let thTextD = String(format: "%.2f", thresholdZ)

            debugParts.append("WHO \(kind.rawValue) ageMo=\(ageText) value=\(valText) z=\(zText)")
            debugParts.append("priors=\(priorZ.count) medZ=\(medText) dZ=\(dText) th=\(thTextD)")
        }
        #endif

        // --- Extra: robust trajectory deviation check (Theil–Sen + MAD) ---
        // Runs for all measures when we have enough prior points.
        var trajectoryConcern = false
        var trajectoryMsg: String? = nil
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
                if debugLoggingEnabled {
                    let expText  = String(format: "%.3f", traj.expectedZ)
                    let resText  = String(format: "%.3f", traj.residual)
                    let sigText  = String(format: "%.3f", traj.sigma)
                    let scoreTxt = String(format: "%.2f", traj.score)
                    let thTxt    = String(format: "%.2f", traj.threshold)
                    debugParts.append("traj expZ=\(expText) res=\(resText) sigma=\(sigText) score=\(scoreTxt) th=\(thTxt)")
                }
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
        #if DEBUG
        if debugLoggingEnabled, !debugParts.isEmpty {
            print(debugParts.joined(separator: " | "))
        }
        #endif

        return TrendAssessment(
            current: currentRes,
            previousMedianZ: med,
            deltaZFromMedian: delta,
            thresholdZ: thresholdZ,
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
    // LAME (legacy): "LastN" trend pipeline. Do not use for WellVisitForm/UI or DB.
    // Contract now is: use ALL priors via `assessTrend(...)`.
    @available(*, deprecated, message: "Legacy LastN pipeline. Use assessTrend(...) with ALL priors.")
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

    /// Preferred LMS file stems (without extension) for each kind.
    /// Most measures are stored as <kind>_0_5y_<sex>_lms.
    /// Weight-for-length may be stored as 0–2y (or 0–5y) depending on the dataset bundle.
    private static func lmsFileStems(kind: Kind, sex: Sex) -> [String] {
        let sx = sex.rawValue
        switch kind {
        case .wfl:
            // Try the most specific first, then fall back.
            return [
                "wfl_0_2y_\(sx)_lms",
                "wfl_0_5y_\(sx)_lms",
                "wfh_0_5y_\(sx)_lms" // some bundles use weight-for-height naming
            ]
        default:
            return ["\(kind.rawValue)_0_5y_\(sx)_lms"]
        }
    }

    private static func loadLMSTable(kind: Kind, sex: Sex, bundle: Bundle) throws -> LMSTable {
        let stems = lmsFileStems(kind: kind, sex: sex)
        // Cache by the first (preferred) stem.
        let cacheKey = stems.first ?? "\(kind.rawValue)_0_5y_\(sex.rawValue)_lms"

        if let cached = cacheQueue.sync(execute: { cache[cacheKey] }) {
            return cached
        }

        let candidates: [(subdir: String?, label: String)] = [
            ("WHO", "WHO"),
            ("Resources/WHO", "Resources/WHO"),
            (nil, "(root)")
        ]

        var foundURL: URL? = nil
        var usedStem: String? = nil
        outer: for stem in stems {
            for c in candidates {
                if let u = bundle.url(forResource: stem, withExtension: "csv", subdirectory: c.subdir) {
                    foundURL = u
                    usedStem = stem
                    break outer
                }
            }
        }

        guard let url = foundURL else {
            // Build a helpful "tried" string.
            var triedParts: [String] = []
            for stem in stems {
                triedParts.append("WHO/\(stem).csv")
                triedParts.append("Resources/WHO/\(stem).csv")
                triedParts.append("\(stem).csv")
            }
            let tried = triedParts.joined(separator: ", ")
            throw GrowthError.resourceNotFound(LF("who_growth.detail.tried_paths", tried))
        }

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw GrowthError.malformedCSV(L("who_growth.detail.decode_failed"))
        }

        let table = try parseLMSTable(fromCSV: text)

        cacheQueue.sync {
            // Cache under preferred key and the actual used stem (if different).
            cache[cacheKey] = table
            if let u = usedStem, u != cacheKey {
                cache[u] = table
            }
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
            throw GrowthError.malformedCSV(L("who_growth.detail.empty_file"))
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
            throw GrowthError.malformedCSV(L("who_growth.detail.no_numeric_rows"))
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

    /// Public helper: convert a z-score to percentile (0..100).
    /// Exposes the same internal mapping used by this evaluator.
    static func percentileFromZScore(_ z: Double) -> Double {
        percentileFromZ(z)
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
        case .wfl:
            return 0.30
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

// MARK: - WHO Growth token helpers (single source of truth)
private enum WHOGrowthTokenFactory {

    // Localized metric label used in shift/traj tokens.
    static func metricLabel(for kind: WHOGrowthEvaluator.Kind, bundle: Bundle = .main) -> String {
        // Prefer the growth.metric.* vocabulary used by your token strings.
        let key: String
        switch kind {
        case .wfa:   key = "growth.metric.wfa"
        case .lhfa:  key = "growth.metric.lhfa"
        case .hcfa:  key = "growth.metric.hcfa"
        case .wfl:   key = "growth.metric.wfl"
        case .bmifa: key = "growth.metric.bmifa"
        }
        let v = NSLocalizedString(key, bundle: bundle, comment: "")
        // If key is missing, NSLocalizedString returns the key itself.
        if v == key {
            return kind.displayName(bundle: bundle)
        }
        return v
    }

    // Compute baseline from ALL priors (contract: no lastN slicing).
    // Baseline is the median prior z, with percentile derived from that median z.
    static func computeShift(
        kind: WHOGrowthEvaluator.Kind,
        sex: WHOGrowthEvaluator.Sex,
        prior: [(x: Double, value: Double)],
        current: (x: Double, value: Double),
        xIsLengthForWFL: Bool,
        bundle: Bundle = .main
    ) -> (metricLabel: String, deltaZ: Double, deltaP: Double, currentP: Double, priorsCount: Int)? {

        // Need at least 1 prior to compute a shift.
        guard !prior.isEmpty else { return nil }

        // Evaluate current.
        let currentZ: Double
        let currentP: Double
        do {
            if xIsLengthForWFL {
                let r = try WHOGrowthEvaluator.evaluateWeightForLength(sex: sex, lengthCM: current.x, weightKG: current.value, bundle: bundle)
                currentZ = r.zScore
                currentP = r.percentile
            } else {
                let r = try WHOGrowthEvaluator.evaluate(kind: kind, sex: sex, ageMonths: current.x, value: current.value, bundle: bundle)
                currentZ = r.zScore
                currentP = r.percentile
            }
        } catch {
            return nil
        }

        // Evaluate priors z-scores (ALL priors).
        var priorZ: [Double] = []
        priorZ.reserveCapacity(prior.count)
        for p in prior {
            do {
                if xIsLengthForWFL {
                    let r = try WHOGrowthEvaluator.evaluateWeightForLength(sex: sex, lengthCM: p.x, weightKG: p.value, bundle: bundle)
                    priorZ.append(r.zScore)
                } else {
                    let r = try WHOGrowthEvaluator.evaluate(kind: kind, sex: sex, ageMonths: p.x, value: p.value, bundle: bundle)
                    priorZ.append(r.zScore)
                }
            } catch {
                // skip bad points
                continue
            }
        }
        guard !priorZ.isEmpty else { return nil }

        let baselineZ = median(priorZ)
        let baselineP = WHOGrowthEvaluator.percentileFromZScore(baselineZ)

        let deltaZ = currentZ - baselineZ
        let deltaP = currentP - baselineP

        return (
            metricLabel: metricLabel(for: kind, bundle: bundle),
            deltaZ: deltaZ,
            deltaP: deltaP,
            currentP: currentP,
            priorsCount: priorZ.count
        )
    }

    // Create shift + traj tokens from the evaluator’s single assessment.
    // Contract:
    // - Uses ALL priors (no lastN).
    // - Emits ONLY v2 shift token key.
    // - Emits traj v1 token when trajectory direction is meaningful.
    static func makeTokens(
        kind: WHOGrowthEvaluator.Kind,
        sex: WHOGrowthEvaluator.Sex,
        prior: [(x: Double, value: Double)],
        current: (x: Double, value: Double),
        thresholdZ: Double,
        xIsLengthForWFL: Bool,
        bundle: Bundle = .main
    ) -> [ProblemToken] {

        var out: [ProblemToken] = []
        let metric = metricLabel(for: kind, bundle: bundle)

        // SHIFT (median-based) — v2 only.
        if let shift = computeShift(kind: kind, sex: sex, prior: prior, current: current, xIsLengthForWFL: xIsLengthForWFL, bundle: bundle) {
            let dz = String(format: "%+.2f", shift.deltaZ)
            let dP = String(format: "%+.1f", shift.deltaP)
            let p  = String(format: "%.1f", shift.currentP)
            let n  = "\(shift.priorsCount)"
            out.append(ProblemToken("growth.who.shift.v2", [metric, dz, dP, p, n]))
        }

        // TREND / TRAJ (one canonical evaluator).
        do {
            let assessment: WHOGrowthEvaluator.TrendAssessment
            if xIsLengthForWFL {
                // WFL trend uses the WFL helper (x is lengthCM, value is weightKG).
                let mappedPrior = prior.map { (lengthCM: $0.x, weightKG: $0.value) }
                let mappedCur = (lengthCM: current.x, weightKG: current.value)
                assessment = try WHOGrowthEvaluator.assessTrendWeightForLength(
                    sex: sex,
                    prior: mappedPrior,
                    current: mappedCur,
                    thresholdZ: thresholdZ,
                    bundle: bundle
                )
            } else {
                let mappedPrior = prior.map { (ageMonths: $0.x, value: $0.value) }
                let mappedCur = (ageMonths: current.x, value: current.value)
                assessment = try WHOGrowthEvaluator.assessTrend(
                    kind: kind,
                    sex: sex,
                    prior: mappedPrior,
                    current: mappedCur,
                    thresholdZ: thresholdZ,
                    bundle: bundle
                )
            }

            // Trajectory direction based on deltaZ-from-median if available.
            if let d = assessment.deltaZFromMedian, d.isFinite {
                let dirKey: String
                if abs(d) < 0.05 {
                    dirKey = "growth.who.traj.dir.flat"
                } else if d > 0 {
                    dirKey = "growth.who.traj.dir.up"
                } else {
                    dirKey = "growth.who.traj.dir.down"
                }

                let dir = NSLocalizedString(dirKey, bundle: bundle, comment: "")
                let dzAbs = String(format: "%.2f", abs(d))
                let th = String(format: "%.2f", thresholdZ)
                out.append(ProblemToken("growth.who.traj.v1", [metric, dir, dzAbs, th]))
            }
        } catch {
            // best-effort; no traj token
        }

        return out
    }

    // Local median helper (avoid relying on WHOGrowthEvaluator’s private median).
    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let n = s.count
        if n % 2 == 1 { return s[n/2] }
        return 0.5 * (s[n/2 - 1] + s[n/2])
    }
}
