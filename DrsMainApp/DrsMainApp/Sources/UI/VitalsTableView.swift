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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(
                    NSLocalizedString(
                        "vitals.nav.title",
                        comment: "Title for the vitals table sheet"
                    )
                )
                .font(.title2).bold()

                Spacer()

                Button(
                    NSLocalizedString(
                        "generic.button.close",
                        comment: "Close button label for sheets"
                    )
                ) {
                    dismiss()
                }
            }
            .padding(.bottom, 8)

            if vitals.isEmpty {
                Text(
                    NSLocalizedString(
                        "vitals.empty",
                        comment: "Shown when there are no vitals recorded for the patient"
                    )
                )
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        }
                    }
                    .listStyle(.plain)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: sortOrder) { _, newOrder in
                    vitals.sort(using: newOrder)
                }
            }
        }
        .padding()
        .frame(minWidth: 900, minHeight: 500)
        .onAppear {
            vitals = appState.loadVitalsForSelectedPatient()
            vitals.sort(using: sortOrder)
        }
    }
}

#Preview {
    VitalsTableView()
        .environmentObject(AppState(clinicianStore: ClinicianStore()))
}
