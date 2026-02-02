//
//  VitalsTableView.swift
//  DrsMainApp
//
//  Created by yunastic on 11/1/25.
//


import SwiftUI
import Foundation

// MARK: - Light-blue section card styling (matches PerinatalHistoryForm section blocks)
fileprivate struct LightBlueSectionCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1)
            )
    }
}

fileprivate extension View {
    /// Apply the standard light-blue “section card” look.
    func lightBlueSectionCardStyle() -> some View {
        self.modifier(LightBlueSectionCardStyle())
    }
}

struct VitalsTableView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var vitals: [VitalsPoint] = []

    // Sort newest first by recordedAtISO (String is Comparable → fine for KeyPathComparator)
    
    
    // MARK: - Date formatting (ISO8601 -> user-friendly, localized)
    private static let isoParsers: [ISO8601DateFormatter] = {
        // Support both with and without fractional seconds.
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]

        return [f1, f2]
    }()

    private static let displayDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = .current
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()

    private func parseISODate(_ iso: String) -> Date? {
        guard !iso.isEmpty else { return nil }
        for f in Self.isoParsers {
            if let d = f.date(from: iso) { return d }
        }
        return nil
    }

    private func displayRecordedAt(_ iso: String) -> String {
        guard let d = parseISODate(iso) else {
            return iso.isEmpty ? "—" : iso   // fallback if parsing fails
        }
        return Self.displayDateFormatter.string(from: d)
    }

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
                                        Text(displayRecordedAt(item.recordedAtISO))
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
                        
                    }
                }
                .padding(16)
                .lightBlueSectionCardStyle()
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
                vitals.sort { a, b in
                    let da = parseISODate(a.recordedAtISO)
                    let db = parseISODate(b.recordedAtISO)

                    switch (da, db) {
                    case let (x?, y?):
                        return x > y
                    case (_?, nil):
                        return true
                    case (nil, _?):
                        return false
                    default:
                        return a.recordedAtISO > b.recordedAtISO
                    }
                }
            }
        }
    }
}

#Preview {
    VitalsTableView()
        .environmentObject(AppState(clinicianStore: ClinicianStore()))
}
