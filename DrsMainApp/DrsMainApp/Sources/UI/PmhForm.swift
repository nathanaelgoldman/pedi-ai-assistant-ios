//
//  PmhForm.swift
//  DrsMainApp
//
//  Created by yunastic on 11/14/25.
//
import SwiftUI

struct PmhForm: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    // Form state
    @State private var asthma = false
    @State private var otitis = false
    @State private var uti = false
    @State private var allergies = false
    @State private var allergyDetails = ""
    @State private var other = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack {
                    VStack(spacing: 16) {
                        // Two-column layout, comfy padding
                        Grid(horizontalSpacing: 24, verticalSpacing: 16) {
                            GridRow {
                                Toggle(String(localized: "pmh.toggle.asthma"), isOn: $asthma)
                                Toggle(String(localized: "pmh.toggle.recurrent_otitis"), isOn: $otitis)
                            }
                            GridRow {
                                Toggle(String(localized: "pmh.toggle.recurrent_uti"), isOn: $uti)
                                Toggle(String(localized: "pmh.toggle.allergies"), isOn: $allergies)
                            }
                        }
                        .padding(.horizontal)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "pmh.label.allergy_details"))
                                .font(.headline)
                            TextField(String(localized: "pmh.placeholder.allergy_example"), text: $allergyDetails, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(3...6)
                                .disabled(!allergies)
                                .opacity(allergies ? 1 : 0.5)
                        }
                        .padding(.horizontal)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "pmh.label.other_pmh"))
                                .font(.headline)
                            TextEditor(text: $other)
                                .frame(minHeight: 120)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(.secondary.opacity(0.3))
                                )
                        }
                        .padding(.horizontal)

                        Spacer(minLength: 8)
                    }
                    .padding(20)
                    .lightBlueSectionCardStyle()
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .navigationTitle(String(localized: "pmh.nav.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "generic.button.done")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "generic.button.save")) { save() }
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 880, maxWidth: 1000,
               minHeight: 520, idealHeight: 640, maxHeight: .infinity)
        .onAppear(perform: prefill)
    }

    private func prefill() {
        // Use whatever is already cached; AppState now auto-refreshes on patient change
        if let pmh = app.pastMedicalHistory {
            asthma = pmh.asthma != 0
            otitis = pmh.otitis != 0
            uti = pmh.uti != 0
            allergies = pmh.allergies != 0
            allergyDetails = pmh.allergyDetails ?? ""
            other = pmh.other ?? ""
        } else {
            // Best-effort fetch (in case the form was opened directly)
            app.loadPMHForSelectedPatient()
            if let pmh = app.pastMedicalHistory {
                asthma = pmh.asthma != 0
                otitis = pmh.otitis != 0
                uti = pmh.uti != 0
                allergies = pmh.allergies != 0
                allergyDetails = pmh.allergyDetails ?? ""
                other = pmh.other ?? ""
            }
        }
    }

    private func save() {
        // Ensure we have a selected patient
        guard let pid = app.selectedPatientID else {
            return
        }

        // Build the value object for AppState (match struct labels)
        let updated = PastMedicalHistory(
            patientID: Int64(pid),
            asthma: asthma ? 1 : 0,
            otitis: otitis ? 1 : 0,
            uti: uti ? 1 : 0,
            allergies: allergies ? 1 : 0,
            allergyDetails: allergies ? allergyDetails.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            other: other.trimmingCharacters(in: .whitespacesAndNewlines),
            updatedAtISO: nil // let the store fill this
        )

        if app.savePMHForSelectedPatient(updated) {
            // Keep the read-only panel fresh
            app.loadPMHForSelectedPatient()
            dismiss()
        }
    }
}

// MARK: - Light-blue section card styling (matches other forms)
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
    /// Apply the standard light-blue “section card” look (used for blocks inside forms).
    func lightBlueSectionCardStyle() -> some View {
        self.modifier(LightBlueSectionCardStyle())
    }
}
