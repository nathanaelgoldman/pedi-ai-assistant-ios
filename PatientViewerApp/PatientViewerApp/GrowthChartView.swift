//
//  GrowthChartView.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/12/25.
//

import SwiftUI
import Charts

struct GrowthChartView: View {
    let dataPoints: [GrowthDataPoint]
    let referenceCurves: [(label: String, points: [GrowthDataPoint])]
    let measurement: String

    // Logger
    private static let log = AppLog.feature("GrowthChartView")

    // SupportLog (for user-facing debug export)
    private func mTok(_ m: String) -> String { m } // measurement is not sensitive


    private func SLAsync(_ message: String) {
        Task { @MainActor in
            SupportLog.shared.info(message)
        }
    }

    // Localization helper with fallback (mirrors the PDF generator behavior)
    private func L(_ key: String, _ fallback: String) -> String {
        NSLocalizedString(key, value: fallback, comment: "")
    }

    // Precomputed domains so we can log and keep body clean
    private var xDom: ClosedRange<Double> { xDomain() }
    private var yDom: ClosedRange<Double> { yDomain() }

    // Default plausible Y ranges per measurement (0–24m; adjust as needed)
    private static let defaultRanges: [String: ClosedRange<Double>] = [
        "weight": 0...20,
        "height": 40...100,
        "head_circ": 30...55,
        "bmi": 10...30
    ]

    /// Compute a padded, clamped Y-axis range from patient + reference values.
    private func dynamicYRange(
        measurement: String,
        dataPoints: [GrowthDataPoint],
        referenceCurves: [(label: String, points: [GrowthDataPoint])]
    ) -> ClosedRange<Double> {
        let def = Self.defaultRanges[measurement] ?? 0...100

        // Gather finite values from patient and reference curves
        let patientValues = dataPoints.map(\.value).filter { $0.isFinite }
        let curveValues = referenceCurves.flatMap { $0.points.map(\.value) }.filter { $0.isFinite }
        let all = patientValues + curveValues

        if all.isEmpty {
            Self.log.debug("dynamicYRange: no values; using default \(def.lowerBound, privacy: .public)-\(def.upperBound, privacy: .public) for \(measurement, privacy: .public)")
            return def
        }

        guard let minV = all.min(), let maxV = all.max(), maxV.isFinite, minV.isFinite, maxV > minV else {
            Self.log.debug("dynamicYRange: invalid range; using default \(def.lowerBound, privacy: .public)-\(def.upperBound, privacy: .public) for \(measurement, privacy: .public)")
            return def
        }

        let span = maxV - minV
        let pad = max(span * 0.10, 1.0) // 10% padding, minimum 1 unit
        var lower = floor((minV - pad) * 10) / 10
        var upper = ceil((maxV + pad) * 10) / 10

        // Clamp inside reasonable defaults
        lower = max(lower, def.lowerBound)
        upper = min(upper, def.upperBound)

        // Ensure at least 1 unit height
        if upper - lower < 1 { upper = lower + 1 }

        Self.log.debug("dynamicYRange(\(measurement, privacy: .public)): min=\(minV, privacy: .public) max=\(maxV, privacy: .public) span=\(span, privacy: .public) -> y=\(lower, privacy: .public)...\(upper, privacy: .public)")

        return lower...upper
    }

    // Clean/sanitized datasets (drop any non-finite pairs)
    private func cleanData() -> [GrowthDataPoint] {
        let cleaned = dataPoints.filter { $0.ageMonths.isFinite && $0.value.isFinite }
        Self.log.debug("cleanData: input=\(dataPoints.count, privacy: .public) output=\(cleaned.count, privacy: .public) for \(measurement, privacy: .public)")
        return cleaned
    }

    private func cleanCurves() -> [(label: String, points: [GrowthDataPoint])] {
        let mapped = referenceCurves
            .map { (label: $0.label, points: $0.points.filter { $0.ageMonths.isFinite && $0.value.isFinite }) }
            .filter { !$0.points.isEmpty }
        let totalPoints = mapped.reduce(0) { $0 + $1.points.count }
        Self.log.debug("cleanCurves: curvesIn=\(referenceCurves.count, privacy: .public) curvesOut=\(mapped.count, privacy: .public) pointsOut=\(totalPoints, privacy: .public) for \(measurement, privacy: .public)")
        return mapped
    }

    private var hasAnyData: Bool {
        !cleanData().isEmpty || !cleanCurves().isEmpty
    }

    @ChartContentBuilder
    private var chartContent: some ChartContent {
        // User data
        ForEach(Array(cleanData().enumerated()), id: \.offset) { _, point in
            PointMark(
                x: .value(L("patient_viewer.growth_chart.axis.age_months", "Age (months)"), point.ageMonths),
                y: .value(L("patient_viewer.growth_chart.axis.value", "Value"), point.value)
            )
            .foregroundStyle(.blue)
            .symbolSize(40)
        }

        // WHO reference curves
        ForEach(cleanCurves(), id: \.label) { curve in
            ForEach(Array(curve.points.enumerated()), id: \.offset) { _, refPoint in
                LineMark(
                    x: .value(L("patient_viewer.growth_chart.axis.age_months", "Age (months)"), refPoint.ageMonths),
                    y: .value(L("patient_viewer.growth_chart.axis.value", "Value"), refPoint.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(by: .value(L("patient_viewer.growth_chart.axis.curve", "Curve"), curve.label))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasAnyData {
                ZStack {
                    // Keep the chart itself on a white card so the app's blue theme
                    // doesn't tint the plot/axes area.
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                        .fill(Color(.systemBackground))

                    Chart {
                        chartContent
                    }
                    // NOTE: Y-domain is intentionally controlled by the parent (GrowthChartScreen)
                    // so the screen can adapt the vertical range to the window/device.
                    .chartXScale(domain: xDom)
                    .chartScrollableAxes(.horizontal)
                    .chartXVisibleDomain(length: 24)
                    .chartPlotStyle { plotArea in
                        plotArea
                            // Small visual breathing room so “0 month” and the first gridline aren’t clipped.
                            .padding(.leading, 18)
                    }
                    .chartXAxisLabel(L("patient_viewer.growth_chart.axis.age_months", "Age (months)"))
                    .chartYAxisLabel(yAxisLabel(measurement))
                    .onAppear {
                        Self.log.debug("Chart appear measurement=\(self.measurement, privacy: .public)")
                        Self.log.debug(
                            "xFull=\(self.xDom.lowerBound, privacy: .public)...\(self.xDom.upperBound, privacy: .public)"
                        )
                        Self.log.debug(
                            "xVisible=\(self.xVisibleDom.lowerBound, privacy: .public)...\(self.xVisibleDom.upperBound, privacy: .public)"
                        )
                        Self.log.debug(
                            "points=\(self.cleanData().count, privacy: .public) curves=\(self.cleanCurves().count, privacy: .public)"
                        )
                        SLAsync("GCV appear | m=\(self.mTok(self.measurement)) pts=\(self.cleanData().count) curves=\(self.cleanCurves().count)")
                    }
                    .chartXAxis {
                        AxisMarks(preset: .aligned, values: .stride(by: 1)) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let intVal = value.as(Int.self), intVal % 2 == 0 {
                                    Text("\(intVal)")
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(preset: .aligned,
                                  values: .stride(by: yStrideForMeasurement(measurement))) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel()
                        }
                    }
                    // ✅ IMPORTANT: let the parent decide the height.
                    // This allows GrowthChartScreen (with the segmented control) to “push” the chart
                    // into available space without overlap on iPhone/Mac.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                        .stroke(AppTheme.cardStroke, lineWidth: 0.8)
                )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                        .fill(Color(.systemBackground))

                    VStack(spacing: 8) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .imageScale(.large)
                        Text(L("patient_viewer.growth_chart.empty.title", "No growth data"))
                            .font(.headline)
                        Text(L("patient_viewer.growth_chart.empty.message", "No patient measurements available for this chart."))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                        .stroke(AppTheme.cardStroke, lineWidth: 0.8)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    Self.log.debug("No data to chart for \(self.measurement, privacy: .public)")
                    SLAsync("GCV empty | m=\(self.mTok(self.measurement))")
                }
            }
        }
        // Avoid wasting vertical space; keep horizontal padding for readability.
        .padding(.horizontal)
        .padding(.vertical, 8)
        .navigationTitle(titleForMeasurement(measurement))
        .onChange(of: measurement) { oldValue, newValue in
            // SwiftUI may reuse the same view instance when the measurement changes,
            // so onAppear won't fire again. Log the switch explicitly.
            SLAsync("GCV measurement change | from=\(self.mTok(oldValue)) to=\(self.mTok(newValue))")
        }
        .onDisappear {
            SLAsync("GCV disappear | m=\(self.mTok(self.measurement))")
        }
    }

    private func yDomain() -> ClosedRange<Double> {
        dynamicYRange(
            measurement: measurement,
            dataPoints: cleanData(),
            referenceCurves: cleanCurves()
        )
    }
    
    private func yStrideForMeasurement(_ measurement: String) -> Double {
        switch measurement {
        case "height":
            return 5.0       // 5 cm steps
        case "weight", "head_circ":
            return 2.0       // 2 kg / 2 cm steps
        case "bmi":
            return 1.0       // BMI steps
        default:
            return 1.0       // fallback
        }
    }

    private func xDomain() -> ClosedRange<Double> {
        let agesFromData = cleanData().map(\.ageMonths)
        let agesFromCurves = cleanCurves().flatMap { $0.points.map(\.ageMonths) }
        let allAges = agesFromData + agesFromCurves
        guard let min = allAges.min(), let max = allAges.max(), min.isFinite, max.isFinite else {
            Self.log.debug("xDomain: no finite ages; using default 0...24 for \(measurement, privacy: .public)")
            return 0...24
        }
        let paddedMin = Swift.max(0, min - 1)
        var paddedMax = Swift.min(max + 1, 60)
        if paddedMax - paddedMin < 1 { paddedMax = paddedMin + 1 }
        let domain = paddedMin...paddedMax
        Self.log.debug("xDomain computed: \(domain.lowerBound, privacy: .public)...\(domain.upperBound, privacy: .public) for \(measurement, privacy: .public)")
        return domain
    }
    
    private var xVisibleDom: ClosedRange<Double> {
        let lower = xDom.lowerBound
        // Start with at most 24 months visible; user can scroll further.
        let upper = min(xDom.upperBound, 24)
        return lower...upper
    }

    private func titleForMeasurement(_ m: String) -> String {
        switch m {
        case "weight":
            return L("patient_viewer.growth_chart.title.weight_for_age", "Weight-for-Age (0–60m)")
        case "height":
            return L("patient_viewer.growth_chart.title.length_for_age", "Length-for-Age (0–60m)")
        case "head_circ":
            return L("patient_viewer.growth_chart.title.head_circumference_for_age", "Head Circumference-for-Age (0–60m)")
        case "bmi":
            return L("patient_viewer.growth_chart.title.bmi_for_age", "BMI-for-Age (0–60m)")
        default:
            return L("patient_viewer.growth_chart.title.generic", "Growth chart")
        }
    }
    
    private func yAxisLabel(_ measurement: String) -> String {
        switch measurement {
        case "weight":
            return L("patient_viewer.growth_chart.y_axis.weight", "Weight (kg)")
        case "height":
            return L("patient_viewer.growth_chart.y_axis.height", "Length/Height (cm)")
        case "head_circ":
            return L("patient_viewer.growth_chart.y_axis.head_circ", "Head circumference (cm)")
        case "bmi":
            return L("patient_viewer.growth_chart.y_axis.bmi", "BMI")
        default:
            return L("patient_viewer.growth_chart.y_axis.generic", "Value")
        }
    }
}
