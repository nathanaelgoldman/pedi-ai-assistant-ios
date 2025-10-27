//
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
                Text("Patients")
                    .font(.headline)
                Spacer()
                Button {
                    appState.reloadPatients()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload patients from the bundle database")
            }

            List(selection: $appState.selectedPatientID) {
                ForEach(appState.patients) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.alias.isEmpty ? p.fullName : p.alias)
                            .font(.body.weight(.medium))
                        Text("\(p.fullName) • \(p.dobISO) • \(p.sex)")
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
