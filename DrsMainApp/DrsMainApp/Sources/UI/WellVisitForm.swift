
//  WellVisitForm.swift
//  DrsMainApp
//
//  Created by yunastic on 11/20/25.
//

import SwiftUI
import SQLite3
#if os(macOS)
import AppKit
#endif

private var maxWellVisitFormHeight: CGFloat {
    #if os(macOS)
    let screenH = NSScreen.main?.visibleFrame.height ?? 900
    // Leave room for title bar / toolbar / padding
    return max(CGFloat(640), screenH - 140)
    #else
    return 1100
    #endif
}

// Matches C macro used elsewhere so we can safely bind text.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Localization

/// Small helper for `Localizable.strings` keys.
/// Use `.k(...)` for SwiftUI text and `.s(...)` when a `String` is required.
private enum L10nWVF {
    static func k(_ key: String) -> LocalizedStringKey { LocalizedStringKey(key) }
    static func s(_ key: String) -> String { NSLocalizedString(key, comment: "") }
}

// MARK: - GroupBox helper style (removes default gray GroupBox chrome)
/// A minimal GroupBoxStyle that removes the default rounded/gray container
/// so we can apply our own card background (lightBlueSectionCardStyle).
fileprivate struct PlainGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            configuration.content
        }
    }
}
// MARK: - Light-blue section card styling (matches SickEpisodeForm)
fileprivate struct LightBlueSectionCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1)
            )
    }
}

fileprivate extension View {
    /// Apply the standard light-blue “section card” look (used for blocks inside forms).
    func lightBlueSectionCardStyle() -> some View {
        self.modifier(LightBlueSectionCardStyle())
    }
}

// MARK: - Problem listing tokens (step 1)

/// Stable, localization-proof representation of problem-listing lines.
/// Stored as JSON in `well_visits.problem_listing_tokens` and consumed by report generation.
struct ProblemToken: Codable, Hashable {
    let key: String
    let args: [String]

    init(_ key: String, _ args: [String] = []) {
        self.key = key
        self.args = args
    }
}

// MARK: - Milestone model & catalog

private struct MilestoneDescriptor: Identifiable, Hashable {
    let id = UUID()
    let code: String
    let labelKey: String

    var label: String {
        L10nWVF.s(labelKey)
    }
}

private enum MilestoneStatus: String, CaseIterable, Identifiable {
    case achieved = "achieved"
        case uncertain = "uncertain"
        case notYet = "not_yet"

        var id: String { rawValue }

        /// Localized label for UI.
        var localizedDisplayName: String {
            let key = "well_visit_form.milestones.status.\(rawValue)"
            let s = NSLocalizedString(key, comment: "")
            return (s == key) ? rawValue : s
        }

        /// Backwards-compatible parser for older DB rows (e.g. "not yet").
        static func parseStored(_ raw: String) -> MilestoneStatus? {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return nil }

            if let exact = MilestoneStatus(rawValue: t) { return exact }

            let c = t.lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")

            switch c {
            case "achieved": return .achieved
            case "uncertain": return .uncertain
            case "not_yet", "notyet", "notdone", "not_done", "not_achieved":
                return .notYet
            default:
                return nil
            }
        }
}

// Milestone sets, ported from the Python MILESTONE_SETS
private let WELL_VISIT_MILESTONES: [String: [MilestoneDescriptor]] = [
    "newborn_first": [
        .init(code: "regards_face",       labelKey: "well_visit_form.milestone.regards_face"),
        .init(code: "follows_to_midline", labelKey: "well_visit_form.milestone.follows_to_midline"),
        .init(code: "alerts_to_sound",    labelKey: "well_visit_form.milestone.alerts_to_sound_voice"),
        .init(code: "calms_to_voice",     labelKey: "well_visit_form.milestone.calms_to_caregiver_voice"),
        .init(code: "lifts_chin",         labelKey: "well_visit_form.milestone.lifts_chin_chest_prone"),
        .init(code: "symmetric_moves",    labelKey: "well_visit_form.milestone.symmetric_movements"),
    ],
    "one_month": [
        .init(code: "regards_face",       labelKey: "well_visit_form.milestone.regards_face"),
        .init(code: "follows_to_midline", labelKey: "well_visit_form.milestone.follows_to_midline"),
        .init(code: "alerts_to_sound",    labelKey: "well_visit_form.milestone.alerts_to_sound_voice"),
        .init(code: "calms_to_voice",     labelKey: "well_visit_form.milestone.calms_to_caregiver_voice"),
        .init(code: "lifts_chin",         labelKey: "well_visit_form.milestone.lifts_chin_briefly_prone"),
        .init(code: "symmetric_moves",    labelKey: "well_visit_form.milestone.symmetric_movements"),
    ],
    "two_month": [
        .init(code: "social_smile",         labelKey: "well_visit_form.milestone.social_smile"),
        .init(code: "coos",                 labelKey: "well_visit_form.milestone.coos_vowel_sounds"),
        .init(code: "follows_past_midline", labelKey: "well_visit_form.milestone.follows_past_midline"),
        .init(code: "lifts_head_prone",     labelKey: "well_visit_form.milestone.lifts_head_45_prone"),
        .init(code: "hands_to_mouth",       labelKey: "well_visit_form.milestone.hands_to_mouth_opens_hands"),
        .init(code: "alerts_to_sound",      labelKey: "well_visit_form.milestone.alerts_quiets_to_sound_voice"),
    ],
    "four_month": [
        .init(code: "social_smile",        labelKey: "well_visit_form.milestone.social_smile"),
        .init(code: "babbles",             labelKey: "well_visit_form.milestone.babbles_coos"),
        .init(code: "hands_together",      labelKey: "well_visit_form.milestone.hands_midline_together"),
        .init(code: "reaches_toys",        labelKey: "well_visit_form.milestone.reaches_for_toys"),
        .init(code: "supports_head",       labelKey: "well_visit_form.milestone.good_head_control"),
        .init(code: "rolls_prone_supine",  labelKey: "well_visit_form.milestone.rolls_prone_to_supine"),
    ],
    "six_month": [
        .init(code: "responds_name",       labelKey: "well_visit_form.milestone.responds_to_name"),
        .init(code: "babbles_consonants",  labelKey: "well_visit_form.milestone.consonant_babble"),
        .init(code: "transfers",           labelKey: "well_visit_form.milestone.transfers_hand_to_hand"),
        .init(code: "sits_support",        labelKey: "well_visit_form.milestone.sits_minimal_support"),
        .init(code: "rolls_both",          labelKey: "well_visit_form.milestone.rolls_both_ways"),
        .init(code: "stranger_awareness",  labelKey: "well_visit_form.milestone.stranger_awareness"),
    ],
    "nine_month": [
        .init(code: "peekaboo",            labelKey: "well_visit_form.milestone.plays_peekaboo"),
        .init(code: "mam_bab_dad",         labelKey: "well_visit_form.milestone.mam_bab_dad_nonspecific"),
        .init(code: "pincer",              labelKey: "well_visit_form.milestone.inferior_pincer_grasp"),
        .init(code: "sits_no_support",     labelKey: "well_visit_form.milestone.sits_without_support"),
        .init(code: "pulls_to_stand",      labelKey: "well_visit_form.milestone.pulls_to_stand"),
        .init(code: "waves_bye",           labelKey: "well_visit_form.milestone.waves_byebye"),
    ],
    "twelve_month": [
        .init(code: "specific_mama_dada",  labelKey: "well_visit_form.milestone.mama_dada_specific"),
        .init(code: "one_word",            labelKey: "well_visit_form.milestone.at_least_one_word"),
        .init(code: "fine_pincer",         labelKey: "well_visit_form.milestone.fine_pincer_grasp"),
        .init(code: "stands_alone",        labelKey: "well_visit_form.milestone.stands_alone"),
        .init(code: "walks",               labelKey: "well_visit_form.milestone.takes_a_few_steps"),
        .init(code: "points",              labelKey: "well_visit_form.milestone.points_proto_declarative"),
    ],
    "fifteen_month": [
        .init(code: "walks_independent",   labelKey: "well_visit_form.milestone.walks_independently"),
        .init(code: "scribbles",           labelKey: "well_visit_form.milestone.scribbles"),
        .init(code: "uses_3_words",        labelKey: "well_visit_form.milestone.uses_3_words"),
        .init(code: "points_request",      labelKey: "well_visit_form.milestone.points_to_request_objects"),
        .init(code: "drink_cup",           labelKey: "well_visit_form.milestone.drinks_from_cup"),
        .init(code: "imitates",            labelKey: "well_visit_form.milestone.imitates_simple_actions"),
    ],
    "eighteen_month": [
        .init(code: "runs",                labelKey: "well_visit_form.milestone.runs"),
        .init(code: "stair_help",          labelKey: "well_visit_form.milestone.walks_up_steps_with_help"),
        .init(code: "uses_10_words",       labelKey: "well_visit_form.milestone.uses_10_to_25_words"),
        .init(code: "pretend_play",        labelKey: "well_visit_form.milestone.begins_pretend_play"),
        .init(code: "points_body_parts",   labelKey: "well_visit_form.milestone.points_to_3_body_parts"),
        .init(code: "feeds_spoon",         labelKey: "well_visit_form.milestone.feeds_self_with_spoon"),
    ],
    "twentyfour_month": [
        .init(code: "two_word_phrases",    labelKey: "well_visit_form.milestone.two_word_phrases"),
        .init(code: "follows_2step",       labelKey: "well_visit_form.milestone.follows_2_step_command"),
        .init(code: "jumps",               labelKey: "well_visit_form.milestone.jumps_with_both_feet"),
        .init(code: "stacks_blocks",       labelKey: "well_visit_form.milestone.stacks_5_to_6_blocks"),
        .init(code: "parallel_play",       labelKey: "well_visit_form.milestone.parallel_play"),
        .init(code: "removes_clothing",    labelKey: "well_visit_form.milestone.removes_some_clothing"),
    ],
    "thirty_month": [
        .init(code: "understands_prepositions", labelKey: "well_visit_form.milestone.understands_prepositions"),
        .init(code: "throws_overhand",          labelKey: "well_visit_form.milestone.throws_ball_overhand"),
        .init(code: "imitates_lines",           labelKey: "well_visit_form.milestone.imitates_vertical_line"),
        .init(code: "toilet_awareness",         labelKey: "well_visit_form.milestone.toilet_awareness"),
        .init(code: "speaks_50_words",          labelKey: "well_visit_form.milestone.vocabulary_50_words"),
        .init(code: "shares_interest",          labelKey: "well_visit_form.milestone.shares_interest_with_adult"),
    ],
    "thirtysix_month": [
        .init(code: "pedals_tricycle",          labelKey: "well_visit_form.milestone.pedals_tricycle"),
        .init(code: "balances_moment",          labelKey: "well_visit_form.milestone.balances_one_foot_momentarily"),
        .init(code: "draws_circle",             labelKey: "well_visit_form.milestone.draws_circle"),
        .init(code: "speaks_sentences",         labelKey: "well_visit_form.milestone.uses_3_word_sentences"),
        .init(code: "colors_names",             labelKey: "well_visit_form.milestone.names_colors_pictures"),
        .init(code: "interactive_play",         labelKey: "well_visit_form.milestone.engages_interactive_play"),
    ],
    "four_year": [
        .init(code: "knows_first_last_name",           labelKey: "well_visit_form.milestone.knows_first_last_name"),
        .init(code: "can_tell_stories",               labelKey: "well_visit_form.milestone.can_tell_stories"),
        .init(code: "sentences_4plus_words",          labelKey: "well_visit_form.milestone.sentences_4plus_words"),
        .init(code: "prefers_play_with_others",       labelKey: "well_visit_form.milestone.prefers_play_with_others"),
        .init(code: "cooperates_with_children",       labelKey: "well_visit_form.milestone.cooperates_with_children"),
        .init(code: "confuses_real_makebelieve",      labelKey: "well_visit_form.milestone.confuses_real_vs_makebelieve"),
        .init(code: "names_colors_numbers",           labelKey: "well_visit_form.milestone.names_colors_and_numbers"),
        .init(code: "understands_time_starting",      labelKey: "well_visit_form.milestone.starts_to_understand_time"),
        .init(code: "draws_person_2_4_parts",         labelKey: "well_visit_form.milestone.draws_person_2_to_4_parts"),
        .init(code: "hops_one_foot_2s",               labelKey: "well_visit_form.milestone.hops_one_foot_2_seconds"),
        .init(code: "catches_bounced_ball",           labelKey: "well_visit_form.milestone.catches_bounced_ball"),
        .init(code: "uses_scissors_draw_shapes",      labelKey: "well_visit_form.milestone.uses_scissors_draws_shapes"),
    ],
    "five_year": [
        .init(code: "speaks_clearly",                 labelKey: "well_visit_form.milestone.speaks_clearly"),
        .init(code: "tells_simple_story_full_sentences", labelKey: "well_visit_form.milestone.tells_simple_story_full_sentences"),
        .init(code: "uses_future_tense",              labelKey: "well_visit_form.milestone.uses_future_tense"),
        .init(code: "wants_to_please_be_like_friends", labelKey: "well_visit_form.milestone.wants_to_please_be_like_friends"),
        .init(code: "likes_sing_dance_act",           labelKey: "well_visit_form.milestone.likes_to_sing_dance_act"),
        .init(code: "distinguishes_real_makebelieve", labelKey: "well_visit_form.milestone.distinguishes_real_vs_makebelieve"),
        .init(code: "counts_10_plus",                 labelKey: "well_visit_form.milestone.counts_10_or_more"),
        .init(code: "draws_person_6_parts",           labelKey: "well_visit_form.milestone.draws_person_6_parts"),
        .init(code: "knows_everyday_things",          labelKey: "well_visit_form.milestone.knows_everyday_things"),
        .init(code: "hops_may_skip",                  labelKey: "well_visit_form.milestone.hops_may_skip"),
        .init(code: "uses_fork_spoon_well",           labelKey: "well_visit_form.milestone.uses_fork_and_spoon_well"),
        .init(code: "dresses_undresses_self",         labelKey: "well_visit_form.milestone.dresses_undresses_without_help"),
    ],
]

// Visit type list for the picker
private struct WellVisitType: Identifiable {
    let id: String
    let titleKey: String

    var title: String {
        L10nWVF.s(titleKey)
    }
}

private let WELL_VISIT_TYPES: [WellVisitType] = [
    .init(id: "newborn_first",    titleKey: "well_visit_form.visit_type.newborn_first"),
    .init(id: "one_month",        titleKey: "well_visit_form.visit_type.one_month"),
    .init(id: "two_month",        titleKey: "well_visit_form.visit_type.two_month"),
    .init(id: "four_month",       titleKey: "well_visit_form.visit_type.four_month"),
    .init(id: "six_month",        titleKey: "well_visit_form.visit_type.six_month"),
    .init(id: "nine_month",       titleKey: "well_visit_form.visit_type.nine_month"),
    .init(id: "twelve_month",     titleKey: "well_visit_form.visit_type.twelve_month"),
    .init(id: "fifteen_month",    titleKey: "well_visit_form.visit_type.fifteen_month"),
    .init(id: "eighteen_month",   titleKey: "well_visit_form.visit_type.eighteen_month"),
    .init(id: "twentyfour_month", titleKey: "well_visit_form.visit_type.twentyfour_month"),
    .init(id: "thirty_month",     titleKey: "well_visit_form.visit_type.thirty_month"),
    .init(id: "thirtysix_month",  titleKey: "well_visit_form.visit_type.thirtysix_month"),
    .init(id: "four_year",        titleKey: "well_visit_form.visit_type.four_year"),
    .init(id: "five_year",        titleKey: "well_visit_form.visit_type.five_year"),
]

// Logical age groups for visit-type–specific layouts and reporting.
// This lets us keep UI and PDF mappings in sync without changing the DB schema.
enum WellVisitAgeGroup: String {
    case newborn     // hospital discharge / first weeks
    case infant      // roughly 1–12 months
    case toddler     // 12–24/30 months
    case preschool   // 30–36+ months
}

/// Map a `visit_type` ID (as stored in SQLite) into a broader age group.
/// Keeping this as a helper means both the SwiftUI form and
/// any report/PDF builder in this target can use the same mapping.
func ageGroupForVisitType(_ id: String) -> WellVisitAgeGroup {
    switch id {
    case "newborn_first", "one_month":
        return .newborn

    case "two_month", "four_month", "six_month", "nine_month", "twelve_month":
        return .infant

    case "fifteen_month", "eighteen_month", "twentyfour_month":
        return .toddler

    case "thirty_month", "thirtysix_month", "four_year", "five_year":
        return .preschool

    default:
        // Sensible fallback if new visit types are added but not yet mapped.
        return .infant
    }
}

/// Layout profile describing which major sections should be shown
/// for a given well visit. This will be reused by both the on‑screen
/// form and the PDF/report generator so they stay in sync.
struct WellVisitLayoutProfile {
    let showsFeeding: Bool
    let showsSupplementation: Bool
    let showsVitaminD: Bool
    let showsSleep: Bool
    let showsPhysicalExam: Bool
    let showsMilestones: Bool
    let showsProblemListing: Bool
    let showsConclusions: Bool
    let showsPlan: Bool
    let showsClinicianComment: Bool
    let showsNextVisit: Bool
    let showsAISection: Bool
}

/// Return the layout profile for a given age group.
func layoutProfile(for ageGroup: WellVisitAgeGroup) -> WellVisitLayoutProfile {
    switch ageGroup {
    case .newborn, .infant:
        return WellVisitLayoutProfile(
            showsFeeding: true,
            showsSupplementation: true,
            showsVitaminD: true,
            showsSleep: true,
            showsPhysicalExam: true,
            showsMilestones: true,
            showsProblemListing: true,
            showsConclusions: true,
            showsPlan: true,
            showsClinicianComment: true,
            showsNextVisit: true,
            showsAISection: true
        )
    case .toddler, .preschool:
        return WellVisitLayoutProfile(
            showsFeeding: true,
            showsSupplementation: false,
            showsVitaminD: true,
            showsSleep: true,
            showsPhysicalExam: true,
            showsMilestones: true,
            showsProblemListing: true,
            showsConclusions: true,
            showsPlan: true,
            showsClinicianComment: true,
            showsNextVisit: true,
            showsAISection: true
        )
    }
}

/// Convenience for mapping directly from visit_type ID.
func layoutProfile(forVisitType id: String) -> WellVisitLayoutProfile {
    layoutProfile(for: ageGroupForVisitType(id))
}

/// Helper used by report/PDF/DOCX builders to keep section visibility
/// in sync with the SwiftUI well‑visit form.
///
/// Call this from ReportBuilder (or any other reporting code) with the
/// `visit_type` string stored in SQLite. The returned `WellVisitLayoutProfile`
/// exposes booleans such as `showsFeeding`, `showsSleep`, `showsPhysicalExam`,
/// `showsMilestones`, etc., which can be used to decide which sections
/// to render in the exported report.
///
/// Example usage in a report builder:
///
///     let layout = reportLayoutProfile(forVisitType: visit.visitType)
///     if layout.showsFeeding {
///         appendFeedingSection(...)
///     }
///     if layout.showsSleep {
///         appendSleepSection(...)
///     }
///
/// Because this reuses the same `WellVisitAgeGroup` and `layoutProfile`
/// logic as the on‑screen form, any future changes to age‑group gating
/// will automatically apply to both UI and reports.
func reportLayoutProfile(forVisitType id: String) -> WellVisitLayoutProfile {
    return layoutProfile(forVisitType: id)
}

// MARK: - WellVisitForm

struct WellVisitForm: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var clinicianStore: ClinicianStore

    /// If nil → create new visit; non-nil → edit existing well_visit row.
    let editingVisitID: Int?
    
    // MARK: - Logging (UI)
    private static let uiLog = AppLog.ui
    private static let dbLog = AppLog.db

    // Core fields
    @State private var visitDate: Date = Date()
    @State private var visitTypeID: String = "newborn_first"

    // History & narrative sections
    @State private var parentsConcerns: String = ""

    // Legacy free-text feeding comment (used mainly for older visits)
    @State private var feeding: String = ""

    // Structured feeding fields for early visits (first-after-maternity, 1–4 months)
    @State private var milkTypeBreast: Bool = false
    @State private var milkTypeFormula: Bool = false
    @State private var feedVolumeMl: String = ""       // per feed, in mL
    @State private var feedFreqPer24h: String = ""     // feeds per 24h
    @State private var regurgitationPresent: Bool = false
    @State private var feedingIssue: String = ""       // brief description of any difficulty
    @State private var poopStatus: String = ""         // "normal", "abnormal", "hard"
    @State private var poopComment: String = ""        // optional details
    @State private var solidFoodStarted: Bool = false
    @State private var solidFoodStartDate: Date = Date()
    @State private var solidFoodQuality: String = ""
    @State private var solidFoodComment: String = ""
    @State private var foodVarietyQuality: String = ""
    @State private var dairyAmountCode: String = ""

    @State private var supplementation: String = ""
    @State private var vitaminDGiven: Bool = false

    // Sleep: structured fields for early visits + legacy free-text
    @State private var wakesForFeedsPerNight: String = ""   // e.g. "3"
    @State private var longerSleepAtNight: Bool = false
    @State private var sleepIssueReported: Bool = false
    @State private var sleep: String = ""                   // free-text issue / general comment

    // Additional structured sleep fields for older visits (12-month+)
    @State private var sleepHoursText: String = ""          // e.g. "lt10", "10_15"
    @State private var sleepRegular: String = ""            // e.g. "regular", "irregular"
    @State private var sleepSnoring: Bool = false           // snoring reported

    // Physical examination (structured + free text, stored in lab_text for now)
    @State private var peFontanelleNormal: Bool = true
    @State private var peFontanelleComment: String = ""
    @State private var pePupilsRRNormal: Bool = true
    @State private var pePupilsRRComment: String = ""
    @State private var peOcularMotilityNormal: Bool = true
    @State private var peOcularMotilityComment: String = ""
    @State private var peTrophicNormal: Bool = true
    @State private var peTrophicComment: String = ""
    @State private var peHydrationNormal: Bool = true
    @State private var peHydrationComment: String = ""
    @State private var peColor: String = "normal"       // normal, jaundice, pale
    @State private var peColorComment: String = ""

    @State private var peToneNormal: Bool = true
    @State private var peToneComment: String = ""
    @State private var peWakefulnessNormal: Bool = true
    @State private var peWakefulnessComment: String = ""
    @State private var peMoroNormal: Bool = true
    @State private var peMoroComment: String = ""
    @State private var peHandsFistNormal: Bool = true
    @State private var peHandsFistComment: String = ""
    @State private var peSymmetryNormal: Bool = true
    @State private var peSymmetryComment: String = ""
    @State private var peFollowsMidlineNormal: Bool = true
    @State private var peFollowsMidlineComment: String = ""

    @State private var peBreathingNormal: Bool = true
    @State private var peBreathingComment: String = ""
    @State private var peHeartNormal: Bool = true
    @State private var peHeartComment: String = ""

    @State private var peAbdomenNormal: Bool = true
    @State private var peAbdomenComment: String = ""
    @State private var peAbdMassPresent: Bool = false
    @State private var peGenitalia: String = ""
    @State private var peTesticlesDescended: Bool = true
    @State private var peFemoralPulsesNormal: Bool = true
    @State private var peFemoralPulsesComment: String = ""
    @State private var peLiverSpleenNormal: Bool = true
    @State private var peLiverSpleenComment: String = ""
    @State private var peUmbilicNormal: Bool = true
    @State private var peUmbilicComment: String = ""

    @State private var peSpineNormal: Bool = true
    @State private var peSpineComment: String = ""

    @State private var peHipsLimbsNormal: Bool = true
    @State private var peHipsLimbsComment: String = ""

    @State private var peSkinMarksNormal: Bool = true
    @State private var peSkinMarksComment: String = ""
    @State private var peSkinIntegrityNormal: Bool = true
    @State private var peSkinIntegrityComment: String = ""
    @State private var peSkinRashNormal: Bool = true
    @State private var peSkinRashComment: String = ""
    @State private var peTeethPresent: Bool = false
    @State private var peTeethCount: String = ""
    @State private var peTeethComment: String = ""

    @State private var physicalExam: String = ""

    // Neurodevelopment screening (Milestones & Development section)
    @State private var mchatScore: String = ""
    @State private var mchatResult: String = ""
    @State private var devTestScore: String = ""
    @State private var devTestResult: String = ""

    // Summary / plan
    @State private var problemListing: String = ""
    @State private var problemListingTokens: [ProblemToken] = []
    @State private var conclusions: String = ""
    @State private var plan: String = ""
    @State private var clinicianComment: String = ""

    // Next visit scheduling
    @State private var hasNextVisitDate: Bool = false
    @State private var nextVisitDate: Date = Date()

    // Placeholder for future AI content
    @State private var aiNotes: String = ""
    @State private var aiIsRunning = false
    // MARK: - Weight delta (early visits)
    @State private var latestWeightSummary: String = ""
    @State private var previousWeightSummary: String = ""
    @State private var deltaWeightPerDaySummary: String = ""
    @State private var deltaWeightPerDayValue: Int32? = nil
    @State private var deltaWeightIsNormal: Bool = false

    // MARK: - Growth snapshot (manual_growth) near visit
    @State private var growthAgeSummary: String = ""
    @State private var growthCurrentSummary: String = ""
    @State private var growthPreviousSummary: String = ""
    @State private var growthDeltaSummary: String = ""
    @State private var growthSnapshotIsLoading: Bool = false
    
    @State private var showErrorAlert: Bool = false
    @State private var saveErrorMessage: String = ""
    
    // MARK: - WHO growth evaluation (LMS / z-score)
    @State private var whoSex: WHOGrowthEvaluator.Sex? = nil
    @State private var growthWHOZSummary: String = ""
    @State private var growthWHOTrendSummary: String = ""
    @State private var growthWHOTrendIsFlagged: Bool = false

    /// We only show the weight-delta helper box for the first 3 well visits
    /// (1, 2 and 4-month visits).
    private var isWeightDeltaVisit: Bool {
        let earlyTypes: Set<String> = [
            "newborn_first",
            "one_month",
            "two_month"
        ]
        return earlyTypes.contains(visitTypeID)
    }

    /// Show WHO z-score + trend only from the 4-month visit onward.
    /// For earlier visits (newborn/1m/2m) we rely on absolute weight gain (g/day)
    /// and there are often too few points for meaningful WHO trend evaluation.
    private var showsWHOGrowthEvaluation: Bool {
        switch visitTypeID {
        case "four_month",
             "six_month",
             "nine_month",
             "twelve_month",
             "fifteen_month",
             "eighteen_month",
             "twentyfour_month",
             "thirty_month",
             "thirtysix_month",
             "four_year",
             "five_year":
            return true
        default:
            return false
        }
    }

    // Milestone state: per-code status + optional note
    @State private var milestoneStatuses: [String: MilestoneStatus] = [:]
    @State private var milestoneNotes: [String: String] = [:]

    

    // MARK: - Addenda (well visits)
    @State private var wellAddenda: [WellVisitAddendum] = []
    @State private var addendaAreLoading: Bool = false
    @State private var addendaErrorMessage: String? = nil
    @State private var newWellAddendumText: String = ""

    // Date formatter (yyyy-MM-dd)
    private static let isoDateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    // MARK: - Growth snapshot helpers (manual_growth)

    private struct GrowthPoint {
        let recordedAtRaw: String
        let recordedDate: Date
        let weightKg: Double?
        let heightCm: Double?
        let headCircCm: Double?
    }

    private func fmt(_ v: Double?, decimals: Int) -> String {
        guard let v else { return "—" }
        return String(format: "%0.*f", decimals, v)
    }

    /// Best-effort DOB fetch (YYYY-MM-DD or ISO8601) from patients table.
    private func fetchDOB(dbURL: URL, patientID: Int) -> Date? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else { return nil }
        defer { sqlite3_close(db) }

        func runDOBQuery(_ column: String) -> String? {
            let sql = "SELECT \(column) FROM patients WHERE id = ? LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: cStr)
        }

        let raw = runDOBQuery("dob") ?? runDOBQuery("date_of_birth")
        let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        let prefix10 = String(t.prefix(10))
        if let d = Self.isoDateOnly.date(from: prefix10) { return d }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: t) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: t) { return d }

        return nil
    }
    
    /// Best-effort patient sex fetch from patients table.
    /// Returns WHO evaluator sex if we can parse it.
    private func fetchWHOSex(dbURL: URL, patientID: Int) -> WHOGrowthEvaluator.Sex? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else { return nil }
        defer { sqlite3_close(db) }

        let sql = "SELECT sex FROM patients WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        let raw = String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
        return parseWHOSex(raw)
    }

    private func parseWHOSex(_ raw: String) -> WHOGrowthEvaluator.Sex? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let u = t.uppercased()

        if u == "M" || u == "MALE" || u == "BOY" || u == "GARCON" || u == "G" { return .male }
        if u == "F" || u == "FEMALE" || u == "GIRL" || u == "FILLE" { return .female }
        return nil
    }

    private func ageMonths(dob: Date, at date: Date) -> Double {
        let days = Calendar.current.dateComponents([.day], from: dob, to: date).day ?? 0
        return Double(max(0, days)) / 30.4375
    }

    private func bmiKgM2(weightKg: Double, heightCm: Double) -> Double? {
        guard weightKg.isFinite, weightKg > 0 else { return nil }
        guard heightCm.isFinite, heightCm > 0 else { return nil }
        let hm = heightCm / 100.0
        guard hm > 0 else { return nil }
        return weightKg / (hm * hm)
    }

    private func computeAgeSummary(dob: Date, visit: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: dob, to: visit).day ?? 0
        let safeDays = max(0, days)
        let months = Double(safeDays) / 30.4375
        // Keep it clinician-friendly: days + approx months
        return String(
            format: L10nWVF.s("well_visit_form.growth_snapshot.age_at_visit"),
            String(safeDays),
            String(format: "%.1f", months)
        )
    }

    /// Fetch recent manual_growth points around the visit date (ASC for readability).
    private func fetchGrowthPoints(
        dbURL: URL,
        patientID: Int,
        lookbackDays: Int = 365,
        forwardDays: Int = 3,
        limit: Int = 12
    ) -> [GrowthPoint] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else { return [] }
        defer { sqlite3_close(db) }

        let visitISO = Self.isoDateOnly.string(from: visitDate)
        let lowerMod = "-\(lookbackDays) day"
        let upperMod = "+\(forwardDays) day"

        let sql = """
        SELECT recorded_at, weight_kg, height_cm, head_circumference_cm
        FROM manual_growth
        WHERE patient_id = ?
          AND COALESCE(source,'manual') NOT LIKE 'vitals%'
          AND date(recorded_at) >= date(?, ?)
          AND date(recorded_at) <= date(?, ?)
        ORDER BY datetime(recorded_at) ASC
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))
        _ = visitISO.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
        _ = lowerMod.withCString { sqlite3_bind_text(stmt, 3, $0, -1, SQLITE_TRANSIENT) }
        _ = visitISO.withCString { sqlite3_bind_text(stmt, 4, $0, -1, SQLITE_TRANSIENT) }
        _ = upperMod.withCString { sqlite3_bind_text(stmt, 5, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 6, Int32(limit))

        func colDoubleOrNil(_ idx: Int32) -> Double? {
            if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return nil }
            return sqlite3_column_double(stmt, idx)
        }

        var out: [GrowthPoint] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let recordedAt: String = {
                guard let cStr = sqlite3_column_text(stmt, 0) else { return "" }
                return String(cString: cStr)
            }()
            let raw = recordedAt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }

            // Parse date best-effort: date-only or datetime.
            let dateOnly = String(raw.prefix(10))
            let recordedDate: Date? = Self.isoDateOnly.date(from: dateOnly)
                ?? iso.date(from: raw)
                ?? {
                    iso.formatOptions = [.withInternetDateTime]
                    return iso.date(from: raw)
                }()

            guard let rd = recordedDate else { continue }

            let w = colDoubleOrNil(1)
            let h = colDoubleOrNil(2)
            let hc = colDoubleOrNil(3)
            if w == nil && h == nil && hc == nil { continue }

            out.append(GrowthPoint(recordedAtRaw: raw, recordedDate: rd, weightKg: w, heightCm: h, headCircCm: hc))
        }

        return out
    }

    /// Pick the best “current” point: closest within ±3 days of visit date; else latest on/before visit.
    private func selectCurrentGrowthPoint(_ points: [GrowthPoint]) -> GrowthPoint? {
        guard !points.isEmpty else { return nil }

        let visitDay = Calendar.current.startOfDay(for: visitDate)
        let windowDays = 3

        // 1) Closest within ±3 days
        let withDiff: [(GrowthPoint, Int)] = points.map { p in
            let d0 = Calendar.current.startOfDay(for: p.recordedDate)
            let diff = Calendar.current.dateComponents([.day], from: d0, to: visitDay).day ?? 0
            return (p, abs(diff))
        }

        if let best = withDiff
            .filter({ $0.1 <= windowDays })
            .sorted(by: { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                return a.0.recordedDate > b.0.recordedDate
            })
            .first?.0 {
            return best
        }

        // 2) Fallback: latest on/before visit
        return points
            .filter { $0.recordedDate <= visitDate }
            .sorted(by: { $0.recordedDate > $1.recordedDate })
            .first
    }

    private func buildGrowthSummaryLine(labelKey: String, _ p: GrowthPoint) -> String {
        return String(
            format: L10nWVF.s(labelKey),
            p.recordedAtRaw,
            fmt(p.weightKg, decimals: 2),
            fmt(p.heightCm, decimals: 1),
            fmt(p.headCircCm, decimals: 1)
        )
    }

    private func buildGrowthDeltaLine(current: GrowthPoint, previous: GrowthPoint) -> String {
        func d(_ a: Double?, _ b: Double?, decimals: Int) -> String {
            guard let a, let b else { return "—" }
            return String(format: "%0.*f", decimals, (a - b))
        }
        let dayDelta = max(1, Calendar.current.dateComponents([.day], from: previous.recordedDate, to: current.recordedDate).day ?? 1)
        let dw = (current.weightKg != nil && previous.weightKg != nil) ? ((current.weightKg! - previous.weightKg!) * 1000.0 / Double(dayDelta)) : nil

        let dwPerDay = dw == nil ? "—" : String(format: "%.0f", dw!)

        return String(
            format: L10nWVF.s("well_visit_form.growth_snapshot.delta"),
            d(current.weightKg, previous.weightKg, decimals: 2),
            d(current.heightCm, previous.heightCm, decimals: 1),
            d(current.headCircCm, previous.headCircCm, decimals: 1),
            dwPerDay
        )
    }

    private func refreshGrowthSnapshotCard() {
        guard let dbURL = appState.currentDBURL,
              let patientID = appState.selectedPatientID else {
            growthAgeSummary = ""
            growthCurrentSummary = ""
            growthPreviousSummary = ""
            growthDeltaSummary = ""
            growthWHOZSummary = ""
            growthWHOTrendSummary = ""
            growthWHOTrendIsFlagged = false
            return
        }

        growthSnapshotIsLoading = true
        let includeWHO = self.showsWHOGrowthEvaluation

        DispatchQueue.global(qos: .userInitiated).async {
            let points = fetchGrowthPoints(dbURL: dbURL, patientID: patientID)
            let current = selectCurrentGrowthPoint(points)

            // previous point = last point strictly before the current point
            let previous: GrowthPoint? = {
                guard let current else { return nil }
                return points
                    .filter { $0.recordedDate < current.recordedDate }
                    .sorted(by: { $0.recordedDate > $1.recordedDate })
                    .first
            }()

            let dob = fetchDOB(dbURL: dbURL, patientID: patientID)
            
            let sex = fetchWHOSex(dbURL: dbURL, patientID: patientID)

            // Build WHO z-score + trend summaries (best-effort)
            var whoZLines: [String] = []
            var whoTrendLines: [String] = []
            var whoTrendIsFlagged = false

            if includeWHO, let dob, let sex, let current {
                func buildPrior(_ extract: (GrowthPoint) -> Double?) -> [(ageMonths: Double, value: Double)] {
                    let priors = points
                        .filter { $0.recordedDate < current.recordedDate }
                        .sorted(by: { $0.recordedDate < $1.recordedDate })
                        .compactMap { p -> (Double, Double)? in
                            guard let v = extract(p) else { return nil }
                            return (ageMonths(dob: dob, at: p.recordedDate), v)
                        }
                    return priors.map { (ageMonths: $0.0, value: $0.1) }
                }

                let currentAgeM = ageMonths(dob: dob, at: current.recordedDate)

                do {
                    let wfaLabel   = WHOGrowthEvaluator.Kind.wfa.displayName()
                    let lhfaLabel  = WHOGrowthEvaluator.Kind.lhfa.displayName()
                    let hcfaLabel  = WHOGrowthEvaluator.Kind.hcfa.displayName()
                    let bmifaLabel = WHOGrowthEvaluator.Kind.bmifa.displayName()
                    
                    if let w = current.weightKg {
                        let r = try WHOGrowthEvaluator.evaluate(kind: .wfa, sex: sex, ageMonths: currentAgeM, value: w)
                        whoZLines.append(wfaLabel + " z=" + String(format: "%.2f", r.zScore) + " P" + String(format: "%.0f", r.percentile))

                        let prior = buildPrior { $0.weightKg }
                        let t = try WHOGrowthEvaluator.assessTrendLastN(kind: .wfa, sex: sex, prior: prior,
                                                                       current: (ageMonths: currentAgeM, value: w),
                                                                       lastN: 10, thresholdZ: 1.0)
                        if t.priorCount > 0 {
                            whoTrendLines.append(wfaLabel + ": " + t.narrative)
                            if t.isSignificantShift
                                    || abs(t.current.zScore) >= 2.0
                                    || t.current.percentile <= 3.0
                                    || t.current.percentile >= 97.0 {
                                    whoTrendIsFlagged = true
                                }
                        }
                    }

                    if let h = current.heightCm {
                        let r = try WHOGrowthEvaluator.evaluate(kind: .lhfa, sex: sex, ageMonths: currentAgeM, value: h)
                        whoZLines.append(lhfaLabel + " z=" + String(format: "%.2f", r.zScore) + " P" + String(format: "%.0f", r.percentile))

                        let prior = buildPrior { $0.heightCm }
                        let t = try WHOGrowthEvaluator.assessTrendLastN(kind: .lhfa, sex: sex, prior: prior,
                                                                       current: (ageMonths: currentAgeM, value: h),
                                                                       lastN: 10, thresholdZ: 1.0)
                        if t.priorCount > 0 {
                            whoTrendLines.append(lhfaLabel + ": " + t.narrative)
                            if t.isSignificantShift
                                    || abs(t.current.zScore) >= 2.0
                                    || t.current.percentile <= 3.0
                                    || t.current.percentile >= 97.0 {
                                    whoTrendIsFlagged = true
                                }
                        }
                    }

                    if let hc = current.headCircCm {
                        let r = try WHOGrowthEvaluator.evaluate(kind: .hcfa, sex: sex, ageMonths: currentAgeM, value: hc)
                        whoZLines.append(hcfaLabel + " z=" + String(format: "%.2f", r.zScore) + " P" + String(format: "%.0f", r.percentile))

                        let prior = buildPrior { $0.headCircCm }
                        let t = try WHOGrowthEvaluator.assessTrendLastN(kind: .hcfa, sex: sex, prior: prior,
                                                                       current: (ageMonths: currentAgeM, value: hc),
                                                                       lastN: 10, thresholdZ: 1.0)
                        if t.priorCount > 0 {
                            whoTrendLines.append(hcfaLabel + ": " + t.narrative)
                            if t.isSignificantShift
                                    || abs(t.current.zScore) >= 2.0
                                    || t.current.percentile <= 3.0
                                    || t.current.percentile >= 97.0 {
                                    whoTrendIsFlagged = true
                                }
                        }
                    }

                    if let w = current.weightKg, let h = current.heightCm, let bmi = bmiKgM2(weightKg: w, heightCm: h) {
                        let r = try WHOGrowthEvaluator.evaluate(kind: .bmifa, sex: sex, ageMonths: currentAgeM, value: bmi)
                        whoZLines.append(bmifaLabel + " z=" + String(format: "%.2f", r.zScore) + " P" + String(format: "%.0f", r.percentile))

                        let prior = points
                            .filter { $0.recordedDate < current.recordedDate }
                            .sorted(by: { $0.recordedDate < $1.recordedDate })
                            .compactMap { p -> (ageMonths: Double, value: Double)? in
                                guard let pw = p.weightKg, let ph = p.heightCm,
                                      let pbmi = bmiKgM2(weightKg: pw, heightCm: ph) else { return nil }
                                return (ageMonths(dob: dob, at: p.recordedDate), pbmi)
                            }

                        let t = try WHOGrowthEvaluator.assessTrendLastN(kind: .bmifa, sex: sex, prior: prior,
                                                                       current: (ageMonths: currentAgeM, value: bmi),
                                                                       lastN: 10, thresholdZ: 1.0)
                        if t.priorCount > 0 {
                            whoTrendLines.append(bmifaLabel + ": " + t.narrative)
                            if t.isSignificantShift
                            || abs(t.current.zScore) >= 2.0
                            || t.current.percentile <= 3.0
                            || t.current.percentile >= 97.0 {
                            whoTrendIsFlagged = true
                            }
                        }
                    }
                } catch {
                    whoZLines = []
                    whoTrendLines = ["WHO evaluation failed: \(error.localizedDescription)"]
                    whoTrendIsFlagged = false
                }
            }

            DispatchQueue.main.async {
                if let dob {
                    self.growthAgeSummary = computeAgeSummary(dob: dob, visit: self.visitDate)
                } else {
                    self.growthAgeSummary = String(
                        format: L10nWVF.s("well_visit_form.growth_snapshot.age_at_visit"),
                        "—",
                        "—"
                    )
                }

                if let current {
                    self.growthCurrentSummary = buildGrowthSummaryLine(
                        labelKey: "well_visit_form.growth_snapshot.near_visit",
                        current
                    )
                } else {
                    self.growthCurrentSummary = String(
                        format: L10nWVF.s("well_visit_form.growth_snapshot.near_visit"),
                        "—", "—", "—", "—"
                    )
                }

                if let previous {
                    self.growthPreviousSummary = buildGrowthSummaryLine(
                        labelKey: "well_visit_form.growth_snapshot.previous",
                        previous
                    )
                } else {
                    self.growthPreviousSummary = String(
                        format: L10nWVF.s("well_visit_form.growth_snapshot.previous"),
                        "—", "—", "—", "—"
                    )
                }

                if let current, let previous {
                    self.growthDeltaSummary = buildGrowthDeltaLine(current: current, previous: previous)
                } else {
                    self.growthDeltaSummary = ""
                }

                self.whoSex = sex

                self.growthWHOZSummary = whoZLines.isEmpty
                    ? ""
                    : String(
                        format: L10nWVF.s("well_visit_form.growth_snapshot.who_zscores"),
                        whoZLines.joined(separator: " · ")
                    )

                self.growthWHOTrendSummary = whoTrendLines.isEmpty
                    ? ""
                    : {
                        let title = L10nWVF.s("well_visit_form.growth_snapshot.trend_title")
                        return title + "\n" + whoTrendLines.joined(separator: "\n")
                    }()

                self.growthWHOTrendIsFlagged = whoTrendIsFlagged

                self.growthSnapshotIsLoading = false
            }
        }
    }

    private var visitTypes: [WellVisitType] { WELL_VISIT_TYPES }

    private var currentMilestoneDescriptors: [MilestoneDescriptor] {
        WELL_VISIT_MILESTONES[visitTypeID] ?? []
    }

    private var currentAgeGroup: WellVisitAgeGroup {
        ageGroupForVisitType(visitTypeID)
    }

    private var layout: WellVisitLayoutProfile {
        layoutProfile(for: currentAgeGroup)
    }


    private var showsVitaminDField: Bool {
        layout.showsVitaminD
    }

    private var showsAISection: Bool {
        layout.showsAISection
    }

    private var isSolidsVisit: Bool {
        // Solid-food infancy block only for 4-, 6- and 9-month visits
        visitTypeID == "four_month"
        || visitTypeID == "six_month"
        || visitTypeID == "nine_month"
    }
    
    private var isStructuredFeedingUnder12: Bool {
        // Structured feeding (milk checkboxes, volumes, etc.) from newborn to 9-month visits
        visitTypeID == "newborn_first"
        || visitTypeID == "one_month"
        || visitTypeID == "two_month"
        || visitTypeID == "four_month"
        || visitTypeID == "six_month"
        || visitTypeID == "nine_month"
    }

    private var isOlderFeedingVisit: Bool {
        // Excel: food_variety_quality + dairy_amount_text at 12–36 months
        visitTypeID == "twelve_month"
        || visitTypeID == "fifteen_month"
        || visitTypeID == "eighteen_month"
        || visitTypeID == "twentyfour_month"
        || visitTypeID == "thirty_month"
        || visitTypeID == "thirtysix_month"
    }

    private var isEarlySleepVisit: Bool {
        // Structured sleep fields for early visits per Excel:
        // first-after-maternity, 1-month, 2-month, 4-month, 6-month, 9-month
        visitTypeID == "newborn_first"
        || visitTypeID == "one_month"
        || visitTypeID == "two_month"
        || visitTypeID == "four_month"
        || visitTypeID == "six_month"
        || visitTypeID == "nine_month"
    }

    private var isOlderSleepVisit: Bool {
        // Structured sleep fields for older visits per Excel:
        // 12-month, 15-month, 18-month, 24-mo, 30-month, 36-month
        visitTypeID == "twelve_month"
        || visitTypeID == "fifteen_month"
        || visitTypeID == "eighteen_month"
        || visitTypeID == "twentyfour_month"
        || visitTypeID == "thirty_month"
        || visitTypeID == "thirtysix_month"
    }

    private var isFontanelleVisit: Bool {
        // Fontanelle relevant up to 24-month visits (exclude preschool ages)
        currentAgeGroup != .preschool
    }

    private var isPrimitiveNeuroVisit: Bool {
        // Early neurologic primitives (hands in fists, symmetry, follows midline, wakefulness)
        // first-after-maternity, 1-month, 2-month
        visitTypeID == "newborn_first"
        || visitTypeID == "one_month"
        || visitTypeID == "two_month"
    }

    private var isMoroVisit: Bool {
        // Moro reflex relevant up to 6-month visit
        visitTypeID == "newborn_first"
        || visitTypeID == "one_month"
        || visitTypeID == "two_month"
        || visitTypeID == "four_month"
        || visitTypeID == "six_month"
    }

    private var isHipsVisit: Bool {
        // Hips / limbs / posture explicitly focused in the first 6 months
        visitTypeID == "newborn_first"
        || visitTypeID == "one_month"
        || visitTypeID == "two_month"
        || visitTypeID == "four_month"
        || visitTypeID == "six_month"
    }

    private var isMCHATVisit: Bool {
        // Excel: mchat_score/result at 18-month, 24-mo, 30-month
        visitTypeID == "eighteen_month"
        || visitTypeID == "twentyfour_month"
        || visitTypeID == "thirty_month"
    }

    private var isDevTestScoreVisit: Bool {
        // Excel: devtest_score at 9-month, 12-month, 15-month, 18-month, 24-mo, 30-month, 36-month
        visitTypeID == "nine_month"
        || visitTypeID == "twelve_month"
        || visitTypeID == "fifteen_month"
        || visitTypeID == "eighteen_month"
        || visitTypeID == "twentyfour_month"
        || visitTypeID == "thirty_month"
        || visitTypeID == "thirtysix_month"
    }

    private var isDevTestResultVisit: Bool {
        // Excel: devtest_result at 9-month, 12-month, 15-month, 18-month, 24-mo, 30-month, 36-month
        visitTypeID == "nine_month"
        || visitTypeID == "twelve_month"
        || visitTypeID == "fifteen_month"
        || visitTypeID == "eighteen_month"
        || visitTypeID == "twentyfour_month"
        || visitTypeID == "thirty_month"
        || visitTypeID == "thirtysix_month"
    }

        @ViewBuilder
        private var solidsSection: some View {
            Text(L10nWVF.k("well_visit_form.solids.title"))
                .font(.subheadline.bold())

            Toggle(L10nWVF.k("well_visit_form.solids.started"), isOn: $solidFoodStarted)

            if solidFoodStarted {
                DatePicker(
                    L10nWVF.k("well_visit_form.solids.start_date"),
                    selection: $solidFoodStartDate,
                    displayedComponents: .date
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10nWVF.k("well_visit_form.solids.intake"))
                        .font(.subheadline)
                    Picker(L10nWVF.k("well_visit_form.solids.quality"), selection: $solidFoodQuality) {
                        Text(L10nWVF.k("well_visit_form.shared.appears_good")).tag("appears_good")
                        Text(L10nWVF.k("well_visit_form.shared.uncertain")).tag("uncertain")
                        Text(L10nWVF.k("well_visit_form.shared.probably_limited")).tag("probably_limited")
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10nWVF.k("well_visit_form.solids.comment.label"))
                            .font(.subheadline)
                        TextEditor(text: $solidFoodComment)
                            .frame(minHeight: 80)
                    }
                }
            }
        }

    @ViewBuilder
    private var olderFeedingSection: some View {
        Text(L10nWVF.k("well_visit_form.feeding_older.title"))
            .font(.subheadline.bold())

        VStack(alignment: .leading, spacing: 8) {
            Text(L10nWVF.k("well_visit_form.feeding_older.food_variety_quality.label"))
                .font(.subheadline)
            Picker(L10nWVF.k("well_visit_form.feeding_older.food_variety_quality.picker"), selection: $foodVarietyQuality) {
                Text(L10nWVF.k("well_visit_form.shared.appears_good")).tag("appears_good")
                Text(L10nWVF.k("well_visit_form.shared.uncertain")).tag("uncertain")
                Text(L10nWVF.k("well_visit_form.shared.probably_limited")).tag("probably_limited")
            }
            .pickerStyle(.segmented)
        }

        VStack(alignment: .leading, spacing: 8) {
            Text(L10nWVF.k("well_visit_form.feeding_older.dairy_intake.label"))
                .font(.subheadline)
            Picker(L10nWVF.k("well_visit_form.feeding_older.dairy_intake.picker"), selection: $dairyAmountCode) {
                Text(L10nWVF.k("well_visit_form.feeding_older.dairy_intake.1")).tag("1")
                Text(L10nWVF.k("well_visit_form.feeding_older.dairy_intake.2")).tag("2")
                Text(L10nWVF.k("well_visit_form.feeding_older.dairy_intake.3")).tag("3")
                Text(L10nWVF.k("well_visit_form.feeding_older.dairy_intake.4")).tag("4")
            }
            .pickerStyle(.segmented)
        }

        VStack(alignment: .leading, spacing: 8) {
            Toggle(L10nWVF.k("well_visit_form.feeding_older.still_breastfeeding"), isOn: $milkTypeBreast)
                .toggleStyle(.switch)
        }
    }
    
    @ViewBuilder
    private var aiAssistantSection: some View {
        GroupBox(L10nWVF.k("well_visit_form.ai.title")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        triggerAIForWellVisit()
                    } label: {
                        Label(L10nWVF.k("well_visit_form.ai.run"), systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)

                    if aiIsRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                let entries = currentAIEntriesForVisit

                if entries.isEmpty {
                    Text(L10nWVF.k("well_visit_form.ai.empty_state"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries, id: \.key) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.key)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextEditor(text: .constant(entry.value))
                                .frame(minHeight: 140)
                                .disabled(true)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.secondary.opacity(0.3))
                                )
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .padding(.top, 4)
        }
        .groupBoxStyle(PlainGroupBoxStyle())
        .padding(12)
        .lightBlueSectionCardStyle()
    }
    
    private var isEarlyMilkOnlyVisit: Bool {
        // First-after-maternity + 1-month + 2-month use the structured milk-only feeding view
        visitTypeID == "newborn_first"
        || visitTypeID == "one_month"
        || visitTypeID == "two_month"
    }

    private var estimatedTotalIntakeMlPer24h: String {
        guard let volume = Double(feedVolumeMl),
              let freq = Double(feedFreqPer24h),
              volume > 0, freq > 0 else {
            return "–"
        }
        let total = volume * freq
        return String(format: "%.0f ml / 24h", total)
    }
    
    /// Normalize any legacy stored values to the canonical codes used by the Picker tags.
    private func normalizeQualityCode(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }

        let lower = t.lowercased()
        switch lower {
        case "appears_good", "appears good", "appears-good":
            return "appears_good"
        case "uncertain":
            return "uncertain"
        case "probably_limited", "probably limited", "probably-limited":
            return "probably_limited"
        default:
            return lower.replacingOccurrences(of: " ", with: "_")
        }
    }


// MARK: - Addenda helpers (well visits)

    private func loadWellAddenda() {
        guard let wid = editingVisitID else { return }
        guard let dbURL = appState.currentDBURL else {
            addendaErrorMessage = L10nWVF.s("well_visit_form.addenda.db_missing_error")
            return
        }

        addendaAreLoading = true
        addendaErrorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let store = WellVisitStore()
                let rows = try store.fetchAddendaForWellVisit(dbURL: dbURL, wellVisitID: Int64(wid))
                DispatchQueue.main.async {
                    self.wellAddenda = rows
                    self.addendaAreLoading = false
                    
                }
            } catch {
                DispatchQueue.main.async {
                    self.addendaAreLoading = false
                    self.addendaErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func addWellAddendumTapped() {
        guard let wid = editingVisitID else { return }
        let trimmed = newWellAddendumText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let dbURL = appState.currentDBURL else {
            addendaErrorMessage = L10nWVF.s("well_visit_form.addenda.db_missing_error")
            return
        }

        let uid: Int64? = appState.activeUserID.map(Int64.init)

        addendaAreLoading = true
        addendaErrorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let store = WellVisitStore()
                _ = try store.insertAddendumForWellVisit(
                    dbURL: dbURL,
                    wellVisitID: Int64(wid),
                    userID: uid,
                    text: trimmed
                )
                DispatchQueue.main.async {
                    self.newWellAddendumText = ""
                    self.addendaAreLoading = false
                    self.loadWellAddenda()
                }
            } catch {
                DispatchQueue.main.async {
                    self.addendaAreLoading = false
                    self.addendaErrorMessage = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private var wellAddendaSection: some View {
        GroupBox(L10nWVF.k("well_visit_form.addenda.title")) {
            VStack(alignment: .leading, spacing: 12) {

                if editingVisitID == nil {
                    Text(L10nWVF.k("well_visit_form.addenda.save_visit_first_hint"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    if let err = addendaErrorMessage, !err.isEmpty {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack {
                        Button {
                            loadWellAddenda()
                        } label: {
                            Label(L10nWVF.k("well_visit_form.addenda.refresh"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        if addendaAreLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    if wellAddenda.isEmpty {
                        Text(L10nWVF.k("well_visit_form.addenda.empty"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(wellAddenda) { a in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(a.createdAtISO ?? L10nWVF.s("well_visit_form.addenda.time_na"))
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }

                                    Text(a.text)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                }
                                .padding(8)
                                .background(Color.gray.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }

                    Divider().padding(.vertical, 4)

                    Text(L10nWVF.k("well_visit_form.addenda.new.title"))
                        .font(.subheadline.bold())

                    ZStack(alignment: .topLeading) {
                        if newWellAddendumText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(L10nWVF.k("well_visit_form.addenda.new.placeholder"))
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 6)
                        }

                        TextEditor(text: $newWellAddendumText)
                            .frame(minHeight: 90)
                            .padding(.horizontal, 2)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25))
                    )

                    HStack {
                        Spacer()
                        Button {
                            addWellAddendumTapped()
                        } label: {
                            Label(L10nWVF.k("well_visit_form.addenda.add"), systemImage: "plus.bubble")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newWellAddendumText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || addendaAreLoading)
                    }
                }
            }
            .padding(.top, 4)
        }
        .groupBoxStyle(PlainGroupBoxStyle())
        .padding(12)
        .lightBlueSectionCardStyle()
    }

    init(editingVisitID: Int? = nil) {
        self.editingVisitID = editingVisitID
    }

   

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Color.clear
                        .onAppear {
                            // Only meaningful when editing an existing visit
                            if editingVisitID != nil {
                                loadWellAddenda()
                            }
                        }
                    // Visit info
                    GroupBox(L10nWVF.k("well_visit_form.section.visit_info.title")) {
                        VStack(alignment: .leading, spacing: 12) {
                            DatePicker(
                                L10nWVF.k("well_visit_form.section.visit_info.date"),
                                selection: $visitDate,
                                displayedComponents: .date
                            )

                            Picker(L10nWVF.k("well_visit_form.section.visit_info.type"), selection: $visitTypeID) {
                                ForEach(visitTypes) { t in
                                    Text(t.title).tag(t.id)
                                }
                            }
                            .frame(maxWidth: 400, alignment: .leading)
                        }
                        .padding(.top, 4)
                    }
                    .groupBoxStyle(PlainGroupBoxStyle())
                    .padding(12)
                    .lightBlueSectionCardStyle()
                    
                    if isWeightDeltaVisit {
                        GroupBox(L10nWVF.k("well_visit_form.weight_trend.title")) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(
                                    latestWeightSummary.isEmpty
                                    ? L10nWVF.s("well_visit_form.weight_trend.latest_weight.unavailable")
                                    : String(
                                        format: L10nWVF.s("well_visit_form.weight_trend.latest_weight.value"),
                                        latestWeightSummary
                                    )
                                )
                                .font(.subheadline)

                                if !previousWeightSummary.isEmpty {
                                    Text(String(format: L10nWVF.s("well_visit_form.weight_trend.previous_weight.value"), previousWeightSummary))
                                        .font(.subheadline)
                                } else {
                                    Text(L10nWVF.k("well_visit_form.weight_trend.previous_weight.unavailable"))
                                        .font(.subheadline)
                                }

                                HStack {
                                    Text(
                                        deltaWeightPerDaySummary.isEmpty
                                        ? L10nWVF.s("well_visit_form.weight_trend.delta.unavailable")
                                        : deltaWeightPerDaySummary
                                    )
                                    .font(.subheadline)

                                    Spacer()

                                    if let delta = deltaWeightPerDayValue,
                                       delta >= 20,
                                       deltaWeightIsNormal {
                                        Label(L10nWVF.k("well_visit_form.weight_trend.ok"), systemImage: "checkmark.circle.fill")
                                            .font(.subheadline)
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                        }
                        .groupBoxStyle(PlainGroupBoxStyle())
                        .padding(12)
                        .lightBlueSectionCardStyle()
                    }

                    // Growth snapshot near visit (manual_growth)
                    GroupBox(L10nWVF.k("well_visit_form.growth_snapshot.title")) {
                        VStack(alignment: .leading, spacing: 6) {
                            if !growthAgeSummary.isEmpty {
                                Text(growthAgeSummary)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Text(growthCurrentSummary)
                                .font(.subheadline)

                            if !growthPreviousSummary.isEmpty {
                                Text(growthPreviousSummary)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            if !growthDeltaSummary.isEmpty {
                                Text(growthDeltaSummary)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            
                            if showsWHOGrowthEvaluation {
                                if !growthWHOZSummary.isEmpty {
                                    Text(growthWHOZSummary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 4)
                                }

                                if !growthWHOTrendSummary.isEmpty {
                                    if growthWHOTrendIsFlagged {
                                        Label(L10nWVF.k("well_visit_form.growth_trend.flag"), systemImage: "exclamationmark.triangle.fill")
                                            .font(.footnote.bold())
                                            .foregroundStyle(.orange)
                                            .padding(.top, 2)
                                    }

                                    Text(growthWHOTrendSummary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if growthSnapshotIsLoading {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .onAppear {
                            refreshGrowthSnapshotCard()
                        }
                        .onChange(of: visitDate) { _, _ in
                            refreshGrowthSnapshotCard()
                        }
                        .onChange(of: visitTypeID) { _, _ in
                            refreshGrowthSnapshotCard()
                        }
                        .onChange(of: appState.selectedPatientID) { _, _ in
                            refreshGrowthSnapshotCard()
                        }
                    }
                    .groupBoxStyle(PlainGroupBoxStyle())
                    .padding(12)
                    .lightBlueSectionCardStyle()

                    // Parent's concerns  → parent_concerns
                    GroupBox(L10nWVF.k("well_visit_form.section.parents_concerns.title")) {
                        TextEditor(text: $parentsConcerns)
                            .frame(minHeight: 120)
                    }
                    .groupBoxStyle(PlainGroupBoxStyle())
                    .padding(12)
                    .lightBlueSectionCardStyle()

                    // Feeding + Supplementation + Vitamin D
                    if layout.showsFeeding {
                        GroupBox(L10nWVF.k("well_visit_form.section.feeding.title")) {
                            VStack(alignment: .leading, spacing: 12) {

                                if isStructuredFeedingUnder12 {
                                    // NEWBORN → 9-month visits:
                                    // milk checkboxes, volumes, regurgitation, one issues text, ±solids, Vit D
                                    Text(L10nWVF.k("well_visit_form.feeding.milk_type.title"))
                                        .font(.subheadline.bold())

                                    HStack {
                                        Toggle(L10nWVF.k("well_visit_form.feeding.milk_type.breastmilk"), isOn: $milkTypeBreast)
                                        Toggle(L10nWVF.k("well_visit_form.feeding.milk_type.formula"), isOn: $milkTypeFormula)
                                    }

                                    HStack(spacing: 16) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(L10nWVF.k("well_visit_form.feeding.volume_per_feed.label"))
                                                .font(.subheadline)
                                            TextField(L10nWVF.k("well_visit_form.feeding.volume_per_feed.placeholder"), text: $feedVolumeMl)
                                                .frame(width: 80)
                                                .textFieldStyle(.roundedBorder)
                                        }

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(L10nWVF.k("well_visit_form.feeding.feeds_per_24h.label"))
                                                .font(.subheadline)
                                            TextField(L10nWVF.k("well_visit_form.feeding.feeds_per_24h.placeholder"), text: $feedFreqPer24h)
                                                .frame(width: 80)
                                                .textFieldStyle(.roundedBorder)
                                        }
                                    }

                                    if estimatedTotalIntakeMlPer24h != "–" {
                                        Text(String(format: L10nWVF.s("well_visit_form.feeding.estimated_intake.value"), estimatedTotalIntakeMlPer24h))
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }

                                    Toggle(L10nWVF.k("well_visit_form.feeding.regurgitation.toggle"), isOn: $regurgitationPresent)

                                    Text(L10nWVF.k("well_visit_form.feeding.issues.title"))
                                        .font(.subheadline.bold())
                                    TextEditor(text: $feedingIssue)
                                        .frame(minHeight: 80)

                                    // Solid foods only for 4, 6, 9-month visits,
                                    // using the shared solidsSection WITHOUT its own comment box
                                    if isSolidsVisit {
                                        Divider()
                                            .padding(.vertical, 4)
                                        solidsSection
                                    }

                                    if showsVitaminDField {
                                        Toggle(L10nWVF.k("well_visit_form.feeding.vitamin_d.toggle"), isOn: $vitaminDGiven)
                                    }

                                } else {
                                    // 12–36-month visits:
                                    // food variety / dairy intake, breastfeeding, ONE issues text, Vit D
                                    olderFeedingSection

                                    Text(L10nWVF.k("well_visit_form.feeding.issues.title"))
                                        .font(.subheadline.bold())
                                    TextEditor(text: $feedingIssue)
                                        .frame(minHeight: 80)

                                    if showsVitaminDField {
                                        Toggle(L10nWVF.k("well_visit_form.feeding.vitamin_d.toggle"), isOn: $vitaminDGiven)
                                    }
                                }
                            }
                        }
                        .groupBoxStyle(PlainGroupBoxStyle())
                        .padding(12)
                        .lightBlueSectionCardStyle()
                    }

                GroupBox(L10nWVF.k("well_visit_form.stools.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10nWVF.k("well_visit_form.stools.pattern.label"))
                            .font(.subheadline)

                        Picker(L10nWVF.k("well_visit_form.stools.pattern.picker"), selection: $poopStatus) {
                            Text(L10nWVF.k("well_visit_form.stools.pattern.option.normal_breastfed")).tag("normal")
                            Text(L10nWVF.k("well_visit_form.stools.pattern.option.abnormal_reported")).tag("abnormal")
                            Text(L10nWVF.k("well_visit_form.stools.pattern.option.hard_constipated")).tag("hard")
                        }
                        .pickerStyle(.segmented)

                        TextField(L10nWVF.k("well_visit_form.stools.comment.placeholder"), text: $poopComment)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .groupBoxStyle(PlainGroupBoxStyle())
                .padding(12)
                .lightBlueSectionCardStyle()

                // Sleep
                if layout.showsSleep {
                    GroupBox(L10nWVF.k("well_visit_form.sleep.title")) {
                        VStack(alignment: .leading, spacing: 12) {
                            if isEarlySleepVisit {
                                // Structured sleep layout for early visits
                                HStack(spacing: 16) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(L10nWVF.k("well_visit_form.sleep.wakes_for_feeds.label"))
                                            .font(.subheadline)
                                        TextField(L10nWVF.k("well_visit_form.sleep.wakes_for_feeds.placeholder"), text: $wakesForFeedsPerNight)
                                            .frame(width: 80)
                                            .textFieldStyle(.roundedBorder)
                                    }

                                    if isEarlyMilkOnlyVisit {
                                        Toggle(L10nWVF.k("well_visit_form.sleep.longer_stretch.toggle"), isOn: $longerSleepAtNight)
                                            .toggleStyle(.switch)
                                    }
                                }

                                Toggle(L10nWVF.k("well_visit_form.sleep.issues_reported.toggle"), isOn: $sleepIssueReported)
                                    .toggleStyle(.switch)

                                if sleepIssueReported {
                                    Text(L10nWVF.k("well_visit_form.sleep.issue_description.label"))
                                        .font(.subheadline)
                                    TextEditor(text: $sleep)
                                        .frame(minHeight: 80)
                                }
                            } else if isOlderSleepVisit {
                                // Structured sleep layout for older visits (12-month+)
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 16) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(L10nWVF.k("well_visit_form.sleep.wakes_at_night.label"))
                                                .font(.subheadline)
                                            TextField(L10nWVF.k("well_visit_form.sleep.wakes_at_night.placeholder"), text: $wakesForFeedsPerNight)
                                                .frame(width: 80)
                                                .textFieldStyle(.roundedBorder)
                                        }

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(L10nWVF.k("well_visit_form.sleep.total_sleep_24h.label"))
                                                .font(.subheadline)
                                            Picker(L10nWVF.k("well_visit_form.sleep.total_sleep_24h.picker"), selection: $sleepHoursText) {
                                                Text(L10nWVF.k("well_visit_form.sleep.total_sleep_24h.option.lt10")).tag("lt10")
                                                Text(L10nWVF.k("well_visit_form.sleep.total_sleep_24h.option.10_15")).tag("10_15")
                                            }
                                            .pickerStyle(.segmented)
                                        }
                                    }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L10nWVF.k("well_visit_form.sleep.regularity.label"))
                                        .font(.subheadline)
                                    Picker(L10nWVF.k("well_visit_form.sleep.regularity.picker"), selection: $sleepRegular) {
                                        Text(L10nWVF.k("well_visit_form.shared.regular")).tag("regular")
                                        Text(L10nWVF.k("well_visit_form.shared.irregular")).tag("irregular")
                                    }
                                    .pickerStyle(.segmented)
                                }

                                    Toggle(L10nWVF.k("well_visit_form.sleep.snoring.toggle"), isOn: $sleepSnoring)
                                        .toggleStyle(.switch)

                                    Toggle(L10nWVF.k("well_visit_form.sleep.issues_reported.toggle"), isOn: $sleepIssueReported)
                                        .toggleStyle(.switch)

                                    if sleepIssueReported {
                                        Text(L10nWVF.k("well_visit_form.sleep.issue_description.label"))
                                            .font(.subheadline)
                                        TextEditor(text: $sleep)
                                            .frame(minHeight: 80)
                                    }
                                }
                            } else {
                                // Legacy / generic sleep comment for other ages (fallback)
                                TextEditor(text: $sleep)
                                    .frame(minHeight: 100)
                            }
                        }
                    }
                    .groupBoxStyle(PlainGroupBoxStyle())
                    .padding(12)
                    .lightBlueSectionCardStyle()
                }

                    // Physical examination (stored in lab_text for now)
                    if layout.showsPhysicalExam {
                        GroupBox(L10nWVF.k("well_visit_form.section.physical_exam")) {
                            VStack(alignment: .leading, spacing: 12) {
                                // General / appearance
                                Text(L10nWVF.k("well_visit_form.pe.general.title"))
                                    .font(.subheadline.bold())

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(L10nWVF.k("well_visit_form.pe.general.trophic.label"))
                                        Spacer()
                                        Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peTrophicNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField(L10nWVF.k("well_visit_form.pe.general.trophic.comment.placeholder"), text: $peTrophicComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(L10nWVF.k("well_visit_form.pe.general.hydration.label"))
                                        Spacer()
                                        Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peHydrationNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField(L10nWVF.k("well_visit_form.pe.general.hydration.comment.placeholder"), text: $peHydrationComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L10nWVF.k("well_visit_form.pe.general.color.label"))
                                        .font(.subheadline)
                                    Picker(L10nWVF.k("well_visit_form.pe.general.color.picker"), selection: $peColor) {
                                        Text(L10nWVF.k("well_visit_form.pe.general.color.option.normal")).tag("normal")
                                        Text(L10nWVF.k("well_visit_form.pe.general.color.option.jaundice")).tag("jaundice")
                                        Text(L10nWVF.k("well_visit_form.pe.general.color.option.pale")).tag("pale")
                                    }
                                    .pickerStyle(.segmented)

                                    TextField(L10nWVF.k("well_visit_form.pe.general.color.comment.placeholder"), text: $peColorComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                if isFontanelleVisit {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(L10nWVF.k("well_visit_form.pe.general.fontanelle.label"))
                                            Spacer()
                                            Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peFontanelleNormal)
                                                .toggleStyle(.switch)
                                        }
                                        TextField(L10nWVF.k("well_visit_form.pe.general.fontanelle.comment.placeholder"), text: $peFontanelleComment)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(L10nWVF.k("well_visit_form.pe.general.pupils.label"))
                                        Spacer()
                                        Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $pePupilsRRNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField(L10nWVF.k("well_visit_form.pe.general.pupils.comment.placeholder"), text: $pePupilsRRComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(L10nWVF.k("well_visit_form.pe.general.ocular_motility.label"))
                                        Spacer()
                                        Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peOcularMotilityNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField(L10nWVF.k("well_visit_form.pe.general.ocular_motility.comment.placeholder"), text: $peOcularMotilityComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                if isTeethVisit {
                                    Divider()
                                        .padding(.vertical, 4)

                                    Text(L10nWVF.k("well_visit_form.pe.teeth.title"))
                                        .font(.subheadline.bold())

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(L10nWVF.k("well_visit_form.pe.teeth.present.label"))
                                            Spacer()
                                            Toggle(L10nWVF.k("well_visit_form.pe.shared.yes"), isOn: $peTeethPresent)
                                                .toggleStyle(.switch)
                                        }

                                        if peTeethPresent {
                                            HStack(spacing: 12) {
                                                Text(L10nWVF.k("well_visit_form.pe.teeth.count.label"))
                                                TextField(L10nWVF.k("well_visit_form.pe.teeth.count.placeholder"), text: $peTeethCount)
                                                    .frame(width: 80)
                                                    .textFieldStyle(.roundedBorder)
                                            }
                                        }

                                        TextField(L10nWVF.k("well_visit_form.pe.teeth.comment.placeholder"), text: $peTeethComment)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }

                                // Neurologic / behaviour
                                Divider()
                                    .padding(.vertical, 4)

                                Text(L10nWVF.k("well_visit_form.pe.neuro.title"))
                                    .font(.subheadline.bold())

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(L10nWVF.k("well_visit_form.pe.neuro.tone.label"))
                                        Spacer()
                                        Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peToneNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField(L10nWVF.k("well_visit_form.pe.neuro.tone.comment.placeholder"), text: $peToneComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                if isPrimitiveNeuroVisit {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(L10nWVF.k("well_visit_form.pe.neuro.wakefulness.label"))
                                            Spacer()
                                            Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peWakefulnessNormal)
                                                .toggleStyle(.switch)
                                        }
                                        TextField(L10nWVF.k("well_visit_form.pe.neuro.wakefulness.comment.placeholder"), text: $peWakefulnessComment)
                                            .textFieldStyle(.roundedBorder)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(L10nWVF.k("well_visit_form.pe.neuro.hands_fists.label"))
                                            Spacer()
                                            Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peHandsFistNormal)
                                                .toggleStyle(.switch)
                                        }
                                        TextField(L10nWVF.k("well_visit_form.pe.neuro.hands_fists.comment.placeholder"), text: $peHandsFistComment)
                                            .textFieldStyle(.roundedBorder)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(L10nWVF.k("well_visit_form.pe.neuro.symmetry.label"))
                                            Spacer()
                                            Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peSymmetryNormal)
                                                .toggleStyle(.switch)
                                        }
                                        TextField(L10nWVF.k("well_visit_form.pe.neuro.symmetry.comment.placeholder"), text: $peSymmetryComment)
                                            .textFieldStyle(.roundedBorder)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(L10nWVF.k("well_visit_form.pe.neuro.follows_midline.label"))
                                            Spacer()
                                            Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peFollowsMidlineNormal)
                                                .toggleStyle(.switch)
                                        }
                                        TextField(L10nWVF.k("well_visit_form.pe.neuro.follows_midline.comment.placeholder"), text: $peFollowsMidlineComment)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }

                                if isMoroVisit {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(L10nWVF.k("well_visit_form.pe.neuro.moro.label"))
                                            Spacer()
                                            Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peMoroNormal)
                                                .toggleStyle(.switch)
                                        }
                                        TextField(L10nWVF.k("well_visit_form.pe.neuro.moro.comment.placeholder"), text: $peMoroComment)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }

                                // Respiratory
                                Divider()
                                    .padding(.vertical, 4)

                                Text(L10nWVF.k("well_visit_form.pe.respiratory.title"))
                                    .font(.subheadline.bold())

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(L10nWVF.k("well_visit_form.pe.respiratory.breathing.label"))
                                        Spacer()
                                        Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peBreathingNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField(L10nWVF.k("well_visit_form.pe.respiratory.breathing.comment.placeholder"), text: $peBreathingComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                // Cardiovascular
                                Divider()
                                    .padding(.vertical, 4)

                                Text(L10nWVF.k("well_visit_form.pe.cardiovascular.title"))
                                    .font(.subheadline.bold())

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(L10nWVF.k("well_visit_form.pe.cardiovascular.heart_sounds.label"))
                                        Spacer()
                                        Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peHeartNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField(L10nWVF.k("well_visit_form.pe.cardiovascular.heart_sounds.comment.placeholder"), text: $peHeartComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                // Abdomen / digestive
                                Divider()
                                    .padding(.vertical, 4)

                                Text(L10nWVF.k("well_visit_form.pe.abdomen.title"))
                                    .font(.subheadline.bold())

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(L10nWVF.k("well_visit_form.pe.abdomen.palpation.label"))
                                        Spacer()
                                        Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peAbdomenNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField(L10nWVF.k("well_visit_form.pe.abdomen.palpation.comment.placeholder"), text: $peAbdomenComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(L10nWVF.k("well_visit_form.pe.abdomen.mass.label"))
                                        Spacer()
                                        Toggle(L10nWVF.k("well_visit_form.pe.shared.yes"), isOn: $peAbdMassPresent)
                                            .toggleStyle(.switch)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(L10nWVF.k("well_visit_form.pe.abdomen.liver_spleen.label"))
                                        Spacer()
                                        Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peLiverSpleenNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField(L10nWVF.k("well_visit_form.pe.abdomen.liver_spleen.comment.placeholder"), text: $peLiverSpleenComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(L10nWVF.k("well_visit_form.pe.abdomen.umbilicus.label"))
                                        Spacer()
                                        Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peUmbilicNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField(L10nWVF.k("well_visit_form.pe.abdomen.umbilicus.comment.placeholder"), text: $peUmbilicComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L10nWVF.k("well_visit_form.pe.abdomen.genitalia.label"))
                                        .font(.subheadline)
                                    TextField(L10nWVF.k("well_visit_form.pe.abdomen.genitalia.placeholder"), text: $peGenitalia)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(L10nWVF.k("well_visit_form.pe.abdomen.testicles_descended.label"))
                                        Spacer()
                                        Toggle(L10nWVF.k("well_visit_form.pe.shared.yes"), isOn: $peTesticlesDescended)
                                            .toggleStyle(.switch)
                                    }
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(L10nWVF.k("well_visit_form.pe.cardiovascular.femoral_pulses.label"))
                                        Spacer()
                                        Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peFemoralPulsesNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField(L10nWVF.k("well_visit_form.pe.cardiovascular.femoral_pulses.comment.placeholder"), text: $peFemoralPulsesComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                // Hips / limbs / posture
                                Divider()
                                    .padding(.vertical, 4)

                                Text(L10nWVF.k("well_visit_form.pe.msk.title"))
                                    .font(.subheadline.bold())

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(L10nWVF.k("well_visit_form.pe.msk.spine.label"))
                                        Spacer()
                                        Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peSpineNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField(L10nWVF.k("well_visit_form.pe.msk.spine.comment.placeholder"), text: $peSpineComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                if isHipsVisit {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(L10nWVF.k("well_visit_form.pe.msk.hips_limbs.label"))
                                            Spacer()
                                            Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peHipsLimbsNormal)
                                                .toggleStyle(.switch)
                                        }
                                        TextField(L10nWVF.k("well_visit_form.pe.msk.hips_limbs.comment.placeholder"), text: $peHipsLimbsComment)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }

                                // Skin
                                Divider()
                                    .padding(.vertical, 4)

                                Text(L10nWVF.k("well_visit_form.pe.skin.title"))
                                    .font(.subheadline.bold())

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(L10nWVF.k("well_visit_form.pe.skin.marks.label"))
                                        Spacer()
                                        Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peSkinMarksNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField(L10nWVF.k("well_visit_form.pe.skin.marks.comment.placeholder"), text: $peSkinMarksComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(L10nWVF.k("well_visit_form.pe.skin.integrity.label"))
                                        Spacer()
                                        Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peSkinIntegrityNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField(L10nWVF.k("well_visit_form.pe.skin.integrity.comment.placeholder"), text: $peSkinIntegrityComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(L10nWVF.k("well_visit_form.pe.skin.rash.label"))
                                        Spacer()
                                        Toggle(L10nWVF.k("well_visit_form.pe.shared.normal"), isOn: $peSkinRashNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField(L10nWVF.k("well_visit_form.pe.skin.rash.comment.placeholder"), text: $peSkinRashComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                Divider()
                                    .padding(.vertical, 4)

                                Text(L10nWVF.k("well_visit_form.pe.additional_notes.title"))
                                    .font(.subheadline.bold())
                                TextEditor(text: $physicalExam)
                                    .frame(minHeight: 120)
                            }
                        }
                        .groupBoxStyle(PlainGroupBoxStyle())
                        .padding(12)
                        .lightBlueSectionCardStyle()
                    }

                    // Milestones / development
                    if layout.showsMilestones && !currentMilestoneDescriptors.isEmpty {
                        GroupBox(L10nWVF.k("well_visit_form.section.milestones")) {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(currentMilestoneDescriptors) { m in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(m.label)
                                            .font(.body)

                                        Picker(L10nWVF.k("well_visit_form.milestones.status.label"), selection: Binding(
                                            get: { milestoneStatuses[m.code] ?? .uncertain },
                                            set: { milestoneStatuses[m.code] = $0 }
                                        )) {
                                            ForEach(MilestoneStatus.allCases) { status in
                                                Text(status.localizedDisplayName).tag(status)
                                            }
                                        }
                                        .pickerStyle(.segmented)

                                        TextField(
                                            L10nWVF.k("well_visit_form.milestones.note.placeholder"),
                                            text: Binding(
                                                get: { milestoneNotes[m.code] ?? "" },
                                                set: { milestoneNotes[m.code] = $0 }
                                            )
                                        )
                                        .textFieldStyle(.roundedBorder)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            .padding(.top, 4)
                        }
                        .groupBoxStyle(PlainGroupBoxStyle())
                        .padding(12)
                        .lightBlueSectionCardStyle()
                    }

                    // Neurodevelopment screening (M-CHAT / Dev test)
                    if isMCHATVisit || isDevTestScoreVisit || isDevTestResultVisit {
                        GroupBox(L10nWVF.k("well_visit_form.section.neurodevelopment_screening")) {
                            VStack(alignment: .leading, spacing: 12) {
                                if isMCHATVisit {
                                    Text(L10nWVF.k("well_visit_form.mchat.title"))
                                        .font(.subheadline.bold())

                                    HStack(alignment: .center, spacing: 12) {
                                        Text(L10nWVF.k("well_visit_form.mchat.score.label"))
                                        TextField(L10nWVF.k("well_visit_form.mchat.score.placeholder"), text: $mchatScore)
                                            .frame(width: 80)
                                            .textFieldStyle(.roundedBorder)
                                    }

                                    TextField(L10nWVF.k("well_visit_form.mchat.result.placeholder"), text: $mchatResult)
                                        .textFieldStyle(.roundedBorder)

                                    if let riskText = mchatRiskCategoryDescription {
                                        Text(riskText)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                if isDevTestScoreVisit || isDevTestResultVisit {
                                    Divider()
                                        .padding(.vertical, 4)

                                    Text(L10nWVF.k("well_visit_form.dev_test.title"))
                                        .font(.subheadline.bold())

                                    if isDevTestScoreVisit {
                                        HStack(alignment: .center, spacing: 12) {
                                            Text(L10nWVF.k("well_visit_form.dev_test.score.label"))
                                            TextField(L10nWVF.k("well_visit_form.dev_test.score.placeholder"), text: $devTestScore)
                                                .frame(width: 80)
                                                .textFieldStyle(.roundedBorder)
                                        }
                                    }

                                    if isDevTestResultVisit {
                                        TextField(L10nWVF.k("well_visit_form.dev_test.result.placeholder"), text: $devTestResult)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                        .groupBoxStyle(PlainGroupBoxStyle())
                        .padding(12)
                        .lightBlueSectionCardStyle()
                    }

                    // Problem listing
                    if layout.showsProblemListing {
                        GroupBox(L10nWVF.k("well_visit_form.problem_listing.title")) {
                            VStack(alignment: .leading, spacing: 8) {
                                TextEditor(text: $problemListing)
                                    .frame(minHeight: 140)

                                Button {
                                    regenerateProblemListingFromFindings()
                                } label: {
                                    Label(L10nWVF.k("well_visit_form.problem_listing.update_from_findings"), systemImage: "list.bullet.clipboard")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .groupBoxStyle(PlainGroupBoxStyle())
                        .padding(12)
                        .lightBlueSectionCardStyle()
                    }

                    // Conclusions
                    if layout.showsConclusions {
                        GroupBox(L10nWVF.k("well_visit_form.conclusions.title")) {
                            TextEditor(text: $conclusions)
                                .frame(minHeight: 140)
                        }
                        .groupBoxStyle(PlainGroupBoxStyle())
                        .padding(12)
                        .lightBlueSectionCardStyle()
                    }

                    // Plan / Anticipatory Guidance
                    if layout.showsPlan {
                        GroupBox(L10nWVF.k("well_visit_form.plan.title")) {
                            TextEditor(text: $plan)
                                .frame(minHeight: 140)
                        }
                        .groupBoxStyle(PlainGroupBoxStyle())
                        .padding(12)
                        .lightBlueSectionCardStyle()
                    }

                    // Clinician Comment – stays at the end
                    if layout.showsClinicianComment {
                        GroupBox(L10nWVF.k("well_visit_form.clinician_comment.title")) {
                            TextEditor(text: $clinicianComment)
                                .frame(minHeight: 120)
                        }
                        .groupBoxStyle(PlainGroupBoxStyle())
                        .padding(12)
                        .lightBlueSectionCardStyle()
                    }

                    // Next Visit Date
                    if layout.showsNextVisit {
                        GroupBox(L10nWVF.k("well_visit_form.next_visit.title")) {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(L10nWVF.k("well_visit_form.next_visit.toggle"), isOn: $hasNextVisitDate)

                                DatePicker(
                                    L10nWVF.k("well_visit_form.next_visit.datepicker"),
                                    selection: $nextVisitDate,
                                    displayedComponents: .date
                                )
                                .disabled(!hasNextVisitDate)
                            }
                            .padding(.top, 4)
                        }
                        .groupBoxStyle(PlainGroupBoxStyle())
                        .padding(12)
                        .lightBlueSectionCardStyle()
                    }
                    
                    

                    
                    // AI assistant (well visits)
                    if showsAISection {
                        aiAssistantSection
                    }
                    
                    // Addenda (only when editing an existing well visit)
                    if editingVisitID != nil {
                        wellAddendaSection
                    }
                }
                .padding(20)
            }
            .navigationTitle(editingVisitID == nil ? Text("well_visit_form.nav.new") : Text("well_visit_form.nav.edit"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("well_visit_form.toolbar.cancel") {
                        AppLog.ui.debug("CANCEL tapped | pid=\(logOptInt(appState.selectedPatientID), privacy: .public) visitID=\(logOptInt(editingVisitID), privacy: .public)")
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("well_visit_form.toolbar.save") {
                         AppLog.ui.debug("WellVisitForm: SAVE tapped | pid=\(logOptInt(appState.selectedPatientID), privacy: .public) visitID=\(logOptInt(editingVisitID), privacy: .public)")
                                saveTapped()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .alert(
                "well_visit_form.alert.save_failed.title",
                isPresented: $showErrorAlert
            ) {
                Button("well_visit_form.alert.ok", role: .cancel) { }
            } message: {
                Text(saveErrorMessage ?? NSLocalizedString("well_visit_form.alert.unknown_error", comment: ""))
            }
            .onAppear {
                 AppLog.ui.debug("WellVisitForm: opened editingVisitID=\(logOptInt(editingVisitID), privacy: .public)")
                loadIfEditing()
                refreshWeightTrend()
            }
            .onChangeCompat(of: visitDate) {
                refreshWeightTrend()
            }
        }
        
        .frame(
            minWidth: 1100,
            idealWidth: 1200,
            maxWidth: 1400,
            minHeight: 640,
            idealHeight: min(CGFloat(820), maxWellVisitFormHeight),
            maxHeight: maxWellVisitFormHeight
        )
    }
    
    private var isTeethVisit: Bool {
        // Show teeth section from 4-month visit onwards
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
    
    private var isPostTwelveMonthVisit: Bool {
        let visitTypes: Set<String> = [
            "fifteen_month",
            "eighteen_month",
            "twentyfour_month",
            "thirty_month",
            "thirtysix_month"
        ]
        return visitTypes.contains(visitTypeID)
    }
    
    private var currentAIEntriesForVisit: [(key: String, value: String)] {
        guard
            let visitID = editingVisitID,
            let stored = appState.aiSummariesByWellVisit[visitID]
        else {
            return []
        }
        return Array(stored)
    }

    /// Derives the M-CHAT risk category from the current score, if valid.
    /// Categories:
    /// - 0–2   → Low risk
    /// - 3–7   → Medium risk
    /// - 8–20  → High risk
    /// Derives the M-CHAT risk code from a score string, if valid.
    /// Returns stable stored codes: "low_risk", "medium_risk", "high_risk".
    private func mchatRiskCode(from scoreText: String) -> String? {
        let t = scoreText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let score = Int(t) else { return nil }

        switch score {
        case 0...2:  return "low_risk"
        case 3...7:  return "medium_risk"
        case 8...20: return "high_risk"
        default:     return nil
        }
    }

    /// Derives the M-CHAT risk category explanation from the current score, if valid.
    private var mchatRiskCategoryDescription: String? {
        guard let code = mchatRiskCode(from: mchatScore) else { return nil }
        switch code {
        case "low_risk":
            return NSLocalizedString("well_visit_form.mchat.risk.low", comment: "")
        case "medium_risk":
            return NSLocalizedString("well_visit_form.mchat.risk.medium", comment: "")
        case "high_risk":
            return NSLocalizedString("well_visit_form.mchat.risk.high", comment: "")
        default:
            return nil
        }
    }

    // MARK: - Weight trend helper

    private func refreshWeightTrend() {
        // Only relevant for the early well visits
        guard isWeightDeltaVisit else {
            latestWeightSummary = ""
            previousWeightSummary = ""
            deltaWeightPerDaySummary = ""
            deltaWeightPerDayValue = nil
            deltaWeightIsNormal = false
            return
        }

        guard let dbURL = appState.currentDBURL,
              let patientID = appState.selectedPatientID,
              FileManager.default.fileExists(atPath: dbURL.path)
        else {
            latestWeightSummary = NSLocalizedString("well_visit_form.weight_trend.no_weight_data", comment: "")
            previousWeightSummary = ""
            deltaWeightPerDaySummary = ""
            deltaWeightPerDayValue = nil
            deltaWeightIsNormal = false
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = db
        else {
            return
        }
        defer { sqlite3_close(db) }

        let dateISO = Self.isoDateOnly.string(from: visitDate)

        let sql = """
        WITH all_weights AS (
            -- Manual growth only (exclude vitals-mirrored rows)
            SELECT weight_kg * 1000.0 AS weight_g,
                   substr(recorded_at, 1, 10) AS date_str
            FROM manual_growth
            WHERE patient_id = ?
              AND weight_kg IS NOT NULL
              AND COALESCE(source,'manual') NOT LIKE 'vitals%'

            UNION ALL

            -- Birth weight (date = patient's DOB)
            SELECT CAST(birth_weight_g AS REAL) AS weight_g,
                   substr((SELECT dob FROM patients WHERE id = ?), 1, 10) AS date_str
            FROM perinatal_history
            WHERE patient_id = ?
              AND birth_weight_g IS NOT NULL

            UNION ALL

            -- Maternity discharge weight
            SELECT CAST(discharge_weight_g AS REAL) AS weight_g,
                   substr(maternity_discharge_date, 1, 10) AS date_str
            FROM perinatal_history
            WHERE patient_id = ?
              AND discharge_weight_g IS NOT NULL
              AND maternity_discharge_date IS NOT NULL
        )
        SELECT weight_g, date_str
        FROM all_weights
        WHERE date_str IS NOT NULL
          AND date(date_str) <= date(?)
        ORDER BY date(date_str) DESC
        LIMIT 2;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID)) // manual_growth
        sqlite3_bind_int64(stmt, 2, sqlite3_int64(patientID)) // patients.id for DOB subquery
        sqlite3_bind_int64(stmt, 3, sqlite3_int64(patientID)) // perinatal birth_weight
        sqlite3_bind_int64(stmt, 4, sqlite3_int64(patientID)) // perinatal discharge_weight
        _ = dateISO.withCString { sqlite3_bind_text(stmt, 5, $0, -1, SQLITE_TRANSIENT) } // visit date

        var points: [(weightG: Double, dateStr: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let w = sqlite3_column_double(stmt, 0)
            let d: String
            if let c = sqlite3_column_text(stmt, 1) {
                d = String(cString: c)
            } else {
                d = ""
            }
            points.append((w, d))
        }

        guard !points.isEmpty else {
            latestWeightSummary = NSLocalizedString("well_visit_form.weight_trend.no_weight_data", comment: "")
            previousWeightSummary = ""
            deltaWeightPerDaySummary = ""
            deltaWeightPerDayValue = nil
            deltaWeightIsNormal = false
            return
        }

        func cleanDate(_ raw: String) -> String {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return "" }

            // ISO8601: 2025-12-29T09:30:41Z  →  2025-12-29
            if let t = s.firstIndex(of: "T") {
                return String(s[..<t])
            }

            // Legacy: 2025-12-29 09:30:41  →  2025-12-29
            if let space = s.firstIndex(of: " ") {
                return String(s[..<space])
            }

            // Already date-only
            return s
        }

        let latest = points[0]
        let latestKg = latest.weightG / 1000.0
        let latestDateDisplay = cleanDate(latest.dateStr)
        latestWeightSummary = String(
            format: NSLocalizedString("well_visit_form.weight_trend.weight_at_date_format", comment: ""),
            latestKg,
            latestDateDisplay
        )

        guard points.count >= 2 else {
            previousWeightSummary = ""
            deltaWeightPerDaySummary = ""
            deltaWeightPerDayValue = nil
            deltaWeightIsNormal = false
            return
        }

        let previous = points[1]
        let previousKg = previous.weightG / 1000.0
        let previousDateDisplay = cleanDate(previous.dateStr)
        previousWeightSummary = String(
            format: NSLocalizedString("well_visit_form.weight_trend.weight_at_date_format", comment: ""),
            previousKg,
            previousDateDisplay
        )

        // Parse dates to compute day difference
        let rawLatest = latest.dateStr
        let rawPrevious = previous.dateStr

        func parseVisitDate(_ raw: String) -> Date? {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }

            // 1) ISO 8601 (e.g., 2025-12-29T09:30:41Z or with fractional seconds)
            let iso = ISO8601DateFormatter()
            iso.timeZone = TimeZone(secondsFromGMT: 0)
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }

            // Some sources omit fractional seconds; try again without it.
            let isoNoFrac = ISO8601DateFormatter()
            isoNoFrac.timeZone = TimeZone(secondsFromGMT: 0)
            isoNoFrac.formatOptions = [.withInternetDateTime]
            if let d = isoNoFrac.date(from: s) { return d }

            // 2) Legacy formats used elsewhere in the app.
            let dateTimeFormatter = DateFormatter()
            dateTimeFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateTimeFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            dateTimeFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let d = dateTimeFormatter.date(from: s) { return d }

            let dateOnlyFormatter = DateFormatter()
            dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateOnlyFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
            if let d = dateOnlyFormatter.date(from: s) { return d }

            return nil
        }

        let dLatest = parseVisitDate(rawLatest)
        let dPrevious = parseVisitDate(rawPrevious)

        guard let start = dPrevious, let end = dLatest else {
            deltaWeightPerDaySummary = ""
            deltaWeightPerDayValue = nil
            deltaWeightIsNormal = false
            return
        }

        var dayDiff = Int((end.timeIntervalSince(start) / 86400.0).rounded())
        if dayDiff <= 0 { dayDiff = 1 }

        let deltaTotalG = latest.weightG - previous.weightG
        let deltaPerDay = deltaTotalG / Double(dayDiff)
        let roundedPerDay = Int32(deltaPerDay.rounded())

        deltaWeightPerDayValue = roundedPerDay
        deltaWeightPerDaySummary = String(
            format: NSLocalizedString("well_visit_form.weight_trend.delta_weight_per_day", comment: ""),
            Int(roundedPerDay)
        )
        deltaWeightIsNormal = roundedPerDay >= 20
    }

// MARK: - Load existing visit (edit mode)



    private func loadIfEditing() {
        guard let visitID = editingVisitID,
              let dbURL = appState.currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path)
        else { return }
        // Load stored AI inputs / summaries for this well visit
        appState.loadWellAIInputs(forWellVisitID: visitID)

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = db else { return }
        defer { sqlite3_close(db) }

        // Load core well_visits fields + feeding-related structured fields
        do {
            let sql = """
            SELECT
                visit_date,
                visit_type,
                COALESCE(parent_concerns,''),
                COALESCE(feeding_comment,''),
                COALESCE(dairy_amount_text,''),
                COALESCE(sleep_issue_text,''),
                COALESCE(problem_listing,''),
                COALESCE(conclusions,''),
                COALESCE(anticipatory_guidance,''),
                COALESCE(next_visit_date,''),
                COALESCE(comments,''),
                COALESCE(lab_text,''),
                vitamin_d_given,
                COALESCE(mchat_score, 0),
                COALESCE(mchat_result, ''),
                COALESCE(devtest_score, 0),
                COALESCE(devtest_result, ''),
                COALESCE(poop_status,''),
                COALESCE(poop_comment,''),
                COALESCE(milk_types,''),
                feed_volume_ml,
                feed_freq_per_24h,
                regurgitation,
                COALESCE(feeding_issue,''),
                solid_food_started,
                COALESCE(solid_food_start_date,''),
                COALESCE(solid_food_quality,''),
                COALESCE(solid_food_comment,''),
                COALESCE(food_variety_quality,''),
                COALESCE(sleep_hours_text,''),
                COALESCE(sleep_regular,''),
                longer_sleep_night,
                sleep_snoring,
                sleep_issue_reported
            FROM well_visits
            WHERE id = ?
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, sqlite3_int64(visitID))

            if sqlite3_step(stmt) == SQLITE_ROW {
                func text(_ i: Int32) -> String {
                    if let c = sqlite3_column_text(stmt, i) {
                        return String(cString: c)
                    }
                    return ""
                }

                let dateISO            = text(0)
                let type               = text(1)
                let parentTxt          = text(2)
                let feedingText        = text(3)
                let dairyOrSuppRaw     = text(4)
                let sleepText          = text(5)
                let problems           = text(6)
                let conclText          = text(7)
                let planText           = text(8)
                let nextVisitISO       = text(9)
                let clinicianText      = text(10)
                let peText             = text(11)
                let vitVal             = sqlite3_column_int(stmt, 12)
                let mchatScoreInt      = sqlite3_column_int(stmt, 13)
                let mchatResultText    = text(14)
                let devTestScoreInt    = sqlite3_column_int(stmt, 15)
                let devTestResultText  = text(16)

                let poopStatusText     = text(17)
                let poopCommentText    = text(18)
                let milkTypesText      = text(19)
                let feedVolumeVal      = sqlite3_column_double(stmt, 20)
                let feedFreqVal        = sqlite3_column_int(stmt, 21)
                let regurgitationVal   = sqlite3_column_int(stmt, 22)
                let feedingIssueText   = text(23)
                let solidStartedVal    = sqlite3_column_int(stmt, 24)
                let solidStartDateISO  = text(25)
                let solidQualityText   = text(26)
                let solidCommentText   = text(27)
                let foodVarietyText    = text(28)

                let sleepHoursTextDB   = text(29)
                let sleepRegularText   = text(30)
                let longerSleepNightVal = sqlite3_column_int(stmt, 31)
                let sleepSnoringVal    = sqlite3_column_int(stmt, 32)
                let sleepIssueReportedVal = sqlite3_column_int(stmt, 33)

                // Decode structured wakes-per-night prefix (if present) from sleep_issue_text
                var parsedSleep = sleepText
                var parsedWakes = ""
                if !sleepText.isEmpty {
                    let lines = sleepText.components(separatedBy: .newlines)
                    if let first = lines.first,
                       first.hasPrefix("wakes_per_night=") {
                        let valuePart = first.dropFirst("wakes_per_night=".count)
                        parsedWakes = valuePart.trimmingCharacters(in: .whitespaces)
                        let remainingLines = lines.dropFirst()
                        parsedSleep = remainingLines.joined(separator: "\n")
                    }
                }

                if !dateISO.isEmpty,
                   let d = Self.isoDateOnly.date(from: dateISO) {
                    visitDate = d
                }
                if !type.isEmpty {
                    visitTypeID = type
                }
                parentsConcerns  = parentTxt
                feeding          = feedingText

                // Hydrate structured wakes-per-night and remaining sleep text
                wakesForFeedsPerNight = parsedWakes
                sleep                 = parsedSleep

                // Overloaded dairy_amount_text: if it looks like "1"–"4" we treat it as dairy code,
                // otherwise we treat it as supplementation free-text (backwards compatible).
                if ["1", "2", "3", "4"].contains(dairyOrSuppRaw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    dairyAmountCode = dairyOrSuppRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    supplementation = ""
                } else {
                    dairyAmountCode = ""
                    supplementation = dairyOrSuppRaw
                }

                problemListing   = problems
        // Load problem listing tokens (if present) for localization-safe rendering.
        tokenLoad: do {
            let sql = "SELECT COALESCE(problem_listing_tokens,'') FROM well_visits WHERE id = ? LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { break tokenLoad }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, sqlite3_int64(visitID))
            if sqlite3_step(stmt) == SQLITE_ROW {
                let raw: String = {
                    if let c = sqlite3_column_text(stmt, 0) { return String(cString: c) }
                    return ""
                }()

                if let decoded = decodeProblemTokensFromDB(raw) {
                    problemListingTokens = decoded
                } else {
                    problemListingTokens = []
                }
            }
        }
                conclusions      = conclText
                plan             = planText
                clinicianComment = clinicianText
                physicalExam     = peText
                vitaminDGiven    = (vitVal != 0)

                if !nextVisitISO.isEmpty,
                   let nv = Self.isoDateOnly.date(from: nextVisitISO) {
                    hasNextVisitDate = true
                    nextVisitDate = nv
                } else {
                    hasNextVisitDate = false
                }

                if mchatScoreInt > 0 {
                    mchatScore = String(mchatScoreInt)
                } else {
                    mchatScore = ""
                }
                mchatResult = normalizeMchatResultCode(mchatResultText)

                if devTestScoreInt > 0 {
                    devTestScore = String(devTestScoreInt)
                } else {
                    devTestScore = ""
                }
                devTestResult = normalizeDevTestResultCode(devTestResultText)

                // Structured feeding fields
                poopStatus = normalizePoopStatusCode(poopStatusText)
                poopComment = poopCommentText

                // Decode milk_types → toggles
                let milkTrim = milkTypesText.trimmingCharacters(in: .whitespacesAndNewlines)
                switch milkTrim {
                case "both":
                    milkTypeBreast = true
                    milkTypeFormula = true
                case "breast":
                    milkTypeBreast = true
                    milkTypeFormula = false
                case "formula":
                    milkTypeBreast = false
                    milkTypeFormula = true
                default:
                    milkTypeBreast = false
                    milkTypeFormula = false
                }

                if feedVolumeVal > 0 {
                    feedVolumeMl = String(format: "%.0f", feedVolumeVal)
                } else {
                    feedVolumeMl = ""
                }

                if feedFreqVal > 0 {
                    feedFreqPer24h = String(feedFreqVal)
                } else {
                    feedFreqPer24h = ""
                }

                regurgitationPresent = (regurgitationVal != 0)
                feedingIssue = feedingIssueText

                solidFoodStarted = (solidStartedVal != 0)
                if solidFoodStarted,
                   !solidStartDateISO.isEmpty,
                   let solidsDate = Self.isoDateOnly.date(from: solidStartDateISO) {
                    solidFoodStartDate = solidsDate
                }

                solidFoodQuality = normalizeQualityCode(solidQualityText)
                solidFoodComment = solidCommentText
                foodVarietyQuality = normalizeQualityCode(foodVarietyText)

                // Structured sleep fields
                sleepHoursText = sleepHoursTextDB
                sleepRegular = normalizeSleepRegularCode(sleepRegularText)
                sleepSnoring   = (sleepSnoringVal != 0)
                longerSleepAtNight = (longerSleepNightVal != 0)

                if sleepIssueReportedVal != 0 {
                    sleepIssueReported = true
                } else {
                    // Backwards compatible:
                    // For legacy rows (no explicit flag), we only auto‑set "sleep issues reported"
                    // if there is some FREE‑TEXT sleep description after removing any
                    // structured "wakes_per_night=" prefix. This prevents the flag from
                    // turning on just because a wakes-per-night value was stored.
                    let trimmedDetails = parsedSleep.trimmingCharacters(in: .whitespacesAndNewlines)
                    sleepIssueReported = !trimmedDetails.isEmpty
                }
            }
        }

        // Load physical exam structured columns
        do {
            let sql = """
            SELECT
                pe_trophic_normal,
                COALESCE(pe_trophic_comment,''),
                pe_hydration_normal,
                COALESCE(pe_hydration_comment,''),
                COALESCE(pe_color,''),
                COALESCE(pe_color_comment,''),
                pe_fontanelle_normal,
                COALESCE(pe_fontanelle_comment,''),
                pe_pupils_rr_normal,
                COALESCE(pe_pupils_rr_comment,''),
                pe_ocular_motility_normal,
                COALESCE(pe_ocular_motility_comment,''),
                pe_tone_normal,
                COALESCE(pe_tone_comment,''),
                pe_wakefulness_normal,
                COALESCE(pe_wakefulness_comment,''),
                pe_moro_normal,
                COALESCE(pe_moro_comment,''),
                pe_hands_fist_normal,
                COALESCE(pe_hands_fist_comment,''),
                pe_symmetry_normal,
                COALESCE(pe_symmetry_comment,''),
                pe_follows_midline_normal,
                COALESCE(pe_follows_midline_comment,''),
                pe_breathing_normal,
                COALESCE(pe_breathing_comment,''),
                pe_heart_sounds_normal,
                COALESCE(pe_heart_sounds_comment,''),
                pe_abd_mass,
                COALESCE(pe_genitalia,''),
                pe_testicles_descended,
                pe_femoral_pulses_normal,
                COALESCE(pe_femoral_pulses_comment,''),
                pe_liver_spleen_normal,
                COALESCE(pe_liver_spleen_comment,''),
                pe_umbilic_normal,
                COALESCE(pe_umbilic_comment,''),
                pe_spine_normal,
                COALESCE(pe_spine_comment,''),
                pe_hips_normal,
                COALESCE(pe_hips_comment,''),
                pe_skin_marks_normal,
                COALESCE(pe_skin_marks_comment,''),
                pe_skin_integrity_normal,
                COALESCE(pe_skin_integrity_comment,''),
                pe_skin_rash_normal,
                COALESCE(pe_skin_rash_comment,''),
                pe_teeth_present,
                pe_teeth_count,
                COALESCE(pe_teeth_comment,'')
            FROM well_visits
            WHERE id = ?
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, sqlite3_int64(visitID))

            if sqlite3_step(stmt) == SQLITE_ROW {

                func boolDefaultTrue(_ index: Int32) -> Bool {
                    if sqlite3_column_type(stmt, index) == SQLITE_NULL {
                        return true
                    }
                    return sqlite3_column_int(stmt, index) != 0
                }

                func boolDefaultFalse(_ index: Int32) -> Bool {
                    if sqlite3_column_type(stmt, index) == SQLITE_NULL {
                        return false
                    }
                    return sqlite3_column_int(stmt, index) != 0
                }

                func text(_ index: Int32) -> String {
                    if let c = sqlite3_column_text(stmt, index) {
                        return String(cString: c)
                    }
                    return ""
                }

                peTrophicNormal       = boolDefaultTrue(0)
                peTrophicComment      = text(1)
                peHydrationNormal     = boolDefaultTrue(2)
                peHydrationComment    = text(3)

                let colorValue        = text(4)
                peColor               = colorValue.isEmpty ? "normal" : colorValue
                peColorComment        = text(5)

                peFontanelleNormal    = boolDefaultTrue(6)
                peFontanelleComment   = text(7)

                pePupilsRRNormal      = boolDefaultTrue(8)
                pePupilsRRComment     = text(9)

                peOcularMotilityNormal  = boolDefaultTrue(10)
                peOcularMotilityComment = text(11)

                peToneNormal          = boolDefaultTrue(12)
                peToneComment         = text(13)

                peWakefulnessNormal   = boolDefaultTrue(14)
                peWakefulnessComment  = text(15)

                peMoroNormal          = boolDefaultTrue(16)
                peMoroComment         = text(17)

                peHandsFistNormal     = boolDefaultTrue(18)
                peHandsFistComment    = text(19)

                peSymmetryNormal      = boolDefaultTrue(20)
                peSymmetryComment     = text(21)

                peFollowsMidlineNormal  = boolDefaultTrue(22)
                peFollowsMidlineComment = text(23)

                peBreathingNormal     = boolDefaultTrue(24)
                peBreathingComment    = text(25)

                peHeartNormal         = boolDefaultTrue(26)
                peHeartComment        = text(27)

                peAbdMassPresent      = boolDefaultFalse(28)
                peGenitalia           = text(29)

                peTesticlesDescended  = boolDefaultTrue(30)

                peFemoralPulsesNormal   = boolDefaultTrue(31)
                peFemoralPulsesComment  = text(32)

                peLiverSpleenNormal   = boolDefaultTrue(33)
                peLiverSpleenComment  = text(34)

                peUmbilicNormal       = boolDefaultTrue(35)
                peUmbilicComment      = text(36)

                peSpineNormal         = boolDefaultTrue(37)
                peSpineComment        = text(38)

                peHipsLimbsNormal     = boolDefaultTrue(39)
                peHipsLimbsComment    = text(40)

                peSkinMarksNormal     = boolDefaultTrue(41)
                peSkinMarksComment    = text(42)

                peSkinIntegrityNormal = boolDefaultTrue(43)
                peSkinIntegrityComment = text(44)

                peSkinRashNormal      = boolDefaultTrue(45)
                peSkinRashComment     = text(46)

                // Teeth: if a positive count exists, treat "present" as true.
                // This prevents inconsistent rows (present=0 but count>0) from generating "absent" in the problem listing.
                peTeethPresent        = boolDefaultFalse(47)

                let teethCountInt     = sqlite3_column_int(stmt, 48)
                if teethCountInt > 0 {
                    peTeethCount = String(teethCountInt)
                    peTeethPresent = true
                } else {
                    peTeethCount = ""
                }

                peTeethComment        = text(49)
            }
        }

        // Load milestone rows (if any)
        do {
            let sql = """
            SELECT code, status, COALESCE(note,'')
            FROM well_visit_milestones
            WHERE visit_id = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, sqlite3_int64(visitID))

            var statuses: [String: MilestoneStatus] = [:]
            var notes: [String: String] = [:]

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let codeC = sqlite3_column_text(stmt, 0),
                      let statusC = sqlite3_column_text(stmt, 1)
                else { continue }

                let code   = String(cString: codeC)
                let status = String(cString: statusC)
                let note   = (sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) }) ?? ""

                if let parsed = MilestoneStatus.parseStored(status) {
                    statuses[code] = parsed
                }
                if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    notes[code] = note
                }
            }

            milestoneStatuses = statuses
            milestoneNotes = notes
        }
        
        // After loading all fields (including visit date), recompute the weight trend
        refreshWeightTrend()
    }
    
    // MARK: - Localization helpers (WellVisitForm)

    // MARK: - Problem listing token persistence (WellVisitForm)

    /// Ensure the optional `problem_listing_tokens` column exists (backwards compatible).
    /// Safe to call repeatedly; we ignore the "duplicate column" error.
    private func ensureProblemListingTokensColumn(db: OpaquePointer) {
        // 1) If it already exists, do nothing (no noise, no risk).
        if columnExists(in: "well_visits", column: "problem_listing_tokens", db: db) {
            return
        }

        // 2) Otherwise, add it.
        let sql = "ALTER TABLE well_visits ADD COLUMN problem_listing_tokens TEXT;"
        let rc = sqlite3_exec(db, sql, nil, nil, nil)

        // 3) If something weird happens, log it (but keep the app running).
        if rc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            // If another thread/process added it between the check and ALTER, ignore that race safely.
            if msg.localizedCaseInsensitiveContains("duplicate column name") {
                return
            }
            // Optional: replace with your logger if you prefer
            AppLog.db.error("WellVisitForm: ensureProblemListingTokensColumn ALTER failed | msg=\(msg, privacy: .private)")
        }
    }

    private func columnExists(in table: String, column: String, db: OpaquePointer) -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return false
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            // PRAGMA table_info columns: 0=cid, 1=name, 2=type, ...
            if let cName = sqlite3_column_text(stmt, 1) {
                let name = String(cString: cName)
                if name == column { return true }
            }
        }
        return false
    }

    private func encodeProblemTokensForDB(_ tokens: [ProblemToken]) -> String {
        guard !tokens.isEmpty else { return "" }
        let enc = JSONEncoder()
        guard let data = try? enc.encode(tokens) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func decodeProblemTokensFromDB(_ raw: String) -> [ProblemToken]? {
        let t = trimmed(raw)
        guard !t.isEmpty else { return nil }
        guard let data = t.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        return try? dec.decode([ProblemToken].self, from: data)
    }


    private func L(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Logging helper: render optional Ints without the `Optional(...)` wrapper.
    private func logOptInt(_ v: Int?) -> String {
        v.map(String.init) ?? "nil"
    }

    /// Returns true if a localized string exists for this key (i.e., lookup doesn't just echo the key back).
    private func hasLocalization(_ key: String) -> Bool {
        let v = L(key)
        return v != key
    }

    /// Try to resolve a localized label for a stable `code` using a list of key prefixes.
    /// Example: prefixes ["well_visit_form.shared", "well_visit_form.sleep.regularity"] with code "regular".
    private func localizedLabel(for code: String, prefixes: [String]) -> String {
        let c = trimmed(code)
        if c.isEmpty { return "" }
        for p in prefixes {
            let k = "\(p).\(c)"
            if hasLocalization(k) {
                return L(k)
            }
        }
        return c
    }
    
    // Sleep regularity UI: keep storing canonical tokens (regular/irregular/uncertain),
    // but always display a localized label.
    private func sleepRegularityDisplayLabel(_ raw: String) -> String {
        let code = normalizeSleepRegularCode(raw)
        return localizedLabel(for: code, prefixes: [
            "well_visit_form.sleep.regularity",
            "well_visit_form.shared"
        ])
    }
    
    private func localizedIfExists(_ key: String) -> String? {
        let s = NSLocalizedString(key, comment: "")
        return (s == key) ? nil : s
    }

    private func normalizeSimpleCode(_ raw: String) -> String {
        trimmed(raw)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }

    private func normalizePoopStatusCode(_ raw: String) -> String {
        let c = normalizeSimpleCode(raw)
        switch c {
        case "normal", "abnormal", "hard":
            return c
        default:
            return trimmed(raw)   // keep legacy/free-text
        }
    }

    private func normalizeSleepRegularCode(_ raw: String) -> String {
        let c = normalizeSimpleCode(raw)
        switch c {
        case "regular", "irregular", "uncertain":
            return c
        default:
            return trimmed(raw)
        }
    }

    private func normalizeMchatResultCode(_ raw: String) -> String {
        let c = normalizeSimpleCode(raw)
        switch c {
        case "low_risk", "medium_risk", "high_risk", "negative", "positive", "pass", "fail", "normal", "abnormal":
            return c
        default:
            return trimmed(raw)
        }
    }

    private func normalizeDevTestResultCode(_ raw: String) -> String {
        let c = normalizeSimpleCode(raw)
        switch c {
        case "normal", "borderline", "abnormal", "pass", "fail", "suspect", "concerning":
            return c
        default:
            return trimmed(raw)
        }
    }

    /// If the value looks like an English label (e.g. "Low risk"), normalize it into a snake_case code.
    /// We only use this for matching known codes; otherwise we keep the original string.
    private func englishLabelToCodeCandidate(_ s: String) -> String {
        let t = trimmed(s)
        if t.isEmpty { return "" }
        // Only attempt if all scalars are ASCII letters/digits/spaces/underscores/hyphens.
        for u in t.unicodeScalars {
            if u.value > 127 { return t }
            let ch = Character(u)
            if !(ch.isLetter || ch.isNumber || ch == " " || ch == "_" || ch == "-") {
                return t
            }
        }
        return t
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func isKnownSleepRegularityCode(_ code: String) -> Bool {
        switch code {
        case "regular", "irregular", "uncertain":
            return true
        default:
            return false
        }
    }

    private func isKnownMCHATResultCode(_ code: String) -> Bool {
        switch code {
        case "low_risk", "medium_risk", "high_risk",
             "low", "medium", "high",
             "negative", "positive",
             "pass", "fail",
             "normal", "abnormal":
            return true
        default:
            return false
        }
    }

    private func isKnownDevTestResultCode(_ code: String) -> Bool {
        switch code {
        case "normal", "borderline", "abnormal",
             "pass", "fail",
             "suspect", "concerning",
             // legacy/alt codes we may see in older rows
             "at_risk", "delayed", "uncertain":
            return true
        default:
            return false
        }
    }

    // MARK: - PE problem-listing line helpers

    private func peField(_ labelKey: String, _ value: String) -> String {
        String(format: L("well_visit_form.problem_listing.pe.field_format"), L(labelKey), value)
    }

    private func peFieldWithDetail(_ labelKey: String, _ value: String, detail: String?) -> String {
        let d = trimmed(detail ?? "")
        if d.isEmpty {
            return peField(labelKey, value)
        }
        return String(format: L("well_visit_form.problem_listing.pe.field_with_detail_format"), L(labelKey), value, d)
    }

    private func peAbnormalField(
        _ labelKey: String,
        normal: Bool,
        comment: String,
        defaultKey: String
    ) -> String? {
        let c = trimmed(comment)
        if normal && c.isEmpty { return nil }
        let v = c.isEmpty ? L(defaultKey) : c
        return peField(labelKey, v)
    }

    private func peTextField(_ labelKey: String, text: String) -> String? {
        let t = trimmed(text)
        if t.isEmpty { return nil }
        return peField(labelKey, t)
    }

    // MARK: - PE token helpers (for localization-safe problem listing)
    private func peTextFieldToken(_ labelKey: String, text: String) -> (line: String, token: ProblemToken)? {
        let t = trimmed(text)
        if t.isEmpty { return nil }
        let line = peField(labelKey, t)
        let token = peFieldToken(labelKey, value: t, valueIsKey: false)
        return (line, token)
    }

    // Teeth: keep tokenization stable by storing the base value key + optional count + optional comment.
    // args[0] = labelKey
    // args[1] = baseValueKey (present/absent)
    // args[2] = count ("" if none)
    // args[3] = comment ("" if none)
    private func peTeethToken(countText: String, present: Bool, comment: String) -> (line: String, token: ProblemToken) {
        // Robustness: if a positive count is present, we treat "teeth present" as true
        // even if the boolean flag was never toggled (avoids generating "absent" incorrectly).
        let cntTrim = trimmed(countText)
        let countInt = Int(cntTrim) ?? 0
        let effectivePresent = present || countInt > 0

        let baseKey = effectivePresent
            ? "well_visit_form.problem_listing.pe.teeth.present"
            : "well_visit_form.problem_listing.pe.teeth.absent"

        var value = L(baseKey)
        var countArg = ""
        if countInt > 0 {
            countArg = String(countInt)
            value += " " + String(format: L("well_visit_form.problem_listing.pe.teeth.count_format"), countInt)
        }

        let c = trimmed(comment)
        let line = peFieldWithDetail(
            "well_visit_form.problem_listing.pe.label.teeth",
            value,
            detail: c.isEmpty ? nil : c
        )

        let token = ProblemToken(
            "well_visit_form.problem_listing.token.pe_teeth_v1",
            [
                "well_visit_form.problem_listing.pe.label.teeth",
                baseKey,
                countArg,
                c
            ]
        )

        return (line, token)
    }

    /// Token format (v1):
    /// args[0] = labelKey
    /// args[1] = value (either text or a localization key)
    /// args[2] = valueIsKey ("1"/"0")
    /// args[3] = detail (either text or a localization key; may be empty)
    /// args[4] = detailIsKey ("1"/"0")
    private func peFieldToken(
        _ labelKey: String,
        value: String,
        valueIsKey: Bool,
        detail: String? = nil,
        detailIsKey: Bool = false
    ) -> ProblemToken {
        ProblemToken(
            "well_visit_form.problem_listing.token.pe_field_v1",
            [
                labelKey,
                value,
                valueIsKey ? "1" : "0",
                trimmed(detail ?? ""),
                detailIsKey ? "1" : "0"
            ]
        )
    }

    private func peAbnormalFieldToken(
        _ labelKey: String,
        normal: Bool,
        comment: String,
        defaultKey: String
    ) -> (line: String, token: ProblemToken)? {
        let c = trimmed(comment)
        if normal && c.isEmpty { return nil }

        let valueTextOrKey: String
        let valueIsKey: Bool
        if c.isEmpty {
            valueTextOrKey = defaultKey
            valueIsKey = true
        } else {
            valueTextOrKey = c
            valueIsKey = false
        }

        let line: String
        if valueIsKey {
            line = peField(labelKey, L(valueTextOrKey))
        } else {
            line = peField(labelKey, valueTextOrKey)
        }

        let token = peFieldToken(
            labelKey,
            value: valueTextOrKey,
            valueIsKey: valueIsKey
        )
        return (line, token)
    }

    private func peFieldWithDetailToken(
        _ labelKey: String,
        value: String,
        valueIsKey: Bool,
        detail: String?
    ) -> (line: String, token: ProblemToken) {
        let d = trimmed(detail ?? "")
        let valueRendered = valueIsKey ? L(value) : value

        let line: String
        if d.isEmpty {
            line = peField(labelKey, valueRendered)
        } else {
            line = String(format: L("well_visit_form.problem_listing.pe.field_with_detail_format"), L(labelKey), valueRendered, d)
        }

        let token = peFieldToken(
            labelKey,
            value: value,
            valueIsKey: valueIsKey,
            detail: d,
            detailIsKey: false
        )
        return (line, token)
    }

    /// Rebuilds the problem listing from abnormal fields / comments.
    /// This does NOT touch the database – it only updates the TextEditor content.
    /// Rebuilds the problem listing from abnormal fields / comments.
    /// This does NOT touch the database – it only updates the TextEditor content.
    private func regenerateProblemListingFromFindings() {
        var lines: [String] = []
        var tokens: [ProblemToken] = []

        func add(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lines.append("• " + trimmed)
            }
        }

        func addKey(_ key: String) {
            tokens.append(ProblemToken(key))
            add(NSLocalizedString(key, comment: ""))
        }

        func addKey(_ key: String, tokenArgs: [String], formatArgs: [CVarArg]) {
            tokens.append(ProblemToken(key, tokenArgs))
            let fmt = NSLocalizedString(key, comment: "")
            add(String(format: fmt, arguments: formatArgs))
        }


        // 1) Parents' concerns
        let parentsTrim = parentsConcerns.trimmingCharacters(in: .whitespacesAndNewlines)
        if !parentsTrim.isEmpty {
            addKey(
                "well_visit_form.problem_listing.parents_concerns",
                tokenArgs: [parentsTrim],
                formatArgs: [parentsTrim]
            )
        }

        // 2) Feeding
        if isEarlyMilkOnlyVisit {
            if regurgitationPresent {
                addKey("well_visit_form.problem_listing.feeding.regurgitation")
            }

            // IMPORTANT: In early milk-only visits, clinicians may still use `feeding_comment`.
            // Include it in the problem listing when non-empty.
            let feedingTrim = feeding.trimmingCharacters(in: .whitespacesAndNewlines)
            if !feedingTrim.isEmpty {
                addKey(
                    "well_visit_form.problem_listing.feeding.diet",
                    tokenArgs: [feedingTrim],
                    formatArgs: [feedingTrim]
                )
            }

            let feedingIssueTrim = feedingIssue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !feedingIssueTrim.isEmpty {
                addKey(
                    "well_visit_form.problem_listing.feeding.difficulty",
                    tokenArgs: [feedingIssueTrim],
                    formatArgs: [feedingIssueTrim]
                )
            }
        } else {
            let feedingTrim = feeding.trimmingCharacters(in: .whitespacesAndNewlines)
            if !feedingTrim.isEmpty {
                addKey(
                    "well_visit_form.problem_listing.feeding.diet",
                    tokenArgs: [feedingTrim],
                    formatArgs: [feedingTrim]
                )
            }

            // Regurgitation can remain clinically relevant beyond early milk-only visits.
            if regurgitationPresent {
                addKey("well_visit_form.problem_listing.feeding.regurgitation")
            }

            // Add feedingIssue in non-early visits if present
            let feedingIssueTrim = feedingIssue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !feedingIssueTrim.isEmpty {
                addKey(
                    "well_visit_form.problem_listing.feeding.difficulty",
                    tokenArgs: [feedingIssueTrim],
                    formatArgs: [feedingIssueTrim]
                )
            }

            if solidFoodStarted {
                addKey("well_visit_form.problem_listing.feeding.solids_started")

                let solidsQualityRaw = solidFoodQuality.trimmingCharacters(in: .whitespacesAndNewlines)
                let solidsQualityCode = normalizeQualityCode(solidsQualityRaw)
                // Solids quality: only flag if NOT "appears_good"
                if !solidsQualityCode.isEmpty && solidsQualityCode != "appears_good" {
                    // Store the stable code in the token; render as a localized label.
                    let labelKey = "well_visit_form.shared.\(solidsQualityCode)"
                    let label = L(labelKey)
                    addKey(
                        "well_visit_form.problem_listing.feeding.solids_quality",
                        tokenArgs: [solidsQualityCode],
                        formatArgs: [label]
                    )
                }
            }

            // IMPORTANT: Always include solids comment when present, even if `solidFoodStarted` was never toggled.
            let solidsCommentTrim = solidFoodComment.trimmingCharacters(in: .whitespacesAndNewlines)
            if !solidsCommentTrim.isEmpty {
                addKey(
                    "well_visit_form.problem_listing.feeding.solids_comment",
                    tokenArgs: [solidsCommentTrim],
                    formatArgs: [solidsCommentTrim]
                )
            }

            // Food variety: only if NOT "appears_good" (stored tags are appears_good/uncertain/probably_limited)
            let foodVarietyCode = normalizeQualityCode(foodVarietyQuality)
            if !foodVarietyCode.isEmpty && foodVarietyCode != "appears_good" {
                // Store the stable code in the token; render as a localized label.
                let labelKey = "well_visit_form.shared.\(foodVarietyCode)"
                let label = L(labelKey)
                addKey(
                    "well_visit_form.problem_listing.feeding.food_variety",
                    tokenArgs: [foodVarietyCode],
                    formatArgs: [label]
                )
            }

            // Dairy intake: only if more than 3 cups (code "4")
            let dairyTrim = dairyAmountCode.trimmingCharacters(in: .whitespacesAndNewlines)
            if dairyTrim == "4" {
                addKey("well_visit_form.problem_listing.feeding.dairy_gt_3")
            }
        }

        // 2b) Stools
        let poopStatusTrim = poopStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        if poopStatusTrim == "abnormal" {
            addKey("well_visit_form.problem_listing.stools.abnormal")
        } else if poopStatusTrim == "hard" {
            addKey("well_visit_form.problem_listing.stools.hard")
        }
        let poopCommentTrim = poopComment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !poopCommentTrim.isEmpty {
            addKey(
                "well_visit_form.problem_listing.stools.comment",
                tokenArgs: [poopCommentTrim],
                formatArgs: [poopCommentTrim]
            )
        }

        // 3) Sleep
        if sleepIssueReported || !sleep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let wakesTrim = wakesForFeedsPerNight.trimmingCharacters(in: .whitespacesAndNewlines)
            if !wakesTrim.isEmpty && isPostTwelveMonthVisit {
                addKey(
                    "well_visit_form.problem_listing.sleep.wakes_per_night",
                    tokenArgs: [wakesTrim],
                    formatArgs: [wakesTrim]
                )
            }

            if isOlderSleepVisit {
                let sleepHoursTrim = sleepHoursText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sleepHoursTrim.isEmpty {
                    var shouldAddSleepDuration = false
                    let lower = sleepHoursTrim.lowercased()
                    if lower.contains("<10") || lower.contains("less than 10") {
                        shouldAddSleepDuration = true
                    } else {
                        let digits = sleepHoursTrim.filter { "0123456789.".contains($0) }
                        if let v = Double(digits), v < 10 { shouldAddSleepDuration = true }
                    }

                    if shouldAddSleepDuration {
                        addKey(
                            "well_visit_form.problem_listing.sleep.duration",
                            tokenArgs: [sleepHoursTrim],
                            formatArgs: [sleepHoursTrim]
                        )
                    }
                }

                let sleepRegularTrim = trimmed(sleepRegular)
                if !sleepRegularTrim.isEmpty {
                    let code = normalizeSleepRegularCode(sleepRegularTrim)
                    if isKnownSleepRegularityCode(code) {
                        // Store stable code; render localized label if available.
                        let label = localizedLabel(for: code, prefixes: [
                            "well_visit_form.sleep.regularity",
                            "well_visit_form.shared"
                        ])
                        addKey(
                            "well_visit_form.problem_listing.sleep.regularity",
                            tokenArgs: [code],
                            formatArgs: [label]
                        )
                    } else {
                        // Free-text / legacy value: keep literal text.
                        addKey(
                            "well_visit_form.problem_listing.sleep.regularity",
                            tokenArgs: [sleepRegularTrim],
                            formatArgs: [sleepRegularTrim]
                        )
                    }
                }

                if sleepSnoring {
                    addKey("well_visit_form.problem_listing.sleep.snoring")
                }
            }

            let sleepTrim = sleep.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sleepTrim.isEmpty {
                addKey(
                    "well_visit_form.problem_listing.sleep.issue",
                    tokenArgs: [sleepTrim],
                    formatArgs: [sleepTrim]
                )
            }
        }

        // 4) Physical exam – start migrating away from raw lines by emitting PE tokens
        if let item = peAbnormalFieldToken(
            "well_visit_form.problem_listing.pe.label.trophic_state",
            normal: peTrophicNormal,
            comment: peTrophicComment,
            defaultKey: "well_visit_form.problem_listing.pe.default_abnormal_impression"
        ) {
            tokens.append(item.token)
            add(item.line)
        }

        if let item = peAbnormalFieldToken(
            "well_visit_form.problem_listing.pe.label.hydration",
            normal: peHydrationNormal,
            comment: peHydrationComment,
            defaultKey: "well_visit_form.problem_listing.pe.default_abnormal_impression"
        ) {
            tokens.append(item.token)
            add(item.line)
        }

        if peColor != "normal" || !trimmed(peColorComment).isEmpty {
            let detail = trimmed(peColorComment).isEmpty ? nil : peColorComment

            let raw = trimmed(peColor)
            let prefixedKey = raw.isEmpty ? "" : "well_visit_form.pe.general.color.option.\(raw)"

            // Prefer a real localization key when possible; otherwise keep the raw value (legacy/free-text).
            let valueTextOrKey: String
            let valueIsKey: Bool
            if !raw.isEmpty, hasLocalization(raw) {
                valueTextOrKey = raw
                valueIsKey = true
            } else if !prefixedKey.isEmpty, hasLocalization(prefixedKey) {
                valueTextOrKey = prefixedKey
                valueIsKey = true
            } else {
                valueTextOrKey = raw.isEmpty ? "normal" : raw
                valueIsKey = false
            }

            let item = peFieldWithDetailToken(
                "well_visit_form.problem_listing.pe.label.color",
                value: valueTextOrKey,
                valueIsKey: valueIsKey,
                detail: detail
            )
            tokens.append(item.token)
            add(item.line)
        }

        if isFontanelleVisit,
           let item = peAbnormalFieldToken(
                "well_visit_form.problem_listing.pe.label.fontanelle",
                normal: peFontanelleNormal,
                comment: peFontanelleComment,
                defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
           ) {
            tokens.append(item.token)
            add(item.line)
        }

        if let item = peAbnormalFieldToken(
            "well_visit_form.problem_listing.pe.label.pupils",
            normal: pePupilsRRNormal,
            comment: pePupilsRRComment,
            defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
        ) {
            tokens.append(item.token)
            add(item.line)
        }

        if let item = peAbnormalFieldToken(
            "well_visit_form.problem_listing.pe.label.ocular_motility",
            normal: peOcularMotilityNormal,
            comment: peOcularMotilityComment,
            defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
        ) {
            tokens.append(item.token)
            add(item.line)
        }

        if let item = peAbnormalFieldToken(
            "well_visit_form.problem_listing.pe.label.tone",
            normal: peToneNormal,
            comment: peToneComment,
            defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
        ) {
            tokens.append(item.token)
            add(item.line)
        }

        if isPrimitiveNeuroVisit {
            if let item = peAbnormalFieldToken(
                "well_visit_form.problem_listing.pe.label.wakefulness",
                normal: peWakefulnessNormal,
                comment: peWakefulnessComment,
                defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
            ) {
                tokens.append(item.token)
                add(item.line)
            }
            if let item = peAbnormalFieldToken(
                "well_visit_form.problem_listing.pe.label.hands_opening",
                normal: peHandsFistNormal,
                comment: peHandsFistComment,
                defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
            ) {
                tokens.append(item.token)
                add(item.line)
            }
            if let item = peAbnormalFieldToken(
                "well_visit_form.problem_listing.pe.label.symmetry_movements",
                normal: peSymmetryNormal,
                comment: peSymmetryComment,
                defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
            ) {
                tokens.append(item.token)
                add(item.line)
            }
            if let item = peAbnormalFieldToken(
                "well_visit_form.problem_listing.pe.label.follows_midline",
                normal: peFollowsMidlineNormal,
                comment: peFollowsMidlineComment,
                defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
            ) {
                tokens.append(item.token)
                add(item.line)
            }
        }

        if isMoroVisit,
           let item = peAbnormalFieldToken(
                "well_visit_form.problem_listing.pe.label.moro_reflex",
                normal: peMoroNormal,
                comment: peMoroComment,
                defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
           ) {
            tokens.append(item.token)
            add(item.line)
        }

        if let item = peAbnormalFieldToken(
            "well_visit_form.problem_listing.pe.label.respiratory",
            normal: peBreathingNormal,
            comment: peBreathingComment,
            defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
        ) {
            tokens.append(item.token)
            add(item.line)
        }

        if let item = peAbnormalFieldToken(
            "well_visit_form.problem_listing.pe.label.cardiac",
            normal: peHeartNormal,
            comment: peHeartComment,
            defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
        ) {
            tokens.append(item.token)
            add(item.line)
        }

        if let item = peAbnormalFieldToken(
            "well_visit_form.problem_listing.pe.label.abdomen",
            normal: peAbdomenNormal,
            comment: peAbdomenComment,
            defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
        ) {
            tokens.append(item.token)
            add(item.line)
        }

        if peAbdMassPresent {
            let item = peFieldWithDetailToken(
                "well_visit_form.problem_listing.pe.label.abdomen",
                value: "well_visit_form.problem_listing.pe.abdomen.mass_palpable",
                valueIsKey: true,
                detail: nil
            )
            tokens.append(item.token)
            add(item.line)
        }

        if let item = peAbnormalFieldToken(
            "well_visit_form.problem_listing.pe.label.liver_spleen",
            normal: peLiverSpleenNormal,
            comment: peLiverSpleenComment,
            defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
        ) {
            tokens.append(item.token)
            add(item.line)
        }

        if let item = peAbnormalFieldToken(
            "well_visit_form.problem_listing.pe.label.umbilicus",
            normal: peUmbilicNormal,
            comment: peUmbilicComment,
            defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
        ) {
            tokens.append(item.token)
            add(item.line)
        }

        if let item = peTextFieldToken(
            "well_visit_form.problem_listing.pe.label.genitalia",
            text: peGenitalia
        ) {
            tokens.append(item.token)
            add(item.line)
        }

        if !peTesticlesDescended {
            let item = peFieldWithDetailToken(
                "well_visit_form.problem_listing.pe.label.testicles",
                value: "well_visit_form.problem_listing.pe.testicles.not_fully_descended",
                valueIsKey: true,
                detail: nil
            )
            tokens.append(item.token)
            add(item.line)
        }

        if let item = peAbnormalFieldToken(
            "well_visit_form.problem_listing.pe.label.femoral_pulses",
            normal: peFemoralPulsesNormal,
            comment: peFemoralPulsesComment,
            defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
        ) {
            tokens.append(item.token)
            add(item.line)
        }

        if let item = peAbnormalFieldToken(
            "well_visit_form.problem_listing.pe.label.spine_posture",
            normal: peSpineNormal,
            comment: peSpineComment,
            defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
        ) {
            tokens.append(item.token)
            add(item.line)
        }

        if isHipsVisit,
           let item = peAbnormalFieldToken(
                "well_visit_form.problem_listing.pe.label.hips_limbs",
                normal: peHipsLimbsNormal,
                comment: peHipsLimbsComment,
                defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
           ) {
            tokens.append(item.token)
            add(item.line)
        }

        if let item = peAbnormalFieldToken(
            "well_visit_form.problem_listing.pe.label.skin_marks",
            normal: peSkinMarksNormal,
            comment: peSkinMarksComment,
            defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
        ) {
            tokens.append(item.token)
            add(item.line)
        }

        if let item = peAbnormalFieldToken(
            "well_visit_form.problem_listing.pe.label.skin_integrity",
            normal: peSkinIntegrityNormal,
            comment: peSkinIntegrityComment,
            defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
        ) {
            tokens.append(item.token)
            add(item.line)
        }

        if let item = peAbnormalFieldToken(
            "well_visit_form.problem_listing.pe.label.rash_lesions",
            normal: peSkinRashNormal,
            comment: peSkinRashComment,
            defaultKey: "well_visit_form.problem_listing.pe.default_abnormal"
        ) {
            tokens.append(item.token)
            add(item.line)
        }

        if isTeethVisit {
            let cntTrim = trimmed(peTeethCount)
            let countInt = Int(cntTrim) ?? 0
            let effectivePresent = peTeethPresent || countInt > 0
            let commentTrim = trimmed(peTeethComment)

            // Flag teeth only when abnormal:
            // - Absent after 12 months
            // - Count beyond plausible primary dentition max (20)
            // - Any comment present (e.g., decay)
            let absenceAbnormal = isPostTwelveMonthVisit && !effectivePresent
            let countAbnormal = !cntTrim.isEmpty && countInt > 20
            let shouldFlagTeeth = absenceAbnormal || countAbnormal || !commentTrim.isEmpty

            if shouldFlagTeeth {
                let item = peTeethToken(
                    countText: peTeethCount,
                    present: peTeethPresent,
                    comment: peTeethComment
                )
                tokens.append(item.token)
                add(item.line)
            }
        }

        // 5) Milestones (only if some are not achieved / uncertain)
        if !currentMilestoneDescriptors.isEmpty {
            var hadAny = false

            for descriptor in currentMilestoneDescriptors {
                let code = descriptor.code
                let status = milestoneStatuses[code] ?? .uncertain
                if status == .achieved { continue }

                let noteTrim = milestoneNotes[code]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                // Stable token: (code, status rawValue, optional note)
                tokens.append(
                    ProblemToken(
                        "well_visit_form.problem_listing.token.milestone_item_v1",
                        [code, status.rawValue, noteTrim, descriptor.label]
                    )
                )

                // Render exactly as before
                var line = String(
                    format: L("well_visit_form.problem_listing.milestones.line_format"),
                    descriptor.label,
                    status.localizedDisplayName
                )

                if !noteTrim.isEmpty {
                    line = String(
                        format: L("well_visit_form.problem_listing.milestones.line_with_note_format"),
                        line,
                        noteTrim
                    )
                }

                // Insert the header once, right before the first flagged milestone
                if !hadAny {
                    addKey("well_visit_form.problem_listing.milestones.header")
                    hadAny = true
                }

                let prefixed = String(
                    format: L("well_visit_form.problem_listing.milestones.item_prefix_format"),
                    line
                )
                add(prefixed)
            }
        }

        // 6) Neurodevelopment tests
        if isMCHATVisit {
            let scoreTrim = trimmed(mchatScore)
            let resultRaw = trimmed(mchatResult)

            if !scoreTrim.isEmpty || !resultRaw.isEmpty {
                // Prefer score-derived risk code when possible so results don't go stale.
                if let derived = mchatRiskCode(from: scoreTrim) {
                    let label = localizedLabel(for: derived, prefixes: [
                        "well_visit_form.mchat.result",
                        "well_visit_form.shared"
                    ])
                    addKey(
                        "well_visit_form.problem_listing.mchat.line_format",
                        tokenArgs: [scoreTrim, derived],
                        formatArgs: [scoreTrim, label]
                    )
                } else {
                    // Otherwise prefer stable codes from the stored result; fall back to legacy/free-text.
                    let code = normalizeMchatResultCode(resultRaw)
                    if !code.isEmpty, isKnownMCHATResultCode(code) {
                        let label = localizedLabel(for: code, prefixes: [
                            "well_visit_form.mchat.result",
                            "well_visit_form.shared"
                        ])
                        addKey(
                            "well_visit_form.problem_listing.mchat.line_format",
                            tokenArgs: [scoreTrim, code],
                            formatArgs: [scoreTrim, label]
                        )
                    } else {
                        addKey(
                            "well_visit_form.problem_listing.mchat.line_format",
                            tokenArgs: [scoreTrim, resultRaw],
                            formatArgs: [scoreTrim, resultRaw]
                        )
                    }
                }
            }
        }

        if isDevTestScoreVisit || isDevTestResultVisit {
            let scoreTrim = trimmed(devTestScore)
            let resultRaw = trimmed(devTestResult)
            if !scoreTrim.isEmpty || !resultRaw.isEmpty {
                // Prefer stable codes; fall back to legacy/free-text.
                let code = normalizeDevTestResultCode(resultRaw)
                if !code.isEmpty, isKnownDevTestResultCode(code) {
                    let label = localizedLabel(for: code, prefixes: [
                        "well_visit_form.dev_test.result",
                        "well_visit_form.shared"
                    ])
                    addKey(
                        "well_visit_form.problem_listing.dev_test.line_format",
                        tokenArgs: [scoreTrim, code],
                        formatArgs: [scoreTrim, label]
                    )
                } else {
                    addKey(
                        "well_visit_form.problem_listing.dev_test.line_format",
                        tokenArgs: [scoreTrim, resultRaw],
                        formatArgs: [scoreTrim, resultRaw]
                    )
                }
            }
        }

        // 7) Free PE notes block
        if let item = peTextFieldToken(
            "well_visit_form.problem_listing.pe.label.additional_pe_notes",
            text: physicalExam
        ) {
            tokens.append(item.token)
            add(item.line)
        }

        // Weight gain – only flag if < 20 g/day (also keep token)
        if isWeightDeltaVisit, let delta = deltaWeightPerDayValue, delta < 20 {
            addKey(
                "well_visit_form.problem_listing.weight_gain.suboptimal",
                tokenArgs: ["\(Int(delta))"],
                formatArgs: [Int(delta)]
            )
        }

        // Save both outputs
        problemListingTokens = tokens
        problemListing = lines.joined(separator: "\n")
    }
    
    // MARK: - AI helpers (well visits)

    // MARK: - Manual growth helpers (for AI context)

    private struct ManualGrowthSnapshot {
        let recordedAtRaw: String
        let weightKg: Double?
        let heightCm: Double?
        let headCircCm: Double?
    }

    /// Query manual growth rows around the current `visitDate`.
    ///
    /// IMPORTANT: We intentionally exclude any vitals-mirrored rows (`source` LIKE 'vitals%').
    ///
    /// Returns rows in chronological order (ASC).
    private func fetchManualGrowthSeriesForAI(
        dbURL: URL,
        patientID: Int,
        lookbackDays: Int = 365,
        forwardDays: Int = 3,
        limit: Int = 6
    ) -> [ManualGrowthSnapshot] {

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            return []
        }
        defer { sqlite3_close(db) }

        let visitISO = Self.isoDateOnly.string(from: visitDate)
        let lowerMod = "-\(lookbackDays) day"
        let upperMod = "+\(forwardDays) day"

        let sql = """
        SELECT recorded_at, weight_kg, height_cm, head_circumference_cm
        FROM manual_growth
        WHERE patient_id = ?
          AND COALESCE(source,'manual') NOT LIKE 'vitals%'
          AND date(recorded_at) >= date(?, ?)
          AND date(recorded_at) <= date(?, ?)
        ORDER BY datetime(recorded_at) ASC
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))
        _ = visitISO.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
        _ = lowerMod.withCString { sqlite3_bind_text(stmt, 3, $0, -1, SQLITE_TRANSIENT) }
        _ = visitISO.withCString { sqlite3_bind_text(stmt, 4, $0, -1, SQLITE_TRANSIENT) }
        _ = upperMod.withCString { sqlite3_bind_text(stmt, 5, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 6, Int32(limit))

        func colDoubleOrNil(_ idx: Int32) -> Double? {
            if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return nil }
            return sqlite3_column_double(stmt, idx)
        }

        var out: [ManualGrowthSnapshot] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let recordedAt: String = {
                guard let cStr = sqlite3_column_text(stmt, 0) else { return "" }
                return String(cString: cStr)
            }()
            let recTrim = recordedAt.trimmingCharacters(in: .whitespacesAndNewlines)
            if recTrim.isEmpty { continue }

            let w  = colDoubleOrNil(1)
            let h  = colDoubleOrNil(2)
            let hc = colDoubleOrNil(3)

            // Skip rows with no measurements at all.
            if w == nil && h == nil && hc == nil { continue }

            out.append(
                ManualGrowthSnapshot(
                    recordedAtRaw: recTrim,
                    weightKg: w,
                    heightCm: h,
                    headCircCm: hc
                )
            )
        }

        return out
    }

    /// Formats a compact growth timeline block for AI context.
    /// Intentionally plain (English) and compact.
    private func manualGrowthTrendBlockForAI(
        _ series: [ManualGrowthSnapshot],
        lookbackDays: Int,
        forwardDays: Int
    ) -> String {
        func fmt(_ v: Double?, decimals: Int) -> String {
            guard let v else { return "—" }
            return String(format: "%0.*f", decimals, v)
        }

        let header = "Growth near visit (manual_growth window -\(lookbackDays)d..+\(forwardDays)d):"
        let lines = series.map { p in
            "• \(p.recordedAtRaw): wt \(fmt(p.weightKg, decimals: 2)) kg; len \(fmt(p.heightCm, decimals: 1)) cm; HC \(fmt(p.headCircCm, decimals: 1)) cm"
        }

        return ([header] + lines).joined(separator: "\n")
    }

    /// Single entry-point used by `buildWellVisitAIContext()`.
    /// Returns an updated problem string with a growth block appended (when available).
    private func appendManualGrowthBlockForAI(
        baseProblems: String,
        dbURL: URL,
        patientID: Int,
        lookbackDays: Int = 365,
        forwardDays: Int = 3,
        limit: Int = 6
    ) -> String {
        let series = fetchManualGrowthSeriesForAI(
            dbURL: dbURL,
            patientID: patientID,
            lookbackDays: lookbackDays,
            forwardDays: forwardDays,
            limit: limit
        )

        guard !series.isEmpty else { return baseProblems }

        let block = manualGrowthTrendBlockForAI(series, lookbackDays: lookbackDays, forwardDays: forwardDays)
        return baseProblems.isEmpty ? block : (baseProblems + "\n" + block)
    }

    /// Fetch a manual growth entry that best matches the current `visitDate`.
    ///
    /// Strategy:
    /// 1) Prefer the closest record within a small window around the visit date (±3 days)
    ///    so same-day (or near) measurements are used even if a later measurement exists.
    /// 2) If nothing exists in the window, fall back to the most recent record on or before
    ///    the visit date.
    ///
    /// Uses `date(recorded_at)` so it works whether `recorded_at` is date-only or datetime.
    private func fetchManualGrowthSnapshot(dbURL: URL, patientID: Int) -> ManualGrowthSnapshot? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = db else {
            return nil
        }
        defer { sqlite3_close(db) }

        let visitISO = Self.isoDateOnly.string(from: visitDate)
        let windowDays: Int32 = 3

        func colDoubleOrNil(_ stmt: OpaquePointer?, _ idx: Int32) -> Double? {
            guard let stmt else { return nil }
            if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return nil }
            return sqlite3_column_double(stmt, idx)
        }

        func runQuery(_ sql: String, bind: (_ stmt: OpaquePointer) -> Void) -> ManualGrowthSnapshot? {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }

            bind(stmt)

            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

            let recordedAt: String = {
                guard let cStr = sqlite3_column_text(stmt, 0) else { return "" }
                return String(cString: cStr)
            }()
            if recordedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }

            let w  = colDoubleOrNil(stmt, 1)
            let h  = colDoubleOrNil(stmt, 2)
            let hc = colDoubleOrNil(stmt, 3)

            // If everything is nil, don't bother.
            if w == nil && h == nil && hc == nil { return nil }

            return ManualGrowthSnapshot(
                recordedAtRaw: recordedAt,
                weightKg: w,
                heightCm: h,
                headCircCm: hc
            )
        }

        // 1) Prefer the closest measurement within ±3 days of the visit date.
        let closestSQL = """
        SELECT recorded_at, weight_kg, height_cm, head_circumference_cm
        FROM manual_growth
        WHERE patient_id = ?
          AND COALESCE(source,'manual') NOT LIKE 'vitals%'
          AND abs(julianday(date(recorded_at)) - julianday(date(?))) <= ?
        ORDER BY abs(julianday(date(recorded_at)) - julianday(date(?))) ASC,
                 datetime(recorded_at) DESC
        LIMIT 1;
        """

        if let snap = runQuery(closestSQL) { stmt in
            sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))
            _ = visitISO.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int(stmt, 3, windowDays)
            _ = visitISO.withCString { sqlite3_bind_text(stmt, 4, $0, -1, SQLITE_TRANSIENT) }
        } {
            return snap
        }

        // 2) Fallback: most recent record on or before the visit date.
        let fallbackSQL = """
        SELECT recorded_at, weight_kg, height_cm, head_circumference_cm
        FROM manual_growth
        WHERE patient_id = ?
          AND COALESCE(source,'manual') NOT LIKE 'vitals%'
          AND date(recorded_at) <= date(?)
        ORDER BY datetime(recorded_at) DESC
        LIMIT 1;
        """

        return runQuery(fallbackSQL) { stmt in
            sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))
            _ = visitISO.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
        }
    }

    /// Formats a compact, AI-friendly line that we append into the well-visit AI problem listing.
    private func manualGrowthLineForAI(_ snap: ManualGrowthSnapshot) -> String {
        func fmt(_ v: Double?, decimals: Int = 1) -> String {
            guard let v else { return "—" }
            return String(format: "%0.*f", decimals, v)
        }

        // Keep this intentionally plain (English) since it's AI-context only.
        return "Growth near visit (manual_growth @ \(snap.recordedAtRaw)): weight \(fmt(snap.weightKg, decimals: 2)) kg; length \(fmt(snap.heightCm, decimals: 1)) cm; HC \(fmt(snap.headCircCm, decimals: 1)) cm"
    }

    /// Fetch patient's recorded sex from the bundle DB (best effort).
    ///
    /// We keep this intentionally lightweight (single-column query), mirroring the SickEpisodeForm approach.
    /// Returned values can vary depending on legacy data; `normalizePatientSexForWHO(_:)` collapses
    /// common forms to "M" / "F".
    private func fetchPatientSexRaw(dbURL: URL, patientID: Int) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = db else {
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT sex FROM patients WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        let raw = String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    /// Normalize patient sex string into a stable "M" / "F" code for WHO lookups.
    /// Returns nil when unknown/empty.
    private func normalizePatientSexForWHO(_ raw: String?) -> String? {
        let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        let lower = t.lowercased()
        if lower == "m" || lower == "male" || lower == "man" || lower == "boy" || lower == "garçon" || lower == "garcon" {
            return "M"
        }
        if lower == "f" || lower == "female" || lower == "woman" || lower == "girl" || lower == "fille" {
            return "F"
        }

        // Some legacy schemas store sex as numeric strings.
        // We avoid being too clever; only map obvious cases.
        if lower == "1" { return "M" }
        if lower == "2" { return "F" }

        return nil
    }

    /// Convert the patient's recorded sex into the app's `ReportGrowth.Sex` enum for WHO lookups.
    /// Returns nil when unknown.
    private func fetchPatientSexForWHOEnum(dbURL: URL, patientID: Int) -> ReportGrowth.Sex? {
        let raw = fetchPatientSexRaw(dbURL: dbURL, patientID: patientID)
        guard let code = normalizePatientSexForWHO(raw) else { return nil }
        return (code == "M") ? .male : .female
    }

    /// Fetch patient's DOB from the bundle DB (best effort) so we can compute age at the visit.
    private func fetchPatientDOBDate(dbURL: URL, patientID: Int) -> Date? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = db else {
            return nil
        }
        defer { sqlite3_close(db) }

        func runDOBQuery(_ column: String) -> String? {
            let sql = "SELECT \(column) FROM patients WHERE id = ? LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: cStr)
        }

        // Try common DOB column names.
        let raw = runDOBQuery("dob") ?? runDOBQuery("date_of_birth")
        let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        // Prefer date-only parsing (YYYY-MM-DD). If the DB stores a datetime, take the first 10 chars.
        let prefix10 = String(t.prefix(10))
        if let d = Self.isoDateOnly.date(from: prefix10) {
            return d
        }

        // Fallback: attempt ISO8601 parsing.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: t) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: t) { return d }

        return nil
    }

    /// Compute age in days from DOB to the current `visitDate` (best effort).
    private func computeAgeDaysForVisit(patientID: Int) -> Int? {
        guard let dbURL = appState.currentDBURL,
              let dob = fetchPatientDOBDate(dbURL: dbURL, patientID: patientID) else {
            return nil
        }
        let days = Calendar.current.dateComponents([.day], from: dob, to: visitDate).day
        guard let d = days else { return nil }
        return max(0, d)
    }

    /// Build the AI context for the current well visit, mirroring the sick-episode flow.
    /// For now we only allow AI when editing an existing saved visit.
    private func buildWellVisitAIContext() -> AppState.WellVisitAIContext? {
        guard let patientID = appState.selectedPatientID,
              let visitID = editingVisitID else {
            return nil
        }

        func cleaned(_ text: String?) -> String? {
            guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !t.isEmpty else {
                return nil
            }
            return t
        }

        let trimmedProblems = problemListing.trimmingCharacters(in: .whitespacesAndNewlines)

        // Add contemporaneous growth values (if available) so AI can interpret the visit.
        var problemsForAI = trimmedProblems
        if let dbURL = appState.currentDBURL {
            problemsForAI = appendManualGrowthBlockForAI(
                baseProblems: problemsForAI,
                dbURL: dbURL,
                patientID: patientID
            )
        }

        let perinatalSummary = cleaned(appState.perinatalSummaryForSelectedPatient())
        let pmhSummary       = cleaned(appState.pmhSummaryForSelectedPatient())
        let vaccSummary      = cleaned(appState.vaccinationSummaryForSelectedPatient())

        let ageDays = computeAgeDaysForVisit(patientID: patientID)

        return AppState.WellVisitAIContext(
            patientID: patientID,
            wellVisitID: visitID,
            visitType: visitTypeID,
            ageDays: ageDays,
            problemListing: problemsForAI,
            perinatalSummary: perinatalSummary,
            pmhSummary: pmhSummary,
            vaccinationStatus: vaccSummary
        )
    }
    
    /// Trigger the AI call via AppState using the current well-visit context.
    /// Mirrors `triggerAIForEpisode()` on the sick side.
    private func triggerAIForWellVisit() {
        guard let ctx = buildWellVisitAIContext() else {
            appState.aiSummariesForActiveWellVisit = [
                "local-stub": NSLocalizedString("well_visit_form.ai.cannot_run", comment: "")
            ]
            return
        }

        aiIsRunning = true
        appState.runAIForWellVisit(using: ctx)
        aiIsRunning = false
    }
    
    // MARK: - Save logic

    private func saveTapped() {
        guard let dbURL = appState.currentDBURL else {
        AppLog.db.error("WellVisitForm: saveTapped ABORT | reason=no_active_bundle")
                showError(NSLocalizedString("well_visit_form.error.no_active_bundle", comment: ""))
            return
        }
        guard let patientID = appState.selectedPatientID else {
        AppLog.db.error("WellVisitForm: saveTapped ABORT | reason=no_patient_selected")
                showError(NSLocalizedString("well_visit_form.error.no_patient_selected", comment: ""))
            return
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        AppLog.db.info("WellVisitForm: saveTapped start | pid=\(logOptInt(appState.selectedPatientID), privacy: .public) visitID=\(logOptInt(editingVisitID), privacy: .public)")
        
        
        ensureBundleUserRowIfNeeded(dbURL: dbURL)

        var db: OpaquePointer?
        let openRC = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil)

        if openRC != SQLITE_OK || db == nil {
            let msg: String = {
                if let db = db { return String(cString: sqlite3_errmsg(db)) }
                return "rc=\(openRC)"
            }()
            AppLog.db.error("WellVisitForm: saveTapped ABORT | reason=could_not_open_db | msg=\(msg, privacy: .private)")
            if let db = db { sqlite3_close(db) }
            showError(NSLocalizedString("well_visit_form.error.could_not_open_db", comment: ""))
            return
        }

        guard let db = db else {
            AppLog.db.error("WellVisitForm: saveTapped ABORT | reason=could_not_open_db | msg=nil_db_after_open")
            showError(NSLocalizedString("well_visit_form.error.could_not_open_db", comment: ""))
            return
        }
        defer { sqlite3_close(db) }
        ensureProblemListingTokensColumn(db: db)

        let dateISO        = Self.isoDateOnly.string(from: visitDate)
        let type           = visitTypeID
        let parents        = parentsConcerns
        let feedingText    = feeding

        let wakesTrim      = wakesForFeedsPerNight.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawSleepText   = sleep
        let sleepText: String = {
            let sleepTrim = rawSleepText.trimmingCharacters(in: .whitespacesAndNewlines)
            if wakesTrim.isEmpty {
                // No structured wakes-per-night info: store plain text
                return rawSleepText
            } else if sleepTrim.isEmpty {
                // Only wakes-per-night value
                return "wakes_per_night=\(wakesTrim)"
            } else {
                // Structured prefix + free-text details (backwards compatible)
                return "wakes_per_night=\(wakesTrim)\n\(rawSleepText)"
            }
        }()

        let probs          = problemListing
        let probsTokens    = encodeProblemTokensForDB(problemListingTokens)
        let concl          = conclusions
        let planText       = plan
        let clinicianText  = clinicianComment
        let peText         = physicalExam
        let vitInt         = vitaminDGiven ? 1 : 0
        let nextVisitISO: String? = hasNextVisitDate
            ? Self.isoDateOnly.string(from: nextVisitDate)
            : nil

        let trimmedMchatScore = mchatScore.trimmingCharacters(in: .whitespacesAndNewlines)
        let mchatScoreInt = Int32(trimmedMchatScore.isEmpty ? "0" : trimmedMchatScore) ?? 0
        let mchatResultText = normalizeMchatResultCode(mchatResult)

        let trimmedDevScore = devTestScore.trimmingCharacters(in: .whitespacesAndNewlines)
        let devTestScoreInt = Int32(trimmedDevScore.isEmpty ? "0" : trimmedDevScore) ?? 0
        let devTestResultText = normalizeDevTestResultCode(devTestResult)
        let deltaWeightDB: Int32? = deltaWeightPerDayValue

        let sleepHoursDB = sleepHoursText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sleepRegularDB = normalizeSleepRegularCode(sleepRegular)
        let sleepSnoringDB: Int32 = sleepSnoring ? 1 : 0
        let longerSleepNightDB: Int32 = longerSleepAtNight ? 1 : 0
        let sleepIssueReportedDB: Int32 = sleepIssueReported ? 1 : 0

        // Feeding-related DB fields
        let poopStatusDB  = normalizePoopStatusCode(poopStatus)
        let poopCommentDB = poopComment.trimmingCharacters(in: .whitespacesAndNewlines)

        let milkTypesDB: String = {
            switch (milkTypeBreast, milkTypeFormula) {
            case (true, true):   return "both"
            case (true, false):  return "breast"
            case (false, true):  return "formula"
            default:             return ""
            }
        }()

        let feedVolumeDB: Double? = {
            let trimmed = feedVolumeMl.trimmingCharacters(in: .whitespacesAndNewlines)
            if let v = Double(trimmed), v > 0 {
                return v
            }
            return nil
        }()

        let feedFreqDB: Int32? = {
            let trimmed = feedFreqPer24h.trimmingCharacters(in: .whitespacesAndNewlines)
            if let v = Int32(trimmed), v > 0 {
                return v
            }
            return nil
        }()

        let regurgitationDB: Int32 = regurgitationPresent ? 1 : 0
        let feedingIssueDB = feedingIssue.trimmingCharacters(in: .whitespacesAndNewlines)

        let solidStartedDB: Int32 = solidFoodStarted ? 1 : 0
        let solidStartDateISO: String? = solidFoodStarted
            ? Self.isoDateOnly.string(from: solidFoodStartDate)
            : nil
        let solidQualityDB  = normalizeQualityCode(solidFoodQuality)
        let solidCommentDB  = solidFoodComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let foodVarietyDB   = normalizeQualityCode(foodVarietyQuality)

        // Overloaded dairy_amount_text column:
        // if a structured dairy code is set (1–4), store that;
        // otherwise store the free-text supplementation (backwards compatible).
        let dairyAmountDB: String = {
            let dairyTrim = dairyAmountCode.trimmingCharacters(in: .whitespacesAndNewlines)
            let suppTrim  = supplementation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !dairyTrim.isEmpty {
                return dairyTrim
            } else {
                return suppTrim
            }
        }()

        var visitID: Int = editingVisitID ?? -1

        if editingVisitID == nil {
            // INSERT new well_visits row
            let sql = """
            INSERT INTO well_visits (
                patient_id,
                visit_date,
                visit_type,
                parent_concerns,
                feeding_comment,
                sleep_issue_text,
                problem_listing,
                problem_listing_tokens,
                conclusions,
                anticipatory_guidance,
                next_visit_date,
                comments,
                lab_text,
                vitamin_d_given,
                dairy_amount_text,
                poop_status,
                poop_comment,
                milk_types,
                feed_volume_ml,
                feed_freq_per_24h,
                regurgitation,
                feeding_issue,
                solid_food_started,
                solid_food_start_date,
                solid_food_quality,
                solid_food_comment,
                food_variety_quality,
                sleep_hours_text,
                sleep_regular,
                longer_sleep_night,
                sleep_snoring,
                sleep_issue_reported,
                mchat_score,
                mchat_result,
                devtest_score,
                devtest_result,
                delta_weight_g,
                user_id,
                created_at,
                updated_at
            ) VALUES (
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, ?, ?,
                CURRENT_TIMESTAMP,CURRENT_TIMESTAMP
            );
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                let errMsg = String(cString: sqlite3_errmsg(db))
                showError(
                    String(
                        format: NSLocalizedString("well_visit_form.error.failed_prepare_insert", comment: ""),
                        errMsg
                    )
                )
                return
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))
            _ = dateISO.withCString         { sqlite3_bind_text(stmt, 2,  $0, -1, SQLITE_TRANSIENT) }
            _ = type.withCString            { sqlite3_bind_text(stmt, 3,  $0, -1, SQLITE_TRANSIENT) }
            _ = parents.withCString         { sqlite3_bind_text(stmt, 4,  $0, -1, SQLITE_TRANSIENT) }
            _ = feedingText.withCString     { sqlite3_bind_text(stmt, 5,  $0, -1, SQLITE_TRANSIENT) }
            _ = sleepText.withCString       { sqlite3_bind_text(stmt, 6,  $0, -1, SQLITE_TRANSIENT) }
            _ = probs.withCString           { sqlite3_bind_text(stmt, 7,  $0, -1, SQLITE_TRANSIENT) }
            _ = probsTokens.withCString     { sqlite3_bind_text(stmt, 8,  $0, -1, SQLITE_TRANSIENT) }
            _ = concl.withCString           { sqlite3_bind_text(stmt, 9,  $0, -1, SQLITE_TRANSIENT) }
            _ = planText.withCString        { sqlite3_bind_text(stmt, 10,  $0, -1, SQLITE_TRANSIENT) }
            if let nv = nextVisitISO {
                _ = nv.withCString          { sqlite3_bind_text(stmt, 11, $0, -1, SQLITE_TRANSIENT) }
            } else {
                sqlite3_bind_null(stmt, 11)
            }
            _ = clinicianText.withCString   { sqlite3_bind_text(stmt, 12, $0, -1, SQLITE_TRANSIENT) }
            _ = peText.withCString          { sqlite3_bind_text(stmt, 13, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int(stmt, 14, Int32(vitInt))
            _ = dairyAmountDB.withCString   { sqlite3_bind_text(stmt, 15, $0, -1, SQLITE_TRANSIENT) }
            _ = poopStatusDB.withCString    { sqlite3_bind_text(stmt, 16, $0, -1, SQLITE_TRANSIENT) }
            _ = poopCommentDB.withCString   { sqlite3_bind_text(stmt, 17, $0, -1, SQLITE_TRANSIENT) }
            _ = milkTypesDB.withCString     { sqlite3_bind_text(stmt, 18, $0, -1, SQLITE_TRANSIENT) }

            if let vol = feedVolumeDB {
                sqlite3_bind_double(stmt, 19, vol)
            } else {
                sqlite3_bind_null(stmt, 19)
            }

            if let freq = feedFreqDB {
                sqlite3_bind_int(stmt, 20, freq)
            } else {
                sqlite3_bind_null(stmt, 20)
            }

            sqlite3_bind_int(stmt, 21, regurgitationDB)
            _ = feedingIssueDB.withCString  { sqlite3_bind_text(stmt, 22, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int(stmt, 23, solidStartedDB)

            if let solidsISO = solidStartDateISO {
                _ = solidsISO.withCString   { sqlite3_bind_text(stmt, 24, $0, -1, SQLITE_TRANSIENT) }
            } else {
                sqlite3_bind_null(stmt, 24)
            }

            _ = solidQualityDB.withCString  { sqlite3_bind_text(stmt, 25, $0, -1, SQLITE_TRANSIENT) }
            _ = solidCommentDB.withCString  { sqlite3_bind_text(stmt, 26, $0, -1, SQLITE_TRANSIENT) }
            _ = foodVarietyDB.withCString   { sqlite3_bind_text(stmt, 27, $0, -1, SQLITE_TRANSIENT) }

            _ = sleepHoursDB.withCString    { sqlite3_bind_text(stmt, 28, $0, -1, SQLITE_TRANSIENT) }
            _ = sleepRegularDB.withCString  { sqlite3_bind_text(stmt, 29, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int(stmt, 30, longerSleepNightDB)
            sqlite3_bind_int(stmt, 31, sleepSnoringDB)
            sqlite3_bind_int(stmt, 32, sleepIssueReportedDB)

            sqlite3_bind_int(stmt, 33, mchatScoreInt)
            _ = mchatResultText.withCString { sqlite3_bind_text(stmt, 34, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int(stmt, 35, devTestScoreInt)
            _ = devTestResultText.withCString {
                sqlite3_bind_text(stmt, 36, $0, -1, SQLITE_TRANSIENT)
            }
            
            if let delta = deltaWeightDB {
                sqlite3_bind_int(stmt, 37, delta)
            } else {
                sqlite3_bind_null(stmt, 37)
            }

            // Bind user_id at index 38
            if let uid = appState.activeUserID {
                sqlite3_bind_int64(stmt, 38, sqlite3_int64(uid))
            } else {
                sqlite3_bind_null(stmt, 38)
            }

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                showError(NSLocalizedString("well_visit_form.error.failed_insert", comment: ""))
                return
            }

            let rowChanges = sqlite3_changes(db)
            visitID = Int(sqlite3_last_insert_rowid(db))
            AppLog.db.notice(
                "WellVisitForm: saveTapped success (INSERT) | pid=\(logOptInt(appState.selectedPatientID), privacy: .public) visitID=\(visitID, privacy: .public) changes=\(rowChanges, privacy: .public)"
            )

            // Save physical exam structured fields
            savePhysicalExamColumns(db: db, visitID: visitID)
        } else {
            // UPDATE existing well_visits row
            let sql = """
            UPDATE well_visits
            SET visit_date = ?,
                visit_type = ?,
                parent_concerns = ?,
                feeding_comment = ?,
                sleep_issue_text = ?,
                problem_listing = ?,
                problem_listing_tokens = ?,
                conclusions = ?,
                anticipatory_guidance = ?,
                next_visit_date = ?,
                comments = ?,
                lab_text = ?,
                vitamin_d_given = ?,
                dairy_amount_text = ?,
                poop_status = ?,
                poop_comment = ?,
                milk_types = ?,
                feed_volume_ml = ?,
                feed_freq_per_24h = ?,
                regurgitation = ?,
                feeding_issue = ?,
                solid_food_started = ?,
                solid_food_start_date = ?,
                solid_food_quality = ?,
                solid_food_comment = ?,
                food_variety_quality = ?,
                sleep_hours_text = ?,
                sleep_regular = ?,
                longer_sleep_night = ?,
                sleep_snoring = ?,
                sleep_issue_reported = ?,
                mchat_score = ?,
                mchat_result = ?,
                devtest_score = ?,
                devtest_result = ?,
                delta_weight_g = ?,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = ?;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                let errMsg = String(cString: sqlite3_errmsg(db))
                showError(
                    String(
                        format: NSLocalizedString("well_visit_form.error.failed_prepare_update", comment: ""),
                        errMsg
                    )
                )
                return
            }
            defer { sqlite3_finalize(stmt) }

            _ = dateISO.withCString         { sqlite3_bind_text(stmt, 1,  $0, -1, SQLITE_TRANSIENT) }
            _ = type.withCString            { sqlite3_bind_text(stmt, 2,  $0, -1, SQLITE_TRANSIENT) }
            _ = parents.withCString         { sqlite3_bind_text(stmt, 3,  $0, -1, SQLITE_TRANSIENT) }
            _ = feedingText.withCString     { sqlite3_bind_text(stmt, 4,  $0, -1, SQLITE_TRANSIENT) }
            _ = sleepText.withCString       { sqlite3_bind_text(stmt, 5,  $0, -1, SQLITE_TRANSIENT) }
            _ = probs.withCString           { sqlite3_bind_text(stmt, 6,  $0, -1, SQLITE_TRANSIENT) }
            _ = probsTokens.withCString     { sqlite3_bind_text(stmt, 7,  $0, -1, SQLITE_TRANSIENT) }
            _ = concl.withCString           { sqlite3_bind_text(stmt, 8,  $0, -1, SQLITE_TRANSIENT) }
            _ = planText.withCString        { sqlite3_bind_text(stmt, 9,  $0, -1, SQLITE_TRANSIENT) }
            if let nv = nextVisitISO {
                _ = nv.withCString          { sqlite3_bind_text(stmt, 10,  $0, -1, SQLITE_TRANSIENT) }
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            _ = clinicianText.withCString   { sqlite3_bind_text(stmt, 11, $0, -1, SQLITE_TRANSIENT) }
            _ = peText.withCString          { sqlite3_bind_text(stmt, 12, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int(stmt, 13, Int32(vitInt))
            _ = dairyAmountDB.withCString   { sqlite3_bind_text(stmt, 14, $0, -1, SQLITE_TRANSIENT) }
            _ = poopStatusDB.withCString    { sqlite3_bind_text(stmt, 15, $0, -1, SQLITE_TRANSIENT) }
            _ = poopCommentDB.withCString   { sqlite3_bind_text(stmt, 16, $0, -1, SQLITE_TRANSIENT) }
            _ = milkTypesDB.withCString     { sqlite3_bind_text(stmt, 17, $0, -1, SQLITE_TRANSIENT) }

            if let vol = feedVolumeDB {
                sqlite3_bind_double(stmt, 18, vol)
            } else {
                sqlite3_bind_null(stmt, 18)
            }

            if let freq = feedFreqDB {
                sqlite3_bind_int(stmt, 19, freq)
            } else {
                sqlite3_bind_null(stmt, 19)
            }

            sqlite3_bind_int(stmt, 20, regurgitationDB)
            _ = feedingIssueDB.withCString  { sqlite3_bind_text(stmt, 21, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int(stmt, 22, solidStartedDB)

            if let solidsISO = solidStartDateISO {
                _ = solidsISO.withCString   { sqlite3_bind_text(stmt, 23, $0, -1, SQLITE_TRANSIENT) }
            } else {
                sqlite3_bind_null(stmt, 23)
            }

            _ = solidQualityDB.withCString  { sqlite3_bind_text(stmt, 24, $0, -1, SQLITE_TRANSIENT) }
            _ = solidCommentDB.withCString  { sqlite3_bind_text(stmt, 25, $0, -1, SQLITE_TRANSIENT) }
            _ = foodVarietyDB.withCString   { sqlite3_bind_text(stmt, 26, $0, -1, SQLITE_TRANSIENT) }

            _ = sleepHoursDB.withCString    { sqlite3_bind_text(stmt, 27, $0, -1, SQLITE_TRANSIENT) }
            _ = sleepRegularDB.withCString  { sqlite3_bind_text(stmt, 28, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int(stmt, 29, longerSleepNightDB)
            sqlite3_bind_int(stmt, 30, sleepSnoringDB)
            sqlite3_bind_int(stmt, 31, sleepIssueReportedDB)

            sqlite3_bind_int(stmt, 32, mchatScoreInt)
            _ = mchatResultText.withCString { sqlite3_bind_text(stmt, 33, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int(stmt, 34, devTestScoreInt)
            _ = devTestResultText.withCString {
                sqlite3_bind_text(stmt, 35, $0, -1, SQLITE_TRANSIENT)
            }
            if let delta = deltaWeightDB {
                sqlite3_bind_int(stmt, 36, delta)
            } else {
                sqlite3_bind_null(stmt, 36)
            }

            sqlite3_bind_int64(stmt, 37, sqlite3_int64(visitID))

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                showError(NSLocalizedString("well_visit_form.error.failed_update", comment: ""))
                return
            }
            let rowChanges = sqlite3_changes(db)
            AppLog.db.notice(
                "WellVisitForm: saveTapped success (UPDATE) | pid=\(logOptInt(appState.selectedPatientID), privacy: .public) visitID=\(visitID, privacy: .public) changes=\(rowChanges, privacy: .public)"
            )
            // Save physical exam structured fields
            savePhysicalExamColumns(db: db, visitID: visitID)
        }

        // Save milestones for this visit (delete old, insert new)
        saveMilestones(db: db, visitID: visitID)
        
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000.0)
        AppLog.db.notice("WellVisitForm: saveTapped done | mode=\(editingVisitID == nil ? "INSERT" : "UPDATE", privacy: .public) pid=\(String(describing: patientID), privacy: .public) visitID=\(visitID, privacy: .public) ms=\(elapsedMs, privacy: .public)")

        AppLog.ui.info("WellVisitForm: requesting reloadVisitsForSelectedPatient (after save) | pid=\(String(describing: patientID), privacy: .public)")
        appState.reloadVisitsForSelectedPatient()
        dismiss()
    }

    private func savePhysicalExamColumns(db: OpaquePointer, visitID: Int) {
        
        AppLog.db.debug("WellVisitForm: savePhysicalExamColumns start | visitID=\(visitID, privacy: .public)")
        let peTrophicNormalDB: Int32       = peTrophicNormal ? 1 : 0
        let peTrophicCommentDB             = peTrophicComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peHydrationNormalDB: Int32     = peHydrationNormal ? 1 : 0
        let peHydrationCommentDB           = peHydrationComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peColorDB                      = peColor.trimmingCharacters(in: .whitespacesAndNewlines)
        let peColorCommentDB               = peColorComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peFontanelleNormalDB: Int32    = peFontanelleNormal ? 1 : 0
        let peFontanelleCommentDB          = peFontanelleComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let pePupilsRRNormalDB: Int32      = pePupilsRRNormal ? 1 : 0
        let pePupilsRRCommentDB            = pePupilsRRComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peOcularMotilityNormalDB: Int32 = peOcularMotilityNormal ? 1 : 0
        let peOcularMotilityCommentDB      = peOcularMotilityComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peToneNormalDB: Int32          = peToneNormal ? 1 : 0
        let peToneCommentDB                = peToneComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peWakefulnessNormalDB: Int32   = peWakefulnessNormal ? 1 : 0
        let peWakefulnessCommentDB         = peWakefulnessComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peMoroNormalDB: Int32          = peMoroNormal ? 1 : 0
        let peMoroCommentDB                = peMoroComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peHandsFistNormalDB: Int32     = peHandsFistNormal ? 1 : 0
        let peHandsFistCommentDB           = peHandsFistComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peSymmetryNormalDB: Int32      = peSymmetryNormal ? 1 : 0
        let peSymmetryCommentDB            = peSymmetryComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peFollowsMidlineNormalDB: Int32 = peFollowsMidlineNormal ? 1 : 0
        let peFollowsMidlineCommentDB      = peFollowsMidlineComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peBreathingNormalDB: Int32     = peBreathingNormal ? 1 : 0
        let peBreathingCommentDB           = peBreathingComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peHeartNormalDB: Int32         = peHeartNormal ? 1 : 0
        let peHeartCommentDB               = peHeartComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peAbdMassDB: Int32             = peAbdMassPresent ? 1 : 0
        let peGenitaliaDB                  = peGenitalia.trimmingCharacters(in: .whitespacesAndNewlines)
        let peTesticlesDescendedDB: Int32  = peTesticlesDescended ? 1 : 0
        let peFemoralPulsesNormalDB: Int32 = peFemoralPulsesNormal ? 1 : 0
        let peFemoralPulsesCommentDB       = peFemoralPulsesComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peLiverSpleenNormalDB: Int32   = peLiverSpleenNormal ? 1 : 0
        let peLiverSpleenCommentDB         = peLiverSpleenComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peUmbilicNormalDB: Int32       = peUmbilicNormal ? 1 : 0
        let peUmbilicCommentDB             = peUmbilicComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peSpineNormalDB: Int32         = peSpineNormal ? 1 : 0
        let peSpineCommentDB               = peSpineComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peHipsLimbsNormalDB: Int32     = peHipsLimbsNormal ? 1 : 0
        let peHipsLimbsCommentDB           = peHipsLimbsComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peSkinMarksNormalDB: Int32     = peSkinMarksNormal ? 1 : 0
        let peSkinMarksCommentDB           = peSkinMarksComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peSkinIntegrityNormalDB: Int32 = peSkinIntegrityNormal ? 1 : 0
        let peSkinIntegrityCommentDB       = peSkinIntegrityComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peSkinRashNormalDB: Int32      = peSkinRashNormal ? 1 : 0
        let peSkinRashCommentDB            = peSkinRashComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let peTeethCountTrim             = peTeethCount.trimmingCharacters(in: .whitespacesAndNewlines)
        let peTeethCountDB: Int32?       = Int32(peTeethCountTrim).flatMap { $0 > 0 ? $0 : nil }

        // Teeth: keep DB consistent — if count > 0, mark teeth as present.
        let peTeethPresentDB: Int32      = (peTeethPresent || peTeethCountDB != nil) ? 1 : 0

        let peTeethCommentDB             = peTeethComment.trimmingCharacters(in: .whitespacesAndNewlines)

        let sql = """
        UPDATE well_visits
        SET
            pe_trophic_normal = ?,
            pe_trophic_comment = ?,
            pe_hydration_normal = ?,
            pe_hydration_comment = ?,
            pe_color = ?,
            pe_color_comment = ?,
            pe_fontanelle_normal = ?,
            pe_fontanelle_comment = ?,
            pe_pupils_rr_normal = ?,
            pe_pupils_rr_comment = ?,
            pe_ocular_motility_normal = ?,
            pe_ocular_motility_comment = ?,
            pe_tone_normal = ?,
            pe_tone_comment = ?,
            pe_wakefulness_normal = ?,
            pe_wakefulness_comment = ?,
            pe_moro_normal = ?,
            pe_moro_comment = ?,
            pe_hands_fist_normal = ?,
            pe_hands_fist_comment = ?,
            pe_symmetry_normal = ?,
            pe_symmetry_comment = ?,
            pe_follows_midline_normal = ?,
            pe_follows_midline_comment = ?,
            pe_breathing_normal = ?,
            pe_breathing_comment = ?,
            pe_heart_sounds_normal = ?,
            pe_heart_sounds_comment = ?,
            pe_abd_mass = ?,
            pe_genitalia = ?,
            pe_testicles_descended = ?,
            pe_femoral_pulses_normal = ?,
            pe_femoral_pulses_comment = ?,
            pe_liver_spleen_normal = ?,
            pe_liver_spleen_comment = ?,
            pe_umbilic_normal = ?,
            pe_umbilic_comment = ?,
            pe_spine_normal = ?,
            pe_spine_comment = ?,
            pe_hips_normal = ?,
            pe_hips_comment = ?,
            pe_skin_marks_normal = ?,
            pe_skin_marks_comment = ?,
            pe_skin_integrity_normal = ?,
            pe_skin_integrity_comment = ?,
            pe_skin_rash_normal = ?,
            pe_skin_rash_comment = ?,
            pe_teeth_present = ?,
            pe_teeth_count = ?,
            pe_teeth_comment = ?
        WHERE id = ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            AppLog.db.error("WellVisitForm: savePhysicalExamColumns prepare failed | visitID=\(visitID, privacy: .public) msg=\(msg, privacy: .private)")
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, peTrophicNormalDB)
        _ = peTrophicCommentDB.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 3, peHydrationNormalDB)
        _ = peHydrationCommentDB.withCString { sqlite3_bind_text(stmt, 4, $0, -1, SQLITE_TRANSIENT) }
        _ = peColorDB.withCString { sqlite3_bind_text(stmt, 5, $0, -1, SQLITE_TRANSIENT) }
        _ = peColorCommentDB.withCString { sqlite3_bind_text(stmt, 6, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 7, peFontanelleNormalDB)
        _ = peFontanelleCommentDB.withCString { sqlite3_bind_text(stmt, 8, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 9, pePupilsRRNormalDB)
        _ = pePupilsRRCommentDB.withCString { sqlite3_bind_text(stmt, 10, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 11, peOcularMotilityNormalDB)
        _ = peOcularMotilityCommentDB.withCString { sqlite3_bind_text(stmt, 12, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 13, peToneNormalDB)
        _ = peToneCommentDB.withCString { sqlite3_bind_text(stmt, 14, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 15, peWakefulnessNormalDB)
        _ = peWakefulnessCommentDB.withCString { sqlite3_bind_text(stmt, 16, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 17, peMoroNormalDB)
        _ = peMoroCommentDB.withCString { sqlite3_bind_text(stmt, 18, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 19, peHandsFistNormalDB)
        _ = peHandsFistCommentDB.withCString { sqlite3_bind_text(stmt, 20, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 21, peSymmetryNormalDB)
        _ = peSymmetryCommentDB.withCString { sqlite3_bind_text(stmt, 22, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 23, peFollowsMidlineNormalDB)
        _ = peFollowsMidlineCommentDB.withCString { sqlite3_bind_text(stmt, 24, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 25, peBreathingNormalDB)
        _ = peBreathingCommentDB.withCString { sqlite3_bind_text(stmt, 26, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 27, peHeartNormalDB)
        _ = peHeartCommentDB.withCString { sqlite3_bind_text(stmt, 28, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 29, peAbdMassDB)
        _ = peGenitaliaDB.withCString { sqlite3_bind_text(stmt, 30, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 31, peTesticlesDescendedDB)
        sqlite3_bind_int(stmt, 32, peFemoralPulsesNormalDB)
        _ = peFemoralPulsesCommentDB.withCString { sqlite3_bind_text(stmt, 33, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 34, peLiverSpleenNormalDB)
        _ = peLiverSpleenCommentDB.withCString { sqlite3_bind_text(stmt, 35, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 36, peUmbilicNormalDB)
        _ = peUmbilicCommentDB.withCString { sqlite3_bind_text(stmt, 37, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 38, peSpineNormalDB)
        _ = peSpineCommentDB.withCString { sqlite3_bind_text(stmt, 39, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 40, peHipsLimbsNormalDB)
        _ = peHipsLimbsCommentDB.withCString { sqlite3_bind_text(stmt, 41, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 42, peSkinMarksNormalDB)
        _ = peSkinMarksCommentDB.withCString { sqlite3_bind_text(stmt, 43, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 44, peSkinIntegrityNormalDB)
        _ = peSkinIntegrityCommentDB.withCString { sqlite3_bind_text(stmt, 45, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 46, peSkinRashNormalDB)
        _ = peSkinRashCommentDB.withCString { sqlite3_bind_text(stmt, 47, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 48, peTeethPresentDB)
        if let cnt = peTeethCountDB {
            sqlite3_bind_int(stmt, 49, cnt)
        } else {
            sqlite3_bind_null(stmt, 49)
        }
        _ = peTeethCommentDB.withCString { sqlite3_bind_text(stmt, 50, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int64(stmt, 51, sqlite3_int64(visitID))
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE {
            let rowChanges = sqlite3_changes(db)
            AppLog.db.debug(
                "WellVisitForm: savePhysicalExamColumns done | visitID=\(visitID, privacy: .public) changes=\(rowChanges, privacy: .public)"
            )
        } else {
            let msg = String(cString: sqlite3_errmsg(db))
            AppLog.db.error("WellVisitForm: savePhysicalExamColumns UPDATE failed | visitID=\(visitID, privacy: .public) msg=\(msg, privacy: .private)")
        }
    }

    private func saveMilestones(db: OpaquePointer, visitID: Int) {
        
        AppLog.db.debug("WellVisitForm: saveMilestones start | visitID=\(visitID, privacy: .public) count=\(currentMilestoneDescriptors.count, privacy: .public)")
        // Wipe existing rows for this visit
        do {
            let sql = "DELETE FROM well_visit_milestones WHERE visit_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, sqlite3_int64(visitID))
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(db))
                AppLog.db.error("WellVisitForm: saveMilestones DELETE failed | visitID=\(visitID, privacy: .public) msg=\(msg, privacy: .private)")
            }  // ignore failure for now
        }

        let descriptors = currentMilestoneDescriptors
        guard !descriptors.isEmpty else { return }

        let sql = """
        INSERT INTO well_visit_milestones
            (visit_id, code, label, status, note, updated_at)
        VALUES (?,?,?,?,?,CURRENT_TIMESTAMP);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        
        var okCount = 0

        for m in descriptors {
            let status = milestoneStatuses[m.code] ?? .uncertain
            let note   = milestoneNotes[m.code] ?? ""

            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)

            sqlite3_bind_int64(stmt, 1, sqlite3_int64(visitID))
            _ = m.code.withCString   { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
            _ = m.label.withCString  { sqlite3_bind_text(stmt, 3, $0, -1, SQLITE_TRANSIENT) }
            _ = status.rawValue.withCString { sqlite3_bind_text(stmt, 4, $0, -1, SQLITE_TRANSIENT) }
            _ = note.withCString     { sqlite3_bind_text(stmt, 5, $0, -1, SQLITE_TRANSIENT) }

            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE {
                okCount += 1
            } else {
                let msg = String(cString: sqlite3_errmsg(db))
                AppLog.db.error("WellVisitForm: saveMilestones INSERT failed | visitID=\(visitID, privacy: .public) code=\(m.code, privacy: .public) msg=\(msg, privacy: .private)")
            }
        }
        
        AppLog.db.debug("WellVisitForm: saveMilestones done | visitID=\(visitID, privacy: .public) ok=\(okCount, privacy: .public) total=\(descriptors.count, privacy: .public)")
    }
    
    // Ensure the active clinician exists in the bundle's local `users` table.
    // This mirrors the logic used for sick episodes.
    private func ensureBundleUserRowIfNeeded(dbURL: URL) {
        AppLog.db.debug("WellVisitForm: ensureBundleUserRowIfNeeded start | activeUserID=\(logOptInt(appState.activeUserID), privacy: .public)")
        guard
            let activeID = appState.activeUserID,
            let clinician = clinicianStore.users.first(where: { $0.id == activeID })
        else {
            AppLog.db.debug("WellVisitForm: ensureBundleUserRowIfNeeded skip | missing activeID/clinician")
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db = db else {
            AppLog.db.error("WellVisitForm: ensureBundleUserRowIfNeeded open DB failed | path=\(dbURL.path, privacy: .private)")
            return
        }
        defer { sqlite3_close(db) }

        // Minimal users table used by the viewer app and PDF generators
        let createSQL = """
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY,
            first_name TEXT NOT NULL,
            last_name  TEXT NOT NULL
        );
        """
        guard sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            AppLog.db.error("WellVisitForm: ensureBundleUserRowIfNeeded create users table failed | msg=\(msg, privacy: .private)")
            return
        }

        // If the row already exists, nothing else to do
        let checkSQL = "SELECT 1 FROM users WHERE id = ? LIMIT 1;"
        var checkStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(checkStmt) }

        sqlite3_bind_int64(checkStmt, 1, sqlite3_int64(activeID))
        if sqlite3_step(checkStmt) == SQLITE_ROW {
            AppLog.db.debug("WellVisitForm: ensureBundleUserRowIfNeeded already present | userID=\(activeID, privacy: .public)")
            return
        }

        // Insert the active clinician into the bundle users table
        let insertSQL = "INSERT INTO users (id, first_name, last_name) VALUES (?, ?, ?);"
        var insertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(insertStmt) }

        sqlite3_bind_int64(insertStmt, 1, sqlite3_int64(activeID))
        _ = clinician.firstName.withCString { sqlite3_bind_text(insertStmt, 2, $0, -1, SQLITE_TRANSIENT) }
        _ = clinician.lastName.withCString  { sqlite3_bind_text(insertStmt, 3, $0, -1, SQLITE_TRANSIENT) }

        let rc = sqlite3_step(insertStmt)
        if rc == SQLITE_DONE {
            AppLog.db.notice("WellVisitForm: ensureBundleUserRowIfNeeded inserted user | userID=\(activeID, privacy: .public)")
        } else {
            let msg = String(cString: sqlite3_errmsg(db))
            AppLog.db.error("WellVisitForm: ensureBundleUserRowIfNeeded insert failed | userID=\(activeID, privacy: .public) msg=\(msg, privacy: .private)")
        }
    }

    private func showError(_ message: String) {
        AppLog.db.error(
            "WellVisitForm: saveTapped FAILED | pid=\(logOptInt(appState.selectedPatientID), privacy: .public) visitID=\(logOptInt(editingVisitID), privacy: .public) msg=\(message, privacy: .private)"
        )
        saveErrorMessage = message
        showErrorAlert = true
    }
}


// MARK: - SwiftUI compatibility helpers

private extension View {
    /// Avoids the macOS 14 deprecation warning for `onChange(of:perform:)` while keeping compatibility
    /// with older deployment targets.
    @ViewBuilder
    func onChangeCompat<T: Equatable>(of value: T, perform action: @escaping () -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self.onChange(of: value) {
                action()
            }
        } else {
            self.onChange(of: value) { _ in
                action()
            }
        }
    }
}
