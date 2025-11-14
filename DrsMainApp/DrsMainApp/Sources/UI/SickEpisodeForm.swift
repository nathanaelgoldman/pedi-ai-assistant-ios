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

/// Form for creating or editing a sick episode.
/// This version focuses on a stable UI; persistence will be wired in next.
struct SickEpisodeForm: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    /// If non-nil, the form is editing that specific episode id.
    let editingEpisodeID: Int?

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
    @State private var skin: String = "Normal"
    @State private var ent: Set<String> = ["Normal"]
    @State private var rightEar: String = "Normal"
    @State private var leftEar: String = "Normal"
    @State private var rightEye: String = "Normal"
    @State private var leftEye: String = "Normal"
    @State private var lungs: String = "Normal"
    @State private var abdomen: String = "Normal"
    @State private var peristalsis: String = "Normal"
    @State private var genitalia: String = "Normal"
    @State private var neurological: String = "Alert"
    @State private var musculoskeletal: String = "Normal"
    @State private var lymphNodes: String = "None"

    // MARK: - Plan
    @State private var problemListing: String = ""
    @State private var complementaryInvestigations: String = ""
    @State private var diagnosis: String = ""
    @State private var icd10: String = ""
    @State private var medications: String = ""
    @State private var anticipatoryGuidance: String = "URI"
    @State private var comments: String = ""

    // MARK: - Choices
    private let complaintOptions = [
        "Fever","Cough","Runny nose","Diarrhea","Vomiting",
        "Rash","Abdominal pain","Headache"
    ]
    private let appearanceChoices = ["Well","Tired","Irritable","Lethargic"]
    private let feedingChoices = ["Normal","Decreased","Refuses"]
    private let breathingChoices = ["Normal","Fast","Labored","Noisy"]
    private let urinationChoices = ["Normal","Decreased","Painful","Foul-smelling"]
    private let painChoices = ["None","Abdominal","Ear","Throat","Limb"]
    private let stoolsChoices = ["Normal","Soft","Liquid"]
    private let contextChoices = ["Travel","Sick contact","Daycare","None"]

    private let generalChoices = ["Well","Tired","Irritable","Lethargic"]
    private let hydrationChoices = ["Normal","Decreased"]
    private let heartChoices = ["Normal","Murmur","Tachycardia"]
    private let colorChoices = ["Normal","Pale","Yellow"]
    private let skinChoices = ["Normal","Papular rash","Macular rash","Maculopapular rash","Petechiae","Purpura"]
    private let entChoices = ["Normal","Red throat","Ear discharge","Congested nose"]
    private let earChoices = ["Normal","Red TM","Red & Bulging with pus","Pus in canal","Not seen (wax)","Red canal"]
    private let eyeChoices = ["Normal","Discharge","Red","Crusty"]
    private let lungsChoices = ["Normal","Crackles","Wheeze","Decreased sounds"]
    private let abdomenChoices = ["Normal","Tender","Distended","Guarding"]
    private let peristalsisChoices = ["Normal","Increased","Decreased"]
    private let genitaliaChoices = ["Normal","Redness","Discharge","Abnormal"]
    private let neuroChoices = ["Alert","Sleepy","Irritable","Abnormal tone"]
    private let mskChoices = ["Normal","Limping","Swollen joint","Pain"]
    private let nodesChoices = ["None","Cervical","Generalized"]

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

                    // Two columns using Grid
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 16) {
                        GridRow {
                            // Column A
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

                            // Column B
                            VStack(alignment: .leading, spacing: 12) {
                                SectionHeader("Physical Examination")
                                pickerRow("General appearance", $generalAppearance, generalChoices)
                                pickerRow("Hydration", $hydration, hydrationChoices)
                                pickerRow("Heart", $heart, heartChoices)
                                pickerRow("Color / Hemodynamics", $color, colorChoices)
                                pickerRow("Skin", $skin, skinChoices)
                                multiSelectChips(title: "ENT", options: entChoices, selection: $ent)
                                pickerRow("Right ear", $rightEar, earChoices)
                                pickerRow("Left ear", $leftEar, earChoices)
                                pickerRow("Right eye", $rightEye, eyeChoices)
                                pickerRow("Left eye", $leftEye, eyeChoices)
                                pickerRow("Lungs", $lungs, lungsChoices)
                                pickerRow("Abdomen", $abdomen, abdomenChoices)
                                pickerRow("Peristalsis", $peristalsis, peristalsisChoices)
                                pickerRow("Genitalia", $genitalia, genitaliaChoices)
                                pickerRow("Neurological", $neurological, neuroChoices)
                                pickerRow("Musculoskeletal", $musculoskeletal, mskChoices)
                                pickerRow("Lymph nodes", $lymphNodes, nodesChoices)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }

                    // Plan
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader("Plan")
                        TextEditor(text: $problemListing)
                            .frame(minHeight: 100)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                        TextField("Complementary investigations", text: $complementaryInvestigations, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                        TextField("Working diagnosis", text: $diagnosis)
                            .textFieldStyle(.roundedBorder)
                        TextField("ICD-10", text: $icd10)
                            .textFieldStyle(.roundedBorder)
                        TextEditor(text: $medications)
                            .frame(minHeight: 80)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                        pickerRow("Anticipatory guidance", $anticipatoryGuidance, guidanceChoices)
                        TextField("Comments", text: $comments, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
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

    // MARK: - Save (placeholder; persistence in next step)
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
        payload["skin"] = skin
        payload["ent"] = Array(ent).sorted().joined(separator: ", ")
        payload["right_ear"] = rightEar
        payload["left_ear"] = leftEar
        payload["right_eye"] = rightEye
        payload["left_eye"] = leftEye
        payload["lungs"] = lungs
        payload["abdomen"] = abdomen
        payload["peristalsis"] = peristalsis
        payload["genitalia"] = genitalia
        payload["neurological"] = neurological
        payload["musculoskeletal"] = musculoskeletal
        payload["lymph_nodes"] = lymphNodes
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

        // Refresh visits/profile and close after a (soon-to-be) successful save.
        if let pid = appState.selectedPatientID {
            appState.loadVisits(for: Int64(pid))
            appState.loadPatientProfile(for: Int64(pid))
        }
        dismiss()
    }
}

// MARK: - Small helpers

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

