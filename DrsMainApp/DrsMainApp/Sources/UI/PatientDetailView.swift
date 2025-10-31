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

/// Right-pane details for a selected patient from the sidebar list.
struct PatientDetailView: View {
    @EnvironmentObject var appState: AppState
    let patient: PatientRow   // ← match AppState.selectedPatient type
    @State private var visitForDetail: VisitRow? = nil

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
                if let profile = appState.currentPatientProfile,
                   (profile.perinatalHistory?.isEmpty == false ||
                    profile.pmh?.isEmpty == false ||
                    profile.vaccinationStatus?.isEmpty == false) {

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
                

                Divider()

                // Visits section
                Text("Visits")
                    .font(.headline)

                if appState.visits.isEmpty {
                    Text("No visits found for this patient.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(appState.visits) { v in
                            Button(action: { visitForDetail = v }) {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "calendar")
                                        .font(.system(size: 16))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(visitDateFormatted(v.dateISO))
                                            .font(.body)
                                        Text(prettyCategory(v.category))
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(8)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
        }
        .onAppear {
            // Load both visits and the profile
            appState.loadVisits(for: patient.id)
            appState.loadPatientProfile(for: Int64(patient.id))
        }
        .onChange(of: appState.selectedPatientID) { _, newID in
            if let id = newID {
                appState.loadVisits(for: id)
                appState.loadPatientProfile(for: Int64(patient.id))
            }
        }
        .sheet(item: $visitForDetail) { v in
            VisitDetailView(visit: v)
        }
    }
}

/// Lightweight detail for a selected visit (no extra DB fetch yet).
struct VisitDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let visit: VisitRow

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
                }
                GridRow {
                    Text("Category").foregroundStyle(.secondary)
                    Text(prettyCategory(visit.category))
                }
            }

            // --- Summary pulled from AppState (problems / diagnosis / conclusions) ---
            if let s = appState.visitSummary,
               ( (s.problems?.isEmpty == false) ||
                 (s.diagnosis?.isEmpty == false) ||
                 (s.conclusions?.isEmpty == false) ) {

                Divider().padding(.top, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Summary")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 8) {
                        if let p = s.problems, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            LabeledContent {
                                Text(p)
                            } label: {
                                Text("Problems")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let d = s.diagnosis, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            LabeledContent {
                                Text(d)
                            } label: {
                                Text("Diagnosis")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let c = s.conclusions, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            LabeledContent {
                                Text(c)
                            } label: {
                                Text("Conclusions")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 280)
        .onAppear {
            appState.loadVisitSummary(for: visit)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
