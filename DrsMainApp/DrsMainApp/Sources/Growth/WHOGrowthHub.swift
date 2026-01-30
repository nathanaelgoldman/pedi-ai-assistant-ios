
//
//  WHOGrowthHub.swift
//  DrsMainApp
//
//  Single source of truth for WHO growth computation + interpretation.
//  - UI consumes the Result to display summaries (no extra interpretation in UI)
//  - DB pipeline persists the tokens from Result (no recomputation downstream)
//  - Reports render persisted tokens (no recomputation in reports)
//
//  Created by Nathanael on 1/30/26.
//

import Foundation

/// Minimal interface required by WHOGrowthHub for WHO growth computations.
protocol WHOGrowthPointLike {
    var recordedDate: Date { get }
    var weightKg: Double? { get }
    var heightCm: Double? { get }
    var headCircCm: Double? { get }
}

/// A computation hub that wraps `WHOGrowthEvaluator` and emits:
/// - UI-ready summary lines
/// - localization-proof tokens for persistence and reporting
///
/// IMPORTANT CONTRACT
/// - This file is the only place that decides thresholds, rounding, percentile display rules, and
///   which situations emit `problemTokens`.
/// - Callers (UI, DB writer, report builder) must not re-interpret the numbers.
struct WHOGrowthHub {

    // MARK: - Public API

    /// Inputs are *facts* (already fetched): no DB access and no UI state.
    struct Input {
        let dob: Date
        let sex: WHOGrowthEvaluator.Sex
        let visitDate: Date

        /// Full series window that the UI uses (already filtered/ordered upstream).
        /// The hub will re-sort defensively.
        let points: [any WHOGrowthPointLike]
        let current: any WHOGrowthPointLike

        init(dob: Date,
             sex: WHOGrowthEvaluator.Sex,
             visitDate: Date,
             points: [any WHOGrowthPointLike],
             current: any WHOGrowthPointLike) {
            self.dob = dob
            self.sex = sex
            self.visitDate = visitDate
            self.points = points
            self.current = current
        }
    }

    /// Output is consumed by the UI and persisted to DB.
    struct Result {
        // UI-facing (already localized by the caller as-needed; these are *final* strings)
        var zSummaryLines: [String] = []
        var trendLines: [String] = []
        var nutritionLine: String = ""
        var trendIsFlagged: Bool = false
        var overallFlags: [String] = []

        // Persistence/reporting
        var problemTokens: [ProblemToken] = []
        var measurementTokens: [ProblemToken] = []

        // For debugging/QA
        var debugNotes: [String] = []

        static var empty: Result { Result() }
    }

    /// Central evaluation call (the *only* place that computes and interprets WHO growth).
    ///
    /// NOTE: This is intentionally synchronous and pure (depends only on Input).
    static func evaluate(_ input: Input,
                         policy: Policy = .default) -> Result {
        // Defensive ordering: callers might pass unsorted.
        // NOTE: `GrowthPoint` differs between targets/modules (naming drift). To keep this hub
        // as the single source of truth without coupling to a specific GrowthPoint shape,
        // we extract required fields via reflection and work with a local normalized type.

        struct HubPoint {
            let date: Date
            let weightKg: Double?
            let heightCm: Double?
            let headCircCm: Double?
        }

        func normalize(_ gp: any WHOGrowthPointLike) -> HubPoint {
            HubPoint(
                date: gp.recordedDate,
                weightKg: gp.weightKg,
                heightCm: gp.heightCm,
                headCircCm: gp.headCircCm
            )
        }

        var result = Result.empty

        let points: [HubPoint] = input.points
            .map { normalize($0) }
            .sorted(by: { $0.date < $1.date })

        let current = normalize(input.current)

        // Helpers
        func addOverallFlag(_ label: String) {
            if !result.overallFlags.contains(label) {
                result.overallFlags.append(label)
            }
        }

        func pushZP(metricId: String, z: Double, percentile: Double) {
            // Persist the percentile string with the hub's display policy.
            let pStr = fmtPercentile(percentile, policy: policy)
            result.measurementTokens.append(ProblemToken("growth.who.zp", [metricId, fmt(z, decimals: policy.zDecimals), pStr]))
        }

        func pushExtreme(metricId: String, z: Double, percentile: Double) {
            // Extreme token keeps numeric percentile (rounded integer) for stable reporting.
            result.problemTokens.append(
                ProblemToken(
                    "growth.who.extreme",
                    [metricId, fmt(z, decimals: policy.zDecimals), String(format: "%.0f", percentile)]
                )
            )
        }

        func pushShift(metricId: String, deltaZ: Double, deltaP: Double, currentP: Double, priorCount: Int) {
            // Args v2: [metricId, deltaZ_signed, deltaPercentile_signed, currentPercentile, priorsCount]
            // Percentile uses hub display policy (may produce "<0.1").
            let args = [
                metricId,
                fmtSigned(deltaZ, decimals: policy.zDecimals),
                fmtSigned(deltaP, decimals: 0),
                fmtPercentile(currentP, policy: policy),
                String(priorCount)
            ]
            result.problemTokens.append(ProblemToken("growth.who.shift.v2", args))
        }

        func pushTrajectory(metricId: String, residualZ: Double) {
            // Args v1 (4): [metricId, directionKey, residualZ_signed, threshold]
            let dirKey: String = {
                if residualZ > 0.10 { return "growth.who.traj.dir.up" }
                if residualZ < -0.10 { return "growth.who.traj.dir.down" }
                return "growth.who.traj.dir.flat"
            }()
            let args = [
                metricId,
                dirKey,
                fmtSigned(residualZ, decimals: policy.zDecimals),
                fmt(policy.trajectoryScoreThreshold, decimals: policy.zDecimals)
            ]
            result.problemTokens.append(ProblemToken("growth.who.traj.v1", args))
        }

        func computeTrajectoryAnomaly(
            prior: [(x: Double, z: Double)],
            currentX: Double,
            currentZ: Double
        ) -> (residualZ: Double, sigma: Double, score: Double)? {
            // Need enough history to fit a line robustly.
            guard prior.count >= 4 else { return nil }

            let n = Double(prior.count)
            let meanX = prior.reduce(0.0) { $0 + $1.x } / n
            let meanZ = prior.reduce(0.0) { $0 + $1.z } / n

            var varX = 0.0
            var covXZ = 0.0
            for p in prior {
                let dx = p.x - meanX
                let dz = p.z - meanZ
                varX += dx * dx
                covXZ += dx * dz
            }
            if varX < 1e-9 { return nil }

            let slope = covXZ / varX
            let intercept = meanZ - slope * meanX
            let expectedZ = intercept + slope * currentX
            let residualZ = currentZ - expectedZ

            // Residual SD
            var rss = 0.0
            for p in prior {
                let pred = intercept + slope * p.x
                let r = p.z - pred
                rss += r * r
            }
            let df = max(1.0, n - 2.0)
            var sigma = sqrt(rss / df)
            if sigma < 0.05 { sigma = 0.05 }

            let score = abs(residualZ) / sigma
            return (residualZ: residualZ, sigma: sigma, score: score)
        }

        func bmiKgM2(weightKg: Double, heightCm: Double) -> Double? {
            guard weightKg.isFinite, heightCm.isFinite, heightCm > 0 else { return nil }
            let m = heightCm / 100.0
            guard m > 0 else { return nil }
            return weightKg / (m * m)
        }

        // Core facts
        let dob = input.dob
        let sex = input.sex
        let currentAgeM = ageMonths(dob: dob, at: current.date)

        // We keep the same "extreme" logic used in the UI helper.
        func isExtreme(z: Double, p: Double) -> Bool {
            return abs(z) >= 2.0 || p <= 3.0 || p >= 97.0
        }

        // Build a prior series for assessTrend(kind:)
        func buildPrior(_ extract: (HubPoint) -> Double?) -> [(ageMonths: Double, value: Double)] {
            let priors = points
                .filter { $0.date < current.date }
                .compactMap { p -> (Double, Double)? in
                    guard let v = extract(p) else { return nil }
                    return (ageMonths(dob: dob, at: p.date), v)
                }
                .sorted(by: { $0.0 < $1.0 })
            return priors.map { (ageMonths: $0.0, value: $0.1) }
        }

        // For nutrition summary
        var wflZForNutrition: Double? = nil
        var bmiZForNutrition: Double? = nil

        do {
            // MARK: - WFA
            if let w = current.weightKg {
                let label = WHOGrowthEvaluator.Kind.wfa.displayName()
                let r = try WHOGrowthEvaluator.evaluate(kind: .wfa, sex: sex, ageMonths: currentAgeM, value: w)

                result.zSummaryLines.append("**\(label):** z=\(fmt(r.zScore, decimals: policy.zDecimals)) P\(fmtPercentile(r.percentile, policy: policy))")
                pushZP(metricId: "wfa", z: r.zScore, percentile: r.percentile)

                // Median-based shift (local, deterministic)
                let priorZs: [Double] = points
                    .filter { $0.date < current.date }
                    .compactMap { p -> Double? in
                        guard let pw = p.weightKg else { return nil }
                        let am = ageMonths(dob: dob, at: p.date)
                        return (try? WHOGrowthEvaluator.evaluate(kind: .wfa, sex: sex, ageMonths: am, value: pw).zScore)
                    }

                if priorZs.count >= 3, let medZ = median(priorZs) {
                    let dZ = r.zScore - medZ
                    if abs(dZ) >= policy.shiftThresholdZ {
                        let medP = WHOGrowthEvaluator.percentileFromZScore(medZ)
                        let dP = r.percentile - medP
                        pushShift(metricId: "wfa", deltaZ: dZ, deltaP: dP, currentP: r.percentile, priorCount: priorZs.count)
                    }
                }

                if isExtreme(z: r.zScore, p: r.percentile) {
                    result.trendIsFlagged = true
                    addOverallFlag(label)
                    pushExtreme(metricId: "wfa", z: r.zScore, percentile: r.percentile)
                }

                let prior = buildPrior { $0.weightKg }
                let t = try WHOGrowthEvaluator.assessTrend(
                    kind: .wfa, sex: sex, prior: prior,
                    current: (ageMonths: currentAgeM, value: w),
                    thresholdZ: policy.shiftThresholdZ
                )

                if t.priorCount > 0 {
                    result.trendLines.append("**\(label):** " + t.narrative)
                    if t.isSignificantShift {
                        result.trendIsFlagged = true
                        addOverallFlag(label)
                    }

                    let priorTraj: [(x: Double, z: Double)] = points
                        .filter { $0.date < current.date }
                        .compactMap { p -> (Double, Double)? in
                            guard let pw = p.weightKg else { return nil }
                            let am = ageMonths(dob: dob, at: p.date)
                            guard let z = try? WHOGrowthEvaluator.evaluate(kind: .wfa, sex: sex, ageMonths: am, value: pw).zScore else { return nil }
                            return (am, z)
                        }
                        .sorted(by: { $0.0 < $1.0 })

                    if let traj = computeTrajectoryAnomaly(prior: priorTraj, currentX: currentAgeM, currentZ: r.zScore),
                       traj.score >= policy.trajectoryScoreThreshold {
                        result.trendIsFlagged = true
                        addOverallFlag(label)
                        pushTrajectory(metricId: "wfa", residualZ: traj.residualZ)
                    }
                }
            }

            // MARK: - LHFA
            if let h = current.heightCm {
                let label = WHOGrowthEvaluator.Kind.lhfa.displayName()
                let r = try WHOGrowthEvaluator.evaluate(kind: .lhfa, sex: sex, ageMonths: currentAgeM, value: h)

                result.zSummaryLines.append("**\(label):** z=\(fmt(r.zScore, decimals: policy.zDecimals)) P\(fmtPercentile(r.percentile, policy: policy))")
                pushZP(metricId: "lhfa", z: r.zScore, percentile: r.percentile)

                let priorZs: [Double] = points
                    .filter { $0.date < current.date }
                    .compactMap { p -> Double? in
                        guard let ph = p.heightCm else { return nil }
                        let am = ageMonths(dob: dob, at: p.date)
                        return (try? WHOGrowthEvaluator.evaluate(kind: .lhfa, sex: sex, ageMonths: am, value: ph).zScore)
                    }

                if priorZs.count >= 3, let medZ = median(priorZs) {
                    let dZ = r.zScore - medZ
                    if abs(dZ) >= policy.shiftThresholdZ {
                        let medP = WHOGrowthEvaluator.percentileFromZScore(medZ)
                        let dP = r.percentile - medP
                        pushShift(metricId: "lhfa", deltaZ: dZ, deltaP: dP, currentP: r.percentile, priorCount: priorZs.count)
                    }
                }

                if isExtreme(z: r.zScore, p: r.percentile) {
                    result.trendIsFlagged = true
                    addOverallFlag(label)
                    pushExtreme(metricId: "lhfa", z: r.zScore, percentile: r.percentile)
                }

                let prior = buildPrior { $0.heightCm }
                let t = try WHOGrowthEvaluator.assessTrend(
                    kind: .lhfa, sex: sex, prior: prior,
                    current: (ageMonths: currentAgeM, value: h),
                    thresholdZ: policy.shiftThresholdZ
                )

                if t.priorCount > 0 {
                    result.trendLines.append("**\(label):** " + t.narrative)
                    if t.isSignificantShift {
                        result.trendIsFlagged = true
                        addOverallFlag(label)
                    }

                    let priorTraj: [(x: Double, z: Double)] = points
                        .filter { $0.date < current.date }
                        .compactMap { p -> (Double, Double)? in
                            guard let ph = p.heightCm else { return nil }
                            let am = ageMonths(dob: dob, at: p.date)
                            guard let z = try? WHOGrowthEvaluator.evaluate(kind: .lhfa, sex: sex, ageMonths: am, value: ph).zScore else { return nil }
                            return (am, z)
                        }
                        .sorted(by: { $0.0 < $1.0 })

                    if let traj = computeTrajectoryAnomaly(prior: priorTraj, currentX: currentAgeM, currentZ: r.zScore),
                       traj.score >= policy.trajectoryScoreThreshold {
                        result.trendIsFlagged = true
                        addOverallFlag(label)
                        pushTrajectory(metricId: "lhfa", residualZ: traj.residualZ)
                    }
                }
            }

            // MARK: - HCFA
            if let hc = current.headCircCm {
                let label = WHOGrowthEvaluator.Kind.hcfa.displayName()
                let r = try WHOGrowthEvaluator.evaluate(kind: .hcfa, sex: sex, ageMonths: currentAgeM, value: hc)

                result.zSummaryLines.append("**\(label):** z=\(fmt(r.zScore, decimals: policy.zDecimals)) P\(fmtPercentile(r.percentile, policy: policy))")
                pushZP(metricId: "hcfa", z: r.zScore, percentile: r.percentile)

                let priorZs: [Double] = points
                    .filter { $0.date < current.date }
                    .compactMap { p -> Double? in
                        guard let phc = p.headCircCm else { return nil }
                        let am = ageMonths(dob: dob, at: p.date)
                        return (try? WHOGrowthEvaluator.evaluate(kind: .hcfa, sex: sex, ageMonths: am, value: phc).zScore)
                    }

                if priorZs.count >= 3, let medZ = median(priorZs) {
                    let dZ = r.zScore - medZ
                    if abs(dZ) >= policy.shiftThresholdZ {
                        let medP = WHOGrowthEvaluator.percentileFromZScore(medZ)
                        let dP = r.percentile - medP
                        pushShift(metricId: "hcfa", deltaZ: dZ, deltaP: dP, currentP: r.percentile, priorCount: priorZs.count)
                    }
                }

                if isExtreme(z: r.zScore, p: r.percentile) {
                    result.trendIsFlagged = true
                    addOverallFlag(label)
                    pushExtreme(metricId: "hcfa", z: r.zScore, percentile: r.percentile)
                }

                let prior = buildPrior { $0.headCircCm }
                let t = try WHOGrowthEvaluator.assessTrend(
                    kind: .hcfa, sex: sex, prior: prior,
                    current: (ageMonths: currentAgeM, value: hc),
                    thresholdZ: policy.shiftThresholdZ
                )

                if t.priorCount > 0 {
                    result.trendLines.append("**\(label):** " + t.narrative)
                    if t.isSignificantShift {
                        result.trendIsFlagged = true
                        addOverallFlag(label)
                    }

                    let priorTraj: [(x: Double, z: Double)] = points
                        .filter { $0.date < current.date }
                        .compactMap { p -> (Double, Double)? in
                            guard let phc = p.headCircCm else { return nil }
                            let am = ageMonths(dob: dob, at: p.date)
                            guard let z = try? WHOGrowthEvaluator.evaluate(kind: .hcfa, sex: sex, ageMonths: am, value: phc).zScore else { return nil }
                            return (am, z)
                        }
                        .sorted(by: { $0.0 < $1.0 })

                    if let traj = computeTrajectoryAnomaly(prior: priorTraj, currentX: currentAgeM, currentZ: r.zScore),
                       traj.score >= policy.trajectoryScoreThreshold {
                        result.trendIsFlagged = true
                        addOverallFlag(label)
                        pushTrajectory(metricId: "hcfa", residualZ: traj.residualZ)
                    }
                }
            }

            // MARK: - WFL (<24m) OR BMIFA (>=24m)
            if let w = current.weightKg, let h = current.heightCm {
                if currentAgeM < 24.0 {
                    let label = WHOGrowthEvaluator.Kind.wfl.displayName()
                    let wfl = try WHOGrowthEvaluator.evaluateWeightForLength(sex: sex, lengthCM: h, weightKG: w)

                    result.zSummaryLines.append("**\(label):** z=\(fmt(wfl.zScore, decimals: policy.zDecimals)) P\(fmtPercentile(wfl.percentile, policy: policy))")
                    wflZForNutrition = wfl.zScore
                    pushZP(metricId: "wfl", z: wfl.zScore, percentile: wfl.percentile)

                    let priorZs: [Double] = points
                        .filter { $0.date < current.date }
                        .compactMap { p -> Double? in
                            guard let pw = p.weightKg, let ph = p.heightCm else { return nil }
                            return (try? WHOGrowthEvaluator.evaluateWeightForLength(sex: sex, lengthCM: ph, weightKG: pw).zScore)
                        }

                    if priorZs.count >= 3, let medZ = median(priorZs) {
                        let dZ = wfl.zScore - medZ
                        if abs(dZ) >= policy.shiftThresholdZ {
                            let medP = WHOGrowthEvaluator.percentileFromZScore(medZ)
                            let dP = wfl.percentile - medP
                            pushShift(metricId: "wfl", deltaZ: dZ, deltaP: dP, currentP: wfl.percentile, priorCount: priorZs.count)
                        }
                    }

                    if isExtreme(z: wfl.zScore, p: wfl.percentile) {
                        result.trendIsFlagged = true
                        addOverallFlag(label)
                        pushExtreme(metricId: "wfl", z: wfl.zScore, percentile: wfl.percentile)
                    }

                    let priorWFL: [(lengthCM: Double, weightKG: Double)] = points
                        .filter { $0.date < current.date }
                        .compactMap { p -> (Double, Double)? in
                            guard let pw = p.weightKg, let ph = p.heightCm else { return nil }
                            return (ph, pw)
                        }
                        .sorted(by: { $0.0 < $1.0 })

                    let t = try WHOGrowthEvaluator.assessTrendWeightForLength(
                        sex: sex,
                        prior: priorWFL,
                        current: (lengthCM: h, weightKG: w),
                        thresholdZ: policy.shiftThresholdZ
                    )

                    if t.priorCount > 0 {
                        result.trendLines.append("**\(label):** " + t.narrative)
                        if t.isSignificantShift {
                            result.trendIsFlagged = true
                            addOverallFlag(label)
                        }

                        let priorTraj: [(x: Double, z: Double)] = points
                            .filter { $0.date < current.date }
                            .compactMap { p -> (Double, Double)? in
                                guard let pw = p.weightKg, let ph = p.heightCm else { return nil }
                                guard let z = try? WHOGrowthEvaluator.evaluateWeightForLength(sex: sex, lengthCM: ph, weightKG: pw).zScore else { return nil }
                                return (ph, z) // x = length(cm)
                            }
                            .sorted(by: { $0.0 < $1.0 })

                        if let traj = computeTrajectoryAnomaly(prior: priorTraj, currentX: h, currentZ: wfl.zScore),
                           traj.score >= policy.trajectoryScoreThreshold {
                            result.trendIsFlagged = true
                            addOverallFlag(label)
                            pushTrajectory(metricId: "wfl", residualZ: traj.residualZ)
                        }
                    }

                } else {
                    if let bmi = bmiKgM2(weightKg: w, heightCm: h) {
                        let label = WHOGrowthEvaluator.Kind.bmifa.displayName()
                        let r = try WHOGrowthEvaluator.evaluate(kind: .bmifa, sex: sex, ageMonths: currentAgeM, value: bmi)

                        result.zSummaryLines.append("**\(label):** z=\(fmt(r.zScore, decimals: policy.zDecimals)) P\(fmtPercentile(r.percentile, policy: policy))")
                        bmiZForNutrition = r.zScore
                        pushZP(metricId: "bmifa", z: r.zScore, percentile: r.percentile)

                        let priorZs: [Double] = points
                            .filter { $0.date < current.date }
                            .compactMap { p -> Double? in
                                guard let pw = p.weightKg, let ph = p.heightCm,
                                      let pbmi = bmiKgM2(weightKg: pw, heightCm: ph) else { return nil }
                                let am = ageMonths(dob: dob, at: p.date)
                                return (try? WHOGrowthEvaluator.evaluate(kind: .bmifa, sex: sex, ageMonths: am, value: pbmi).zScore)
                            }

                        if priorZs.count >= 3, let medZ = median(priorZs) {
                            let dZ = r.zScore - medZ
                            if abs(dZ) >= policy.shiftThresholdZ {
                                let medP = WHOGrowthEvaluator.percentileFromZScore(medZ)
                                let dP = r.percentile - medP
                                pushShift(metricId: "bmifa", deltaZ: dZ, deltaP: dP, currentP: r.percentile, priorCount: priorZs.count)
                            }
                        }

                        if isExtreme(z: r.zScore, p: r.percentile) {
                            result.trendIsFlagged = true
                            addOverallFlag(label)
                            pushExtreme(metricId: "bmifa", z: r.zScore, percentile: r.percentile)
                        }

                        let prior = points
                            .filter { $0.date < current.date }
                            .compactMap { p -> (ageMonths: Double, value: Double)? in
                                guard let pw = p.weightKg, let ph = p.heightCm,
                                      let pbmi = bmiKgM2(weightKg: pw, heightCm: ph) else { return nil }
                                return (ageMonths(dob: dob, at: p.date), pbmi)
                            }
                            .sorted(by: { $0.ageMonths < $1.ageMonths })

                        let t = try WHOGrowthEvaluator.assessTrend(
                            kind: .bmifa, sex: sex, prior: prior,
                            current: (ageMonths: currentAgeM, value: bmi),
                            thresholdZ: policy.shiftThresholdZ
                        )

                        if t.priorCount > 0 {
                            result.trendLines.append("**\(label):** " + t.narrative)
                            if t.isSignificantShift {
                                result.trendIsFlagged = true
                                addOverallFlag(label)
                            }

                            let priorTraj: [(x: Double, z: Double)] = points
                                .filter { $0.date < current.date }
                                .compactMap { p -> (Double, Double)? in
                                    guard let pw = p.weightKg, let ph = p.heightCm,
                                          let pbmi = bmiKgM2(weightKg: pw, heightCm: ph) else { return nil }
                                    let am = ageMonths(dob: dob, at: p.date)
                                    guard let z = try? WHOGrowthEvaluator.evaluate(kind: .bmifa, sex: sex, ageMonths: am, value: pbmi).zScore else { return nil }
                                    return (am, z)
                                }
                                .sorted(by: { $0.0 < $1.0 })

                            if let traj = computeTrajectoryAnomaly(prior: priorTraj, currentX: currentAgeM, currentZ: r.zScore),
                               traj.score >= policy.trajectoryScoreThreshold {
                                result.trendIsFlagged = true
                                addOverallFlag(label)
                                pushTrajectory(metricId: "bmifa", residualZ: traj.residualZ)
                            }
                        }
                    }
                }
            }

            // MARK: - Nutrition status summary
            if let nut = WHOGrowthEvaluator.assessNutritionStatus(
                ageMonths: currentAgeM,
                wflZ: wflZForNutrition,
                bmiZ: bmiZForNutrition
            ) {
                result.nutritionLine = nut.summaryLine()
            }

        } catch {
            result.debugNotes.append("WHO evaluation failed: \(error.localizedDescription)")
            // Keep the result otherwise empty/partial.
        }

        return result
    }

    // MARK: - Policy

    /// Formatting + threshold policy (kept here to prevent drift between UI/DB/report).
    struct Policy {
        /// Absolute z-shift threshold that triggers a “shift” problem token.
        let shiftThresholdZ: Double

        /// Trajectory anomaly score threshold that triggers a trajectory problem token.
        let trajectoryScoreThreshold: Double

        /// Percentile display rule: if percentile is >0 and < this cutoff, display as "<cutoff".
        /// Example: cutoff=0.1 => 0.05 becomes "<0.1".
        let percentileLtCutoff: Double

        /// Decimal places for z-scores in display.
        let zDecimals: Int

        /// Decimal places for tiny percentiles when not using the “<cutoff” style.
        let tinyPercentileDecimals: Int

        static let `default` = Policy(
            shiftThresholdZ: 1.0,
            trajectoryScoreThreshold: 2.5,
            percentileLtCutoff: 0.1,
            zDecimals: 2,
            tinyPercentileDecimals: 1
        )
    }

    // MARK: - Shared helpers (used by hub + token rendering)

    static func ageMonths(dob: Date, at date: Date) -> Double {
        // Keep consistent with the rest of the app. We assume `ageMonths(dob:at:)` exists,
        // but we avoid depending on UI helpers. If you already have a canonical helper in Growth,
        // we can swap to that in the next step.
        let seconds = date.timeIntervalSince(dob)
        return seconds / (60.0 * 60.0 * 24.0 * 30.4375) // average month length
    }

    static func ensureSigned(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return t }
        if t.hasPrefix("-") || t.hasPrefix("−") { return t }
        if t.hasPrefix("+") { return t }
        return "+" + t
    }

    static func fmt(_ v: Double, decimals: Int) -> String {
        guard v.isFinite else { return "—" }
        return String(format: "%0.*f", decimals, v)
    }

    static func fmtSigned(_ v: Double, decimals: Int) -> String {
        guard v.isFinite else { return "—" }
        let s = String(format: "%+0.*f", decimals, v)
        return s
    }

    static func fmtPercentile(_ p: Double, policy: Policy) -> String {
        guard p.isFinite else { return "—" }
        if p <= 0 { return "0" }

        // Prefer readable "<cutoff" when extremely small.
        if p > 0, p < policy.percentileLtCutoff {
            let c = fmt(policy.percentileLtCutoff, decimals: policy.tinyPercentileDecimals)
            return "<" + c
        }

        return String(format: "%.0f", p)
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let n = s.count
        if n % 2 == 1 { return s[n/2] }
        return 0.5 * (s[n/2 - 1] + s[n/2])
    }
}

