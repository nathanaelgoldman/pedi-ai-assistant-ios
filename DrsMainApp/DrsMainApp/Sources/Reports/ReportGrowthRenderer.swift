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

    // Max rendered chart width: 18 cm (in points) so DPI stays reasonable at 300 dpi
    private static let maxWidthCM: CGFloat = 18.0
    private static let maxWidthPoints: CGFloat = (maxWidthCM / 2.54) * 72.0  // ≈ 510.24 pt

    /// Clamp a requested logical size to the maximum width, preserving aspect ratio.
    private static func clampSizeToMaxWidth(_ size: CGSize) -> CGSize {
        guard size.width > maxWidthPoints, size.width > 0, size.height > 0 else { return size }
        let k = maxWidthPoints / size.width
        return CGSize(width: maxWidthPoints, height: size.height * k)
    }

    // MARK: - Public API

    /// Produce the three standard charts (WFA, L/HFA, HCFA) as images.
    /// - Parameter series: Data from ReportDataLoader.loadGrowthSeriesForWell(visitID:)
    /// - Returns: [NSImage] in order: WFA, L/HFA, HCFA
    static func renderAllCharts(series: ReportDataLoader.ReportGrowthSeries,
                                size: CGSize = CGSize(width: 700, height: 450)) -> [NSImage] {

        let clamped = clampSizeToMaxWidth(size)
        let sex = series.sex
        // WHO curves
        let wfaCurves = (try? loadWHO(kind: .wfa, sex: sex)) ?? fallbackFlatCurves()
        let lhfaCurves = (try? loadWHO(kind: .lhfa, sex: sex)) ?? fallbackFlatCurves()
        let hcfaCurves = (try? loadWHO(kind: .hcfa, sex: sex)) ?? fallbackFlatCurves()

        let wfaImg = renderChart(title: "Weight‑for‑Age (0–24 m)",
                                 yLabel: "kg",
                                 curves: wfaCurves,
                                 points: series.wfa,
                                 size: clamped)

        let lhfaImg = renderChart(title: "Length/Height‑for‑Age (0–24 m)",
                                  yLabel: "cm",
                                  curves: lhfaCurves,
                                  points: series.lhfa,
                                  size: clamped)

        let hcfaImg = renderChart(title: "Head Circumference‑for‑Age (0–24 m)",
                                  yLabel: "cm",
                                  curves: hcfaCurves,
                                  points: series.hcfa,
                                  size: clamped)

        return [wfaImg, lhfaImg, hcfaImg]
    }

    // MARK: - WHO Loader

    /// Try to locate a WHO CSV in several plausible bundle locations and name variants.
    /// Expected canonical name: "<kind>_0_24m_<M|F>.csv" inside "WHO/" subdirectory.
    private static func findWHOURL(kind: ReportGrowth.Kind,
                                   sex: ReportGrowth.Sex,
                                   bundle: Bundle) -> URL? {
        let base = "\(kind.rawValue)_0_24m_\(sex == .male ? "M" : "F")"
        let candidates: [(subdir: String?, name: String)] = [
            ("WHO", base),
            ("who", base),
            ("Resources/WHO", base),
            (nil, base)
        ]
        for c in candidates {
            if let url = bundle.url(forResource: c.name, withExtension: "csv", subdirectory: c.subdir) {
                return url
            }
        }
        // Last resort: scan any CSVs in bundle root and WHO dirs that loosely match.
        let searchSubdirs: [String?] = [nil, "WHO", "who", "Resources/WHO"]
        for sub in searchSubdirs {
            if let urls = bundle.urls(forResourcesWithExtension: "csv", subdirectory: sub) {
                if let match = urls.first(where: { url in
                    let fname = url.deletingPathExtension().lastPathComponent.lowercased()
                    // accept both exact and case-insensitive matches like "wfa_0_24m_m" or with extra suffixes
                    let prefix = "\(kind.rawValue)_0_24m_".lowercased()
                    let sexMarker = (sex == .male ? "m" : "f")
                    return fname.hasPrefix(prefix) && fname.contains(sexMarker)
                }) {
                    return match
                }
            }
        }
        return nil
    }

    /// Expected CSV header: age_months,p3,p15,p50,p85,p97
    private static func loadWHO(kind: ReportGrowth.Kind,
                                sex: ReportGrowth.Sex,
                                bundle: Bundle = .main) throws -> ReportGrowth.Curves {
        // Locate file robustly
        guard let url = findWHOURL(kind: kind, sex: sex, bundle: bundle) else {
            #if DEBUG
            print("[ReportGrowthRenderer] WHO CSV not found for \(kind.rawValue) sex=\(sex == .male ? "M" : "F") in bundle paths {WHO/, who/, Resources/WHO/, root}. Falling back to flat curves.")
            #endif
            throw NSError(domain: "ReportGrowthRenderer",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "WHO CSV not found for \(kind.rawValue) \(sex == .male ? "M" : "F")"])
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
            #if DEBUG
            print("[ReportGrowthRenderer] Bad WHO header in \(url.lastPathComponent). Header: \(lines.first ?? "")")
            #endif
            throw NSError(domain: "ReportGrowthRenderer",
                          code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Bad WHO header in \(url.lastPathComponent)"])
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

        #if DEBUG
        if ages.isEmpty { print("[ReportGrowthRenderer] WHO CSV \(url.lastPathComponent) parsed but no rows; using fallback.") }
        else { print("[ReportGrowthRenderer] WHO loaded \(url.lastPathComponent): rows=\(ages.count)") }
        #endif

        return ReportGrowth.Curves(agesMonths: ages, p3: p3, p15: p15, p50: p50, p85: p85, p97: p97)
    }

    private static func fallbackFlatCurves() -> ReportGrowth.Curves {
        let ages = stride(from: 0.0, through: 24.0, by: 1.0).map { $0 }
        let zeros = Array(repeating: 0.0, count: ages.count)
        return ReportGrowth.Curves(agesMonths: ages, p3: zeros, p15: zeros, p50: zeros, p85: zeros, p97: zeros)
    }

    // MARK: - Drawing

    private struct Style {
        var inset: CGFloat = 8
        var gridColor: NSColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        var axisColor: NSColor = NSColor(calibratedWhite: 0.15, alpha: 1.0)
        var labelColor: NSColor = NSColor(calibratedWhite: 0.1, alpha: 1.0)
        var legendText: NSColor = NSColor(calibratedWhite: 0.1, alpha: 1.0)
        // Distinct, print‑friendly colors per percentile
        var curveP3:  NSColor = NSColor(calibratedRed: 0.82, green: 0.29, blue: 0.36, alpha: 1.0)   // red (P3)
        var curveP15: NSColor = NSColor(calibratedRed: 0.97, green: 0.57, blue: 0.34, alpha: 1.0)   // orange (P15)
        var curveP50: NSColor = NSColor(calibratedRed: 0.18, green: 0.53, blue: 0.67, alpha: 1.0)   // blue (P50)
        var curveP85: NSColor = NSColor(calibratedRed: 0.34, green: 0.66, blue: 0.45, alpha: 1.0)   // green (P85)
        var curveP97: NSColor = NSColor(calibratedRed: 0.49, green: 0.42, blue: 0.77, alpha: 1.0)   // purple (P97)
        var pointColor: NSColor = .systemBlue

        var curveThin: CGFloat = 1.2
        var curveThick: CGFloat = 1.0   // make P50 thinner than others
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

        // High-DPI rendering: target 300 DPI so lines remain crisp in PDF/print.
        // Convert logical point size to pixels using: pixelsPerPoint = targetDPI / 72.
        let targetDPI: CGFloat = 300.0
        let scale: CGFloat = targetDPI / 72.0  // ≈ 4.1667×
        let pw = max(1, Int((size.width  * scale).rounded()))
        let ph = max(1, Int((size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pw,
                                         pixelsHigh: ph,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else {
            // Fallback to 1× if bitmap allocation fails
            let fallback = NSImage(size: size)
            fallback.lockFocus()
            let ctx = NSGraphicsContext.current!.cgContext
            let rect = CGRect(origin: .zero, size: size)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(rect)
            fallback.unlockFocus()
            return fallback
        }
        rep.size = size  // logical points, keeps image sized correctly when embedded

        NSGraphicsContext.saveGraphicsState()
        guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            let fallback = NSImage(size: size)
            return fallback
        }
        NSGraphicsContext.current = nsCtx
        let ctx = nsCtx.cgContext

        // Scale context so our drawing code continues to use point-based 'size' and layout
        ctx.scaleBy(x: scale, y: scale)

        // Quality knobs for crisp lines and text when downsampled in PDF
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high

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
        strokeCurve(.p3,  color: style.curveP3,  width: 1.6, dash: [2,3])
        strokeCurve(.p15, color: style.curveP15, width: 1.3, dash: [4,3])
        strokeCurve(.p50, color: style.curveP50, width: style.curveThick, dash: nil)
        strokeCurve(.p85, color: style.curveP85, width: 1.3, dash: [4,3])
        strokeCurve(.p97, color: style.curveP97, width: 1.6, dash: [2,3])

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

        // Finalize high-DPI render and wrap into an NSImage at logical size
        NSGraphicsContext.current = nil
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }

    private static func drawLegend(in plot: CGRect, style: Style) {
        let items: [(String, NSColor, [CGFloat]?)] = [
            ("P3",  style.curveP3,  [2,3]),
            ("P15", style.curveP15, [4,3]),
            ("P50", style.curveP50, nil),
            ("P85", style.curveP85, [4,3]),
            ("P97", style.curveP97, [2,3]),
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
            let lw: CGFloat
            switch item.0 {
            case "P3", "P97": lw = 1.6
            case "P15", "P85": lw = 1.3
            case "P50": lw = 1.0
            default: lw = 1.2
            }
            ctx.setLineWidth(lw)
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

// MARK: - Temporary overload to support drawWHO flag from callers
extension ReportGrowthRenderer {
    /// Overload that accepts `drawWHO` to match updated call sites.
    /// Currently forwards to the original implementation; WHO drawing is already handled inside.
    static func renderAllCharts(series: ReportDataLoader.ReportGrowthSeries,
                                size: CGSize,
                                drawWHO: Bool) -> [NSImage] {
        return renderAllCharts(series: series, size: size)
    }
}
