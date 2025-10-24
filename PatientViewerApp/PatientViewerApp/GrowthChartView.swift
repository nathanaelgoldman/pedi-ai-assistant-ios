import SwiftUI
import Charts
import os

struct GrowthChartView: View {
    let dataPoints: [GrowthDataPoint]
    let referenceCurves: [(label: String, points: [GrowthDataPoint])]
    let measurement: String

    // Logger
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PatientViewerApp",
                                    category: "GrowthChartView")

    // Precomputed domains so we can log and keep body clean
    private var xDom: ClosedRange<Double> { xDomain() }
    private var yDom: ClosedRange<Double> { yDomain() }

    // Default plausible Y ranges per measurement (0–24m; adjust as needed)
    private static let defaultRanges: [String: ClosedRange<Double>] = [
        "weight": 0...20,
        "height": 40...100,
        "head_circ": 30...55
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
                x: .value("Age (months)", point.ageMonths),
                y: .value("Value", point.value)
            )
            .foregroundStyle(.blue)
            .symbolSize(40)
        }

        // WHO reference curves
        ForEach(cleanCurves(), id: \.label) { curve in
            ForEach(Array(curve.points.enumerated()), id: \.offset) { _, refPoint in
                LineMark(
                    x: .value("Age (months)", refPoint.ageMonths),
                    y: .value("Value", refPoint.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(by: .value("Curve", curve.label))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
    }

    var body: some View {
        VStack {
            if hasAnyData {
                Chart {
                    chartContent
                }
                .chartXScale(domain: xDom)
                .chartYScale(domain: yDom)
                .chartXAxisLabel("Age (months)")
                .chartYAxisLabel(yAxisLabel(measurement))
                .onAppear {
                    Self.log.debug("Chart appear: measurement=\(self.measurement, privacy: .public) x=\(self.xDom.lowerBound, privacy: .public)...\(self.xDom.upperBound, privacy: .public) y=\(self.yDom.lowerBound, privacy: .public)...\(self.yDom.upperBound, privacy: .public) points=\(self.cleanData().count, privacy: .public) curves=\(self.cleanCurves().count, privacy: .public)")
                }
                .chartXAxis {
                    AxisMarks(preset: .aligned, values: .stride(by: 1)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let intVal = value.as(Int.self) {
                                Text("\(intVal)")
                            }
                        }
                    }
                }
                .chartYAxis {
                    let yStride: Double = measurement == "height" ? 5.0 : 1.0
                    AxisMarks(preset: .aligned, values: .stride(by: yStride)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel()
                    }
                }
                .frame(height: 300)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .imageScale(.large)
                    Text("No growth data yet")
                        .font(.headline)
                    Text("Add a measurement to see the chart.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(height: 300)
                .onAppear {
                    Self.log.debug("No data to chart for \(self.measurement, privacy: .public)")
                }
            }
        }
        .padding()
        .navigationTitle(titleForMeasurement(measurement))
    }

    private func yDomain() -> ClosedRange<Double> {
        dynamicYRange(
            measurement: measurement,
            dataPoints: cleanData(),
            referenceCurves: cleanCurves()
        )
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

    private func titleForMeasurement(_ m: String) -> String {
        switch m {
        case "weight": return "Weight-for-Age"
        case "height": return "Length-for-Age"
        case "head_circ": return "Head Circumference-for-Age"
        default: return "Growth Chart"
        }
    }
    
    private func yAxisLabel(_ measurement: String) -> String {
        switch measurement {
        case "weight": return "Weight (kg)"
        case "height": return "Length/Height (cm)"
        case "head_circ": return "Head Circumference (cm)"
        default: return "Measurement"
        }
    }
}//
//  GrowthChartView.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/12/25.
//

