
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
        let points: [GrowthPoint]

        /// The selected "near visit" point.
        let current: GrowthPoint

        init(dob: Date,
             sex: WHOGrowthEvaluator.Sex,
             visitDate: Date,
             points: [GrowthPoint],
             current: GrowthPoint) {
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
        // TODO (next step): Implement by delegating to WHOGrowthEvaluator “golden pipeline”
        // so UI + DB always share the exact same decisions.
        // For now we return empty to keep the build stable while we wire call sites.
        return .empty
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

        // Prefer the readable “<cutoff” style when extremely small.
        if p > 0, p < policy.percentileLtCutoff {
            // e.g. "<0.1"
            let c = fmt(policy.percentileLtCutoff, decimals: policy.tinyPercentileDecimals)
            return "<" + c
        }

        // Otherwise show integer percentile.
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

