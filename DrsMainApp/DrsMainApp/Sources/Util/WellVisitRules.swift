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

    /// Attempt to extract a stable well-visit type identifier (e.g. "one_month")
    /// from ReportMeta using reflection, without requiring explicit changes
    /// to ReportMeta itself.
    private static func extractVisitTypeID(from meta: ReportMeta) -> String? {
        // All known visit type IDs used across forms/reports.
        let knownIDs: Set<String> = [
            "newborn_first",
            "one_month",
            "two_month",
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

        func mapTitleToID(_ lower: String) -> String? {
            if lower.contains("newborn") || lower.contains("first after maternity") {
                return "newborn_first"
            }
            if lower.contains("1-month") || lower.contains("1 month") {
                return "one_month"
            }
            if lower.contains("2-month") || lower.contains("2 month") {
                return "two_month"
            }
            if lower.contains("4-month") || lower.contains("4 month") {
                return "four_month"
            }
            if lower.contains("6-month") || lower.contains("6 month") {
                return "six_month"
            }
            if lower.contains("9-month") || lower.contains("9 month") {
                return "nine_month"
            }
            if lower.contains("12-month") || lower.contains("12 month") || lower.contains("1-year") {
                return "twelve_month"
            }
            if lower.contains("15-month") || lower.contains("15 month") {
                return "fifteen_month"
            }
            if lower.contains("18-month") || lower.contains("18 month") {
                return "eighteen_month"
            }
            if lower.contains("24-month") || lower.contains("24 month") || lower.contains("2-year") {
                return "twentyfour_month"
            }
            if lower.contains("30-month") || lower.contains("30 month") {
                return "thirty_month"
            }
            if lower.contains("36-month") || lower.contains("36 month") || lower.contains("3-year") {
                return "thirtysix_month"
            }
            return nil
        }

        func search(_ value: Any, depth: Int = 0) -> String? {
            if depth > 4 { return nil }

            if let s = value as? String {
                if knownIDs.contains(s) {
                    print("[WellVisitRules] extractVisitTypeID: found direct ID '" + s + "'")
                    return s
                }
                if let mapped = mapTitleToID(s.lowercased()) {
                    print("[WellVisitRules] extractVisitTypeID: mapped '" + s + "' -> '" + mapped + "'")
                    return mapped
                }
            }

            let mirror = Mirror(reflecting: value)
            for child in mirror.children {
                if let found = search(child.value, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }

        return search(meta)
    }

    /// Lightweight helper used when we only have a human-readable title
    /// such as "1-month visit" or "12-month visit" instead of a full
    /// ReportMeta object.
    private static func extractVisitTypeID(from visitTypeTitle: String?) -> String? {
        guard let raw = visitTypeTitle, !raw.isEmpty else {
            return nil
        }

        let lower = raw.lowercased()

        // Allow passing a direct internal ID such as "one_month".
        let knownIDs: Set<String> = [
            "newborn_first",
            "one_month",
            "two_month",
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
        if knownIDs.contains(lower) {
            print("[WellVisitRules] extractVisitTypeID: found direct ID '\(lower)' from title")
            return lower
        }

        // Map common human-readable titles to internal IDs.
        if lower.contains("newborn") || lower.contains("first after maternity") {
            return "newborn_first"
        }
        if lower.contains("1-month") || lower.contains("1 month") {
            return "one_month"
        }
        if lower.contains("2-month") || lower.contains("2 month") {
            return "two_month"
        }
        if lower.contains("4-month") || lower.contains("4 month") {
            return "four_month"
        }
        if lower.contains("6-month") || lower.contains("6 month") {
            return "six_month"
        }
        if lower.contains("9-month") || lower.contains("9 month") {
            return "nine_month"
        }
        if lower.contains("12-month") || lower.contains("12 month") || lower.contains("1-year") {
            return "twelve_month"
        }
        if lower.contains("15-month") || lower.contains("15 month") {
            return "fifteen_month"
        }
        if lower.contains("18-month") || lower.contains("18 month") {
            return "eighteen_month"
        }
        if lower.contains("24-month") || lower.contains("24 month") || lower.contains("2-year") {
            return "twentyfour_month"
        }
        if lower.contains("30-month") || lower.contains("30 month") {
            return "thirty_month"
        }
        if lower.contains("36-month") || lower.contains("36 month") || lower.contains("3-year") {
            return "thirtysix_month"
        }

        return nil
    }

    /// Central hook used by ReportBuilder to decide whether a given
    /// well-visit report section should be included for this visit.
    ///
    /// Rules:
    /// - Perinatal summary is always shown.
    /// - If we cannot reliably infer the visit type, we default to
    ///   including all sections (current behaviour).
    /// - Otherwise, we apply simple age-based gating for the current visit.
    static func shouldIncludeSection(title: String, visitTypeTitle: String?) -> Bool {
        // Log the incoming query
        print("[WellVisitRules] shouldIncludeSection? title='\(title)'")

        // Perinatal Summary must ALWAYS be present, regardless of age or visit type
        if title == "Perinatal Summary" {
            print("[WellVisitRules] shouldIncludeSection: always include Perinatal Summary")
            return true
        }

        // Map the human-readable visit type (e.g. "1-month visit", "12-month visit")
        // to our internal ID (e.g. "one_month", "twelve_month")
        let visitTypeID = extractVisitTypeID(from: visitTypeTitle)
        print("[WellVisitRules] shouldIncludeSection: visitTypeID='\(visitTypeID ?? "nil")' for title='\(title)'")

        // If we cannot resolve a visit type ID, fall back to showing the section
        guard let visitTypeID else {
            return true
        }

        // Group visit types into broad age bands for gating logic
        let infantTypes: Set<String> = [
            "newborn_first", // first visit after maternity
            "one_month",
            "two_month",
            "four_month",
            "six_month",
            "nine_month",
            "twelve_month"
        ]

        let toddlerPreschoolTypes: Set<String> = [
            "fifteen_month",
            "eighteen_month",
            "twentyfour_month",
            "thirty_month",
            "thirtysix_month"
        ]

        let ageBand: String
        if infantTypes.contains(visitTypeID) {
            ageBand = "infant"
        } else if toddlerPreschoolTypes.contains(visitTypeID) {
            ageBand = "toddler_preschool"
        } else {
            ageBand = "other"
        }

        // Default is to include sections unless explicitly gated off
        var show = true

        switch ageBand {
        case "infant":
            // For now, all sections are shown for infant visits
            show = true

        case "toddler_preschool":
            // Age gating example:
            // For toddler / preschool visits, hide the standalone "Supplementation" section.
            // (Those visits usually only need Feeding text, without infant-style supplementation block.)
            if title == "Supplementation" {
                show = false
            } else {
                show = true
            }

        default:
            // For any other visit type, keep all sections visible by default
            show = true
        }

        print("[WellVisitRules] shouldIncludeSection: ageBand='\(ageBand)' visitTypeID='\(visitTypeID)' title='\(title)' -> \(show)")
        return show
    }
}
