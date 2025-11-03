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
            // Header row
            HStack {
                Text("Date").font(.subheadline).foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                Text("Weight (kg)").font(.subheadline).foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .trailing)
                Text("Height (cm)").font(.subheadline).foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .trailing)
                Text("Head C (cm)").font(.subheadline).foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .trailing)
                Text("Source").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()

            // Rows
            List {
                ForEach(rows) { p in
                    HStack {
                        Text(formatDate(p.recordedAtISO)).monospacedDigit()
                            .frame(width: 120, alignment: .leading)
                        Text(formatNumber(p.weightKg)).monospacedDigit()
                            .frame(width: 100, alignment: .trailing)
                        Text(formatNumber(p.heightCm)).monospacedDigit()
                            .frame(width: 100, alignment: .trailing)
                        Text(formatNumber(p.headCircumferenceCm)).monospacedDigit()
                            .frame(width: 110, alignment: .trailing)
                        Text(p.source)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 240)

            // Empty state (kept INSIDE the VStack so modifiers below apply to the whole view)
            if rows.isEmpty {
                Text("No growth records found for this patient.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .onAppear { reload() }
        .onChange(of: appState.selectedPatientID) { _ in reload() }
        .onChange(of: appState.currentBundleURL) { _ in reload() }
        .navigationTitle("Growth")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .automatic) {
                Button { reload() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }

    private func reload() {
        rows = appState.loadGrowthForSelectedPatient()
        // Sort newest first by ISO string (YYYY-MM-DD or full ISO)
        rows.sort { $0.recordedAtISO > $1.recordedAtISO }
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
