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
    static func generateChartImage(
        dbPath: String,
        patientID: Int64,
        measurement: String,
        sex: String,
        filename: String
    ) async -> UIImage? {
        let refCurves = WhoReferenceLoader.loadCurve(fromCSV: filename, sex: sex)
        let patientData = GrowthDataFetcher.fetchGrowthData(
            dbPath: dbPath,
            patientID: patientID,
            measurement: measurement
        )

        // Debug output for patient data and reference curves
        print("[DEBUG] patientData count: \(patientData.count)")
        for pt in patientData {
            print("[DEBUG] patient point: age=\(pt.ageMonths), value=\(pt.value)")
        }
        print("[DEBUG] refCurves count: \(refCurves.count)")
        for curve in refCurves {
            print("[DEBUG] curve label: \(curve.label), points: \(curve.points.count)")
        }

        // determine y-axis domain based on measurement
        let yRange: ClosedRange<Double>
        switch measurement {
        case "weight":
            yRange = 0...20
        case "height":
            yRange = 40...100
        case "head_circ":
            yRange = 30...55
        default:
            yRange = 0...100
        }

        // Dynamically compute X-axis range based on patient data
        let maxAge = patientData.map(\.ageMonths).max() ?? 24
        let paddedMaxAge = min(maxAge + 1.0, 24)

        let chartContent = await Chart {
            // Reference Curves
            ForEach(refCurves, id: \.label) { curve in
                ForEach(curve.points, id: \.ageMonths) { point in
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
            ForEach(patientData, id: \.ageMonths) { point in
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

        // Render as UIImage
        return await MainActor.run {
            let renderer = ImageRenderer(content: chartView)
            renderer.scale = 1.0
            renderer.proposedSize = ProposedViewSize(width: 1400, height: 1000)
            return renderer.uiImage
        }
    }
}
