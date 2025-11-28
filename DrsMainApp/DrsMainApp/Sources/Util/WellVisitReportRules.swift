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

/// Central entry point for age‑based report rules.
///
/// Typical usage from the report side:
///
///     let profile = WellVisitReportRules.reportProfile(for: visitTypeID)
///     let flags = profile.flags
///     if flags.isWeightDeltaVisit { ... pull & render weight delta ... }
///
enum WellVisitReportRules {

    /// Returns the age‑specific flags for a given visit type (e.g. "nine_month").
    static func flags(for visitTypeID: String) -> WellVisitReportFlags {
        let ageGroup = ageGroupForVisitType(visitTypeID)

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
    /// For now we assume `visitTypeRaw` is already one of the
    /// canonical IDs used throughout the app (e.g. "nine_month").
    /// If we ever pass a "pretty" label (e.g. "9‑month visit"),
    /// we can add a normalization layer here without touching
    /// the report caller.
    static func visibility(for visitTypeRaw: String?, ageMonths: Double?) -> WellVisitVisibility? {
        guard let raw = visitTypeRaw,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        // At this stage we treat the raw string as the internal visitTypeID.
        // If the DB later stores human‑readable labels instead, we can map
        // them back to the canonical IDs here.
        let visitTypeID = raw
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
}
