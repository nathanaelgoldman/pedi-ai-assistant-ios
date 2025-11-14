import SwiftUI

///VaccinationStatusForm.swift
///
/// Simple edit sheet for the patient's Vaccination Status.
/// Reads/writes via AppState helpers:
///   - getVaccinationStatusForSelectedPatient()
///   - saveVaccinationStatusForSelectedPatient(_:)
struct VaccinationStatusForm: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var status: String = "Unknown"

    private static let choices: [String] = [
        "Up to date",
        "Delayed",
        "Not vaccinated",
        "Unknown"
    ]

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("Vaccination Status")
                    .font(.title2).bold()
                Spacer()
            }

            // Picker
            Picker("Status", selection: $status) {
                ForEach(Self.choices, id: \.self) { choice in
                    Text(choice).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            Spacer(minLength: 8)

            // Actions
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                Spacer()
                Button("Save") {
                    let ok = app.saveVaccinationStatusForSelectedPatient(status)
                    if ok {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 520, maxWidth: 560,
               minHeight: 180, idealHeight: 220, maxHeight: 240)
        .onAppear {
            if let current = app.getVaccinationStatusForSelectedPatient(),
               Self.choices.contains(current) {
                status = current
            } else {
                status = "Unknown"
            }
        }
    }
}

#if DEBUG
#Preview {
    // Lightweight preview to avoid depending on AppState construction.
    EmptyView()
}
#endif
