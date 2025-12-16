//
//  ReportGrowthRenderer.swift
//  DrsMainApp
//
//  Created by yunastic on 11/5/25.
//


import Foundation
import AppKit

// Local helper (this file is used from Reports and may not see UI-level helpers).
fileprivate func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

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

        let wfaImg = renderChart(title: L("report.growth.title.wfa_0_60m"),
                                 yLabel: "kg",
                                 curves: wfaCurves,
                                 points: series.wfa,
                                 size: clamped)

        let lhfaImg = renderChart(title: L("report.growth.title.lhfa_0_60m"),
                                  yLabel: "cm",
                                  curves: lhfaCurves,
                                  points: series.lhfa,
                                  size: clamped)

        let hcfaImg = renderChart(title: L("report.growth.title.hcfa_0_60m"),
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
            let sexMarker = (sex == .male ? "M" : "F")
            throw NSError(domain: "ReportGrowthRenderer",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(format: L("report.growth.error.who_csv_not_found_fmt"), kind.rawValue, sexMarker)])
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
                          userInfo: [NSLocalizedDescriptionKey: String(format: L("report.growth.error.bad_header_fmt"), url.lastPathComponent)])
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
        // Flat dummy curves from 0–60 months (used only if WHO CSV is missing)
        let ages = stride(from: 0.0, through: 60.0, by: 1.0).map { $0 }
        let zeros = Array(repeating: 0.0, count: ages.count)
        return ReportGrowth.Curves(agesMonths: ages, p3: zeros, p15: zeros, p50: zeros, p85: zeros, p97: zeros)
    }

    // MARK: - Drawing

    private struct Style {
        var marginLeft: CGFloat = 72
        var marginRight: CGFloat = 20
        var marginTop: CGFloat = 36
        var marginBottom: CGFloat = 44
        var gridColor: NSColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        var axisColor: NSColor = NSColor(calibratedWhite: 0.15, alpha: 1.0)
        var labelColor: NSColor = NSColor(calibratedWhite: 0.1, alpha: 1.0)
        var legendText: NSColor = NSColor(calibratedWhite: 0.1, alpha: 1.0)
        // Slightly smaller labels to reduce collisions at 1-month / 1-kg density
        var labelFontSmall: NSFont = .systemFont(ofSize: 9)
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
        var legendFont: NSFont = .systemFont(ofSize: 9)
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

        // Ensure 1pt maps to the intended pixel density, but avoid double-scaling if already applied by NSGraphicsContext.
        let sx = ctx.ctm.a
        let sy = ctx.ctm.d
        if abs(sx - 1.0) < 0.01 && abs(sy - 1.0) < 0.01 {
            ctx.scaleBy(x: scale, y: scale)
        }

        // Quality knobs for crisp lines and text when downsampled in PDF
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high

        let rect = CGRect(origin: .zero, size: size)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(rect)

        // Plot region (explicit margins so labels fit within image bounds)
        let plot = CGRect(
            x: rect.minX + style.marginLeft,
            y: rect.minY + style.marginBottom,
            width: max(1, rect.width - style.marginLeft - style.marginRight),
            height: max(1, rect.height - style.marginTop - style.marginBottom)
        )

        // X range is months 0–24
        let xMin: CGFloat = 0
        let xMax: CGFloat = 60

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

        // Grid lines (vertical: minor every month; major every 6 months) — plus Y dynamic grid below
        // Minor vertical grid: every 1 month
        ctx.saveGState()
        ctx.setStrokeColor(style.gridColor.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(0.3)
        for month in 0...60 {
            let x = X(Double(month))
            ctx.move(to: CGPoint(x: x, y: plot.minY))
            ctx.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // Major vertical grid: every 6 months (slightly darker/thicker)
        ctx.saveGState()
        ctx.setStrokeColor(style.axisColor.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(0.8)
        for month in stride(from: 0, through: 60, by: 6) {
            let x = X(Double(month))
            ctx.move(to: CGPoint(x: x, y: plot.minY))
            ctx.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // Horizontal grid: major/minor based on y units (kg vs cm)
        let isKg = (yLabel.lowercased() == "kg")
        let majorStep: CGFloat = isKg ? 1.0 : 5.0
        let minorStep: CGFloat = isKg ? 0.5 : 1.0

        // Start inside the visible range to avoid drawing a grid line below the baseline
        let startMinor = ceil(yMin / minorStep) * minorStep
        let startMajor = ceil(yMin / majorStep) * majorStep

        // Minor lines
        ctx.saveGState()
        ctx.setStrokeColor(style.gridColor.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(0.4)
        var v = startMinor
        while v <= yMax + 0.0001 {
            let y = Y(Double(v))
            // Clamp to visible plot area to avoid stray lines below baseline or above top
            if y <= plot.minY + 0.5 || y >= plot.maxY - 0.5 {
                v += minorStep
                continue
            }
            // Skip if it coincides with a major line (we'll draw major later)
            let k = round((v - startMajor) / majorStep)
            if abs(v - (startMajor + k * majorStep)) > 0.001 {
                ctx.move(to: CGPoint(x: plot.minX, y: y))
                ctx.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
            v += minorStep
        }
        ctx.strokePath()
        ctx.restoreGState()

        // Major lines
        ctx.saveGState()
        ctx.setStrokeColor(style.axisColor.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(0.8)
        var vm = startMajor
        while vm <= yMax + 0.0001 {
            let y = Y(Double(vm))
            // Clamp to visible plot area; don't draw the baseline or above the top
            if y > plot.minY + 0.5 && y < plot.maxY - 0.5 {
                ctx.move(to: CGPoint(x: plot.minX, y: y))
                ctx.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
            vm += majorStep
        }
        ctx.strokePath()
        ctx.restoreGState()

        // Axes rectangle
        ctx.setStrokeColor(style.axisColor.cgColor)
        ctx.setLineWidth(1.2)
        ctx.stroke(plot)

        // X labels (every 2 months; unit is on axis title) + axis label
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: style.labelFontSmall,
            .foregroundColor: style.labelColor
        ]
        // Measure a representative label height once
        let sampleLabelSize = NSAttributedString(string: "00", attributes: labelAttrs).size()
        let xLabelYOffset: CGFloat = sampleLabelSize.height + 6  // keep labels a few points below the axis line
        for month in stride(from: 0, through: 60, by: 2) {
            let s = NSAttributedString(string: "\(month)", attributes: labelAttrs)
            let sz = s.size()
            let xx = X(Double(month)) - sz.width/2
            let yy = plot.minY - xLabelYOffset
            s.draw(at: CGPoint(x: xx, y: yy))
        }
        // X axis title (centered), placed below labels with extra gap
        let xAxis = NSAttributedString(string: L("report.growth.axis.age_months"), attributes: labelAttrs)
        let xSize = xAxis.size()
        let xAxisY = plot.minY - (xLabelYOffset + 8 + xSize.height)
        xAxis.draw(at: CGPoint(x: plot.midX - xSize.width/2, y: xAxisY))

        // Y labels at each major tick (no unit here; unit is shown on the axis title).
        var vLabel = startMajor  // include the lowest label inside the plot
        while vLabel <= yMax + 0.0001 {
            let y = Y(Double(vLabel))
            let txt = "\(Int(round(vLabel)))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: style.labelFontSmall,
                .foregroundColor: style.labelColor
            ]
            let s = NSAttributedString(string: txt, attributes: attrs)
            let sz = s.size()
            // Right‑align 6pt left of the plot border (keeps label close to the graph)
            let x = plot.minX - 6 - sz.width
            let yy = y - sz.height / 2
            s.draw(at: CGPoint(x: x, y: yy))
            vLabel += majorStep
        }
        // Y axis title (rotated)
        let yAxis = NSAttributedString(string: yLabel, attributes: labelAttrs)
        let ySize = yAxis.size()
        ctx.saveGState()
        ctx.translateBy(x: plot.minX - 40, y: plot.midY)
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
        let items: [(id: String, label: String, color: NSColor, dash: [CGFloat]?)] = [
            (id: "p3",  label: "P3",  color: style.curveP3,  dash: [2,3]),
            (id: "p15", label: "P15", color: style.curveP15, dash: [4,3]),
            (id: "p50", label: "P50", color: style.curveP50, dash: nil),
            (id: "p85", label: "P85", color: style.curveP85, dash: [4,3]),
            (id: "p97", label: "P97", color: style.curveP97, dash: [2,3]),
            (id: "patient", label: L("report.growth.legend.patient"), color: style.pointColor, dash: nil)
        ]

        let padding: CGFloat = 6
        let swatchW: CGFloat = 18
        let rowH: CGFloat = 14
        // Measure max label width to avoid excess empty space on the right
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: style.legendFont,
            .foregroundColor: style.legendText
        ]
        let maxLabelW = items.map { NSAttributedString(string: $0.label, attributes: textAttrs).size().width }.max() ?? 0
        let legendW: CGFloat = padding*2 + swatchW + 8 + ceil(maxLabelW)
        let legendH: CGFloat = CGFloat(items.count) * rowH + padding*2

        // Move legend to bottom‑right inside the plot
        let box = CGRect(x: plot.maxX - legendW - 8, y: plot.minY + 8, width: legendW, height: legendH)

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

        for (i, item) in items.enumerated() {
            let y = box.maxY - padding - CGFloat(i+1)*rowH + 3
            // swatch
            let swRect = CGRect(x: box.minX + padding, y: y, width: swatchW, height: 8)
            ctx.saveGState()
            ctx.setStrokeColor(item.color.cgColor)
            let lw: CGFloat
            switch item.id {
            case "p3", "p97": lw = 1.6
            case "p15", "p85": lw = 1.3
            case "p50": lw = 1.0
            default: lw = 1.2
            }
            ctx.setLineWidth(lw)
            if let dash = item.dash { ctx.setLineDash(phase: 0, lengths: dash) }
            ctx.move(to: CGPoint(x: swRect.minX, y: swRect.midY))
            ctx.addLine(to: CGPoint(x: swRect.maxX, y: swRect.midY))
            ctx.strokePath()
            ctx.restoreGState()

            // label
            let label = NSAttributedString(string: item.label, attributes: textAttrs)
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
