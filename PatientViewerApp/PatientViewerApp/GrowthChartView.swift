import SwiftUI
import Charts

struct GrowthChartView: View {
    let dataPoints: [GrowthDataPoint]
    let referenceCurves: [(label: String, points: [GrowthDataPoint])]
    let measurement: String

    @ChartContentBuilder
    private var chartContent: some ChartContent {
        // User data
        ForEach(dataPoints, id: \.ageMonths) { point in
            PointMark(
                x: .value("Age (months)", point.ageMonths),
                y: .value("Value", point.value)
            )
            .foregroundStyle(.blue)
            .symbolSize(40)
        }

        // WHO reference curves
        ForEach(referenceCurves, id: \.label) { curve in
            ForEach(curve.points, id: \.ageMonths) { refPoint in
                LineMark(
                    x: .value("Age (months)", refPoint.ageMonths),
                    y: .value("Value", refPoint.value)
                )
                .foregroundStyle(by: .value("Curve", curve.label))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
    }

    var body: some View {
        Chart {
            chartContent
        }
        .chartXScale(domain: xDomain())
        .chartYScale(domain: yDomain())
        .chartXAxisLabel("Age (months)")
        .chartYAxisLabel(yAxisLabel(measurement))
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
        .padding()
        .navigationTitle(titleForMeasurement(measurement))
    }

    private func yDomain() -> ClosedRange<Double> {
        let allValues = dataPoints.map(\.value) + referenceCurves.flatMap { $0.points.map(\.value) }
        guard let min = allValues.min(), let max = allValues.max() else {
            return 0...1
        }
        return (min - 1)...(max + 1)
    }
    
    private func xDomain() -> ClosedRange<Double> {
        let allAges = dataPoints.map(\.ageMonths) + referenceCurves.flatMap { $0.points.map(\.ageMonths) }
        guard let min = allAges.min(), let max = allAges.max() else {
            return 0...24
        }
        let paddedMin = Swift.max(0, min - 1)
        let paddedMax = Swift.min(max + 1, 60)
        return paddedMin...paddedMax
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

