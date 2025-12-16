//
//  WellVisitReportRules.swift
//  DrsMainApp
//
//  Created by yunastic on 11/28/25.
//// REPORT CONTRACT (Well visits)
// - Age gating lives in WellVisitReportRules + ReportDataLoader ONLY.
// - Age gating controls ONLY which fields appear INSIDE the current visit sections.
// - Growth charts, perinatal summary, and previous well visits are NEVER age-gated.
// - ReportBuilder is a dumb renderer: it prints whatever WellReportData gives it.
//- We don't make RTF (that is legacy from previous failed attempts)
//- we don't touch GrowthCharts
//- we work with PDF and Docx.
//- the contract is to filter the age appropriate current visit field to include in the report. Everything else is left unchanged.
//



import Foundation

// MARK: - Localization helpers (file-local)
fileprivate func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

fileprivate func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

/// Fine‑grained age‑based rules that decide which well‑visit fields
/// should actually be pulled into the report for a given visit type.
///
/// This mirrors the CSV matrix we generated (rows = visit types,
/// columns = booleans such as `isWeightDeltaVisit`, `isMCHATVisit`, etc.).
struct WellVisitReportFlags {
    let visitTypeID: String

    // Feeding & nutrition
    let isWeightDeltaVisit: Bool
    let isEarlyMilkOnlyVisit: Bool
    let isStructuredFeedingUnder12: Bool
    let isSolidsVisit: Bool
    let isOlderFeedingVisit: Bool

    // Sleep
    let isEarlySleepVisit: Bool
    let isOlderSleepVisit: Bool
    let isPostTwelveMonthVisit: Bool

    // Physical exam details
    let isFontanelleVisit: Bool
    let isPrimitiveNeuroVisit: Bool
    let isMoroVisit: Bool
    let isHipsVisit: Bool
    let isTeethVisit: Bool

    // Developmental tools
    let isMCHATVisit: Bool
    let isDevTestScoreVisit: Bool
    let isDevTestResultVisit: Bool
}

/// Raw age‑matrix row loaded from `well_visit_age_mapping.csv`.
/// This is intentionally kept very close to the CSV columns so that
/// the CSV becomes the single source of truth.
private struct AgeMatrixRow {
    let visitTypeID: String

    // Feeding & nutrition
    let isWeightDeltaVisit: Bool
    let isEarlyMilkOnlyVisit: Bool
    let isStructuredFeedingUnder12: Bool
    let isSolidsVisit: Bool
    let isOlderFeedingVisit: Bool

    // Sleep
    let isEarlySleepVisit: Bool
    let isOlderSleepVisit: Bool
    let isPostTwelveMonthVisit: Bool

    // Physical exam details
    let isFontanelleVisit: Bool
    let isPrimitiveNeuroVisit: Bool
    let isMoroVisit: Bool
    let isHipsVisit: Bool
    let isTeethVisit: Bool

    // Developmental tools
    let isMCHATVisit: Bool
    let isDevTestScoreVisit: Bool
    let isDevTestResultVisit: Bool
}

/// Central entry point for age‑based report rules.
///
/// Typical usage from the report side:
///
///     let profile = WellVisitReportRules.reportProfile(for: visitTypeID)
///     let flags = profile.flags
///     if flags.isWeightDeltaVisit { ... pull & render weight delta ... }
///
enum WellVisitReportRules {

    // MARK: - CSV‑driven age matrix

    /// In‑memory age matrix loaded from `well_visit_age_mapping.csv`.
    ///
    /// Keyed by `VisitTypeID` (e.g. "newborn_first", "nine_month", ...).
    /// This makes the CSV the single source of truth for age‑based
    /// visibility of current‑visit fields.
    private static let ageMatrix: [String: AgeMatrixRow] = {
        loadAgeMatrix()
    }()

    /// Loads the CSV matrix from the app bundle.
    ///
    /// Expected columns (case‑sensitive):
    /// - "VisitTypeID"
    /// - "weightDelta", "structuredFeedingUnder12", "earlyMilkOnly",
    ///   "solidsBlock", "olderFeeding",
    ///   "earlySleep", "olderSleep", "post12mVisit",
    ///   "fontanelle", "primitiveNeuro", "moro", "hipsFocus", "teeth",
    ///   "MCHAT", "DevTestScore", "DevTestResult"
    ///
    /// Any missing or unparsable value is treated as `false`.
    private static func loadAgeMatrix() -> [String: AgeMatrixRow] {
        guard let url = Bundle.main.url(forResource: "well_visit_age_mapping", withExtension: "csv") else {
            NSLog("%@", L("log.well_visit_report_rules.csv_not_found_fallback"))
            return [:]
        }

        guard let data = try? Data(contentsOf: url),
              let rawString = String(data: data, encoding: .utf8) else {
            NSLog("%@", L("log.well_visit_report_rules.csv_read_failed_fallback"))
            return [:]
        }

        var result: [String: AgeMatrixRow] = [:]

        let lines = rawString
            .split(whereSeparator: { $0.isNewline })
            .map { String($0) }

        guard let headerLine = lines.first else {
            NSLog("%@", L("log.well_visit_report_rules.csv_empty_fallback"))
            return [:]
        }

        let headers = headerLine.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        func index(of column: String) -> Int? {
            headers.firstIndex { $0 == column }
        }

        guard
            let idxVisitType = index(of: "VisitTypeID"),
            let idxWeightDelta = index(of: "weightDelta"),
            let idxStructuredFeeding = index(of: "structuredFeedingUnder12"),
            let idxEarlyMilkOnly = index(of: "earlyMilkOnly"),
            let idxSolidsBlock = index(of: "solidsBlock"),
            let idxOlderFeeding = index(of: "olderFeeding"),
            let idxEarlySleep = index(of: "earlySleep"),
            let idxOlderSleep = index(of: "olderSleep"),
            let idxPost12m = index(of: "post12mVisit"),
            let idxFontanelle = index(of: "fontanelle"),
            let idxPrimitiveNeuro = index(of: "primitiveNeuro"),
            let idxMoro = index(of: "moro"),
            let idxHipsFocus = index(of: "hipsFocus"),
            let idxTeeth = index(of: "teeth"),
            let idxMCHAT = index(of: "MCHAT"),
            let idxDevTestScore = index(of: "DevTestScore"),
            let idxDevTestResult = index(of: "DevTestResult")
        else {
            NSLog("%@", L("log.well_visit_report_rules.csv_missing_columns_fallback"))
            return [:]
        }

        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            // Simple comma‑splitter: our CSV does not use embedded commas.
            let cols = line.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard idxVisitType < cols.count else { continue }

            let visitTypeID = cols[idxVisitType]
            if visitTypeID.isEmpty { continue }

            func boolAt(_ idx: Int) -> Bool {
                guard idx < cols.count else { return false }
                return boolFromCSV(cols[idx])
            }

            let row = AgeMatrixRow(
                visitTypeID: visitTypeID,
                isWeightDeltaVisit: boolAt(idxWeightDelta),
                isEarlyMilkOnlyVisit: boolAt(idxEarlyMilkOnly),
                isStructuredFeedingUnder12: boolAt(idxStructuredFeeding),
                isSolidsVisit: boolAt(idxSolidsBlock),
                isOlderFeedingVisit: boolAt(idxOlderFeeding),
                isEarlySleepVisit: boolAt(idxEarlySleep),
                isOlderSleepVisit: boolAt(idxOlderSleep),
                isPostTwelveMonthVisit: boolAt(idxPost12m),
                isFontanelleVisit: boolAt(idxFontanelle),
                isPrimitiveNeuroVisit: boolAt(idxPrimitiveNeuro),
                isMoroVisit: boolAt(idxMoro),
                isHipsVisit: boolAt(idxHipsFocus),
                isTeethVisit: boolAt(idxTeeth),
                isMCHATVisit: boolAt(idxMCHAT),
                isDevTestScoreVisit: boolAt(idxDevTestScore),
                isDevTestResultVisit: boolAt(idxDevTestResult)
            )

            result[visitTypeID] = row
        }

        return result
    }

    /// Normalises CSV boolean values: "1", "true", "yes" → true; everything else → false.
    private static func boolFromCSV(_ raw: String?) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return false
        }

        let lowered = raw.lowercased()
        return lowered == "1" || lowered == "true" || lowered == "yes" || lowered == "y"
    }

    /// Returns the age‑specific flags for a given visit type (e.g. "nine_month").
    static func flags(for visitTypeID: String) -> WellVisitReportFlags {
        // Prefer the CSV‑driven matrix if we have a row for this visit type.
        if let row = ageMatrix[visitTypeID] {
            return WellVisitReportFlags(
                visitTypeID: visitTypeID,
                isWeightDeltaVisit: row.isWeightDeltaVisit,
                isEarlyMilkOnlyVisit: row.isEarlyMilkOnlyVisit,
                isStructuredFeedingUnder12: row.isStructuredFeedingUnder12,
                isSolidsVisit: row.isSolidsVisit,
                isOlderFeedingVisit: row.isOlderFeedingVisit,
                isEarlySleepVisit: row.isEarlySleepVisit,
                isOlderSleepVisit: row.isOlderSleepVisit,
                isPostTwelveMonthVisit: row.isPostTwelveMonthVisit,
                isFontanelleVisit: row.isFontanelleVisit,
                isPrimitiveNeuroVisit: row.isPrimitiveNeuroVisit,
                isMoroVisit: row.isMoroVisit,
                isHipsVisit: row.isHipsVisit,
                isTeethVisit: row.isTeethVisit,
                isMCHATVisit: row.isMCHATVisit,
                isDevTestScoreVisit: row.isDevTestScoreVisit,
                isDevTestResultVisit: row.isDevTestResultVisit
            )
        }

        // If there is no CSV row, default to "all false" so we never leak
        // unexpected content into the current‑visit sections.
        NSLog("%@", LF("log.well_visit_report_rules.no_row_default_false", visitTypeID))
        return WellVisitReportFlags(
            visitTypeID: visitTypeID,
            isWeightDeltaVisit: false,
            isEarlyMilkOnlyVisit: false,
            isStructuredFeedingUnder12: false,
            isSolidsVisit: false,
            isOlderFeedingVisit: false,
            isEarlySleepVisit: false,
            isOlderSleepVisit: false,
            isPostTwelveMonthVisit: false,
            isFontanelleVisit: false,
            isPrimitiveNeuroVisit: false,
            isMoroVisit: false,
            isHipsVisit: false,
            isTeethVisit: false,
            isMCHATVisit: false,
            isDevTestScoreVisit: false,
            isDevTestResultVisit: false
        )
    }

}

/// Convenience wrapper so the report layer can grab everything it needs
/// (age group, layout profile, and flags) in one call.
struct WellVisitReportProfile {
    let visitTypeID: String
    let ageGroup: WellVisitAgeGroup
    let layout: WellVisitLayoutProfile
    let flags: WellVisitReportFlags
}


extension WellVisitReportRules {

    /// High‑level visibility wrapper that the report layer can use to
    /// decide which well‑visit sections to render for a given visit.
    ///
    /// This is deliberately thin: it exposes the underlying profile
    /// (age group, layout profile, and flags) plus some convenience
    /// computed properties that map directly to the booleans in
    /// `WellVisitReportFlags`.
    struct WellVisitVisibility {
        /// Full profile (age group + layout + flags) for this visit type.
        let profile: WellVisitReportProfile

        /// Age in months at the time of the visit, if known.
        let ageMonths: Double?

        /// Shorthand accessors
        var flags: WellVisitReportFlags { profile.flags }
        var ageGroup: WellVisitAgeGroup { profile.ageGroup }
        var layout: WellVisitLayoutProfile { profile.layout }

        // MARK: - Feeding & nutrition

        var showWeightDelta: Bool { flags.isWeightDeltaVisit }
        var showEarlyMilkOnlyFeeding: Bool { flags.isEarlyMilkOnlyVisit }
        var showStructuredFeedingUnder12: Bool { flags.isStructuredFeedingUnder12 }
        var showSolids: Bool { flags.isSolidsVisit }
        var showOlderFeeding: Bool { flags.isOlderFeedingVisit }

        // MARK: - Sleep

        var showEarlySleep: Bool { flags.isEarlySleepVisit }
        var showOlderSleep: Bool { flags.isOlderSleepVisit }
        var isPostTwelveMonthVisit: Bool { flags.isPostTwelveMonthVisit }

        // MARK: - Physical exam details

        var showFontanelle: Bool { flags.isFontanelleVisit }
        var showPrimitiveNeuro: Bool { flags.isPrimitiveNeuroVisit }
        var showMoro: Bool { flags.isMoroVisit }
        var showHips: Bool { flags.isHipsVisit }
        var showTeeth: Bool { flags.isTeethVisit }

        // MARK: - Developmental tools

        var showMCHAT: Bool { flags.isMCHATVisit }
        var showDevTestScore: Bool { flags.isDevTestScoreVisit }
        var showDevTestResult: Bool { flags.isDevTestResultVisit }
    }

    /// Convenience entry point for the report layer:
    /// given a stored visit type (string) and the age in months,
    /// return a `WellVisitVisibility` wrapper that contains the
    /// correct age‑based flags and layout profile.
    ///
    /// Now normalizes human-readable visit type labels to internal IDs.
    static func visibility(for visitTypeRaw: String?, ageMonths: Double?) -> WellVisitVisibility? {
        guard let raw = visitTypeRaw,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        // Normalize any human‑readable labels (e.g. "1‑month visit") to the
        // internal canonical visitTypeID used by the age matrix and layout
        // profiles (e.g. "one_month").
        let visitTypeID = normalizeVisitTypeID(raw)

        let profile = reportProfile(for: visitTypeID)

        return WellVisitVisibility(
            profile: profile,
            ageMonths: ageMonths
        )
    }

    /// Existing helper: bundles age group, layout profile and flags
    /// for a given visit type ID.
    static func reportProfile(for visitTypeID: String) -> WellVisitReportProfile {
        let ageGroup = ageGroupForVisitType(visitTypeID)
        let layout = reportLayoutProfile(forVisitType: visitTypeID)
        let flags = flags(for: visitTypeID)

        return WellVisitReportProfile(
            visitTypeID: visitTypeID,
            ageGroup: ageGroup,
            layout: layout,
            flags: flags
        )
    }

    /// Normalises raw visit type strings from the DB (which may be
    /// human‑readable labels such as "1‑month visit") into the
    /// canonical internal IDs used by the age matrix and layout
    /// profiles (e.g. "one_month").
    private static func normalizeVisitTypeID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        switch trimmed {
        case "Newborn first visit":
            return "newborn_first"
        case "1-month visit":
            return "one_month"
        case "2-month visit":
            return "two_month"
        case "4-month visit":
            return "four_month"
        case "6-month visit":
            return "six_month"
        case "9-month visit":
            return "nine_month"
        case "12-month visit":
            return "twelve_month"
        case "15-month visit":
            return "fifteen_month"
        case "18-month visit":
            return "eighteen_month"
        case "24-month visit":
            return "twentyfour_month"
        case "30-month visit":
            return "thirty_month"
        case "36-month visit":
            return "thirtysix_month"
        default:
            return trimmed
        }
    }
}

extension WellVisitReportRules {

    // MARK: - Field-level gating for the current visit

    /// Enumerates the individual current-visit fields that can be age-gated
    /// in the report. The report / data loader layer should use these keys
    /// instead of re-implementing age logic.
    enum CurrentVisitField {
        // Feeding & nutrition
        case weightDelta
        case earlyMilkOnlyFeeding
        case structuredFeedingUnder12
        case solids
        case olderFeeding

        // Sleep
        case earlySleep
        case olderSleep

        // Physical exam details
        case fontanelle
        case primitiveNeuro
        case moro
        case hips
        case teeth

        // Developmental tools
        case mchat
        case devTestScore
        case devTestResult
    }

    /// Maps a logical current-visit field group to the underlying DB column keys
    /// in the `well_visits` table. These keys are the canonical identifiers that
    /// `ReportDataLoader` can use to filter its raw dictionaries.
    private static func dbColumns(for field: CurrentVisitField) -> [String] {
        switch field {
        // Feeding & nutrition
        case .weightDelta:
            // Delta weight visits: we only gate the delta-related fields; growth
            // charts and absolute measurements are handled elsewhere.
            return [
                "delta_weight_g",
                "delta_days_since_discharge"
            ]

        case .earlyMilkOnlyFeeding,
             .structuredFeedingUnder12:
            // Early milk-only / structured feeding under 12 months share the
            // same underlying DB columns. The age matrix decides which logical
            // block is active for a given visit type.
            return [
                "feed_freq_per_24h",
                "feed_volume_ml",
                "milk_types",
                "expressed_bm",
                "est_total_ml",
                "est_ml_per_kg_24h",
                "wakes_for_feeds",
                "dairy_amount_text",
                "feeding_issue",
                "feeding_comment",
                "regurgitation"
            ]

        case .solids:
            // Solids-specific fields, only relevant once solid foods are started.
            return [
                "solid_food_started",
                "solid_food_start_date",
                "solid_food_comment",
                "solid_food_quality"
            ]

        case .olderFeeding:
            // Older feeding focus: variety / quality plus general feeding issues.
            return [
                "food_variety_quality",
                "dairy_amount_text",
                "feeding_issue",
                "feeding_comment",
                "regurgitation"
            ]

        // Sleep
        case .earlySleep:
            // Early sleep profile (newborn / infant): structural sleep patterns only.
            // Snoring is reserved for the older sleep profile.
            return [
                "sleep_hours_text",
                "longer_sleep_night",
                "sleep_regular",
                "sleep_issue",
                "sleep_issue_reported",
                "sleep_issue_text"
            ]

        case .olderSleep:
            // Older sleep profile: same base fields as early sleep, plus snoring.
            return [
                "sleep_hours_text",
                "longer_sleep_night",
                "sleep_regular",
                "sleep_issue",
                "sleep_issue_reported",
                "sleep_issue_text",
                "sleep_snoring"
            ]

        // Physical exam details
        case .fontanelle:
            return [
                "pe_fontanelle_normal",
                "pe_fontanelle_comment"
            ]

        case .primitiveNeuro:
            // Primitive neuro signs and general tone / wakefulness.
            return [
                "pe_hands_fist_normal",
                "pe_hands_fist_comment",
                "pe_tone_normal",
                "pe_tone_comment",
                "pe_wakefulness_normal",
                "pe_wakefulness_comment",
                "pe_symmetry_normal",
                "pe_symmetry_comment",
                "pe_follows_midline_normal",
                "pe_follows_midline_comment"
            ]

        case .moro:
            return [
                "pe_moro_normal",
                "pe_moro_comment"
            ]

        case .hips:
            return [
                "pe_hips_normal",
                "pe_hips_comment"
            ]

        case .teeth:
            return [
                "pe_teeth_present",
                "pe_teeth_count",
                "pe_teeth_comment"
            ]

        // Developmental tools
        case .mchat:
            return [
                "mchat_score",
                "mchat_result"
            ]

        case .devTestScore:
            return [
                "devtest_score"
            ]

        case .devTestResult:
            return [
                "devtest_result"
            ]
        }
    }

    /// Central age-gating rule for a *single* current-visit field.
    ///
    /// - Parameters:
    ///   - field: Which logical field we are deciding about.
    ///   - visibility: Age/layout profile returned by `visibility(...)`.
    ///   - hasContent: Whether the clinician actually entered non-placeholder content
    ///                 for this field (e.g. non-empty, not just "—").
    ///
    /// - Returns: `true` if the field should be included in the report for this visit.
    ///
    /// Contract:
    /// - The age matrix is the single source of truth: if it marks this field as part
    ///   of the visit, the field is eligible to appear in the report.
    /// - Fields that are not enabled by the age matrix are never shown in the
    ///   current-visit sections, even if they contain data (this avoids leaking
    ///   legacy / test content such as early solids into newborn visits).
    static func shouldShow(field: CurrentVisitField,
                           for visibility: WellVisitVisibility,
                           hasContent: Bool) -> Bool {

        let flags = visibility.flags
        let ageAllows: Bool

        switch field {
        // Feeding & nutrition
        case .weightDelta:
            ageAllows = flags.isWeightDeltaVisit
        case .earlyMilkOnlyFeeding:
            ageAllows = flags.isEarlyMilkOnlyVisit
        case .structuredFeedingUnder12:
            ageAllows = flags.isStructuredFeedingUnder12
        case .solids:
            ageAllows = flags.isSolidsVisit
        case .olderFeeding:
            ageAllows = flags.isOlderFeedingVisit

        // Sleep
        case .earlySleep:
            ageAllows = flags.isEarlySleepVisit
        case .olderSleep:
            ageAllows = flags.isOlderSleepVisit

        // Physical exam details
        case .fontanelle:
            ageAllows = flags.isFontanelleVisit
        case .primitiveNeuro:
            ageAllows = flags.isPrimitiveNeuroVisit
        case .moro:
            ageAllows = flags.isMoroVisit
        case .hips:
            ageAllows = flags.isHipsVisit
        case .teeth:
            ageAllows = flags.isTeethVisit

        // Developmental tools
        case .mchat:
            ageAllows = flags.isMCHATVisit
        case .devTestScore:
            ageAllows = flags.isDevTestScoreVisit
        case .devTestResult:
            ageAllows = flags.isDevTestResultVisit
        }
        // Mark parameter as "used" to avoid warnings; the age matrix alone drives visibility.
        _ = hasContent

        // Age matrix is the single source of truth: if it does not allow this field
        // for the current visit type, we never show it in the current-visit sections.
        return ageAllows
    }

    // MARK: - Allowed DB columns for the current visit

    /// Returns the set of DB column keys (from the `well_visits` table) that are
    /// age-allowed for the given visit, based solely on the age matrix.
    ///
    /// Content-based filtering (e.g. dropping empty fields) remains the
    /// responsibility of `ReportDataLoader`, which can intersect these keys
    /// with whatever non-empty values it has loaded from the database.
    static func allowedDBColumns(for visibility: WellVisitVisibility) -> Set<String> {
        var columns = Set<String>()

        func consider(_ field: CurrentVisitField) {
            // Age matrix is the single source of truth for whether this logical
            // block belongs to the current visit type.
            if shouldShow(field: field, for: visibility, hasContent: true) {
                columns.formUnion(dbColumns(for: field))
            }
        }

        // Feeding & nutrition
        consider(.weightDelta)
        consider(.earlyMilkOnlyFeeding)
        consider(.structuredFeedingUnder12)
        consider(.solids)
        consider(.olderFeeding)

        // Sleep
        consider(.earlySleep)
        consider(.olderSleep)

        // Physical exam details
        consider(.fontanelle)
        consider(.primitiveNeuro)
        consider(.moro)
        consider(.hips)
        consider(.teeth)

        // Developmental tools
        consider(.mchat)
        consider(.devTestScore)
        consider(.devTestResult)

        // Vitamin D supplementation is relevant for all visit types and should
        // never be age‑gated. Always allow these columns if they contain data.
        columns.formUnion([
            "vitamin_d",
            "vitamin_d_given"
        ])

        return columns
    }

    /// Convenience overload: computes the allowed DB column keys directly from
    /// the stored visit type label and age in months. If the visit type cannot
    /// be normalised or has no age profile, this returns an empty set.
    static func allowedDBColumns(for visitTypeRaw: String?, ageMonths: Double?) -> Set<String> {
        guard let visibility = visibility(for: visitTypeRaw, ageMonths: ageMonths) else {
            return []
        }
        return allowedDBColumns(for: visibility)
    }
}
