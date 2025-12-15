//
//  GrowthTableView.swift
//  DrsMainApp
//
//  Created by yunastic on 11/1/25.
//
import SwiftUI

#if os(iOS)
import UIKit
#endif

private extension View {
    @ViewBuilder
    func decimalKeyboardIfAvailable() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}

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
                Text(
                    NSLocalizedString(
                        "growth.header.date",
                        comment: "Growth table header: date column"
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)

                Text(
                    NSLocalizedString(
                        "growth.header.weight-kg",
                        comment: "Growth table header: weight (kg) column"
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)

                Text(
                    NSLocalizedString(
                        "growth.header.height-cm",
                        comment: "Growth table header: height (cm) column"
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)

                Text(
                    NSLocalizedString(
                        "growth.header.headc-cm",
                        comment: "Growth table header: head circumference (cm) column"
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)

                Text(
                    NSLocalizedString(
                        "growth.header.source",
                        comment: "Growth table header: source column"
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()

            // Rows
            List(rows, id: \.id) { p in
                GrowthRowView(
                    p: p,
                    formatDate: formatDate,
                    formatNumber: formatNumber,
                    onDelete: {
                        do {
                            try appState.deleteGrowthPointIfManual(p)
                            scheduleReload()
                        } catch {
                            print("deleteGrowthPointIfManual error: \(error)")
                        }
                    }
                )
            }
            .listStyle(.inset)
            .frame(minHeight: 240)

            // Empty state (kept INSIDE the VStack so modifiers below apply to the whole view)
            if rows.isEmpty {
                Text(
                    NSLocalizedString(
                        "growth.empty",
                        comment: "Shown when no growth records are found for the selected patient"
                    )
                )
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .onAppear { scheduleReload() }
        .onChange(of: appState.selectedPatientID) { _, _ in
            scheduleReload()
        }
        .onChange(of: appState.currentBundleURL) { _, _ in
            scheduleReload()
        }
        .navigationTitle(
            NSLocalizedString(
                "growth.nav.title",
                comment: "Navigation title for the growth table window"
            )
        )
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(
                    NSLocalizedString(
                        "generic.button.close",
                        comment: "Toolbar button to close a sheet or window"
                    )
                ) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .automatic) {
                Button { scheduleReload() } label: {
                    Label(
                        NSLocalizedString(
                            "growth.toolbar.refresh",
                            comment: "Toolbar button to refresh growth records"
                        ),
                        systemImage: "arrow.clockwise"
                    )
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Label(
                        NSLocalizedString(
                            "growth.toolbar.add",
                            comment: "Toolbar button to add a manual growth point"
                        ),
                        systemImage: "plus"
                    )
                }
                .help(
                    NSLocalizedString(
                        "growth.toolbar.add.help",
                        comment: "Help text for the button that adds a manual growth point"
                    )
                )
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ManualGrowthForm { date, weightKg, heightCm, headC in
                if let pid = appState.selectedPatientID {
                    var df = ISO8601DateFormatter()
                    df.formatOptions = [.withFullDate]
                    let iso = df.string(from: date)
                    do {
                        try appState.addGrowthPointManual(
                            patientID: pid,
                            recordedAtISO: iso,
                            weightKg: weightKg,
                            heightCm: heightCm,
                            headCircumferenceCm: headC,
                            episodeID: nil
                        )
                        scheduleReload()
                    } catch {
                        print("addGrowthPointManual error: \(error)")
                    }
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

/// A single growth row with a disabled swipe-to-delete when source != manual.
private struct GrowthRowView: View {
    let p: GrowthPoint
    let formatDate: (String) -> String
    let formatNumber: (Double?) -> String
    let onDelete: () -> Void

    private var isManual: Bool { p.source.lowercased() == "manual" }

    var body: some View {
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
        .swipeActions(edge: .trailing, allowsFullSwipe: isManual) {
            if isManual {
                Button(role: .destructive, action: onDelete) {
                    Label(
                        NSLocalizedString(
                            "growth.row.delete",
                            comment: "Swipe action button to delete a manual growth point"
                        ),
                        systemImage: "trash"
                    )
                }
            }
        }
        .contextMenu {
            if isManual {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label(
                        NSLocalizedString(
                            "growth.row.delete",
                            comment: "Context menu button to delete a manual growth point"
                        ),
                        systemImage: "trash"
                    )
                }
            }
        }
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
                Section(
                    NSLocalizedString(
                        "growth.form.section.date",
                        comment: "Section title for selecting the growth record date"
                    )
                ) {
                    DatePicker(
                        NSLocalizedString(
                            "growth.form.label.recorded-date",
                            comment: "Label for the date picker in the growth form"
                        ),
                        selection: $date,
                        displayedComponents: .date
                    )
                }
                Section(
                    NSLocalizedString(
                        "growth.form.section.measurements",
                        comment: "Section title for entering growth measurements"
                    )
                ) {
                    TextField(
                        NSLocalizedString(
                            "growth.form.field.weight-kg",
                            comment: "Text field placeholder for weight in kilograms"
                        ),
                        text: $weightText
                    )
                    .decimalKeyboardIfAvailable()

                    TextField(
                        NSLocalizedString(
                            "growth.form.field.height-cm",
                            comment: "Text field placeholder for height in centimeters"
                        ),
                        text: $heightText
                    )
                    .decimalKeyboardIfAvailable()

                    TextField(
                        NSLocalizedString(
                            "growth.form.field.headc-cm",
                            comment: "Text field placeholder for head circumference in centimeters"
                        ),
                        text: $headText
                    )
                    .decimalKeyboardIfAvailable()

                    Text(
                        NSLocalizedString(
                            "growth.form.hint.optional-fields",
                            comment: "Hint explaining that growth fields can be left blank to skip"
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(
                NSLocalizedString(
                    "growth.form.title",
                    comment: "Navigation title for the sheet that adds a growth point"
                )
            )
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        NSLocalizedString(
                            "generic.button.cancel",
                            comment: "Toolbar button to cancel and dismiss a sheet"
                        )
                    ) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        NSLocalizedString(
                            "generic.button.save",
                            comment: "Toolbar button to save current changes"
                        )
                    ) {
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
