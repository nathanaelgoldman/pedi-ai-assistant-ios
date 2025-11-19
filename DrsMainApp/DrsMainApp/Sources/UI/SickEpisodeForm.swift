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
import OSLog
import SQLite3

// SQLite helper: transient destructor pointer for sqlite3_bind_text
fileprivate let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
    @State private var duration: String = ""

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

    // MARK: - AI assistance
    @State private var aiIsRunning: Bool = false
    @State private var aiPromptPreview: String = ""
    @State private var selectedAIHistoryID: Int? = nil

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

    private let guidanceChoices = ["URI","AGE","UTI","Otitis"]

    private let log = Logger(subsystem: "DrsMainApp", category: "SickEpisodeForm")

    init(editingEpisodeID: Int? = nil) {
        self.editingEpisodeID = editingEpisodeID
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    HStack {
                        Image(systemName: "stethoscope")
                            .font(.system(size: 22))
                        Text(editingEpisodeID == nil ? "New Sick Episode" : "Edit Sick Episode #\(editingEpisodeID!)")
                            .font(.title2.bold())
                        Spacer()
                    }

                    // Vitals (moved to top)
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader("Vitals")
                        // Live vitals classification badges
                        let badges = vitalsBadges()
                        if !badges.isEmpty {
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
                        if activeEpisodeID == nil {
                            Text("Save the episode first to enable vitals entry.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                                GridRow {
                                    TextField("Weight (kg)", text: $weightKgField)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("Height (cm)", text: $heightCmField)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("Head circ (cm)", text: $headCircumferenceField)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("Temperature (°C)", text: $temperatureCField)
                                        .textFieldStyle(.roundedBorder)
                                }
                                GridRow {
                                    TextField("HR (bpm)", text: $heartRateField)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("RR (/min)", text: $respiratoryRateField)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("SpO₂ (%)", text: $spo2Field)
                                        .textFieldStyle(.roundedBorder)
                                    HStack {
                                        TextField("BP systolic", text: $bpSysField)
                                            .textFieldStyle(.roundedBorder)
                                        TextField("BP diastolic", text: $bpDiaField)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }
                                GridRow {
                                    TextField("Recorded at (ISO8601)", text: $recordedAtField)
                                        .textFieldStyle(.roundedBorder)
                                        .help("Leave blank for current time.")
                                    Toggle("Replace previous vitals for this episode", isOn: $replacePreviousVitals)
                                        .toggleStyle(.switch)
                                        .gridCellColumns(3)
                                }
                            }

                            HStack {
                                Button {
                                    saveVitalsTapped()
                                } label: {
                                    Label("Save vitals", systemImage: "heart.text.square")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(activeEpisodeID == nil)

                                Spacer()
                            }

                            if !vitalsHistory.isEmpty {
                                Divider()
                                Text("Vitals history (oldest → newest)").font(.subheadline.bold())
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(vitalsHistory) { row in
                                        HStack {
                                            Text(row.recordedAt).font(.caption.monospaced())
                                            Spacer()
                                            Text(summary(for: row)).font(.caption)
                                        }
                                    }
                                }
                                HStack {
                                    Picker("Delete a row…", selection: $vitalsDeleteSelection) {
                                        Text("—").tag(Int64?.none)
                                        ForEach(vitalsHistory) { row in
                                            Text("\(row.recordedAt)").tag(Optional(row.id))
                                        }
                                    }
                                    .labelsHidden()
                                    Button(role: .destructive) {
                                        deleteSelectedVitals()
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .disabled(vitalsDeleteSelection == nil)
                                }
                            } else {
                                Text("No vitals recorded for this episode yet.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 8)

                    Divider()

                    // Two columns using HStack (forces top alignment)
                    HStack(alignment: .top, spacing: 20) {
                        // Column A (left)
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader("Main Complaint")
                            complaintBlock

                            SectionHeader("History of Present Illness")
                            pickerRow("Appearance", $appearance, appearanceChoices)
                            pickerRow("Feeding", $feeding, feedingChoices)
                            pickerRow("Breathing", $breathing, breathingChoices)
                            pickerRow("Urination", $urination, urinationChoices)
                            pickerRow("Pain", $pain, painChoices)
                            pickerRow("Stools", $stools, stoolsChoices)
                            multiSelectChips(title: "Context", options: contextChoices, selection: $context)
                            TextField("HPI summary", text: $hpi, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(3...6)
                            TextField("Duration (hours)", text: $duration)
                                .textFieldStyle(.roundedBorder)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                        // Column B (right)
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader("Physical Examination")
                            pickerRow("General appearance", $generalAppearance, generalChoices)
                            pickerRow("Hydration", $hydration, hydrationChoices)
                            pickerRow("Heart", $heart, heartChoices)
                            pickerRow("Color / Hemodynamics", $color, colorChoices)
                            multiSelectChips(title: "Skin", options: skinOptionsMulti, selection: $skinSet)
                            multiSelectChips(title: "ENT", options: entChoices, selection: $ent)
                            pickerRow("Right ear", $rightEar, earChoices)
                            pickerRow("Left ear", $leftEar, earChoices)
                            pickerRow("Right eye", $rightEye, eyeChoices)
                            pickerRow("Left eye", $leftEye, eyeChoices)
                            multiSelectChips(title: "Lungs", options: lungsOptionsMulti, selection: $lungsSet)
                            multiSelectChips(title: "Abdomen", options: abdomenOptionsMulti, selection: $abdomenSet)
                            pickerRow("Peristalsis", $peristalsis, peristalsisChoices)
                            multiSelectChips(title: "Genitalia", options: genitaliaOptionsMulti, selection: $genitaliaSet)
                            pickerRow("Neurological", $neurological, neuroChoices)
                            pickerRow("Musculoskeletal", $musculoskeletal, mskChoices)
                            multiSelectChips(title: "Lymph nodes", options: nodesOptionsMulti, selection: $lymphNodesSet)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }

                    // Plan
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader("Problem Listing")
                        HStack {
                            Button {
                                generateProblemList()
                            } label: {
                                Label("Generate Problem List", systemImage: "brain.head.profile")
                            }
                            .buttonStyle(.borderedProminent)
                            .help("Build an aggregated problem listing from patient age/sex, complaint, duration, and abnormal findings.")
                            Spacer()
                        }
                        TextEditor(text: $problemListing)
                            .frame(minHeight: 120)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                        TextField("Complementary investigations", text: $complementaryInvestigations, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                        TextField("Working diagnosis", text: $diagnosis)
                            .textFieldStyle(.roundedBorder)
                        TextField("ICD-10", text: $icd10)
                            .textFieldStyle(.roundedBorder)
                        SectionHeader("Plan")
                        TextEditor(text: $medications)
                            .frame(minHeight: 80)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                        pickerRow("Anticipatory guidance", $anticipatoryGuidance, guidanceChoices)
                        TextField("Comments", text: $comments, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.top, 8)

                    // AI assistance (JSON flags + API – stubbed for now)
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader("AI Assistance")
                        Text("JSON guideline flags run locally and do not change the record; AI queries will later be configured in the clinician profile.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Button {
                                triggerGuidelineFlags()
                            } label: {
                                Label("Check guideline flags", systemImage: "exclamationmark.triangle")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                triggerAIForEpisode()
                            } label: {
                                if aiIsRunning {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .padding(.trailing, 4)
                                    Text("Asking AI…")
                                } else {
                                    Label("Ask AI", systemImage: "sparkles")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(aiIsRunning)

                            Button {
                                previewAIPrompt()
                            } label: {
                                Label("Preview AI JSON", systemImage: "doc.plaintext")
                            }
                            .buttonStyle(.bordered)

                            Spacer()
                        }

                        // ICD-10 suggestion UI (AI Assistance)
                        if let icdSuggestion = appState.icd10SuggestionForActiveEpisode,
                           !icdSuggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Suggested ICD-10")
                                    .font(.subheadline.bold())
                                Text(icdSuggestion)
                                    .font(.caption)
                                    .textSelection(.enabled)

                                HStack {
                                    Button {
                                        // Apply the suggestion into the editable ICD-10 field.
                                        icd10 = icdSuggestion
                                    } label: {
                                        Label("Apply to ICD-10 field", systemImage: "arrow.down.doc")
                                    }
                                    .buttonStyle(.bordered)

                                    if !icd10.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text("Current ICD-10 will be replaced.")
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
                                Text("ICD-10 codes found in AI note")
                                    .font(.subheadline.bold())

                                Text("Tap a code to append it to the ICD-10 field. Duplicates are ignored.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                // Simple adaptive grid of code buttons
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
                                Text("Guideline flags (local JSON)")
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
                                Text("AI notes (per provider)")
                                    .font(.subheadline.bold())
                                ForEach(appState.aiSummariesForActiveEpisode.keys.sorted(), id: \.self) { provider in
                                    if let text = appState.aiSummariesForActiveEpisode[provider] {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(provider == "local-stub" ? "AI (stub)" : provider)
                                                .font(.caption.bold())
                                                .foregroundStyle(.secondary)
                                            Text(text)
                                                .font(.caption)
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
                                    // Simple chronological list, newest → oldest (already sorted in AppState)
                                    ForEach(appState.aiInputsForActiveEpisode) { row in
                                        Button {
                                            selectedAIHistoryID = row.id
                                        } label: {
                                            VStack(alignment: .leading, spacing: 2) {
                                                HStack {
                                                    Text(row.createdAtISO.isEmpty ? "Time: n/a" : row.createdAtISO)
                                                        .font(.caption2.monospaced())
                                                    Spacer()
                                                    Text(row.model.isEmpty ? "provider: unknown" : row.model)
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                }
                                                Text(row.responsePreview.isEmpty ? "(no response stored)" : row.responsePreview)
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

                                    // Full-response viewer for the selected history entry
                                    if let selectedID = selectedAIHistoryID,
                                       let selectedRow = appState.aiInputsForActiveEpisode.first(where: { $0.id == selectedID }) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Selected AI response")
                                                .font(.subheadline.bold())
                                            ScrollView {
                                                Text(selectedRow.fullResponse.isEmpty ? "(no response stored)" : selectedRow.fullResponse)
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
                                    }
                                }
                                .padding(.top, 4)
                            } label: {
                                Text("AI history for this episode")
                                    .font(.subheadline.bold())
                            }
                            .padding(8)
                            .background(Color.gray.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        if !aiPromptPreview.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Structured episode JSON (debug)")
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
                    .padding(.horizontal, 20)

                    // Inline Done button so the user can close the form after saving without relying on the toolbar
                    HStack {
                        Spacer()
                        Button("Done") {
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 8)
                }
                .padding(20)
            }
            .frame(minWidth: 860, idealWidth: 980, maxWidth: .infinity,
                   minHeight: 580, idealHeight: 720, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveTapped() }
                        .keyboardShortcut(.defaultAction)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { dismiss() }
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
            }
        }
    }

    // MARK: - Subviews

    private var complaintBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select common complaints")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Simple chip-like toggles in rows of 4 for predictable wrapping
            WrappingChips(strings: complaintOptions, selection: $presetComplaints)

            TextField("Other complaints (comma-separated)", text: $otherComplaints)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func pickerRow(_ title: String, _ selection: Binding<String>, _ options: [String]) -> some View {
        HStack {
            Text(title)
                .frame(width: 220, alignment: .leading)
                .foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func multiSelectChips(title: String, options: [String], selection: Binding<Set<String>>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            WrappingChips(strings: options, selection: selection)
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
            throw NSError(domain: "SickEpisodeForm.DB", code: 1, userInfo: [NSLocalizedDescriptionKey: "open failed: \(msg)"])
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

    private func insertEpisode(dbURL: URL, patientID: Int64, payload: [String: Any]) throws -> Int64 {
        log.info("insertEpisode → db=\(dbURL.path, privacy: .public), pid=\(patientID)")
        var db: OpaquePointer?
        db = try dbOpen(dbURL)
        defer { if db != nil { sqlite3_close(db) } }

        let sql = """
        INSERT INTO episodes (
          patient_id, user_id, created_at,
          main_complaint, hpi, duration,
          appearance, feeding, breathing, urination, pain, stools, context,
          general_appearance, hydration, heart, color, skin,
          ent, right_ear, left_ear, right_eye, left_eye,
          lungs, abdomen, peristalsis, genitalia,
          neurological, musculoskeletal, lymph_nodes,
          problem_listing, complementary_investigations, diagnosis, icd10, medications,
          anticipatory_guidance, comments
        ) VALUES ( ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? );
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SickEpisodeForm.DB", code: 2, userInfo: [NSLocalizedDescriptionKey: "prepare insert failed: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }

        // 1: patient_id
        sqlite3_bind_int64(stmt, 1, patientID)
        // 2: created_at
        bindText(stmt, 2, isoNow())

        func str(_ k: String) -> String? { payload[k] as? String }

        // 3.. end: follow the column order above
        bindText(stmt, 3,  str("main_complaint"))
        bindText(stmt, 4,  str("hpi"))
        bindText(stmt, 5,  str("duration"))
        bindText(stmt, 6,  str("appearance"))
        bindText(stmt, 7,  str("feeding"))
        bindText(stmt, 8,  str("breathing"))
        bindText(stmt, 9,  str("urination"))
        bindText(stmt, 10, str("pain"))
        bindText(stmt, 11, str("stools"))
        bindText(stmt, 12, str("context"))
        bindText(stmt, 13, str("general_appearance"))
        bindText(stmt, 14, str("hydration"))
        bindText(stmt, 15, str("heart"))
        bindText(stmt, 16, str("color"))
        bindText(stmt, 17, str("skin"))
        bindText(stmt, 18, str("ent"))
        bindText(stmt, 19, str("right_ear"))
        bindText(stmt, 20, str("left_ear"))
        bindText(stmt, 21, str("right_eye"))
        bindText(stmt, 22, str("left_eye"))
        bindText(stmt, 23, str("lungs"))
        bindText(stmt, 24, str("abdomen"))
        bindText(stmt, 25, str("peristalsis"))
        bindText(stmt, 26, str("genitalia"))
        bindText(stmt, 27, str("neurological"))
        bindText(stmt, 28, str("musculoskeletal"))
        bindText(stmt, 29, str("lymph_nodes"))
        bindText(stmt, 30, str("problem_listing"))
        bindText(stmt, 31, str("complementary_investigations"))
        bindText(stmt, 32, str("diagnosis"))
        bindText(stmt, 33, str("icd10"))
        bindText(stmt, 34, str("medications"))
        bindText(stmt, 35, str("anticipatory_guidance"))
        bindText(stmt, 36, str("comments"))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
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
          main_complaint = ?, hpi = ?, duration = ?,
          appearance = ?, feeding = ?, breathing = ?, urination = ?, pain = ?, stools = ?, context = ?,
          general_appearance = ?, hydration = ?, heart = ?, color = ?, skin = ?,
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
        bindText(stmt, 4,  str("appearance"))
        bindText(stmt, 5,  str("feeding"))
        bindText(stmt, 6,  str("breathing"))
        bindText(stmt, 7,  str("urination"))
        bindText(stmt, 8,  str("pain"))
        bindText(stmt, 9,  str("stools"))
        bindText(stmt, 10, str("context"))
        bindText(stmt, 11, str("general_appearance"))
        bindText(stmt, 12, str("hydration"))
        bindText(stmt, 13, str("heart"))
        bindText(stmt, 14, str("color"))
        bindText(stmt, 15, str("skin"))
        bindText(stmt, 16, str("ent"))
        bindText(stmt, 17, str("right_ear"))
        bindText(stmt, 18, str("left_ear"))
        bindText(stmt, 19, str("right_eye"))
        bindText(stmt, 20, str("left_eye"))
        bindText(stmt, 21, str("lungs"))
        bindText(stmt, 22, str("abdomen"))
        bindText(stmt, 23, str("peristalsis"))
        bindText(stmt, 24, str("genitalia"))
        bindText(stmt, 25, str("neurological"))
        bindText(stmt, 26, str("musculoskeletal"))
        bindText(stmt, 27, str("lymph_nodes"))
        bindText(stmt, 28, str("problem_listing"))
        bindText(stmt, 29, str("complementary_investigations"))
        bindText(stmt, 30, str("diagnosis"))
        bindText(stmt, 31, str("icd10"))
        bindText(stmt, 32, str("medications"))
        bindText(stmt, 33, str("anticipatory_guidance"))
        bindText(stmt, 34, str("comments"))

        sqlite3_bind_int64(stmt, 35, episodeID)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SickEpisodeForm.DB", code: 5, userInfo: [NSLocalizedDescriptionKey: "update step failed: \(msg)"])
        }
        log.info("updateEpisode OK → id=\(episodeID), changes=\(sqlite3_changes(db))")
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
            log.error("debugCountEpisodes: open failed")
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
            log.info("Episodes count for pid \(patientID): \(c)")
        }
    }

    // MARK: - Vitals DB helpers

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
        SELECT main_complaint, hpi, duration,
               appearance, feeding, breathing, urination, pain, stools, context,
               general_appearance, hydration, heart, color, skin,
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
            "main_complaint","hpi","duration",
            "appearance","feeding","breathing","urination","pain","stools","context",
            "general_appearance","hydration","heart","color","skin",
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
        // Complaints → split and map into preset + "other"
        let allComplaints = splitTrim(row["main_complaint"])
        let presetSet = Set(allComplaints.filter { complaintOptions.contains($0) })
        let freeList = allComplaints.filter { !complaintOptions.contains($0) }
        self.presetComplaints = presetSet
        self.otherComplaints = freeList.joined(separator: ", ")

        self.hpi = row["hpi"] ?? ""
        self.duration = row["duration"] ?? ""

        assignPicker(row["appearance"], allowed: appearanceChoices) { self.appearance = $0 }
        assignPicker(row["feeding"],   allowed: feedingChoices)   { self.feeding = $0 }
        assignPicker(row["breathing"], allowed: breathingChoices) { self.breathing = $0 }
        assignPicker(row["urination"], allowed: urinationChoices) { self.urination = $0 }
        assignPicker(row["pain"],      allowed: painChoices)      { self.pain = $0 }
        assignPicker(row["stools"],    allowed: stoolsChoices)    { self.stools = $0 }
        self.context = Set(splitTrim(row["context"]).filter { contextChoices.contains($0) })

        assignPicker(row["general_appearance"], allowed: generalChoices) { self.generalAppearance = $0 }
        assignPicker(row["hydration"], allowed: hydrationChoices) { self.hydration = $0 }
        assignPicker(row["heart"], allowed: heartChoices) { self.heart = $0 }
        assignPicker(row["color"], allowed: colorChoices) { self.color = $0 }
        

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

    /// Compute a combined complaint string from preset + free text.
    private func currentMainComplaintString() -> String {
        let free = otherComplaints
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let complaints = Array(presetComplaints).sorted() + free
        return complaints.joined(separator: ", ")
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
            return "\(yrs) y"
        } else if yrs == 1 {
            // This is the case that was wrong before (e.g. 1 y 4 mo)
            if mos > 0 {
                return "1 y \(mos) mo"
            } else {
                return "1 y"
            }
        } else if mos >= 1 {
            // Under 1 year → months only
            return "\(mos) mo"
        } else {
            // Newborns / very young infants → days
            return "\(days) d"
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
                lines.append("Age: \(a)")
            }
            if let sx = demo.sex, !sx.isEmpty {
                lines.append("Sex: \(sx)")
            }
            if let vax = demo.vax,
               !vax.isEmpty,
               vax.lowercased() != "up to date",
               vax.lowercased() != "up-to-date" {
                lines.append("Vaccination status: \(vax)")
            }
        }

        // Main complaint + duration
        let mc = currentMainComplaintString()
        if !mc.isEmpty { lines.append("Main complaint: \(mc)") }
        if !duration.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("Duration: \(duration) hours")
        }
        // Free-text HPI summary (so items like "blood in stool" are visible to AI)
        if !hpi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("HPI summary: \(hpi)")
        }

        // Structured HPI abnormalities
        if appearance != "Well" { lines.append("Appearance: \(appearance)") }
        if feeding != "Normal" { lines.append("Feeding: \(feeding)") }
        if breathing != "Normal" { lines.append("Breathing: \(breathing)") }
        if urination != "Normal" { lines.append("Urination: \(urination)") }
        if pain != "None" { lines.append("Pain: \(pain)") }
        if stools != "Normal" { lines.append("Stools: \(stools)") }
        let ctx = Array(context).filter { $0 != "None" }
        if !ctx.isEmpty {
            lines.append("Context: \(ctx.sorted().joined(separator: ", "))")
        }

        // Vitals abnormalities – use current UI fields + classification badges
        let vitalsFlags = vitalsBadges()
        if !vitalsFlags.isEmpty {
            var vitalsPieces: [String] = []

            let tText = temperatureCField.trimmingCharacters(in: .whitespaces)
            if !tText.isEmpty {
                vitalsPieces.append("T \(tText)°C")
            }

            let hrText = heartRateField.trimmingCharacters(in: .whitespaces)
            if !hrText.isEmpty {
                vitalsPieces.append("HR \(hrText)")
            }

            let rrText = respiratoryRateField.trimmingCharacters(in: .whitespaces)
            if !rrText.isEmpty {
                vitalsPieces.append("RR \(rrText)")
            }

            let s2Text = spo2Field.trimmingCharacters(in: .whitespaces)
            if !s2Text.isEmpty {
                vitalsPieces.append("SpO₂ \(s2Text)%")
            }

            let sysText = bpSysField.trimmingCharacters(in: .whitespaces)
            let diaText = bpDiaField.trimmingCharacters(in: .whitespaces)
            if !sysText.isEmpty && !diaText.isEmpty {
                vitalsPieces.append("BP \(sysText)/\(diaText)")
            }

            let valuesPart = vitalsPieces.joined(separator: ", ")
            let flagsPart = vitalsFlags.joined(separator: ", ")

            if !valuesPart.isEmpty {
                lines.append("Abnormal vitals: \(valuesPart) [\(flagsPart)]")
            } else {
                lines.append("Abnormal vitals: \(flagsPart)")
            }
        }

        // PE abnormalities
        if generalAppearance != "Well" { lines.append("General Appearance: \(generalAppearance)") }
        if hydration != "Normal" { lines.append("Hydration: \(hydration)") }
        if heart != "Normal" { lines.append("Heart: \(heart)") }
        if color != "Normal" { lines.append("Color: \(color)") }
        if !(skinSet.count == 1 && skinSet.contains("Normal")) {
            lines.append("Skin: \(Array(skinSet).sorted().joined(separator: ", "))")
        }
        if !(ent.count == 1 && ent.contains("Normal")) {
            lines.append("ENT: \(Array(ent).sorted().joined(separator: ", "))")
        }
        if rightEar != "Normal" { lines.append("Right Ear: \(rightEar)") }
        if leftEar  != "Normal" { lines.append("Left Ear: \(leftEar)") }
        if rightEye != "Normal" { lines.append("Right Eye: \(rightEye)") }
        if leftEye  != "Normal" { lines.append("Left Eye: \(leftEye)") }
        if !(lungsSet.count == 1 && lungsSet.contains("Normal")) {
            lines.append("Lungs: \(Array(lungsSet).sorted().joined(separator: ", "))")
        }
        if !(abdomenSet.count == 1 && abdomenSet.contains("Normal")) {
            lines.append("Abdomen: \(Array(abdomenSet).sorted().joined(separator: ", "))")
        }
        if peristalsis != "Normal" { lines.append("Peristalsis: \(peristalsis)") }
        if !(genitaliaSet.count == 1 && genitaliaSet.contains("Normal")) {
            lines.append("Genitalia: \(Array(genitaliaSet).sorted().joined(separator: ", "))")
        }
        if neurological != "Alert" { lines.append("Neurological: \(neurological)") }
        if musculoskeletal != "Normal" { lines.append("MSK: \(musculoskeletal)") }
        if !(lymphNodesSet.count == 1 && lymphNodesSet.contains("None")) {
            lines.append("Lymph Nodes: \(Array(lymphNodesSet).sorted().joined(separator: ", "))")
        }

        problemListing = lines.joined(separator: "\n")
    }
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

        return AppState.EpisodeAIContext(
            patientID: pid,
            episodeID: Int(eid),
            problemListing: problemListing,
            complementaryInvestigations: complementaryInvestigations,
            vaccinationStatus: vaccinationStatus,
            pmhSummary: pmhSummary
        )
    }

    /// Trigger local guideline flags via AppState using the current episode context.
    private func triggerGuidelineFlags() {
        guard let ctx = buildEpisodeAIContext() else {
            appState.aiGuidelineFlagsForActiveEpisode = [
                "Cannot run guideline flags: please ensure a patient and saved episode are selected."
            ]
            return
        }
        // Use the central JSON-based entry point; for now we pass nil so AppState
        // falls back to the existing stub when no clinician-specific rules are used.
        appState.runGuidelineFlags(using: ctx, rulesJSON: nil)
    }

    /// Trigger the AI call via AppState using the current episode context.
    private func triggerAIForEpisode() {
        guard let ctx = buildEpisodeAIContext() else {
            appState.aiSummariesForActiveEpisode = [
                "local-stub": "Cannot run AI: please ensure a patient and saved episode are selected."
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
            aiPromptPreview = "Cannot build AI prompt: please ensure a patient and saved episode are selected, and that problem listing and complementary investigations are filled in as appropriate."
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

    // MARK: - Save (commit to db + refresh UI)
    private func saveTapped() {
        let free = otherComplaints
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let complaints = Array(presetComplaints).sorted() + free

        var payload: [String: Any] = [:]
        // Core
        payload["main_complaint"] = complaints.joined(separator: ", ")
        payload["hpi"] = hpi
        payload["duration"] = duration
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
        let keysJoined = payload.keys.joined(separator: ",")
        log.info("Save tapped (episode: \(episodeLabel)) payload keys: \(keysJoined)")

        guard let pid = appState.selectedPatientID,
              let dbURL = appState.currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else {
            log.error("Cannot save episode: missing pid or dbURL.")
            return
        }

        log.info("Persisting SickEpisode to DB: \(dbURL.path, privacy: .public) for pid \(pid)")
        do {
            try ensureEpisodesTable(dbURL: dbURL)
        } catch {
            log.error("ensureEpisodesTable failed: \(String(describing: error), privacy: .public)")
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

            // Refresh visits/profile but keep the form open
            appState.loadVisits(for: pid)
            appState.loadPatientProfile(for: Int64(pid))
        } catch {
            log.error("Episode save failed: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - Small helpers

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

/// Minimal wrapping chips component backed by a Set of strings.
private struct WrappingChips: View {
    let strings: [String]
    @Binding var selection: Set<String>

    var body: some View {
        // Use simple flexible rows to avoid heavy layout logic.
        VStack(alignment: .leading, spacing: 8) {
            let rows = stride(from: 0, to: strings.count, by: 4).map {
                Array(strings[$0 ..< min($0 + 4, strings.count)])
            }
            ForEach(rows.indices, id: \.self) { idx in
                HStack(spacing: 8) {
                    ForEach(rows[idx], id: \.self) { s in
                        Toggle(isOn: Binding(
                            get: { selection.contains(s) },
                            set: { on in
                                if on { selection.insert(s) } else { selection.remove(s) }
                            })
                        ) {
                            Text(s)
                        }
                        .toggleStyle(.button)
                        .buttonStyle(.bordered)
                    }
                }
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
        let band = ageBandLabel(forYears: ageY)

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
                out.append(band != nil ? "HR low for \(band!)" : "HR low")
            } else if let hi = hi, hr > hi {
                out.append(band != nil ? "HR high for \(band!)" : "HR high")
            }
        }

        if let rr = rr, let a = ageY {
            let (lo, hi) = rrRange(forYears: a)
            if let lo = lo, rr < lo {
                out.append(band != nil ? "RR low for \(band!)" : "RR low")
            } else if let hi = hi, rr > hi {
                out.append(band != nil ? "RR high for \(band!)" : "RR high")
            }
        }

        // Temperature flags
        if let t = temp {
            if t >= 38.0 {
                out.append("Fever")
            } else if t < 35.5 {
                out.append("Hypothermia")
            }
        }

        // SpO₂ flags
        if let s2 = s2, s2 < 95 {
            out.append("SpO₂ low")
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
                if let msg = res.message, !msg.isEmpty {
                    out.append(msg)
                } else {
                    let label: String
                    switch res.category {
                    case .elevated: label = "Elevated"
                    case .stage1:   label = "Stage 1"
                    case .stage2:   label = "Stage 2"
                    default:        label = "Abnormal"
                    }
                    out.append("BP \(sysInt)/\(diaInt) \(label)")
                }
            default:
                // Handles any future/extra categories (e.g., low-for-age / hypotension)
                if let msg = res.message, !msg.isEmpty {
                    out.append(msg)
                } else {
                    out.append("BP \(sysInt)/\(diaInt) Abnormal")
                }
            }
        }

        return out
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

    /// Human-readable band label ("neonate", "infant", "toddler", etc.)
    private func ageBandLabel(forYears y: Double?) -> String? {
        guard let y = y else { return nil }
        let neonate = 28.0 / 365.25
        if y < neonate { return "neonate" }
        else if y < 1.0 { return "infant" }
        else if y < 3.0 { return "toddler" }
        else if y < 6.0 { return "preschool" }
        else if y < 12.0 { return "school age" }
        else if y < 16.0 { return "adolescent" }
        else { return "adult-like" }
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
        do {
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

            // Skip if all empty
            if [w,h,hc,t].allSatisfy({ $0 == nil }) &&
               [hr,rr,s2,bs,bd].allSatisfy({ $0 == nil }) {
                log.info("Vitals not saved: all fields empty")
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
            log.error("saveVitalsTapped failed: \(String(describing: error), privacy: .public)")
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
