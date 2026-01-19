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
        "head_circ": 30...55, // cm (0–24m)
        "bmi": 8...40         // kg/m² (0–60m) — wide enough to avoid clipping
    ]

    private static let logger = AppLog.feature("GrowthChartRenderer")

    // MARK: - Localization helpers

    /// Localized display name for a measurement key (e.g., "weight", "height", "head_circ", "bmi").
    private static func localizedMeasurementName(_ measurement: String) -> String {
        let m = measurement.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch m {
        case "weight":
            return NSLocalizedString("growth.measurement.weight", comment: "Measurement label: weight")
        case "height":
            return NSLocalizedString("growth.measurement.height", comment: "Measurement label: height/length")
        case "head_circ":
            return NSLocalizedString("growth.measurement.head_circ", comment: "Measurement label: head circumference")
        case "bmi":
            return NSLocalizedString("growth.measurement.bmi", comment: "Measurement label: BMI")
        default:
            // Best-effort fallback for unknown measurement strings
            return measurement.capitalized
        }
    }

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

    /// Compute BMI-for-age points from weight (kg) and height/length (cm).
    /// We match weight and height points by ageMonths within a small tolerance.
    private static func computeBMIData(
        weightPoints: [GrowthDataPoint],
        heightPoints: [GrowthDataPoint]
    ) -> [GrowthDataPoint] {
        let w = weightPoints.filter { $0.ageMonths.isFinite && $0.value.isFinite }
            .sorted { $0.ageMonths < $1.ageMonths }
        let h = heightPoints.filter { $0.ageMonths.isFinite && $0.value.isFinite }
            .sorted { $0.ageMonths < $1.ageMonths }

        guard !w.isEmpty, !h.isEmpty else {
            Self.logger.notice("BMI: missing source series (weight.count=\(w.count, privacy: .public), height.count=\(h.count, privacy: .public))")
            return []
        }

        // ~4–5 days tolerance (in months) to pair measurements taken around the same time.
        let tol: Double = 0.15
        var j = 0
        var out: [GrowthDataPoint] = []
        out.reserveCapacity(min(w.count, h.count))

        for wp in w {
            // Move height pointer forward until it's within the left window.
            while j < h.count && h[j].ageMonths < wp.ageMonths - tol {
                j += 1
            }

            // Pick the closest height point within [age-tol, age+tol].
            var best: GrowthDataPoint? = nil
            var k = j
            while k < h.count && h[k].ageMonths <= wp.ageMonths + tol {
                let cand = h[k]
                if best == nil || abs(cand.ageMonths - wp.ageMonths) < abs(best!.ageMonths - wp.ageMonths) {
                    best = cand
                }
                k += 1
            }

            guard let hp = best else { continue }

            let meters = hp.value / 100.0
            guard meters > 0 else { continue }

            let bmi = wp.value / (meters * meters)
            guard bmi.isFinite else { continue }

            out.append(GrowthDataPoint(ageMonths: wp.ageMonths, value: bmi))
        }

        if out.isEmpty {
            Self.logger.notice("BMI: no matched points produced (weight.count=\(w.count, privacy: .public), height.count=\(h.count, privacy: .public))")
        } else {
            Self.logger.debug("BMI: produced \(out.count, privacy: .public) point(s) from weight.count=\(w.count, privacy: .public), height.count=\(h.count, privacy: .public)")
        }

        return out
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

        let patientData: [GrowthDataPoint]
        if measurement == "bmi" {
            // Prefer BMI computed from same-row weight+height in the DB (manual_growth),
            // which avoids accidental pairing across different dates (e.g., discharge weight vs birth length).
            let bmiDirect = GrowthDataFetcher.fetchGrowthData(
                dbPath: dbPath,
                patientID: patientID,
                measurement: "bmi"
            )

            if !bmiDirect.isEmpty {
                patientData = bmiDirect
                Self.logger.debug("BMI: using direct series from DB (count=\(bmiDirect.count, privacy: .public))")
            } else {
                // Fallback: derive BMI by pairing weight and height points by age proximity.
                let w = GrowthDataFetcher.fetchGrowthData(
                    dbPath: dbPath,
                    patientID: patientID,
                    measurement: "weight"
                )
                let h = GrowthDataFetcher.fetchGrowthData(
                    dbPath: dbPath,
                    patientID: patientID,
                    measurement: "height"
                )
                patientData = Self.computeBMIData(weightPoints: w, heightPoints: h)
                Self.logger.debug("BMI: direct series empty; using paired series (count=\(patientData.count, privacy: .public))")
            }
        } else {
            patientData = GrowthDataFetcher.fetchGrowthData(
                dbPath: dbPath,
                patientID: patientID,
                measurement: measurement
            )
        }

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
                        let prettyName = Self.localizedMeasurementName(measurement)
                        let title = String(
                            format: NSLocalizedString(
                                "growth.chart.placeholder.title",
                                comment: "Placeholder title when no growth data is available for a chart. %@ = measurement name"
                            ),
                            locale: Locale.current,
                            prettyName
                        )
                        Text(title)
                            .font(.title2)
                            .bold()

                        Text(NSLocalizedString(
                            "growth.chart.placeholder.subtitle",
                            comment: "Placeholder subtitle inviting the user to add measurements"
                        ))
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
        // Build the Chart and render on the main actor so all @MainActor-isolated
        // view modifiers (e.g., .chartLegend) are called on the correct actor.
        let image: UIImage? = await MainActor.run {
            let axisAgeLabel = NSLocalizedString(
                "growth.chart.axis.ageMonths",
                comment: "Chart axis label for age in months"
            )
            let axisValueLabel = NSLocalizedString(
                "growth.chart.axis.value",
                comment: "Chart axis label for the plotted measurement values"
            )
            let percentileLegendLabel = NSLocalizedString(
                "growth.chart.legend.percentile",
                comment: "Legend label for percentile/SD reference curves"
            )
            // 1) Base chart content
            let chartContent = Chart {
                // Reference Curves (filtered inside the loop)
                ForEach(refCurves, id: \.label) { curve in
                    let points = curve.points.filter { $0.ageMonths.isFinite && $0.value.isFinite }
                    ForEach(points, id: \.ageMonths) { point in
                        LineMark(
                            x: .value(axisAgeLabel, point.ageMonths),
                            y: .value(axisValueLabel, point.value)
                        )
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        .opacity(0.7)
                    }
                    .foregroundStyle(by: .value(percentileLegendLabel, curve.label))
                }

                // Patient Data
                ForEach(cleanPatient, id: \.ageMonths) { point in
                    PointMark(
                        x: .value(axisAgeLabel, point.ageMonths),
                        y: .value(axisValueLabel, point.value)
                    )
                    .foregroundStyle(.blue)
                    .symbolSize(40)
                }
            }

            // 2) X/Y scales
            let chartScaled = chartContent
                .chartXScale(domain: 0...paddedMaxAge)
                .chartYScale(domain: yRange)

            // 3) Axes styling (black ticks/labels, lighter grid)
            let chartWithAxes = chartScaled
                .chartYAxis {
                    switch measurement {
                    case "weight":
                        AxisMarks(position: .leading, values: .stride(by: 2)) { value in
                            AxisGridLine().foregroundStyle(.black.opacity(0.3))
                            AxisTick().foregroundStyle(.black)

                            if let v = value.as(Double.self) {
                                AxisValueLabel {
                                    Text(String(Int(v.rounded())))
                                        .foregroundColor(.black)
                                }
                            }
                        }

                    case "height":
                        AxisMarks(position: .leading, values: .stride(by: 5)) { value in
                            AxisGridLine().foregroundStyle(.black.opacity(0.3))
                            AxisTick().foregroundStyle(.black)

                            if let v = value.as(Double.self) {
                                AxisValueLabel {
                                    Text(String(Int(v.rounded())))
                                        .foregroundColor(.black)
                                }
                            }
                        }

                    case "head_circ":
                        AxisMarks(position: .leading, values: .stride(by: 2)) { value in
                            AxisGridLine().foregroundStyle(.black.opacity(0.3))
                            AxisTick().foregroundStyle(.black)

                            if let v = value.as(Double.self) {
                                AxisValueLabel {
                                    Text(String(Int(v.rounded())))
                                        .foregroundColor(.black)
                                }
                            }
                        }

                    case "bmi":
                        AxisMarks(position: .leading, values: .stride(by: 2)) { value in
                            AxisGridLine().foregroundStyle(.black.opacity(0.3))
                            AxisTick().foregroundStyle(.black)

                            if let v = value.as(Double.self) {
                                AxisValueLabel {
                                    Text(String(format: "%.1f", v))
                                        .foregroundColor(.black)
                                }
                            }
                        }

                    default:
                        AxisMarks(position: .leading, values: .automatic) { value in
                            AxisGridLine().foregroundStyle(.black.opacity(0.3))
                            AxisTick().foregroundStyle(.black)

                            if let v = value.as(Double.self) {
                                AxisValueLabel {
                                    Text(String(Int(v.rounded())))
                                        .foregroundColor(.black)
                                }
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(position: .bottom, values: .stride(by: 2)) { value in
                        AxisGridLine().foregroundStyle(.black.opacity(0.3))
                        AxisTick().foregroundStyle(.black)

                        if let month = value.as(Double.self) {
                            AxisValueLabel {
                                Text(String(Int(month.rounded())))
                                    .foregroundColor(.black)
                            }
                        }
                    }
                }

            // 4) Final view used for rendering
            let chartView = chartWithAxes
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
