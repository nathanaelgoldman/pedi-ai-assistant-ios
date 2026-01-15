//
//  VitalsTableView.swift
//  DrsMainApp
//
//  Created by yunastic on 11/1/25.
//

import SwiftUI

struct VitalsTableView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var vitals: [VitalsPoint] = []

    // Sort newest first by recordedAtISO (String is Comparable → fine for KeyPathComparator)
    @State private var sortOrder: [KeyPathComparator<VitalsPoint>] = [
        .init(\.recordedAtISO, order: .reverse)
    ]

    var body: some View {
        NavigationStack {
            VStack {
                VStack(alignment: .leading, spacing: 10) {
                    if vitals.isEmpty {
                        Text(
                            NSLocalizedString(
                                "vitals.empty",
                                comment: "Shown when there are no vitals recorded for the patient"
                            )
                        )
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else {
                        VStack(spacing: 6) {
                            // Column headers
                            HStack {
                                Text(
                                    NSLocalizedString(
                                        "vitals.header.date-time",
                                        comment: "Vitals table header: Date and time of measurement"
                                    )
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Text(
                                    NSLocalizedString(
                                        "vitals.header.temp-c",
                                        comment: "Vitals table header: Temperature in Celsius"
                                    )
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)

                                Text(
                                    NSLocalizedString(
                                        "vitals.header.hr",
                                        comment: "Vitals table header: Heart rate"
                                    )
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)

                                Text(
                                    NSLocalizedString(
                                        "vitals.header.rr",
                                        comment: "Vitals table header: Respiratory rate"
                                    )
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)

                                Text(
                                    NSLocalizedString(
                                        "vitals.header.spo2",
                                        comment: "Vitals table header: Oxygen saturation"
                                    )
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)

                                Text(
                                    NSLocalizedString(
                                        "vitals.header.bp",
                                        comment: "Vitals table header: Blood pressure"
                                    )
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)

                                Text(
                                    NSLocalizedString(
                                        "vitals.header.weight-kg",
                                        comment: "Vitals table header: Weight in kilograms"
                                    )
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .trailing)

                                Text(
                                    NSLocalizedString(
                                        "vitals.header.height-cm",
                                        comment: "Vitals table header: Height in centimeters"
                                    )
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .trailing)

                                Text(
                                    NSLocalizedString(
                                        "vitals.header.hc-cm",
                                        comment: "Vitals table header: Head circumference in centimeters"
                                    )
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .trailing)
                            }
                            .padding(.horizontal, 4)

                            // Rows
                            List {
                                ForEach(vitals) { item in
                                    HStack {
                                        Text(item.recordedAtISO.isEmpty ? "—" : item.recordedAtISO)
                                            .monospacedDigit()
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                        Text(item.temperatureC.map { String(format: "%.1f", $0) } ?? "")
                                            .frame(width: 70, alignment: .trailing)

                                        Text(item.heartRate.map { "\($0)" } ?? "")
                                            .frame(width: 40, alignment: .trailing)

                                        Text(item.respiratoryRate.map { "\($0)" } ?? "")
                                            .frame(width: 40, alignment: .trailing)

                                        Text(item.spo2.map { "\($0)%" } ?? "")
                                            .frame(width: 60, alignment: .trailing)

                                        Text(
                                            (item.bpSystolic != nil && item.bpDiastolic != nil)
                                                ? "\(item.bpSystolic!)/\(item.bpDiastolic!)"
                                                : ""
                                        )
                                        .frame(width: 70, alignment: .trailing)

                                        Text(item.weightKg.map { String(format: "%.2f", $0) } ?? "")
                                            .frame(width: 90, alignment: .trailing)

                                        Text(item.heightCm.map { String(format: "%.1f", $0) } ?? "")
                                            .frame(width: 90, alignment: .trailing)

                                        Text(item.headCircumferenceCm.map { String(format: "%.1f", $0) } ?? "")
                                            .frame(width: 80, alignment: .trailing)
                                    }
                                    .padding(.vertical, 2)
                                    .listRowBackground(Color.clear)
                                }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                        }
                        .frame(maxHeight: .infinity)
                        .onChange(of: sortOrder) { _, newOrder in
                            vitals.sort(using: newOrder)
                        }
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
            }
            // Match the “self-contained sheet” style used elsewhere
            .padding(20)
            .frame(minWidth: 900, minHeight: 500)
            .navigationTitle(
                NSLocalizedString(
                    "vitals.nav.title",
                    comment: "Navigation title for the vitals table sheet"
                )
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        NSLocalizedString(
                            "generic.button.close",
                            comment: "Close button label for sheets"
                        )
                    ) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .onAppear {
                vitals = appState.loadVitalsForSelectedPatient()
                vitals.sort(using: sortOrder)
            }
        }
    }
}

#Preview {
    VitalsTableView()
        .environmentObject(AppState(clinicianStore: ClinicianStore()))
}
