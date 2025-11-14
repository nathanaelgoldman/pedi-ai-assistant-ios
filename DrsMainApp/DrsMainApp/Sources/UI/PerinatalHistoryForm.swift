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

    // MARK: - Standardized choice sets (mirrors Python app)
    static let CH_PREGNANCY = [
        "normal", "gestational diabetes", "preeclampsia",
        "infection", "threat of premature birth", "intrauterine growth retardation"
    ]
    static let CH_BIRTH_MODE = [
        "normal vaginal delivery", "emergent c/s", "planned c/s",
        "instrumental unspecified", "vacuum", "forceps"
    ]
    static let CH_RESUSC = ["none", "free oxygen", "bag mask", "chest compression", "fluids & drugs"]
    static let CH_INF_RISK = ["PROM", "Seroconversion TORCH", "GBS+ & no treatment", "GBS+ & treatment"]
    static let CH_MAT_STAY_EVENTS = [
        "none", "weight loss &gt;= 10%", "hyperbilirubinemia with PT",
        "hyperbilirubinemia w/o PT", "hypoglycemia", "suspicion infection"
    ]
    static let CH_VACCINATIONS_MAT = ["BCG", "Hep. B", "RSV", "Anti-HBV Immunoglobulins"]
    static let CH_MOTHER_VAX = ["no vaccination", "dtap", "flu", "covid", "rsv"]
    static let CH_FAMILY_VAX = ["no vaccination", "dtap", "flu", "covid", "rsv"]
    static let CH_HEART = ["normal", "abnormal", "not done"]
    static let CH_METAB = ["done pending", "normal", "abnormal"]
    static let CH_HEARING = ["normal", "abnormal", "abnormal right", "abnormal left", "not done"]
    static let CH_FEEDING = ["EBF", "mixed", "exclusive formula feeding"]

    // Working state for multi-select fields (CSV-backed)
    @State private var pregnancyRiskSet: Set<String> = []
    @State private var infectionRiskSet: Set<String> = []
    @State private var maternityStayEventsSet: Set<String> = []
    @State private var maternityVaccinationsSet: Set<String> = []
    @State private var motherVaccinationsSet: Set<String> = []
    @State private var familyVaccinationsSet: Set<String> = []

    var body: some View {
        Form {
            GeometryReader { geo in
                let useTwoCols = geo.size.width >= 700
                if useTwoCols {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 12) {
                            columnLeft
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            columnRight
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                } else {
                    // Fallback to single column on narrow widths (e.g., iPhone portrait)
                    VStack(alignment: .leading, spacing: 12) {
                        columnLeft
                        columnRight
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                }
            }
            .frame(minHeight: 400) // keep a pleasant minimum height
        }
        .onAppear {
            if app.perinatalHistory == nil {
                // Proactively fetch from DB if not already loaded
                app.loadPerinatalHistoryForSelectedPatient()
            }
            loadFromAppState()
            coerceSelectionsToValid()
        }
        .onChange(of: app.perinatalHistory) { _, _ in
            // If the store refreshed (e.g., loaded from DB), reflect those values into the form
            loadFromAppState()
        }
        .onChange(of: app.selectedPatientID) { _, _ in
            // Patient changed while this form is open: autosave the old patient silently.
            autosavePreviousPatientIfNeeded()
        }
        .onDisappear {
            // Safety net: if the form is dismissed in another way, still autosave
            autosavePreviousPatientIfNeeded()
        }
        .navigationTitle("Perinatal History")
        .interactiveDismissDisabled(false)
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                Button {
                    save()
                } label: {
                    if saving { ProgressView() } else { Text("Save") }
                }
                .disabled(saving)
            }
            ToolbarItemGroup(placement: .cancellationAction) {
                Button("Done") { onDone() }
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
        .frame(minWidth: 900, idealWidth: 1050, maxWidth: 1400, minHeight: 560)
#if os(macOS)
        .presentationSizing(.fitted)
#endif
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

        // Sync multi-select sets from CSV-backed fields
        pregnancyRiskSet = csvToSet(h?.pregnancyRisk)
        infectionRiskSet = csvToSet(h?.infectionRisk)
        maternityStayEventsSet = csvToSet(h?.maternityStayEvents)
        maternityVaccinationsSet = csvToSet(h?.maternityVaccinations)
        motherVaccinationsSet = csvToSet(h?.motherVaccinations)
        familyVaccinationsSet = csvToSet(h?.familyVaccinations)

        // Keep the display strings consistent with sets
        pregnancyRisk = setToCSV(pregnancyRiskSet)
        infectionRisk = setToCSV(infectionRiskSet)
        maternityStayEvents = setToCSV(maternityStayEventsSet)
        maternityVaccinations = setToCSV(maternityVaccinationsSet)
        motherVaccinations = setToCSV(motherVaccinationsSet)
        familyVaccinations = setToCSV(familyVaccinationsSet)

        currentPatientID = app.selectedPatientID
        originalHistory = app.perinatalHistory
        coerceSelectionsToValid()
    }

    private func save() {
        guard let pid = app.selectedPatientID else {
            saveError = "No active patient selected."
            return
        }

        saving = true
        defer { saving = false }

        // Mirror menu selections into CSV strings for a consistent UI
        pregnancyRisk = setToCSV(pregnancyRiskSet)
        infectionRisk = setToCSV(infectionRiskSet)
        maternityStayEvents = setToCSV(maternityStayEventsSet)
        maternityVaccinations = setToCSV(maternityVaccinationsSet)
        motherVaccinations = setToCSV(motherVaccinationsSet)
        familyVaccinations = setToCSV(familyVaccinationsSet)

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
        h.pregnancyRisk = emptyToNil(setToCSV(pregnancyRiskSet))
        h.birthMode = emptyToNil(birthMode)
        h.birthTermWeeks = Int(birthTermWeeks)
        h.resuscitation = emptyToNil(resuscitation)
        h.nicuStay = nicuStay
        h.infectionRisk = emptyToNil(setToCSV(infectionRiskSet))
        h.birthWeightG = Int(birthWeightG)
        h.birthLengthCm = parseDouble(birthLengthCm)
        h.birthHeadCircumferenceCm = parseDouble(birthHeadCircumferenceCm)
        h.maternityStayEvents = emptyToNil(setToCSV(maternityStayEventsSet))
        h.maternityVaccinations = emptyToNil(setToCSV(maternityVaccinationsSet))
        h.vitaminK = vitaminK
        h.feedingInMaternity = emptyToNil(feedingInMaternity)
        h.passedMeconium24h = passedMeconium24h
        h.urination24h = urination24h
        h.heartScreening = emptyToNil(heartScreening)
        h.metabolicScreening = emptyToNil(metabolicScreening)
        h.hearingScreening = emptyToNil(hearingScreening)
        h.motherVaccinations = emptyToNil(setToCSV(motherVaccinationsSet))
        h.familyVaccinations = emptyToNil(setToCSV(familyVaccinationsSet))
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

    private func onDone() {
        // Save synchronously if there are edits, then dismiss the sheet.
        if isDirty {
            save()
        }
        dismiss()
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

    // MARK: - Choice helpers

    private func csvToSet(_ s: String?) -> Set<String> {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return Set(
            s.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private func setToCSV(_ set: Set<String>) -> String {
        set.sorted().joined(separator: ", ")
    }

    @ViewBuilder
    private func multiSelectMenu(title: String, options: [String], selection: Binding<Set<String>>) -> some View {
        Menu {
            ForEach(options, id: \.self) { opt in
                Button {
                    if selection.wrappedValue.contains(opt) {
                        selection.wrappedValue.remove(opt)
                    } else {
                        selection.wrappedValue.insert(opt)
                    }
                } label: {
                    if selection.wrappedValue.contains(opt) {
                        Label(opt, systemImage: "checkmark")
                    } else {
                        Text(opt)
                    }
                }
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text({
                    let csv = setToCSV(selection.wrappedValue)
                    return csv.isEmpty ? "—" : csv
                }())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
        }
    }

    // MARK: - Columns

    @ViewBuilder
    private var columnLeft: some View {
        Section(header: Text("Birth & Pregnancy")) {
            // Multi-select pregnancy issues
            multiSelectMenu(title: "Pregnancy issues",
                            options: Self.CH_PREGNANCY,
                            selection: $pregnancyRiskSet)

            // Single-choice pickers
            Picker("Birth mode", selection: $birthMode) {
                Text("— Select —").tag("")
                ForEach(Self.CH_BIRTH_MODE, id: \.self) { Text($0) }
            }.pickerStyle(.menu)

            TextField("Gestational age (weeks)", text: $birthTermWeeks)

            Picker("Resuscitation at birth", selection: $resuscitation) {
                Text("— Select —").tag("")
                ForEach(Self.CH_RESUSC, id: \.self) { Text($0) }
            }.pickerStyle(.menu)

            Toggle("NICU stay", isOn: $nicuStay)

            // Infection risk multi-select
            multiSelectMenu(title: "Infection risk factors",
                            options: Self.CH_INF_RISK,
                            selection: $infectionRiskSet)
        }
        Section(header: Text("Measurements at Birth")) {
            TextField("Birth weight (g)", text: $birthWeightG)
            TextField("Birth length (cm)", text: $birthLengthCm)
            TextField("Head circumference (cm)", text: $birthHeadCircumferenceCm)
            TextField("Discharge weight (g)", text: $dischargeWeightG)
        }
    }

    @ViewBuilder
    private var columnRight: some View {
        Section(header: Text("Maternity Stay")) {
            multiSelectMenu(title: "Events",
                            options: Self.CH_MAT_STAY_EVENTS,
                            selection: $maternityStayEventsSet)

            multiSelectMenu(title: "Vaccinations in maternity",
                            options: Self.CH_VACCINATIONS_MAT,
                            selection: $maternityVaccinationsSet)

            Toggle("Vitamin K given", isOn: $vitaminK)

            Picker("Feeding in maternity", selection: $feedingInMaternity) {
                Text("— Select —").tag("")
                ForEach(Self.CH_FEEDING, id: \.self) { Text($0) }
            }.pickerStyle(.menu)

            Toggle("Passed meconium in 24h", isOn: $passedMeconium24h)
            Toggle("Urination in 24h", isOn: $urination24h)

            TextField("Discharge date (YYYY-MM-DD)", text: $maternityDischargeDate)
            TextField("Discharge weight (g)", text: $dischargeWeightG)
        }
        Section(header: Text("Screenings")) {
            Picker("Heart screening", selection: $heartScreening) {
                Text("— Select —").tag("")
                ForEach(Self.CH_HEART, id: \.self) { Text($0) }
            }.pickerStyle(.menu)

            Picker("Metabolic screening", selection: $metabolicScreening) {
                Text("— Select —").tag("")
                ForEach(Self.CH_METAB, id: \.self) { Text($0) }
            }.pickerStyle(.menu)

            Picker("Hearing screening", selection: $hearingScreening) {
                Text("— Select —").tag("")
                ForEach(Self.CH_HEARING, id: \.self) { Text($0) }
            }.pickerStyle(.menu)
        }
        Section(header: Text("Family & Aftercare")) {
            multiSelectMenu(title: "Mother vaccinations",
                            options: Self.CH_MOTHER_VAX,
                            selection: $motherVaccinationsSet)
            multiSelectMenu(title: "Family vaccinations",
                            options: Self.CH_FAMILY_VAX,
                            selection: $familyVaccinationsSet)
            TextField("Illnesses after birth", text: $illnessesAfterBirth)
            TextField("Evolution since maternity", text: $evolutionSinceMaternity)
        }
    }

    // MARK: - Helpers

    private func coerceSelectionsToValid() {
        // Clamp single-choice pickers to valid vocab (fallback to first option)
        if !Self.CH_BIRTH_MODE.contains(birthMode) {
            birthMode = Self.CH_BIRTH_MODE.first ?? ""
        }
        if !Self.CH_RESUSC.contains(resuscitation) {
            resuscitation = Self.CH_RESUSC.first ?? ""
        }
        if !Self.CH_HEART.contains(heartScreening) {
            heartScreening = Self.CH_HEART.first ?? ""
        }
        if !Self.CH_METAB.contains(metabolicScreening) {
            metabolicScreening = Self.CH_METAB.first ?? ""
        }
        if !Self.CH_HEARING.contains(hearingScreening) {
            hearingScreening = Self.CH_HEARING.first ?? ""
        }
        if !Self.CH_FEEDING.contains(feedingInMaternity) {
            feedingInMaternity = Self.CH_FEEDING.first ?? ""
        }

        // Clamp multi-select sets to allowed vocabularies
        pregnancyRiskSet = pregnancyRiskSet.intersection(Set(Self.CH_PREGNANCY))
        infectionRiskSet = infectionRiskSet.intersection(Set(Self.CH_INF_RISK))
        maternityStayEventsSet = maternityStayEventsSet.intersection(Set(Self.CH_MAT_STAY_EVENTS))
        maternityVaccinationsSet = maternityVaccinationsSet.intersection(Set(Self.CH_VACCINATIONS_MAT))
        motherVaccinationsSet = motherVaccinationsSet.intersection(Set(Self.CH_MOTHER_VAX))
        familyVaccinationsSet = familyVaccinationsSet.intersection(Set(Self.CH_FAMILY_VAX))
    }

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
