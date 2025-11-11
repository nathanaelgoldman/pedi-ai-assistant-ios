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
    @State private var pendingReload = false
    @State private var showAddSheet = false

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
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if p.source.lowercased() == "manual" {
                            Button(role: .destructive) {
                                appState.deleteGrowthPointIfManual(p)
                                scheduleReload()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
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
        .onAppear { scheduleReload() }
        .onChange(of: appState.selectedPatientID) { _, _ in scheduleReload() }
        .onChange(of: appState.currentBundleURL) { _, _ in scheduleReload() }
        .navigationTitle("Growth")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .automatic) {
                Button { scheduleReload() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add a manual growth point")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ManualGrowthForm { date, weightKg, heightCm, headC in
                // Use current selection; if unavailable, just dismiss.
                if let pid = appState.selectedPatientID {
                    appState.addGrowthPointManual(
                        patientID: pid,
                        date: date,
                        weightKg: weightKg,
                        heightCm: heightCm,
                        headCircumferenceCm: headC
                    )
                    scheduleReload()
                }
            }
        }
    }

    /// Schedule a reload on the next runloop turn to avoid layout-time state mutations.
    private func scheduleReload() {
        if pendingReload { return }
        pendingReload = true
        DispatchQueue.main.async {
            reload()
            pendingReload = false
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

/// Inline lightweight sheet for adding a manual growth point.
private struct ManualGrowthForm: View {
    @Environment(\.dismiss) private var dismiss

    // Simple callbacks — call `onSave` with parsed values, then dismiss.
    var onSave: (_ date: Date, _ weightKg: Double?, _ heightCm: Double?, _ headCircumferenceCm: Double?) -> Void

    @State private var date = Date()
    @State private var weightText = ""
    @State private var heightText = ""
    @State private var headText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    DatePicker("Recorded date", selection: $date, displayedComponents: .date)
                }
                Section("Measurements (optional)") {
                    TextField("Weight (kg)", text: $weightText)
                        .keyboardType(.decimalPad)
                    TextField("Height (cm)", text: $heightText)
                        .keyboardType(.decimalPad)
                    TextField("Head circumference (cm)", text: $headText)
                        .keyboardType(.decimalPad)
                    Text("Leave any field blank to skip it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Growth Point")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let weight = parseDouble(weightText)
                        let height = parseDouble(heightText)
                        let head   = parseDouble(headText)
                        // If all three are nil, don't save anything.
                        guard weight != nil || height != nil || head != nil else {
                            dismiss()
                            return
                        }
                        onSave(date, weight, height, head)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// Locale-aware decimal parsing; returns nil for empty/invalid.
    private func parseDouble(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let nf = NumberFormatter()
        nf.locale = .current
        nf.numberStyle = .decimal
        // Try locale parsing first, then fallback to dot-decimal.
        if let n = nf.number(from: trimmed) {
            return n.doubleValue
        }
        return Double(trimmed)
    }
}

#Preview {
    // Lightweight preview with mock data (does not require DB)
    let store = ClinicianStore()
    let app = AppState(clinicianStore: store)
    return GrowthTableView()
        .environmentObject(app)
}
