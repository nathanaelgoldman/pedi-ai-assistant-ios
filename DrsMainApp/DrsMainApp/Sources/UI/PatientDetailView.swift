//
//  PatientDetailView.swift
//  DrsMainApp
//
//  Created by yunastic on 10/27/25.
//
//
//  PatientDetailView.swift
//  DrsMainApp
//
//  Created by yunastic on 10/27/25.
//
//
//  PatientDetailView.swift
//  DrsMainApp
//
//  Created by yunastic on 10/27/25.
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
        "one_month": "1-month visit",
        "two_month": "2-month visit",
        "four_month": "4-month visit",
        "six_month": "6-month visit",
        "nine_month": "9-month visit",
        "twelve_month": "12-month visit",
        "fifteen_month": "15-month visit",
        "eighteen_month": "18-month visit",
        "twentyfour_month": "24-month visit",
        "thirty_month": "30-month visit",
        "thirtysix_month": "36-month visit",
        "episode": "Sick visit"
    ]

    if let nice = map[k] { return nice }
    // fallback: “Fifteen_Month” → “Fifteen Month”
    return raw.replacingOccurrences(of: "_", with: " ").capitalized
}

// Segments for visit filtering
fileprivate enum VisitTab: String, CaseIterable, Identifiable {
    case all = "All"
    case sick = "Sick"
    case well = "Well"

    var id: String { rawValue }
    var label: String { rawValue }
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
        "twenty_four_month","thirty_month","thirtysix_month","thirty_six_month"
    ]
    if wellKeys.contains(k) { return true }
    // treat anything that's not explicit "episode" as well if it matches "month" pattern
    if k.contains("month") { return true }
    return false
}

fileprivate func isSickCategory(_ raw: String) -> Bool {
    let k = raw
        .lowercased()
        .replacingOccurrences(of: "-", with: "_")
        .replacingOccurrences(of: " ", with: "_")
    return k == "episode" || prettyCategory(raw) == "Sick visit"
}

/// Right-pane details for a selected patient from the sidebar list.
struct PatientDetailView: View {
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
    // Break out header actions & report menu to ease type-checking
    @ViewBuilder
    private func headerActionButtons() -> some View {
        HStack {
            Spacer()
            Button {
                showDocuments.toggle()
            } label: {
                Label("Documents…", systemImage: "doc.on.clipboard")
            }
            Button {
                showVitals.toggle()
            } label: {
                Label("Vitals…", systemImage: "waveform.path.ecg")
            }
            Button {
                perinatalPatientIDForSheet = patient.id
                showPerinatalHistory = true
            } label: {
                Label("Perinatal History…", systemImage: "doc.text")
            }
            Button {
                pmhPatientIDForSheet = patient.id
                showPMH = true
            } label: {
                Label("Past Medical History…", systemImage: "book")
            }
            Button {
                vaxPatientIDForSheet = patient.id
                showVaccinationStatus = true
            } label: {
                Label("Vaccination Status…", systemImage: "syringe")
            }
            Button {
                showGrowth.toggle()
            } label: {
                Label("Growth…", systemImage: "chart.xyaxis.line")
            }
            Button {
                showGrowthCharts.toggle()
            } label: {
                Label("Growth Charts…", systemImage: "chart.bar.xaxis")
            }
            Button {
                Task { await MacBundleExporter.run(appState: appState) }
            } label: {
                Label("Export peMR Bundle…", systemImage: "square.and.arrow.up")
            }
            Button {
                editingEpisodeID = nil
                showEpisodeForm = true
                visitForDetail = nil
            } label: {
                Label("New Sick Episode…", systemImage: "stethoscope")
            }
            reportMenu()
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func reportMenu() -> some View {
        // Precompute to avoid heavy expressions inside the ViewBuilder
        let sick = latestSickVisit
        let well = latestWellVisit

        Menu {
            if let v = sick {
                Button("Latest Sick (\(visitDateFormatted(v.dateISO)))") {
                    visitForDetail = v
                    reportVisitKind = .sick(episodeID: v.id)
                }
            } else {
                Text("No sick visits").foregroundStyle(.secondary)
            }

            if let v = well {
                Button("Latest Well (\(prettyCategory(v.category)), \(visitDateFormatted(v.dateISO)))") {
                    visitForDetail = v
                    reportVisitKind = .well(visitID: v.id)
                }
            } else {
                Text("No well visits").foregroundStyle(.secondary)
            }
        } label: {
            Label("Report…", systemImage: "doc.plaintext")
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
                Text("Patient Summary")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    if let s = profile.perinatalHistory, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        LabeledContent {
                            Text(s)
                        } label: {
                            Text("Perinatal")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let pmh = profile.pmh, !pmh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        LabeledContent {
                            Text(pmh)
                        } label: {
                            Text("Past Medical History")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let notes = profile.parentNotes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        LabeledContent {
                            Text(notes)
                        } label: {
                            Text("Parent Notes")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let v = profile.vaccinationStatus, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        LabeledContent {
                            Text(v)
                        } label: {
                            Text("Vaccination")
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 40))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(patient.fullName.isEmpty ? "Anon Patient" : patient.fullName)
                            .font(.title2.bold())
                        Text(patient.alias)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                
                headerActionButtons()

                // Facts grid
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Patient ID").foregroundStyle(.secondary)
                        Text("\(patient.id)")
                    }
                    GridRow {
                        Text("DOB").foregroundStyle(.secondary)
                        Text(dobFormatted)
                    }
                    GridRow {
                        Text("Sex").foregroundStyle(.secondary)
                        Text(patient.sex)
                    }
                    if let bundle = appState.currentBundleURL {
                        GridRow {
                            Text("Bundle").foregroundStyle(.secondary)
                            Text(bundle.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                // --- Patient Summary card (perinatal / PMH / vaccination) ---
                patientSummarySection
                

                Divider()

                // Visits section
                HStack {
                    Text("Visits")
                        .font(.headline)
                    Spacer()
                    Picker("Filter", selection: $visitTab) {
                        ForEach(VisitTab.allCases) { tab in
                            Text(tab.label).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }

                let list = filteredVisits
                if list.isEmpty {
                    Text("No visits found for this patient in “\(visitTab.label)”")
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
            // Load both visits and the profile
            appState.loadVisits(for: patient.id)
            appState.loadPatientProfile(for: Int64(patient.id))
        }
        .onChange(of: appState.selectedPatientID) { newID in
            guard let id = newID else { return }
            // Only close Perinatal sheet if it was opened for a different patient than the newly selected one
            if showPerinatalHistory, let openID = perinatalPatientIDForSheet, openID != id {
                showPerinatalHistory = false
            }
            if showPMH, let openID = pmhPatientIDForSheet, openID != id {
                showPMH = false
            }
            if showVaccinationStatus, let openID = vaxPatientIDForSheet, openID != id {
                showVaccinationStatus = false
            }
            if showEpisodeForm { showEpisodeForm = false; editingEpisodeID = nil }
            appState.loadVisits(for: id)
            appState.loadPatientProfile(for: Int64(id))
        }
        .onChange(of: showEpisodeForm) { open in
            // When the sheet closes, forget the editing target to avoid stale state on the next open
            if !open {
                editingEpisodeID = nil
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
            showPerinatalHistory = false
            if let id = appState.selectedPatientID {
                appState.loadPatientProfile(for: Int64(id))
            }
        }) {
            PerinatalHistoryForm()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showPMH, onDismiss: {
            showPMH = false
            if let id = appState.selectedPatientID {
                appState.loadPatientProfile(for: Int64(id))
            }
        }) {
            PmhForm()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showVaccinationStatus, onDismiss: {
            showVaccinationStatus = false
            if let id = appState.selectedPatientID {
                appState.loadPatientProfile(for: Int64(id))
            }
        }) {
            VaccinationStatusForm()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showEpisodeForm, onDismiss: {
            // Refresh visits and profile after closing the form
            if let id = appState.selectedPatientID {
                appState.loadVisits(for: id)
                appState.loadPatientProfile(for: Int64(id))
                visitTab = .all
            }
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

            Button("Details…") {
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
                Button("Edit…") {
                    editingEpisodeID = v.id
                    showEpisodeForm = true
                }
                .buttonStyle(.bordered)
                .disabled(!isWithin24Hours(v.dateISO))
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
            Text("Summary")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                if let p = summary.problems, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    LabeledContent {
                        BubbleText(text: p)
                    } label: {
                        Text("Problems").foregroundStyle(.secondary)
                    }
                }
                if let d = summary.diagnosis, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    LabeledContent {
                        BubbleText(text: d)
                    } label: {
                        Text("Diagnosis").foregroundStyle(.secondary)
                    }
                }
                if let c = summary.conclusions, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    LabeledContent {
                        BubbleText(text: c)
                    } label: {
                        Text("Conclusions").foregroundStyle(.secondary)
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
                    Text("Visit Details")
                        .font(.title2.bold())
                    Spacer()
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("ID").foregroundStyle(.secondary)
                        Text("\(visit.id)")
                    }
                    GridRow {
                        Text("Date").foregroundStyle(.secondary)
                        Text(formattedDate(visit.dateISO))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GridRow {
                        Text("Category").foregroundStyle(.secondary)
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

                Spacer()
            }
        }
        .padding(24)
        .frame(minWidth: 680, idealWidth: 760, maxWidth: 900,
               minHeight: 520, idealHeight: 600, maxHeight: 900)
        .onAppear {
            appState.loadVisitSummary(for: visit)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Export PDF") {
                        Task { @MainActor in
                            do {
                                let builder = ReportBuilder(appState: appState, clinicianStore: clinicianStore)
                                let kind: VisitKind = isSickCategory(visit.category)
                                    ? .sick(episodeID: visit.id)
                                    : .well(visitID: visit.id)
                                _ = try builder.exportPDF(for: kind)
                            } catch {
                                let alert = NSAlert()
                                alert.messageText = "Export failed"
                                alert.informativeText = error.localizedDescription
                                alert.alertStyle = .warning
                                alert.runModal()
                            }
                        }
                    }
                    Button("Export Word (.docx)") {
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
                                panel.title = "Save Word Report"
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
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .alert("Report exported", isPresented: $showExportSuccess) {
            Button("Reveal in Finder") {
                if let u = exportSuccessURL {
                    NSWorkspace.shared.activateFileViewerSelecting([u])
                }
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportSuccessURL?.lastPathComponent ?? "Saved")
        }
        .alert("Export failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportErrorMessage ?? "Unknown error")
        }
    }
}

// Composite stable identifier to avoid duplicate IDs when mixing sick/well domains
private extension VisitRow {
    var stableID: String {
        let prefix = isSickCategory(self.category) ? "sick" : "well"
        return "\(prefix)-\(self.id)"
    }
}

