//
//  ReportGrowthRenderer.swift
//  DrsMainApp
//
//  Created by yunastic on 11/5/25.
//

import Foundation
import AppKit

/// Renders WHO growth charts (0–24 months) for the Well Visit report.
/// - Loads WHO CSVs from `Resources/WHO/` (file names like `wfa_0_24m_M.csv`)
/// - Draws percentile curves, axes, ticks, labels, legend, and patient points
/// - Returns NSImage objects you can embed as PDF pages (one per chart)
final class ReportGrowthRenderer {

    // MARK: - Public API

    /// Produce the three standard charts (WFA, L/HFA, HCFA) as images.
    /// - Parameter series: Data from ReportDataLoader.loadGrowthSeriesForWell(visitID:)
    /// - Returns: [NSImage] in order: WFA, L/HFA, HCFA
    static func renderAllCharts(series: ReportDataLoader.ReportGrowthSeries,
                                size: CGSize = CGSize(width: 700, height: 450)) -> [NSImage] {

        let sex = series.sex
        // WHO curves
        let wfaCurves = (try? loadWHO(kind: .wfa, sex: sex)) ?? fallbackFlatCurves()
        let lhfaCurves = (try? loadWHO(kind: .lhfa, sex: sex)) ?? fallbackFlatCurves()
        let hcfaCurves = (try? loadWHO(kind: .hcfa, sex: sex)) ?? fallbackFlatCurves()

        let wfaImg = renderChart(title: "Weight‑for‑Age (0–24 m)",
                                 yLabel: "kg",
                                 curves: wfaCurves,
                                 points: series.wfa,
                                 size: size)

        let lhfaImg = renderChart(title: "Length/Height‑for‑Age (0–24 m)",
                                  yLabel: "cm",
                                  curves: lhfaCurves,
                                  points: series.lhfa,
                                  size: size)

        let hcfaImg = renderChart(title: "Head Circumference‑for‑Age (0–24 m)",
                                  yLabel: "cm",
                                  curves: hcfaCurves,
                                  points: series.hcfa,
                                  size: size)

        return [wfaImg, lhfaImg, hcfaImg]
    }

    // MARK: - WHO Loader

    /// Expected CSV header: age_months,p3,p15,p50,p85,p97
    private static func loadWHO(kind: ReportGrowth.Kind,
                                sex: ReportGrowth.Sex,
                                bundle: Bundle = .main) throws -> ReportGrowth.Curves {
        let file = "\(kind.rawValue)_0_24m_\(sex == .male ? "M" : "F")"
        guard let url = bundle.url(forResource: file, withExtension: "csv", subdirectory: "WHO") else {
            throw NSError(domain: "ReportGrowthRenderer",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "WHO CSV not found: WHO/\(file).csv"])
        }

        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.split(whereSeparator: \.isNewline)
        guard let header = lines.first?.lowercased(),
              header.contains("age_months"),
              header.contains("p3"),
              header.contains("p15"),
              header.contains("p50"),
              header.contains("p85"),
              header.contains("p97") else {
            throw NSError(domain: "ReportGrowthRenderer",
                          code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Bad WHO header in \(file).csv"])
        }

        var ages: [Double] = []
        var p3:  [Double] = []
        var p15: [Double] = []
        var p50: [Double] = []
        var p85: [Double] = []
        var p97: [Double] = []

        for line in lines.dropFirst() {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard cols.count >= 6,
                  let ageM = Double(cols[0]),
                  let v3   = Double(cols[1]),
                  let v15  = Double(cols[2]),
                  let v50  = Double(cols[3]),
                  let v85  = Double(cols[4]),
                  let v97  = Double(cols[5]) else { continue }

            ages.append(ageM)
            p3.append(v3); p15.append(v15); p50.append(v50); p85.append(v85); p97.append(v97)
        }

        return ReportGrowth.Curves(agesMonths: ages, p3: p3, p15: p15, p50: p50, p85: p85, p97: p97)
    }

    private static func fallbackFlatCurves() -> ReportGrowth.Curves {
        let ages = stride(from: 0.0, through: 24.0, by: 1.0).map { $0 }
        let zeros = Array(repeating: 0.0, count: ages.count)
        return ReportGrowth.Curves(agesMonths: ages, p3: zeros, p15: zeros, p50: zeros, p85: zeros, p97: zeros)
    }

    // MARK: - Drawing

    private struct Style {
        var inset: CGFloat = 48
        var gridColor: NSColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        var axisColor: NSColor = NSColor(calibratedWhite: 0.15, alpha: 1.0)
        var labelColor: NSColor = NSColor(calibratedWhite: 0.1, alpha: 1.0)
        var legendText: NSColor = NSColor(calibratedWhite: 0.1, alpha: 1.0)
        var curveP50: NSColor = .black
        var curveP3:  NSColor = NSColor(calibratedWhite: 0.2, alpha: 1.0)
        var curveP97: NSColor = NSColor(calibratedWhite: 0.2, alpha: 1.0)
        var curveP15: NSColor = NSColor(calibratedWhite: 0.35, alpha: 1.0)
        var curveP85: NSColor = NSColor(calibratedWhite: 0.35, alpha: 1.0)
        var pointColor: NSColor = .systemBlue

        var curveThin: CGFloat = 1.2
        var curveThick: CGFloat = 2.0
        var pointRadius: CGFloat = 2.8

        var titleFont: NSFont = .systemFont(ofSize: 15, weight: .semibold)
        var labelFont: NSFont = .systemFont(ofSize: 11)
        var legendFont: NSFont = .systemFont(ofSize: 10)
    }

    private static func renderChart(title: String,
                                    yLabel: String,
                                    curves: ReportGrowth.Curves,
                                    points: [ReportGrowth.Point],
                                    size: CGSize,
                                    style: Style = Style()) -> NSImage {

        let img = NSImage(size: size)
        img.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            img.unlockFocus(); return img
        }

        let rect = CGRect(origin: .zero, size: size)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(rect)

        // Plot region
        let plot = rect.insetBy(dx: style.inset, dy: style.inset)

        // X range is months 0–24
        let xMin: CGFloat = 0
        let xMax: CGFloat = 24

        // Y range from curves + patient points
        var yMin = CGFloat(curves.values(for: .p3).min() ?? 0)
        var yMax = CGFloat(curves.values(for: .p97).max() ?? 1)
        if let pmin = points.map(\.value).min(), let pmax = points.map(\.value).max() {
            yMin = min(yMin, CGFloat(pmin))
            yMax = max(yMax, CGFloat(pmax))
        }
        if yMax <= yMin { yMax = yMin + 1 }

        let pad = (yMax - yMin) * 0.08
        yMin -= pad; yMax += pad

        // Helpers to convert data to plot coords
        func X(_ m: Double) -> CGFloat {
            let t = CGFloat((m - Double(xMin)) / Double(xMax - xMin))
            return plot.minX + t * plot.width
        }
        func Y(_ v: Double) -> CGFloat {
            let t = CGFloat((v - Double(yMin)) / Double(yMax - yMin))
            return plot.minY + t * plot.height
        }

        // Title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: style.titleFont,
            .foregroundColor: style.labelColor
        ]
        NSAttributedString(string: title, attributes: titleAttrs)
            .draw(at: CGPoint(x: plot.minX, y: plot.maxY + 10))

        // Grid lines
        ctx.saveGState()
        ctx.setStrokeColor(style.gridColor.cgColor)
        ctx.setLineWidth(0.8)
        // vertical every 3 months
        for month in stride(from: 0, through: 24, by: 3) {
            let x = X(Double(month))
            ctx.move(to: CGPoint(x: x, y: plot.minY))
            ctx.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        // horizontal 6 bands
        for i in 0...6 {
            let y = plot.minY + CGFloat(i) * (plot.height / 6.0)
            ctx.move(to: CGPoint(x: plot.minX, y: y))
            ctx.addLine(to: CGPoint(x: plot.maxX, y: y))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // Axes rectangle
        ctx.setStrokeColor(style.axisColor.cgColor)
        ctx.setLineWidth(1.2)
        ctx.stroke(plot)

        // X labels + axis label
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: style.labelFont,
            .foregroundColor: style.labelColor
        ]
        for month in stride(from: 0, through: 24, by: 3) {
            let s = NSAttributedString(string: "\(month)m", attributes: labelAttrs)
            s.draw(at: CGPoint(x: X(Double(month)) - 8, y: plot.minY - 16))
        }
        // X axis title
        let xAxis = NSAttributedString(string: "Age (months)", attributes: labelAttrs)
        let xSize = xAxis.size()
        xAxis.draw(at: CGPoint(x: plot.midX - xSize.width/2, y: plot.minY - 32))

        // Y labels (min/mid/max) + axis title
        let yTicks: [CGFloat] = [yMin, (yMin + yMax)/2.0, yMax]
        for (i, v) in yTicks.enumerated() {
            let txt = String(format: "%.1f %@", v, yLabel)
            let s = NSAttributedString(string: txt, attributes: labelAttrs)
            let yy: CGFloat = (i == 0 ? plot.minY : (i == 1 ? plot.midY - 6 : plot.maxY - 12))
            s.draw(at: CGPoint(x: plot.minX - 56, y: yy))
        }
        // Y axis title (rotated)
        let yAxis = NSAttributedString(string: yLabel, attributes: labelAttrs)
        let ySize = yAxis.size()
        ctx.saveGState()
        ctx.translateBy(x: plot.minX - 72, y: plot.midY)
        ctx.rotate(by: -.pi / 2)
        yAxis.draw(at: CGPoint(x: -ySize.width/2, y: -ySize.height/2))
        ctx.restoreGState()

        // WHO curves (set clearer styles)
        func strokeCurve(_ p: ReportGrowth.Percentile, color: NSColor, width: CGFloat, dash: [CGFloat]? = nil) {
            let xs = curves.agesMonths
            let ys = curves.values(for: p)
            guard xs.count == ys.count, xs.count > 1 else { return }
            ctx.saveGState()
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            if let dash = dash { ctx.setLineDash(phase: 0, lengths: dash) }
            ctx.beginPath()
            for i in 0..<xs.count {
                let pt = CGPoint(x: X(xs[i]), y: Y(ys[i]))
                if i == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
        strokeCurve(.p15, color: style.curveP15, width: 1.0, dash: [4,3])
        strokeCurve(.p85, color: style.curveP85, width: 1.0, dash: [4,3])
        strokeCurve(.p3,  color: style.curveP3,  width: 1.2, dash: [2,3])
        strokeCurve(.p97, color: style.curveP97, width: 1.2, dash: [2,3])
        strokeCurve(.p50, color: style.curveP50, width: style.curveThick, dash: nil)

        // Patient polyline + points
        ctx.saveGState()
        ctx.setStrokeColor(style.pointColor.cgColor)
        ctx.setFillColor(style.pointColor.cgColor)
        if points.count > 1 {
            ctx.setLineWidth(1.2)
            ctx.beginPath()
            for (i, pt) in points.enumerated() {
                let p = CGPoint(x: X(pt.ageMonths), y: Y(pt.value))
                if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
            ctx.strokePath()
        }
        let r = style.pointRadius
        for pt in points {
            let p = CGPoint(x: X(pt.ageMonths), y: Y(pt.value))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2*r, height: 2*r))
        }
        ctx.restoreGState()

        // Legend (top-right inside the plot)
        drawLegend(in: plot, style: style)

        img.unlockFocus()
        return img
    }

    private static func drawLegend(in plot: CGRect, style: Style) {
        let items: [(String, NSColor, [CGFloat]?)] = [
            ("P50", style.curveP50, nil),
            ("P3 / P97", style.curveP3, [2,3]),
            ("P15 / P85", style.curveP15, [4,3]),
            ("Patient", style.pointColor, nil)
        ]

        let padding: CGFloat = 6
        let swatchW: CGFloat = 24
        let rowH: CGFloat = 16
        let legendW: CGFloat = 160
        let legendH: CGFloat = CGFloat(items.count) * rowH + padding*2

        let box = CGRect(x: plot.maxX - legendW - 8, y: plot.maxY - legendH - 8, width: legendW, height: legendH)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        // background
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        path.fill()
        // border
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.7, alpha: 1).cgColor)
        ctx.setLineWidth(0.8)
        path.stroke()

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: style.legendFont,
            .foregroundColor: style.legendText
        ]

        for (i, item) in items.enumerated() {
            let y = box.maxY - padding - CGFloat(i+1)*rowH + 3
            // swatch
            let swRect = CGRect(x: box.minX + padding, y: y, width: swatchW, height: 8)
            ctx.saveGState()
            ctx.setStrokeColor(item.1.cgColor)
            ctx.setLineWidth(item.0 == "P50" ? 2.0 : 1.2)
            if let dash = item.2 { ctx.setLineDash(phase: 0, lengths: dash) }
            ctx.move(to: CGPoint(x: swRect.minX, y: swRect.midY))
            ctx.addLine(to: CGPoint(x: swRect.maxX, y: swRect.midY))
            ctx.strokePath()
            ctx.restoreGState()

            // label
            let label = NSAttributedString(string: item.0, attributes: textAttrs)
            label.draw(at: CGPoint(x: swRect.maxX + 8, y: swRect.minY - 2))
        }

        ctx.restoreGState()
    }
}
