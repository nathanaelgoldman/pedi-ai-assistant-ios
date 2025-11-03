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
                Text("Patient Vitals")
                    .font(.title2).bold()
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(.bottom, 8)

            if vitals.isEmpty {
                Text("No vitals recorded for this patient.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 6) {
                    // Column headers
                    HStack {
                        Text("Date/Time").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        Text("Temp °C").font(.subheadline).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                        Text("HR").font(.subheadline).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        Text("RR").font(.subheadline).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        Text("SpO₂").font(.subheadline).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                        Text("BP").font(.subheadline).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                        Text("Weight (kg)").font(.subheadline).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                        Text("Height (cm)").font(.subheadline).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                        Text("HC (cm)").font(.subheadline).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
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

                                Text((item.bpSystolic != nil && item.bpDiastolic != nil) ? "\(item.bpSystolic!)/\(item.bpDiastolic!)" : "")
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
