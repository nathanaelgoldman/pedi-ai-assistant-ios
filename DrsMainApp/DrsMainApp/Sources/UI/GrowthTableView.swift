//
//  GrowthTableView.swift
//  DrsMainApp
//
//  Created by yunastic on 11/1/25.
//
import SwiftUI

/// Read-only table that lists unified growth points for the currently selected patient.
struct GrowthTableView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [GrowthPoint] = []

    var body: some View {
        VStack(spacing: 0) {
            Table(rows) {
                TableColumn("Date") { p in
                    Text(formatDate(p.recordedAtISO)).monospacedDigit()
                }.width(min: 120)

                TableColumn("Weight (kg)") { p in
                    Text(formatNumber(p.weightKg)).monospacedDigit()
                }.width(min: 90)

                TableColumn("Height (cm)") { p in
                    Text(formatNumber(p.heightCm)).monospacedDigit()
                }.width(min: 90)

                TableColumn("Head C (cm)") { p in
                    Text(formatNumber(p.headCircumferenceCm)).monospacedDigit()
                }.width(min: 100)

                TableColumn("Source") { p in
                    Text(p.source)
                }.width(min: 90)
            }
            .frame(minHeight: 240)

            if rows.isEmpty {
                VStack {
                    Text("No growth records found for this patient.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: appState.selectedPatientID) { _ in
            reload()
        }
        .onChange(of: appState.currentBundleURL) { _ in
            reload()
        }
        .navigationTitle("Growth")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }

    private func reload() {
        rows = appState.loadGrowthForSelectedPatient()
    }

    private func formatDate(_ iso: String) -> String {
        // Try full ISO first, then fallback to YYYY-MM-DD prefix
        if let d = ISO8601DateFormatter().date(from: iso) {
            let df = DateFormatter()
            df.calendar = Calendar(identifier: .iso8601)
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = "yyyy-MM-dd"
            return df.string(from: d)
        }
        return iso.count >= 10 ? String(iso.prefix(10)) : iso
    }

    private func formatNumber(_ x: Double?) -> String {
        guard let x else { return "—" }
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        f.locale = Locale.current
        return f.string(from: NSNumber(value: x)) ?? String(format: "%.2f", x)
    }
}

#Preview {
    // Lightweight preview with mock data (does not require DB)
    let store = ClinicianStore()
    let app = AppState(clinicianStore: store)
    return GrowthTableView()
        .environmentObject(app)
}
