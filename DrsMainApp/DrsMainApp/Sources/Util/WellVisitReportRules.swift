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
            NSLog("⚠️ WellVisitReportRules: could not find well_visit_age_mapping.csv in bundle, falling back to legacy hard‑coded rules.")
            return [:]
        }

        guard let data = try? Data(contentsOf: url),
              let rawString = String(data: data, encoding: .utf8) else {
            NSLog("⚠️ WellVisitReportRules: failed to read well_visit_age_mapping.csv, falling back to legacy hard‑coded rules.")
            return [:]
        }

        var result: [String: AgeMatrixRow] = [:]

        let lines = rawString
            .split(whereSeparator: { $0.isNewline })
            .map { String($0) }

        guard let headerLine = lines.first else {
            NSLog("⚠️ WellVisitReportRules: CSV appears empty, falling back to legacy hard‑coded rules.")
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
            NSLog("⚠️ WellVisitReportRules: CSV header missing required columns, falling back to legacy hard‑coded rules.")
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
        let ageGroup = ageGroupForVisitType(visitTypeID)

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

        // Fallback: old hard‑coded behaviour if CSV row is missing.
        return WellVisitReportFlags(
            visitTypeID: visitTypeID,
            isWeightDeltaVisit: isWeightDeltaVisit(visitTypeID),
            isEarlyMilkOnlyVisit: isEarlyMilkOnlyVisit(visitTypeID),
            isStructuredFeedingUnder12: isStructuredFeedingUnder12(visitTypeID),
            isSolidsVisit: isSolidsVisit(visitTypeID),
            isOlderFeedingVisit: isOlderFeedingVisit(visitTypeID),
            isEarlySleepVisit: isEarlySleepVisit(visitTypeID),
            isOlderSleepVisit: isOlderSleepVisit(visitTypeID),
            isPostTwelveMonthVisit: isPostTwelveMonthVisit(visitTypeID),
            isFontanelleVisit: isFontanelleVisit(ageGroup: ageGroup),
            isPrimitiveNeuroVisit: isPrimitiveNeuroVisit(visitTypeID),
            isMoroVisit: isMoroVisit(visitTypeID),
            isHipsVisit: isHipsVisit(visitTypeID),
            isTeethVisit: isTeethVisit(visitTypeID),
            isMCHATVisit: isMCHATVisit(visitTypeID),
            isDevTestScoreVisit: isDevTestVisit(visitTypeID),
            isDevTestResultVisit: isDevTestVisit(visitTypeID)
        )
    }

    // MARK: - Private helpers (mirrors the CSV & WellVisitForm logic)

    private static func isWeightDeltaVisit(_ visitTypeID: String) -> Bool {
        switch visitTypeID {
        case "newborn_first", "one_month", "two_month":
            return true
        default:
            return false
        }
    }

    private static func isEarlyMilkOnlyVisit(_ visitTypeID: String) -> Bool {
        switch visitTypeID {
        case "newborn_first", "one_month", "two_month":
            return true
        default:
            return false
        }
    }

    private static func isStructuredFeedingUnder12(_ visitTypeID: String) -> Bool {
        switch visitTypeID {
        case "newborn_first", "one_month", "two_month", "four_month", "six_month", "nine_month":
            return true
        default:
            return false
        }
    }

    private static func isSolidsVisit(_ visitTypeID: String) -> Bool {
        switch visitTypeID {
        case "four_month", "six_month", "nine_month":
            return true
        default:
            return false
        }
    }

    private static func isOlderFeedingVisit(_ visitTypeID: String) -> Bool {
        switch visitTypeID {
        case "twelve_month", "fifteen_month", "eighteen_month",
             "twentyfour_month", "thirty_month", "thirtysix_month":
            return true
        default:
            return false
        }
    }

    private static func isEarlySleepVisit(_ visitTypeID: String) -> Bool {
        switch visitTypeID {
        case "newborn_first", "one_month", "two_month",
             "four_month", "six_month", "nine_month":
            return true
        default:
            return false
        }
    }

    private static func isOlderSleepVisit(_ visitTypeID: String) -> Bool {
        switch visitTypeID {
        case "twelve_month", "fifteen_month", "eighteen_month",
             "twentyfour_month", "thirty_month", "thirtysix_month":
            return true
        default:
            return false
        }
    }

    private static func isPostTwelveMonthVisit(_ visitTypeID: String) -> Bool {
        switch visitTypeID {
        case "fifteen_month", "eighteen_month",
             "twentyfour_month", "thirty_month", "thirtysix_month":
            return true
        default:
            return false
        }
    }

    private static func isFontanelleVisit(ageGroup: WellVisitAgeGroup) -> Bool {
        // Same logic as in WellVisitForm: all age groups except preschool
        switch ageGroup {
        case .preschool:
            return false
        default:
            return true
        }
    }

    private static func isPrimitiveNeuroVisit(_ visitTypeID: String) -> Bool {
        switch visitTypeID {
        case "newborn_first", "one_month", "two_month":
            return true
        default:
            return false
        }
    }

    private static func isMoroVisit(_ visitTypeID: String) -> Bool {
        switch visitTypeID {
        case "newborn_first", "one_month", "two_month", "four_month", "six_month":
            return true
        default:
            return false
        }
    }

    private static func isHipsVisit(_ visitTypeID: String) -> Bool {
        switch visitTypeID {
        case "newborn_first", "one_month", "two_month", "four_month", "six_month":
            return true
        default:
            return false
        }
    }

    private static func isTeethVisit(_ visitTypeID: String) -> Bool {
        switch visitTypeID {
        case "four_month", "six_month", "nine_month",
             "twelve_month", "fifteen_month", "eighteen_month",
             "twentyfour_month", "thirty_month", "thirtysix_month":
            return true
        default:
            return false
        }
    }

    private static func isMCHATVisit(_ visitTypeID: String) -> Bool {
        switch visitTypeID {
        case "eighteen_month", "twentyfour_month", "thirty_month":
            return true
        default:
            return false
        }
    }

    private static func isDevTestVisit(_ visitTypeID: String) -> Bool {
        switch visitTypeID {
        case "nine_month", "twelve_month", "fifteen_month",
             "eighteen_month", "twentyfour_month",
             "thirty_month", "thirtysix_month":
            return true
        default:
            return false
        }
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
        case .devTestScore, .devTestResult:
            ageAllows = flags.isDevTestScoreVisit
        }
        // Mark parameter as "used" to avoid warnings; the age matrix alone drives visibility.
        _ = hasContent

        // Age matrix is the single source of truth: if it does not allow this field
        // for the current visit type, we never show it in the current-visit sections.
        return ageAllows
    }
}
