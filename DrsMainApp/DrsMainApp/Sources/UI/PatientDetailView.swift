//
//  PatientDetailView.swift
//  DrsMainApp
//
//  Created by yunastic on 10/27/25.
//
//



import SwiftUI
import OSLog
import AppKit
import UniformTypeIdentifiers


// Humanize visit categories (well-visit keys + a fallback)
fileprivate func prettyCategory(_ raw: String) -> String {
    let k = raw
        .lowercased()
        .replacingOccurrences(of: "-", with: "_")
        .replacingOccurrences(of: " ", with: "_")

    let map: [String: String] = [
        "one_month": NSLocalizedString(
            "patient.visit-category.one-month",
            comment: "Visit type label: 1‑month well visit"
        ),
        "two_month": NSLocalizedString(
            "patient.visit-category.two-month",
            comment: "Visit type label: 2‑month well visit"
        ),
        "four_month": NSLocalizedString(
            "patient.visit-category.four-month",
            comment: "Visit type label: 4‑month well visit"
        ),
        "six_month": NSLocalizedString(
            "patient.visit-category.six-month",
            comment: "Visit type label: 6‑month well visit"
        ),
        "nine_month": NSLocalizedString(
            "patient.visit-category.nine-month",
            comment: "Visit type label: 9‑month well visit"
        ),
        "twelve_month": NSLocalizedString(
            "patient.visit-category.twelve-month",
            comment: "Visit type label: 12‑month well visit"
        ),
        "fifteen_month": NSLocalizedString(
            "patient.visit-category.fifteen-month",
            comment: "Visit type label: 15‑month well visit"
        ),
        "eighteen_month": NSLocalizedString(
            "patient.visit-category.eighteen-month",
            comment: "Visit type label: 18‑month well visit"
        ),
        "twentyfour_month": NSLocalizedString(
            "patient.visit-category.twentyfour-month",
            comment: "Visit type label: 24‑month well visit"
        ),
        "thirty_month": NSLocalizedString(
            "patient.visit-category.thirty-month",
            comment: "Visit type label: 30‑month well visit"
        ),
        "thirtysix_month": NSLocalizedString(
            "patient.visit-category.thirtysix-month",
            comment: "Visit type label: 36‑month well visit"
        ),
        "four_year": NSLocalizedString(
            "patient.visit-category.four-year",
            comment: "Visit type label: 4‑year well visit"
        ),
        "five_year": NSLocalizedString(
            "patient.visit-category.five-year",
            comment: "Visit type label: 5‑year well visit"
        ),
        "newborn_first": NSLocalizedString(
            "patient.visit-category.newborn-first",
            comment: "Visit type label: first newborn visit after maternity"
        ),
        // Alias (if some data sources use a different key)
        "first_after_maternity": NSLocalizedString(
            "patient.visit-category.newborn-first",
            comment: "Visit type label: first newborn visit after maternity"
        ),
        "episode": NSLocalizedString(
            "patient.visit-category.sick",
            comment: "Visit type label: acute sick visit"
        )
    ]

    if let nice = map[k] { return nice }
    // fallback: “Fifteen_Month” → “Fifteen Month”
    return raw.replacingOccurrences(of: "_", with: " ").capitalized
}

// Segments for visit filtering
fileprivate enum VisitTab: String, CaseIterable, Identifiable {
    case all
    case sick
    case well

    var id: String { rawValue }

    private var labelKey: String {
        switch self {
        case .all:
            return "patient.visits.filter.all"
        case .sick:
            return "patient.visits.filter.sick"
        case .well:
            return "patient.visits.filter.well"
        }
    }

    var label: String {
        NSLocalizedString(
            labelKey,
            comment: "Segment title for visit filter in patient detail"
        )
    }
}

// Detect whether a visit category is a "well" milestone vs a sick episode
fileprivate func isWellCategory(_ raw: String) -> Bool {
    let k = raw
        .lowercased()
        .replacingOccurrences(of: "-", with: "_")
        .replacingOccurrences(of: " ", with: "_")

    let wellKeys: Set<String> = [
        "one_month","two_month","four_month","six_month","nine_month",
        "twelve_month","fifteen_month","eighteen_month","twentyfour_month",
        "twenty_four_month","thirty_month","thirtysix_month","thirty_six_month",
        "four_year","five_year",
        "newborn_first"
    ]
    if wellKeys.contains(k) { return true }
    // treat anything that's not explicit "episode" as well if it matches "month" pattern
    if k.contains("month") { return true }
    if k.contains("newborn") { return true }
    return false
}

fileprivate func isSickCategory(_ raw: String) -> Bool {
    let k = raw
        .lowercased()
        .replacingOccurrences(of: "-", with: "_")
        .replacingOccurrences(of: " ", with: "_")
    return k == "episode"
}

/// Right-pane details for a selected patient from the sidebar list.

struct PatientDetailView: View {

    // Logger for diagnosing view-driven refreshes / sheet lifecycle.
    private static let uiLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "DrsMainApp",
        category: "ui.patient_detail"
    )

    // Compact patient/bundle meta shown next to the patient name (moved up from the old Facts grid)
    @ViewBuilder
    private var patientHeaderMeta: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                Text("\(patient.id)")
            } label: {
                Text(
                    NSLocalizedString(
                        "patient.grid.patient-id.label",
                        comment: "Label for patient ID in patient details grid"
                    )
                )
                .foregroundStyle(.secondary)
            }

            LabeledContent {
                Text(dobFormatted)
            } label: {
                Text(
                    NSLocalizedString(
                        "patient.grid.dob.label",
                        comment: "Label for date of birth in patient details grid"
                    )
                )
                .foregroundStyle(.secondary)
            }

            LabeledContent {
                Text(patient.sex)
            } label: {
                Text(
                    NSLocalizedString(
                        "patient.grid.sex.label",
                        comment: "Label for sex in patient details grid"
                    )
                )
                .foregroundStyle(.secondary)
            }

            if let bundle = appState.currentBundleURL {
                LabeledContent {
                    Text(bundle.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(bundle.lastPathComponent)
                } label: {
                    Text(
                        NSLocalizedString(
                            "patient.grid.bundle.label",
                            comment: "Label for bundle filename in patient details grid"
                        )
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .frame(minWidth: 260, maxWidth: 520, alignment: .leading)
    }
    @EnvironmentObject var appState: AppState
    let patient: PatientRow   // ← match AppState.selectedPatient type
    @State private var visitForDetail: VisitRow? = nil
    @State private var visitTab: VisitTab = .all
    @State private var showDocuments = false
    @State private var showGrowth = false
    @State private var showVitals = false
    @State private var showGrowthCharts = false
    @State private var reportVisitKind: VisitKind?
    @State private var showPerinatalHistory = false
    @State private var perinatalPatientIDForSheet: Int? = nil
    @State private var showPMH = false
    @State private var pmhPatientIDForSheet: Int? = nil
    @State private var showVaccinationStatus = false
    @State private var vaxPatientIDForSheet: Int? = nil
    @State private var showEpisodeForm = false
    @State private var editingEpisodeID: Int? = nil
    @State private var episodePatientIDForSheet: Int? = nil
    @State private var episodeBundleTokenForSheet: String? = nil

    @State private var showWellVisitForm = false
    @State private var editingWellVisitID: Int? = nil
    @State private var wellVisitPatientIDForSheet: Int? = nil
    @State private var wellVisitBundleTokenForSheet: String? = nil

    // Formatters for visit and DOB rendering
    private static let isoFullDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    private static let isoDateTimeWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func visitDateFormatted(_ isoString: String) -> String {
        // Try full Internet date-time with fractional seconds first
        if let d = Self.isoDateTimeWithFractional.date(from: isoString) {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return df.string(from: d)
        }
        // Fallback: plain full-date (yyyy-MM-dd)
        if let d = Self.isoFullDate.date(from: isoString) {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            return df.string(from: d)
        }
        // Last resort: return the raw string
        return isoString
    }

    private func parseVisitDate(_ isoString: String) -> Date? {
        if let d = Self.isoDateTimeWithFractional.date(from: isoString) { return d }
        if let d = Self.isoFullDate.date(from: isoString) { return d }
        return nil
    }

    private func isWithin24Hours(_ isoString: String) -> Bool {
        guard let d = parseVisitDate(isoString) else { return false }
        return Date().timeIntervalSince(d) < 24 * 60 * 60
    }

    private var dobFormatted: String {
        // patient.dobISO is yyyy-MM-dd
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]
        if let d = iso.date(from: patient.dobISO) {
            let df = DateFormatter()
            df.dateStyle = .medium
            return df.string(from: d)
        }
        return patient.dobISO
    }

    // Newest-first sorted visits by ISO date string
    private var visitsSorted: [VisitRow] {
        // Sort newest-first by ISO date string (handles both full datetime and date-only)
        appState.visits.sorted { $0.dateISO > $1.dateISO }
    }

    private var filteredVisits: [VisitRow] {
        let base = visitsSorted
        switch visitTab {
        case .all:
            return base
        case .sick:
            return base.filter { isSickCategory($0.category) }
        case .well:
            return base.filter { isWellCategory($0.category) && !isSickCategory($0.category) }
        }
    }

    private var latestSickVisit: VisitRow? {
        appState.visits
            .filter { isSickCategory($0.category) }
            .max(by: { $0.dateISO < $1.dateISO })
    }

    private var latestWellVisit: VisitRow? {
        appState.visits
            .filter { isWellCategory($0.category) && !isSickCategory($0.category) }
            .max(by: { $0.dateISO < $1.dateISO })
    }
    // Break out header actions into multiple group cards laid out horizontally
    @ViewBuilder
    private func headerActionGroupsGrid() -> some View {
        // Adaptive grid: fills available width, wraps to new rows as needed
        let columns: [GridItem] = [
            GridItem(.adaptive(minimum: 240), spacing: 12, alignment: .top)
        ]

        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            // Clinical / profile editors
            headerActionGroupCard(
                titleKey: "patient.header.group.profile",
                systemImage: "person.text.rectangle"
            ) {
                Button {
                    perinatalPatientIDForSheet = patient.id
                    showPerinatalHistory = true
                } label: {
                    Label(
                        NSLocalizedString(
                            "patient.header.perinatal-history",
                            comment: "Patient header action: edit perinatal history"
                        ),
                        systemImage: "doc.text"
                    )
                }

                Button {
                    pmhPatientIDForSheet = patient.id
                    showPMH = true
                } label: {
                    Label(
                        NSLocalizedString(
                            "patient.header.pmh",
                            comment: "Patient header action: edit past medical history"
                        ),
                        systemImage: "book"
                    )
                }

                Button {
                    vaxPatientIDForSheet = patient.id
                    showVaccinationStatus = true
                } label: {
                    Label(
                        NSLocalizedString(
                            "patient.header.vaccination-status",
                            comment: "Patient header action: edit vaccination status"
                        ),
                        systemImage: "syringe"
                    )
                }
            }

            // Measurements / tables
            headerActionGroupCard(
                titleKey: "patient.header.group.measurements",
                systemImage: "waveform.path.ecg"
            ) {
                Button {
                    showVitals.toggle()
                } label: {
                    Label(
                        NSLocalizedString(
                            "patient.header.vitals",
                            comment: "Patient header action: open vitals table"
                        ),
                        systemImage: "waveform.path.ecg"
                    )
                }

                Button {
                    showGrowth.toggle()
                } label: {
                    Label(
                        NSLocalizedString(
                            "patient.header.growth",
                            comment: "Patient header action: open growth table"
                        ),
                        systemImage: "chart.xyaxis.line"
                    )
                }

                Button {
                    showGrowthCharts.toggle()
                } label: {
                    Label(
                        NSLocalizedString(
                            "patient.header.growth-charts",
                            comment: "Patient header action: open growth charts"
                        ),
                        systemImage: "chart.bar.xaxis"
                    )
                }
            }

            // Documents / export
            headerActionGroupCard(
                titleKey: "patient.header.group.documents",
                systemImage: "doc.on.clipboard"
            ) {
                Button {
                    showDocuments.toggle()
                } label: {
                    Label(
                        NSLocalizedString(
                            "patient.header.documents",
                            comment: "Patient header action: open documents list"
                        ),
                        systemImage: "doc.on.clipboard"
                    )
                }

                Button {
                    Task { await MacBundleExporter.run(appState: appState) }
                } label: {
                    Label(
                        NSLocalizedString(
                            "patient.header.export-bundle",
                            comment: "Patient header action: export peMR bundle"
                        ),
                        systemImage: "square.and.arrow.up"
                    )
                }
            }

            // New items + report
            headerActionGroupCard(
                titleKey: "patient.header.group.new_items",
                systemImage: "plus.circle"
            ) {
                Button {
                    wellVisitPatientIDForSheet = patient.id
                    wellVisitBundleTokenForSheet = appState.currentBundleURL?.path
                    editingWellVisitID = nil
                    showWellVisitForm = true
                    visitForDetail = nil
                } label: {
                    Label(
                        NSLocalizedString(
                            "patient.header.new-well-visit",
                            comment: "Patient header action: create new well visit"
                        ),
                        systemImage: "checkmark.seal"
                    )
                }

                Button {
                    episodePatientIDForSheet = patient.id
                    episodeBundleTokenForSheet = appState.currentBundleURL?.path
                    editingEpisodeID = nil
                    showEpisodeForm = true
                    visitForDetail = nil
                } label: {
                    Label(
                        NSLocalizedString(
                            "patient.header.new-sick-episode",
                            comment: "Patient header action: create new sick episode"
                        ),
                        systemImage: "stethoscope"
                    )
                }

                reportMenu()
            }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func headerActionGroupCard<Content: View>(
        titleKey: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(
                    NSLocalizedString(
                        titleKey,
                        comment: "Patient header group title"
                    )
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                content()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    @ViewBuilder
    private func reportMenu() -> some View {
        // Precompute to avoid heavy expressions inside the ViewBuilder
        let sick = latestSickVisit
        let well = latestWellVisit

        Menu {
            if let v = sick {
                Button(
                    String(
                        format: NSLocalizedString(
                            "patient.report.latest-sick-title",
                            comment: "Menu item: Latest sick visit, placeholder is visit date"
                        ),
                        visitDateFormatted(v.dateISO)
                    )
                ) {
                    visitForDetail = v
                    reportVisitKind = .sick(episodeID: v.id)
                }
            } else {
                Text(
                    NSLocalizedString(
                        "patient.report.no-sick-visits",
                        comment: "Menu placeholder when no sick visits exist"
                    )
                )
                .foregroundStyle(.secondary)
            }

            if let v = well {
                Button(
                    String(
                        format: NSLocalizedString(
                            "patient.report.latest-well-title",
                            comment: "Menu item: Latest well visit, placeholders are category then date"
                        ),
                        prettyCategory(v.category),
                        visitDateFormatted(v.dateISO)
                    )
                ) {
                    visitForDetail = v
                    reportVisitKind = .well(visitID: v.id)
                }
            } else {
                Text(
                    NSLocalizedString(
                        "patient.report.no-well-visits",
                        comment: "Menu placeholder when no well visits exist"
                    )
                )
                .foregroundStyle(.secondary)
            }
        } label: {
            Label(
                NSLocalizedString(
                    "patient.report.menu-title",
                    comment: "Toolbar menu title for visit reports"
                ),
                systemImage: "doc.plaintext"
            )
        }
    }

    @ViewBuilder
    private var patientSummarySection: some View {
        if let profile = appState.currentPatientProfile,
           (profile.perinatalHistory?.isEmpty == false ||
            profile.pmh?.isEmpty == false ||
            profile.vaccinationStatus?.isEmpty == false ||
            profile.parentNotes?.isEmpty == false) {

            VStack(alignment: .leading, spacing: 8) {
                Text(
                    NSLocalizedString(
                        "patient.summary.title",
                        comment: "Section title for patient profile summary card"
                    )
                )
                .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    if let s = profile.perinatalHistory, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        LabeledContent {
                            Text(s)
                        } label: {
                            Text(
                                NSLocalizedString(
                                    "patient.summary.perinatal.label",
                                    comment: "Label for perinatal history in patient summary card"
                                )
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                    if let pmh = profile.pmh, !pmh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        LabeledContent {
                            Text(pmh)
                        } label: {
                            Text(
                                NSLocalizedString(
                                    "patient.summary.pmh.label",
                                    comment: "Label for past medical history in patient summary card"
                                )
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                    if let notes = profile.parentNotes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        LabeledContent {
                            Text(notes)
                        } label: {
                            Text(
                                NSLocalizedString(
                                    "patient.summary.parent-notes.label",
                                    comment: "Label for parent notes in patient summary card"
                                )
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                    if let v = profile.vaccinationStatus, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        LabeledContent {
                            Text(v)
                        } label: {
                            Text(
                                NSLocalizedString(
                                    "patient.summary.vaccination.label",
                                    comment: "Label for vaccination status in patient summary card"
                                )
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Lightweight logging & handlers (keeps SwiftUI body type-checking fast)

    private func debugLog(_ message: String) {
        // Keep logging simple to avoid heavy string interpolation in ViewBuilder closures.
        Self.uiLog.debug("\(message, privacy: .public)")
    }

    private func handleOnAppear() {
        // Keep AppState selection in sync with the current detail view.
        // IMPORTANT: Do not trigger DB loads from the View; AppState.selectedPatientID didSet handles that.
        if appState.selectedPatientID != patient.id {
            appState.selectedPatientID = patient.id
        }
    }

    private func handleSelectedPatientIDChange(_ newID: Int?) {
        guard let id = newID else { return }

        debugLog("PatientDetailView: selectedPatientID changed -> \(id)")
        debugLog("Sheets open? peri=\(showPerinatalHistory) pmh=\(showPMH) vax=\(showVaccinationStatus) well=\(showWellVisitForm) episode=\(showEpisodeForm)")

        // Only close sheets if they were opened for a different patient than the newly selected one
        if showPerinatalHistory, let openID = perinatalPatientIDForSheet, openID != id {
            showPerinatalHistory = false
        }
        if showPMH, let openID = pmhPatientIDForSheet, openID != id {
            showPMH = false
        }
        if showVaccinationStatus, let openID = vaxPatientIDForSheet, openID != id {
            showVaccinationStatus = false
        }

        if showEpisodeForm {
            debugLog("PatientDetailView: dismissing SickEpisodeForm (patient context change)")
            // Clear the sheet context BEFORE dismissing so onDismiss can detect a programmatic dismissal.
            episodePatientIDForSheet = nil
            editingEpisodeID = nil
            episodeBundleTokenForSheet = nil
            showEpisodeForm = false
        }
        if showWellVisitForm {
            debugLog("PatientDetailView: dismissing WellVisitForm (patient context change)")
            // Clear the sheet context BEFORE dismissing so onDismiss can detect a programmatic dismissal.
            wellVisitPatientIDForSheet = nil
            editingWellVisitID = nil
            wellVisitBundleTokenForSheet = nil
            showWellVisitForm = false
        }

        // Also dismiss any open visit-detail sheet when switching patient context.
        if visitForDetail != nil {
            visitForDetail = nil
            reportVisitKind = nil
        }

        debugLog(
            "PatientDetailView: after cleanup openIDs: peri=\(String(describing: perinatalPatientIDForSheet)) " +
            "pmh=\(String(describing: pmhPatientIDForSheet)) vax=\(String(describing: vaxPatientIDForSheet)) " +
            "well=\(String(describing: wellVisitPatientIDForSheet)) episode=\(String(describing: episodePatientIDForSheet))"
        )
        // No DB loads here: AppState.selectedPatientID didSet is the single source of truth.
    }

    private func handleOnDisappear() {
        // If this view is being replaced (e.g., bundle switch) while a sheet is open,
        // clear the sheet context first so onDismiss can detect it and skip reloads.
        if showWellVisitForm {
            wellVisitPatientIDForSheet = nil
            wellVisitBundleTokenForSheet = nil
            editingWellVisitID = nil
            showWellVisitForm = false
        }
        if showEpisodeForm {
            episodePatientIDForSheet = nil
            episodeBundleTokenForSheet = nil
            editingEpisodeID = nil
            showEpisodeForm = false
        }
        if showPerinatalHistory {
            perinatalPatientIDForSheet = nil
            showPerinatalHistory = false
        }
        if showPMH {
            pmhPatientIDForSheet = nil
            showPMH = false
        }
        if showVaccinationStatus {
            vaxPatientIDForSheet = nil
            showVaccinationStatus = false
        }
    }

    private func onDismissPerinatalSheet() {
        let openID = perinatalPatientIDForSheet
        showPerinatalHistory = false
        perinatalPatientIDForSheet = nil
        debugLog("onDismiss Perinatal: openID=\(String(describing: openID)) selected=\(String(describing: appState.selectedPatientID))")
        if let openID, let selected = appState.selectedPatientID, openID == selected {
            appState.loadPatientProfile(for: Int64(openID))
        }
    }

    private func onDismissPmhSheet() {
        let openID = pmhPatientIDForSheet
        showPMH = false
        pmhPatientIDForSheet = nil
        debugLog("onDismiss PMH: openID=\(String(describing: openID)) selected=\(String(describing: appState.selectedPatientID))")
        if let openID, let selected = appState.selectedPatientID, openID == selected {
            appState.loadPatientProfile(for: Int64(openID))
        }
    }

    private func onDismissVaxSheet() {
        let openID = vaxPatientIDForSheet
        showVaccinationStatus = false
        vaxPatientIDForSheet = nil
        debugLog("onDismiss Vax: openID=\(String(describing: openID)) selected=\(String(describing: appState.selectedPatientID))")
        if let openID, let selected = appState.selectedPatientID, openID == selected {
            appState.loadPatientProfile(for: Int64(openID))
        }
    }

    private func onDismissWellVisitSheet() {
        let openID = wellVisitPatientIDForSheet
        let openToken = wellVisitBundleTokenForSheet
        wellVisitPatientIDForSheet = nil
        wellVisitBundleTokenForSheet = nil

        let selected = appState.selectedPatientID
        let currentToken = appState.currentBundleURL?.path
        debugLog("onDismiss WellVisitForm: openID=\(String(describing: openID)) selected=\(String(describing: selected))")
        debugLog("onDismiss WellVisitForm: openToken=\(String(describing: openToken)) currentToken=\(String(describing: currentToken))")

        if let openID,
           let selected,
           openID == selected,
           let openToken,
           openToken == currentToken {
            appState.loadVisits(for: selected)
            visitTab = .all
        }
    }

    private func onDismissEpisodeSheet() {
        let openID = episodePatientIDForSheet
        let openToken = episodeBundleTokenForSheet
        episodePatientIDForSheet = nil
        episodeBundleTokenForSheet = nil

        let selected = appState.selectedPatientID
        let currentToken = appState.currentBundleURL?.path
        debugLog("onDismiss SickEpisodeForm: openID=\(String(describing: openID)) selected=\(String(describing: selected))")
        debugLog("onDismiss SickEpisodeForm: openToken=\(String(describing: openToken)) currentToken=\(String(describing: currentToken))")

        if let openID,
           let selected,
           openID == selected,
           let openToken,
           openToken == currentToken {
            appState.loadVisits(for: selected)
            visitTab = .all
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 40))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                patient.fullName.isEmpty
                                ? NSLocalizedString(
                                    "patient.header.anon",
                                    comment: "Patient header title when full name is not available"
                                  )
                                : patient.fullName
                            )
                            .font(.title2.bold())

                            Text(patient.alias)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        patientHeaderMeta
                    }

                    // Action groups laid out horizontally under the patient name
                    headerActionGroupsGrid()
                }

                // --- Patient Summary card (perinatal / PMH / vaccination) ---
                patientSummarySection
                

                Divider()

                // Visits section
                HStack {
                    Text(
                        NSLocalizedString(
                            "patient.visits.title",
                            comment: "Section title for visits list in patient detail"
                        )
                    )
                    .font(.headline)
                    Spacer()
                    Picker(
                        NSLocalizedString(
                            "patient.visits.filter.label",
                            comment: "Accessibility label for visit filter segmented control"
                        ),
                        selection: $visitTab
                    ) {
                        ForEach(VisitTab.allCases) { tab in
                            Text(tab.label).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }

                let list = filteredVisits
                if list.isEmpty {
                    Text(
                        String(
                            format: NSLocalizedString(
                                "patient.visits.empty-filtered",
                                comment: "Shown when no visits match current filter; placeholder is filter label"
                            ),
                            visitTab.label
                        )
                    )
                    .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(list, id: \.stableID) { v in
                            visitRow(v)
                        }
                    }
                }
            }
            .padding(20)
        }
        .id(patient.id)
        .onAppear {
            handleOnAppear()
        }
        .onChange(of: appState.selectedPatientID) { _, newID in
            handleSelectedPatientIDChange(newID)
        }
        .onDisappear {
            handleOnDisappear()
        }
        .onChange(of: showEpisodeForm) { _, open in
            // When the sheet closes, forget the editing target to avoid stale state on the next open
            if !open {
                editingEpisodeID = nil
            }
        }
        .onChange(of: showWellVisitForm) { _, open in
            if !open {
                editingWellVisitID = nil
            }
        }
        .sheet(isPresented: $showDocuments) {
            DocumentListView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showGrowth) {
            GrowthTableView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showGrowthCharts) {
            GrowthChartView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showVitals) {
            VitalsTableView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showPerinatalHistory, onDismiss: {
            onDismissPerinatalSheet()
        }) {
            PerinatalHistoryForm()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showPMH, onDismiss: {
            onDismissPmhSheet()
        }) {
            PmhForm()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showVaccinationStatus, onDismiss: {
            onDismissVaxSheet()
        }) {
            VaccinationStatusForm()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showWellVisitForm, onDismiss: {
            onDismissWellVisitSheet()
        }) {
            WellVisitForm(editingVisitID: editingWellVisitID)
                .id(editingWellVisitID ?? -1)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showEpisodeForm, onDismiss: {
            onDismissEpisodeSheet()
        }) {
            SickEpisodeForm(editingEpisodeID: editingEpisodeID)
                .id(editingEpisodeID ?? -1)
                .environmentObject(appState)
        }
        .sheet(item: $visitForDetail) { v in
            NavigationStack {
                VisitDetailView(visit: v)
                    .navigationTitle("Visit")
            }
        }
    }

    // MARK: - Visit row helper (kept inside struct so it can access state/methods)
    @ViewBuilder
    private func visitRow(_ v: VisitRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isSickCategory(v.category) ? "stethoscope" : "checkmark.seal")
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 2) {
                Text(visitDateFormatted(v.dateISO))
                    .font(.body)
                Text(prettyCategory(v.category))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(
                NSLocalizedString(
                    "patient.visit-row.details-button",
                    comment: "Button to open visit details sheet"
                )
            ) {
                let kind: VisitKind
                if isSickCategory(v.category) {
                    kind = .sick(episodeID: v.id)
                } else {
                    kind = .well(visitID: v.id)
                }
                visitForDetail = v
                reportVisitKind = kind
            }
            .buttonStyle(.bordered)

            if isSickCategory(v.category) {
                // Sick episode editing (no time restriction)
                Button(
                    NSLocalizedString(
                        "patient.visit-row.edit-button",
                        comment: "Button to edit a visit from patient details"
                    )
                ) {
                    episodePatientIDForSheet = patient.id
                    episodeBundleTokenForSheet = appState.currentBundleURL?.path
                    editingEpisodeID = v.id
                    showEpisodeForm = true
                }
                .buttonStyle(.bordered)
            } else if isWellCategory(v.category) {
                // Well-visit editing – no time restriction for now
                Button(
                    NSLocalizedString(
                        "patient.visit-row.edit-button",
                        comment: "Button to edit a visit from patient details"
                    )
                ) {
                    wellVisitPatientIDForSheet = patient.id
                    wellVisitBundleTokenForSheet = appState.currentBundleURL?.path
                    editingWellVisitID = v.id
                    showWellVisitForm = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// Compact bubble-styled selectable text to keep body simpler for the compiler
private struct BubbleText: View {
    let text: String
    var body: some View {
        Text(text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.25))
            )
    }
}

private struct SummarySection: View {
    let summary: VisitSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                NSLocalizedString(
                    "patient.visit-summary.title",
                    comment: "Section title for visit summary card"
                )
            )
            .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                if let p = summary.problems, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    LabeledContent {
                        BubbleText(text: p)
                    } label: {
                        Text(
                            NSLocalizedString(
                                "patient.visit-summary.problems.label",
                                comment: "Label for problems list in visit summary"
                            )
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                if let d = summary.diagnosis, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    LabeledContent {
                        BubbleText(text: d)
                    } label: {
                        Text(
                            NSLocalizedString(
                                "patient.visit-summary.diagnosis.label",
                                comment: "Label for diagnosis text in visit summary"
                            )
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                if let c = summary.conclusions, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    LabeledContent {
                        BubbleText(text: c)
                    } label: {
                        Text(
                            NSLocalizedString(
                                "patient.visit-summary.conclusions.label",
                                comment: "Label for conclusions/plan text in visit summary"
                            )
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MilestonesSection: View {
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                NSLocalizedString(
                    "patient.milestones.title",
                    comment: "Section title for milestones summary card"
                )
            )
            .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                BubbleText(text: summary)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Lightweight detail for a selected visit (no extra DB fetch yet).
struct VisitDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let visit: VisitRow

    @EnvironmentObject var clinicianStore: ClinicianStore

    @State private var exportSuccessURL: URL? = nil
    @State private var exportErrorMessage: String? = nil
    @State private var showExportSuccess = false
    @State private var showExportError = false

    private static let isoFullDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    private static let isoDateTimeWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func formattedDate(_ isoString: String) -> String {
        if let d = Self.isoDateTimeWithFractional.date(from: isoString) {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return df.string(from: d)
        }
        if let d = Self.isoFullDate.date(from: isoString) {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            return df.string(from: d)
        }
        return isoString
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 24))
                    Text(
                        NSLocalizedString(
                            "patient.visit-detail.title",
                            comment: "Title for visit detail sheet"
                        )
                    )
                    .font(.title2.bold())
                    Spacer()
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text(
                            NSLocalizedString(
                                "patient.visit-detail.grid.id.label",
                                comment: "Label for visit ID in visit detail grid"
                            )
                        )
                        .foregroundStyle(.secondary)
                        Text("\(visit.id)")
                    }
                    GridRow {
                        Text(
                            NSLocalizedString(
                                "patient.visit-detail.grid.date.label",
                                comment: "Label for visit date in visit detail grid"
                            )
                        )
                        .foregroundStyle(.secondary)
                        Text(formattedDate(visit.dateISO))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GridRow {
                        Text(
                            NSLocalizedString(
                                "patient.visit-detail.grid.category.label",
                                comment: "Label for visit category in visit detail grid"
                            )
                        )
                        .foregroundStyle(.secondary)
                        Text(prettyCategory(visit.category))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // --- Summary pulled from AppState (problems / diagnosis / conclusions) ---
                if let s = appState.visitSummary,
                   ((s.problems?.isEmpty == false) ||
                    (s.diagnosis?.isEmpty == false) ||
                    (s.conclusions?.isEmpty == false)) {

                    Divider().padding(.top, 4)
                    SummarySection(summary: s)
                }

                // --- Milestones summary card (if available from AppState.visitDetails) ---
                if let details = appState.visitDetails,
                   let ms = details.milestonesSummary,
                   !ms.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Divider().padding(.top, 4)
                    MilestonesSection(summary: ms)
                }

                Spacer()
            }
        }
        .padding(24)
        .frame(minWidth: 680, idealWidth: 760, maxWidth: 900,
               minHeight: 520, idealHeight: 600, maxHeight: 900)
        .onAppear {
            appState.loadVisitSummary(for: visit)
            appState.loadVisitDetails(for: visit)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button(
                        NSLocalizedString(
                            "patient.visit-detail.export.pdf",
                            comment: "Menu item to export visit report as PDF"
                        )
                    ) {
                        Task { @MainActor in
                            do {
                                let builder = ReportBuilder(appState: appState, clinicianStore: clinicianStore)
                                let kind: VisitKind = isSickCategory(visit.category)
                                    ? .sick(episodeID: visit.id)
                                    : .well(visitID: visit.id)
                                _ = try builder.exportPDF(for: kind)
                            } catch {
                                let alert = NSAlert()
                                alert.messageText = NSLocalizedString(
                                    "patient.visit-detail.export.failed.title",
                                    comment: "Title for export failed alert"
                                )
                                alert.informativeText = error.localizedDescription
                                alert.alertStyle = .warning
                                alert.runModal()
                            }
                        }
                    }
                    Button(
                        NSLocalizedString(
                            "patient.visit-detail.export.docx",
                            comment: "Menu item to export visit report as Word (DOCX)"
                        )
                    ) {
                        Task { @MainActor in
                            do {
                                let builder = ReportBuilder(appState: appState, clinicianStore: clinicianStore)
                                let kind: VisitKind = isSickCategory(visit.category)
                                    ? .sick(episodeID: visit.id)
                                    : .well(visitID: visit.id)

                                // Produce the DOCX to the app's default location first
                                let tempURL = try builder.exportDOCX(for: kind)

                                // Ask user where to save; default to Downloads with the suggested name
                                let panel = NSSavePanel()
                                panel.title = NSLocalizedString(
                                    "patient.visit-detail.export.docx.save-panel.title",
                                    comment: "Title for save panel when exporting Word report"
                                )
                                let docxType = UTType(filenameExtension: "docx") ?? .data
                                panel.allowedContentTypes = [docxType]
                                panel.canCreateDirectories = true
                                panel.isExtensionHidden = false
                                panel.nameFieldStringValue = tempURL.lastPathComponent
                                panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

                                if panel.runModal() == .OK, let dest = panel.url {
                                    // Replace if an older file is present
                                    if FileManager.default.fileExists(atPath: dest.path) {
                                        try? FileManager.default.removeItem(at: dest)
                                    }
                                    try FileManager.default.copyItem(at: tempURL, to: dest)
                                    exportSuccessURL = dest
                                    showExportSuccess = true
                                }
                            } catch {
                                exportErrorMessage = error.localizedDescription
                                showExportError = true
                            }
                        }
                    }
                } label: {
                    Label(
                        NSLocalizedString(
                            "patient.visit-detail.export.menu-title",
                            comment: "Toolbar menu title for export actions in visit detail"
                        ),
                        systemImage: "square.and.arrow.up"
                    )
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .alert(
            NSLocalizedString(
                "patient.visit-detail.export.success.title",
                comment: "Title for successful export alert"
            ),
            isPresented: $showExportSuccess
        ) {
            Button(
                NSLocalizedString(
                    "patient.visit-detail.export.success.reveal-button",
                    comment: "Button to reveal exported report in Finder"
                )
            ) {
                if let u = exportSuccessURL {
                    NSWorkspace.shared.activateFileViewerSelecting([u])
                }
            }
            Button(
                NSLocalizedString(
                    "patient.visit-detail.export.success.ok-button",
                    comment: "OK button for successful export alert"
                ),
                role: .cancel
            ) { }
        } message: {
            Text(exportSuccessURL?.lastPathComponent ?? NSLocalizedString(
                "patient.visit-detail.export.success.default-filename",
                comment: "Fallback filename text when export succeeded but URL is missing"
            ))
        }
        .alert(
            NSLocalizedString(
                "patient.visit-detail.export.failed.title",
                comment: "Title for export failed alert"
            ),
            isPresented: $showExportError
        ) {
            Button(
                NSLocalizedString(
                    "patient.visit-detail.export.failed.ok-button",
                    comment: "OK button for export failed alert"
                ),
                role: .cancel
            ) { }
        } message: {
            Text(exportErrorMessage ?? NSLocalizedString(
                "patient.visit-detail.export.failed.unknown-message",
                comment: "Fallback message when export error has no description"
            ))
        }
    }
}

// Composite stable identifier to avoid duplicate IDs when mixing sick/well domains
private extension VisitRow {
    var stableID: String {
        let k = self.category
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let prefix = (k == "episode") ? "sick" : "well"
        return "\(prefix)-\(self.id)"
    }
}

