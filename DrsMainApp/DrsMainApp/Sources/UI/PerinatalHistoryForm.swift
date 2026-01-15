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
    @State private var showDischargeDatePicker = false
    @State private var dischargeDateTemp = Date()
    @State private var dischargeWeightG = ""
    @State private var illnessesAfterBirth = ""
    @State private var evolutionSinceMaternity = ""
    @State private var currentPatientID: Int?
    @State private var originalHistory: PerinatalHistory?

    @State private var saving = false
    @State private var saveError: String?
    @State private var showSavedToast = false

    // MARK: - Standardized choice sets (mirrors Python app)
    static let CH_PREGNANCY: [String] = [
        String(localized: "perinatal.choice.pregnancy.normal"),
        String(localized: "perinatal.choice.pregnancy.gestational_diabetes"),
        String(localized: "perinatal.choice.pregnancy.preeclampsia"),
        String(localized: "perinatal.choice.pregnancy.infection"),
        String(localized: "perinatal.choice.pregnancy.threat_premature_birth"),
        String(localized: "perinatal.choice.pregnancy.iugr")
    ]

    static let CH_BIRTH_MODE: [String] = [
        String(localized: "perinatal.choice.birth_mode.normal_vaginal"),
        String(localized: "perinatal.choice.birth_mode.emergent_cs"),
        String(localized: "perinatal.choice.birth_mode.planned_cs"),
        String(localized: "perinatal.choice.birth_mode.instrumental_unspecified"),
        String(localized: "perinatal.choice.birth_mode.vacuum"),
        String(localized: "perinatal.choice.birth_mode.forceps")
    ]

    static let CH_RESUSC: [String] = [
        String(localized: "perinatal.choice.resusc.none"),
        String(localized: "perinatal.choice.resusc.free_oxygen"),
        String(localized: "perinatal.choice.resusc.bag_mask"),
        String(localized: "perinatal.choice.resusc.chest_compression"),
        String(localized: "perinatal.choice.resusc.fluids_drugs")
    ]

    static let CH_INF_RISK: [String] = [
        String(localized: "perinatal.choice.infrisk.prom"),
        String(localized: "perinatal.choice.infrisk.seroconversion_torch"),
        String(localized: "perinatal.choice.infrisk.gbs_no_treatment"),
        String(localized: "perinatal.choice.infrisk.gbs_treatment")
    ]

    static let CH_MAT_STAY_EVENTS: [String] = [
        String(localized: "perinatal.choice.maternity_event.none"),
        String(localized: "perinatal.choice.maternity_event.weight_loss_10"),
        String(localized: "perinatal.choice.maternity_event.hyperbili_with_pt"),
        String(localized: "perinatal.choice.maternity_event.hyperbili_without_pt"),
        String(localized: "perinatal.choice.maternity_event.hypoglycemia"),
        String(localized: "perinatal.choice.maternity_event.suspicion_infection")
    ]

    static let CH_VACCINATIONS_MAT: [String] = [
        String(localized: "perinatal.choice.maternity_vax.bcg"),
        String(localized: "perinatal.choice.maternity_vax.hepb"),
        String(localized: "perinatal.choice.maternity_vax.rsv"),
        String(localized: "perinatal.choice.maternity_vax.anti_hbv_ig")
    ]

    static let CH_MOTHER_VAX: [String] = [
        String(localized: "perinatal.choice.mother_vax.none"),
        String(localized: "perinatal.choice.mother_vax.dtap"),
        String(localized: "perinatal.choice.mother_vax.flu"),
        String(localized: "perinatal.choice.mother_vax.covid"),
        String(localized: "perinatal.choice.mother_vax.rsv")
    ]

    static let CH_FAMILY_VAX: [String] = [
        String(localized: "perinatal.choice.family_vax.none"),
        String(localized: "perinatal.choice.family_vax.dtap"),
        String(localized: "perinatal.choice.family_vax.flu"),
        String(localized: "perinatal.choice.family_vax.covid"),
        String(localized: "perinatal.choice.family_vax.rsv")
    ]

    static let CH_HEART: [String] = [
        String(localized: "perinatal.choice.heart.normal"),
        String(localized: "perinatal.choice.heart.abnormal"),
        String(localized: "perinatal.choice.heart.not_done")
    ]

    static let CH_METAB: [String] = [
        String(localized: "perinatal.choice.metab.done_pending"),
        String(localized: "perinatal.choice.metab.normal"),
        String(localized: "perinatal.choice.metab.abnormal")
    ]

    static let CH_HEARING: [String] = [
        String(localized: "perinatal.choice.hearing.normal"),
        String(localized: "perinatal.choice.hearing.abnormal"),
        String(localized: "perinatal.choice.hearing.abnormal_right"),
        String(localized: "perinatal.choice.hearing.abnormal_left"),
        String(localized: "perinatal.choice.hearing.not_done")
    ]

    static let CH_FEEDING: [String] = [
        String(localized: "perinatal.choice.feeding.ebf"),
        String(localized: "perinatal.choice.feeding.mixed"),
        String(localized: "perinatal.choice.feeding.exclusive_formula")
    ]

    // Working state for multi-select fields (CSV-backed)
    @State private var pregnancyRiskSet: Set<String> = []
    @State private var infectionRiskSet: Set<String> = []
    @State private var maternityStayEventsSet: Set<String> = []
    @State private var maternityVaccinationsSet: Set<String> = []
    @State private var motherVaccinationsSet: Set<String> = []
    @State private var familyVaccinationsSet: Set<String> = []

    // Keep the UI container separate so we can wrap it in a NavigationStack on macOS.
    private var formContent: some View {
        HStack {
            Spacer(minLength: 0)

            VStack(spacing: 0) {
                ScrollView {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 16) {
                                columnLeft
                            }
                            VStack(alignment: .leading, spacing: 16) {
                                columnRight
                            }
                        }

                        // Fallback to single column on narrow widths
                        VStack(alignment: .leading, spacing: 16) {
                            columnLeft
                            columnRight
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .frame(minWidth: 900, idealWidth: 1050, maxWidth: 1400, minHeight: 560, alignment: .top)

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
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
        .navigationTitle(String(localized: "perinatal.form.nav.title"))
        .interactiveDismissDisabled(false)
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                Button {
                    save()
                } label: {
                    if saving {
                        ProgressView()
                    } else {
                        Text(String(localized: "generic.button.save"))
                    }
                }
                .disabled(saving)
            }
            ToolbarItemGroup(placement: .cancellationAction) {
                Button(String(localized: "generic.button.done")) { onDone() }
                Button(String(localized: "generic.button.reset")) { loadFromAppState() }
            }
        }
        .alert(
            String(localized: "perinatal.alert.save_failed.title"),
            isPresented: Binding(get: { saveError != nil },
                                 set: { if !$0 { saveError = nil } }),
            actions: {
                Button(String(localized: "generic.button.ok")) { saveError = nil }
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

    var body: some View {
        Group {
#if os(macOS)
            // Ensure a proper title bar + toolbar area on macOS sheets/windows.
            NavigationStack {
                formContent
            }
            // Give the sheet enough room so the navigation title/toolbar aren’t clipped.
            .frame(minWidth: 980, idealWidth: 1150, maxWidth: 1500,
                   minHeight: 680, idealHeight: 860, maxHeight: 1100,
                   alignment: .top)
            .presentationSizing(.fitted)
#else
            NavigationView {
                formContent
            }
#endif
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
        if let d = parseISODate(maternityDischargeDate) {
            dischargeDateTemp = d
        }
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
            saveError = String(localized: "perinatal.error.no_active_patient")
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
            saveError = String(localized: "perinatal.error.save_failed.app")
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
            Text(String(localized: "generic.toast.saved"))
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
                let csv = setToCSV(selection.wrappedValue)
                Text(csv.isEmpty ? String(localized: "generic.placeholder.none") : csv)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    @ViewBuilder
    private func unitTextField(_ label: String, text: Binding<String>, unit: String) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)

                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, alignment: .leading)
            }
        } label: {
            Text(label)
        }
    }

    // MARK: - Columns

    @ViewBuilder
    private var columnLeft: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                // Multi-select pregnancy issues
                multiSelectMenu(
                    title: String(localized: "perinatal.field.pregnancy_issues"),
                    options: Self.CH_PREGNANCY,
                    selection: $pregnancyRiskSet
                )

                // Single-choice pickers
                Picker(String(localized: "perinatal.field.birth_mode"), selection: $birthMode) {
                    Text(String(localized: "generic.menu.select.placeholder")).tag("")
                    ForEach(Self.CH_BIRTH_MODE, id: \.self) { Text($0) }
                }
                .pickerStyle(.menu)

                let termLU = labelAndUnitFromFormatKey("appstate.profile.perinatal.term_weeks_format")
                unitTextField(termLU.label.isEmpty ? String(localized: "perinatal.field.gestational_age_weeks") : termLU.label,
                              text: $birthTermWeeks,
                              unit: termLU.unit.isEmpty ? "w" : termLU.unit)
#if os(iOS)
                    .keyboardType(.numberPad)
#endif

                Picker(String(localized: "perinatal.field.resuscitation_at_birth"), selection: $resuscitation) {
                    Text(String(localized: "generic.menu.select.placeholder")).tag("")
                    ForEach(Self.CH_RESUSC, id: \.self) { Text($0) }
                }
                .pickerStyle(.menu)

                Toggle(String(localized: "perinatal.field.nicu_stay"), isOn: $nicuStay)

                // Infection risk multi-select
                multiSelectMenu(
                    title: String(localized: "perinatal.field.infection_risk_factors"),
                    options: Self.CH_INF_RISK,
                    selection: $infectionRiskSet
                )
            }
            .padding(.top, 2)
        } label: {
            Text(String(localized: "perinatal.section.birth_pregnancy"))
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                unitTextField(
                    String(localized: "perinatal.field.birth_weight_g"),
                    text: $birthWeightG,
                    unit: "g"
                )

                unitTextField(
                    String(localized: "perinatal.field.birth_length_cm"),
                    text: $birthLengthCm,
                    unit: "cm"
                )

                unitTextField(
                    String(localized: "perinatal.field.head_circumference_cm"),
                    text: $birthHeadCircumferenceCm,
                    unit: "cm"
                )

                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("", text: $maternityDischargeDate)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            // Seed the picker with the current value if possible
                            if let d = parseISODate(maternityDischargeDate) {
                                dischargeDateTemp = d
                            }
                            showDischargeDatePicker.toggle()
                        } label: {
                            Image(systemName: "calendar")
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "generic.datepicker.pick_date"))
                        .popover(isPresented: $showDischargeDatePicker) {
                            VStack(alignment: .leading, spacing: 12) {
                                DatePicker(
                                    String(localized: "generic.datepicker.date"),
                                    selection: $dischargeDateTemp,
                                    displayedComponents: [.date]
                                )
                                .datePickerStyle(.graphical)

                                HStack {
                                    Button(String(localized: "generic.button.clear")) {
                                        maternityDischargeDate = ""
                                        showDischargeDatePicker = false
                                    }

                                    Spacer()

                                    Button(String(localized: "generic.button.done")) {
                                        maternityDischargeDate = formatISODate(dischargeDateTemp)
                                        showDischargeDatePicker = false
                                    }
                                    .keyboardShortcut(.defaultAction)
                                }
                            }
                            .padding(14)
                            .frame(minWidth: 320)
                        }
                    }
                } label: {
                    Text(
                        String(
                            format: NSLocalizedString("appstate.profile.perinatal.discharge_date_format", comment: ""),
                            ""
                        )
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }

                unitTextField(
                    String(localized: "perinatal.field.discharge_weight_g"),
                    text: $dischargeWeightG,
                    unit: "g"
                )
            }
            .padding(.top, 2)
        } label: {
            Text(String(localized: "perinatal.section.measurements_birth"))
        }
    }

    @ViewBuilder
    private var columnRight: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                multiSelectMenu(
                    title: String(localized: "perinatal.field.maternity_events"),
                    options: Self.CH_MAT_STAY_EVENTS,
                    selection: $maternityStayEventsSet
                )

                multiSelectMenu(
                    title: String(localized: "perinatal.field.vaccinations_maternity"),
                    options: Self.CH_VACCINATIONS_MAT,
                    selection: $maternityVaccinationsSet
                )

                Toggle(String(localized: "perinatal.field.vitamin_k_given"), isOn: $vitaminK)

                Picker(String(localized: "perinatal.field.feeding_maternity"), selection: $feedingInMaternity) {
                    Text(String(localized: "generic.menu.select.placeholder")).tag("")
                    ForEach(Self.CH_FEEDING, id: \.self) { Text($0) }
                }
                .pickerStyle(.menu)

                Toggle(String(localized: "perinatal.field.passed_meconium_24h"), isOn: $passedMeconium24h)
                Toggle(String(localized: "perinatal.field.urination_24h"), isOn: $urination24h)
            }
            .padding(.top, 2)
        } label: {
            Text(String(localized: "perinatal.section.maternity_stay"))
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker(String(localized: "perinatal.field.heart_screening"), selection: $heartScreening) {
                    Text(String(localized: "generic.menu.select.placeholder")).tag("")
                    ForEach(Self.CH_HEART, id: \.self) { Text($0) }
                }
                .pickerStyle(.menu)

                Picker(String(localized: "perinatal.field.metabolic_screening"), selection: $metabolicScreening) {
                    Text(String(localized: "generic.menu.select.placeholder")).tag("")
                    ForEach(Self.CH_METAB, id: \.self) { Text($0) }
                }
                .pickerStyle(.menu)

                Picker(String(localized: "perinatal.field.hearing_screening"), selection: $hearingScreening) {
                    Text(String(localized: "generic.menu.select.placeholder")).tag("")
                    ForEach(Self.CH_HEARING, id: \.self) { Text($0) }
                }
                .pickerStyle(.menu)
            }
            .padding(.top, 2)
        } label: {
            Text(String(localized: "perinatal.section.screenings"))
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                multiSelectMenu(
                    title: String(localized: "perinatal.field.mother_vaccinations"),
                    options: Self.CH_MOTHER_VAX,
                    selection: $motherVaccinationsSet
                )

                multiSelectMenu(
                    title: String(localized: "perinatal.field.family_vaccinations"),
                    options: Self.CH_FAMILY_VAX,
                    selection: $familyVaccinationsSet
                )

                LabeledContent {
                    TextField("", text: $illnessesAfterBirth)
                        .textFieldStyle(.roundedBorder)
                } label: {
                    Text(
                        String(
                            format: NSLocalizedString("appstate.profile.perinatal.illnesses_after_birth_format", comment: ""),
                            ""
                        )
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }

                LabeledContent {
                    TextField("", text: $evolutionSinceMaternity)
                        .textFieldStyle(.roundedBorder)
                } label: {
                    Text(
                        String(
                            format: NSLocalizedString("appstate.profile.perinatal.evolution_since_maternity_format", comment: ""),
                            ""
                        )
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            }
            .padding(.top, 2)
        } label: {
            Text(String(localized: "perinatal.section.family_aftercare"))
        }
    }

    // MARK: - Helpers

    /// Some legacy keys are *format* strings (e.g. "Term: %d weeks").
    /// In the form UI we only want a stable label + a trailing unit, without formatting.
    /// This avoids undefined behavior when the format expects an Int/Double.
    private func labelAndUnitFromFormatKey(_ key: String) -> (label: String, unit: String) {
        let raw = NSLocalizedString(key, comment: "")
        // Strip common printf-style placeholders like %@, %d, %ld, %.2f, etc.
        let pattern = "%[-+0-9\\.#]*l?[A-Za-z@]"
        let stripped: String = {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return raw }
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            return re.stringByReplacingMatches(in: raw, options: [], range: range, withTemplate: "")
        }()
        // Now split label vs unit using ':' if present (works for EN/FR "Label:  unit").
        let parts = stripped.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let label = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let unit = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return (label.isEmpty ? stripped.trimmingCharacters(in: .whitespacesAndNewlines) : label,
                    unit)
        }
        return (stripped.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

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

    private func parseISODate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: t)
    }

    private func formatISODate(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private func parseDouble(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let normalized = t.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }
}
