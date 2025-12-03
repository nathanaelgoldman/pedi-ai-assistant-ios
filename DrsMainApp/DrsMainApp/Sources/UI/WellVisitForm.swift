//
//  WellVisitForm.swift
//  DrsMainApp
//
//  Created by yunastic on 11/20/25.
//

import SwiftUI
import SQLite3

// Matches C macro used elsewhere so we can safely bind text.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Milestone model & catalog

private struct MilestoneDescriptor: Identifiable, Hashable {
    let id = UUID()
    let code: String
    let label: String
}

private enum MilestoneStatus: String, CaseIterable, Identifiable {
    case achieved    = "achieved"
    case notYet      = "not yet"
    case uncertain   = "uncertain"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .achieved:  return "Achieved"
        case .notYet:    return "Not yet"
        case .uncertain: return "Uncertain"
        }
    }
}

// Milestone sets, ported from the Python MILESTONE_SETS
private let WELL_VISIT_MILESTONES: [String: [MilestoneDescriptor]] = [
    "newborn_first": [
        .init(code: "regards_face",       label: "Regards face"),
        .init(code: "follows_to_midline", label: "Follows to midline"),
        .init(code: "alerts_to_sound",    label: "Alerts to sound/voice"),
        .init(code: "calms_to_voice",     label: "Calms to caregiver voice"),
        .init(code: "lifts_chin",         label: "Lifts chin/chest in prone"),
        .init(code: "symmetric_moves",    label: "Symmetric movements"),
    ],
    "one_month": [
        .init(code: "regards_face",       label: "Regards face"),
        .init(code: "follows_to_midline", label: "Follows to midline"),
        .init(code: "alerts_to_sound",    label: "Alerts to sound/voice"),
        .init(code: "calms_to_voice",     label: "Calms to caregiver voice"),
        .init(code: "lifts_chin",         label: "Lifts chin briefly in prone"),
        .init(code: "symmetric_moves",    label: "Symmetric movements"),
    ],
    "two_month": [
        .init(code: "social_smile",        label: "Social smile"),
        .init(code: "coos",                label: "Coos / vowel sounds"),
        .init(code: "follows_past_midline",label: "Follows past midline"),
        .init(code: "lifts_head_prone",    label: "Lifts head ~45° in prone"),
        .init(code: "hands_to_mouth",      label: "Hands to mouth / opens hands"),
        .init(code: "alerts_to_sound",     label: "Alerts/quiets to sound/voice"),
    ],
    "four_month": [
        .init(code: "social_smile",       label: "Social smile"),
        .init(code: "babbles",            label: "Babbles / coos"),
        .init(code: "hands_together",     label: "Hands to midline / together"),
        .init(code: "reaches_toys",       label: "Reaches for toys"),
        .init(code: "supports_head",      label: "Good head control"),
        .init(code: "rolls_prone_supine", label: "Rolls prone→supine"),
    ],
    "six_month": [
        .init(code: "responds_name",      label: "Responds to name"),
        .init(code: "babbles_consonants", label: "Consonant babble"),
        .init(code: "transfers",          label: "Transfers objects hand-to-hand"),
        .init(code: "sits_support",       label: "Sits with minimal support"),
        .init(code: "rolls_both",         label: "Rolls both ways"),
        .init(code: "stranger_awareness", label: "Stranger awareness"),
    ],
    "nine_month": [
        .init(code: "peekaboo",           label: "Plays peek-a-boo"),
        .init(code: "mam_bab_dad",        label: "Mam/bab/dad (nonspecific)"),
        .init(code: "pincer",             label: "Inferior pincer grasp"),
        .init(code: "sits_no_support",    label: "Sits without support"),
        .init(code: "pulls_to_stand",     label: "Pulls to stand"),
        .init(code: "waves_bye",          label: "Waves bye-bye"),
    ],
    "twelve_month": [
        .init(code: "specific_mama_dada", label: "Mama/Dada specific"),
        .init(code: "one_word",           label: "At least one word"),
        .init(code: "fine_pincer",        label: "Fine pincer grasp"),
        .init(code: "stands_alone",       label: "Stands alone"),
        .init(code: "walks",              label: "Takes a few steps"),
        .init(code: "points",             label: "Points/Proto-declarative"),
    ],
    "fifteen_month": [
        .init(code: "walks_independent",  label: "Walks independently"),
        .init(code: "scribbles",          label: "Scribbles"),
        .init(code: "uses_3_words",       label: "Uses ≥3 words"),
        .init(code: "points_request",     label: "Points to request objects"),
        .init(code: "drink_cup",          label: "Drinks from cup"),
        .init(code: "imitates",           label: "Imitates simple actions"),
    ],
    "eighteen_month": [
        .init(code: "runs",               label: "Runs"),
        .init(code: "stair_help",         label: "Walks up steps with help"),
        .init(code: "uses_10_words",      label: "Uses ~10–25 words"),
        .init(code: "pretend_play",       label: "Begins pretend play"),
        .init(code: "points_body_parts",  label: "Points to ≥3 body parts"),
        .init(code: "feeds_spoon",        label: "Feeds self with spoon"),
    ],
    "twentyfour_month": [
        .init(code: "two_word_phrases",   label: "Two-word phrases"),
        .init(code: "follows_2step",      label: "Follows 2-step command"),
        .init(code: "jumps",              label: "Jumps with both feet"),
        .init(code: "stacks_blocks",      label: "Stacks 5–6 blocks"),
        .init(code: "parallel_play",      label: "Parallel play"),
        .init(code: "removes_clothing",   label: "Removes some clothing"),
    ],
    "thirty_month": [
        .init(code: "understands_prepositions", label: "Understands prepositions"),
        .init(code: "throws_overhand",          label: "Throws ball overhand"),
        .init(code: "imitates_lines",           label: "Imitates vertical line"),
        .init(code: "toilet_awareness",         label: "Toilet awareness"),
        .init(code: "speaks_50_words",          label: "Vocabulary ~50 words"),
        .init(code: "shares_interest",          label: "Shares interest with adult"),
    ],
    "thirtysix_month": [
        .init(code: "pedals_tricycle",          label: "Pedals tricycle"),
        .init(code: "balances_moment",          label: "Balances on one foot momentarily"),
        .init(code: "draws_circle",             label: "Draws circle"),
        .init(code: "speaks_sentences",         label: "Uses 3-word sentences"),
        .init(code: "colors_names",             label: "Names colors/pictures"),
        .init(code: "interactive_play",         label: "Engages in interactive play"),
    ]
]

// Visit type list for the picker
private struct WellVisitType: Identifiable {
    let id: String
    let title: String
}

private let WELL_VISIT_TYPES: [WellVisitType] = [
    .init(id: "newborn_first",  title: "Newborn – first visit"),
    .init(id: "one_month",      title: "1-month visit"),
    .init(id: "two_month",      title: "2-month visit"),
    .init(id: "four_month",     title: "4-month visit"),
    .init(id: "six_month",      title: "6-month visit"),
    .init(id: "nine_month",     title: "9-month visit"),
    .init(id: "twelve_month",   title: "12-month visit"),
    .init(id: "fifteen_month",  title: "15-month visit"),
    .init(id: "eighteen_month", title: "18-month visit"),
    .init(id: "twentyfour_month", title: "24-month visit"),
    .init(id: "thirty_month",   title: "30-month visit"),
    .init(id: "thirtysix_month",title: "36-month visit"),
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

    case "thirty_month", "thirtysix_month":
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

    /// If nil → create new visit; non-nil → edit existing well_visit row.
    let editingVisitID: Int?

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

    // Milestone state: per-code status + optional note
    @State private var milestoneStatuses: [String: MilestoneStatus] = [:]
    @State private var milestoneNotes: [String: String] = [:]

    // Error reporting
    @State private var saveErrorMessage: String? = nil
    @State private var showErrorAlert: Bool = false

    // Date formatter (yyyy-MM-dd)
    private static let isoDateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

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
            Text("Solid foods")
                .font(.subheadline.bold())

            Toggle("Solid foods started", isOn: $solidFoodStarted)

            if solidFoodStarted {
                DatePicker(
                    "Start date",
                    selection: $solidFoodStartDate,
                    displayedComponents: .date
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Solid food intake")
                        .font(.subheadline)
                    Picker("Solid food quantity / quality", selection: $solidFoodQuality) {
                        Text("Appears good").tag("appears_good")
                        Text("Uncertain").tag("uncertain")
                        Text("Probably limited").tag("probably_limited")
                    }
                    .pickerStyle(.segmented)
                }
            }
        }

    @ViewBuilder
    private var olderFeedingSection: some View {
        Text("Variety & dairy intake")
            .font(.subheadline.bold())

        VStack(alignment: .leading, spacing: 8) {
            Text("Food variety quality")
                .font(.subheadline)
            Picker("Food variety quality", selection: $foodVarietyQuality) {
                Text("Appears good").tag("appears_good")
                Text("Uncertain").tag("uncertain")
                Text("Probably limited").tag("probably_limited")
            }
            .pickerStyle(.segmented)
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Dairy intake (per day)")
                .font(.subheadline)
            Picker("Dairy intake (per day)", selection: $dairyAmountCode) {
                Text("1 cup or bottle").tag("1")
                Text("2 cups or bottles").tag("2")
                Text("3 cups or bottles").tag("3")
                Text("4 cups or bottles").tag("4")
            }
            .pickerStyle(.segmented)
        }

        VStack(alignment: .leading, spacing: 8) {
            Toggle("Still breastfeeding", isOn: $milkTypeBreast)
                .toggleStyle(.switch)
        }
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

    init(editingVisitID: Int? = nil) {
        self.editingVisitID = editingVisitID
    }

   

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Visit info
                    GroupBox("Visit info") {
                        VStack(alignment: .leading, spacing: 12) {
                            DatePicker(
                                "Date",
                                selection: $visitDate,
                                displayedComponents: .date
                            )

                            Picker("Type", selection: $visitTypeID) {
                                ForEach(visitTypes) { t in
                                    Text(t.title).tag(t.id)
                                }
                            }
                            .frame(maxWidth: 400, alignment: .leading)
                        }
                        .padding(.top, 4)
                    }
                    
                    if isWeightDeltaVisit {
                        GroupBox("Weight change since last measurement") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(latestWeightSummary.isEmpty
                                     ? "Latest weight: not available"
                                     : "Latest weight: \(latestWeightSummary)")
                                    .font(.subheadline)

                                if !previousWeightSummary.isEmpty {
                                    Text("Previous weight: \(previousWeightSummary)")
                                        .font(.subheadline)
                                } else {
                                    Text("Previous weight: not available")
                                        .font(.subheadline)
                                }

                                HStack {
                                    Text(deltaWeightPerDaySummary.isEmpty
                                         ? "Δ weight: not available"
                                         : deltaWeightPerDaySummary)
                                        .font(.subheadline)

                                    Spacer()

                                    if let delta = deltaWeightPerDayValue,
                                       delta >= 20,
                                       deltaWeightIsNormal {
                                        Label("OK", systemImage: "checkmark.circle.fill")
                                            .font(.subheadline)
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                        }
                    }

                    // Parent's concerns  → parent_concerns
                    GroupBox("Parent's Concerns") {
                        TextEditor(text: $parentsConcerns)
                            .frame(minHeight: 120)
                    }

                    // Feeding + Supplementation + Vitamin D
                    if layout.showsFeeding {
                        GroupBox("Feeding & Supplementation") {
                            VStack(alignment: .leading, spacing: 12) {

                                if isStructuredFeedingUnder12 {
                                    // NEWBORN → 9-month visits:
                                    // milk checkboxes, volumes, regurgitation, one issues text, ±solids, Vit D
                                    Text("Milk type(s)")
                                        .font(.subheadline.bold())

                                    HStack {
                                        Toggle("Breastmilk", isOn: $milkTypeBreast)
                                        Toggle("Formula", isOn: $milkTypeFormula)
                                    }

                                    HStack(spacing: 16) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Volume per feed (ml)")
                                                .font(.subheadline)
                                            TextField("e.g. 60", text: $feedVolumeMl)
                                                .frame(width: 80)
                                                .textFieldStyle(.roundedBorder)
                                        }

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Feeds per 24h")
                                                .font(.subheadline)
                                            TextField("e.g. 8", text: $feedFreqPer24h)
                                                .frame(width: 80)
                                                .textFieldStyle(.roundedBorder)
                                        }
                                    }

                                    if estimatedTotalIntakeMlPer24h != "–" {
                                        Text("Estimated intake: \(estimatedTotalIntakeMlPer24h)")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }

                                    Toggle("Significant regurgitation", isOn: $regurgitationPresent)

                                    Text("Feeding difficulties / issues")
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
                                        Toggle("Vitamin D supplementation given", isOn: $vitaminDGiven)
                                    }

                                } else {
                                    // 12–36-month visits:
                                    // food variety / dairy intake, breastfeeding, ONE issues text, Vit D
                                    olderFeedingSection

                                    Text("Feeding difficulties / issues")
                                        .font(.subheadline.bold())
                                    TextEditor(text: $feedingIssue)
                                        .frame(minHeight: 80)

                                    if showsVitaminDField {
                                        Toggle("Vitamin D supplementation given", isOn: $vitaminDGiven)
                                    }
                                }
                            }
                        }
                    }

                    GroupBox("Stools") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Stool pattern")
                                .font(.subheadline)

                            Picker("Stool pattern", selection: $poopStatus) {
                                Text("Normal / typical breastfed stool").tag("normal")
                                Text("Abnormal reported").tag("abnormal")
                                Text("Hard / constipated").tag("hard")
                            }
                            .pickerStyle(.segmented)

                            TextField("Stool comment (optional)", text: $poopComment)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    // Sleep
                    if layout.showsSleep {
                        GroupBox("Sleep") {
                            VStack(alignment: .leading, spacing: 12) {
                                if isEarlySleepVisit {
                                    // Structured sleep layout for early visits
                                    HStack(spacing: 16) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Wakes for feeds (per night)")
                                                .font(.subheadline)
                                            TextField("e.g. 3", text: $wakesForFeedsPerNight)
                                                .frame(width: 80)
                                                .textFieldStyle(.roundedBorder)
                                        }

                                        if isEarlyMilkOnlyVisit {
                                            Toggle("Has a longer stretch of sleep at night", isOn: $longerSleepAtNight)
                                                .toggleStyle(.switch)
                                        }
                                    }

                                    Toggle("Sleep issues reported", isOn: $sleepIssueReported)
                                        .toggleStyle(.switch)

                                    if sleepIssueReported {
                                        Text("Sleep issue description")
                                            .font(.subheadline)
                                        TextEditor(text: $sleep)
                                            .frame(minHeight: 80)
                                    }
                                } else if isOlderSleepVisit {
                                    // Structured sleep layout for older visits (12-month+)
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(spacing: 16) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("Wakes at night (per night)")
                                                    .font(.subheadline)
                                                TextField("e.g. 1", text: $wakesForFeedsPerNight)
                                                    .frame(width: 80)
                                                    .textFieldStyle(.roundedBorder)
                                            }

                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("Total sleep in 24h")
                                                    .font(.subheadline)
                                                Picker("Total sleep in 24h", selection: $sleepHoursText) {
                                                    Text("Less than 10 h").tag("lt10")
                                                    Text("10–15 h").tag("10_15")
                                                }
                                                .pickerStyle(.segmented)
                                            }
                                        }

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Sleep regularity")
                                                .font(.subheadline)
                                            Picker("Sleep regularity", selection: $sleepRegular) {
                                                Text("Regular").tag("regular")
                                                Text("Irregular").tag("irregular")
                                            }
                                            .pickerStyle(.segmented)
                                        }

                                        Toggle("Snoring / noisy breathing during sleep", isOn: $sleepSnoring)
                                            .toggleStyle(.switch)

                                        Toggle("Sleep issues reported", isOn: $sleepIssueReported)
                                            .toggleStyle(.switch)

                                        if sleepIssueReported {
                                            Text("Sleep issue description")
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
                    }

                    // Physical examination (stored in lab_text for now)
                    if layout.showsPhysicalExam {
                        GroupBox("Physical examination") {
                            VStack(alignment: .leading, spacing: 12) {
                                // General / appearance
                                Text("General / appearance")
                                    .font(.subheadline.bold())

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Trophic state / weight impression")
                                        Spacer()
                                        Toggle("Normal", isOn: $peTrophicNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField("Trophic comment (optional)", text: $peTrophicComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Hydration")
                                        Spacer()
                                        Toggle("Normal", isOn: $peHydrationNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField("Hydration comment (optional)", text: $peHydrationComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Color")
                                        .font(.subheadline)
                                    Picker("Color", selection: $peColor) {
                                        Text("Normal").tag("normal")
                                        Text("Jaundice").tag("jaundice")
                                        Text("Pale").tag("pale")
                                    }
                                    .pickerStyle(.segmented)

                                    TextField("Color comment (optional)", text: $peColorComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                if isFontanelleVisit {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Fontanelle")
                                            Spacer()
                                            Toggle("Normal", isOn: $peFontanelleNormal)
                                                .toggleStyle(.switch)
                                        }
                                        TextField("Fontanelle comment (optional)", text: $peFontanelleComment)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Pupils (RR / symmetry)")
                                        Spacer()
                                        Toggle("Normal", isOn: $pePupilsRRNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField("Pupils comment (optional)", text: $pePupilsRRComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Ocular motility / alignment")
                                        Spacer()
                                        Toggle("Normal", isOn: $peOcularMotilityNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField("Ocular motility comment (optional)", text: $peOcularMotilityComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                if isTeethVisit {
                                    Divider()
                                        .padding(.vertical, 4)

                                    Text("Teeth / oral cavity")
                                        .font(.subheadline.bold())

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Teeth present")
                                            Spacer()
                                            Toggle("Yes", isOn: $peTeethPresent)
                                                .toggleStyle(.switch)
                                        }

                                        if peTeethPresent {
                                            HStack(spacing: 12) {
                                                Text("Number of teeth (approx)")
                                                TextField("e.g. 4", text: $peTeethCount)
                                                    .frame(width: 80)
                                                    .textFieldStyle(.roundedBorder)
                                            }
                                        }

                                        TextField("Teeth / oral comment (optional)", text: $peTeethComment)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }

                                // Neurologic / behaviour
                                Divider()
                                    .padding(.vertical, 4)

                                Text("Neurologic / behaviour")
                                    .font(.subheadline.bold())

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Tone")
                                        Spacer()
                                        Toggle("Normal", isOn: $peToneNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField("Tone comment (optional)", text: $peToneComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                if isPrimitiveNeuroVisit {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Wakefulness / reactivity")
                                            Spacer()
                                            Toggle("Normal", isOn: $peWakefulnessNormal)
                                                .toggleStyle(.switch)
                                        }
                                        TextField("Wakefulness comment (optional)", text: $peWakefulnessComment)
                                            .textFieldStyle(.roundedBorder)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Hands in fists / opening")
                                            Spacer()
                                            Toggle("Normal", isOn: $peHandsFistNormal)
                                                .toggleStyle(.switch)
                                        }
                                        TextField("Hands comment (optional)", text: $peHandsFistComment)
                                            .textFieldStyle(.roundedBorder)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Symmetry of movements")
                                            Spacer()
                                            Toggle("Normal", isOn: $peSymmetryNormal)
                                                .toggleStyle(.switch)
                                        }
                                        TextField("Symmetry comment (optional)", text: $peSymmetryComment)
                                            .textFieldStyle(.roundedBorder)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Follows to midline")
                                            Spacer()
                                            Toggle("Normal", isOn: $peFollowsMidlineNormal)
                                                .toggleStyle(.switch)
                                        }
                                        TextField("Follows midline comment (optional)", text: $peFollowsMidlineComment)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }

                                if isMoroVisit {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Moro reflex")
                                            Spacer()
                                            Toggle("Normal", isOn: $peMoroNormal)
                                                .toggleStyle(.switch)
                                        }
                                        TextField("Moro comment (optional)", text: $peMoroComment)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }

                                // Respiratory
                                Divider()
                                    .padding(.vertical, 4)

                                Text("Respiratory")
                                    .font(.subheadline.bold())

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Breathing / auscultation")
                                        Spacer()
                                        Toggle("Normal", isOn: $peBreathingNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField("Respiratory comment (optional)", text: $peBreathingComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                // Cardiovascular
                                Divider()
                                    .padding(.vertical, 4)

                                Text("Cardiovascular")
                                    .font(.subheadline.bold())

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Heart sounds / murmurs")
                                        Spacer()
                                        Toggle("Normal", isOn: $peHeartNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField("Cardiac comment (optional)", text: $peHeartComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                // Abdomen / digestive
                                Divider()
                                    .padding(.vertical, 4)

                                Text("Abdomen / digestive")
                                    .font(.subheadline.bold())

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Abdomen (palpation / organomegaly)")
                                        Spacer()
                                        Toggle("Normal", isOn: $peAbdomenNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField("Abdomen comment (optional)", text: $peAbdomenComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Abdominal mass palpable")
                                        Spacer()
                                        Toggle("Yes", isOn: $peAbdMassPresent)
                                            .toggleStyle(.switch)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Liver / spleen")
                                        Spacer()
                                        Toggle("Normal", isOn: $peLiverSpleenNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField("Liver/spleen comment (optional)", text: $peLiverSpleenComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Umbilicus")
                                        Spacer()
                                        Toggle("Normal", isOn: $peUmbilicNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField("Umbilicus comment (optional)", text: $peUmbilicComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Genitalia (exam)")
                                        .font(.subheadline)
                                    TextField("Genitalia description", text: $peGenitalia)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Testicles descended (if applicable)")
                                        Spacer()
                                        Toggle("Yes", isOn: $peTesticlesDescended)
                                            .toggleStyle(.switch)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Femoral pulses")
                                        Spacer()
                                        Toggle("Normal", isOn: $peFemoralPulsesNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField("Femoral pulses comment (optional)", text: $peFemoralPulsesComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                // Hips / limbs / posture
                                Divider()
                                    .padding(.vertical, 4)

                                Text("Hips / limbs / posture")
                                    .font(.subheadline.bold())

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Spine / posture")
                                        Spacer()
                                        Toggle("Normal", isOn: $peSpineNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField("Spine comment (optional)", text: $peSpineComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                if isHipsVisit {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Hips / limbs")
                                            Spacer()
                                            Toggle("Normal", isOn: $peHipsLimbsNormal)
                                                .toggleStyle(.switch)
                                        }
                                        TextField("Hips / limbs comment (optional)", text: $peHipsLimbsComment)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }

                                // Skin
                                Divider()
                                    .padding(.vertical, 4)

                                Text("Skin")
                                    .font(.subheadline.bold())

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Skin marks")
                                        Spacer()
                                        Toggle("Normal", isOn: $peSkinMarksNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField("Skin marks comment (optional)", text: $peSkinMarksComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Skin integrity")
                                        Spacer()
                                        Toggle("Normal", isOn: $peSkinIntegrityNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField("Skin integrity comment (optional)", text: $peSkinIntegrityComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Rash / lesions")
                                        Spacer()
                                        Toggle("Normal", isOn: $peSkinRashNormal)
                                            .toggleStyle(.switch)
                                    }
                                    TextField("Rash comment (optional)", text: $peSkinRashComment)
                                        .textFieldStyle(.roundedBorder)
                                }

                                Divider()
                                    .padding(.vertical, 4)

                                Text("Additional notes")
                                    .font(.subheadline.bold())
                                TextEditor(text: $physicalExam)
                                    .frame(minHeight: 120)
                            }
                        }
                    }

                    // Milestones / development
                    if layout.showsMilestones && !currentMilestoneDescriptors.isEmpty {
                        GroupBox("Developmental milestones") {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(currentMilestoneDescriptors) { m in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(m.label)
                                            .font(.body)

                                        Picker("Status", selection: Binding(
                                            get: { milestoneStatuses[m.code] ?? .uncertain },
                                            set: { milestoneStatuses[m.code] = $0 }
                                        )) {
                                            ForEach(MilestoneStatus.allCases) { status in
                                                Text(status.displayName).tag(status)
                                            }
                                        }
                                        .pickerStyle(.segmented)

                                        TextField(
                                            "Note (optional)",
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
                    }

                    // Neurodevelopment screening (M-CHAT / Dev test)
                    if isMCHATVisit || isDevTestScoreVisit || isDevTestResultVisit {
                        GroupBox("Neurodevelopment screening") {
                            VStack(alignment: .leading, spacing: 12) {
                                if isMCHATVisit {
                                    Text("M-CHAT")
                                        .font(.subheadline.bold())

                                    HStack(alignment: .center, spacing: 12) {
                                        Text("M-CHAT score")
                                        TextField("e.g. 0–20", text: $mchatScore)
                                            .frame(width: 80)
                                            .textFieldStyle(.roundedBorder)
                                    }

                                    TextField("M-CHAT result (e.g. low / medium / high risk)", text: $mchatResult)
                                        .textFieldStyle(.roundedBorder)
                                }

                                if isDevTestScoreVisit || isDevTestResultVisit {
                                    Divider()
                                        .padding(.vertical, 4)

                                    Text("Developmental test")
                                        .font(.subheadline.bold())

                                    if isDevTestScoreVisit {
                                        HStack(alignment: .center, spacing: 12) {
                                            Text("Dev test score")
                                            TextField("score", text: $devTestScore)
                                                .frame(width: 80)
                                                .textFieldStyle(.roundedBorder)
                                        }
                                    }

                                    if isDevTestResultVisit {
                                        TextField("Dev test result (e.g. normal / delayed / borderline)", text: $devTestResult)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }

                    // Problem listing
                    // Problem listing
                    if layout.showsProblemListing {
                        GroupBox("Problem listing") {
                            VStack(alignment: .leading, spacing: 8) {
                                TextEditor(text: $problemListing)
                                    .frame(minHeight: 140)

                                Button {
                                    regenerateProblemListingFromFindings()
                                } label: {
                                    Label("Update from findings", systemImage: "list.bullet.clipboard")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }

                    // Conclusions
                    if layout.showsConclusions {
                        GroupBox("Conclusions") {
                            TextEditor(text: $conclusions)
                                .frame(minHeight: 140)
                        }
                    }

                    // Plan / Anticipatory Guidance
                    if layout.showsPlan {
                        GroupBox("Plan / Anticipatory Guidance") {
                            TextEditor(text: $plan)
                                .frame(minHeight: 140)
                        }
                    }

                    // Clinician Comment – stays at the end
                    if layout.showsClinicianComment {
                        GroupBox("Clinician Comment") {
                            TextEditor(text: $clinicianComment)
                                .frame(minHeight: 120)
                        }
                    }

                    // Next Visit Date
                    if layout.showsNextVisit {
                        GroupBox("Next Visit Date") {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle("Schedule next visit", isOn: $hasNextVisitDate)

                                DatePicker(
                                    "Next visit date",
                                    selection: $nextVisitDate,
                                    displayedComponents: .date
                                )
                                .disabled(!hasNextVisitDate)
                            }
                            .padding(.top, 4)
                        }
                    }

                    // AI assistant (well visits)
                    if showsAISection {
                        GroupBox("AI Assistant") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 12) {
                                    Button {
                                        triggerAIForWellVisit()
                                    } label: {
                                        Label("Run AI summary", systemImage: "wand.and.stars")
                                    }
                                    .buttonStyle(.borderedProminent)

                                    if aiIsRunning {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                }

                                let entries = Array(appState.aiSummariesForActiveWellVisit.sorted { $0.key < $1.key })

                                if entries.isEmpty {
                                    Text("No AI summary yet. Click “Run AI summary” to generate suggestions for this visit.")
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
                    }
                }
                .padding(20)
            }
            .navigationTitle(editingVisitID == nil ? "New Well Visit" : "Edit Well Visit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveTapped()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .alert(
                "Could not save visit",
                isPresented: $showErrorAlert
            ) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(saveErrorMessage ?? "Unknown error.")
            }
            .onAppear {
                loadIfEditing()
                refreshWeightTrend()
            }
            .onChange(of: visitDate) { _ in
                refreshWeightTrend()
            }
        }
        .frame(
            minWidth: 1100,
            idealWidth: 1200,
            maxWidth: 1400,
            minHeight: 800,
            idealHeight: 900,
            maxHeight: 1100
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
            latestWeightSummary = "No weight data available"
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
            SELECT weight_kg * 1000.0 AS weight_g, recorded_at AS date_str
            FROM vitals
            WHERE patient_id = ? AND weight_kg IS NOT NULL

            UNION ALL

            SELECT weight_kg * 1000.0 AS weight_g, recorded_at AS date_str
            FROM manual_growth
            WHERE patient_id = ? AND weight_kg IS NOT NULL

            UNION ALL

            SELECT discharge_weight_g AS weight_g, maternity_discharge_date AS date_str
            FROM perinatal_history
            WHERE patient_id = ?
              AND discharge_weight_g IS NOT NULL
              AND maternity_discharge_date IS NOT NULL
        )
        SELECT weight_g, date_str
        FROM all_weights
        WHERE date_str IS NOT NULL
          AND date_str <= ?
        ORDER BY date_str DESC
        LIMIT 2;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sqlite3_int64(patientID))
        sqlite3_bind_int64(stmt, 2, sqlite3_int64(patientID))
        sqlite3_bind_int64(stmt, 3, sqlite3_int64(patientID))
        _ = dateISO.withCString { sqlite3_bind_text(stmt, 4, $0, -1, SQLITE_TRANSIENT) }

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
            latestWeightSummary = "No weight data available"
            previousWeightSummary = ""
            deltaWeightPerDaySummary = ""
            deltaWeightPerDayValue = nil
            deltaWeightIsNormal = false
            return
        }

        func cleanDate(_ raw: String) -> String {
            if raw.isEmpty { return "" }
            if let space = raw.firstIndex(of: " ") {
                return String(raw[..<space])
            }
            return raw
        }

        let latest = points[0]
        let latestKg = latest.weightG / 1000.0
        let latestDateDisplay = cleanDate(latest.dateStr)
        latestWeightSummary = String(format: "%.2f kg (%@)", latestKg, latestDateDisplay)

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
        previousWeightSummary = String(format: "%.2f kg (%@)", previousKg, previousDateDisplay)

        // Parse dates to compute day difference
        let rawLatest = latest.dateStr
        let rawPrevious = previous.dateStr

        let dateTimeFormatter = DateFormatter()
        dateTimeFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateTimeFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateTimeFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateOnlyFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"

        let dLatest = dateTimeFormatter.date(from: rawLatest) ?? dateOnlyFormatter.date(from: rawLatest)
        let dPrevious = dateTimeFormatter.date(from: rawPrevious) ?? dateOnlyFormatter.date(from: rawPrevious)

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
        deltaWeightPerDaySummary = "Δ weight: \(roundedPerDay) g/day"
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
                mchatResult = mchatResultText

                if devTestScoreInt > 0 {
                    devTestScore = String(devTestScoreInt)
                } else {
                    devTestScore = ""
                }
                devTestResult = devTestResultText

                // Structured feeding fields
                poopStatus  = poopStatusText
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

                solidFoodQuality = solidQualityText
                solidFoodComment = solidCommentText
                foodVarietyQuality = foodVarietyText

                // Structured sleep fields
                sleepHoursText = sleepHoursTextDB
                sleepRegular   = sleepRegularText
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
                
                peTeethPresent        = boolDefaultFalse(47)

                let teethCountInt     = sqlite3_column_int(stmt, 48)
                if teethCountInt > 0 {
                    peTeethCount = String(teethCountInt)
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

                if let parsed = MilestoneStatus(rawValue: status) {
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
    
    /// Rebuilds the problem listing from abnormal fields / comments.
    /// This does NOT touch the database – it only updates the TextEditor content.
    private func regenerateProblemListingFromFindings() {
        var lines: [String] = []

        func add(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lines.append("• " + trimmed)
            }
        }

        // 1) Parents' concerns
        if !parentsConcerns.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Parents' concerns: \(parentsConcerns)")
        }

        // 2) Feeding
        if isEarlyMilkOnlyVisit {
            if regurgitationPresent {
                add("Feeding: significant regurgitation reported.")
            }
            if !feedingIssue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add("Feeding difficulty: \(feedingIssue)")
            }
        } else {
            if !feeding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add("Feeding / diet: \(feeding)")
            }
            if solidFoodStarted {
                add("Solid food started.")
            }
            if !solidFoodQuality.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add("Solid food quality: \(solidFoodQuality)")
            }
            if !solidFoodComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add("Solid food comment: \(solidFoodComment)")
            }

            // Food variety: only if NOT "appears good"
            let foodVarietyTrim = foodVarietyQuality.trimmingCharacters(in: .whitespacesAndNewlines)
            if !foodVarietyTrim.isEmpty && foodVarietyTrim.lowercased() != "appears good" {
                add("Food variety: \(foodVarietyTrim)")
            }

            // Dairy intake: only if more than 3 cups (code "4")
            let dairyTrim = dairyAmountCode.trimmingCharacters(in: .whitespacesAndNewlines)
            if dairyTrim == "4" {
                add("Dairy intake: >3 cups/day.")
            }
        }

        // 2b) Stools – added for any visit when abnormal
        let poopStatusTrim = poopStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        if poopStatusTrim == "abnormal" {
            add("Stools: abnormal pattern reported.")
        } else if poopStatusTrim == "hard" {
            add("Stools: hard / constipation reported.")
        }
        let poopCommentTrim = poopComment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !poopCommentTrim.isEmpty {
            add("Stools comment: \(poopCommentTrim)")
        }

        // 3) Sleep
        // 3) Sleep
        if sleepIssueReported || !sleep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let wakesTrim = wakesForFeedsPerNight.trimmingCharacters(in: .whitespacesAndNewlines)
            // Waking to feed is only a problem after 12 months
            if !wakesTrim.isEmpty && isPostTwelveMonthVisit {
                add("Sleep: wakes \(wakesTrim) time(s) per night.")
            }

            if isOlderSleepVisit {
                let sleepHoursTrim = sleepHoursText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sleepHoursTrim.isEmpty {
                    var shouldAddSleepDuration = false

                    let lower = sleepHoursTrim.lowercased()
                    // Heuristic: either explicitly "<10" or parses as a numeric value < 10
                    if lower.contains("<10") || lower.contains("less than 10") {
                        shouldAddSleepDuration = true
                    } else {
                        let digits = sleepHoursTrim.filter { "0123456789.".contains($0) }
                        if let v = Double(digits), v < 10 {
                            shouldAddSleepDuration = true
                        }
                    }

                    if shouldAddSleepDuration {
                        add("Sleep duration: \(sleepHoursTrim)")
                    }
                }

                if !sleepRegular.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    add("Sleep regularity: \(sleepRegular)")
                }
                if sleepSnoring {
                    add("Sleep: snoring / noisy breathing reported.")
                }
            }

            if !sleep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add("Sleep issue: \(sleep)")
            }
        }

        // 4) Physical exam – only add when not normal or when there is a comment
        if !peTrophicNormal || !peTrophicComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Trophic state: " + (peTrophicComment.isEmpty ? "abnormal impression." : peTrophicComment))
        }
        if !peHydrationNormal || !peHydrationComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Hydration: " + (peHydrationComment.isEmpty ? "abnormal impression." : peHydrationComment))
        }
        if peColor != "normal" || !peColorComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Color: \(peColor)" + (peColorComment.isEmpty ? "" : " – \(peColorComment)"))
        }
        if isFontanelleVisit,
           (!peFontanelleNormal || !peFontanelleComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            add("Fontanelle: " + (peFontanelleComment.isEmpty ? "abnormal." : peFontanelleComment))
        }
        if !pePupilsRRNormal || !pePupilsRRComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Pupils: " + (pePupilsRRComment.isEmpty ? "abnormal." : pePupilsRRComment))
        }
        if !peOcularMotilityNormal || !peOcularMotilityComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Ocular motility: " + (peOcularMotilityComment.isEmpty ? "abnormal." : peOcularMotilityComment))
        }

        if !peToneNormal || !peToneComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Tone: " + (peToneComment.isEmpty ? "abnormal." : peToneComment))
        }
        if isPrimitiveNeuroVisit {
            if !peWakefulnessNormal || !peWakefulnessComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add("Wakefulness / reactivity: " + (peWakefulnessComment.isEmpty ? "abnormal." : peWakefulnessComment))
            }
            if !peHandsFistNormal || !peHandsFistComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add("Hands / opening: " + (peHandsFistComment.isEmpty ? "abnormal." : peHandsFistComment))
            }
            if !peSymmetryNormal || !peSymmetryComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add("Symmetry of movements: " + (peSymmetryComment.isEmpty ? "abnormal." : peSymmetryComment))
            }
            if !peFollowsMidlineNormal || !peFollowsMidlineComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add("Follows to midline: " + (peFollowsMidlineComment.isEmpty ? "abnormal." : peFollowsMidlineComment))
            }
        }
        if isMoroVisit,
           (!peMoroNormal || !peMoroComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            add("Moro reflex: " + (peMoroComment.isEmpty ? "abnormal." : peMoroComment))
        }

        if !peBreathingNormal || !peBreathingComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Respiratory: " + (peBreathingComment.isEmpty ? "abnormal." : peBreathingComment))
        }
        if !peHeartNormal || !peHeartComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Cardiac: " + (peHeartComment.isEmpty ? "abnormal." : peHeartComment))
        }

        if !peAbdomenNormal || !peAbdomenComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Abdomen: " + (peAbdomenComment.isEmpty ? "abnormal." : peAbdomenComment))
        }
        if peAbdMassPresent {
            add("Abdomen: mass palpable.")
        }
        if !peLiverSpleenNormal || !peLiverSpleenComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Liver / spleen: " + (peLiverSpleenComment.isEmpty ? "abnormal." : peLiverSpleenComment))
        }
        if !peUmbilicNormal || !peUmbilicComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Umbilicus: " + (peUmbilicComment.isEmpty ? "abnormal." : peUmbilicComment))
        }

        if !peGenitalia.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Genitalia: \(peGenitalia)")
        }
        if !peTesticlesDescended {
            add("Testicles: not fully descended.")
        }
        if !peFemoralPulsesNormal || !peFemoralPulsesComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Femoral pulses: " + (peFemoralPulsesComment.isEmpty ? "abnormal." : peFemoralPulsesComment))
        }

        if !peSpineNormal || !peSpineComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Spine / posture: " + (peSpineComment.isEmpty ? "abnormal." : peSpineComment))
        }
        if isHipsVisit,
           (!peHipsLimbsNormal || !peHipsLimbsComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            add("Hips / limbs: " + (peHipsLimbsComment.isEmpty ? "abnormal." : peHipsLimbsComment))
        }

        if !peSkinMarksNormal || !peSkinMarksComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Skin marks: " + (peSkinMarksComment.isEmpty ? "abnormal." : peSkinMarksComment))
        }
        if !peSkinIntegrityNormal || !peSkinIntegrityComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Skin integrity: " + (peSkinIntegrityComment.isEmpty ? "abnormal." : peSkinIntegrityComment))
        }
        if !peSkinRashNormal || !peSkinRashComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Rash / lesions: " + (peSkinRashComment.isEmpty ? "abnormal." : peSkinRashComment))
        }

        if isTeethVisit,
           (peTeethPresent
            || !peTeethCount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !peTeethComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            var text = "Teeth: "
            if peTeethPresent {
                text += "present"
            } else {
                text += "absent"
            }
            if !peTeethCount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text += " (\(peTeethCount) teeth)"
            }
            if !peTeethComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text += " – \(peTeethComment)"
            }
            add(text)
        }

        // 5) Milestones (only if some are not achieved / uncertain)
        if !currentMilestoneDescriptors.isEmpty {
            var milestoneLines: [String] = []
            for descriptor in currentMilestoneDescriptors {
                let code = descriptor.code
                let status = milestoneStatuses[code] ?? .uncertain
                if status == .achieved { continue }

                var line = descriptor.label + " – " + status.displayName
                if let note = milestoneNotes[code],
                   !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    line += " (\(note))"
                }
                milestoneLines.append(line)
            }
            if !milestoneLines.isEmpty {
                add("Milestones of concern:")
                for l in milestoneLines {
                    add("  - \(l)")
                }
            }
        }

        // 6) Neurodevelopment tests
        if isMCHATVisit {
            if !mchatScore.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !mchatResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add("M-CHAT: score \(mchatScore) – \(mchatResult)")
            }
        }
        if isDevTestScoreVisit || isDevTestResultVisit {
            if !devTestScore.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !devTestResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add("Developmental test: score \(devTestScore) – \(devTestResult)")
            }
        }

        // 7) Free PE notes block
        if !physicalExam.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Additional PE notes: \(physicalExam)")
        }
        
        // 1) Weight gain – only flag if < 20 g/day
        if isWeightDeltaVisit,
           let delta = deltaWeightPerDayValue {
            if delta < 20 {
                lines.append("Suboptimal weight gain: \(delta) g/day (target ≥ 20 g/day)")
            }
            // If delta >= 20 g/day, we do NOT add anything to problem listing.
        }

        // Finally, replace the problem listing with the auto-generated content
        problemListing = lines.joined(separator: "\n")
    }
    
    // MARK: - AI helpers (well visits)

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

        let perinatalSummary = cleaned(appState.perinatalSummaryForSelectedPatient())
        let pmhSummary       = cleaned(appState.pmhSummaryForSelectedPatient())
        let vaccSummary      = cleaned(appState.vaccinationSummaryForSelectedPatient())

        return AppState.WellVisitAIContext(
            patientID: patientID,
            wellVisitID: visitID,
            visitType: visitTypeID,
            ageDays: nil,  // can be wired to well_visits.age_days later
            problemListing: trimmedProblems,
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
                "local-stub": "Cannot run AI: please ensure a patient and saved well visit are selected."
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
            showError("No active bundle / database is selected.")
            return
        }
        guard let patientID = appState.selectedPatientID else {
            showError("No patient is selected.")
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db = db else {
            showError("Could not open database.")
            return
        }
        defer { sqlite3_close(db) }

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
        let mchatResultText = mchatResult

        let trimmedDevScore = devTestScore.trimmingCharacters(in: .whitespacesAndNewlines)
        let devTestScoreInt = Int32(trimmedDevScore.isEmpty ? "0" : trimmedDevScore) ?? 0
        let devTestResultText = devTestResult
        let deltaWeightDB: Int32? = deltaWeightPerDayValue

        let sleepHoursDB = sleepHoursText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sleepRegularDB = sleepRegular.trimmingCharacters(in: .whitespacesAndNewlines)
        let sleepSnoringDB: Int32 = sleepSnoring ? 1 : 0
        let longerSleepNightDB: Int32 = longerSleepAtNight ? 1 : 0
        let sleepIssueReportedDB: Int32 = sleepIssueReported ? 1 : 0

        // Feeding-related DB fields
        let poopStatusDB  = poopStatus.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let solidQualityDB  = solidFoodQuality.trimmingCharacters(in: .whitespacesAndNewlines)
        let solidCommentDB  = solidFoodComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let foodVarietyDB   = foodVarietyQuality.trimmingCharacters(in: .whitespacesAndNewlines)

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
                created_at,
                updated_at
            ) VALUES (
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, 
                CURRENT_TIMESTAMP,CURRENT_TIMESTAMP
            );
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                let errMsg = String(cString: sqlite3_errmsg(db))
                showError("Failed to prepare INSERT: \(errMsg)")
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
            _ = concl.withCString           { sqlite3_bind_text(stmt, 8,  $0, -1, SQLITE_TRANSIENT) }
            _ = planText.withCString        { sqlite3_bind_text(stmt, 9,  $0, -1, SQLITE_TRANSIENT) }
            if let nv = nextVisitISO {
                _ = nv.withCString          { sqlite3_bind_text(stmt, 10, $0, -1, SQLITE_TRANSIENT) }
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

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                showError("Failed to insert well visit.")
                return
            }
            visitID = Int(sqlite3_last_insert_rowid(db))
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
                showError("Failed to prepare UPDATE: \(errMsg)")
                return
            }
            defer { sqlite3_finalize(stmt) }

            _ = dateISO.withCString         { sqlite3_bind_text(stmt, 1,  $0, -1, SQLITE_TRANSIENT) }
            _ = type.withCString            { sqlite3_bind_text(stmt, 2,  $0, -1, SQLITE_TRANSIENT) }
            _ = parents.withCString         { sqlite3_bind_text(stmt, 3,  $0, -1, SQLITE_TRANSIENT) }
            _ = feedingText.withCString     { sqlite3_bind_text(stmt, 4,  $0, -1, SQLITE_TRANSIENT) }
            _ = sleepText.withCString       { sqlite3_bind_text(stmt, 5,  $0, -1, SQLITE_TRANSIENT) }
            _ = probs.withCString           { sqlite3_bind_text(stmt, 6,  $0, -1, SQLITE_TRANSIENT) }
            _ = concl.withCString           { sqlite3_bind_text(stmt, 7,  $0, -1, SQLITE_TRANSIENT) }
            _ = planText.withCString        { sqlite3_bind_text(stmt, 8,  $0, -1, SQLITE_TRANSIENT) }
            if let nv = nextVisitISO {
                _ = nv.withCString          { sqlite3_bind_text(stmt, 9,  $0, -1, SQLITE_TRANSIENT) }
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            _ = clinicianText.withCString   { sqlite3_bind_text(stmt, 10, $0, -1, SQLITE_TRANSIENT) }
            _ = peText.withCString          { sqlite3_bind_text(stmt, 11, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int(stmt, 12, Int32(vitInt))
            _ = dairyAmountDB.withCString   { sqlite3_bind_text(stmt, 13, $0, -1, SQLITE_TRANSIENT) }
            _ = poopStatusDB.withCString    { sqlite3_bind_text(stmt, 14, $0, -1, SQLITE_TRANSIENT) }
            _ = poopCommentDB.withCString   { sqlite3_bind_text(stmt, 15, $0, -1, SQLITE_TRANSIENT) }
            _ = milkTypesDB.withCString     { sqlite3_bind_text(stmt, 16, $0, -1, SQLITE_TRANSIENT) }

            if let vol = feedVolumeDB {
                sqlite3_bind_double(stmt, 17, vol)
            } else {
                sqlite3_bind_null(stmt, 17)
            }

            if let freq = feedFreqDB {
                sqlite3_bind_int(stmt, 18, freq)
            } else {
                sqlite3_bind_null(stmt, 18)
            }

            sqlite3_bind_int(stmt, 19, regurgitationDB)
            _ = feedingIssueDB.withCString  { sqlite3_bind_text(stmt, 20, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int(stmt, 21, solidStartedDB)

            if let solidsISO = solidStartDateISO {
                _ = solidsISO.withCString   { sqlite3_bind_text(stmt, 22, $0, -1, SQLITE_TRANSIENT) }
            } else {
                sqlite3_bind_null(stmt, 22)
            }

            _ = solidQualityDB.withCString  { sqlite3_bind_text(stmt, 23, $0, -1, SQLITE_TRANSIENT) }
            _ = solidCommentDB.withCString  { sqlite3_bind_text(stmt, 24, $0, -1, SQLITE_TRANSIENT) }
            _ = foodVarietyDB.withCString   { sqlite3_bind_text(stmt, 25, $0, -1, SQLITE_TRANSIENT) }

            _ = sleepHoursDB.withCString    { sqlite3_bind_text(stmt, 26, $0, -1, SQLITE_TRANSIENT) }
            _ = sleepRegularDB.withCString  { sqlite3_bind_text(stmt, 27, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int(stmt, 28, longerSleepNightDB)
            sqlite3_bind_int(stmt, 29, sleepSnoringDB)
            sqlite3_bind_int(stmt, 30, sleepIssueReportedDB)

            sqlite3_bind_int(stmt, 31, mchatScoreInt)
            _ = mchatResultText.withCString { sqlite3_bind_text(stmt, 32, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int(stmt, 33, devTestScoreInt)
            _ = devTestResultText.withCString {
                sqlite3_bind_text(stmt, 34, $0, -1, SQLITE_TRANSIENT)
            }
            if let delta = deltaWeightDB {
                sqlite3_bind_int(stmt, 35, delta)
            } else {
                sqlite3_bind_null(stmt, 35)
            }

            sqlite3_bind_int64(stmt, 36, sqlite3_int64(visitID))

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                showError("Failed to update well visit.")
                return
            }
            // Save physical exam structured fields
            savePhysicalExamColumns(db: db, visitID: visitID)
        }

        // Save milestones for this visit (delete old, insert new)
        saveMilestones(db: db, visitID: visitID)

        // Refresh visit list in UI + close sheet
        appState.reloadVisitsForSelectedPatient()
        dismiss()
    }

    private func savePhysicalExamColumns(db: OpaquePointer, visitID: Int) {
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
        let peTeethPresentDB: Int32      = peTeethPresent ? 1 : 0
        let peTeethCountTrim             = peTeethCount.trimmingCharacters(in: .whitespacesAndNewlines)
        let peTeethCountDB: Int32?       = Int32(peTeethCountTrim).flatMap { $0 > 0 ? $0 : nil }
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
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
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
        _ = sqlite3_step(stmt)
    }

    private func saveMilestones(db: OpaquePointer, visitID: Int) {
        // Wipe existing rows for this visit
        do {
            let sql = "DELETE FROM well_visit_milestones WHERE visit_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, sqlite3_int64(visitID))
            _ = sqlite3_step(stmt)  // ignore failure for now
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

            _ = sqlite3_step(stmt)
        }
    }

    private func showError(_ message: String) {
        saveErrorMessage = message
        showErrorAlert = true
    }
}
