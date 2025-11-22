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
            showsNextVisit: true
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
            showsNextVisit: true
        )
    }
}

/// Convenience for mapping directly from visit_type ID.
func layoutProfile(forVisitType id: String) -> WellVisitLayoutProfile {
    layoutProfile(for: ageGroupForVisitType(id))
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
    @State private var feeding: String = ""
    @State private var supplementation: String = ""
    @State private var vitaminDGiven: Bool = false
    @State private var sleep: String = ""

    // Physical examination (stored in lab_text for now)
    @State private var physicalExam: String = ""

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

    private var showsSupplementationFields: Bool {
        layout.showsSupplementation
    }

    private var showsVitaminDField: Bool {
        layout.showsVitaminD
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

                    // Parent's concerns  → parent_concerns
                    GroupBox("Parent's Concerns") {
                        TextEditor(text: $parentsConcerns)
                            .frame(minHeight: 120)
                    }

                    // Feeding + Supplementation + Vitamin D
                    if layout.showsFeeding {
                        GroupBox("Feeding & Supplementation") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Feeding")
                                    .font(.subheadline.bold())
                                TextEditor(text: $feeding)
                                    .frame(minHeight: 100)

                                if showsSupplementationFields {
                                    Text("Supplementation (free text)")
                                        .font(.subheadline.bold())
                                    TextEditor(text: $supplementation)
                                        .frame(minHeight: 80)
                                }

                                if showsVitaminDField {
                                    Toggle("Vitamin D supplementation given", isOn: $vitaminDGiven)
                                }
                            }
                        }
                    }

                    // Sleep
                    if layout.showsSleep {
                        GroupBox("Sleep") {
                            TextEditor(text: $sleep)
                                .frame(minHeight: 100)
                        }
                    }

                    // Physical examination (stored in lab_text for now)
                    if layout.showsPhysicalExam {
                        GroupBox("Physical examination") {
                            TextEditor(text: $physicalExam)
                                .frame(minHeight: 160)
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

                    // Problem listing
                    if layout.showsProblemListing {
                        GroupBox("Problem listing") {
                            TextEditor(text: $problemListing)
                                .frame(minHeight: 140)
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

                    // AI assistant placeholder
                    GroupBox("AI Assistant (preview)") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("This area will later show AI-generated suggestions and summaries for this visit.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            TextEditor(text: $aiNotes)
                                .frame(minHeight: 120)
                                .disabled(true)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.secondary.opacity(0.3))
                                )
                        }
                        .padding(.top, 4)
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

    // MARK: - Load existing visit (edit mode)

    private func loadIfEditing() {
        guard let visitID = editingVisitID,
              let dbURL = appState.currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path)
        else { return }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = db else { return }
        defer { sqlite3_close(db) }

        // Load core well_visits fields
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
                vitamin_d_given
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
                let supplementationTxt = text(4)
                let sleepText          = text(5)
                let problems           = text(6)
                let conclText          = text(7)
                let planText           = text(8)
                let nextVisitISO       = text(9)
                let clinicianText      = text(10)
                let peText             = text(11)
                let vitVal             = sqlite3_column_int(stmt, 12)

                if !dateISO.isEmpty,
                   let d = Self.isoDateOnly.date(from: dateISO) {
                    visitDate = d
                }
                if !type.isEmpty {
                    visitTypeID = type
                }
                parentsConcerns  = parentTxt
                feeding          = feedingText
                supplementation  = supplementationTxt
                sleep            = sleepText
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
        let supplementationText = supplementation
        let sleepText      = sleep
        let probs          = problemListing
        let concl          = conclusions
        let planText       = plan
        let clinicianText  = clinicianComment
        let peText         = physicalExam
        let vitInt         = vitaminDGiven ? 1 : 0
        let nextVisitISO: String? = hasNextVisitDate
            ? Self.isoDateOnly.string(from: nextVisitDate)
            : nil

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
                created_at,
                updated_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP);
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
            _ = supplementationText.withCString {
                sqlite3_bind_text(stmt, 14, $0, -1, SQLITE_TRANSIENT)
            }

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                showError("Failed to insert well visit.")
                return
            }
            visitID = Int(sqlite3_last_insert_rowid(db))
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
            _ = supplementationText.withCString {
                sqlite3_bind_text(stmt, 13, $0, -1, SQLITE_TRANSIENT)
            }
            sqlite3_bind_int64(stmt, 14, sqlite3_int64(visitID))

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                showError("Failed to update well visit.")
                return
            }
        }

        // Save milestones for this visit (delete old, insert new)
        saveMilestones(db: db, visitID: visitID)

        // Refresh visit list in UI + close sheet
        appState.reloadVisitsForSelectedPatient()
        dismiss()
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
