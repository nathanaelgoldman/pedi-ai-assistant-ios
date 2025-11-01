//
//  GrowthChartView.swift
//  DrsMainApp
//
//  Created by yunastic on 11/1/25.
//

import SwiftUI
import Charts
import OSLog
import SQLite3

struct GrowthChartView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var points: [DBPoint] = []
    @State private var selectedTab: Tab = .weight

    private let log = Logger(subsystem: "DrsMainApp", category: "GrowthChartView")

    enum Tab: String, CaseIterable, Identifiable {
        case weight = "Weight"
        case height = "Height"
        case hc     = "Head Circ."
        var id: String { rawValue }
    }

    // Local plotting model for Charts
    struct PlotPoint: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
    }

    // Raw row fetched from DB (manual_growth + vitals)
    struct DBPoint: Identifiable {
        let id = UUID()
        let recordedAt: Date
        let weightKg: Double?
        let heightCm: Double?
        let headCircumferenceCm: Double?
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Chart", selection: $selectedTab) {
                    ForEach(Tab.allCases) { t in Text(t.rawValue).tag(t) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                let series = makeSeries(points: points, tab: selectedTab)
                if series.isEmpty {
                    Text("No \(selectedTab.rawValue.lowercased()) data to plot.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    Chart(series) { p in
                        LineMark(
                            x: .value("Date", p.date),
                            y: .value(selectedTab.rawValue, p.value)
                        )
                        PointMark(
                            x: .value("Date", p.date),
                            y: .value(selectedTab.rawValue, p.value)
                        )
                    }
                    .chartXAxisLabel("Date")
                    .chartYAxisLabel(selectedTab.rawValue)
                    .padding(.horizontal)
                    .frame(minHeight: 360)
                }
            }
            .navigationTitle("Growth Charts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Refresh") { reloadData() }
                }
            }
            .onAppear { reloadData() }
            .frame(minWidth: 720, minHeight: 520)
        }
    }

    private func reloadData() {
        guard let pid = appState.selectedPatientID else { return }
        guard let dbURL = appState.currentDBURL, FileManager.default.fileExists(atPath: dbURL.path) else {
            self.points = []
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            self.points = []
            return
        }
        defer { sqlite3_close(db) }

        // Union manual_growth and vitals with aligned columns
        let sql = """
        SELECT recorded_at, weight_kg, height_cm, head_circumference_cm
        FROM manual_growth
        WHERE patient_id = ?
        UNION ALL
        SELECT recorded_at, weight_kg, height_cm, head_circumference_cm
        FROM vitals
        WHERE patient_id = ?
        ORDER BY recorded_at ASC;
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            log.error("Growth prepare failed: \(msg, privacy: .public)")
            self.points = []
            return
        }

        sqlite3_bind_int64(stmt, 1, sqlite3_int64(pid))
        sqlite3_bind_int64(stmt, 2, sqlite3_int64(pid))

        var rows: [DBPoint] = []

        let iso = ISO8601DateFormatter()
        let dmy = DateFormatter()
        dmy.calendar = Calendar(identifier: .iso8601)
        dmy.locale = Locale(identifier: "en_US_POSIX")
        dmy.dateFormat = "yyyy-MM-dd"

        func parseDate(_ s: String) -> Date? {
            if let d = iso.date(from: s) { return d }
            if let d = dmy.date(from: s) { return d }
            return nil
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            // recorded_at TEXT
            var recDate: Date = Date()
            if let c0 = sqlite3_column_text(stmt, 0) {
                let s = String(cString: c0)
                if let d = parseDate(s) { recDate = d }
            }

            // Doubles or nulls
            let w: Double? = (sqlite3_column_type(stmt, 1) == SQLITE_NULL) ? nil : sqlite3_column_double(stmt, 1)
            let h: Double? = (sqlite3_column_type(stmt, 2) == SQLITE_NULL) ? nil : sqlite3_column_double(stmt, 2)
            let hc: Double? = (sqlite3_column_type(stmt, 3) == SQLITE_NULL) ? nil : sqlite3_column_double(stmt, 3)

            rows.append(DBPoint(recordedAt: recDate, weightKg: w, heightCm: h, headCircumferenceCm: hc))
        }

        self.points = rows
        log.info("Fetched \(self.points.count) growth rows from DB")
    }

    private func makeSeries(points: [DBPoint], tab: Tab) -> [PlotPoint] {
        switch tab {
        case .weight:
            return points.compactMap { p in
                guard let v = p.weightKg else { return nil }
                return PlotPoint(date: p.recordedAt, value: v)
            }
        case .height:
            return points.compactMap { p in
                guard let v = p.heightCm else { return nil }
                return PlotPoint(date: p.recordedAt, value: v)
            }
        case .hc:
            return points.compactMap { p in
                guard let v = p.headCircumferenceCm else { return nil }
                return PlotPoint(date: p.recordedAt, value: v)
            }
        }
    }
    }
