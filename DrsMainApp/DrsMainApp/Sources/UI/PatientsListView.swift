//  PatientsListView.swift
//  DrsMainApp
//
//  Created by yunastic on 10/27/25.
//
import SwiftUI

struct PatientsListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(
                    NSLocalizedString(
                        "patientsList.title",
                        comment: "Patients list header title"
                    )
                )
                .font(.headline)

                Spacer()

                Button {
                    appState.reloadPatients()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(
                    NSLocalizedString(
                        "patientsList.reload.help",
                        comment: "Help tooltip for button that reloads patients from the bundle database"
                    )
                )
            }

            List(selection: $appState.selectedPatientID) {
                ForEach(appState.patients) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.alias.isEmpty ? p.fullName : p.alias)
                            .font(.body.weight(.medium))

                        Text(
                            String(
                                format: NSLocalizedString(
                                    "patientsList.row.details-format",
                                    comment: "Patient row details: full name • DOB • sex"
                                ),
                                p.fullName,
                                p.dobISO,
                                p.sex
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .tag(p.id as Int?)
                }
            }
        }
        .padding()
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 320)
    }
}
