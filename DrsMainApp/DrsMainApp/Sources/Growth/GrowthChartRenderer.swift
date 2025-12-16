//
//  GrowthChartRenderer.swift
//  DrsMainApp
//
//  Created by yunastic on 11/5/25.
//
import AppKit

final class GrowthChartRenderer {

    private static func L(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    struct Style {
        var inset: CGFloat = 36
        var gridColor: NSColor = .quaternaryLabelColor
        var axisColor: NSColor = .secondaryLabelColor
        var curveThin: CGFloat = 1.0
        var curveThick: CGFloat = 1.8
        var pointRadius: CGFloat = 2.5
        var titleFont: NSFont = .systemFont(ofSize: 14, weight: .semibold)
        var labelFont: NSFont = .systemFont(ofSize: 10)
    }

    /// Render a generic growth chart into an NSImage
    /// - Parameters:
    ///   - title: Chart title (e.g., "Weight-for-Age (0–24 m)")
    ///   - yLabel: Units ("kg" / "cm")
    ///   - curves: WHO curves
    ///   - points: Patient points (already filtered to <= visit date)
    ///   - size: Output size in points
    static func renderChart(title: String,
                            yLabel: String,
                            curves: ReportGrowth.Curves,
                            points: [ReportGrowth.Point],
                            size: CGSize = CGSize(width: 700, height: 450),
                            style: Style = Style()) -> NSImage {

        let img = NSImage(size: size)
        img.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            img.unlockFocus()
            return img
        }

        let rect = CGRect(origin: .zero, size: size)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(rect)

        // Plot area
        let plot = rect.insetBy(dx: style.inset, dy: style.inset)
        let xMin: CGFloat = 0
        let xMax: CGFloat = 24

        // Y range from WHO curves; pad a bit; include patient points
        var yMinMax = curves.yRange(percentiles: [.p3, .p97]) ?? (0, 1)
        if let pMin = points.map(\.value).min(), let pMax = points.map(\.value).max() {
            yMinMax = (min(yMinMax.min, pMin), max(yMinMax.max, pMax))
        }
        let pad = (yMinMax.max - yMinMax.min) * 0.08
        let yMin = CGFloat(yMinMax.min - pad)
        let yMax = CGFloat(yMinMax.max + pad)

        func X(_ m: Double) -> CGFloat {
            let t = CGFloat((m - Double(xMin)) / Double(xMax - xMin))
            return plot.minX + t * plot.width
        }
        func Y(_ v: Double) -> CGFloat {
            let t = CGFloat((v - Double(yMin)) / Double(yMax - yMin))
            return plot.minY + t * plot.height
        }

        // Grid + axes
        ctx.setStrokeColor(style.gridColor.cgColor)
        ctx.setLineWidth(0.5)
        for month in stride(from: 0, through: 24, by: 3) {
            let x = X(Double(month))
            ctx.move(to: CGPoint(x: x, y: plot.minY))
            ctx.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        for i in 0...5 {
            let y = plot.minY + CGFloat(i) * (plot.height / 5.0)
            ctx.move(to: CGPoint(x: plot.minX, y: y))
            ctx.addLine(to: CGPoint(x: plot.maxX, y: y))
        }
        ctx.strokePath()

        ctx.setStrokeColor(style.axisColor.cgColor)
        ctx.setLineWidth(1.0)
        // Border
        ctx.stroke(plot)

        // Title
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: style.titleFont, .foregroundColor: NSColor.labelColor]
        let titleStr = NSAttributedString(string: title, attributes: titleAttrs)
        titleStr.draw(at: CGPoint(x: plot.minX, y: plot.maxY + 8))

        // Axis labels (x months)
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: style.labelFont, .foregroundColor: NSColor.secondaryLabelColor]
        for month in stride(from: 0, through: 24, by: 3) {
            let s = NSAttributedString(string: "\(month)\(L("report.growth.axis.month_suffix"))", attributes: labelAttrs)
            let p = CGPoint(x: X(Double(month)) - 8, y: plot.minY - 14)
            s.draw(at: p)
        }
        // Y label on the left (min/mid/max ticks)
        let yVals: [Double] = [Double(yMin), Double(yMin + (plot.height/2.0) * (Double(yMax - yMin)/Double(plot.height))), Double(yMax)]
        for (i, v) in yVals.enumerated() {
            let txt = String(format: "%.1f %@", v, yLabel)
            let s = NSAttributedString(string: txt, attributes: labelAttrs)
            let yy = i == 0 ? plot.minY : (i == 1 ? (plot.midY - 6) : plot.maxY - 12)
            s.draw(at: CGPoint(x: plot.minX - 48, y: yy))
        }

        // Draw WHO percentile curves (p3, p50, p97 prominent; p15/p85 lighter)
        func strokeCurve(_ p: ReportGrowth.Percentile, width: CGFloat, alpha: CGFloat) {
            let ys = curves.values(for: p)
            guard ys.count == curves.agesMonths.count else { return }
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(width)
            ctx.beginPath()
            for (i, ageM) in curves.agesMonths.enumerated() {
                let pt = CGPoint(x: X(ageM), y: Y(ys[i]))
                if i == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
            }
            ctx.strokePath()
        }
        strokeCurve(.p15, width: style.curveThin,  alpha: 0.25)
        strokeCurve(.p85, width: style.curveThin,  alpha: 0.25)
        strokeCurve(.p3,  width: style.curveThin,  alpha: 0.6)
        strokeCurve(.p97, width: style.curveThin,  alpha: 0.6)
        strokeCurve(.p50, width: style.curveThick, alpha: 0.9)

        // Patient points
        ctx.setFillColor(NSColor.systemBlue.cgColor)
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1.0)
        let r = style.pointRadius
        if points.count > 1 {
            ctx.beginPath()
            for (i, pt) in points.enumerated() {
                let p = CGPoint(x: X(pt.ageMonths), y: Y(pt.value))
                if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
            ctx.strokePath()
        }
        for pt in points {
            let p = CGPoint(x: X(pt.ageMonths), y: Y(pt.value))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2*r, height: 2*r))
        }

        img.unlockFocus()
        return img
    }

    // Convenience wrappers (all identical rendering, different titles/units)
    static func renderWFA(curves: ReportGrowth.Curves,
                          points: [ReportGrowth.Point],
                          size: CGSize = CGSize(width: 700, height: 450)) -> NSImage {
        renderChart(title: L("report.growth.title.wfa_0_24m"), yLabel: "kg", curves: curves, points: points, size: size)
    }

    static func renderLHFA(curves: ReportGrowth.Curves,
                           points: [ReportGrowth.Point],
                           size: CGSize = CGSize(width: 700, height: 450)) -> NSImage {
        renderChart(title: L("report.growth.title.lhfa_0_24m"), yLabel: "cm", curves: curves, points: points, size: size)
    }

    static func renderHCFA(curves: ReportGrowth.Curves,
                           points: [ReportGrowth.Point],
                           size: CGSize = CGSize(width: 700, height: 450)) -> NSImage {
        renderChart(title: L("report.growth.title.hcfa_0_24m"), yLabel: "cm", curves: curves, points: points, size: size)
    }
}
