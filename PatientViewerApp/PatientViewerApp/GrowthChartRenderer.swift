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
import OSLog

struct GrowthChartRenderer {
    // Shared Y-axis defaults and dynamic clamping/padding used by renderer.
    private static let defaultRanges: [String: ClosedRange<Double>] = [
        "weight": 0...26,     // kg (0–24m)
        "height": 40...120,   // cm (0–24m)
        "head_circ": 30...55  // cm (0–24m)
    ]

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "PatientViewerApp",
        category: "GrowthChartRenderer"
    )

    private static func dynamicYRange(
        measurement: String,
        patientValues: [Double],
        referenceValues: [Double]
    ) -> ClosedRange<Double> {
        // Combine and ensure finite values only.
        let all = (patientValues + referenceValues).filter { $0.isFinite }

        // If nothing to go on, fall back to defaults for the measurement.
        if let minVal = all.min(), let maxVal = all.max(), minVal.isFinite, maxVal.isFinite {
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

            Self.logger.debug("Y-range for \(measurement, privacy: .public) computed as \(lower, privacy: .public)-\(upper, privacy: .public)")
            return lower...upper
        } else {
            let defaults = defaultRanges[measurement] ?? 0...100
            Self.logger.notice("No finite values for \(measurement, privacy: .public); using defaults \(defaults.lowerBound, privacy: .public)-\(defaults.upperBound, privacy: .public)")
            return defaults
        }
    }
    static func generateChartImage(
        dbPath: String,
        patientID: Int64,
        measurement: String,
        sex: String,
        filename: String,
        maxAgeMonths: Double? = nil
    ) async -> UIImage? {
        Self.logger.info("Render start: measurement=\(measurement, privacy: .public), patientID=\(patientID, privacy: .public), sex=\(sex, privacy: .public), csv=\(filename, privacy: .public)")
        // These loaders are synchronous — no 'await' needed here.
        let refCurves = WhoReferenceLoader.loadCurve(fromCSV: filename, sex: sex)
        let patientData = GrowthDataFetcher.fetchGrowthData(
            dbPath: dbPath,
            patientID: patientID,
            measurement: measurement
        )

        // Filter out any non-finite (NaN/±Inf) values from both sources before plotting.
        let cleanPatientAll = patientData.filter { $0.ageMonths.isFinite && $0.value.isFinite }

        // Apply optional age cutoff (used by PDF renderer to stop at visit age with a small tolerance).
        let ageTolerance = 0.1
        let cleanPatient: [GrowthDataPoint]
        if let cutoff = maxAgeMonths {
            cleanPatient = cleanPatientAll.filter { $0.ageMonths <= cutoff + ageTolerance }
            if cleanPatient.isEmpty && !cleanPatientAll.isEmpty {
                Self.logger.notice("All patient points for \(measurement, privacy: .public) are after cutoff ageMonths=\(cutoff, privacy: .public); none will be plotted for this chart.")
            }
        } else {
            cleanPatient = cleanPatientAll
        }

        if cleanPatient.isEmpty {
            Self.logger.notice("No patient points to plot for \(measurement, privacy: .public) (after cutoff/filtering)")
        }

        // Determine Y-axis domain dynamically (patient + reference), padded and clamped to defaults.
        let patientValues = cleanPatient.map(\.value).filter { $0.isFinite }
        let referenceValues = refCurves
            .flatMap { $0.points.map(\.value) }
            .filter { $0.isFinite }
        let totalRefPoints = refCurves.reduce(0) { $0 + $1.points.count }
        if totalRefPoints == 0 {
            Self.logger.notice("No reference curve points loaded for \(measurement, privacy: .public)")
        }
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

        // Clamp to 0...60 months with a small padding; if no data, default to 60.
        let maxDomainMonths: Double = 60
        let paddedMaxAge: Double
        if bestMax > 0 {
            // A little padding, but never beyond 60 months.
            paddedMaxAge = min(bestMax + 1.0, maxDomainMonths)
        } else {
            paddedMaxAge = maxDomainMonths
        }

        // If both patient and reference are empty, render a placeholder image instead of attempting to chart.
        if cleanPatient.isEmpty && totalRefPoints == 0 {
            Self.logger.notice("No data available to render for \(measurement, privacy: .public). Returning placeholder image.")
            return await MainActor.run {
                let placeholder = ZStack {
                    Color.white
                    VStack(spacing: 12) {
                        Text("No \(measurement.capitalized) data available")
                            .font(.title2)
                            .bold()
                        Text("Add measurements to see the chart.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }
                .frame(width: 1400, height: 1200)

                let renderer = ImageRenderer(content: placeholder)
                renderer.scale = 1.0
                renderer.proposedSize = ProposedViewSize(width: 1400, height: 1200)
                return renderer.uiImage
            }
        }

        // Debug output (optional)
        Self.logger.debug("patientData.count=\(patientData.count, privacy: .public)")
        Self.logger.debug("cleanPatient.count=\(cleanPatient.count, privacy: .public)")
        Self.logger.debug("refCurves.count=\(refCurves.count, privacy: .public)")
        Self.logger.debug("paddedMaxAge=\(paddedMaxAge, privacy: .public)")

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
                switch measurement {
                case "weight":
                    // label/grid every 2 kg
                    AxisMarks(position: .leading, values: .stride(by: 2))
                case "height":
                    // label/grid every 5 cm
                    AxisMarks(position: .leading, values: .stride(by: 5))
                case "head_circ":
                    // label/grid every 2 cm
                    AxisMarks(position: .leading, values: .stride(by: 2))
                default:
                    AxisMarks(position: .leading, values: .automatic)
                }
            }
            .chartXAxis {
                // label/grid every 2 months
                AxisMarks(position: .bottom, values: .stride(by: 2))
            }
            .chartXAxisLabel("Age (months)")
            .chartYAxisLabel(measurement.capitalized)
            .chartLegend(.visible)

            let chartView = ZStack {
                chartContent
            }
            .frame(width: 1400, height: 1200)
            .background(Color.white)

            let renderer = ImageRenderer(content: chartView)
            renderer.scale = 1.0
            renderer.proposedSize = ProposedViewSize(width: 1400, height: 1200)
            return renderer.uiImage
        }

        return image
    }
}
