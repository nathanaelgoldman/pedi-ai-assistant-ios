//
//  PerinatalHistoryForm.swift
//  DrsMainApp
//
//  Created by yunastic on 11/13/25.
//
import SwiftUI

/// Lightweight editor for the perinatal_history table, wired to AppState.
/// Reads current values from `app.perinatalHistory`, lets you edit, then saves via
/// `app.savePerinatalHistoryForSelectedPatient(_:)`.
struct PerinatalHistoryForm: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    // Store as strings for painless cross-platform text fields; convert on save.
    @State private var pregnancyRisk = ""
    @State private var birthMode = ""
    @State private var birthTermWeeks = ""
    @State private var resuscitation = ""
    @State private var nicuStay = false
    @State private var infectionRisk = ""
    @State private var birthWeightG = ""
    @State private var birthLengthCm = ""
    @State private var birthHeadCircumferenceCm = ""
    @State private var maternityStayEvents = ""
    @State private var maternityVaccinations = ""
    @State private var vitaminK = false
    @State private var feedingInMaternity = ""
    @State private var passedMeconium24h = false
    @State private var urination24h = false
    @State private var heartScreening = ""
    @State private var metabolicScreening = ""
    @State private var hearingScreening = ""
    @State private var motherVaccinations = ""
    @State private var familyVaccinations = ""
    @State private var maternityDischargeDate = ""  // ISO yyyy-MM-dd preferred
    @State private var dischargeWeightG = ""
    @State private var illnessesAfterBirth = ""
    @State private var evolutionSinceMaternity = ""
    @State private var currentPatientID: Int?
    @State private var originalHistory: PerinatalHistory?

    @State private var saving = false
    @State private var saveError: String?
    @State private var showSavedToast = false

    var body: some View {
        Form {
            Section(header: Text("Birth & Pregnancy")) {
                TextField("Pregnancy risk", text: $pregnancyRisk)
                TextField("Birth mode (e.g., vaginal, C-section)", text: $birthMode)
                TextField("Birth term (weeks)", text: $birthTermWeeks)
                TextField("Resuscitation", text: $resuscitation)
                Toggle("NICU stay", isOn: $nicuStay)
                TextField("Infection risk", text: $infectionRisk)
            }

            Section(header: Text("Measurements at Birth")) {
                TextField("Birth weight (g)", text: $birthWeightG)
                TextField("Birth length (cm)", text: $birthLengthCm)
                TextField("Head circumference (cm)", text: $birthHeadCircumferenceCm)
                TextField("Discharge weight (g)", text: $dischargeWeightG)
            }

            Section(header: Text("Maternity Stay")) {
                TextField("Events", text: $maternityStayEvents)
                TextField("Vaccinations in maternity", text: $maternityVaccinations)
                Toggle("Vitamin K given", isOn: $vitaminK)
                TextField("Feeding in maternity", text: $feedingInMaternity)
                Toggle("Passed meconium in 24h", isOn: $passedMeconium24h)
                Toggle("Urination in 24h", isOn: $urination24h)
                TextField("Discharge date (YYYY-MM-DD)", text: $maternityDischargeDate)
            }

            Section(header: Text("Screenings")) {
                TextField("Heart screening", text: $heartScreening)
                TextField("Metabolic screening", text: $metabolicScreening)
                TextField("Hearing screening", text: $hearingScreening)
            }

            Section(header: Text("Family & Aftercare")) {
                TextField("Mother vaccinations", text: $motherVaccinations)
                TextField("Family vaccinations", text: $familyVaccinations)
                TextField("Illnesses after birth", text: $illnessesAfterBirth)
                TextField("Evolution since maternity", text: $evolutionSinceMaternity)
            }
        }
        .onAppear {
            if app.perinatalHistory == nil {
                // Proactively fetch from DB if not already loaded
                app.loadPerinatalHistoryForSelectedPatient()
            }
            loadFromAppState()
        }
        .onChange(of: app.perinatalHistory) { _, _ in
            // If the store refreshed (e.g., loaded from DB), reflect those values into the form
            loadFromAppState()
        }
        .task(id: app.selectedPatientID) {
            // Autosave for the patient that owned this form, then close the form
            autosavePreviousPatientIfNeeded()
            dismiss()
        }
        .onDisappear {
            // Safety net: if the form is dismissed in another way, still autosave
            autosavePreviousPatientIfNeeded()
        }
        .navigationTitle("Perinatal History")
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                Button {
                    save()
                } label: {
                    if saving { ProgressView() } else { Text("Save") }
                }
                .disabled(saving || !isDirty)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Reset") { loadFromAppState() }
            }
        }
        .alert(
            "Save failed",
            isPresented: Binding(get: { saveError != nil },
                                 set: { if !$0 { saveError = nil } }),
            actions: {
                Button("OK") { saveError = nil }
            },
            message: {
                Text(saveError ?? "")
            }
        )
        .overlay(alignment: .bottom) {
            if showSavedToast {
                savedToast
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Load/Save

    private func loadFromAppState() {
        let h = app.perinatalHistory
        pregnancyRisk = h?.pregnancyRisk ?? ""
        birthMode = h?.birthMode ?? ""
        birthTermWeeks = h?.birthTermWeeks.map(String.init) ?? ""
        resuscitation = h?.resuscitation ?? ""
        nicuStay = h?.nicuStay ?? false
        infectionRisk = h?.infectionRisk ?? ""
        birthWeightG = h?.birthWeightG.map(String.init) ?? ""
        birthLengthCm = h?.birthLengthCm.map { trimmedDecimal($0) } ?? ""
        birthHeadCircumferenceCm = h?.birthHeadCircumferenceCm.map { trimmedDecimal($0) } ?? ""
        maternityStayEvents = h?.maternityStayEvents ?? ""
        maternityVaccinations = h?.maternityVaccinations ?? ""
        vitaminK = h?.vitaminK ?? false
        feedingInMaternity = h?.feedingInMaternity ?? ""
        passedMeconium24h = h?.passedMeconium24h ?? false
        urination24h = h?.urination24h ?? false
        heartScreening = h?.heartScreening ?? ""
        metabolicScreening = h?.metabolicScreening ?? ""
        hearingScreening = h?.hearingScreening ?? ""
        motherVaccinations = h?.motherVaccinations ?? ""
        familyVaccinations = h?.familyVaccinations ?? ""
        maternityDischargeDate = h?.maternityDischargeDate ?? ""
        dischargeWeightG = h?.dischargeWeightG.map(String.init) ?? ""
        illnessesAfterBirth = h?.illnessesAfterBirth ?? ""
        evolutionSinceMaternity = h?.evolutionSinceMaternity ?? ""
        currentPatientID = app.selectedPatientID
        originalHistory = app.perinatalHistory
    }

    private func save() {
        guard let pid = app.selectedPatientID else {
            saveError = "No active patient selected."
            return
        }

        saving = true
        defer { saving = false }

        // Build history from form fields for the selected patient
        let h = buildPerinatalHistory(for: pid)

        if app.savePerinatalHistoryForSelectedPatient(h) {
            app.loadPerinatalHistoryForSelectedPatient()
            originalHistory = app.perinatalHistory
            flashSavedToast()
        } else {
            saveError = "App failed to save the perinatal history."
        }
    }

    @MainActor
    private func buildPerinatalHistory(for pid: Int) -> PerinatalHistory {
        var h = app.perinatalHistory ?? PerinatalHistory(patientID: pid)

        h.patientID = pid
        h.pregnancyRisk = emptyToNil(pregnancyRisk)
        h.birthMode = emptyToNil(birthMode)
        h.birthTermWeeks = Int(birthTermWeeks)
        h.resuscitation = emptyToNil(resuscitation)
        h.nicuStay = nicuStay
        h.infectionRisk = emptyToNil(infectionRisk)
        h.birthWeightG = Int(birthWeightG)
        h.birthLengthCm = parseDouble(birthLengthCm)
        h.birthHeadCircumferenceCm = parseDouble(birthHeadCircumferenceCm)
        h.maternityStayEvents = emptyToNil(maternityStayEvents)
        h.maternityVaccinations = emptyToNil(maternityVaccinations)
        h.vitaminK = vitaminK
        h.feedingInMaternity = emptyToNil(feedingInMaternity)
        h.passedMeconium24h = passedMeconium24h
        h.urination24h = urination24h
        h.heartScreening = emptyToNil(heartScreening)
        h.metabolicScreening = emptyToNil(metabolicScreening)
        h.hearingScreening = emptyToNil(hearingScreening)
        h.motherVaccinations = emptyToNil(motherVaccinations)
        h.familyVaccinations = emptyToNil(familyVaccinations)
        h.maternityDischargeDate = emptyToNil(maternityDischargeDate)
        h.dischargeWeightG = Int(dischargeWeightG)
        h.illnessesAfterBirth = emptyToNil(illnessesAfterBirth)
        h.evolutionSinceMaternity = emptyToNil(evolutionSinceMaternity)

        return h
    }

    @MainActor
    private func autosavePreviousPatientIfNeeded() {
        guard let oldPid = currentPatientID,
              let url = app.currentDBURL else { return }

        let h = buildPerinatalHistory(for: oldPid)
        do {
            try PerinatalStore.upsert(dbURL: url, for: oldPid, history: h)
            // Update the in-memory cache if we are still on the same patient
            if app.selectedPatientID == oldPid {
                app.perinatalHistory = h
                originalHistory = h
                flashSavedToast()
            } else {
                flashSavedToast()
            }
        } catch {
            // Non-fatal: log but don't block UI
            print("Perinatal autosave failed for patient \(oldPid): \(error)")
        }
    }

    // MARK: - Dirty check

    private var isDirty: Bool {
        guard let pid = currentPatientID ?? app.selectedPatientID else { return false }
        let current = buildPerinatalHistory(for: pid)
        return !equal(current, originalHistory)
    }

    private func equal(_ a: PerinatalHistory?, _ b: PerinatalHistory?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a?, let b?):
            return a.patientID == b.patientID &&
                   a.pregnancyRisk == b.pregnancyRisk &&
                   a.birthMode == b.birthMode &&
                   a.birthTermWeeks == b.birthTermWeeks &&
                   a.resuscitation == b.resuscitation &&
                   a.nicuStay == b.nicuStay &&
                   a.infectionRisk == b.infectionRisk &&
                   a.birthWeightG == b.birthWeightG &&
                   a.birthLengthCm == b.birthLengthCm &&
                   a.birthHeadCircumferenceCm == b.birthHeadCircumferenceCm &&
                   a.maternityStayEvents == b.maternityStayEvents &&
                   a.maternityVaccinations == b.maternityVaccinations &&
                   a.vitaminK == b.vitaminK &&
                   a.feedingInMaternity == b.feedingInMaternity &&
                   a.passedMeconium24h == b.passedMeconium24h &&
                   a.urination24h == b.urination24h &&
                   a.heartScreening == b.heartScreening &&
                   a.metabolicScreening == b.metabolicScreening &&
                   a.hearingScreening == b.hearingScreening &&
                   a.motherVaccinations == b.motherVaccinations &&
                   a.familyVaccinations == b.familyVaccinations &&
                   a.maternityDischargeDate == b.maternityDischargeDate &&
                   a.dischargeWeightG == b.dischargeWeightG &&
                   a.illnessesAfterBirth == b.illnessesAfterBirth &&
                   a.evolutionSinceMaternity == b.evolutionSinceMaternity
        default:
            return false
        }
    }

    // MARK: - Toast

    private func flashSavedToast() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showSavedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showSavedToast = false
            }
        }
    }

    private var savedToast: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
            Text("Saved")
                .font(.headline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .clipShape(Capsule())
        .shadow(radius: 8, y: 2)
    }

    // MARK: - Helpers

    private func emptyToNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func trimmedDecimal(_ d: Double) -> String {
        // Avoid scientific notation / long tails
        let s = String(format: "%.2f", d)
        return s.replacingOccurrences(of: #"(\.0+)$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(,\0+)$"#, with: "", options: .regularExpression)
    }

    private func parseDouble(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let normalized = t.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }
}
