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

    @State private var saving = false
    @State private var saveError: String?

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
        .onAppear(perform: loadFromAppState)
        .navigationTitle("Perinatal History")
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                Button {
                    save()
                } label: {
                    if saving { ProgressView() } else { Text("Save") }
                }
                .disabled(saving)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Reset") { loadFromAppState() }
            }
        }
        .alert("Save failed", isPresented: .constant(saveError != nil), actions: {
            Button("OK") { saveError = nil }
        }, message: {
            Text(saveError ?? "")
        })
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
        //birthLengthCm = h?.birthLengthCm.map { trimmedDecimal($0) } ?? ""
        birthLengthCm = ""
        //birthHeadCircumferenceCm = h?.birthHeadCircumferenceCm.map { trimmedDecimal($0) } ?? ""
        birthHeadCircumferenceCm = ""
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
    }

    private func save() {
        guard app.selectedPatientID != nil else {
            saveError = "No active patient selected."
            return
        }
        let pid = app.selectedPatientID!

        saving = true
        defer { saving = false }

        var h = app.perinatalHistory ?? PerinatalHistory(patientID: pid) // relies on PerinatalHistory having default nils

        h.pregnancyRisk = emptyToNil(pregnancyRisk)
        h.birthMode = emptyToNil(birthMode)
        h.birthTermWeeks = Int(birthTermWeeks)
        h.resuscitation = emptyToNil(resuscitation)
        h.nicuStay = nicuStay
        h.infectionRisk = emptyToNil(infectionRisk)
        h.birthWeightG = Int(birthWeightG)
        //h.birthLengthCm = Double(birthLengthCm.replacingOccurrences(of: ",", with: "."))
        // TODO: Re-wire birthLengthCm once exact property name on PerinatalHistory is confirmed
        //h.birthHeadCircumferenceCm = Double(birthHeadCircumferenceCm.replacingOccurrences(of: ",", with: "."))
        // TODO: Re-wire birthHeadCircumferenceCm once exact property name on PerinatalHistory is confirmed
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

        if app.savePerinatalHistoryForSelectedPatient(h) {
            // refresh UI cache
            app.loadPerinatalHistoryForSelectedPatient()
        } else {
            saveError = "App failed to save the perinatal history."
        }
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
}
