//
//  GrowthChartRenderer.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/13/25.
//

import Foundation
import SwiftUI
import Charts
import UIKit

struct GrowthChartRenderer {
    // Shared Y-axis defaults and dynamic clamping/padding used by renderer.
    private static let defaultRanges: [String: ClosedRange<Double>] = [
        "weight": 0...20,     // kg (0–24m)
        "height": 40...100,   // cm (0–24m)
        "head_circ": 30...55  // cm (0–24m)
    ]

    private static func dynamicYRange(
        measurement: String,
        patientValues: [Double],
        referenceValues: [Double]
    ) -> ClosedRange<Double> {
        // Combine and ensure finite values only.
        let all = (patientValues + referenceValues).filter { $0.isFinite }

        // If nothing to go on, fall back to defaults for the measurement.
        guard let minVal = all.min(), let maxVal = all.max(),
              minVal.isFinite, maxVal.isFinite else {
            return defaultRanges[measurement] ?? 0...100
        }

        // Compute padded span with minimum width to avoid a flat line.
        let span = max(maxVal - minVal, 1.0)
        let pad = max(span * 0.10, 1.0)
        var lower = minVal - pad
        var upper = maxVal + pad

        // Clamp to sensible defaults so axis never explodes or goes negative.
        let defaults = defaultRanges[measurement] ?? 0...100
        lower = max(lower, defaults.lowerBound)
        upper = min(upper, defaults.upperBound)

        // Guarantee at least a 1.0 unit vertical domain.
        if upper - lower < 1.0 {
            upper = lower + 1.0
        }

        return lower...upper
    }
    static func generateChartImage(
        dbPath: String,
        patientID: Int64,
        measurement: String,
        sex: String,
        filename: String
    ) async -> UIImage? {
        // These loaders are synchronous — no 'await' needed here.
        let refCurves = WhoReferenceLoader.loadCurve(fromCSV: filename, sex: sex)
        let patientData = GrowthDataFetcher.fetchGrowthData(
            dbPath: dbPath,
            patientID: patientID,
            measurement: measurement
        )

        // Filter out any non-finite (NaN/±Inf) values from both sources before plotting.
        let cleanPatient = patientData.filter { $0.ageMonths.isFinite && $0.value.isFinite }

        // Determine Y-axis domain dynamically (patient + reference), padded and clamped to defaults.
        let patientValues = cleanPatient.map(\.value).filter { $0.isFinite }
        let referenceValues = refCurves
            .flatMap { $0.points.map(\.value) }
            .filter { $0.isFinite }
        let yRange = Self.dynamicYRange(
            measurement: measurement,
            patientValues: patientValues,
            referenceValues: referenceValues
        )

        // Compute X-axis max from BOTH patient and reference curves (with non-finite values filtered).
        let patientMaxAge = cleanPatient.map(\.ageMonths).filter { $0.isFinite }.max() ?? 0
        let curveMaxAge = refCurves
            .flatMap { $0.points.map(\.ageMonths) }
            .filter { $0.isFinite }
            .max() ?? 0
        let bestMax = max(patientMaxAge, curveMaxAge)
        // Clamp to 0...24 months with a small padding; if no data, default to 24.
        let paddedMaxAge = (bestMax > 0) ? min(bestMax + 1.0, 24) : 24

        // Debug output (optional)
        print("[DEBUG] patientData count: \(patientData.count)")
        print("[DEBUG] cleanPatient count: \(cleanPatient.count)")
        print("[DEBUG] refCurves count: \(refCurves.count)")
        print("[DEBUG] paddedMaxAge: \(paddedMaxAge)")

        // Build the Chart and render on the main actor so all @MainActor-isolated
        // view modifiers (e.g., .chartLegend) are called on the correct actor.
        let image: UIImage? = await MainActor.run {
            let chartContent = Chart {
                // Reference Curves (filtered inside the loop)
                ForEach(refCurves, id: \.label) { curve in
                    let points = curve.points.filter { $0.ageMonths.isFinite && $0.value.isFinite }
                    ForEach(points, id: \.ageMonths) { point in
                        LineMark(
                            x: .value("Age (months)", point.ageMonths),
                            y: .value("Value", point.value)
                        )
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        .opacity(0.7)
                    }
                    .foregroundStyle(by: .value("Percentile", curve.label))
                }

                // Patient Data
                ForEach(cleanPatient, id: \.ageMonths) { point in
                    PointMark(
                        x: .value("Age (months)", point.ageMonths),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(.blue)
                    .symbolSize(40)
                }
            }
            .chartXScale(domain: 0...paddedMaxAge)
            .chartYScale(domain: yRange)
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: 1)) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                }
            }
            .chartXAxis {
                AxisMarks(position: .bottom, values: .stride(by: 1)) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                }
            }
            .chartXAxisLabel("Age (months)")
            .chartYAxisLabel(measurement.capitalized)
            .chartLegend(.visible)

            let chartView = ZStack {
                chartContent
            }
            .frame(width: 1400, height: 1000)
            .background(Color.white)

            let renderer = ImageRenderer(content: chartView)
            renderer.scale = 1.0
            renderer.proposedSize = ProposedViewSize(width: 1400, height: 1000)
            return renderer.uiImage
        }

        return image
    }
}
