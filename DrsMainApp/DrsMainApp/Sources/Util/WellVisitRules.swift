//
//  WellVisitRules.swift
//  DrsMainApp
//
//  Created by yunastic on 11/26/25.
//
import Foundation

/// Shared gating rules for well-visits, used by both the SwiftUI form
/// and by the report (DOCX/PDF) builder.
struct WellVisitRules {
    let visitTypeID: String

    struct ReportVisibility {
        let showPerinatal: Bool
        let showGrowth: Bool
        let showFeeding: Bool
        let showSupplementation: Bool
        let showSleep: Bool
        let showDevelopment: Bool
        let showSchool: Bool
        let showParentalConcerns: Bool
        let showVaccines: Bool
        let showScreening: Bool
    }

    static func reportVisibility(for visitTypeID: String) -> ReportVisibility {
        switch visitTypeID {
        case "newborn_first":
            return ReportVisibility(
                showPerinatal: true,
                showGrowth: true,
                showFeeding: true,
                showSupplementation: true,
                showSleep: true,
                showDevelopment: true,
                showSchool: false,
                showParentalConcerns: true,
                showVaccines: false,
                showScreening: false
            )

        case "one_month", "two_month", "four_month":
            return ReportVisibility(
                showPerinatal: false,
                showGrowth: true,
                showFeeding: true,
                showSupplementation: true,
                showSleep: true,
                showDevelopment: true,
                showSchool: false,
                showParentalConcerns: true,
                showVaccines: true,
                showScreening: false
            )

        case "six_month", "nine_month", "twelve_month":
            return ReportVisibility(
                showPerinatal: false,
                showGrowth: true,
                showFeeding: true,
                showSupplementation: true,
                showSleep: true,
                showDevelopment: true,
                showSchool: false,
                showParentalConcerns: true,
                showVaccines: true,
                showScreening: true
            )

        case "fifteen_month", "eighteen_month", "twentyfour_month",
             "thirty_month", "thirtysix_month":
            return ReportVisibility(
                showPerinatal: false,
                showGrowth: true,
                showFeeding: true,
                showSupplementation: false,   // toddler / preschool: no vit D block
                showSleep: true,
                showDevelopment: true,
                showSchool: true,
                showParentalConcerns: true,
                showVaccines: true,
                showScreening: true
            )

        default:
            // Fallback: treat as 6–12 month style visit
            return ReportVisibility(
                showPerinatal: false,
                showGrowth: true,
                showFeeding: true,
                showSupplementation: true,
                showSleep: true,
                showDevelopment: true,
                showSchool: false,
                showParentalConcerns: true,
                showVaccines: true,
                showScreening: true
            )
        }
    }

    var reportVisibility: ReportVisibility {
        Self.reportVisibility(for: visitTypeID)
    }

    // MARK: - Core layout

    var ageGroup: WellVisitAgeGroup {
        ageGroupForVisitType(visitTypeID)
    }

    var layout: WellVisitLayoutProfile {
        layoutProfile(for: ageGroup)
    }

    // MARK: - Simple passthroughs from layout

    var showsVitaminDField: Bool {
        layout.showsVitaminD
    }

    var showsAISection: Bool {
        layout.showsAISection
    }

    // MARK: - Feeding

    /// Solid-food infancy block only for 4-, 6- and 9-month visits.
    var isSolidsVisit: Bool {
        visitTypeID == "four_month"
        || visitTypeID == "six_month"
        || visitTypeID == "nine_month"
    }

    /// Structured feeding (milk checkboxes, volumes, etc.) from newborn to 9-month visits.
    var isStructuredFeedingUnder12: Bool {
        visitTypeID == "newborn_first"
        || visitTypeID == "one_month"
        || visitTypeID == "two_month"
        || visitTypeID == "four_month"
        || visitTypeID == "six_month"
        || visitTypeID == "nine_month"
    }

    /// Early milk-only visits: first-after-maternity, 1-month, 2-month.
    var isEarlyMilkOnlyVisit: Bool {
        visitTypeID == "newborn_first"
        || visitTypeID == "one_month"
        || visitTypeID == "two_month"
    }

    /// 12–36-month visits using the “variety & dairy” block.
    var isOlderFeedingVisit: Bool {
        visitTypeID == "twelve_month"
        || visitTypeID == "fifteen_month"
        || visitTypeID == "eighteen_month"
        || visitTypeID == "twentyfour_month"
        || visitTypeID == "thirty_month"
        || visitTypeID == "thirtysix_month"
    }

    // MARK: - Sleep

    /// Structured sleep fields for early visits:
    /// newborn_first, 1-month, 2-month, 4-month, 6-month, 9-month.
    var isEarlySleepVisit: Bool {
        visitTypeID == "newborn_first"
        || visitTypeID == "one_month"
        || visitTypeID == "two_month"
        || visitTypeID == "four_month"
        || visitTypeID == "six_month"
        || visitTypeID == "nine_month"
    }

    /// Structured sleep fields for older visits:
    /// 12, 15, 18, 24, 30, 36 months.
    var isOlderSleepVisit: Bool {
        visitTypeID == "twelve_month"
        || visitTypeID == "fifteen_month"
        || visitTypeID == "eighteen_month"
        || visitTypeID == "twentyfour_month"
        || visitTypeID == "thirty_month"
        || visitTypeID == "thirtysix_month"
    }

    /// Helper used in problem listing (wakes at night only a problem after 12 months).
    var isPostTwelveMonthVisit: Bool {
        let visitTypes: Set<String> = [
            "fifteen_month",
            "eighteen_month",
            "twentyfour_month",
            "thirty_month",
            "thirtysix_month"
        ]
        return visitTypes.contains(visitTypeID)
    }

    // MARK: - Physical exam gating

    /// Fontanelle relevant up to 24-month visits (exclude preschool ages).
    var isFontanelleVisit: Bool {
        ageGroup != .preschool
    }

    /// Early neurologic primitives (hands in fists, symmetry, follows midline, wakefulness)
    /// for newborn_first, 1-month, 2-month.
    var isPrimitiveNeuroVisit: Bool {
        visitTypeID == "newborn_first"
        || visitTypeID == "one_month"
        || visitTypeID == "two_month"
    }

    /// Moro reflex relevant up to 6-month visit.
    var isMoroVisit: Bool {
        visitTypeID == "newborn_first"
        || visitTypeID == "one_month"
        || visitTypeID == "two_month"
        || visitTypeID == "four_month"
        || visitTypeID == "six_month"
    }

    /// Hips / limbs / posture explicitly focused in the first 6 months.
    var isHipsVisit: Bool {
        visitTypeID == "newborn_first"
        || visitTypeID == "one_month"
        || visitTypeID == "two_month"
        || visitTypeID == "four_month"
        || visitTypeID == "six_month"
    }

    /// Teeth section is shown from 4-month visit onwards.
    var isTeethVisit: Bool {
        let teethVisitTypes: Set<String> = [
            "four_month",
            "six_month",
            "nine_month",
            "twelve_month",
            "fifteen_month",
            "eighteen_month",
            "twentyfour_month",
            "thirty_month",
            "thirtysix_month"
        ]
        return teethVisitTypes.contains(visitTypeID)
    }

    // MARK: - Neurodevelopment screening

    /// M-CHAT at 18, 24, 30 months.
    var isMCHATVisit: Bool {
        visitTypeID == "eighteen_month"
        || visitTypeID == "twentyfour_month"
        || visitTypeID == "thirty_month"
    }

    /// devtest_score at 9, 12, 15, 18, 24, 30, 36 months.
    var isDevTestScoreVisit: Bool {
        visitTypeID == "nine_month"
        || visitTypeID == "twelve_month"
        || visitTypeID == "fifteen_month"
        || visitTypeID == "eighteen_month"
        || visitTypeID == "twentyfour_month"
        || visitTypeID == "thirty_month"
        || visitTypeID == "thirtysix_month"
    }

    /// devtest_result at 9, 12, 15, 18, 24, 30, 36 months.
    var isDevTestResultVisit: Bool {
        visitTypeID == "nine_month"
        || visitTypeID == "twelve_month"
        || visitTypeID == "fifteen_month"
        || visitTypeID == "eighteen_month"
        || visitTypeID == "twentyfour_month"
        || visitTypeID == "thirty_month"
        || visitTypeID == "thirtysix_month"
    }
}

// MARK: - Report gating bridge

extension WellVisitRules {

    /// Central hook used by ReportBuilder to decide whether a given
    /// well-visit report section should be included for this visit.
    ///
    /// For now:
    /// - Always show perinatal summary in well-visit reports.
    /// - Defer age-specific gating until ReportMeta exposes visit type cleanly.
    static func shouldIncludeSection(title: String, meta: ReportMeta) -> Bool {
        // For now:
        // - Always show perinatal summary in well-visit reports.
        // - Defer age-specific gating until ReportMeta exposes visit type cleanly.
        let lower = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Keep perinatal summary visible in all well-visit reports
        if lower.contains("perinatal") {
            return true
        }

        // Placeholder: no additional gating yet; preserve current behaviour
        return true
    }
}
