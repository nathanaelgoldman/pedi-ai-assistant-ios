//
//  SickEpisodeForm.swift
//  DrsMainApp
//
//  Created by yunastic on 11/14/25.
//
//
//  SickEpisodeForm.swift
//  DrsMainApp
//
//  Created by ChatGPT on 11/14/25.
//



import SwiftUI
import AppKit
import OSLog
import SQLite3

// SQLite helper: transient destructor pointer for sqlite3_bind_text

fileprivate let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Standard sheet card styling (shared look across sheets)
fileprivate struct SheetCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
            )
    }
}

// MARK: - Chip button style (Perinatal-like pill chips)
fileprivate struct ChipButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isSelected
                        ? Color.accentColor.opacity(configuration.isPressed ? 0.25 : 0.18)
                        : Color(nsColor: .textBackgroundColor)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(isSelected ? 0.28 : 0.22), lineWidth: 1)
            )
            .foregroundStyle(Color.primary)
    }
}

// MARK: - Light-blue section card styling (matches PerinatalHistoryForm section blocks)
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
    /// Apply the standard “card in a sheet” look.
    func sheetCardStyle() -> some View {
        self.modifier(SheetCardStyle())
    }

    /// Apply the standard light-blue “section card” look (used for blocks inside forms).
    func lightBlueSectionCardStyle() -> some View {
        self.modifier(LightBlueSectionCardStyle())
    }
}

/// Form for creating or editing a sick episode.
/// This version focuses on a stable UI; persistence will be wired in next.
struct SickEpisodeForm: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    /// If non-nil, the form is editing that specific episode id.
    let editingEpisodeID: Int?

    /// Active episode id for this form; once a new episode is first saved, this becomes non-nil.
    
    @State private var activeEpisodeID: Int64? = nil

    // MARK: - Core HPI
    @State private var presetComplaints: Set<String> = []
    @State private var otherComplaints: String = ""
    @State private var hpi: String = ""
    // MARK: - Guideline match details
    private struct GuidelineMatchSelection: Identifiable, Equatable {
        let id: String            // ruleId
        let match: GuidelineMatch // includes flagText, priority, note
    }
    // Selected guideline match for popover details (must live in the View, not in an extension)
    @State private var selectedGuidelineMatch: GuidelineMatchSelection? = nil
    // Duration (UI) — edited as value + unit, stored as a single string in DB
    private enum DurationUnit: String, CaseIterable, Identifiable {
        case hours = "h"
        case days  = "d"
        var id: String { rawValue }

        var label: String {
            switch self {
            case .hours: return NSLocalizedString("common.hours_short", comment: "Short unit label for hours")
            case .days:  return NSLocalizedString("common.days_short", comment: "Short unit label for days")
            }
        }
    }
    @State private var duration: String = ""

    @State private var durationValue: String = ""
    @State private var durationUnit: DurationUnit = .hours

    // Per-complaint durations (UI): value + unit, stored later as a single string "48h"/"3d".
    private struct DurationInput: Equatable {
        var value: String = ""
        var unit: DurationUnit = .hours
    }

    // Keys match `complaintOptions` strings (e.g. "Cough", "Vomiting").
    @State private var complaintDurations: [String: DurationInput] = [:]
    

    // MARK: - Structured HPI
    @State private var appearance: String = "Well"
    @State private var feeding: String = "Normal"
    @State private var breathing: String = "Normal"
    @State private var urination: String = "Normal"
    @State private var pain: String = "None"
    @State private var stools: String = "Normal"
    @State private var context: Set<String> = []

    // MARK: - Physical Exam
    @State private var generalAppearance: String = "Well"
    @State private var hydration: String = "Normal"
    @State private var heart: String = "Normal"
    @State private var color: String = "Normal"
    @State private var workOfBreathingSet: Set<String> = ["Normal effort"]
    
    // Telemedicine: visit mode (persisted in DB column `visit_mode`)
    @State private var visitMode: String = "in_person"

    // UI choices for visit mode (stable codes)
    private let visitModeChoices: [String] = [
        "in_person",
        "telemedicine"
    ]
    // Telemedicine: PE assessment mode (persisted in DB column `pe_assessment_mode`)
    @State private var peAssessmentMode: String = "in_person"

    // UI choices for PE assessment mode (stable codes)
    private let peAssessmentModeChoices: [String] = [
        "in_person",
        "remote",
        "not_assessed"
    ]

    @State private var ent: Set<String> = ["Normal"]
    @State private var rightEar: String = "Normal"
    @State private var leftEar: String = "Normal"
    @State private var rightEye: String = "Normal"
    @State private var leftEye: String = "Normal"
    @State private var peristalsis: String = "Normal"
    @State private var neurological: String = "Alert"
    @State private var musculoskeletal: String = "Normal"
    @State private var skinSet: Set<String> = ["Normal"]
    @State private var lungsSet: Set<String> = ["Normal"]
    @State private var abdomenSet: Set<String> = ["Normal"]
    @State private var genitaliaSet: Set<String> = ["Normal"]
    @State private var lymphNodesSet: Set<String> = ["None"]
    

    // MARK: - Plan
    @State private var problemListing: String = ""
    @State private var complementaryInvestigations: String = ""
    @State private var diagnosis: String = ""
    @State private var icd10: String = ""
    @State private var medications: String = ""
    @State private var anticipatoryGuidance: String = "URI"
    @State private var comments: String = ""

    // MARK: - Episode signals (local clinical support)
    @State private var episodeSignals: [String] = []
    @State private var episodeSignalsLastUpdatedISO: String? = nil
    // MARK: - Guideline match details (clickable UI)
    private struct GuidelineMatchForUI: Identifiable, Equatable {
        let id: String          // ruleId
        let flag: String
        let note: String?
        let priority: Int
    }

    @State private var guidelineMatchesForUI: [GuidelineMatchForUI] = []
    

    // MARK: - AI assistance
    @State private var aiIsRunning: Bool = false
    @State private var aiPromptPreview: String = ""
    @State private var selectedAIHistoryID: Int? = nil

    // MARK: - Addenda
    @State private var addenda: [VisitAddendum] = []
    @State private var newAddendumText: String = ""
    @State private var addendaIsLoading: Bool = false
    @State private var addendaErrorMessage: String? = nil

    private let episodeStore = EpisodeStore()

    // MARK: - Vitals (UI fields)
    @State private var weightKgField: String = ""
    @State private var heightCmField: String = ""
    @State private var headCircumferenceField: String = ""
    @State private var temperatureCField: String = ""
    @State private var heartRateField: String = ""
    @State private var respiratoryRateField: String = ""
    @State private var spo2Field: String = ""
    @State private var bpSysField: String = ""
    @State private var bpDiaField: String = ""
    @State private var recordedAtField: String = ""
    @State private var replacePreviousVitals: Bool = false
    @EnvironmentObject var clinicianStore: ClinicianStore
    
    

    // In-memory vitals history for the current episode
    fileprivate struct VitalsRow: Identifiable {
        let id: Int64
        let recordedAt: String
        let weightKg: Double?
        let heightCm: Double?
        let headCircumferenceCm: Double?
        let temperatureC: Double?
        let heartRate: Int?
        let respiratoryRate: Int?
        let spo2: Int?
        let bpSys: Int?
        let bpDia: Int?
    }
    @State private var vitalsHistory: [VitalsRow] = []
    @State private var vitalsDeleteSelection: Int64? = nil

    // MARK: - Choices
    private let complaintOptions = [
        "Fever","Cough","Runny nose","Diarrhea","Vomiting",
        "Rash","Abdominal pain","Headache"
    ]
    private let appearanceChoices = ["Well","Tired","Irritable","Lethargic"]
    private let feedingChoices = ["Normal","Decreased","Refuses"]
    private let breathingChoices = ["Normal","Fast","Labored","Noisy"]
    private let urinationChoices = ["Normal","Decreased","Painful","Foul-smelling"]
    private let painChoices = ["None","Abdominal","Ear","Throat","Limb","Head","Neck"]
    private let stoolsChoices = ["Normal","Soft","Liquid","Hard","Bloody diarrhea"]
    private let contextChoices = ["Travel","Sick contact","Daycare","None"]

    private let generalChoices = ["Well","Tired","Irritable","Lethargic"]
    private let hydrationChoices = ["Normal","Decreased"]
    private let heartChoices = ["Normal","Murmur","Tachycardia","Bradycardia"]
    private let colorChoices = ["Normal","Pale","Yellow"]
    private let workOfBreathingOptionsMulti = [
        "Normal effort",
        "Tachypnea",
        "Retractions",
        "Nasal flaring",
        "Paradoxical breathing",
        "Grunting",
        "Stridor"
    ]

    // ENT stays multi-select; add tonsil deposits
    private let entChoices = ["Normal","Red throat","Ear discharge","Congested nose","Tonsil deposits"]

    private let earChoices = ["Normal","Red TM","Red & Bulging with pus","Pus in canal","Not seen (wax)","Red canal"]

    // Eyes keep single-select; add eyelid swelling
    private let eyeChoices = ["Normal","Discharge","Red","Crusty","Eyelid swelling"]

    // NEW: multi-select option sets for certain PE sections
    private let skinOptionsMulti = [
        "Normal","Dry, scaly rash","Papular rash","Macular rash","Maculopapular rash","Petechiae","Purpura"
    ]
    private let lungsOptionsMulti = [
        "Normal",
        "Crackles","Crackles (R)","Crackles (L)",
        "Wheeze","Wheeze (R)","Wheeze (L)",
        "Rhonchi","Rhonchi (R)","Rhonchi (L)",
        "Decreased sounds","Decreased sounds (R)","Decreased sounds (L)"
    ]
    private let abdomenOptionsMulti = [
        "Normal","Tender","Distended",
        "Epigastric pain","Periumbilical pain","RLQ pain","LLQ pain","Hypogastric pain",
        "Guarding","Rebound"
    ]
    private let genitaliaOptionsMulti = ["Normal","Swelling","Redness","Discharge"]
    private let nodesOptionsMulti     = ["None","Cervical","Submandibular","Tender","Generalized"]

    private let peristalsisChoices = ["Normal","Increased","Decreased"]
    private let neuroChoices = ["Alert","Sleepy","Irritable","Abnormal tone"]
    private let mskChoices = ["Normal","Limping","Swollen joint","Pain"]

    private let guidanceChoices = ["See Plan","URI","AGE","UTI","Otitis"]

    private static let uiLog = AppLog.ui
    private static let dbLog = AppLog.db
    private let log = AppLog.feature("sickEpisode")

    init(editingEpisodeID: Int? = nil) {
        self.editingEpisodeID = editingEpisodeID
    }
    // Precomputed title text to keep `body` type-checking fast.
    private var formTitleText: String {
        if let id = editingEpisodeID {
            return String(
                format: NSLocalizedString(
                    "sickEpisode.title.editWithID",
                    comment: "Title for editing an existing sick episode with its numeric ID"
                ),
                id
            )
        } else {
            return NSLocalizedString(
                "sickEpisode.title.new",
                comment: "Title for creating a new sick episode"
            )
        }
    }
    
    private func vitalsBadgesRow(_ badges: [String]) -> some View {
        HStack(spacing: 8) {
            ForEach(badges, id: \.self) { b in
                Text(b)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.bottom, 4)
    }


    // MARK: - View sections (split up to help the compiler type-check faster)

    private var headerView: some View {
        HStack {
            Image(systemName: "stethoscope")
                .font(.system(size: 22))
            Text(formTitleText)
                .font(.title2.bold())
            Spacer()
        }
    }

    private var vitalsBadgesList: [String] {
        vitalsBadges()
    }
    
    // MARK: - Vitals validation UI
    private struct VitalsValidationAlert: Identifiable {
        let id = UUID()
        let message: String
    }

    @State private var vitalsValidationAlert: VitalsValidationAlert?

    private var vitalsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(NSLocalizedString("sick_episode_form.vitals.section_title", comment: "Section header for vitals"))

            // Live vitals classification badges
            let badges = vitalsBadgesList
            if !badges.isEmpty {
                vitalsBadgesRow(badges)
            }

            if activeEpisodeID == nil {
                Text(NSLocalizedString("sick_episode_form.vitals.save_episode_first_hint", comment: "Hint explaining that vitals entry is available only after saving the episode"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        TextField(NSLocalizedString("sick_episode_form.vitals.weight_kg.placeholder", comment: "Placeholder for weight in kilograms"), text: $weightKgField)
                            .textFieldStyle(.roundedBorder)
                        TextField(NSLocalizedString("sick_episode_form.vitals.height_cm.placeholder", comment: "Placeholder for height in centimeters"), text: $heightCmField)
                            .textFieldStyle(.roundedBorder)
                        TextField(NSLocalizedString("sick_episode_form.vitals.head_circ_cm.placeholder", comment: "Placeholder for head circumference in centimeters"), text: $headCircumferenceField)
                            .textFieldStyle(.roundedBorder)
                        TextField(NSLocalizedString("sick_episode_form.vitals.temperature_c.placeholder", comment: "Placeholder for temperature in Celsius"), text: $temperatureCField)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        TextField(NSLocalizedString("sick_episode_form.vitals.hr_bpm.placeholder", comment: "Placeholder for heart rate in beats per minute"), text: $heartRateField)
                            .textFieldStyle(.roundedBorder)
                        TextField(NSLocalizedString("sick_episode_form.vitals.rr_per_min.placeholder", comment: "Placeholder for respiratory rate per minute"), text: $respiratoryRateField)
                            .textFieldStyle(.roundedBorder)
                        TextField(NSLocalizedString("sick_episode_form.vitals.spo2_percent.placeholder", comment: "Placeholder for oxygen saturation in percent"), text: $spo2Field)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            TextField(NSLocalizedString("sick_episode_form.vitals.bp_systolic.placeholder", comment: "Placeholder for systolic blood pressure"), text: $bpSysField)
                                .textFieldStyle(.roundedBorder)
                            TextField(NSLocalizedString("sick_episode_form.vitals.bp_diastolic.placeholder", comment: "Placeholder for diastolic blood pressure"), text: $bpDiaField)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    GridRow {
                        TextField(NSLocalizedString("sick_episode_form.vitals.recorded_at_iso8601.placeholder", comment: "Placeholder for recorded-at timestamp"), text: $recordedAtField)
                            .textFieldStyle(.roundedBorder)
                            .help(NSLocalizedString("sick_episode_form.vitals.recorded_at_iso8601.help", comment: "Help text for recorded-at field"))
                        Toggle(NSLocalizedString("sick_episode_form.vitals.replace_previous_toggle", comment: "Option to replace existing vitals for this episode"), isOn: $replacePreviousVitals)
                            .toggleStyle(.switch)
                            .gridCellColumns(3)
                    }
                }

                HStack {
                    Button {
                        saveVitalsTapped()
                    } label: {
                        Label(NSLocalizedString("sick_episode_form.vitals.save_button", comment: "Button to save vitals"), systemImage: "heart.text.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(activeEpisodeID == nil)

                    Spacer()
                }

                if !vitalsHistory.isEmpty {
                    Divider()
                    Text(NSLocalizedString("sick_episode_form.vitals.history_title", comment: "Header for vitals history list"))
                        .font(.subheadline.bold())
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(vitalsHistory) { row in
                            HStack {
                                Text(row.recordedAt)
                                    .font(.caption.monospaced())
                                Spacer()
                                Text(summary(for: row))
                                    .font(.caption)
                            }
                        }
                    }
                    HStack {
                        Picker(NSLocalizedString("sick_episode_form.vitals.delete_picker.title", comment: "Title for the vitals row deletion picker"), selection: $vitalsDeleteSelection) {
                            Text(NSLocalizedString("sick_episode_form.vitals.delete_picker.none", comment: "Placeholder option for no vitals row selected"))
                                .tag(Int64?.none)
                            ForEach(vitalsHistory) { row in
                                Text("\(row.recordedAt)")
                                    .tag(Optional(row.id))
                            }
                        }
                        .labelsHidden()

                        Button(role: .destructive) {
                            deleteSelectedVitals()
                        } label: {
                            Label(NSLocalizedString("sick_episode_form.vitals.delete_button", comment: "Button label to delete the selected vitals row"), systemImage: "trash")
                        }
                        .disabled(vitalsDeleteSelection == nil)
                    }
                } else {
                    Text(NSLocalizedString("sick_episode_form.vitals.none_message", comment: "Message when no vitals have been recorded"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .lightBlueSectionCardStyle()
        .padding(.top, 8)
    }
    
    private var visitModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(NSLocalizedString(
                "sick_episode_form.telemed.visit_mode.section_title",
                comment: "Section header for visit mode"
            ))

            pickerRow(
                NSLocalizedString(
                    "sick_episode_form.telemed.visit_mode.label",
                    comment: "Label for visit mode picker"
                ),
                $visitMode,
                visitModeChoices
            )
            .help(NSLocalizedString(
                "sick_episode_form.telemed.visit_mode.help",
                comment: "Help for visit mode picker"
            ))
        }
        .padding(12)
        .lightBlueSectionCardStyle()
    }

    private var twoColumnSection: some View {
        HStack(alignment: .top, spacing: 20) {
            // Column A (left)
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(NSLocalizedString("sick_episode_form.section.main_complaint", comment: "Section header for main complaint"))
                complaintBlock

                SectionHeader(NSLocalizedString("sick_episode_form.section.hpi", comment: "Section header for HPI"))
                pickerRow(NSLocalizedString("sick_episode_form.hpi.appearance.label", comment: "Label for appearance picker"), $appearance, appearanceChoices)
                pickerRow(NSLocalizedString("sick_episode_form.hpi.feeding.label", comment: "Label for feeding picker"), $feeding, feedingChoices)
                pickerRow(NSLocalizedString("sick_episode_form.hpi.breathing.label", comment: "Label for breathing picker"), $breathing, breathingChoices)
                pickerRow(NSLocalizedString("sick_episode_form.hpi.urination.label", comment: "Label for urination picker"), $urination, urinationChoices)
                pickerRow(NSLocalizedString("sick_episode_form.hpi.pain.label", comment: "Label for pain picker"), $pain, painChoices)
                pickerRow(NSLocalizedString("sick_episode_form.hpi.stools.label", comment: "Label for stools picker"), $stools, stoolsChoices)
                multiSelectChips(title: NSLocalizedString("sick_episode_form.hpi.context.label", comment: "Label for context multiselect"), options: contextChoices, selection: $context)
                TextField(NSLocalizedString("sick_episode_form.hpi.summary.placeholder", comment: "Placeholder for HPI summary"), text: $hpi, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
                // Visible label so clinicians understand this is specifically the FEVER duration.
                Text(NSLocalizedString("sick_episode_form.hpi.fever_duration.label",
                                       comment: "Small label shown above the fever duration input"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    TextField(
                        NSLocalizedString("sick_episode_form.hpi.duration_value.placeholder",
                                          comment: "Placeholder for duration numeric value"),
                        text: $durationValue
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)

                    Picker("", selection: $durationUnit) {
                        ForEach(DurationUnit.allCases) { u in
                            Text(u.label).tag(u)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)

                    Spacer()
                }
                // Keep hover help as an extra hint on macOS.
                .help(NSLocalizedString("sick_episode_form.hpi.duration.help",
                                        comment: "Help text for duration input"))

                additionalPEInfoSection()
            }
            .padding(12)
            .lightBlueSectionCardStyle()
            .frame(maxWidth: .infinity, alignment: .topLeading)

            // Column B (right)
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(NSLocalizedString("sick_episode_form.section.physical_exam", comment: "Section header for physical exam"))
                pickerRow(
                    NSLocalizedString(
                        "sick_episode_form.telemed.pe_assessment_mode.label",
                        comment: "Label for PE assessment mode picker"
                    ),
                    $peAssessmentMode,
                    (visitMode == "telemedicine")
                        ? ["remote", "not_assessed"]
                        : ["in_person", "not_assessed"]
                )
                .help(NSLocalizedString(
                    "sick_episode_form.telemed.pe_assessment_mode.remote_help",
                    comment: "Help text for remote PE assessment mode"
                ))
                .onChange(of: visitMode) { newMode in
                    if newMode == "telemedicine", peAssessmentMode == "in_person" {
                            peAssessmentMode = "remote"
                    }
                    if newMode == "in_person", peAssessmentMode == "remote" {
                        peAssessmentMode = "in_person"
                    }
                }
                pickerRow(NSLocalizedString("sick_episode_form.pe.general_appearance.label", comment: "Label for general appearance picker"), $generalAppearance, generalChoices)
                pickerRow(NSLocalizedString("sick_episode_form.pe.hydration.label", comment: "Label for hydration picker"), $hydration, hydrationChoices)
                pickerRow(NSLocalizedString("sick_episode_form.pe.color_hemodynamics.label", comment: "Label for color/hemodynamics picker"), $color, colorChoices)
                workOfBreathingChips()
                multiSelectChips(title: NSLocalizedString("sick_episode_form.pe.skin.label", comment: "Label for skin multiselect"), options: skinOptionsMulti, selection: $skinSet)
                multiSelectChips(title: NSLocalizedString("sick_episode_form.pe.ent.label", comment: "Label for ENT multiselect"), options: entChoices, selection: $ent)
                pickerRow(NSLocalizedString("sick_episode_form.pe.right_ear.label", comment: "Label for right ear picker"), $rightEar, earChoices)
                pickerRow(NSLocalizedString("sick_episode_form.pe.left_ear.label", comment: "Label for left ear picker"), $leftEar, earChoices)
                pickerRow(NSLocalizedString("sick_episode_form.pe.right_eye.label", comment: "Label for right eye picker"), $rightEye, eyeChoices)
                pickerRow(NSLocalizedString("sick_episode_form.pe.left_eye.label", comment: "Label for left eye picker"), $leftEye, eyeChoices)
                pickerRow(NSLocalizedString("sick_episode_form.pe.heart.label", comment: "Label for heart picker"), $heart, heartChoices)
                multiSelectChips(title: NSLocalizedString("sick_episode_form.pe.lungs.label", comment: "Label for lungs multiselect"), options: lungsOptionsMulti, selection: $lungsSet)
                multiSelectChips(title: NSLocalizedString("sick_episode_form.pe.abdomen.label", comment: "Label for abdomen multiselect"), options: abdomenOptionsMulti, selection: $abdomenSet)
                pickerRow(NSLocalizedString("sick_episode_form.pe.peristalsis.label", comment: "Label for peristalsis picker"), $peristalsis, peristalsisChoices)
                multiSelectChips(title: NSLocalizedString("sick_episode_form.pe.genitalia.label", comment: "Label for genitalia multiselect"), options: genitaliaOptionsMulti, selection: $genitaliaSet)
                pickerRow(NSLocalizedString("sick_episode_form.pe.neurological.label", comment: "Label for neurological picker"), $neurological, neuroChoices)
                pickerRow(NSLocalizedString("sick_episode_form.pe.musculoskeletal.label", comment: "Label for musculoskeletal picker"), $musculoskeletal, mskChoices)
                multiSelectChips(title: NSLocalizedString("sick_episode_form.pe.lymph_nodes.label", comment: "Label for lymph nodes multiselect"), options: nodesOptionsMulti, selection: $lymphNodesSet)
            }
            .padding(12)
            .lightBlueSectionCardStyle()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(NSLocalizedString("sick_episode_form.section.problem_listing", comment: "Section header for problem listing"))
            HStack {
                Button {
                    generateProblemList()
                } label: {
                    Label(NSLocalizedString("sick_episode_form.problem_listing.generate_button", comment: "Button to generate problem listing"), systemImage: "brain.head.profile")
                }
                .buttonStyle(.borderedProminent)
                .help(NSLocalizedString("sick_episode_form.problem_listing.generate_help", comment: "Help for generating problem listing"))
                Button {
                    // Re-run local guideline evaluation and refresh the Episode Signals panel.
                    triggerGuidelineFlags()
                    refreshEpisodeSignals()
                } label: {
                    Label("Update guideline flags", systemImage: "flag.fill")
                }
                .buttonStyle(.bordered)
                .help("Re-evaluates local sick-visit rules and updates the Episode Signals panel below.")
                Spacer()
            }
            TextEditor(text: $problemListing)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))

            // Episode Signal Panel (local decision support)
            episodeSignalsPanel

            TextField(NSLocalizedString("sick_episode_form.problem_listing.complementary_investigations.placeholder", comment: "Placeholder for complementary investigations"), text: $complementaryInvestigations, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            TextField(NSLocalizedString("sick_episode_form.problem_listing.working_diagnosis.placeholder", comment: "Placeholder for working diagnosis"), text: $diagnosis)
                .textFieldStyle(.roundedBorder)
            TextField(NSLocalizedString("sick_episode_form.problem_listing.icd10.placeholder", comment: "Placeholder for ICD-10 code(s)"), text: $icd10)
                .textFieldStyle(.roundedBorder)
            SectionHeader(NSLocalizedString("sick_episode_form.section.plan", comment: "Section header for plan"))
            TextEditor(text: $medications)
                .frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
            pickerRow(NSLocalizedString("sick_episode_form.plan.anticipatory_guidance.label", comment: "Label for anticipatory guidance picker"), $anticipatoryGuidance, guidanceChoices)
        }
        .padding(12)
        .lightBlueSectionCardStyle()
        .padding(.top, 8)
    }

    

    private func refreshEpisodeSignals() {
        var lines: [String] = []

        // 1) Abnormal vitals badges already computed live
        let badges = vitalsBadgesList
        if !badges.isEmpty {
            let joined = badges.joined(separator: ", ")
            lines.append(String(format: NSLocalizedString(
                "sick_episode_form.episode_signals.vitals_badges",
                comment: "Line describing abnormal vitals badges in episode signals"
            ), joined))
        }

        // 2) Positive findings proxy: selected complaints + selected PE tokens
        let positivesCount = presetComplaints.count
            + skinSet.filter { $0 != "Normal" }.count
            + lungsSet.filter { $0 != "Normal" }.count
            + abdomenSet.filter { $0 != "Normal" }.count
            + ent.filter { $0 != "Normal" }.count
        lines.append(String(format: NSLocalizedString(
            "sick_episode_form.episode_signals.positives_count",
            comment: "Line showing a rough count of positive findings"
        ), positivesCount))

        // 3) Local guideline flags (already stored on AppState by the guideline check)
        let flags = appState.aiGuidelineFlagsForActiveEpisode
        if !flags.isEmpty {
            lines.append(String(format: NSLocalizedString(
                "sick_episode_form.episode_signals.guideline_flags_count",
                comment: "Line showing count of guideline flags"
            ), flags.count))

            // Show first 6 flags as bullets
            for f in flags.prefix(6) {
                let clean = f.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    lines.append("• \(clean)")
                }
            }

            if flags.count > 6 {
                lines.append("• …(+\(flags.count - 6) more)")
            }
        }


        // Save
        episodeSignals = lines
        episodeSignalsLastUpdatedISO = isoNow()
    }
    

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(NSLocalizedString("sick_episode_form.section.ai_assistance", comment: "Section header for AI assistance"))
            Text(NSLocalizedString("sick_episode_form.ai_assistance.description", comment: "Description of AI assistance behavior"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(NSLocalizedString(
                    "sick_episode_form.ai.disclaimer",
                    comment: "Disclaimer shown near AI assistance output to remind clinicians that AI output is informational and depends on prompt/data quality"
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            HStack {
                Button {
                    triggerGuidelineFlags()
                } label: {
                    Label(NSLocalizedString("sick_episode_form.ai_assistance.check_guideline_flags.button", comment: "Button to check JSON guideline flags"), systemImage: "exclamationmark.triangle")
                }
                .buttonStyle(.bordered)

                Button {
                    triggerAIForEpisode()
                } label: {
                    if aiIsRunning {
                        ProgressView()
                            .scaleEffect(0.7)
                            .padding(.trailing, 4)
                        Text(NSLocalizedString("sick_episode_form.ai_assistance.asking_ai.status", comment: "Status text while AI is running"))
                    } else {
                        Label(NSLocalizedString("sick_episode_form.ai_assistance.ask_ai.button", comment: "Button to send query to AI"), systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(aiIsRunning)

                Button {
                    previewAIPrompt()
                } label: {
                    Label(NSLocalizedString("sick_episode_form.ai_assistance.preview_ai_json.button", comment: "Button to preview AI JSON payload"), systemImage: "doc.plaintext")
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            // --- keep the rest of the existing AI UI exactly as-is, but moved here ---
            
            // ICD-10 suggestion UI (AI Assistance)
            if let icdSuggestion = appState.icd10SuggestionForActiveEpisode,
               !icdSuggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("sick_episode_form.ai_assistance.suggested_icd10.header", comment: "Header for suggested ICD-10 code"))
                        .font(.subheadline.bold())
                    Text(icdSuggestion)
                        .font(.caption)
                        .textSelection(.enabled)

                    HStack {
                        Button {
                            icd10 = icdSuggestion
                        } label: {
                            Label(NSLocalizedString("sick_episode_form.ai_assistance.apply_to_icd10.button", comment: "Button label to apply suggested ICD-10"), systemImage: "arrow.down.doc")
                        }
                        .buttonStyle(.bordered)

                        if !icd10.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(NSLocalizedString("sick_episode_form.ai_assistance.icd10_replace_warning", comment: "Warning about replacing current ICD-10 field"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                }
                .padding(8)
                .background(Color.green.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // All ICD-10-like codes detected in the latest AI note
            if !appState.aiICD10CandidatesForActiveEpisode.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("sick_episode_form.ai_assistance.icd10_candidates.header", comment: "Header for ICD-10 codes found in AI note"))
                        .font(.subheadline.bold())

                    Text(NSLocalizedString("sick_episode_form.ai_assistance.icd10_candidates.instruction", comment: "Instruction for using ICD-10 candidate buttons"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 70), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(appState.aiICD10CandidatesForActiveEpisode, id: \.self) { code in
                            Button {
                                appendICD10Code(code)
                            } label: {
                                Text(code)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if !appState.aiGuidelineFlagsForActiveEpisode.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("sick_episode_form.ai_assistance.guideline_flags.header", comment: "Header for guideline flags from local JSON"))
                        .font(.subheadline.bold())
                    ForEach(appState.aiGuidelineFlagsForActiveEpisode, id: \.self) { flag in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.yellow)
                            Text(flag)
                                .font(.caption)
                        }
                    }
                }
                .padding(8)
                .background(Color.yellow.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if !appState.aiSummariesForActiveEpisode.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("sick_episode_form.ai_assistance.ai_notes.header", comment: "Header for AI notes per provider"))
                        .font(.subheadline.bold())
                    ForEach(appState.aiSummariesForActiveEpisode.keys.sorted(), id: \.self) { provider in
                        if let text = appState.aiSummariesForActiveEpisode[provider] {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider == "local-stub"
                                     ? NSLocalizedString("sick_episode_form.ai_assistance.ai_stub.label", comment: "Label for local stub AI provider")
                                     : provider)
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                ScrollView {
                                    Text(text)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                }
                                .frame(minHeight: 120, maxHeight: 220)
                                .background(Color.secondary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.secondary.opacity(0.3))
                                )
                                .contextMenu {
                                    Button("Copy") {
                                        #if canImport(AppKit)
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(text, forType: .string)
                                        #elseif canImport(UIKit)
                                        UIPasteboard.general.string = text
                                        #endif
                                    }
                                }
                            }
                            .padding(6)
                            .background(Color.blue.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(8)
                .background(Color.blue.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if !appState.aiInputsForActiveEpisode.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(appState.aiInputsForActiveEpisode) { row in
                            Button {
                                selectedAIHistoryID = row.id
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(row.createdAtISO.isEmpty ? NSLocalizedString("sick_episode_form.ai_assistance.history.time_na", comment: "Fallback when timestamp is not available") : row.createdAtISO)
                                            .font(.caption2.monospaced())
                                        Spacer()
                                        Text(row.model.isEmpty ? NSLocalizedString("sick_episode_form.ai_assistance.history.provider_unknown", comment: "Fallback when AI provider is unknown") : row.model)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(row.responsePreview.isEmpty ? NSLocalizedString("sick_episode_form.ai_assistance.history.no_response_stored", comment: "Fallback when no AI response is stored") : row.responsePreview)
                                        .font(.caption)
                                        .lineLimit(2)
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    (selectedAIHistoryID == row.id
                                     ? Color.gray.opacity(0.12)
                                     : Color.gray.opacity(0.04))
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }

                        if let selectedID = selectedAIHistoryID,
                           let selectedRow = appState.aiInputsForActiveEpisode.first(where: { $0.id == selectedID }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(NSLocalizedString("sick_episode_form.ai_assistance.history.selected_response.header", comment: "Header for selected AI response viewer"))
                                    .font(.subheadline.bold())
                                ScrollView {
                                    Text(selectedRow.fullResponse.isEmpty ? NSLocalizedString("sick_episode_form.ai_assistance.history.no_response_stored", comment: "Fallback when no AI response is stored") : selectedRow.fullResponse)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(minHeight: 120, maxHeight: 260)
                                .padding(6)
                                .background(Color.gray.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .padding(.top, 8)

                            if let _ = selectedAIHistoryID {
                                HStack {
                                    Spacer()
                                    Button(role: .destructive) {
                                        deleteSelectedAIHistory()
                                    } label: {
                                        Label(NSLocalizedString("sick_episode_form.ai_assistance.history.delete_entry.button", comment: "Button to delete selected AI history entry"), systemImage: "trash")
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text(NSLocalizedString("sick_episode_form.ai_assistance.history.header", comment: "Header for AI history list"))
                        .font(.subheadline.bold())
                }
                .padding(8)
                .background(Color.gray.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if !aiPromptPreview.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("sick_episode_form.ai_assistance.structured_json_debug.header", comment: "Header for structured episode JSON debug view"))
                        .font(.subheadline.bold())
                    ScrollView {
                        Text(aiPromptPreview)
                            .font(.caption.monospacedDigit())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 120)
                    .padding(6)
                    .background(Color.gray.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding(8)
            }
        }
        .padding(12)
        .lightBlueSectionCardStyle()
    }

    private var addendaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(NSLocalizedString("sick_episode_form.section.addenda", comment: "Section header for visit addenda"))

            if activeEpisodeID == nil {
                Text(NSLocalizedString("sick_episode_form.addenda.save_episode_first_hint", comment: "Hint explaining that addenda are available only after saving the episode"))
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
                        loadAddenda()
                    } label: {
                        Label(NSLocalizedString("sick_episode_form.addenda.refresh_button", comment: "Refresh addenda list button"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    if addendaIsLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }

                if addenda.isEmpty {
                    Text(NSLocalizedString("sick_episode_form.addenda.none_message", comment: "Message when no addenda exist"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(addenda) { a in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(a.createdAtISO ?? NSLocalizedString("sick_episode_form.ai_assistance.history.time_na", comment: "Fallback when timestamp is not available"))
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

                Text(NSLocalizedString("sick_episode_form.addenda.new_addendum.header", comment: "Header for new addendum editor"))
                    .font(.subheadline.bold())

                ZStack(alignment: .topLeading) {
                    if newAddendumText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(NSLocalizedString("sick_episode_form.addenda.new_addendum.placeholder", comment: "Placeholder for new addendum text"))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 6)
                    }

                    TextEditor(text: $newAddendumText)
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
                        addAddendumTapped()
                    } label: {
                        Label(NSLocalizedString("sick_episode_form.addenda.add_button", comment: "Button to add an addendum"), systemImage: "plus.bubble")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(activeEpisodeID == nil || newAddendumText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || addendaIsLoading)
                }
            }
        }
        .padding(12)
        .lightBlueSectionCardStyle()
    }

    private var doneRow: some View {
        HStack {
            Spacer()
            Button(NSLocalizedString("common.done", comment: "Button to close the form")) {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, 8)
    }

    private var mainScrollContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerView
            vitalsSection
            visitModeSection
            twoColumnSection
            planSection
            aiSection
            addendaSection
            doneRow
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()

                ScrollView {
                    mainScrollContent
                        .padding(20)
                        .sheetCardStyle()
                        .padding(16)
                }
            }
            .frame(minWidth: 860, idealWidth: 980, maxWidth: .infinity,
                   minHeight: 580, idealHeight: 720, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Toolbar cancel button")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.save", comment: "Toolbar save button")) {
                        
                        AppLog.ui.info("SickEpisodeForm: SAVE tapped | pid=\(String(describing: appState.selectedPatientID), privacy: .private) episodeID=\(String(describing: activeEpisodeID), privacy: .private)")
                        saveTapped()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(NSLocalizedString("common.done", comment: "Toolbar done button")) { dismiss() }
                }
            }
            .onAppear {
                // If we are editing an existing episode, initialise activeEpisodeID from it
                if activeEpisodeID == nil, let eid = editingEpisodeID {
                    activeEpisodeID = Int64(eid)
                }
                // Clear any AI state from previous episodes
                appState.clearAIForEpisodeContext()
                loadEditingIfNeeded()
                prefillVitalsIfEditing()
                loadVitalsHistory()
                loadAddenda()
                refreshEpisodeSignals()
            }
            
            .alert(item: $vitalsValidationAlert) { alert in
                Alert(
                    title: Text(NSLocalizedString("sick_episode_form.vitals_validation.alert_title", comment: "Title for invalid vitals validation alert")),
                    message: Text(alert.message),
                    dismissButton: .default(Text(NSLocalizedString("common.ok", comment: "OK button")))
                )
            }
        }
    }

    // MARK: - Addenda actions

    private func loadAddenda() {
        guard let episodeID = activeEpisodeID else { return }
        guard let dbURL = appState.bundleDBURL else {
            addendaErrorMessage = NSLocalizedString("sick_episode_form.addenda.db_missing_error", comment: "Error when DB URL is missing")
            return
        }

        addendaIsLoading = true
        addendaErrorMessage = nil

        do {
            let rows = try episodeStore.fetchAddendaForEpisode(dbURL: dbURL, episodeID: episodeID)
            addenda = rows
        } catch {
            addendaErrorMessage = error.localizedDescription
        }

        addendaIsLoading = false
    }

    private func addAddendumTapped() {
        guard let episodeID = activeEpisodeID else { return }
        let text = newAddendumText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard let dbURL = appState.bundleDBURL else {
            addendaErrorMessage = NSLocalizedString("sick_episode_form.addenda.db_missing_error", comment: "Error when DB URL is missing")
            return
        }

        addendaIsLoading = true
        addendaErrorMessage = nil

        do {
            _ = try episodeStore.insertAddendumForEpisode(
                dbURL: dbURL,
                episodeID: episodeID,
                userID: appState.activeUserID.map(Int64.init),
                text: text
            )
            newAddendumText = ""
            loadAddenda()
        } catch {
            addendaErrorMessage = error.localizedDescription
        }

        addendaIsLoading = false
    }

    // MARK: - Subviews

    private var complaintBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("sick_episode_form.complaint.select_common_hint", comment: "Instruction to select common complaints"))
                .font(.caption)
                .foregroundStyle(.secondary)

            // Simple chip-like toggles in rows of 4 for predictable wrapping
            WrappingChips(strings: complaintOptions, selection: $presetComplaints)

            // Complaint-specific durations (shown only when complaint is selected)
            VStack(alignment: .leading, spacing: 8) {
                if presetComplaints.contains("Cough") {
                    complaintDurationRow(titleKey: "sick_episode_form.choice.cough", complaint: "Cough")
                }
                if presetComplaints.contains("Runny nose") {
                    complaintDurationRow(titleKey: "sick_episode_form.choice.runny_nose", complaint: "Runny nose")
                }
                if presetComplaints.contains("Vomiting") {
                    complaintDurationRow(titleKey: "sick_episode_form.choice.vomiting", complaint: "Vomiting")
                }
                if presetComplaints.contains("Diarrhea") {
                    complaintDurationRow(titleKey: "sick_episode_form.choice.diarrhea", complaint: "Diarrhea")
                }
                if presetComplaints.contains("Abdominal pain") {
                    complaintDurationRow(titleKey: "sick_episode_form.choice.abdominal_pain", complaint: "Abdominal pain")
                }
                if presetComplaints.contains("Rash") {
                    complaintDurationRow(titleKey: "sick_episode_form.choice.rash", complaint: "Rash")
                }
                if presetComplaints.contains("Headache") {
                    complaintDurationRow(titleKey: "sick_episode_form.choice.headache", complaint: "Headache")
                }
            }

            TextField(NSLocalizedString("sick_episode_form.complaint.other_complaints.placeholder", comment: "Text field for other complaints, comma-separated"), text: $otherComplaints)
                .textFieldStyle(.roundedBorder)

            // Duration for free-text “Other complaints” (shown only when free text is non-empty)
            if !otherComplaints.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                complaintDurationRow(
                    titleKey: "sick_episode_form.complaint.other.label",
                    complaint: "__other__"
                )
            }
        }
    }

    private func durationBinding(for complaint: String) -> Binding<DurationInput> {
        Binding<DurationInput>(
            get: { complaintDurations[complaint] ?? DurationInput() },
            set: { complaintDurations[complaint] = $0 }
        )
    }
    
    private func serializeDuration(_ input: DurationInput?) -> String? {
        guard let input else { return nil }
        let v = input.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return nil }
        return v + input.unit.rawValue // "48h" / "3d"
    }
    
    private func parseCompactDuration(_ raw: String?) -> DurationInput? {
        guard let raw else { return nil }
        let s0 = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s0.isEmpty else { return nil }
        let s = s0.lowercased()

        // Extract first integer
        let digits = s.replacingOccurrences(of: "[^0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = digits.split(separator: " ").first,
              let n = Int(first),
              n >= 0 else { return nil }

        // Detect unit
        let isDays = s.contains(" day") || s.hasSuffix("d") || s.contains(" days")
        let isHours = s.contains(" hour") || s.hasSuffix("h") || s.contains(" hours")

        if isDays && !isHours {
            return DurationInput(value: String(n), unit: .days)
        }
        if isHours && !isDays {
            return DurationInput(value: String(n), unit: .hours)
        }

        // Heuristic: <=72 => hours, else days
        if n <= 72 {
            return DurationInput(value: String(n), unit: .hours)
        } else {
            return DurationInput(value: String(n), unit: .days)
        }
    }

    private func pickerRow(_ title: String, _ selection: Binding<String>, _ options: [String]) -> some View {
        HStack {
            Text(title)
                .frame(width: 220, alignment: .leading)
                .foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { opt in
                    Text(sickChoiceText(opt)).tag(opt)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func multiSelectChips(title: String, options: [String], selection: Binding<Set<String>>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            // (Note: `title` is already passed in as a localized string where used above.)
            WrappingChips(strings: options, selection: selection)
        }
    }
    
    private func workOfBreathingChips() -> some View {
        // Enforce exclusivity: selecting any abnormal sign removes "Normal effort";
        // selecting "Normal effort" clears all others; never allow empty.
        let binding = Binding<Set<String>>(
            get: { workOfBreathingSet },
            set: { newValue in
                var v = newValue

                let abnormalSelected = v.contains(where: { $0 != "Normal effort" })
                if abnormalSelected {
                    v.remove("Normal effort")
                }

                if v.contains("Normal effort") {
                    v = ["Normal effort"]
                }

                if v.isEmpty {
                    v = ["Normal effort"]
                }

                workOfBreathingSet = v
            }
        )

        return multiSelectChips(
            title: NSLocalizedString(
                "sick_episode_form.pe.work_of_breathing.label",
                comment: "Label for work of breathing multiselect"
            ),
            options: workOfBreathingOptionsMulti,
            selection: binding
        )
    }


    @ViewBuilder
    private func complaintDurationRow(titleKey: String, complaint: String) -> some View {
        let b = durationBinding(for: complaint)

        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: NSLocalizedString(
                "sick_episode_form.hpi.complaint_duration.label_format",
                comment: "Label shown above a complaint-specific duration input; %@ is the complaint name"
            ), NSLocalizedString(titleKey, comment: "Complaint name")))
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField(
                    NSLocalizedString(
                        "sick_episode_form.hpi.duration_value.placeholder",
                        comment: "Placeholder for duration numeric value"
                    ),
                    text: b.value
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)

                Picker("", selection: b.unit) {
                    ForEach(DurationUnit.allCases) { u in
                        Text(u.label).tag(u)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                Spacer()
            }
            .help(NSLocalizedString(
                "sick_episode_form.hpi.duration.help",
                comment: "Help text for duration input"
            ))
        }
    }

    // MARK: - Additional PE Info Field (TextEditor + localized placeholder)
    @ViewBuilder
    fileprivate func additionalPEInfoSection() -> some View {
        SectionHeader(NSLocalizedString(
            "sick_episode_form.pe.additional_info.header",
            comment: "Section header for additional physical examination information"
        ))

        ZStack(alignment: .topLeading) {
            if comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(NSLocalizedString(
                    "sick_episode_form.pe.additional_info.placeholder",
                    comment: "Placeholder for additional physical examination information"
                ))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .padding(.leading, 6)
            }

            TextEditor(text: $comments)
                .frame(minHeight: 110)
                .padding(.horizontal, 2)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.25))
        )
    }

    // MARK: - Choice localization (display only)
    /// Normalizes choice values for robust display-time localization.
    /// We keep stored values stable, but strip common invisible/formatting characters that can
    /// prevent switch-case matching (NBSP, zero-width spaces, BOM) and normalize whitespace.
    private func normalizeChoiceValue(_ raw: String) -> String {
        var s = raw.precomposedStringWithCanonicalMapping

        // Replace NBSP with regular space.
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")

        // Remove zero-width and formatting characters that can sneak into stored values.
        let forbiddenScalars: Set<Unicode.Scalar> = [
            "\u{200B}", // ZERO WIDTH SPACE
            "\u{200C}", // ZERO WIDTH NON-JOINER
            "\u{200D}", // ZERO WIDTH JOINER
            "\u{2060}", // WORD JOINER
            "\u{FEFF}"  // ZERO WIDTH NO-BREAK SPACE / BOM
        ]
        s.unicodeScalars.removeAll { forbiddenScalars.contains($0) }

        // Collapse multiple whitespace into single spaces.
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        // Trim.
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Maps stable stored choice values (English “codes”) to localized display strings.
    /// IMPORTANT: Do not change the underlying stored values; only localize at display-time.
    private func sickChoiceText(_ raw: String) -> String {
        let s = normalizeChoiceValue(raw)
        switch s {
        // Complaints
        case "Fever": return NSLocalizedString("sick_episode_form.choice.fever", comment: "SickEpisodeForm choice")
        case "Cough": return NSLocalizedString("sick_episode_form.choice.cough", comment: "SickEpisodeForm choice")
        case "Runny nose": return NSLocalizedString("sick_episode_form.choice.runny_nose", comment: "SickEpisodeForm choice")
        case "Diarrhea": return NSLocalizedString("sick_episode_form.choice.diarrhea", comment: "SickEpisodeForm choice")
        case "Vomiting": return NSLocalizedString("sick_episode_form.choice.vomiting", comment: "SickEpisodeForm choice")
        case "Rash": return NSLocalizedString("sick_episode_form.choice.rash", comment: "SickEpisodeForm choice")
        case "Abdominal pain": return NSLocalizedString("sick_episode_form.choice.abdominal_pain", comment: "SickEpisodeForm choice")
        case "Headache": return NSLocalizedString("sick_episode_form.choice.headache", comment: "SickEpisodeForm choice")

        // Common single-choice values
        case "Normal": return NSLocalizedString("sick_episode_form.choice.normal", comment: "SickEpisodeForm choice")
        case "Well": return NSLocalizedString("sick_episode_form.choice.well", comment: "SickEpisodeForm choice")
        case "Tired": return NSLocalizedString("sick_episode_form.choice.tired", comment: "SickEpisodeForm choice")
        case "Irritable": return NSLocalizedString("sick_episode_form.choice.irritable", comment: "SickEpisodeForm choice")
        case "Lethargic": return NSLocalizedString("sick_episode_form.choice.lethargic", comment: "SickEpisodeForm choice")
        case "Decreased": return NSLocalizedString("sick_episode_form.choice.decreased", comment: "SickEpisodeForm choice")
        case "Refuses": return NSLocalizedString("sick_episode_form.choice.refuses", comment: "SickEpisodeForm choice")
        case "Fast": return NSLocalizedString("sick_episode_form.choice.fast", comment: "SickEpisodeForm choice")
        case "Labored": return NSLocalizedString("sick_episode_form.choice.labored", comment: "SickEpisodeForm choice")
        case "Noisy": return NSLocalizedString("sick_episode_form.choice.noisy", comment: "SickEpisodeForm choice")
        case "Painful": return NSLocalizedString("sick_episode_form.choice.painful", comment: "SickEpisodeForm choice")
        case "Foul-smelling": return NSLocalizedString("sick_episode_form.choice.foul_smelling", comment: "SickEpisodeForm choice")

        // Pain locations
        case "None": return NSLocalizedString("sick_episode_form.choice.none", comment: "SickEpisodeForm choice")
        case "Abdominal": return NSLocalizedString("sick_episode_form.choice.abdominal", comment: "SickEpisodeForm choice")
        case "Ear": return NSLocalizedString("sick_episode_form.choice.ear", comment: "SickEpisodeForm choice")
        case "Throat": return NSLocalizedString("sick_episode_form.choice.throat", comment: "SickEpisodeForm choice")
        case "Limb": return NSLocalizedString("sick_episode_form.choice.limb", comment: "SickEpisodeForm choice")
        case "Head": return NSLocalizedString("sick_episode_form.choice.head", comment: "SickEpisodeForm choice")
        case "Neck": return NSLocalizedString("sick_episode_form.choice.neck", comment: "SickEpisodeForm choice")

        // Stools
        case "Soft": return NSLocalizedString("sick_episode_form.choice.soft", comment: "SickEpisodeForm choice")
        case "Liquid": return NSLocalizedString("sick_episode_form.choice.liquid", comment: "SickEpisodeForm choice")
        case "Hard": return NSLocalizedString("sick_episode_form.choice.hard", comment: "SickEpisodeForm choice")
        case "Bloody diarrhea": return NSLocalizedString("sick_episode_form.choice.bloody_diarrhea", comment: "SickEpisodeForm choice")

        // Context
        case "Travel": return NSLocalizedString("sick_episode_form.choice.travel", comment: "SickEpisodeForm choice")
        case "Sick contact": return NSLocalizedString("sick_episode_form.choice.sick_contact", comment: "SickEpisodeForm choice")
        case "Daycare": return NSLocalizedString("sick_episode_form.choice.daycare", comment: "SickEpisodeForm choice")

        // Heart / color
        case "Murmur": return NSLocalizedString("sick_episode_form.choice.murmur", comment: "SickEpisodeForm choice")
        case "Tachycardia": return NSLocalizedString("sick_episode_form.choice.tachycardia", comment: "SickEpisodeForm choice")
        case "Bradycardia": return NSLocalizedString("sick_episode_form.choice.bradycardia", comment: "SickEpisodeForm choice")
        case "Pale": return NSLocalizedString("sick_episode_form.choice.pale", comment: "SickEpisodeForm choice")
        case "Yellow": return NSLocalizedString("sick_episode_form.choice.yellow", comment: "SickEpisodeForm choice")
            
        // Work of breathing (PE)
        case "Normal effort": return NSLocalizedString("sick_episode_form.choice.normal_effort", comment: "SickEpisodeForm choice")
        case "Tachypnea": return NSLocalizedString("sick_episode_form.choice.tachypnea", comment: "SickEpisodeForm choice")
        case "Retractions": return NSLocalizedString("sick_episode_form.choice.retractions", comment: "SickEpisodeForm choice")
        case "Nasal flaring": return NSLocalizedString("sick_episode_form.choice.nasal_flaring", comment: "SickEpisodeForm choice")
        case "Paradoxical breathing": return NSLocalizedString("sick_episode_form.choice.paradoxical_breathing", comment: "SickEpisodeForm choice")
        case "Grunting": return NSLocalizedString("sick_episode_form.choice.grunting", comment: "SickEpisodeForm choice")
        case "Stridor": return NSLocalizedString("sick_episode_form.choice.stridor", comment: "SickEpisodeForm choice")
            
        // Telemedicine / PE assessment mode (stable codes)
        case "in_person":
            return NSLocalizedString(
                "sick_episode_form.telemed.pe_assessment_mode.choice.in_person",
                comment: "PE assessment mode choice: in-person"
            )
        case "remote":
            return NSLocalizedString(
                "sick_episode_form.telemed.pe_assessment_mode.choice.remote",
                comment: "PE assessment mode choice: remote assessment"
            )
        case "not_assessed":
            return NSLocalizedString(
                "sick_episode_form.telemed.pe_assessment_mode.choice.not_assessed",
                comment: "PE assessment mode choice: not assessed"
            )

        // ENT
        case "Red throat": return NSLocalizedString("sick_episode_form.choice.red_throat", comment: "SickEpisodeForm choice")
        case "Ear discharge": return NSLocalizedString("sick_episode_form.choice.ear_discharge", comment: "SickEpisodeForm choice")
        case "Congested nose": return NSLocalizedString("sick_episode_form.choice.congested_nose", comment: "SickEpisodeForm choice")
        case "Tonsil deposits": return NSLocalizedString("sick_episode_form.choice.tonsil_deposits", comment: "SickEpisodeForm choice")

        // Ears
        case "Red TM": return NSLocalizedString("sick_episode_form.choice.red_tm", comment: "SickEpisodeForm choice")
        case "Red & Bulging with pus": return NSLocalizedString("sick_episode_form.choice.red_bulging_with_pus", comment: "SickEpisodeForm choice")
        case "Pus in canal": return NSLocalizedString("sick_episode_form.choice.pus_in_canal", comment: "SickEpisodeForm choice")
        case "Not seen (wax)": return NSLocalizedString("sick_episode_form.choice.not_seen_wax", comment: "SickEpisodeForm choice")
        case "Red canal": return NSLocalizedString("sick_episode_form.choice.red_canal", comment: "SickEpisodeForm choice")

        // Eyes
        case "Discharge": return NSLocalizedString("sick_episode_form.choice.discharge", comment: "SickEpisodeForm choice")
        case "Red": return NSLocalizedString("sick_episode_form.choice.red", comment: "SickEpisodeForm choice")
        case "Crusty": return NSLocalizedString("sick_episode_form.choice.crusty", comment: "SickEpisodeForm choice")
        case "Eyelid swelling": return NSLocalizedString("sick_episode_form.choice.eyelid_swelling", comment: "SickEpisodeForm choice")

        // Skin (multi)
        case "Dry, scaly rash": return NSLocalizedString("sick_episode_form.choice.dry_scaly_rash", comment: "SickEpisodeForm choice")
        case "Papular rash": return NSLocalizedString("sick_episode_form.choice.papular_rash", comment: "SickEpisodeForm choice")
        case "Macular rash": return NSLocalizedString("sick_episode_form.choice.macular_rash", comment: "SickEpisodeForm choice")
        case "Maculopapular rash": return NSLocalizedString("sick_episode_form.choice.maculopapular_rash", comment: "SickEpisodeForm choice")
        case "Petechiae": return NSLocalizedString("sick_episode_form.choice.petechiae", comment: "SickEpisodeForm choice")
        case "Purpura": return NSLocalizedString("sick_episode_form.choice.purpura", comment: "SickEpisodeForm choice")

        // Lungs (multi)
        case "Crackles": return NSLocalizedString("sick_episode_form.choice.crackles", comment: "SickEpisodeForm choice")
        case "Crackles (R)": return NSLocalizedString("sick_episode_form.choice.crackles_r", comment: "SickEpisodeForm choice")
        case "Crackles (L)": return NSLocalizedString("sick_episode_form.choice.crackles_l", comment: "SickEpisodeForm choice")
        case "Wheeze": return NSLocalizedString("sick_episode_form.choice.wheeze", comment: "SickEpisodeForm choice")
        case "Wheeze (R)": return NSLocalizedString("sick_episode_form.choice.wheeze_r", comment: "SickEpisodeForm choice")
        case "Wheeze (L)": return NSLocalizedString("sick_episode_form.choice.wheeze_l", comment: "SickEpisodeForm choice")
        case "Rhonchi": return NSLocalizedString("sick_episode_form.choice.rhonchi", comment: "SickEpisodeForm choice")
        case "Rhonchi (R)": return NSLocalizedString("sick_episode_form.choice.rhonchi_r", comment: "SickEpisodeForm choice")
        case "Rhonchi (L)": return NSLocalizedString("sick_episode_form.choice.rhonchi_l", comment: "SickEpisodeForm choice")
        case "Decreased sounds": return NSLocalizedString("sick_episode_form.choice.decreased_sounds", comment: "SickEpisodeForm choice")
        case "Decreased sounds (R)": return NSLocalizedString("sick_episode_form.choice.decreased_sounds_r", comment: "SickEpisodeForm choice")
        case "Decreased sounds (L)": return NSLocalizedString("sick_episode_form.choice.decreased_sounds_l", comment: "SickEpisodeForm choice")

        // Abdomen (multi)
        case "Tender": return NSLocalizedString("sick_episode_form.choice.tender", comment: "SickEpisodeForm choice")
        case "Distended": return NSLocalizedString("sick_episode_form.choice.distended", comment: "SickEpisodeForm choice")
        case "Epigastric pain": return NSLocalizedString("sick_episode_form.choice.epigastric_pain", comment: "SickEpisodeForm choice")
        case "Periumbilical pain": return NSLocalizedString("sick_episode_form.choice.periumbilical_pain", comment: "SickEpisodeForm choice")
        case "RLQ pain": return NSLocalizedString("sick_episode_form.choice.rlq_pain", comment: "SickEpisodeForm choice")
        case "LLQ pain": return NSLocalizedString("sick_episode_form.choice.llq_pain", comment: "SickEpisodeForm choice")
        case "Hypogastric pain": return NSLocalizedString("sick_episode_form.choice.hypogastric_pain", comment: "SickEpisodeForm choice")
        case "Guarding": return NSLocalizedString("sick_episode_form.choice.guarding", comment: "SickEpisodeForm choice")
        case "Rebound": return NSLocalizedString("sick_episode_form.choice.rebound", comment: "SickEpisodeForm choice")

        // Genitalia (multi)
        case "Swelling": return NSLocalizedString("sick_episode_form.choice.swelling", comment: "SickEpisodeForm choice")
        case "Redness": return NSLocalizedString("sick_episode_form.choice.redness", comment: "SickEpisodeForm choice")

        // Lymph nodes (multi)
        case "Cervical": return NSLocalizedString("sick_episode_form.choice.cervical", comment: "SickEpisodeForm choice")
        case "Submandibular": return NSLocalizedString("sick_episode_form.choice.submandibular", comment: "SickEpisodeForm choice")
        case "Generalized": return NSLocalizedString("sick_episode_form.choice.generalized", comment: "SickEpisodeForm choice")

        // Peristalsis
        case "Increased": return NSLocalizedString("sick_episode_form.choice.increased", comment: "SickEpisodeForm choice")

        // Neuro
        case "Alert": return NSLocalizedString("sick_episode_form.choice.alert", comment: "SickEpisodeForm choice")
        case "Sleepy": return NSLocalizedString("sick_episode_form.choice.sleepy", comment: "SickEpisodeForm choice")
        case "Abnormal tone": return NSLocalizedString("sick_episode_form.choice.abnormal_tone", comment: "SickEpisodeForm choice")

        // MSK
        case "Limping": return NSLocalizedString("sick_episode_form.choice.limping", comment: "SickEpisodeForm choice")
        case "Swollen joint": return NSLocalizedString("sick_episode_form.choice.swollen_joint", comment: "SickEpisodeForm choice")
        case "Pain": return NSLocalizedString("sick_episode_form.choice.pain", comment: "SickEpisodeForm choice")

        // Guidance
        case "See Plan": return NSLocalizedString("sick_episode_form.choice.see_plan", comment: "SickEpisodeForm choice")
        case "URI": return NSLocalizedString("sick_episode_form.choice.uri", comment: "SickEpisodeForm choice")
        case "AGE": return NSLocalizedString("sick_episode_form.choice.age", comment: "SickEpisodeForm choice")
        case "UTI": return NSLocalizedString("sick_episode_form.choice.uti", comment: "SickEpisodeForm choice")
        case "Otitis": return NSLocalizedString("sick_episode_form.choice.otitis", comment: "SickEpisodeForm choice")

        default:
            // Fallback: if we missed a value, show it normalized (still stable).
            return s
        }
    }

    // MARK: - DB Helpers (local insert/update)
    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    private func dbOpen(_ url: URL) throws -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            defer { if db != nil { sqlite3_close(db) } }
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(
                domain: "SickEpisodeForm.DB",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        format: NSLocalizedString(
                            "sick_episode_form.db.open_failed",
                            comment: "Error message when opening the SQLite database fails."
                        ),
                        msg
                    )
                ]
            )
        }
        return db
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let s = value, !s.isEmpty {
            sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }
    
    /// Ensure the active clinician exists in the bundle's `users` table.
    /// This keeps episodes.user_id resolvable inside db.sqlite for the viewer.
    private func ensureBundleUserRow(dbURL: URL) {
        // 1) We need an active user id
        guard let uid = appState.activeUserID else {
            AppLog.db.info("ensureBundleUserRow: no activeUserID, skipping users sync")
            return
        }

        // 2) Find the matching clinician in the local ClinicianStore
        guard let clinician = clinicianStore.users.first(where: { $0.id == uid }) else {
            AppLog.db.info("ensureBundleUserRow: no clinician match for id \(uid), skipping users sync")
            return
        }

        // 3) Open bundle DB
        var db: OpaquePointer?
        do {
            db = try dbOpen(dbURL)
        } catch {
            AppLog.db.error("ensureBundleUserRow: dbOpen failed")
            return
        }
        guard let db = db else { return }
        defer { sqlite3_close(db) }

        // 4) Ensure minimal users table (id, first_name, last_name)
        let createSQL = """
        CREATE TABLE IF NOT EXISTS users (
          id INTEGER PRIMARY KEY,
          first_name TEXT NOT NULL,
          last_name  TEXT NOT NULL
        );
        """
        if sqlite3_exec(db, createSQL, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            AppLog.db.error("SickEpisodeForm: ensureBundleUserRow CREATE TABLE failed | err=\(msg, privacy: .public)")
            return
        }

        // 5) Try UPDATE first
        var stmt: OpaquePointer?

        let updateSQL = "UPDATE users SET first_name = ?, last_name = ? WHERE id = ?;"
        if sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK {
            // We can reuse bindText helper
            bindText(stmt, 1, clinician.firstName)
            bindText(stmt, 2, clinician.lastName)
            sqlite3_bind_int64(stmt, 3, sqlite3_int64(uid))
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        let changed = sqlite3_changes(db)
        if changed > 0 {
            AppLog.db.info("ensureBundleUserRow: updated users row for id=\(uid)")
            return
        }

        // 6) If nothing was updated, INSERT a new row
        let insertSQL = "INSERT INTO users (id, first_name, last_name) VALUES (?, ?, ?);"
        if sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            AppLog.db.error("ensureBundleUserRow: INSERT prepare failed: \(msg, privacy: .public)")
            return
        }
        bindText(stmt, 2, clinician.firstName)
        bindText(stmt, 3, clinician.lastName)
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(uid))

        if sqlite3_step(stmt) == SQLITE_DONE {
            AppLog.db.info("ensureBundleUserRow: inserted users row for id=\(uid)")
        } else {
            let msg = String(cString: sqlite3_errmsg(db))
            AppLog.db.error("ensureBundleUserRow: INSERT step failed: \(msg, privacy: .public)")
        }
        sqlite3_finalize(stmt)
    }

    private func insertEpisode(dbURL: URL, patientID: Int64, payload: [String: Any]) throws -> Int64 {
        AppLog.db.info("SickEpisodeForm: insertEpisode start | db=\(dbURL.path, privacy: .private) pid=\(patientID, privacy: .private)")
        var db: OpaquePointer?
        db = try dbOpen(dbURL)
        defer { if db != nil { sqlite3_close(db) } }

        let sql = """
        INSERT INTO episodes (
          patient_id, user_id, created_at,
          main_complaint, hpi, duration, visit_mode,
          dur_other, dur_cough, dur_runny_nose, dur_vomiting, dur_diarrhea, dur_abdominal_pain, dur_rash, dur_headache,
          appearance, feeding, breathing, urination, pain, stools, context,
          general_appearance, hydration, heart, color, pe_assessment_mode, 
        work_of_breathing, skin,
          ent, right_ear, left_ear, right_eye, left_eye,
          lungs, abdomen, peristalsis, genitalia,
          neurological, musculoskeletal, lymph_nodes,
          problem_listing, complementary_investigations, diagnosis, icd10, medications,
          anticipatory_guidance, comments
        ) VALUES ( ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? );
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SickEpisodeForm.DB", code: 2, userInfo: [NSLocalizedDescriptionKey: "prepare insert failed: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }

        func str(_ k: String) -> String? { payload[k] as? String }

        // 1: patient_id
        sqlite3_bind_int64(stmt, 1, patientID)

        // 2: user_id (from activeUserID, or NULL if none)
        if let uid = appState.activeUserID {
            sqlite3_bind_int64(stmt, 2, sqlite3_int64(uid))
        } else {
            sqlite3_bind_null(stmt, 2)
        }

        // 3: created_at
        bindText(stmt, 3, isoNow())

        // 4.. end: follow the column order above
        bindText(stmt, 4,  str("main_complaint"))
        bindText(stmt, 5,  str("hpi"))
        bindText(stmt, 6,  str("duration"))
        bindText(stmt, 7,  str("visit_mode"))
        bindText(stmt, 8,  str("dur_other"))
        bindText(stmt, 9,  str("dur_cough"))
        bindText(stmt, 10,  str("dur_runny_nose"))
        bindText(stmt, 11, str("dur_vomiting"))
        bindText(stmt, 12, str("dur_diarrhea"))
        bindText(stmt, 13, str("dur_abdominal_pain"))
        bindText(stmt, 14, str("dur_rash"))
        bindText(stmt, 15, str("dur_headache"))
        bindText(stmt, 16, str("appearance"))
        bindText(stmt, 17, str("feeding"))
        bindText(stmt, 18, str("breathing"))
        bindText(stmt, 19, str("urination"))
        bindText(stmt, 20, str("pain"))
        bindText(stmt, 21, str("stools"))
        bindText(stmt, 22, str("context"))
        bindText(stmt, 23, str("general_appearance"))
        bindText(stmt, 24, str("hydration"))
        bindText(stmt, 25, str("heart"))
        bindText(stmt, 26, str("color"))
        bindText(stmt, 27, str("pe_assessment_mode"))
        bindText(stmt, 28, str("work_of_breathing"))
        bindText(stmt, 29, str("skin"))
        bindText(stmt, 30, str("ent"))
        bindText(stmt, 31, str("right_ear"))
        bindText(stmt, 32, str("left_ear"))
        bindText(stmt, 33, str("right_eye"))
        bindText(stmt, 34, str("left_eye"))
        bindText(stmt, 35, str("lungs"))
        bindText(stmt, 36, str("abdomen"))
        bindText(stmt, 37, str("peristalsis"))
        bindText(stmt, 38, str("genitalia"))
        bindText(stmt, 39, str("neurological"))
        bindText(stmt, 40, str("musculoskeletal"))
        bindText(stmt, 41, str("lymph_nodes"))
        bindText(stmt, 42, str("problem_listing"))
        bindText(stmt, 43, str("complementary_investigations"))
        bindText(stmt, 44, str("diagnosis"))
        bindText(stmt, 45, str("icd10"))
        bindText(stmt, 46, str("medications"))
        bindText(stmt, 47, str("anticipatory_guidance"))
        bindText(stmt, 48, str("comments"))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            AppLog.db.error("SickEpisodeForm: insertEpisode failed | pid=\(patientID, privacy: .private) db=\(dbURL.lastPathComponent, privacy: .public) err=\(msg, privacy: .public)")
            throw NSError(domain: "SickEpisodeForm.DB", code: 3, userInfo: [NSLocalizedDescriptionKey: "insert step failed: \(msg)"])
        }
        return sqlite3_last_insert_rowid(db)
    }

    private func updateEpisode(dbURL: URL, episodeID: Int64, payload: [String: Any]) throws {
        var db: OpaquePointer?
        db = try dbOpen(dbURL)
        defer { if db != nil { sqlite3_close(db) } }

        let sql = """
        UPDATE episodes SET
          main_complaint = ?, hpi = ?, duration = ?, visit_mode = ?,
          dur_other = ?, dur_cough = ?, dur_runny_nose = ?, dur_vomiting = ?, dur_diarrhea = ?, dur_abdominal_pain = ?, dur_rash = ?, dur_headache = ?,
          appearance = ?, feeding = ?, breathing = ?, urination = ?, pain = ?, stools = ?, context = ?,
          general_appearance = ?, hydration = ?, heart = ?, color = ?, pe_assessment_mode = ?, work_of_breathing = ?, skin = ?,
          ent = ?, right_ear = ?, left_ear = ?, right_eye = ?, left_eye = ?,
          lungs = ?, abdomen = ?, peristalsis = ?, genitalia = ?,
          neurological = ?, musculoskeletal = ?, lymph_nodes = ?,
          problem_listing = ?, complementary_investigations = ?, diagnosis = ?, icd10 = ?, medications = ?,
          anticipatory_guidance = ?, comments = ?
        WHERE id = ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SickEpisodeForm.DB", code: 4, userInfo: [NSLocalizedDescriptionKey: "prepare update failed: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }

        func str(_ k: String) -> String? { payload[k] as? String }

        // Follow the order in the UPDATE
        bindText(stmt, 1,  str("main_complaint"))
        bindText(stmt, 2,  str("hpi"))
        bindText(stmt, 3,  str("duration"))
        bindText(stmt, 4,  str("visit_mode"))
        bindText(stmt, 5,  str("dur_other"))
        bindText(stmt, 6,  str("dur_cough"))
        bindText(stmt, 7,  str("dur_runny_nose"))
        bindText(stmt, 8,  str("dur_vomiting"))
        bindText(stmt, 9,  str("dur_diarrhea"))
        bindText(stmt, 10,  str("dur_abdominal_pain"))
        bindText(stmt, 11, str("dur_rash"))
        bindText(stmt, 12, str("dur_headache"))
        bindText(stmt, 13, str("appearance"))
        bindText(stmt, 14, str("feeding"))
        bindText(stmt, 15, str("breathing"))
        bindText(stmt, 16, str("urination"))
        bindText(stmt, 17, str("pain"))
        bindText(stmt, 18, str("stools"))
        bindText(stmt, 19, str("context"))
        bindText(stmt, 20, str("general_appearance"))
        bindText(stmt, 21, str("hydration"))
        bindText(stmt, 22, str("heart"))
        bindText(stmt, 23, str("color"))
        bindText(stmt, 24, str("pe_assessment_mode"))
        bindText(stmt, 25, str("work_of_breathing"))
        bindText(stmt, 26, str("skin"))
        bindText(stmt, 27, str("ent"))
        bindText(stmt, 28, str("right_ear"))
        bindText(stmt, 29, str("left_ear"))
        bindText(stmt, 30, str("right_eye"))
        bindText(stmt, 31, str("left_eye"))
        bindText(stmt, 32, str("lungs"))
        bindText(stmt, 33, str("abdomen"))
        bindText(stmt, 34, str("peristalsis"))
        bindText(stmt, 35, str("genitalia"))
        bindText(stmt, 36, str("neurological"))
        bindText(stmt, 37, str("musculoskeletal"))
        bindText(stmt, 38, str("lymph_nodes"))
        bindText(stmt, 39, str("problem_listing"))
        bindText(stmt, 340, str("complementary_investigations"))
        bindText(stmt, 41, str("diagnosis"))
        bindText(stmt, 42, str("icd10"))
        bindText(stmt, 43, str("medications"))
        bindText(stmt, 44, str("anticipatory_guidance"))
        bindText(stmt, 45, str("comments"))

        sqlite3_bind_int64(stmt, 46, episodeID)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            AppLog.db.error("SickEpisodeForm: updateEpisode failed | episodeID=\(episodeID, privacy: .private) db=\(dbURL.lastPathComponent, privacy: .public) err=\(msg, privacy: .public)")
            throw NSError(domain: "SickEpisodeForm.DB", code: 5, userInfo: [NSLocalizedDescriptionKey: "update step failed: \(msg)"])
        }
        AppLog.db.info("SickEpisodeForm: updateEpisode success | episodeID=\(episodeID, privacy: .private) changes=\(sqlite3_changes(db), privacy: .public)")
    }

    /// Ensure the `episodes` table exists with the expected schema.
    private func ensureEpisodesTable(dbURL: URL) throws {
        var db: OpaquePointer?
        db = try dbOpen(dbURL)
        defer { if db != nil { sqlite3_close(db) } }

        let sql = """
        CREATE TABLE IF NOT EXISTS episodes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          patient_id INTEGER,
          user_id INTEGER,
          created_at TEXT DEFAULT CURRENT_TIMESTAMP,
          main_complaint TEXT,
          hpi TEXT,
          duration TEXT,
          appearance TEXT,
          feeding TEXT,
          breathing TEXT,
          urination TEXT,
          pain TEXT,
          stools TEXT,
          context TEXT,
          general_appearance TEXT,
          hydration TEXT,
          color TEXT,
          skin TEXT,
          ent TEXT,
          right_ear TEXT,
          left_ear TEXT,
          right_eye TEXT,
          left_eye TEXT,
          heart TEXT,
          lungs TEXT,
          abdomen TEXT,
          peristalsis TEXT,
          genitalia TEXT,
          neurological TEXT,
          musculoskeletal TEXT,
          lymph_nodes TEXT,
          problem_listing TEXT,
          complementary_investigations TEXT,
          diagnosis TEXT,
          icd10 TEXT,
          medications TEXT,
          anticipatory_guidance TEXT,
          comments TEXT
        );
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SickEpisodeForm.DB", code: 10, userInfo: [NSLocalizedDescriptionKey: "schema ensure failed: \(msg)"])
        }
    }

    /// Debug helper: log count of episodes for patient to verify persistence path.
    private func debugCountEpisodes(dbURL: URL, patientID: Int64) {
        var db: OpaquePointer?
        do { db = try dbOpen(dbURL) } catch {
            AppLog.db.error("debugCountEpisodes: open failed")
            return
        }
        defer { if db != nil { sqlite3_close(db) } }
        let sql = "SELECT COUNT(*) FROM episodes WHERE patient_id=?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, patientID)
        if sqlite3_step(stmt) == SQLITE_ROW {
            let c = sqlite3_column_int64(stmt, 0)
            AppLog.db.debug("SickEpisodeForm: debugCountEpisodes | pid=\(patientID, privacy: .private) count=\(c, privacy: .public)")
        }
    }

    // MARK: - Vitals DB helpers

    /// Ensure the `manual_growth` table exists *and* has the expected schema.
    /// Some legacy/imported bundles may have an old or placeholder `manual_growth`
    /// definition that does not include weight_kg/height_cm/head_circumference_cm,
    /// which breaks the vitals→manual_growth triggers. Here we:
    ///  - check if the table exists
    ///  - if it exists, inspect its columns via PRAGMA table_info
    ///  - if the schema is missing the key growth columns, we DROP and recreate it
    ///  - if it does not exist, we create it with the canonical schema
    private func ensureManualGrowthTable(dbURL: URL) throws {
        var db: OpaquePointer?
        db = try dbOpen(dbURL)
        defer { if db != nil { sqlite3_close(db) } }

        // Helper to throw with a consistent NSError
        func makeError(_ message: String) -> NSError {
            return NSError(
                domain: "SickEpisodeForm.DB",
                code: 19,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        // 1. Does manual_growth exist?
        var stmt: OpaquePointer?
        let existsSQL = "SELECT name FROM sqlite_master WHERE type='table' AND name='manual_growth';"
        var tableExists = false
        if sqlite3_prepare_v2(db, existsSQL, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                tableExists = true
            }
        } else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(stmt)
            throw makeError("check manual_growth existence failed: \(msg)")
        }
        sqlite3_finalize(stmt)

        var needsRecreate = false

        if tableExists {
            // 2. Inspect schema; we expect weight_kg, height_cm, head_circumference_cm
            let pragmaSQL = "PRAGMA table_info(manual_growth);"
            if sqlite3_prepare_v2(db, pragmaSQL, -1, &stmt, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                throw makeError("PRAGMA table_info(manual_growth) failed: \(msg)")
            }

            var hasWeight = false
            var hasHeight = false
            var hasHC = false

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cName = sqlite3_column_text(stmt, 1) { // column name is at index 1
                    let name = String(cString: cName)
                    if name == "weight_kg" { hasWeight = true }
                    if name == "height_cm" { hasHeight = true }
                    if name == "head_circumference_cm" { hasHC = true }
                }
            }
            sqlite3_finalize(stmt)

            if !(hasWeight && hasHeight && hasHC) {
                // Schema is not compatible with the triggers that expect these columns.
                needsRecreate = true
            }
        }

        if needsRecreate {
            // 3. Drop the incompatible table so we can recreate it cleanly
            let dropSQL = "DROP TABLE IF EXISTS manual_growth;"
            if sqlite3_exec(db, dropSQL, nil, nil, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                throw makeError("drop manual_growth failed: \(msg)")
            }
            tableExists = false
        }

        if !tableExists {
            // 4. Create with the canonical schema used by your main DB:
            //    id, patient_id, recorded_at, weight_kg, height_cm, head_circumference_cm,
            //    source, created_at, updated_at
            let createSQL = """
            CREATE TABLE IF NOT EXISTS manual_growth (
              id INTEGER PRIMARY KEY,
              patient_id INTEGER NOT NULL,
              recorded_at TEXT NOT NULL,  -- ISO date or datetime
              weight_kg REAL,
              height_cm REAL,
              head_circumference_cm REAL,
              source TEXT DEFAULT 'manual',
              created_at TEXT DEFAULT CURRENT_TIMESTAMP,
              updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
              FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE
            );
            """
            if sqlite3_exec(db, createSQL, nil, nil, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                throw makeError("create manual_growth failed: \(msg)")
            }
        }
    }

    private func ensureVitalsTable(dbURL: URL) throws {
        var db: OpaquePointer?
        db = try dbOpen(dbURL)
        defer { if db != nil { sqlite3_close(db) } }
        let sql = """
        CREATE TABLE IF NOT EXISTS vitals (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          patient_id INTEGER,
          episode_id INTEGER,
          weight_kg REAL,
          height_cm REAL,
          head_circumference_cm REAL,
          temperature_c REAL,
          heart_rate INTEGER,
          respiratory_rate INTEGER,
          spo2 INTEGER,
          recorded_at TEXT DEFAULT CURRENT_TIMESTAMP,
          bp_systolic INTEGER,
          bp_diastolic INTEGER,
          FOREIGN KEY (patient_id) REFERENCES patients(id),
          FOREIGN KEY (episode_id) REFERENCES episodes(id)
        );
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SickEpisodeForm.DB", code: 20, userInfo: [NSLocalizedDescriptionKey: "ensure vitals table failed: \(msg)"])
        }
    }

    private func latestVitalsRow(dbURL: URL, episodeID: Int64) -> VitalsRow? {
        var db: OpaquePointer?
        do { db = try dbOpen(dbURL) } catch { return nil }
        defer { if db != nil { sqlite3_close(db) } }
        let sql = """
        SELECT id, recorded_at, weight_kg, height_cm, head_circumference_cm,
               temperature_c, heart_rate, respiratory_rate, spo2, bp_systolic, bp_diastolic
        FROM vitals
        WHERE episode_id = ?
        ORDER BY datetime(COALESCE(recorded_at, '1970-01-01T00:00:00')) DESC, id DESC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, episodeID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        func dcol(_ i: Int32) -> Double? {
            let t = sqlite3_column_type(stmt, i)
            if t == SQLITE_NULL { return nil }
            return sqlite3_column_double(stmt, i)
        }
        func icol(_ i: Int32) -> Int? {
            let t = sqlite3_column_type(stmt, i)
            if t == SQLITE_NULL { return nil }
            return Int(sqlite3_column_int(stmt, i))
        }
        let id = sqlite3_column_int64(stmt, 0)
        let ts = (sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) }) ?? ""
        return VitalsRow(
            id: id,
            recordedAt: ts,
            weightKg: dcol(2),
            heightCm: dcol(3),
            headCircumferenceCm: dcol(4),
            temperatureC: dcol(5),
            heartRate: icol(6),
            respiratoryRate: icol(7),
            spo2: icol(8),
            bpSys: icol(9),
            bpDia: icol(10)
        )
    }

    private func listVitalsForEpisode(dbURL: URL, episodeID: Int64) -> [VitalsRow] {
        var out: [VitalsRow] = []
        var db: OpaquePointer?
        do { db = try dbOpen(dbURL) } catch { return out }
        defer { if db != nil { sqlite3_close(db) } }
        let sql = """
        SELECT id, recorded_at, weight_kg, height_cm, head_circumference_cm,
               temperature_c, heart_rate, respiratory_rate, spo2, bp_systolic, bp_diastolic
        FROM vitals
        WHERE episode_id = ?
        ORDER BY datetime(COALESCE(recorded_at, '1970-01-01T00:00:00')) ASC, id ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, episodeID)
        while sqlite3_step(stmt) == SQLITE_ROW {
            func dcol(_ i: Int32) -> Double? {
                let t = sqlite3_column_type(stmt, i)
                if t == SQLITE_NULL { return nil }
                return sqlite3_column_double(stmt, i)
            }
            func icol(_ i: Int32) -> Int? {
                let t = sqlite3_column_type(stmt, i)
                if t == SQLITE_NULL { return nil }
                return Int(sqlite3_column_int(stmt, i))
            }
            let id = sqlite3_column_int64(stmt, 0)
            let ts = (sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) }) ?? ""
            out.append(
                VitalsRow(
                    id: id,
                    recordedAt: ts,
                    weightKg: dcol(2),
                    heightCm: dcol(3),
                    headCircumferenceCm: dcol(4),
                    temperatureC: dcol(5),
                    heartRate: icol(6),
                    respiratoryRate: icol(7),
                    spo2: icol(8),
                    bpSys: icol(9),
                    bpDia: icol(10)
                )
            )
        }
        return out
    }

    private func deleteVitalsRow(dbURL: URL, id: Int64) -> Bool {
        var db: OpaquePointer?
        do { db = try dbOpen(dbURL) } catch { return false }
        defer { if db != nil { sqlite3_close(db) } }
        let sql = "DELETE FROM vitals WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func deleteAllVitalsForEpisode(dbURL: URL, episodeID: Int64) -> Int {
        var db: OpaquePointer?
        do { db = try dbOpen(dbURL) } catch { return 0 }
        defer { if db != nil { sqlite3_close(db) } }
        let sql = "DELETE FROM vitals WHERE episode_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, episodeID)
        if sqlite3_step(stmt) == SQLITE_DONE {
            return Int(sqlite3_changes(db))
        }
        return 0
    }

    private func insertVitals(
        dbURL: URL,
        patientID: Int64,
        episodeID: Int64,
        weightKg: Double?, heightCm: Double?, headCircumferenceCm: Double?,
        temperatureC: Double?, heartRate: Int?, respiratoryRate: Int?, spo2: Int?,
        bpSys: Int?, bpDia: Int?,
        recordedAtISO: String?
    ) throws -> Int64 {
        var db: OpaquePointer?
        db = try dbOpen(dbURL)
        defer { if db != nil { sqlite3_close(db) } }
        let sql = """
        INSERT INTO vitals (
          patient_id, episode_id, weight_kg, height_cm, head_circumference_cm,
          temperature_c, heart_rate, respiratory_rate, spo2,
          bp_systolic, bp_diastolic, recorded_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SickEpisodeForm.DB", code: 21, userInfo: [NSLocalizedDescriptionKey: "prepare vitals insert failed: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, patientID)
        sqlite3_bind_int64(stmt, 2, episodeID)
        if let x = weightKg { sqlite3_bind_double(stmt, 3, x) } else { sqlite3_bind_null(stmt, 3) }
        if let x = heightCm { sqlite3_bind_double(stmt, 4, x) } else { sqlite3_bind_null(stmt, 4) }
        if let x = headCircumferenceCm { sqlite3_bind_double(stmt, 5, x) } else { sqlite3_bind_null(stmt, 5) }
        if let x = temperatureC { sqlite3_bind_double(stmt, 6, x) } else { sqlite3_bind_null(stmt, 6) }
        if let x = heartRate { sqlite3_bind_int(stmt, 7, Int32(x)) } else { sqlite3_bind_null(stmt, 7) }
        if let x = respiratoryRate { sqlite3_bind_int(stmt, 8, Int32(x)) } else { sqlite3_bind_null(stmt, 8) }
        if let x = spo2 { sqlite3_bind_int(stmt, 9, Int32(x)) } else { sqlite3_bind_null(stmt, 9) }
        if let x = bpSys { sqlite3_bind_int(stmt, 10, Int32(x)) } else { sqlite3_bind_null(stmt, 10) }
        if let x = bpDia { sqlite3_bind_int(stmt, 11, Int32(x)) } else { sqlite3_bind_null(stmt, 11) }
        bindText(stmt, 12, (recordedAtISO?.isEmpty == false ? recordedAtISO : isoNow()))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SickEpisodeForm.DB", code: 22, userInfo: [NSLocalizedDescriptionKey: "vitals insert step failed: \(msg)"])
        }
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Editing Prefill Helpers

    /// Load the episode from DB if we're in edit mode and prefill the form.
    private func loadEditingIfNeeded() {
        guard let eid = editingEpisodeID,
              let dbURL = appState.currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else {
            return
        }
        if let row = fetchEpisodeRow(dbURL: dbURL, id: Int64(eid)) {
            prefillFromRow(row)
        }
    }

    /// Fetch a single episode row as a string dictionary keyed by column name.
    private func fetchEpisodeRow(dbURL: URL, id: Int64) -> [String: String]? {
        var db: OpaquePointer?
        do { db = try dbOpen(dbURL) } catch { return nil }
        defer { if db != nil { sqlite3_close(db) } }

        let sql = """
        SELECT main_complaint, hpi, duration, visit_mode,
               dur_other, dur_cough, dur_runny_nose, dur_vomiting, dur_diarrhea, dur_abdominal_pain, dur_rash, dur_headache,
               appearance, feeding, breathing, urination, pain, stools, context,
               general_appearance, hydration, heart, color, pe_assessment_mode, work_of_breathing, skin,
               ent, right_ear, left_ear, right_eye, left_eye,
               lungs, abdomen, peristalsis, genitalia,
               neurological, musculoskeletal, lymph_nodes,
               problem_listing, complementary_investigations, diagnosis, icd10, medications,
               anticipatory_guidance, comments
        FROM episodes
        WHERE id = ?
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        func col(_ i: Int32) -> String? {
            if let c = sqlite3_column_text(stmt, i) {
                return String(cString: c)
            }
            return nil
        }

        let keys = [
            "main_complaint","hpi","duration", "visit_mode",
            "dur_other","dur_cough","dur_runny_nose","dur_vomiting","dur_diarrhea","dur_abdominal_pain","dur_rash","dur_headache",
            "appearance","feeding","breathing","urination","pain","stools","context",
            "general_appearance","hydration","heart","color", "pe_assessment_mode", "work_of_breathing","skin",
            "ent","right_ear","left_ear","right_eye","left_eye",
            "lungs","abdomen","peristalsis","genitalia",
            "neurological","musculoskeletal","lymph_nodes",
            "problem_listing","complementary_investigations","diagnosis","icd10","medications",
            "anticipatory_guidance","comments"
        ]
        var out: [String: String] = [:]
        for (idx, key) in keys.enumerated() {
            out[key] = col(Int32(idx)) ?? ""
        }
        return out
    }

    /// Assign picker value only if it exists in the allowed list.
    private func assignPicker(_ value: String?, allowed: [String], assign: (String) -> Void) {
        if let v = value, allowed.contains(v) {
            assign(v)
        }
    }

    /// Split a comma or comma+space separated string, trimmed; filters empty parts.
    private func splitTrim(_ s: String?) -> [String] {
        guard let s = s, !s.isEmpty else { return [] }
        return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Prefill all @State fields from a row dict.
    private func prefillFromRow(_ row: [String: String]) {
        
        // PE assessment mode (stable codes): "in_person" / "remote" / "not_assessed"
        // In telemedicine visit mode, disallow "in_person" to avoid contradictions.
        // Visit mode (stable codes): "in_person" / "telemedicine"
        do {
            let raw = normalizeChoiceValue(row["visit_mode"] ?? "")
            let allowed: Set<String> = ["in_person", "telemedicine"]
            self.visitMode = allowed.contains(raw) ? raw : "in_person"
        }
        
        do {
            let raw = normalizeChoiceValue(row["pe_assessment_mode"] ?? "")

            if self.visitMode == "telemedicine" {
                let allowed: Set<String> = ["remote", "not_assessed"]
                // If a legacy row has "in_person", normalize it to "remote".
                self.peAssessmentMode = allowed.contains(raw) ? raw : "remote"
            } else {
                let allowed: Set<String> = ["in_person", "remote", "not_assessed"]
                self.peAssessmentMode = allowed.contains(raw) ? raw : "in_person"
            }
        }
        
        // Complaints → split and map into preset + "other"
        let allComplaints = splitTrim(row["main_complaint"])
        let presetSet = Set(allComplaints.filter { complaintOptions.contains($0) })
        let freeList = allComplaints.filter { !complaintOptions.contains($0) }
        self.presetComplaints = presetSet
        self.otherComplaints = freeList.joined(separator: ", ")

        self.hpi = row["hpi"] ?? ""
        self.duration = row["duration"] ?? ""

        // Keep the duration TextField/Picker in sync with the persisted `duration` string.
        // Persisted format is expected to be compact, e.g. "48h" or "2d".
        let rawDuration = (row["duration"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if rawDuration.isEmpty {
            self.durationValue = ""
            self.durationUnit = .hours
        } else {
            let lower = rawDuration.lowercased()
            // Detect unit from suffix
            if lower.hasSuffix("h") {
                self.durationUnit = .hours
                self.durationValue = String(lower.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if lower.hasSuffix("d") {
                self.durationUnit = .days
                self.durationValue = String(lower.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // No explicit unit: keep behavior consistent with parser heuristic (<=72 => hours)
                let digits = lower.replacingOccurrences(of: "[^0-9]+", with: "", options: .regularExpression)
                self.durationValue = digits
                if let n = Int(digits), n > 72 {
                    self.durationUnit = .days
                } else {
                    self.durationUnit = .hours
                }
            }
        }

        // Prefill complaint-specific durations from v3 `dur_*` fields.
        // Stored format is compact: "48h" / "2d".
        func parseCompactDuration(_ raw: String) -> DurationInput? {
            let s0 = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s0.isEmpty else { return nil }
            let lower = s0.lowercased()

            if lower.hasSuffix("h") {
                let v = String(lower.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !v.isEmpty else { return nil }
                return DurationInput(value: v, unit: .hours)
            }
            if lower.hasSuffix("d") {
                let v = String(lower.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !v.isEmpty else { return nil }
                return DurationInput(value: v, unit: .days)
            }

            // No explicit unit: keep consistent with fever heuristic (<=72 => hours).
            let digits = lower.replacingOccurrences(of: "[^0-9]+", with: "", options: .regularExpression)
            guard !digits.isEmpty else { return nil }
            let n = Int(digits) ?? 0
            return DurationInput(value: digits, unit: (n > 72 ? .days : .hours))
        }

        // Reset then rebuild from row
        self.complaintDurations = [:]

        let durMap: [(complaint: String, key: String)] = [
            ("Cough", "dur_cough"),
            ("Runny nose", "dur_runny_nose"),
            ("Vomiting", "dur_vomiting"),
            ("Diarrhea", "dur_diarrhea"),
            ("Abdominal pain", "dur_abdominal_pain"),
            ("Rash", "dur_rash"),
            ("Headache", "dur_headache")
        ]


        for item in durMap {
            let raw = row[item.key] ?? ""
            if let parsed = parseCompactDuration(raw) {
                // Ensure the complaint is selected so its duration row is visible.
                if !self.presetComplaints.contains(item.complaint) {
                    self.presetComplaints.insert(item.complaint)
                }
                self.complaintDurations[item.complaint] = parsed
            }
        }

        // Prefill duration for free-text "Other complaints" (dur_other)
        let rawOtherDur = row["dur_other"] ?? ""
        if let parsedOther = parseCompactDuration(rawOtherDur) {
            self.complaintDurations["__other__"] = parsedOther
        }
        
        

        assignPicker(row["appearance"], allowed: appearanceChoices) { self.appearance = $0 }
        assignPicker(row["feeding"],   allowed: feedingChoices)   { self.feeding = $0 }
        assignPicker(row["breathing"], allowed: breathingChoices) { self.breathing = $0 }
        assignPicker(row["urination"], allowed: urinationChoices) { self.urination = $0 }
        assignPicker(row["pain"],      allowed: painChoices)      { self.pain = $0 }
        assignPicker(row["stools"],    allowed: stoolsChoices)    { self.stools = $0 }
        self.context = Set(splitTrim(row["context"]).filter { contextChoices.contains($0) })
        // (removed duplicate PE assessment mode block)

        assignPicker(row["general_appearance"], allowed: generalChoices) { self.generalAppearance = $0 }
        assignPicker(row["hydration"], allowed: hydrationChoices) { self.hydration = $0 }
        assignPicker(row["heart"], allowed: heartChoices) { self.heart = $0 }
        assignPicker(row["color"], allowed: colorChoices) { self.color = $0 }
        // Work of breathing (multi-select)
        if let wob = row["work_of_breathing"] {
            let parts = wob
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            workOfBreathingSet = parts.isEmpty ? ["Normal effort"] : Set(parts)
        } else {
            workOfBreathingSet = ["Normal effort"]
        }

        let entParts = splitTrim(row["ent"])
        self.ent = Set(entParts.filter { entChoices.contains($0) })
        assignPicker(row["right_ear"], allowed: earChoices) { self.rightEar = $0 }
        assignPicker(row["left_ear"],  allowed: earChoices) { self.leftEar  = $0 }
        assignPicker(row["right_eye"], allowed: eyeChoices) { self.rightEye = $0 }
        assignPicker(row["left_eye"],  allowed: eyeChoices) { self.leftEye  = $0 }
        // Skin (multi)
        let skinParts = splitTrim(row["skin"])
        let skinAllowed = Set(skinOptionsMulti)
        self.skinSet = Set(skinParts.filter { skinAllowed.contains($0) })
        if self.skinSet.isEmpty { self.skinSet = ["Normal"] }

        // Lungs (multi)
        let lungParts = splitTrim(row["lungs"])
        let lungsAllowed = Set(lungsOptionsMulti)
        self.lungsSet = Set(lungParts.filter { lungsAllowed.contains($0) })
        if self.lungsSet.isEmpty { self.lungsSet = ["Normal"] }

        // Abdomen (multi)
        let abdParts = splitTrim(row["abdomen"])
        let abdAllowed = Set(abdomenOptionsMulti)
        self.abdomenSet = Set(abdParts.filter { abdAllowed.contains($0) })
        if self.abdomenSet.isEmpty { self.abdomenSet = ["Normal"] }

        // Genitalia (multi)
        let genParts = splitTrim(row["genitalia"])
        let genAllowed = Set(genitaliaOptionsMulti)
        self.genitaliaSet = Set(genParts.filter { genAllowed.contains($0) })
        if self.genitaliaSet.isEmpty { self.genitaliaSet = ["Normal"] }

        // Lymph nodes (multi)
        let nodeParts = splitTrim(row["lymph_nodes"])
        let nodeAllowed = Set(nodesOptionsMulti)
        self.lymphNodesSet = Set(nodeParts.filter { nodeAllowed.contains($0) })
        if self.lymphNodesSet.isEmpty { self.lymphNodesSet = ["None"] }
        
        assignPicker(row["peristalsis"], allowed: peristalsisChoices) { self.peristalsis = $0 }
        
        assignPicker(row["neurological"], allowed: neuroChoices) { self.neurological = $0 }
        assignPicker(row["musculoskeletal"], allowed: mskChoices) { self.musculoskeletal = $0 }
        

        self.problemListing = row["problem_listing"] ?? ""
        self.complementaryInvestigations = row["complementary_investigations"] ?? ""
        self.diagnosis = row["diagnosis"] ?? ""
        self.icd10 = row["icd10"] ?? ""
        self.medications = row["medications"] ?? ""
        assignPicker(row["anticipatory_guidance"], allowed: guidanceChoices) { self.anticipatoryGuidance = $0 }
        self.comments = row["comments"] ?? ""
    }

    // MARK: - Problem List Generation Helpers

    /// Build a *display* string for the duration line using localized unit suffixes.
    ///
    /// Notes:
    /// - Persisted `duration` remains compact (e.g. "48h" / "2d") for stable parsing.
    /// - UI display uses localized suffixes (e.g. "h" / "j" in French).
    private func durationDisplayString() -> String {
        let v = durationValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty {
            let key = (durationUnit == .days)
                ? "sick_episode_form.duration.unit.days.short"
                : "sick_episode_form.duration.unit.hours.short"
            let suffix = NSLocalizedString(key, comment: "Short unit suffix for duration display (e.g. h / d or h / j)")
            return "\(v)\(suffix)"
        }

        // Fallback for legacy rows: parse persisted compact string (e.g. "48h" / "2d").
        let raw = duration.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        let lower = raw.lowercased()

        if lower.hasSuffix("h") {
            let num = String(lower.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = NSLocalizedString(
                "sick_episode_form.duration.unit.hours.short",
                comment: "Short unit suffix for duration display (e.g. h)"
            )
            return "\(num)\(suffix)"
        }
        if lower.hasSuffix("d") {
            let num = String(lower.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = NSLocalizedString(
                "sick_episode_form.duration.unit.days.short",
                comment: "Short unit suffix for duration display (e.g. d / j)"
            )
            return "\(num)\(suffix)"
        }

        // If we can't parse, show as-is.
        return raw
    }

    /// Build a *display* string for a complaint-specific duration stored in `complaintDurations`.
    /// Uses localized unit suffixes (e.g. h / j in French).
    private func complaintDurationDisplayString(for complaint: String) -> String {
        guard presetComplaints.contains(complaint) else { return "" }
        guard let input = complaintDurations[complaint] else { return "" }
        let v = input.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return "" }

        let key = (input.unit == .days)
            ? "sick_episode_form.duration.unit.days.short"
            : "sick_episode_form.duration.unit.hours.short"
        let suffix = NSLocalizedString(key, comment: "Short unit suffix for duration display (e.g. h / d or h / j)")
        return "\(v)\(suffix)"
    }

    /// Compute a combined complaint string from preset + free text.
    private func currentMainComplaintString() -> String {
        let free = otherComplaints
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let complaints = Array(presetComplaints).sorted() + free
        return complaints.joined(separator: ", ")
    }

    /// Compute a combined complaint string for *display* (localized preset + raw free text).
    ///
    /// - Preset complaints are stored as stable raw values (English) but displayed localized via `sickChoiceText`.
    /// - Free-text complaints are shown as-is.
    private func currentMainComplaintDisplayString() -> String {
        let free = otherComplaints
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let presetLocalized = Array(presetComplaints)
            .sorted()
            .map { sickChoiceText($0) }

        return (presetLocalized + free).joined(separator: ", ")
    }

    /// Fetch basic demographics for the active patient from the DB.
    private func fetchPatientDemographics(dbURL: URL, patientID: Int64) -> (first: String?, last: String?, dobISO: String?, sex: String?, vax: String?) {
        var db: OpaquePointer?
        do {
            db = try dbOpen(dbURL)
        } catch {
            return (nil, nil, nil, nil, nil)
        }
        defer { if db != nil { sqlite3_close(db) } }

        let sql = "SELECT first_name, last_name, dob, sex, vaccination_status FROM patients WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return (nil, nil, nil, nil, nil)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, patientID)

        if sqlite3_step(stmt) == SQLITE_ROW {
            func col(_ i: Int32) -> String? {
                if let c = sqlite3_column_text(stmt, i) {
                    return String(cString: c)
                }
                return nil
            }
            return (col(0), col(1), col(2), col(3), col(4))
        }
        return (nil, nil, nil, nil, nil)
    }

    /// Render age as a human-friendly string from ISO DOB "YYYY-MM-DD".
    /// Logic:
    /// - ≥2 years: "X y"
    /// - Exactly 1 year: "1 y" or "1 y N mo" if extra months
    /// - <1 year: "N mo" or "N d"
    private func ageText(from dobISO: String?) -> String? {
        guard let s = dobISO, !s.isEmpty else { return nil }
        let comps = s.split(separator: "-").map(String.init)
        guard comps.count >= 3,
              let y = Int(comps[0]),
              let m = Int(comps[1]),
              let d = Int(comps[2]) else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let dob = DateComponents(calendar: cal, year: y, month: m, day: d).date ?? Date()
        let now = Date()
        let diff = cal.dateComponents([ .year, .month, .day ], from: dob, to: now)

        let yrs = diff.year ?? 0
        let mos = diff.month ?? 0
        let days = diff.day ?? 0

        if yrs >= 2 {
            // For older kids we keep it simple: "10 y"
            return String(format: NSLocalizedString("sick_episode_form.age.years_format", comment: "Age string for >=2 years, e.g. '10 y'"), yrs)
        } else if yrs == 1 {
            // This is the case that was wrong before (e.g. 1 y 4 mo)
            if mos > 0 {
                return String(format: NSLocalizedString("sick_episode_form.age.one_year_months_format", comment: "Age string for 1 year plus months, e.g. '1 y 4 mo'"), mos)
            } else {
                return NSLocalizedString("sick_episode_form.age.one_year", comment: "Age string for exactly 1 year")
            }
        } else if mos >= 1 {
            // Under 1 year → months only
            return String(format: NSLocalizedString("sick_episode_form.age.months_format", comment: "Age string for months, e.g. '6 mo'"), mos)
        } else {
            // Newborns / very young infants → days
            return String(format: NSLocalizedString("sick_episode_form.age.days_format", comment: "Age string for days, e.g. '12 d'"), days)
        }
    }

    /// Build an aggregated problem list and place it in `problemListing`.
    private func generateProblemList() {
        var lines: [String] = []

        // Demographics
        if let pid = appState.selectedPatientID,
           let dbURL = appState.currentDBURL,
           FileManager.default.fileExists(atPath: dbURL.path) {
            let demo = fetchPatientDemographics(dbURL: dbURL, patientID: Int64(pid))
            // Intentionally omit patient name from the problem listing to avoid identifiers.
            if let a = ageText(from: demo.dobISO) {
                lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.age", comment: "Problem list line: Age"), a))
            }
            if let sx = demo.sex, !sx.isEmpty {
                lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.sex", comment: "Problem list line: Sex"), sx))
            }
            if let vax = demo.vax,
               !vax.isEmpty,
               vax.lowercased() != "up to date",
               vax.lowercased() != "up-to-date" {
                lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.vaccination_status", comment: "Problem list line: Vaccination status"), vaccinationStatusText(vax)))
            }
        }

        // Main complaint + duration
        // Use localized labels for preset complaints, but keep free-text as-is.
        let mc = currentMainComplaintDisplayString()
        if !mc.isEmpty {
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.main_complaint", comment: "Problem list line: Main complaint"), mc))
        }
        let durDisplay = durationDisplayString()
        if !durDisplay.isEmpty {
            lines.append(
                String(
                    format: NSLocalizedString(
                        "sick_episode_form.problem_listing.duration_hours",
                        comment: "Problem list line: Duration"
                    ),
                    durDisplay
                )
            )
        }

        // Complaint-specific durations (shown only for selected preset complaints).
        // These are persisted in v3 as dur_* fields but displayed here from the UI state.
        let complaintDurationOrder: [(raw: String, labelKey: String)] = [
            ("Cough", "sick_episode_form.choice.cough"),
            ("Runny nose", "sick_episode_form.choice.runny_nose"),
            ("Vomiting", "sick_episode_form.choice.vomiting"),
            ("Diarrhea", "sick_episode_form.choice.diarrhea"),
            ("Abdominal pain", "sick_episode_form.choice.abdominal_pain"),
            ("Rash", "sick_episode_form.choice.rash"),
            ("Headache", "sick_episode_form.choice.headache")
        ]

        for item in complaintDurationOrder {
            let d = complaintDurationDisplayString(for: item.raw)
            if !d.isEmpty {
                let name = NSLocalizedString(item.labelKey, comment: "Complaint name")
                lines.append(String(format: NSLocalizedString(
                    "sick_episode_form.problem_listing.complaint_duration_format",
                    comment: "Problem list line: complaint duration; %@ is complaint name, %@ is duration"
                ), name, d))
            }
        }

        // Duration for free-text other complaints (if provided)
        if let input = complaintDurations["__other__"] {
            let v = input.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty {
                let key = (input.unit == .days)
                    ? "sick_episode_form.duration.unit.days.short"
                    : "sick_episode_form.duration.unit.hours.short"
                let suffix = NSLocalizedString(key, comment: "Short unit suffix for duration display (e.g. h / d or h / j)")
                let d = "\(v)\(suffix)"
                let name = NSLocalizedString("sick_episode_form.complaint.other.label", comment: "Other complaints label")
                lines.append(String(format: NSLocalizedString(
                    "sick_episode_form.problem_listing.complaint_duration_format",
                    comment: "Problem list line: complaint duration; %@ is complaint name, %@ is duration"
                ), name, d))
            }
        }
        // Free-text HPI summary (so items like "blood in stool" are visible to AI)
        if !hpi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.hpi_summary", comment: "Problem list line: HPI summary"), hpi))
        }

        // Structured HPI abnormalities
        if appearance != "Well" {
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.appearance", comment: "Problem list line: Appearance"), sickChoiceText(appearance)))
        }
        if feeding != "Normal" {
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.feeding", comment: "Problem list line: Feeding"), sickChoiceText(feeding)))
        }
        if breathing != "Normal" {
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.breathing", comment: "Problem list line: Breathing"), sickChoiceText(breathing)))
        }
        if urination != "Normal" {
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.urination", comment: "Problem list line: Urination"), sickChoiceText(urination)))
        }
        if pain != "None" {
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.pain", comment: "Problem list line: Pain"), sickChoiceText(pain)))
        }
        if stools != "Normal" {
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.stools", comment: "Problem list line: Stools"), sickChoiceText(stools)))
        }
        let ctx = Array(context).filter { $0 != "None" }
        if !ctx.isEmpty {
            let ctxText = ctx.sorted().map { sickChoiceText($0) }.joined(separator: ", ")
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.context", comment: "Problem list line: Context"), ctxText))
        }

        // Vitals abnormalities – use current UI fields + classification badges
        let vitalsFlags = vitalsBadges()
        if !vitalsFlags.isEmpty {
            var vitalsPieces: [String] = []

            let tText = temperatureCField.trimmingCharacters(in: .whitespaces)
            if !tText.isEmpty {
                vitalsPieces.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.vitals.temp", comment: "Vitals piece: temperature"), tText))
            }

            let hrText = heartRateField.trimmingCharacters(in: .whitespaces)
            if !hrText.isEmpty {
                vitalsPieces.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.vitals.hr", comment: "Vitals piece: heart rate"), hrText))
            }

            let rrText = respiratoryRateField.trimmingCharacters(in: .whitespaces)
            if !rrText.isEmpty {
                vitalsPieces.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.vitals.rr", comment: "Vitals piece: respiratory rate"), rrText))
            }

            let s2Text = spo2Field.trimmingCharacters(in: .whitespaces)
            if !s2Text.isEmpty {
                vitalsPieces.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.vitals.spo2", comment: "Vitals piece: SpO2"), s2Text))
            }

            let sysText = bpSysField.trimmingCharacters(in: .whitespaces)
            let diaText = bpDiaField.trimmingCharacters(in: .whitespaces)
            if !sysText.isEmpty && !diaText.isEmpty {
                vitalsPieces.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.vitals.bp", comment: "Vitals piece: blood pressure"), sysText, diaText))
            }

            let valuesPart = vitalsPieces.joined(separator: ", ")
            let flagsPart = vitalsFlags.joined(separator: ", ")

            if !valuesPart.isEmpty {
                lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.abnormal_vitals.values_and_flags", comment: "Problem list line: abnormal vitals with values and flags"), valuesPart, flagsPart))
            } else {
                lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.abnormal_vitals.flags_only", comment: "Problem list line: abnormal vitals with flags only"), flagsPart))
            }
        }

        // PE abnormalities
        if generalAppearance != "Well" {
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.general_appearance", comment: "Problem list line: General appearance"), sickChoiceText(generalAppearance)))
        }
        if hydration != "Normal" {
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.hydration", comment: "Problem list line: Hydration"), sickChoiceText(hydration)))
        }
        if heart != "Normal" {
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.heart", comment: "Problem list line: Heart"), sickChoiceText(heart)))
        }
        if color != "Normal" {
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.color", comment: "Problem list line: Color"), sickChoiceText(color)))
        }

        // Work of breathing (multi-select): omit default "Normal effort"
        let wobAbnormal = workOfBreathingSet
            .filter { $0 != "Normal effort" }
            .sorted()

        if !wobAbnormal.isEmpty {
            let label = NSLocalizedString(
                "sick_episode_form.pe.work_of_breathing.label",
                comment: "Problem list label: Work of breathing"
            )
            let value = wobAbnormal.map { sickChoiceText($0) }.joined(separator: ", ")
            lines.append(String(format: NSLocalizedString(
                "sick_episode_form.problem_listing.complaint_duration_format",
                comment: "Generic two-part format used in problem listing; %@ is label, %@ is value"
            ), label, value))
        }
        if !(skinSet.count == 1 && skinSet.contains("Normal")) {
            let joined = Array(skinSet).sorted().map { sickChoiceText($0) }.joined(separator: ", ")
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.skin", comment: "Problem list line: Skin"), joined))
        }
        if !(ent.count == 1 && ent.contains("Normal")) {
            let joined = Array(ent).sorted().map { sickChoiceText($0) }.joined(separator: ", ")
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.ent", comment: "Problem list line: ENT"), joined))
        }
        if rightEar != "Normal" {
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.right_ear", comment: "Problem list line: Right ear"), sickChoiceText(rightEar)))
        }
        if leftEar  != "Normal" {
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.left_ear", comment: "Problem list line: Left ear"), sickChoiceText(leftEar)))
        }
        if rightEye != "Normal" {
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.right_eye", comment: "Problem list line: Right eye"), sickChoiceText(rightEye)))
        }
        if leftEye  != "Normal" {
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.left_eye", comment: "Problem list line: Left eye"), sickChoiceText(leftEye)))
        }
        if !(lungsSet.count == 1 && lungsSet.contains("Normal")) {
            let joined = Array(lungsSet).sorted().map { sickChoiceText($0) }.joined(separator: ", ")
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.lungs", comment: "Problem list line: Lungs"), joined))
        }
        if !(abdomenSet.count == 1 && abdomenSet.contains("Normal")) {
            let joined = Array(abdomenSet).sorted().map { sickChoiceText($0) }.joined(separator: ", ")
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.abdomen", comment: "Problem list line: Abdomen"), joined))
        }
        if peristalsis != "Normal" {
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.peristalsis", comment: "Problem list line: Peristalsis"), sickChoiceText(peristalsis)))
        }
        if !(genitaliaSet.count == 1 && genitaliaSet.contains("Normal")) {
            let joined = Array(genitaliaSet).sorted().map { sickChoiceText($0) }.joined(separator: ", ")
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.genitalia", comment: "Problem list line: Genitalia"), joined))
        }
        if neurological != "Alert" {
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.neurological", comment: "Problem list line: Neurological"), sickChoiceText(neurological)))
        }
        if musculoskeletal != "Normal" {
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.msk", comment: "Problem list line: Musculoskeletal"), sickChoiceText(musculoskeletal)))
        }
        if !(lymphNodesSet.count == 1 && lymphNodesSet.contains("None")) {
            let joined = Array(lymphNodesSet).sorted().map { sickChoiceText($0) }.joined(separator: ", ")
            lines.append(String(format: NSLocalizedString("sick_episode_form.problem_listing.lymph_nodes", comment: "Problem list line: Lymph nodes"), joined))
        }
        
        // Additional PE free-text (from the dedicated box)
        let extraPE = comments.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extraPE.isEmpty {
            // Keep the problem listing readable even if the notes were multi-line
            let oneLine = extraPE.replacingOccurrences(of: "\n", with: " ")
            lines.append(String(format: NSLocalizedString(
                "sick_episode_form.problem_listing.additional_pe_info",
                comment: "Problem list line: Additional physical examination information"
            ), oneLine))
        }

        problemListing = lines.joined(separator: "\n")
    }

// MARK: - PE Additional Info Input UI (TextEditor replacement)

    // MARK: - ICD-10 helper

    /// Append a candidate ICD-10 code to the editable field, avoiding duplicates.
    private func appendICD10Code(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Existing codes as a normalized list
        let existing = icd10
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Avoid adding duplicates
        if existing.contains(trimmed) {
            return
        }

        if existing.isEmpty {
            icd10 = trimmed
        } else {
            icd10 = (existing + [trimmed]).joined(separator: ", ")
        }
    }

    // MARK: - Problem tokens (machine-readable)

    /// Stable token for a stored choice value, using the same key namespace as Localizable.
    /// Example: "Wheeze" -> "sick_episode_form.choice.wheeze"
    private func choiceToken(_ raw: String) -> String {
        "sick_episode_form.choice.\(sickChoiceKey(raw))"
    }

    /// Build a machine-readable list of flagged/abnormal items **without** relying on localized display text.
    /// These tokens are meant to feed terminology mapping + guideline matching.
    private func buildProblemTokens() -> [String] {
        var out: [String] = []

        // Main complaints (preset only). Free-text complaints remain as-is so they can still be used by AI.
        out.append(contentsOf: Array(presetComplaints).map(choiceToken))
        let freeComplaints = otherComplaints
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        out.append(contentsOf: freeComplaints)

        // Structured HPI abnormalities
        if appearance != "Well" { out.append(choiceToken(appearance)) }
        if feeding != "Normal" { out.append(choiceToken(feeding)) }
        if breathing != "Normal" { out.append(choiceToken(breathing)) }
        if urination != "Normal" { out.append(choiceToken(urination)) }
        if pain != "None" { out.append(choiceToken(pain)) }
        if stools != "Normal" { out.append(choiceToken(stools)) }
        let ctx = Array(context).filter { $0 != "None" }
        out.append(contentsOf: ctx.map(choiceToken))

        // PE abnormalities
        if generalAppearance != "Well" { out.append(choiceToken(generalAppearance)) }
        if hydration != "Normal" { out.append(choiceToken(hydration)) }
        if heart != "Normal" { out.append(choiceToken(heart)) }
        if color != "Normal" { out.append(choiceToken(color)) }

        out.append(contentsOf: Array(skinSet).filter { $0 != "Normal" }.map(choiceToken))
        out.append(contentsOf: Array(ent).filter { $0 != "Normal" }.map(choiceToken))

        if rightEar != "Normal" { out.append(choiceToken(rightEar)) }
        if leftEar  != "Normal" { out.append(choiceToken(leftEar)) }
        if rightEye != "Normal" { out.append(choiceToken(rightEye)) }
        if leftEye  != "Normal" { out.append(choiceToken(leftEye)) }

        out.append(contentsOf: Array(lungsSet).filter { $0 != "Normal" }.map(choiceToken))
        out.append(contentsOf: Array(abdomenSet).filter { $0 != "Normal" }.map(choiceToken))
        if peristalsis != "Normal" { out.append(choiceToken(peristalsis)) }
        out.append(contentsOf: Array(genitaliaSet).filter { $0 != "Normal" }.map(choiceToken))

        if neurological != "Alert" { out.append(choiceToken(neurological)) }
        if musculoskeletal != "Normal" { out.append(choiceToken(musculoskeletal)) }

        // Lymph nodes ("None" is the normal/default here)
        out.append(contentsOf: Array(lymphNodesSet).filter { $0 != "None" }.map(choiceToken))

        // Extra PE free text stays as-is (AI use); we do NOT tokenize it here.

        // Dedupe + stable order
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    // MARK: - AI assistance wiring

    /// Build a lightweight AI context for the current episode, if possible.
    private func buildEpisodeAIContext() -> AppState.EpisodeAIContext? {
        guard let pid = appState.selectedPatientID,
              let eid = activeEpisodeID else {
            return nil
        }

        // Pull PMH and vaccination summaries from AppState so they can be fed into
        // guideline rules and AI prompts.
        let pmhSummary: String? = appState.pmhSummaryForSelectedPatient()
        let vaccinationStatus: String? = appState.vaccinationSummaryForSelectedPatient()

        // Demographics (avoid relying on AppState.selectedPatientProfile shape here)
        var patientSex: String? = nil
        var patientAgeDays: Int? = nil
        if let dbURL = appState.currentDBURL,
           FileManager.default.fileExists(atPath: dbURL.path) {
            let demo = fetchPatientDemographics(dbURL: dbURL, patientID: Int64(pid))
            patientSex = demo.sex?.trimmingCharacters(in: .whitespacesAndNewlines)

            // Compute ageDays from DOB at encounter time (use now for this form)
            if let dobISO = demo.dobISO, !dobISO.isEmpty {
                let parts = dobISO.split(separator: "-").map(String.init)
                if parts.count >= 3,
                   let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) {
                    var cal = Calendar(identifier: .gregorian)
                    cal.timeZone = .current
                    if let dob = DateComponents(calendar: cal, year: y, month: m, day: d).date {
                        let now = Date()
                        let days = cal.dateComponents([.day], from: dob, to: now).day
                        patientAgeDays = days
                    }
                }
            }
        }

        let maxTempC: Double? = vitalsHistory
            .compactMap { (row: VitalsRow) -> Double? in
                row.temperatureC
            }
            .max()
            ?? {
                let s = temperatureCField.trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? nil : Double(s)
            }()

        // SpO₂: use the lowest recorded value (worst) from vitals history, fallback to typed field.
        let spo2: Int? = vitalsHistory
            .compactMap { (row: VitalsRow) -> Int? in
                row.spo2
            }
            .min()
            ?? {
                let s = spo2Field.trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? nil : Int(s)
            }()

        // Delegate SpO₂ classification to VitalsRanges (single source of truth).
        let spo2IsAbnormal: Bool? = {
            let cls = VitalsRanges.classifySpO2(spo2)
            return (cls == "low")
        }()

        // ---- Fever duration (human input → canonical units) ----
        // UI stores `duration` as free text; users may type: "48", "48h", "2d", "5 days", etc.
        // We normalize to canonical hours for rules, and keep days when confidently derivable.
        func parseFeverDuration(_ raw: String) -> (days: Int?, hours: Int?, unit: String?) {
            let s0 = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s0.isEmpty else { return (nil, nil, nil) }

            // Lowercased, collapse whitespace
            let s = s0
                .lowercased()
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Extract first integer (e.g. "48", "5")
            let num: Int? = {
                let digits = s.replacingOccurrences(of: "[^0-9]+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !digits.isEmpty else { return nil }
                // Take the first chunk
                let first = digits.split(separator: " ").first
                return first.flatMap { Int($0) }
            }()
            guard let n = num, n >= 0 else { return (nil, nil, nil) }

            // Detect explicit unit tokens
            let isDays = s.contains(" day") || s.hasSuffix("d") || s.contains(" days")
            let isHours = s.contains(" hour") || s.hasSuffix("h") || s.contains(" hours")

            if isDays && !isHours {
                let days = n
                let hours = days * 24
                return (days, hours, "days")
            }
            if isHours && !isDays {
                let hours = n
                let days = (hours % 24 == 0) ? (hours / 24) : nil
                return (days, hours, "hours")
            }

            // If no unit (or ambiguous), apply a pragmatic heuristic:
            // - up to 72 => assume hours (common clinician habit)
            // - beyond 72 => assume days
            if n <= 72 {
                let hours = n
                let days = (hours % 24 == 0) ? (hours / 24) : nil
                return (days, hours, "hours")
            } else {
                let days = n
                let hours = days * 24
                return (days, hours, "days")
            }
        }

        let dur = parseFeverDuration(duration)
        let feverDurationDays: Int? = dur.days
        let feverDurationHours: Int? = dur.hours
        let feverDurationUnit: String? = dur.unit

        // Complaint-specific durations (compact strings like "48h" / "3d") for guideline logic.
        // Keys are stable identifiers (not localized UI strings).
        func compactComplaintDurationForContext(_ complaint: String) -> String {
            guard presetComplaints.contains(complaint) else { return "" }
            let input = complaintDurations[complaint] ?? DurationInput()
            let v = input.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { return "" }
            return v + input.unit.rawValue
        }

        var complaintDurationsPayload: [String: String] = [:]
        let mapping: [(raw: String, key: String)] = [
            ("Cough", "cough"),
            ("Runny nose", "runny_nose"),
            ("Vomiting", "vomiting"),
            ("Diarrhea", "diarrhea"),
            ("Abdominal pain", "abdominal_pain"),
            ("Rash", "rash"),
            ("Headache", "headache")
        ]
        for m in mapping {
            let s = compactComplaintDurationForContext(m.raw)
            if !s.isEmpty {
                complaintDurationsPayload[m.key] = s
            }
        }
        let complaintDurationsForContext: [String: String]? = complaintDurationsPayload.isEmpty ? nil : complaintDurationsPayload
        // Structured perinatal fields (best-effort): prefer structured cache if present.
        let gaWeeks: Int? = appState.perinatalHistory?.birthTermWeeks
        let bwG: Int? = appState.perinatalHistory?.birthWeightG
        let nicu: Bool? = appState.perinatalHistory?.nicuStay
        let p = appState.perinatalHistory
        let perinatalRaw: AppState.EpisodeAIContext.PerinatalRaw? = {
            guard let p else { return nil }
            return .init(
                pregnancyRisk: p.pregnancyRisk,
                infectionRisk: p.infectionRisk,
                resuscitation: p.resuscitation,
                maternityStayEvents: p.maternityStayEvents,
                maternityVaccinations: p.maternityVaccinations,
                motherVaccinations: p.motherVaccinations,
                familyVaccinations: p.familyVaccinations,
                birthMode: p.birthMode,
                feedingInMaternity: p.feedingInMaternity,
                heartScreening: p.heartScreening,
                metabolicScreening: p.metabolicScreening,
                hearingScreening: p.hearingScreening
            )
        }()

        return AppState.EpisodeAIContext(
            patientID: pid,
            episodeID: Int(eid),
            problemListing: problemListing,
            problemTokens: buildSickEpisodeTokens(),
            complementaryInvestigations: complementaryInvestigations,
            vaccinationStatus: vaccinationStatus,
            gestationalAgeWeeks: gaWeeks,
            birthWeightG: bwG,
            nicuStay: nicu,
            perinatalRaw: perinatalRaw,
            pmhSummary: pmhSummary,
            patientAgeDays: patientAgeDays,
            patientSex: patientSex,
            feverDurationDays: feverDurationDays,
            feverDurationHours: feverDurationHours,
            feverDurationUnit: feverDurationUnit,
            complaintDurations: complaintDurationsForContext,
            maxTempC: maxTempC,
            
            // Delegate classification to VitalsRanges (single source of truth).
            maxTempIsAbnormal: {
                let cls = VitalsRanges.classifyTempC(maxTempC)
                return (cls == "fever" || cls == "hypothermia")
            }(),
            spo2: spo2,
            spo2IsAbnormal: spo2IsAbnormal
        )
    }

    /// Trigger local guideline flags via AppState using the current episode context.
    private func triggerGuidelineFlags() {
        guard let ctx = buildEpisodeAIContext() else {
            appState.aiGuidelineFlagsForActiveEpisode = [
                NSLocalizedString(
                    "sick_episode_form.ai.cannot_run_guideline_flags",
                    comment: "Shown when guideline flags cannot run because no patient or saved episode is selected."
                )
            ]
            return
        }
        // Use the central JSON-based entry point; for now we pass nil so AppState
        // falls back to the existing stub when no clinician-specific rules are used.
        AppLog.ui.debug("SickEpisodeForm: guideline ctx.problemTokens=\(ctx.problemTokens, privacy: .public)")
        appState.runGuidelineFlags(using: ctx, rulesJSON: nil)
    }

    /// Trigger the AI call via AppState using the current episode context.
    private func triggerAIForEpisode() {
        guard let ctx = buildEpisodeAIContext() else {
            appState.aiSummariesForActiveEpisode = [
                "local-stub": NSLocalizedString(
                    "sick_episode_form.ai.cannot_run_ai",
                    comment: "Shown when AI cannot run because no patient or saved episode is selected."
                )
            ]
            return
        }

        aiIsRunning = true
        appState.runAIForEpisode(using: ctx)
        aiIsRunning = false
    }

    /// Build and store a debug preview of the structured JSON snapshot for the current episode.
    private func previewAIPrompt() {
        guard let ctx = buildEpisodeAIContext() else {
            aiPromptPreview = NSLocalizedString(
                "sick_episode_form.ai.cannot_build_prompt",
                comment: "Shown when the AI prompt preview cannot be built because required context is missing."
            )
            return
        }
        let fullPrompt = appState.buildSickAIPrompt(using: ctx)

        // We know AppState.buildSickAIPrompt appends a section:
        // ---
        // Structured episode snapshot (JSON)
        // ---
        // { ...json... }
        // Try to extract from just after that marker so the preview shows the JSON payload.
        if let markerRange = fullPrompt.range(of: "Structured episode snapshot (JSON)") {
            // Take everything from the marker onward, then trim up to the first newline after the marker
            let tail = fullPrompt[markerRange.upperBound...]
            if let firstBraceIndex = tail.firstIndex(of: "{") {
                let jsonPart = tail[firstBraceIndex...]
                aiPromptPreview = jsonPart.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // Fallback: show the tail section if we didn't find a JSON object start
                aiPromptPreview = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            // Fallback: show the full prompt if we cannot locate the JSON marker.
            aiPromptPreview = fullPrompt
        }
    }

    /// Delete the currently selected AI history entry (both from DB and the in-memory list).
    private func deleteSelectedAIHistory() {
        guard let selectedID = selectedAIHistoryID else { return }
        // Ask AppState to delete the row from the DB and update its published list.
        appState.deleteAIInputRow(withID: Int64(selectedID))
        // Clear the local selection so the UI collapses the detail view.
        selectedAIHistoryID = nil
    }

    // MARK: - Token protocol (must match sick_tokens.csv)
    private func tokenizeValue(_ raw: String) -> String {
        // Reuse your existing normalization to kill NBSP/ZWSP/etc
        var s = normalizeChoiceValue(raw).lowercased()

        // Match CSV-style normalization: turn separators into underscores
        // (Examples: "Dry, scaly rash" -> dry_scaly_rash, "Crackles (R)" -> crackles_r,
        //  "Red & Bulging with pus" -> red_bulging_with_pus, "Foul-smelling" -> foul_smelling)
        s = s.replacingOccurrences(of: "&", with: " ")

        // Replace any non-alphanumeric runs with "_"
        s = s.replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)

        // Trim underscores
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return s
    }

    private func makeSickToken(domain: String, field: String, value: String) -> String {
        "sick.\(domain).\(field).\(tokenizeValue(value))"
    }

    /// Build the full token set from current UI state.
    /// NOTE: domains/fields must match sick_tokens.csv exactly.
    private func buildSickEpisodeTokens() -> [String] {
        var out: [String] = []

        // ---- HPI ----
        for c in presetComplaints.sorted() {
            out.append(makeSickToken(domain: "hpi", field: "complaint", value: c))
        }

        out.append(makeSickToken(domain: "hpi", field: "appearance", value: appearance))
        out.append(makeSickToken(domain: "hpi", field: "feeding", value: feeding))
        out.append(makeSickToken(domain: "hpi", field: "breathing", value: breathing))
        out.append(makeSickToken(domain: "hpi", field: "urination", value: urination))
        out.append(makeSickToken(domain: "hpi", field: "pain_location", value: pain))
        out.append(makeSickToken(domain: "hpi", field: "stool", value: stools))

        for cx in context.sorted() where normalizeChoiceValue(cx) != "None" {
            out.append(makeSickToken(domain: "hpi", field: "context", value: cx))
        }

        // ---- PE ----
        out.append(makeSickToken(domain: "pe", field: "general_appearance", value: generalAppearance))
        out.append(makeSickToken(domain: "pe", field: "hydration", value: hydration))
        out.append(makeSickToken(domain: "pe", field: "color_hemodynamics", value: color))

        // Work of breathing (WOB) — emit stable guideline tokens (not localized).
        // These feed Guideline Builder rules and ClinicalFeatureExtractor.
        for v in workOfBreathingSet.sorted() {
            let cleaned = normalizeChoiceValue(v)
            guard !cleaned.isEmpty, cleaned != "Normal effort" else { continue }
            out.append("sick.pe.work_of_breathing.\(tokenizeValue(cleaned))")
        }
        out.append(makeSickToken(domain: "pe", field: "heart", value: heart))
        out.append(makeSickToken(domain: "pe", field: "peristalsis", value: peristalsis))
        out.append(makeSickToken(domain: "pe", field: "neuro", value: neurological))
        out.append(makeSickToken(domain: "pe", field: "msk", value: musculoskeletal))

        for v in skinSet.sorted() { out.append(makeSickToken(domain: "pe", field: "skin", value: v)) }
        for v in ent.sorted() { out.append(makeSickToken(domain: "pe", field: "ent", value: v)) }
        for v in lungsSet.sorted() { out.append(makeSickToken(domain: "pe", field: "lungs", value: v)) }
        for v in abdomenSet.sorted() { out.append(makeSickToken(domain: "pe", field: "abdomen", value: v)) }
        for v in genitaliaSet.sorted() { out.append(makeSickToken(domain: "pe", field: "genitalia", value: v)) }
        for v in lymphNodesSet.sorted() { out.append(makeSickToken(domain: "pe", field: "nodes", value: v)) }

        // Ear / Eye: token list intentionally does not encode laterality (matches your CSV)
        out.append(makeSickToken(domain: "pe", field: "ear", value: rightEar))
        out.append(makeSickToken(domain: "pe", field: "ear", value: leftEar))
        out.append(makeSickToken(domain: "pe", field: "eye", value: rightEye))
        out.append(makeSickToken(domain: "pe", field: "eye", value: leftEye))

        // De-dup just in case the same token was added twice
        return Array(Set(out)).sorted()
    }
    // MARK: - Positive Findings List Helper

    /// Returns a localized, de-duplicated list of positive/abnormal findings based on current UI state.
    private func positiveFindingsDisplayList() -> [String] {
        var out: [String] = []

        // Preset main complaints (localized)
        out.append(contentsOf: Array(presetComplaints).sorted().map { sickChoiceText($0) })

        // Structured HPI abnormalities
        if appearance != "Well" { out.append(sickChoiceText(appearance)) }
        if feeding != "Normal" { out.append(sickChoiceText(feeding)) }
        if breathing != "Normal" { out.append(sickChoiceText(breathing)) }
        if urination != "Normal" { out.append(sickChoiceText(urination)) }
        if pain != "None" { out.append(sickChoiceText(pain)) }
        if stools != "Normal" { out.append(sickChoiceText(stools)) }

        // Context (exclude None)
        let ctx = Array(context).filter { $0 != "None" }.sorted().map { sickChoiceText($0) }
        out.append(contentsOf: ctx)

        // PE abnormalities
        if generalAppearance != "Well" { out.append(sickChoiceText(generalAppearance)) }
        if hydration != "Normal" { out.append(sickChoiceText(hydration)) }
        if heart != "Normal" { out.append(sickChoiceText(heart)) }
        if color != "Normal" { out.append(sickChoiceText(color)) }

        out.append(contentsOf: Array(skinSet).filter { $0 != "Normal" }.sorted().map { sickChoiceText($0) })
        out.append(contentsOf: Array(ent).filter { $0 != "Normal" }.sorted().map { sickChoiceText($0) })

        if rightEar != "Normal" { out.append(sickChoiceText(rightEar)) }
        if leftEar  != "Normal" { out.append(sickChoiceText(leftEar)) }
        if rightEye != "Normal" { out.append(sickChoiceText(rightEye)) }
        if leftEye  != "Normal" { out.append(sickChoiceText(leftEye)) }

        out.append(contentsOf: Array(lungsSet).filter { $0 != "Normal" }.sorted().map { sickChoiceText($0) })
        out.append(contentsOf: Array(abdomenSet).filter { $0 != "Normal" }.sorted().map { sickChoiceText($0) })
        if peristalsis != "Normal" { out.append(sickChoiceText(peristalsis)) }
        out.append(contentsOf: Array(genitaliaSet).filter { $0 != "Normal" }.sorted().map { sickChoiceText($0) })

        if neurological != "Alert" { out.append(sickChoiceText(neurological)) }
        if musculoskeletal != "Normal" { out.append(sickChoiceText(musculoskeletal)) }

        out.append(contentsOf: Array(lymphNodesSet).filter { $0 != "None" }.sorted().map { sickChoiceText($0) })

        // De-dupe while preserving order
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    // MARK: - Save (commit to db + refresh UI)
    private func saveTapped() {
        AppLog.ui.info("SickEpisodeForm: saveTapped start | pid=\(String(describing: appState.selectedPatientID), privacy: .private) episodeID=\(String(describing: activeEpisodeID), privacy: .private) editingEpisodeID=\(String(describing: editingEpisodeID), privacy: .private)")
        let free = otherComplaints
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let complaints = Array(presetComplaints).sorted() + free

        var payload: [String: Any] = [:]
        // Core
        payload["main_complaint"] = complaints.joined(separator: ", ")
        payload["hpi"] = hpi
        // Build duration string from UI fields (e.g. "48h", "3d")
        let trimmed = durationValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            duration = trimmed + durationUnit.rawValue
        } else {
            duration = ""
        }
        payload["duration"] = duration

       // ---- v3 (telemedicine + per-complaint durations + WOB) ----
        // For now (before the dedicated UI is added), keep defaults explicit so
        // upgraded DBs stay consistent and future UI wiring has a stable base.
        payload["visit_mode"] = visitMode   // "in_person" / "telemedicine"            // or "telemedicine" later via UI

        // Telemedicine documentation flags (0/1). Defaults are safe for in-person visits.
        payload["telemed_limitations_explained"] = 0
        payload["telemed_safety_net_given"] = 0
        payload["telemed_remote_observations"] = ""

        // Per-complaint duration fields (v3).
        // Persist compact strings like "48h" / "3d" (same pattern as fever duration).
        // Only store durations for selected preset complaints. (No duration for free-text other complaints.)
        func compactComplaintDuration(_ complaint: String) -> String {
            guard presetComplaints.contains(complaint) else { return "" }
            let input = complaintDurations[complaint] ?? DurationInput()
            let v = input.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { return "" }
            return v + input.unit.rawValue
        }

        payload["dur_other"] = serializeDuration(complaintDurations["__other__"])
        payload["dur_cough"] = compactComplaintDuration("Cough")
        payload["dur_runny_nose"] = compactComplaintDuration("Runny nose")
        payload["dur_vomiting"] = compactComplaintDuration("Vomiting")
        payload["dur_diarrhea"] = compactComplaintDuration("Diarrhea")
        payload["dur_abdominal_pain"] = compactComplaintDuration("Abdominal pain")
        payload["dur_rash"] = compactComplaintDuration("Rash")
        payload["dur_headache"] = compactComplaintDuration("Headache")

        // Physical exam: Work of breathing (new column). Leave empty until wired.
        // Physical exam: Work of breathing (multi-select). Persist as comma-separated list.
        payload["work_of_breathing"] = Array(workOfBreathingSet).sorted().joined(separator: ", ")
        // Structured HPI
        payload["appearance"] = appearance
        payload["feeding"] = feeding
        payload["breathing"] = breathing
        payload["urination"] = urination
        payload["pain"] = pain
        payload["stools"] = stools
        payload["context"] = Array(context).sorted().joined(separator: ",")
        // PE
        payload["general_appearance"] = generalAppearance
        payload["hydration"] = hydration
        payload["heart"] = heart
        payload["color"] = color
        payload["pe_assessment_mode"] = peAssessmentMode
        payload["ent"] = Array(ent).sorted().joined(separator: ", ")
        payload["right_ear"] = rightEar
        payload["left_ear"] = leftEar
        payload["right_eye"] = rightEye
        payload["left_eye"] = leftEye
        payload["peristalsis"] = peristalsis
        payload["neurological"] = neurological
        payload["musculoskeletal"] = musculoskeletal
        payload["skin"] = Array(skinSet).sorted().joined(separator: ", ")
        payload["lungs"] = Array(lungsSet).sorted().joined(separator: ", ")
        payload["abdomen"] = Array(abdomenSet).sorted().joined(separator: ", ")
        payload["genitalia"] = Array(genitaliaSet).sorted().joined(separator: ", ")
        payload["lymph_nodes"] = Array(lymphNodesSet).sorted().joined(separator: ", ")
        // Plan
        payload["problem_listing"] = problemListing
        payload["complementary_investigations"] = complementaryInvestigations
        payload["diagnosis"] = diagnosis
        payload["icd10"] = icd10
        payload["medications"] = medications
        payload["anticipatory_guidance"] = anticipatoryGuidance
        payload["comments"] = comments

        let episodeLabel = editingEpisodeID.map(String.init) ?? "new"
        AppLog.ui.debug("SickEpisodeForm: payload built | episode=\(episodeLabel, privacy: .private) keys=\(payload.count, privacy: .public)")

        let durationTrimmed = duration.trimmingCharacters(in: .whitespacesAndNewlines)
        let payloadDuration = String(describing: payload["duration"])
        AppLog.ui.info("SickEpisodeForm: duration UI raw='\(durationTrimmed, privacy: .private)' payload.duration='\(payloadDuration, privacy: .private)'")
        AppLog.ui.debug("SickEpisodeForm: payload keys=\(payload.keys.count, privacy: .public)")

        guard let pid = appState.selectedPatientID,
              let dbURL = appState.currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else {
            AppLog.ui.error("SickEpisodeForm: cannot save (missing pid/dbURL)")
            return
        }

        let userIDLabel = appState.activeUserID.map(String.init) ?? "nil"
        AppLog.db.info("SickEpisodeForm: saving | pid=\(pid, privacy: .private) episode=\(episodeLabel, privacy: .private) activeUserID=\(userIDLabel, privacy: .private)")
        AppLog.db.debug("SickEpisodeForm: db=\(dbURL.lastPathComponent, privacy: .public)")
        ensureBundleUserRow(dbURL: dbURL)
        do {
            try ensureEpisodesTable(dbURL: dbURL)
        } catch {
            AppLog.db.error("ensureEpisodesTable failed: \(String(describing: error), privacy: .public)")
        }

        do {
            if let eid = activeEpisodeID {
                // Existing episode: update in place
                try updateEpisode(dbURL: dbURL, episodeID: eid, payload: payload)
                debugCountEpisodes(dbURL: dbURL, patientID: Int64(pid))
            } else {
                // First save of a new episode: insert and capture id
                let newID = try insertEpisode(dbURL: dbURL, patientID: Int64(pid), payload: payload)
                activeEpisodeID = newID
                debugCountEpisodes(dbURL: dbURL, patientID: Int64(pid))
                // Newly created: prepare vitals UI
                prefillVitalsIfEditing()
                loadVitalsHistory()
            }

            // After a successful save we can (re)run guideline flags using the now-stable episode id.
            // This avoids the “no flags until reload” UX and makes the flags reactive to edits.
            triggerGuidelineFlags()

            // Refresh visits/profile but keep the form open
            appState.loadVisits(for: pid)
            appState.loadPatientProfile(for: Int64(pid))
        } catch {
            AppLog.db.error("Episode save failed: \(String(describing: error), privacy: .public)")
        }
    }
   
}

// MARK: - Episode Signal Panel (local decision support)

// This panel is inserted with `episodeSignalsPanel` in the main UI.
extension SickEpisodeForm {

    private var episodeSignalsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(NSLocalizedString("sick_episode_form.signal_panel.header", comment: "Signal panel header"))
                    .font(.headline)
                Spacer()
                Button(action: {
                    triggerGuidelineFlags()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help(NSLocalizedString("sick_episode_form.signal_panel.refresh_help", comment: "Refresh guideline flags"))
            }
            .padding(.bottom, 2)

            // Abnormal vitals row
            let vitalsFlags = vitalsBadges()
            if !vitalsFlags.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("sick_episode_form.signal_panel.abnormal_vitals", comment: "Abnormal vitals label"))
                        .font(.subheadline)

                    Text(vitalsFlags.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Positive signs (approximate) row and details
            let positiveList = positiveFindingsDisplayList()
            HStack(spacing: 8) {
                Text(NSLocalizedString("sick_episode_form.signal_panel.positive_signs", comment: "Positive signs label"))
                    .font(.subheadline)

                Text("\(positiveList.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !positiveList.isEmpty {
                ForEach(Array(positiveList.prefix(15).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(item)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 28)
                }
            }

            // Rule alerts row and details (clickable)
            let matches = appState.aiGuidelineMatchesForActiveEpisode
                .sorted { (a, b) in
                    if a.priority != b.priority { return a.priority > b.priority }
                    return a.flagText.localizedCaseInsensitiveCompare(b.flagText) == .orderedAscending
                }

            HStack(spacing: 8) {
                Text(NSLocalizedString("sick_episode_form.signal_panel.rule_alerts", comment: "Rule alerts label"))
                    .font(.subheadline)

                Text("\(matches.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !matches.isEmpty {
                ForEach(matches.prefix(8), id: \.ruleId) { m in
                    Button {
                        selectedGuidelineMatch = GuidelineMatchSelection(id: m.ruleId, match: m)
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(m.flagText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 28)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .padding(.vertical, 4)
        .popover(item: $selectedGuidelineMatch, arrowEdge: .trailing) { sel in
            let m = sel.match
            VStack(alignment: .leading, spacing: 10) {
                Text(m.flagText)
                    .font(.headline)

                if let note = m.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ScrollView {
                        Text(note)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 120, idealHeight: 200, maxHeight: 320)
                } else {
                    Text(NSLocalizedString(
                        "sick_episode_form.signal_panel.no_guideline_note",
                        comment: "Shown when a matched guideline has no note"
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Rule: \(m.ruleId)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Priority: \(m.priority)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(minWidth: 360, idealWidth: 440, maxWidth: 520,
                   minHeight: 180, idealHeight: 260, maxHeight: 420)
        }
    }
}

// MARK: - Restore/prefill from DB row

extension SickEpisodeForm {
    private func prefillFromRow(_ row: [String: Any]) {
        // ... other field assignments ...
        // Restore visit mode (stable codes): "in_person" / "telemedicine"
        if let vm = row["visit_mode"] as? String {
            let cleaned = normalizeChoiceValue(vm)
            self.visitMode = (cleaned == "telemedicine") ? "telemedicine" : "in_person"
        } else {
            self.visitMode = "in_person"
        }

        // Restore PE assessment mode with normalization and fallback.
        // In telemedicine visit mode, disallow "in_person" to avoid contradictions.
        if let m = row["pe_assessment_mode"] as? String {
            let cleaned = normalizeChoiceValue(m)
            if self.visitMode == "telemedicine" {
                self.peAssessmentMode = (cleaned == "not_assessed") ? "not_assessed" : "remote"
            } else {
                if cleaned == "remote" || cleaned == "not_assessed" || cleaned == "in_person" {
                    self.peAssessmentMode = cleaned
                } else {
                    self.peAssessmentMode = "in_person"
                }
            }
        } else {
            self.peAssessmentMode = (self.visitMode == "telemedicine") ? "remote" : "in_person"
        }
        // ... continue with other fields ...
    }
}

// MARK: - Small helpers

/// Convert a raw stored choice string into a stable localization key suffix.
/// e.g. "Runny nose" -> "runny_nose", "Red & Bulging with pus" -> "red_bulging_with_pus".
private func sickChoiceKey(_ raw: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
    var out = ""
    var lastWasUnderscore = false
    for ch in raw.lowercased() {
        if allowed.contains(ch) {
            out.append(ch)
            lastWasUnderscore = false
        } else if !lastWasUnderscore {
            out.append("_")
            lastWasUnderscore = true
        }
    }
    return out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
}

/// Normalize a stored/raw value so hidden characters (NBSP/ZWSP/BOM) or stray whitespace
/// do not break key lookups.
private func normalizeChoiceValue(_ raw: String) -> String {
    var s = raw

    // Common invisible / non-standard whitespace
    s = s.replacingOccurrences(of: "\u{00A0}", with: " ") // NBSP
    s = s.replacingOccurrences(of: "\u{200B}", with: "")  // ZWSP
    s = s.replacingOccurrences(of: "\u{FEFF}", with: "")  // BOM

    // Collapse internal whitespace runs to a single space
    s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

    return s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
}


/// Localized label for a stored choice value.
/// Falls back to the raw value if the key is missing.
private func sickChoiceText(_ raw: String) -> String {
    let key = "sick_episode_form.choice.\(sickChoiceKey(raw))"
    let localized = NSLocalizedString(key, comment: "SickEpisodeForm choice label")
    return (localized == key) ? raw : localized
}

/// Localized label for a stored vaccination status value.
/// Falls back to the raw value if the key is missing.
///
/// Stored values are expected to be stable (often English) while display is localized.
/// We try a dedicated vaccination namespace first, then fall back to the generic sick choice keys
/// (useful if vaccination options were previously localized under `sick_episode_form.choice.*`).
private func vaccinationStatusText(_ raw: String) -> String {
    // Normalize to avoid hidden characters / stray whitespace breaking key lookup.
    let cleaned = normalizeChoiceValue(raw)
    guard !cleaned.isEmpty else { return raw }

    let suffix = sickChoiceKey(cleaned)

    // Preferred namespace for vaccination status in this codebase (matches Localizable: vax.status.*)
    let key0 = "vax.status.\(suffix)"
    let loc0 = NSLocalizedString(key0, comment: "Vaccination status label")
    if loc0 != key0 { return loc0 }

    // Alternative namespace (older/other modules)
    let key1 = "patient.vaccination_status.\(suffix)"
    let loc1 = NSLocalizedString(key1, comment: "Vaccination status label")
    if loc1 != key1 { return loc1 }

    // Back-compat fallback (if the values were localized as generic sick choices)
    let key2 = "sick_episode_form.choice.\(suffix)"
    let loc2 = NSLocalizedString(key2, comment: "Vaccination status label (fallback)")
    if loc2 != key2 { return loc2 }

    // Final fallback: show the cleaned stored value
    return cleaned
}

private func summary(for row: SickEpisodeForm.VitalsRow) -> String {
    var parts: [String] = []
    if let w = row.weightKg { parts.append("Wt \(String(format: "%.1f", w))kg") }
    if let h = row.heightCm { parts.append("Ht \(String(format: "%.1f", h))cm") }
    if let hc = row.headCircumferenceCm { parts.append("HC \(String(format: "%.1f", hc))cm") }
    if let t = row.temperatureC { parts.append("T \(String(format: "%.1f", t))°C") }
    if let hr = row.heartRate { parts.append("HR \(hr)") }
    if let rr = row.respiratoryRate { parts.append("RR \(rr)") }
    if let s2 = row.spo2 { parts.append("SpO₂ \(s2)%") }
    if let s = row.bpSys, let d = row.bpDia { parts.append("BP \(s)/\(d)") }
    return parts.joined(separator: " • ")
}

private struct SectionHeader: View {
    let title: String
    init(_ t: String) { title = t }
    var body: some View {
        Text(title)
            .font(.headline)
            .padding(.top, 4)
    }
}

/// Simple flow layout that wraps subviews onto new lines based on available width.
/// (Much more resilient for localization where labels can become longer.)
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity

        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for v in subviews {
            let s = v.sizeThatFits(.unspecified)

            // Wrap to next line if needed.
            if x > 0, x + s.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }

            x += (x == 0 ? 0 : spacing) + s.width
            rowHeight = max(rowHeight, s.height)
            usedWidth = max(usedWidth, x)
        }

        return CGSize(width: min(usedWidth, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for v in subviews {
            let s = v.sizeThatFits(.unspecified)

            // Wrap to next line if needed.
            if x > bounds.minX, (x + s.width) > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }

            v.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: s.width, height: s.height)
            )

            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

/// Wrapping chips component backed by a Set of raw (stored) strings.
///
/// - Important: `strings` values are treated as stable *stored* values (DB-safe).
///   Only the *display* label is localized via `labelFor`.
private struct WrappingChips: View {
    let strings: [String]
    @Binding var selection: Set<String>
    let labelFor: (String) -> String

    init(
        strings: [String],
        selection: Binding<Set<String>>,
        labelFor: @escaping (String) -> String = sickChoiceText
    ) {
        self.strings = strings
        self._selection = selection
        self.labelFor = labelFor
    }

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(strings, id: \.self) { s in
                Toggle(
                    isOn: Binding(
                        get: { selection.contains(s) },
                        set: { on in
                            let noneValue = "None"
                            let normalValue = "Normal"
                            let hasNormal = strings.contains(normalValue)

                            var set = selection

                            if s == noneValue {
                                // Tap "None" => clears others; allow clearing if it was the only one
                                if on {
                                    set = [noneValue]
                                } else {
                                    if set == [noneValue] { set.remove(noneValue) }
                                }
                            } else if s == normalValue {
                                // "Normal" is an exclusive default where present
                                if on {
                                    set = [normalValue]
                                } else {
                                    // Keep Normal if it's the only value (default)
                                    if set != [normalValue] {
                                        set.remove(normalValue)
                                        if set.isEmpty { set = [normalValue] }
                                    }
                                }
                            } else {
                                // Any other choice removes None + Normal
                                if set.contains(noneValue) { set.remove(noneValue) }
                                if set.contains(normalValue) { set.remove(normalValue) }

                                if on {
                                    set.insert(s)
                                } else {
                                    set.remove(s)
                                    // If this group supports Normal, it becomes the default when empty
                                    if set.isEmpty, hasNormal { set = [normalValue] }
                                }
                            }

                            selection = set
                        }
                    )
                ) {
                    Text(labelFor(s))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .toggleStyle(.button)
                .buttonStyle(ChipButtonStyle(isSelected: selection.contains(s)))
            }
        }
    }
}

// MARK: - Vitals UI helpers and lifecycle

extension SickEpisodeForm {
    // MARK: - Vitals classification (moved inside type)

    /// Returns small badges like ["HR high for toddler", "Fever"] or [] if nothing to show.
    private func vitalsBadges() -> [String] {
        // Pull DOB/sex from DB to deduce age band
        var dobISO: String? = nil
        var sex: String? = nil
        if let pid = appState.selectedPatientID,
           let dbURL = appState.currentDBURL,
           FileManager.default.fileExists(atPath: dbURL.path) {
            let demo = fetchPatientDemographics(dbURL: dbURL, patientID: Int64(pid))
            dobISO = demo.dobISO
            sex = demo.sex
        }

        let ageY = ageYears(from: dobISO)
        let bandLabel = localizedAgeBandLabel(forYears: ageY) // localized human label, or nil

        // Parse current UI values (prefer what's typed now)
        func i(_ s: String) -> Int? {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : Int(t)
        }
        func d(_ s: String) -> Double? {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : Double(t)
        }
        let hr = i(heartRateField)
        let rr = i(respiratoryRateField)
        let temp = d(temperatureCField)
        let s2 = i(spo2Field)

        var out: [String] = []

        // HR / RR ranges by age band (AAP-style broad bands; matches Python app)
        if let hr = hr, let a = ageY {
            let (lo, hi) = hrRange(forYears: a)
            if let lo = lo, hr < lo {
                if let band = bandLabel {
                    out.append(String(format: NSLocalizedString(
                        "sick_episode.vitals.badge.hr_low_for",
                        comment: "Vitals badge: HR low for a given age band."
                    ), band))
                } else {
                    out.append(NSLocalizedString(
                        "sick_episode.vitals.badge.hr_low",
                        comment: "Vitals badge: HR low."
                    ))
                }
            } else if let hi = hi, hr > hi {
                if let band = bandLabel {
                    out.append(String(format: NSLocalizedString(
                        "sick_episode.vitals.badge.hr_high_for",
                        comment: "Vitals badge: HR high for a given age band."
                    ), band))
                } else {
                    out.append(NSLocalizedString(
                        "sick_episode.vitals.badge.hr_high",
                        comment: "Vitals badge: HR high."
                    ))
                }
            }
        }

        if let rr = rr, let a = ageY {
            let (lo, hi) = rrRange(forYears: a)
            if let lo = lo, rr < lo {
                if let band = bandLabel {
                    out.append(String(format: NSLocalizedString(
                        "sick_episode.vitals.badge.rr_low_for",
                        comment: "Vitals badge: RR low for a given age band."
                    ), band))
                } else {
                    out.append(NSLocalizedString(
                        "sick_episode.vitals.badge.rr_low",
                        comment: "Vitals badge: RR low."
                    ))
                }
            } else if let hi = hi, rr > hi {
                if let band = bandLabel {
                    out.append(String(format: NSLocalizedString(
                        "sick_episode.vitals.badge.rr_high_for",
                        comment: "Vitals badge: RR high for a given age band."
                    ), band))
                } else {
                    out.append(NSLocalizedString(
                        "sick_episode.vitals.badge.rr_high",
                        comment: "Vitals badge: RR high."
                    ))
                }
            }
        }

        // Temperature flags
        if let t = temp {
            if t >= 38.0 {
                out.append(NSLocalizedString(
                    "sick_episode.vitals.badge.fever",
                    comment: "Vitals badge: Fever."
                ))
            } else if t < 35.5 {
                out.append(NSLocalizedString(
                    "sick_episode.vitals.badge.hypothermia",
                    comment: "Vitals badge: Hypothermia."
                ))
            }
        }

        // SpO₂ flags
        if let s2 = s2, s2 < 95 {
            out.append(NSLocalizedString(
                "sick_episode.vitals.badge.spo2_low",
                comment: "Vitals badge: SpO2 low."
            ))
        }

        // Pediatric BP category (AAP 2017) via VitalsBP
        if let a = ageY,
           let sx = sex, !sx.isEmpty,
           let sysInt = i(bpSysField), let diaInt = i(bpDiaField) {
            let heightOpt = d(heightCmField)
            let res = VitalsBP.classify(
                sex: sx,
                ageYears: a,
                heightCm: heightOpt,
                sys: Double(sysInt),
                dia: Double(diaInt)
            )

            // Append badge only for non-normal, known categories
            switch res.category {
            case .normal, .unknown:
                break
            case .elevated, .stage1, .stage2:
                // If VitalsBP already provided a message, keep it (can be localized later in VitalsBP).
                if let msg = res.message, !msg.isEmpty {
                    out.append(msg)
                } else {
                    let labelKey: String
                    switch res.category {
                    case .elevated:
                        labelKey = "sick_episode.vitals.bp_label.elevated"
                    case .stage1:
                        labelKey = "sick_episode.vitals.bp_label.stage1"
                    case .stage2:
                        labelKey = "sick_episode.vitals.bp_label.stage2"
                    default:
                        labelKey = "sick_episode.vitals.bp_label.abnormal"
                    }
                    let label = NSLocalizedString(labelKey, comment: "BP category label")
                    out.append(String(format: NSLocalizedString(
                        "sick_episode.vitals.badge.bp_value_label",
                        comment: "Vitals badge: BP value with category label."
                    ), sysInt, diaInt, label))
                }
            default:
                // Handles any future/extra categories (e.g., low-for-age / hypotension)
                if let msg = res.message, !msg.isEmpty {
                    out.append(msg)
                } else {
                    let abnormal = NSLocalizedString(
                        "sick_episode.vitals.bp_label.abnormal",
                        comment: "BP category label: abnormal."
                    )
                    out.append(String(format: NSLocalizedString(
                        "sick_episode.vitals.badge.bp_value_label",
                        comment: "Vitals badge: BP value with category label."
                    ), sysInt, diaInt, abnormal))
                }
            }
        }

        return out
    }

    /// Localized human-readable band label ("neonate", "infant", etc.)
    private func localizedAgeBandLabel(forYears y: Double?) -> String? {
        guard let y = y else { return nil }
        let neonate = 28.0 / 365.25

        let key: String
        if y < neonate { key = "sick_episode.vitals.age_band.neonate" }
        else if y < 1.0 { key = "sick_episode.vitals.age_band.infant" }
        else if y < 3.0 { key = "sick_episode.vitals.age_band.toddler" }
        else if y < 6.0 { key = "sick_episode.vitals.age_band.preschool" }
        else if y < 12.0 { key = "sick_episode.vitals.age_band.school_age" }
        else if y < 16.0 { key = "sick_episode.vitals.age_band.adolescent" }
        else { key = "sick_episode.vitals.age_band.adult_like" }

        let localized = NSLocalizedString(key, comment: "Age band label used in vitals badges")
        return (localized == key) ? nil : localized
    }

    /// Parse "YYYY-MM-DD" → years as Double
    private func ageYears(from iso: String?) -> Double? {
        guard let s = iso, !s.isEmpty else { return nil }
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 3 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let dob = DateComponents(calendar: cal, year: parts[0], month: parts[1], day: parts[2]).date ?? Date()
        let now = Date()
        let days = cal.dateComponents([.day], from: dob, to: now).day ?? 0
        return Double(days) / 365.25
    }

    /// Human-readable band label (localized when available).
    /// Delegates to `localizedAgeBandLabel(forYears:)` to avoid leaking English.
    private func ageBandLabel(forYears y: Double?) -> String? {
        localizedAgeBandLabel(forYears: y)
    }

    /// Heart-rate normal range (low, high) for given age in years
    private func hrRange(forYears y: Double) -> (Int?, Int?) {
        let neonate = 28.0 / 365.25
        if y < neonate { return (100, 205) }      // neonate
        else if y < 1.0 { return (100, 190) }     // infant
        else if y < 3.0 { return (98, 140) }      // toddler
        else if y < 6.0 { return (80, 120) }      // preschool
        else if y < 12.0 { return (75, 118) }     // school age
        else if y < 16.0 { return (60, 100) }     // adolescent
        else { return (60, 100) }                 // adult-like
    }

    /// Respiratory-rate normal range (low, high) for given age in years
    private func rrRange(forYears y: Double) -> (Int?, Int?) {
        let neonate = 28.0 / 365.25
        if y < neonate { return (30, 53) }        // neonate
        else if y < 1.0 { return (30, 53) }       // infant
        else if y < 3.0 { return (22, 37) }       // toddler
        else if y < 6.0 { return (20, 28) }       // preschool
        else if y < 12.0 { return (18, 25) }      // school age
        else if y < 16.0 { return (12, 20) }      // adolescent
        else { return (12, 20) }                  // adult-like
    }

    private func prefillVitalsIfEditing() {
        guard let eid = activeEpisodeID,
              let dbURL = appState.currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else { return }
        if let latest = latestVitalsRow(dbURL: dbURL, episodeID: eid) {
            weightKgField = latest.weightKg.map { String(format: "%.1f", $0) } ?? ""
            heightCmField = latest.heightCm.map { String(format: "%.1f", $0) } ?? ""
            headCircumferenceField = latest.headCircumferenceCm.map { String(format: "%.1f", $0) } ?? ""
            temperatureCField = latest.temperatureC.map { String(format: "%.1f", $0) } ?? ""
            heartRateField = latest.heartRate.map(String.init) ?? ""
            respiratoryRateField = latest.respiratoryRate.map(String.init) ?? ""
            spo2Field = latest.spo2.map(String.init) ?? ""
            bpSysField = latest.bpSys.map(String.init) ?? ""
            bpDiaField = latest.bpDia.map(String.init) ?? ""
            recordedAtField = latest.recordedAt
        } else {
            recordedAtField = isoNow()
        }
    }

    private func loadVitalsHistory() {
        guard let eid = activeEpisodeID,
              let dbURL = appState.currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else {
            vitalsHistory = []
            vitalsDeleteSelection = nil
            return
        }
        vitalsHistory = listVitalsForEpisode(dbURL: dbURL, episodeID: eid)
        vitalsDeleteSelection = nil
    }

    private func saveVitalsTapped() {
        guard let eid = activeEpisodeID,
              let pid = appState.selectedPatientID,
              let dbURL = appState.currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else { return }
        func failVital(_ message: String) {
            AppLog.ui.info("SickEpisodeForm: vitals validation failed | \(message, privacy: .public)")
            DispatchQueue.main.async {
                vitalsValidationAlert = VitalsValidationAlert(message: message)
            }
        }
        do {
            try ensureManualGrowthTable(dbURL: dbURL)
            try ensureVitalsTable(dbURL: dbURL)

            // Parse numeric inputs; blank → nil
            func d(_ s: String) -> Double? { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : Double(t) }
            func i(_ s: String) -> Int? { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : Int(t) }

            let w  = d(weightKgField)
            let h  = d(heightCmField)
            let hc = d(headCircumferenceField)
            let t  = d(temperatureCField)
            let hr = i(heartRateField)
            let rr = i(respiratoryRateField)
            let s2 = i(spo2Field)
            var bs = i(bpSysField)
            var bd = i(bpDiaField)
            if let x = bs, let y = bd, x < y { bs = y; bd = x } // swap if reversed

            // ---- Basic physiologic sanity validation (reject nonsense data) ----
            func invalid(_ condition: Bool, _ message: String) throws {
                if condition {
                    throw NSError(
                        domain: "SickEpisodeForm.VitalsValidation",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                }
            }

            // Weight (kg): 0.3 – 300
            if let w = w {
                try invalid(w < 0.3 || w > 300.0,
                    NSLocalizedString("sick_episode_form.vitals_validation.invalid_weight",
                                      comment: "Vitals validation: invalid weight"))
            }

            // Height (cm): 20 – 250
            if let h = h {
                try invalid(h < 20.0 || h > 250.0,
                    NSLocalizedString("sick_episode_form.vitals_validation.invalid_height",
                                      comment: "Vitals validation: invalid height"))
            }

            // Head circumference (cm): 15 – 70
            if let hc = hc {
                try invalid(hc < 15.0 || hc > 70.0,
                    NSLocalizedString("sick_episode_form.vitals_validation.invalid_head_circumference",
                                      comment: "Vitals validation: invalid head circumference"))
            }

            // Temperature (°C): 30 – 45
            if let t = t {
                try invalid(t < 30.0 || t > 45.0,
                    NSLocalizedString("sick_episode_form.vitals_validation.invalid_temperature",
                                      comment: "Vitals validation: invalid temperature"))
            }

            // Heart rate (bpm): 20 – 300
            if let hr = hr {
                try invalid(hr < 20 || hr > 300,
                    NSLocalizedString("sick_episode_form.vitals_validation.invalid_heart_rate",
                                      comment: "Vitals validation: invalid heart rate"))
            }

            // Respiratory rate (/min): 5 – 120
            if let rr = rr {
                try invalid(rr < 5 || rr > 120,
                    NSLocalizedString("sick_episode_form.vitals_validation.invalid_respiratory_rate",
                                      comment: "Vitals validation: invalid respiratory rate"))
            }

            // SpO2 (%): 50 – 100
            if let s2 = s2 {
                try invalid(s2 < 50 || s2 > 100,
                    NSLocalizedString("sick_episode_form.vitals_validation.invalid_spo2",
                                      comment: "Vitals validation: invalid SpO2"))
            }

            // Blood pressure (mmHg): 30 – 300
            if let bs = bs {
                try invalid(bs < 30 || bs > 300,
                    NSLocalizedString("sick_episode_form.vitals_validation.invalid_bp_systolic",
                                      comment: "Vitals validation: invalid systolic BP"))
            }
            if let bd = bd {
                try invalid(bd < 20 || bd > 200,
                    NSLocalizedString("sick_episode_form.vitals_validation.invalid_bp_diastolic",
                                      comment: "Vitals validation: invalid diastolic BP"))
            }

            // Skip if all empty
            if [w,h,hc,t].allSatisfy({ $0 == nil }) &&
               [hr,rr,s2,bs,bd].allSatisfy({ $0 == nil }) {
                AppLog.db.info("SickEpisodeForm: vitals not saved (all fields empty) | pid=\(pid, privacy: .private) episodeID=\(eid, privacy: .private)")
                return
            }

            if replacePreviousVitals {
                _ = deleteAllVitalsForEpisode(dbURL: dbURL, episodeID: eid)
            }

            _ = try insertVitals(
                dbURL: dbURL,
                patientID: Int64(pid),
                episodeID: eid,
                weightKg: w, heightCm: h, headCircumferenceCm: hc,
                temperatureC: t, heartRate: hr, respiratoryRate: rr, spo2: s2,
                bpSys: bs, bpDia: bd,
                recordedAtISO: recordedAtField.trimmingCharacters(in: .whitespaces).isEmpty ? nil : recordedAtField
            )

            // Refresh list + keep fields as-is
            loadVitalsHistory()
        } catch {
            let ns = error as NSError
            let msg = ns.localizedDescription

            if ns.domain == "SickEpisodeForm.VitalsValidation" {
                failVital(msg)
                return
            }

            AppLog.db.error("SickEpisodeForm: saveVitalsTapped failed | pid=\(pid, privacy: .private) episodeID=\(eid, privacy: .private) err=\(String(describing: error), privacy: .public)")
        }
    }

    private func deleteSelectedVitals() {
        guard let sel = vitalsDeleteSelection,
              let dbURL = appState.currentDBURL else { return }
        if deleteVitalsRow(dbURL: dbURL, id: sel) {
            loadVitalsHistory()
        }
    }
}


