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
    @State private var whoCurves: [(label: String, points: [PlotPoint])] = []
    @State private var birthDate: Date? = nil

    private let log = Logger(subsystem: "DrsMainApp", category: "GrowthChartView")

    enum Tab: String, CaseIterable, Identifiable {
        case weight
        case height
        case hc

        var id: String { rawValue }

        /// Title used in the segmented control and y-axis label
        var localizedTitle: String {
            switch self {
            case .weight:
                return NSLocalizedString(
                    "growth.charts.tab.weight",
                    comment: "Segment title for weight chart tab"
                )
            case .height:
                return NSLocalizedString(
                    "growth.charts.tab.height",
                    comment: "Segment title for height/length chart tab"
                )
            case .hc:
                return NSLocalizedString(
                    "growth.charts.tab.hc",
                    comment: "Segment title for head circumference chart tab"
                )
            }
        }

        /// Label for the y-axis
        var localizedYAxisLabel: String {
            // For now we reuse the same text as the tab title
            localizedTitle
        }
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
                Picker(
                    NSLocalizedString(
                        "growth.charts.picker.label",
                        comment: "Accessibility label for growth chart type picker"
                    ),
                    selection: $selectedTab
                ) {
                    ForEach(Tab.allCases) { t in
                        Text(t.localizedTitle).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                let series = makeSeries(points: points, tab: selectedTab)
                if series.isEmpty {
                    Text(
                        NSLocalizedString(
                            "growth.charts.empty",
                            comment: "Shown when there is no data to plot for the current growth chart"
                        )
                    )
                    .foregroundStyle(.secondary)
                    .padding()
                } else {
                    if let bd = birthDate {
                        Chart {
                            // Patient data (points only; no connecting lines)
                            ForEach(series) { p in
                                PointMark(
                                    x: .value(
                                        NSLocalizedString(
                                            "growth.charts.axis.x.age-short",
                                            comment: "X-axis dimension label for age in months (short form)"
                                        ),
                                        monthsBetween(bd, p.date)
                                    ),
                                    y: .value(selectedTab.localizedYAxisLabel, p.value)
                                )
                                .zIndex(2)
                            }
                            // WHO reference overlays
                            ForEach(whoCurves, id: \.label) { curve in
                                ForEach(curve.points) { q in
                                    LineMark(
                                        x: .value(
                                            NSLocalizedString(
                                                "growth.charts.axis.x.age-short",
                                                comment: "X-axis dimension label for age in months (short form)"
                                            ),
                                            monthsBetween(bd, q.date)
                                        ),
                                        y: .value(
                                            NSLocalizedString(
                                                "growth.charts.axis.y.value",
                                                comment: "Generic y-axis dimension label for WHO reference curves"
                                            ),
                                            q.value
                                        )
                                    )
                                    .foregroundStyle(by: .value("WHO", curve.label))
                                    .interpolationMethod(.monotone)
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                                    .opacity(0.9)
                                    .zIndex(1)
                                }
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                                AxisGridLine()
                                AxisTick()
                                AxisValueLabel {
                                    if let v = value.as(Double.self) {
                                        Text(String(format: "%.0f", v))
                                    }
                                }
                            }
                        }
                        .chartYAxis { AxisMarks() }
                        .chartLegend(position: .top, alignment: .leading, spacing: 8)
                        .chartXAxisLabel(
                            NSLocalizedString(
                                "growth.charts.axis.x.age-long",
                                comment: "X-axis label: Age in months"
                            )
                        )
                        .chartYAxisLabel(selectedTab.localizedYAxisLabel)
                        .padding(.horizontal)
                        .frame(minHeight: 360)
                    } else {
                        // Fallback to date axis if DOB is unknown
                        Chart {
                            ForEach(series) { p in
                                PointMark(
                                    x: .value(
                                        NSLocalizedString(
                                            "growth.charts.axis.x.date-dimension",
                                            comment: "X-axis dimension label for date-based growth chart"
                                        ),
                                        p.date
                                    ),
                                    y: .value(selectedTab.localizedYAxisLabel, p.value)
                                )
                                .zIndex(2)
                            }
                            ForEach(whoCurves, id: \.label) { curve in
                                ForEach(curve.points) { q in
                                    LineMark(
                                        x: .value(
                                            NSLocalizedString(
                                                "growth.charts.axis.x.date-dimension",
                                                comment: "X-axis dimension label for date-based growth chart"
                                            ),
                                            q.date
                                        ),
                                        y: .value(
                                            NSLocalizedString(
                                                "growth.charts.axis.y.value",
                                                comment: "Generic y-axis dimension label for WHO reference curves"
                                            ),
                                            q.value
                                        )
                                    )
                                    .foregroundStyle(by: .value("WHO", curve.label))
                                    .interpolationMethod(.monotone)
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                                    .opacity(0.9)
                                    .zIndex(1)
                                }
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                                AxisGridLine()
                                AxisTick()
                                AxisValueLabel(format: .dateTime.year().month().day())
                            }
                        }
                        .chartYAxis { AxisMarks() }
                        .chartLegend(position: .top, alignment: .leading, spacing: 8)
                        .chartXAxisLabel(
                            NSLocalizedString(
                                "growth.charts.axis.x.date-label",
                                comment: "X-axis label: Date"
                            )
                        )
                        .chartYAxisLabel(selectedTab.localizedYAxisLabel)
                        .padding(.horizontal)
                        .frame(minHeight: 360)
                    }
                }
            }
            .navigationTitle(
                NSLocalizedString(
                    "growth.charts.nav.title",
                    comment: "Navigation title for growth charts window"
                )
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        NSLocalizedString(
                            "generic.button.close",
                            comment: "Close button title"
                        )
                    ) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        NSLocalizedString(
                            "generic.button.refresh",
                            comment: "Refresh button title"
                        )
                    ) {
                        reloadData()
                    }
                }
            }
            .onAppear {
                reloadData()
                reloadWHO()
            }
            .onChange(of: selectedTab) { _, _ in
                reloadWHO()
            }
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

        // Resolve patient's DOB so we can plot age (months) on the x-axis
        do {
            let sqlDOB = "SELECT dob FROM patients WHERE id=? LIMIT 1;"
            var stmtDOB: OpaquePointer?
            defer { sqlite3_finalize(stmtDOB) }
            if sqlite3_prepare_v2(db, sqlDOB, -1, &stmtDOB, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmtDOB, 1, sqlite3_int64(pid))
                if sqlite3_step(stmtDOB) == SQLITE_ROW, let c = sqlite3_column_text(stmtDOB, 0) {
                    let s = String(cString: c)
                    self.birthDate = parseDate(s)
                }
            }
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

        // --- Add perinatal points: birth (weight/length/HC) and discharge (weight) ---
        do {
            let sqlPH = """
            SELECT p.dob,
                   ph.birth_weight_g,
                   ph.birth_length_cm,
                   ph.birth_head_circumference_cm,
                   ph.maternity_discharge_date,
                   ph.discharge_weight_g
            FROM patients p
            LEFT JOIN perinatal_history ph ON ph.patient_id = p.id
            WHERE p.id = ?
            LIMIT 1;
            """
            var stmt2: OpaquePointer?
            defer { sqlite3_finalize(stmt2) }
            if sqlite3_prepare_v2(db, sqlPH, -1, &stmt2, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt2, 1, sqlite3_int64(pid))
                if sqlite3_step(stmt2) == SQLITE_ROW {

                    // Parse DOB (birth date)
                    var birthDate: Date? = nil
                    if let c0 = sqlite3_column_text(stmt2, 0) {
                        let s = String(cString: c0)
                        birthDate = parseDate(s)
                    }

                    // Birth values
                    let birthWeightKg: Double? = (sqlite3_column_type(stmt2, 1) == SQLITE_NULL) ? nil : sqlite3_column_double(stmt2, 1) / 1000.0
                    let birthLenCm:   Double? = (sqlite3_column_type(stmt2, 2) == SQLITE_NULL) ? nil : sqlite3_column_double(stmt2, 2)
                    let birthHcCm:    Double? = (sqlite3_column_type(stmt2, 3) == SQLITE_NULL) ? nil : sqlite3_column_double(stmt2, 3)

                    // Discharge date & weight
                    var dischargeDate: Date? = nil
                    if sqlite3_column_type(stmt2, 4) != SQLITE_NULL, let c4 = sqlite3_column_text(stmt2, 4) {
                        dischargeDate = parseDate(String(cString: c4))
                    }
                    let dischargeWeightKg: Double? = (sqlite3_column_type(stmt2, 5) == SQLITE_NULL) ? nil : sqlite3_column_double(stmt2, 5) / 1000.0

                    // Append birth point if we have any birth metric
                    if let bd = birthDate, (birthWeightKg != nil || birthLenCm != nil || birthHcCm != nil) {
                        rows.append(DBPoint(
                            recordedAt: bd,
                            weightKg: birthWeightKg,
                            heightCm: birthLenCm,
                            headCircumferenceCm: birthHcCm
                        ))
                    }

                    // Append discharge weight point if present
                    if let dd = dischargeDate, let dw = dischargeWeightKg {
                        rows.append(DBPoint(
                            recordedAt: dd,
                            weightKg: dw,
                            heightCm: nil,
                            headCircumferenceCm: nil
                        ))
                    }
                }
            } else {
                let msg = String(cString: sqlite3_errmsg(db))
                log.error("Perinatal fetch prepare failed: \(msg, privacy: .public)")
            }
        }

        // Now publish
        self.points = rows.sorted(by: { $0.recordedAt < $1.recordedAt })
        log.info("Fetched \(self.points.count) growth rows from DB (incl. perinatal)")
    }

    private func monthsBetween(_ from: Date, _ to: Date) -> Double {
        let seconds = to.timeIntervalSince(from)
        let days = seconds / 86_400.0
        // Average Gregorian month length:
        return days / 30.437
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

    // MARK: - WHO reference loading (real implementation)
    private func reloadWHO() {
        whoCurves = []

        // Need patient sex and DOB
        guard let patient = appState.selectedPatient else { return }
        let sexCode = (patient.sex.uppercased() == "F") ? "F" : "M"

        // Determine resource base by tab
        let resourceBase: String
        switch selectedTab {
        case .weight: resourceBase = "wfa_0_24m_\(sexCode)"   // weight-for-age
        case .height: resourceBase = "lhfa_0_24m_\(sexCode)"  // length/height-for-age
        case .hc:     resourceBase = "hcfa_0_24m_\(sexCode)"  // head circumference-for-age
        }

        // Resolve patient DOB to align WHO months on the date axis
        guard let dbURL = appState.currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else { return }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return
        }
        defer { sqlite3_close(db) }

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

        var dob: Date?
        do {
            let sql = "SELECT dob FROM patients WHERE id=? LIMIT 1;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, sqlite3_int64(patient.id))
                if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
                    dob = parseDate(String(cString: c))
                }
            }
        }
        guard let birthDate = dob else { return }

        // Load WHO CSV from bundle. Try multiple locations/casings to be robust.
        guard let url = findWHOResource(named: resourceBase),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            log.error("WHO CSV not found for base \(resourceBase, privacy: .public). Checked common locations/casings.")
            return
        }

        let lines = text
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: CharacterSet.whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        guard !lines.isEmpty else { return }

        // Parse header to find age and percentile/SD columns
        let header = lines[0]
        let sep: Character = header.contains(";") ? ";" : ","
        let headers = header
            .split(separator: sep)
            .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }

        // Age column can appear as "age (months)", "age_months", "months", or just "age"
        let ageIdx = headers.firstIndex(where: { h in
            h.contains("month") || h == "age" || h == "age (months)" || h == "months"
        }) ?? 0

        // Build a list of percentile/SD columns that exist in this CSV.
        // We support common WHO headers like: m (median), p3, p15, p50, p85, p97,
        // or SD bands like sd-2, sd-1, sd0, sd1, sd2, and variants.
        func labelForHeader(_ h: String) -> String? {
            let h0 = h.replacingOccurrences(of: " ", with: "").lowercased()
            // direct percentiles
            if h0 == "m" || h0.contains("median") || h0 == "p50" || h0.contains("p0.50") || h0.contains("p0_50") {
                return "p50"
            }
            if h0.contains("p3")  { return "p3" }
            if h0.contains("p15") { return "p15" }
            if h0.contains("p85") { return "p85" }
            if h0.contains("p97") { return "p97" }
            // SD bands
            if h0.contains("sd-2") || h0.contains("-2sd") || h0 == "z-2" { return "-2SD" }
            if h0.contains("sd-1") || h0.contains("-1sd") || h0 == "z-1" { return "-1SD" }
            if h0.contains("sd0")  || h0.contains("0sd")  || h0 == "z0"  { return "0SD" }
            if h0.contains("sd1")  || h0.contains("+1sd") || h0 == "z1"  { return "+1SD" }
            if h0.contains("sd2")  || h0.contains("+2sd") || h0 == "z2"  { return "+2SD" }
            return nil
        }

        var valueCols: [(label: String, idx: Int)] = []
        for (i, h) in headers.enumerated() {
            if i == ageIdx { continue }
            if let label = labelForHeader(h) {
                valueCols.append((label, i))
            }
        }
        // If nothing matched, fallback to the second column as median/p50
        if valueCols.isEmpty, headers.count > 1 {
            valueCols = [("p50", 1)]
        }

        // Desired display order
        let order: [String: Int] = [
            "p3": 0, "-2SD": 1,
            "p15": 2, "-1SD": 3,
            "p50": 4, "0SD": 4,
            "p85": 5, "+1SD": 6,
            "p97": 7, "+2SD": 8
        ]

        // Accumulate series
        var series: [String: [PlotPoint]] = [:]
        for (label, _) in valueCols { series[label] = [] }

        for line in lines.dropFirst() {
            let cols = line
                .split(separator: sep)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard cols.indices.contains(ageIdx), let months = Double(cols[ageIdx]) else { continue }
            let dt = dateByAddingMonths(from: birthDate, months: months)

            for (label, i) in valueCols {
                guard cols.indices.contains(i), let v = Double(cols[i]) else { continue }
                series[label, default: []].append(PlotPoint(date: dt, value: v))
            }
        }

        // Publish sorted curves
        whoCurves = series
            .map { (label: $0.key, points: $0.value.sorted(by: { $0.date < $1.date })) }
            .sorted { (a, b) in
                let ra = order[a.label] ?? 999
                let rb = order[b.label] ?? 999
                if ra != rb { return ra < rb }
                return a.label < b.label
            }
    }

    /// Try to find a WHO CSV named `<base>.csv` in common bundle locations.
    /// We try both lower/upper-case sex suffixes and several subdirectories.
    private func findWHOResource(named base: String) -> URL? {
        // Try the provided base and an uppercase/lowercase fallback for sex suffix
        var candidates: [String] = [base]
        if base.hasSuffix("_m") {
            candidates.append(String(base.dropLast()) + "M")
        } else if base.hasSuffix("_f") {
            candidates.append(String(base.dropLast()) + "F")
        } else if base.hasSuffix("_M") {
            candidates.append(String(base.dropLast()) + "m")
        } else if base.hasSuffix("_F") {
            candidates.append(String(base.dropLast()) + "f")
        }

        let subdirs: [String?] = [
            "WHO",
            "Resources/WHO",
            "Util/WHO",
            nil
        ]

        for name in candidates {
            for sub in subdirs {
                if let url = Bundle.main.url(forResource: name, withExtension: "csv", subdirectory: sub) {
                    return url
                }
            }
        }
        // Try uppercase extension .CSV as fallback
        for name in candidates {
            for sub in subdirs {
                if let url = Bundle.main.url(forResource: name, withExtension: "CSV", subdirectory: sub) {
                    return url
                }
            }
        }
        return nil
    }

    private func dateByAddingMonths(from start: Date, months: Double) -> Date {
        // split months into whole + fractional
        let whole = Int(floor(months))
        let frac  = months - Double(whole)
        let cal = Calendar(identifier: .iso8601)
        let step = cal.date(byAdding: .month, value: whole, to: start) ?? start
        // approx fractional month as 30.437 days (Gregorian average)
        return cal.date(byAdding: .day, value: Int(frac * 30.437), to: step) ?? step
    }
}
