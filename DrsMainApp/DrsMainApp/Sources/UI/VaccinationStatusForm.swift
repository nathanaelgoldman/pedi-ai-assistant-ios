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

    // NOTE: This is the stored *code* value, still in English for DB compatibility.
    @State private var status: String = "Unknown"

    // These are also the stored *codes* – do not localize here.
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
                Text(NSLocalizedString("vax.form.title",
                                       comment: "Vaccination status form title"))
                    .font(.title2).bold()
                Spacer()
            }

            // Picker
            Picker(NSLocalizedString("vax.field.status.label",
                                     comment: "Vaccination status picker label"),
                   selection: $status) {
                ForEach(Self.choices, id: \.self) { choice in
                    // Localized label, but tag stays as the original code
                    Text(localizedStatusLabel(for: choice)).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            Spacer(minLength: 8)

            // Actions
            HStack {
                Button(NSLocalizedString("generic.button.cancel",
                                         comment: "Cancel button")) {
                    dismiss()
                }
                Spacer()
                Button(NSLocalizedString("generic.button.save",
                                         comment: "Save button")) {
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
                status = "Unknown" // stored code, not localized text
            }
        }
    }

    // MARK: - Helpers

    /// Map stored status codes to localized labels for display.
    private func localizedStatusLabel(for code: String) -> String {
        switch code {
        case "Up to date":
            return NSLocalizedString("vax.status.up_to_date",
                                     comment: "Vaccination status: up to date")
        case "Delayed":
            return NSLocalizedString("vax.status.delayed",
                                     comment: "Vaccination status: delayed")
        case "Not vaccinated":
            return NSLocalizedString("vax.status.not_vaccinated",
                                     comment: "Vaccination status: not vaccinated")
        case "Unknown":
            return NSLocalizedString("vax.status.unknown",
                                     comment: "Vaccination status: unknown")
        default:
            // Fallback: show raw value if we somehow get an unknown code
            return code
        }
    }
}

#if DEBUG
#Preview {
    // Lightweight preview to avoid depending on AppState construction.
    EmptyView()
}
#endif
