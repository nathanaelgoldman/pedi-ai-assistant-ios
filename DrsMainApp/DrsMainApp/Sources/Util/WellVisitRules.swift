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
