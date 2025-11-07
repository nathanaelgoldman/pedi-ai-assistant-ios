//
//  ReportBuilder.swift
//  DrsMainApp
//
//  Created by yunastic on 11/2/25.
//

import Foundation
import AppKit
import PDFKit
import UniformTypeIdentifiers
import CoreText

// MARK: - Report geometry (single source of truth)
fileprivate let REPORT_PAGE_SIZE = CGSize(width: 595.0, height: 842.0) // US Letter; switch here if you use A4
fileprivate let REPORT_INSET: CGFloat = 36.0

// MARK: - Visit selection + format

enum VisitKind {
    case sick(episodeID: Int)
    case well(visitID: Int)
}

enum ReportFormat { case pdf, rtf }

// MARK: - Public builder (no direct DB calls)

@MainActor
final class ReportBuilder {

    let appState: AppState
    let clinicianStore: ClinicianStore

    // Loader for parity header/meta rendering
    private lazy var dataLoader = ReportDataLoader(appState: appState, clinicianStore: clinicianStore)

    init(appState: AppState, clinicianStore: ClinicianStore) {
        self.appState = appState
        self.clinicianStore = clinicianStore
    }

    @MainActor
    private func safeWrite(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: Data.WritingOptions.atomic)
    }

    /// Main entry – returns saved file URL
    @MainActor
    func exportReport(for kind: VisitKind, format: ReportFormat) throws -> URL {
        // 1) Build rich text + suggested base name
        let (attributed, suggestedStem) = try buildAttributedReport(for: kind)

        // 2) Ask destination
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedStem + (format == .pdf ? ".pdf" : ".rtf")
        panel.allowedContentTypes = (format == .pdf ? [UTType.pdf] : [UTType.rtf])

        guard panel.runModal() == .OK, let dest = panel.url else {
            throw NSError(domain: "ReportExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "User cancelled or no URL"])
        }

        // 3) Write
        do {
            switch format {
            case .pdf:
                // Build report as two parts: body (no charts) and charts-only Pages.
                let (bodyAttr, chartsAttr) = try buildAttributedReportParts(for: kind)
                let bodyPDF = try makePDF(from: bodyAttr)

                // Prefer direct-drawn charts PDF (avoids text-layout clipping of big attachments).
                var chartsPDFData: Data? = nil
                if case .well(let visitID) = kind, let gs = dataLoader.loadGrowthSeriesForWell(visitID: visitID) {
                    chartsPDFData = try makeChartsPDFForWell(gs)
                } else if let chartsAttr = chartsAttr {
                    chartsPDFData = try makePDF(from: chartsAttr)
                }

                let finalPDF: Data
                if let chartsPDF = chartsPDFData {
                    finalPDF = try mergePDFs([bodyPDF, chartsPDF])
                } else {
                    finalPDF = bodyPDF
                }
                try finalPDF.write(to: dest, options: .atomic)
            case .rtf:
                guard let rtfData = attributed.rtf(
                    from: NSRange(location: 0, length: attributed.length),
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                ) else {
                    throw NSError(
                        domain: "ReportExport",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "RTF generation failed"]
                    )
                }
                try rtfData.write(to: dest, options: .atomic)
            }

            // 4) Reveal
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            return dest

        } catch {
            NSLog("[ReportExport] write failed: \(error)")
            throw error
        }
    }
    // Build split attributed content: body (no charts) + charts-only (if applicable)
    func buildAttributedReportParts(for kind: VisitKind) throws -> (body: NSAttributedString, charts: NSAttributedString?) {
        switch kind {
        case .well(let visitID):
            let data = try dataLoader.loadWell(visitID: visitID)
            let body = assembleAttributedWell_BodyOnly(data: data, visitID: visitID)
            let charts = assembleWellChartsOnly(data: data, visitID: visitID)
            return (body, charts)
        case .sick(let episodeID):
            let data = try dataLoader.loadSick(episodeID: episodeID)
            let (_, fallbackSections) = buildContent(for: kind)
            let all = assembleAttributedSick(data: data, fallbackSections: fallbackSections)
            return (all, nil)
        }
    }
    // Body-only variant of Well report (steps 1–12), excluding Step 13 charts
    func assembleAttributedWell_BodyOnly(data: WellReportData, visitID: Int) -> NSAttributedString {
        let content = NSMutableAttributedString()

        func para(_ text: String, font: NSFont, color: NSColor = .labelColor) {
            content.append(NSAttributedString(string: text + "\n",
                                              attributes: [.font: font, .foregroundColor: color]))
        }

        // Header block (Well)
        para("Well Visit Summary", font: .systemFont(ofSize: 20, weight: .semibold))
        let triad = "Created: \(humanDateTime(data.meta.createdAtISO) ?? "—")   •   Last Edited: \(humanDateTime(data.meta.updatedAtISO) ?? "—")   •   Report Generated: \(humanDateTime(data.meta.generatedAtISO) ?? "—")"
        para(triad, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        content.append(NSAttributedString(string: "\n"))

        para("Alias: \(data.meta.alias)   •   MRN: \(data.meta.mrn)", font: .systemFont(ofSize: 12))
        para("Name: \(data.meta.name)", font: .systemFont(ofSize: 12))
        let dobShortWell = humanDateOnly(data.meta.dobISO) ?? "—"
        let ageShortWell = {
            let pre = data.meta.ageAtVisit.trimmingCharacters(in: .whitespacesAndNewlines)
            if pre.isEmpty || pre == "—" {
                return computeAgeShort(dobISO: data.meta.dobISO, refISO: data.meta.visitDateISO)
            }
            return pre
        }()
        para("DOB: \(dobShortWell)   •   Sex: \(data.meta.sex)   •   Age at Visit: \(ageShortWell)", font: .systemFont(ofSize: 12))
        para("Visit Date: \(humanDateOnly(data.meta.visitDateISO) ?? "—")   •   Visit Type: \(data.meta.visitTypeReadable ?? "Well Visit")", font: .systemFont(ofSize: 12))
        para("Clinician: \(data.meta.clinicianName)", font: .systemFont(ofSize: 12))
        content.append(NSAttributedString(string: "\n"))

        // Steps 1–12 (copy of assembleAttributedWell up to just before Step 13)
        let headerFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 12)

        if let s = data.perinatalSummary, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            para("Perinatal Summary", font: headerFont)
            para(s, font: bodyFont)
            content.append(NSAttributedString(string: "\n"))
        }

        if !data.previousVisitFindings.isEmpty {
            para("Findings from Previous Well Visits", font: headerFont)
            for item in data.previousVisitFindings {
                var sub = item.title
                let rawDate = item.date.trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawDate.isEmpty {
                    let pretty = humanDateOnly(rawDate) ?? rawDate
                    if !pretty.isEmpty { sub = sub.replacingOccurrences(of: rawDate, with: pretty) }
                }

                // Restore Age printing for previous visits (computed from DOB and the visit date)
                let dobForAge = data.meta.dobISO.trimmingCharacters(in: .whitespacesAndNewlines)
                if !dobForAge.isEmpty && !rawDate.isEmpty {
                    let computed = computeAgeShort(dobISO: dobForAge, refISO: rawDate)
                    if computed != "—" {
                        if let r = sub.range(of: "Age —") {
                            sub.replaceSubrange(r, with: "Age \(computed)")
                        } else if !sub.contains("Age ") {
                            sub.append(" · Age \(computed)")
                        }
                    }
                }

                content.append(NSAttributedString(
                    string: sub + "\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                 .foregroundColor: NSColor.labelColor]
                ))

                if let f = item.findings, !f.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let lines = f.components(separatedBy: " • ")
                    for line in lines { para("• \(line)", font: bodyFont) }
                } else {
                    para("—", font: bodyFont)
                }
                content.append(NSAttributedString(string: "\n"))
            }
        }

        let _currentTitle = data.currentVisitTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !_currentTitle.isEmpty {
            para("Current Visit — \(_currentTitle)", font: headerFont)
            content.append(NSAttributedString(string: "\n"))
        }

        para("Parents’ Concerns", font: headerFont)
        let parentsText = (data.parentsConcerns?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? data.parentsConcerns! : "—"
        para(parentsText, font: bodyFont)
        content.append(NSAttributedString(string: "\n"))

        para("Feeding", font: headerFont)
        if data.feeding.isEmpty {
            para("—", font: bodyFont)
        } else {
            let feedOrder = ["Breastfeeding","Formula","Solids","Notes"]
            for key in feedOrder { if let v = data.feeding[key], !v.isEmpty { para("\(key): \(v)", font: bodyFont) } }
            let extra = data.feeding.keys.filter { !["Breastfeeding","Formula","Solids","Notes"].contains($0) }.sorted()
            for key in extra { if let v = data.feeding[key], !v.isEmpty { para("\(key): \(v)", font: bodyFont) } }
        }
        content.append(NSAttributedString(string: "\n"))

        para("Supplementation", font: headerFont)
        if data.supplementation.isEmpty {
            para("—", font: bodyFont)
        } else {
            let order = ["Vitamin D","Iron","Other","Notes"]
            for key in order { if let v = data.supplementation[key], !v.isEmpty { para("\(key): \(v)", font: bodyFont) } }
            let extra = data.supplementation.keys.filter { !["Vitamin D","Iron","Other","Notes"].contains($0) }.sorted()
            for key in extra { if let v = data.supplementation[key], !v.isEmpty { para("\(key): \(v)", font: bodyFont) } }
        }
        content.append(NSAttributedString(string: "\n"))

        para("Sleep", font: headerFont)
        if data.sleep.isEmpty {
            para("—", font: bodyFont)
        } else {
            let order = ["Total hours","Naps","Night wakings","Quality","Notes"]
            for key in order { if let v = data.sleep[key], !v.isEmpty { para("\(key): \(v)", font: bodyFont) } }
            let extra = data.sleep.keys.filter { !["Total hours","Naps","Night wakings","Quality","Notes"].contains($0) }.sorted()
            for key in extra { if let v = data.sleep[key], !v.isEmpty { para("\(key): \(v)", font: bodyFont) } }
        }
        content.append(NSAttributedString(string: "\n"))

        para("Developmental Evaluation", font: headerFont)
        if data.developmental.isEmpty {
            para("—", font: bodyFont)
        } else {
            let devOrder = ["Parent Concerns", "M-CHAT", "Developmental Test"]
            for key in devOrder { if let v = data.developmental[key], !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { para("\(key): \(v)", font: bodyFont) } }
            let extra = data.developmental.keys.filter { !["Parent Concerns","M-CHAT","Developmental Test"].contains($0) }.sorted()
            for key in extra { if let v = data.developmental[key], !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { para("\(key): \(v)", font: bodyFont) } }
        }
        content.append(NSAttributedString(string: "\n"))

        para("Age-specific Milestones", font: headerFont)
        let achieved = data.milestonesAchieved.0
        let total = data.milestonesAchieved.1
        para("Achieved: \(achieved)/\(total)", font: bodyFont)
        if data.milestoneFlags.isEmpty { para("No flags.", font: bodyFont) } else { for line in data.milestoneFlags { para("• \(line)", font: bodyFont) } }
        content.append(NSAttributedString(string: "\n"))

        para("Measurements", font: headerFont)
        if data.measurements.isEmpty {
            para("—", font: bodyFont)
        } else {
            let measOrder = ["Weight","Length","Head Circumference","Weight gain since discharge"]
            for key in measOrder { if let v = data.measurements[key], !v.isEmpty { para("\(key): \(v)", font: bodyFont) } }
            let extra = data.measurements.keys.filter { !["Weight","Length","Head Circumference","Weight gain since discharge"].contains($0) }.sorted()
            for key in extra { if let v = data.measurements[key], !v.isEmpty { para("\(key): \(v)", font: bodyFont) } }
        }
        content.append(NSAttributedString(string: "\n"))

        para("Physical Examination", font: headerFont)
        if data.physicalExamGroups.isEmpty {
            para("—", font: bodyFont)
        } else {
            for (groupTitle, lines) in data.physicalExamGroups {
                content.append(NSAttributedString(
                    string: groupTitle + "\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor]
                ))
                for line in lines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    para("• \(line)", font: bodyFont)
                }
            }
        }
        content.append(NSAttributedString(string: "\n"))

        para("Problem Listing", font: headerFont)
        let _problem = data.problemListing?.trimmingCharacters(in: .whitespacesAndNewlines)
        para((_problem?.isEmpty == false ? _problem! : "—"), font: bodyFont)
        content.append(NSAttributedString(string: "\n"))

        para("Conclusions", font: headerFont)
        let _conclusions = data.conclusions?.trimmingCharacters(in: .whitespacesAndNewlines)
        para((_conclusions?.isEmpty == false ? _conclusions! : "—"), font: bodyFont)
        content.append(NSAttributedString(string: "\n"))

        para("Anticipatory Guidance", font: headerFont)
        let _ag = data.anticipatoryGuidance?.trimmingCharacters(in: .whitespacesAndNewlines)
        para((_ag?.isEmpty == false ? _ag! : "—"), font: bodyFont)
        content.append(NSAttributedString(string: "\n"))

        para("Clinician Comments", font: headerFont)
        let _cc = data.clinicianComments?.trimmingCharacters(in: .whitespacesAndNewlines)
        para((_cc?.isEmpty == false ? _cc! : "—"), font: bodyFont)
        content.append(NSAttributedString(string: "\n"))

        para("Next Visit Date", font: headerFont)
        if let rawNext = data.nextVisitDate?.trimmingCharacters(in: .whitespacesAndNewlines), !rawNext.isEmpty {
            para(humanDateOnly(rawNext) ?? rawNext, font: bodyFont)
        } else {
            para("—", font: bodyFont)
        }
        content.append(NSAttributedString(string: "\n"))

        return content
    }

    // Charts-only pages for Well report (Step 13)
    func assembleWellChartsOnly(data: WellReportData, visitID: Int) -> NSAttributedString? {
        guard let gs = dataLoader.loadGrowthSeriesForWell(visitID: visitID) else { return nil }
        let content = NSMutableAttributedString()

        func para(_ text: String, font: NSFont, color: NSColor = .labelColor) {
            content.append(NSAttributedString(string: text + "\n",
                                              attributes: [.font: font, .foregroundColor: color]))
        }
        let headerFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 12)

        // Summary header for charts document
        para("Growth Charts", font: headerFont)
        let dobPretty = humanDateOnly(gs.dobISO) ?? gs.dobISO
        let cutPretty = humanDateOnly(gs.visitDateISO) ?? gs.visitDateISO
        let sexText = (gs.sex == .female) ? "Female" : "Male"
        para("Sex: \(sexText)   •   DOB: \(dobPretty)   •   Cutoff: \(cutPretty)", font: bodyFont)

        func range(_ pts: [ReportGrowth.Point]) -> String {
            guard let minA = pts.map({ $0.ageMonths }).min(), let maxA = pts.map({ $0.ageMonths }).max() else { return "0 points" }
            let nf = NumberFormatter(); nf.maximumFractionDigits = 1
            let lo = nf.string(from: NSNumber(value: minA)) ?? String(format: "%.1f", minA)
            let hi = nf.string(from: NSNumber(value: maxA)) ?? String(format: "%.1f", maxA)
            return "\(pts.count) point\(pts.count == 1 ? "" : "s") (\(lo)–\(hi) mo)"
        }
        para("Weight‑for‑Age: \(range(gs.wfa))", font: bodyFont)
        para("Length/Height‑for‑Age: \(range(gs.lhfa))", font: bodyFont)
        para("Head Circumference‑for‑Age: \(range(gs.hcfa))", font: bodyFont)
        content.append(NSAttributedString(string: "\n"))

        // Charts — each on its own page
        // Render charts sized to the page content width (capped at 18 cm) so they visually fill the page.
        let contentWidth = REPORT_PAGE_SIZE.width - (2 * REPORT_INSET)
        let max18cm: CGFloat = (18.0 / 2.54) * 72.0
        let renderWidth = min(contentWidth, max18cm)
        let aspect: CGFloat = 450.0 / 700.0   // match renderer's default aspect ratio
        let renderSize = CGSize(width: renderWidth, height: renderWidth * aspect)
        let images = ReportGrowthRenderer.renderAllCharts(series: gs, size: renderSize, drawWHO: true)
        for (idx, img) in images.enumerated() {
            if idx > 0 { content.append(pageBreak()) }
            let caption = (idx == 0 ? "Weight‑for‑Age" : (idx == 1 ? "Length/Height‑for‑Age" : "Head Circumference‑for‑Age"))
            content.append(centeredTitle(caption))
            content.append(attachmentStringFittedToContent(from: img, reservedTopBottom: 72))
            content.append(NSAttributedString(string: "\n\n"))
        }
        return content
    }
}

// MARK: - Content assembly from AppState

private extension ReportBuilder {

    // Centered title for figure pages
    private func centeredTitle(_ text: String) -> NSAttributedString {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        return NSAttributedString(
            string: text + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .paragraphStyle: p,
                .foregroundColor: NSColor.labelColor
            ]
        )
    }

    // Page break marker (form feed). AppKit respects this during layout.
    private func pageBreak() -> NSAttributedString {
        return NSAttributedString(string: "\u{000C}")
    }
    
    // Ensures the text system allocates the full rect for large images (no clipping to a single line).
    private final class FixedImageAttachmentCell: NSTextAttachmentCell {
        private let imageRef: NSImage
        private let fixedSize: NSSize

        init(image: NSImage, size: NSSize) {
            self.imageRef = image
            self.fixedSize = size
            super.init(imageCell: nil)
        }

        required init(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func cellSize() -> NSSize {
            return fixedSize
        }

        override func draw(withFrame cellFrame: NSRect,
                           in controlView: NSView?,
                           characterIndex charIndex: Int,
                           layoutManager: NSLayoutManager) {
            // Draw the image scaled to the reserved rect; respect flipped contexts.
            imageRef.draw(in: cellFrame,
                          from: NSRect(origin: .zero, size: imageRef.size),
                          operation: .sourceOver,
                          fraction: 1.0,
                          respectFlipped: true,
                          hints: nil)
        }
    }

    // Build a TIFF-backed attachment string, centered, scaled to maxWidth.
    private func attachmentString(from img: NSImage, maxWidth: CGFloat = 480) -> NSAttributedString {
        // Preserve the image exactly as rendered (e.g., 300‑dpi from ReportGrowthRenderer).
        // Only scale the displayed bounds in points when exceeding maxWidth.
        let srcSize = img.size
        let scaleFactor = min(1.0, maxWidth / max(srcSize.width, 1))
        let targetSize = NSSize(width: max(1, srcSize.width * scaleFactor),
                                height: max(1, srcSize.height * scaleFactor))

        // Use NSTextAttachment(image:) so we do NOT redraw or resample here.
        // Use a fixed-size attachment cell so layout reserves full height (prevents clipping to a single text line).
        let att = NSTextAttachment()
        att.attachmentCell = FixedImageAttachmentCell(image: img, size: targetSize)
        att.bounds = CGRect(origin: .zero, size: targetSize)

        let para = NSMutableParagraphStyle()
        para.alignment = .center

        let s = NSMutableAttributedString(attachment: att)
        s.addAttributes([.paragraphStyle: para], range: NSRange(location: 0, length: s.length))
        return s
    }
    
    // Build an attachment scaled to the printable content width of the PDF page.
    private func attachmentStringCappedToContentWidth(from img: NSImage,
                                                      pageSize: CGSize = CGSize(width: 8.5 * 72.0, height: 11 * 72.0),
                                                      inset: CGFloat = 36,
                                                      padding: CGFloat = 0) -> NSAttributedString {
        let contentWidth = max(1, pageSize.width - (2 * inset) - padding)
        return attachmentString(from: img, maxWidth: contentWidth)
    }
    
    // Build an attachment fitted to the page content rect (width & height),
    // reserving some vertical space for the caption and spacing.
    private func attachmentStringFittedToContent(from img: NSImage,
                                                 pageSize: CGSize = CGSize(width: 8.5 * 72.0, height: 11 * 72.0),
                                                 inset: CGFloat = 36,
                                                 reservedTopBottom: CGFloat = 72) -> NSAttributedString {
        let contentWidth  = max(1, pageSize.width  - (2 * inset))
        let contentHeight = max(1, pageSize.height - (2 * inset) - max(0, reservedTopBottom))

        // If height is limiting, compute the width that corresponds to the capped height.
        let widthIfHeightBounds = img.size.width * (contentHeight / max(1, img.size.height))
        let effectiveMaxWidth = min(contentWidth, widthIfHeightBounds)

        return attachmentString(from: img, maxWidth: effectiveMaxWidth)
    }

    // MARK: - Date helpers (human readable)
    private func parseISOorSQLite(_ s: String) -> Date? {
        // Try ISO8601 with fractional seconds first (10.13+)
        if #available(macOS 10.13, *) {
            let isoFrac = ISO8601DateFormatter()
            isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = isoFrac.date(from: s) { return d }
        }
        // Plain ISO8601
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }

        // SQLite & ISO variants (including microseconds)
        let fmts = [
            "yyyy-MM-dd HH:mm:ss.SSSSSS",        // SQLite microseconds
            "yyyy-MM-dd HH:mm:ss.SSS",           // SQLite millis
            "yyyy-MM-dd HH:mm:ss",               // SQLite default CURRENT_TIMESTAMP
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX", // ISO microseconds + TZ
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",    // ISO millis + TZ
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",        // ISO no fractional + TZ
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",      // ISO microseconds, no TZ
            "yyyy-MM-dd'T'HH:mm:ss.SSS",         // ISO millis, no TZ
            "yyyy-MM-dd'T'HH:mm:ss",             // ISO no fractional, no TZ
            "yyyy-MM-dd"                         // date-only
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        for f in fmts {
            df.dateFormat = f
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    private func humanDateOnly(_ s: String?) -> String? {
        guard let s = s, let d = parseISOorSQLite(s) else { return s }
        let out = DateFormatter()
        out.locale = Locale.current
        out.timeZone = .current
        out.dateStyle = .medium
        out.timeStyle = .none
        return out.string(from: d)
    }

    private func humanDateTime(_ s: String?) -> String? {
        guard let s = s, let d = parseISOorSQLite(s) else { return s }
        let out = DateFormatter()
        out.locale = Locale.current
        out.timeZone = .current
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: d)
    }

    private func humanizeIfDate(_ s: String) -> String {
        if let d = parseISOorSQLite(s) {
            let out = DateFormatter()
            out.locale = Locale.current
            out.timeZone = .current
            // Heuristic: if original had time, include time; else date only
            if s.contains(":") || s.contains("T") {
                out.dateStyle = .medium
                out.timeStyle = .short
            } else {
                out.dateStyle = .medium
                out.timeStyle = .none
            }
            return out.string(from: d)
        }
        return s
    }

    // Compute a short pediatric age display from DOB and reference date
    private func computeAgeShort(dobISO: String, refISO: String) -> String {
        guard let dob = parseISOorSQLite(dobISO),
              let ref = parseISOorSQLite(refISO),
              ref >= dob else { return "—" }
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day], from: dob, to: ref)
        let y = comps.year ?? 0
        let m = comps.month ?? 0
        let d = comps.day ?? 0
        if y == 0 && m == 0 { return "\(max(d,0))d" }          // < 1 month: days only
        if y == 0 && m < 6 { return d > 0 ? "\(m)m \(d)d" : "\(m)m" } // < 6 months: m + d
        if y == 0 { return "\(m)m" }                           // 6–11 months: months only
        return m > 0 ? "\(y)y \(m)m" : "\(y)y"                 // ≥ 12 months: y + m
    }

    struct Section { let title: String; let body: String }

    func buildContent(for kind: VisitKind) -> (meta: [String:String], sections: [Section]) {
        var sections: [Section] = []

        // Helpers via reflection to be resilient to naming differences
        func reflectString(_ any: Any, keys: [String]) -> String? {
            let m = Mirror(reflecting: any)
            for c in m.children {
                if let label = c.label, keys.contains(label),
                   let val = c.value as? String, !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return val
                }
            }
            return nil
        }

        // Patient display (robust to different field names)
        var patientName = "—"
        var dobISO = "—"
        var sex = "—"
        var mrn = "—"
        if let p = appState.selectedPatient {
            if let dn = reflectString(p, keys: ["displayName", "name"]) {
                patientName = dn
            } else {
                let first = reflectString(p, keys: ["firstName", "first_name"])
                let last  = reflectString(p, keys: ["lastName", "last_name"])
                let combined = [first, last].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !combined.isEmpty {
                    patientName = combined
                } else if let alias = reflectString(p, keys: ["alias", "alias_label"]) {
                    patientName = alias
                } else {
                    patientName = "Patient #\(reflectString(p, keys: ["id"]) ?? "")"
                }
            }
            if let dob = reflectString(p, keys: ["dobISO", "dateOfBirth", "dob"]) {
                dobISO = dob
            }
            if let sx = reflectString(p, keys: ["sex", "gender"]) {
                sex = sx
            }
            if let m = reflectString(p, keys: ["mrn"]) { mrn = m }
        }

        // Visit meta
        var visitType = ""
        var visitDate = ""
        switch kind {
        case .sick(let id):
            visitType = "Sick Visit"
            if let v = appState.visits.first(where: { $0.id == id }) { visitDate = v.dateISO }
        case .well(let id):
            visitType = "Well Visit"
            if let v = appState.visits.first(where: { $0.id == id }) { visitDate = v.dateISO }
        }
        if visitDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            visitDate = ISO8601DateFormatter().string(from: Date())
        }

        // Summary (already computed in AppState)
        if let s = appState.visitSummary {
            if let p = s.problems, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append(.init(title: "Problem Listing", body: p))
            }
            if let d = s.diagnosis, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append(.init(title: "Diagnosis", body: d))
            }
            if let c = s.conclusions, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append(.init(title: "Conclusions / Plan", body: c))
            }
        }

        // Perinatal / PMH snapshot
        if let prof = appState.currentPatientProfile {
            if let peri = prof.perinatalHistory, !peri.isEmpty {
                sections.append(.init(title: "Perinatal", body: peri))
            }
            if let pmh = prof.pmh, !pmh.isEmpty {
                sections.append(.init(title: "Past Medical History", body: pmh))
            }
            if let vacc = prof.vaccinationStatus, !vacc.isEmpty {
                sections.append(.init(title: "Vaccination", body: vacc))
            }
        }

        // Clinician signature
        var clinicianName = "—"
        if let uid = appState.activeUserID,
           let c = clinicianStore.users.first(where: { $0.id == uid }) {
            let first = reflectString(c, keys: ["firstName", "first_name"])
            let last  = reflectString(c, keys: ["lastName", "last_name"])
            let name  = [first, last].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            clinicianName = name.isEmpty ? "User #\(c.id)" : name
        }

        let meta: [String:String] = [
            "Patient": patientName,
            "DOB": dobISO,
            "Sex": sex,
            "MRN": mrn,
            "Visit Type": visitType,
            "Visit Date": visitDate,
            "Clinician": clinicianName
        ]

        return (meta, sections)
    }

    // Build rich text + suggested filename stem (no extension)
    func buildAttributedReport(for kind: VisitKind) throws -> (NSAttributedString, String) {
        // Use the shared data loader to get header/meta parity with iOS.
        switch kind {
        case .well(let visitID):
            let data = try dataLoader.loadWell(visitID: visitID)
            // Keep current sections for now; we will replace them section-by-section next steps.
            let (_, fallbackSections) = buildContent(for: kind)
            let attributed = assembleAttributedWell(data: data, fallbackSections: fallbackSections, visitID: visitID)
            let stem = makeFileStem(from: data.meta, fallbackType: "well")
            return (attributed, stem)
        case .sick(let episodeID):
            let data = try dataLoader.loadSick(episodeID: episodeID)
            let (_, fallbackSections) = buildContent(for: kind)
            let attributed = assembleAttributedSick(data: data, fallbackSections: fallbackSections)
            let stem = makeFileStem(from: data.meta, fallbackType: "sick")
            return (attributed, stem)
        }
    }

    // Compose attributed content used for both PDF/RTF
    func assembleAttributed(meta: [String:String], sections: [Section]) -> NSAttributedString {
        let content = NSMutableAttributedString()

        func para(_ text: String, font: NSFont, color: NSColor = .labelColor) {
            content.append(NSAttributedString(string: text + "\n",
                                              attributes: [.font: font, .foregroundColor: color]))
        }

        para("Clinical Report", font: .systemFont(ofSize: 20, weight: .semibold))
        let pretty = Dictionary(uniqueKeysWithValues: meta.map { (k, v) in (k, humanizeIfDate(v)) })
        let metaLine = pretty.sorted(by: { $0.key < $1.key })
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "   •   ")
        para(metaLine, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        content.append(NSAttributedString(string: "\n"))

        for s in sections {
            para(s.title, font: .systemFont(ofSize: 14, weight: .semibold))
            para(s.body, font: .systemFont(ofSize: 12))
            content.append(NSAttributedString(string: "\n"))
        }

        return content
    }

    // Assemble Well Visit header exactly like iOS; append current fallback sections for now.
    func assembleAttributedWell(data: WellReportData, fallbackSections: [Section], visitID: Int) -> NSAttributedString {
        let content = NSMutableAttributedString()

        func para(_ text: String, font: NSFont, color: NSColor = .labelColor) {
            content.append(NSAttributedString(string: text + "\n",
                                              attributes: [.font: font, .foregroundColor: color]))
        }

        // Header block (Well)
        para("Well Visit Summary", font: .systemFont(ofSize: 20, weight: .semibold))
        let triad = "Created: \(humanDateTime(data.meta.createdAtISO) ?? "—")   •   Last Edited: \(humanDateTime(data.meta.updatedAtISO) ?? "—")   •   Report Generated: \(humanDateTime(data.meta.generatedAtISO) ?? "—")"
        para(triad, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        content.append(NSAttributedString(string: "\n"))

        para("Alias: \(data.meta.alias)   •   MRN: \(data.meta.mrn)", font: .systemFont(ofSize: 12))
        para("Name: \(data.meta.name)", font: .systemFont(ofSize: 12))
        let dobShortWell = humanDateOnly(data.meta.dobISO) ?? "—"
        let ageShortWell = {
            let pre = data.meta.ageAtVisit.trimmingCharacters(in: .whitespacesAndNewlines)
            if pre.isEmpty || pre == "—" { // treat em-dash placeholder as missing
                return computeAgeShort(dobISO: data.meta.dobISO, refISO: data.meta.visitDateISO)
            }
            return pre
        }()
        para("DOB: \(dobShortWell)   •   Sex: \(data.meta.sex)   •   Age at Visit: \(ageShortWell)", font: .systemFont(ofSize: 12))
        para("Visit Date: \(humanDateOnly(data.meta.visitDateISO) ?? "—")   •   Visit Type: \(data.meta.visitTypeReadable ?? "Well Visit")", font: .systemFont(ofSize: 12))
        para("Clinician: \(data.meta.clinicianName)", font: .systemFont(ofSize: 12))
        content.append(NSAttributedString(string: "\n"))

        // --- Step 1: Perinatal Summary ---
        let headerFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 12)
        if let s = data.perinatalSummary, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            para("Perinatal Summary", font: headerFont)
            para(s, font: bodyFont)
            content.append(NSAttributedString(string: "\n"))
        }
        
        // --- Step 2: Findings from Previous Well Visits ---
        if !data.previousVisitFindings.isEmpty {
            para("Findings from Previous Well Visits", font: headerFont)
            for item in data.previousVisitFindings {
                // Subheader for each prior visit (humanized date) — avoid conditional binding on non-optional
                var sub = item.title
                let rawDate = item.date.trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawDate.isEmpty {
                    let pretty = humanDateOnly(rawDate) ?? rawDate
                    if !pretty.isEmpty {
                        sub = sub.replacingOccurrences(of: rawDate, with: pretty)
                    }
                }
                NSLog("[ReportBuilder] PrevWell sub='%@'  rawDate='%@'  hasAge=%@", sub, rawDate, sub.contains("Age ") ? "yes" : "no")
                // If the loader didn't compute an age (or left "Age —"), compute it here using the bundle DOB + raw date
                let dobForAge = data.meta.dobISO.trimmingCharacters(in: .whitespacesAndNewlines)
                let rawForAge = rawDate
                if !dobForAge.isEmpty && !rawForAge.isEmpty {
                    let computed = computeAgeShort(dobISO: dobForAge, refISO: rawForAge)
                    if computed != "—" {
                        if let r = sub.range(of: "Age —") {
                            sub.replaceSubrange(r, with: "Age \(computed)")
                        } else if !sub.contains("Age ") {
                            sub.append(" · Age \(computed)")
                        }
                    }
                }
                content.append(NSAttributedString(
                    string: sub + "\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                 .foregroundColor: NSColor.labelColor]
                ))
                // Render findings (split our joined bullets back into lines)
                if let f = item.findings, !f.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let lines = f.components(separatedBy: " • ")
                    for line in lines {
                        para("• \(line)", font: bodyFont)
                    }
                } else {
                    para("—", font: bodyFont)
                }
                content.append(NSAttributedString(string: "\n"))
            }
        }

        // --- Step 3: Current Visit (subtitle) + Parents' Concerns + Feeding + Supplementation + Sleep ---
        let _currentTitle = data.currentVisitTitle
        let _currentTitleTrimmed = _currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !_currentTitleTrimmed.isEmpty {
            para("Current Visit — \(_currentTitleTrimmed)", font: headerFont)
            content.append(NSAttributedString(string: "\n"))
        }

        // Parents’ Concerns
        para("Parents’ Concerns", font: headerFont)
        let parentsText = (data.parentsConcerns?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? data.parentsConcerns! : "—"
        para(parentsText, font: bodyFont)
        content.append(NSAttributedString(string: "\n"))

        // Feeding
        para("Feeding", font: headerFont)
        if data.feeding.isEmpty {
            para("—", font: bodyFont)
        } else {
            let feedOrder = ["Breastfeeding","Formula","Solids","Notes"]
            for key in feedOrder {
                if let v = data.feeding[key], !v.isEmpty { para("\(key): \(v)", font: bodyFont) }
            }
            let extraFeed = data.feeding.keys.filter { !["Breastfeeding","Formula","Solids","Notes"].contains($0) }.sorted()
            for key in extraFeed {
                if let v = data.feeding[key], !v.isEmpty { para("\(key): \(v)", font: bodyFont) }
            }
        }
        content.append(NSAttributedString(string: "\n"))

        // Supplementation
        para("Supplementation", font: headerFont)
        if data.supplementation.isEmpty {
            para("—", font: bodyFont)
        } else {
            let suppOrder = ["Vitamin D","Iron","Other","Notes"]
            for key in suppOrder {
                if let v = data.supplementation[key], !v.isEmpty { para("\(key): \(v)", font: bodyFont) }
            }
            let extraSupp = data.supplementation.keys.filter { !["Vitamin D","Iron","Other","Notes"].contains($0) }.sorted()
            for key in extraSupp {
                if let v = data.supplementation[key], !v.isEmpty { para("\(key): \(v)", font: bodyFont) }
            }
        }
        content.append(NSAttributedString(string: "\n"))

        // Sleep
        para("Sleep", font: headerFont)
        if data.sleep.isEmpty {
            para("—", font: bodyFont)
        } else {
            let sleepOrder = ["Total hours","Naps","Night wakings","Quality","Notes"]
            for key in sleepOrder {
                if let v = data.sleep[key], !v.isEmpty { para("\(key): \(v)", font: bodyFont) }
            }
            let extraSleep = data.sleep.keys.filter { !["Total hours","Naps","Night wakings","Quality","Notes"].contains($0) }.sorted()
            for key in extraSleep {
                if let v = data.sleep[key], !v.isEmpty { para("\(key): \(v)", font: bodyFont) }
            }
        }
        content.append(NSAttributedString(string: "\n"))

        // --- Step 4: Developmental Evaluation (M-CHAT / Dev test / Parent Concerns) ---
        para("Developmental Evaluation", font: headerFont)
        if data.developmental.isEmpty {
            para("—", font: bodyFont)
        } else {
            // Preferred order first, then any extras
            let devOrder = ["Parent Concerns", "M-CHAT", "Developmental Test"]
            for key in devOrder {
                if let v = data.developmental[key], !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    para("\(key): \(v)", font: bodyFont)
                }
            }
            let extraDev = data.developmental.keys
                .filter { !["Parent Concerns","M-CHAT","Developmental Test"].contains($0) }
                .sorted()
            for key in extraDev {
                if let v = data.developmental[key], !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    para("\(key): \(v)", font: bodyFont)
                }
            }
        }
        content.append(NSAttributedString(string: "\n"))

        // --- Step 5: Age-specific Milestones (Achieved X/Y + Flags) ---
        para("Age-specific Milestones", font: headerFont)
        let achieved = data.milestonesAchieved.0
        let total = data.milestonesAchieved.1
        para("Achieved: \(achieved)/\(total)", font: bodyFont)
        if data.milestoneFlags.isEmpty {
            para("No flags.", font: bodyFont)
        } else {
            for line in data.milestoneFlags {
                para("• \(line)", font: bodyFont)
            }
        }
        content.append(NSAttributedString(string: "\n"))

        // --- Step 6: Measurements (today’s W/L/HC + weight-gain since discharge) ---
        para("Measurements", font: headerFont)
        if data.measurements.isEmpty {
            para("—", font: bodyFont)
        } else {
            let measOrder = ["Weight","Length","Head Circumference","Weight gain since discharge"]
            for key in measOrder {
                if let v = data.measurements[key], !v.isEmpty {
                    para("\(key): \(v)", font: bodyFont)
                }
            }
            let extraMeas = data.measurements.keys
                .filter { !["Weight","Length","Head Circumference","Weight gain since discharge"].contains($0) }
                .sorted()
            for key in extraMeas {
                if let v = data.measurements[key], !v.isEmpty {
                    para("\(key): \(v)", font: bodyFont)
                }
            }
        }
        content.append(NSAttributedString(string: "\n"))

        // --- Step 7: Physical Examination (grouped like iOS) ---
        para("Physical Examination", font: headerFont)
        if data.physicalExamGroups.isEmpty {
            para("—", font: bodyFont)
        } else {
            for (groupTitle, lines) in data.physicalExamGroups {
                content.append(NSAttributedString(
                    string: groupTitle + "\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                 .foregroundColor: NSColor.labelColor]
                ))
                for line in lines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    para("• \(line)", font: bodyFont)
                }
            }
        }
        content.append(NSAttributedString(string: "\n"))

        // --- Step 8: Problem Listing ---
        para("Problem Listing", font: headerFont)
        let _problem = data.problemListing?.trimmingCharacters(in: .whitespacesAndNewlines)
        para((_problem?.isEmpty == false ? _problem! : "—"), font: bodyFont)
        content.append(NSAttributedString(string: "\n"))

        // --- Step 9: Conclusions ---
        para("Conclusions", font: headerFont)
        let _conclusions = data.conclusions?.trimmingCharacters(in: .whitespacesAndNewlines)
        para((_conclusions?.isEmpty == false ? _conclusions! : "—"), font: bodyFont)
        content.append(NSAttributedString(string: "\n"))

        // --- Step 10: Anticipatory Guidance ---
        para("Anticipatory Guidance", font: headerFont)
        let _ag = data.anticipatoryGuidance?.trimmingCharacters(in: .whitespacesAndNewlines)
        para((_ag?.isEmpty == false ? _ag! : "—"), font: bodyFont)
        content.append(NSAttributedString(string: "\n"))

        // --- Step 11: Clinician Comments ---
        para("Clinician Comments", font: headerFont)
        let _cc = data.clinicianComments?.trimmingCharacters(in: .whitespacesAndNewlines)
        para((_cc?.isEmpty == false ? _cc! : "—"), font: bodyFont)
        content.append(NSAttributedString(string: "\n"))

        // --- Step 12: Next Visit Date (optional) ---
        para("Next Visit Date", font: headerFont)
        if let rawNext = data.nextVisitDate?.trimmingCharacters(in: .whitespacesAndNewlines), !rawNext.isEmpty {
            para(humanDateOnly(rawNext) ?? rawNext, font: bodyFont)
        } else {
            para("—", font: bodyFont)
        }
        content.append(NSAttributedString(string: "\n"))

        // --- Step 13: Growth Charts (summary up to visit date) ---
        para("Growth Charts", font: headerFont)
        if let gs = dataLoader.loadGrowthSeriesForWell(visitID: visitID) {
            let dobPretty = humanDateOnly(gs.dobISO) ?? gs.dobISO
            let cutPretty = humanDateOnly(gs.visitDateISO) ?? gs.visitDateISO
            let sexText = (gs.sex == .female) ? "Female" : "Male"
            para("Sex: \(sexText)   •   DOB: \(dobPretty)   •   Cutoff: \(cutPretty)", font: bodyFont)

            func range(_ pts: [ReportGrowth.Point]) -> String {
                guard let minA = pts.map({ $0.ageMonths }).min(),
                      let maxA = pts.map({ $0.ageMonths }).max() else { return "0 points" }
                let nf = NumberFormatter(); nf.maximumFractionDigits = 1
                let lo = nf.string(from: NSNumber(value: minA)) ?? String(format: "%.1f", minA)
                let hi = nf.string(from: NSNumber(value: maxA)) ?? String(format: "%.1f", maxA)
                return "\(pts.count) point\(pts.count == 1 ? "" : "s") (\(lo)–\(hi) mo)"
            }

            para("Weight‑for‑Age: \(range(gs.wfa))", font: bodyFont)
            para("Length/Height‑for‑Age: \(range(gs.lhfa))", font: bodyFont)
            para("Head Circumference‑for‑Age: \(range(gs.hcfa))", font: bodyFont)
        } else {
            para("—", font: bodyFont)
        }
        content.append(NSAttributedString(string: "\n"))
        // Force Growth Charts to start on a new page
        content.append(pageBreak())

        // Render actual chart images (WFA, L/HFA, HCFA) — each chart on its own page
        if let gs = dataLoader.loadGrowthSeriesForWell(visitID: visitID) {
            let contentWidth = REPORT_PAGE_SIZE.width - (2 * REPORT_INSET)
            let max18cm: CGFloat = (18.0 / 2.54) * 72.0
            let renderWidth = min(contentWidth, max18cm)
            let aspect: CGFloat = 450.0 / 700.0
            let renderSize = CGSize(width: renderWidth, height: renderWidth * aspect)
            let images = ReportGrowthRenderer.renderAllCharts(series: gs, size: renderSize, drawWHO: true)

            content.append(NSAttributedString(string: "\n"))
            for (idx, img) in images.enumerated() {
                // Put each chart on its own page
                if idx > 0 {
                    content.append(pageBreak())
                }
                let caption = (idx == 0 ? "Weight‑for‑Age" : (idx == 1 ? "Length/Height‑for‑Age" : "Head Circumference‑for‑Age"))
                content.append(centeredTitle(caption))
                content.append(attachmentStringFittedToContent(from: img, reservedTopBottom: 72))
                content.append(NSAttributedString(string: "\n\n"))
            }
        }

        return content
    }

    // Assemble Sick Visit header parity; append current fallback sections.
    func assembleAttributedSick(data: SickReportData, fallbackSections: [Section]) -> NSAttributedString {
        let content = NSMutableAttributedString()

        func para(_ text: String, font: NSFont, color: NSColor = .labelColor) {
            content.append(NSAttributedString(string: text + "\n",
                                              attributes: [.font: font, .foregroundColor: color]))
        }

        // Header block (Sick)
        para("Sick Visit Report", font: .systemFont(ofSize: 20, weight: .semibold))
        let triad = "Created: \(humanDateTime(data.meta.createdAtISO) ?? "—")   •   Last Edited: \(humanDateTime(data.meta.updatedAtISO) ?? "—")   •   Report Generated: \(humanDateTime(data.meta.generatedAtISO) ?? "—")"
        para(triad, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        content.append(NSAttributedString(string: "\n"))

        para("Alias: \(data.meta.alias)   •   MRN: \(data.meta.mrn)", font: .systemFont(ofSize: 12))
        para("Name: \(data.meta.name)", font: .systemFont(ofSize: 12))
        let dobShortSick = humanDateOnly(data.meta.dobISO) ?? "—"
        let ageShortSick = {
            let pre = data.meta.ageAtVisit.trimmingCharacters(in: .whitespacesAndNewlines)
            if pre.isEmpty || pre == "—" { // treat em-dash placeholder as missing
                return computeAgeShort(dobISO: data.meta.dobISO, refISO: data.meta.visitDateISO)
            }
            return pre
        }()
        para("DOB: \(dobShortSick)   •   Sex: \(data.meta.sex)   •   Age at Visit: \(ageShortSick)", font: .systemFont(ofSize: 12))
        para("Visit Date: \(humanDateOnly(data.meta.visitDateISO) ?? "—")", font: .systemFont(ofSize: 12))
        para("Clinician: \(data.meta.clinicianName)", font: .systemFont(ofSize: 12))
        content.append(NSAttributedString(string: "\n"))
        
        // --- New: render core Sick sections from data (Step 2) ---
        let headerFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 12)

        func section(_ title: String, _ body: String?) {
            para(title, font: headerFont)
            let text = (body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? body! : "—"
            para(text, font: bodyFont)
            content.append(NSAttributedString(string: "\n"))
        }

        // 8) Main Complaint
        section("Main Complaint", data.mainComplaint)
        // 9) History of Present Illness
        section("History of Present Illness", data.hpi)
        // 10) Duration
        section("Duration", data.duration)
        // 11) Basics (Feeding · Urination · Breathing · Pain · Context)
        if !data.basics.isEmpty {
            para("Basics", font: headerFont)
            let order = ["Feeding","Urination","Breathing","Pain","Context"]
            for key in order {
                if let val = data.basics[key], !val.isEmpty {
                    para("\(key): \(val)", font: bodyFont)
                }
            }
            content.append(NSAttributedString(string: "\n"))
        }
        // 12) Past Medical History
        section("Past Medical History", data.pmh)

        // 13) Vaccination
        section("Vaccination", data.vaccination)

        // 14) Vitals Summary (flagged items)
        para("Vitals Summary", font: headerFont)
        if data.vitalsSummary.isEmpty {
            para("—", font: bodyFont)
        } else {
            for line in data.vitalsSummary {
                para("• \(line)", font: bodyFont)
            }
        }
        content.append(NSAttributedString(string: "\n"))

        // 15) Physical Examination (grouped)
        para("Physical Examination", font: headerFont)
        if data.physicalExamGroups.isEmpty {
            para("—", font: bodyFont)
        } else {
            for group in data.physicalExamGroups {
                para(group.group, font: NSFont.systemFont(ofSize: 13, weight: .semibold))
                for line in group.lines {
                    para("• \(line)", font: bodyFont)
                }
            }
        }
        content.append(NSAttributedString(string: "\n"))

        // 16) Problem Listing
        section("Problem Listing", data.problemListing)

        // 17) Investigations
        para("Investigations", font: headerFont)
        if data.investigations.isEmpty {
            para("—", font: bodyFont)
        } else {
            for item in data.investigations {
                para("• \(item)", font: bodyFont)
            }
        }
        content.append(NSAttributedString(string: "\n"))

        // 18) Working Diagnosis
        section("Working Diagnosis", data.workingDiagnosis)

        // 19) ICD-10
        let icdStr: String? = {
            if let tuple = data.icd10 {
                if tuple.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return tuple.code
                } else {
                    return "\(tuple.code) — \(tuple.label)"
                }
            }
            return nil
        }()
        section("ICD-10", icdStr)

        // 20) Plan & Anticipatory Guidance
        section("Plan & Anticipatory Guidance", data.planGuidance)

        // 21) Medications
        para("Medications", font: headerFont)
        if data.medications.isEmpty {
            para("—", font: bodyFont)
        } else {
            for m in data.medications {
                para("• \(m)", font: bodyFont)
            }
        }
        content.append(NSAttributedString(string: "\n"))

        // 22) Clinician Comments
        section("Clinician Comments", data.clinicianComments)

        // 23) Follow-up / Next Visit
        section("Follow-up / Next Visit", data.nextVisitDate)
        

        
        return content
    }

    // Create a sensible filename stem (no extension)
    func makeFileStem(meta: [String:String]) -> String {
        func slug(_ s: String) -> String {
            var out = s
            let bad: [String] = [":", "/", "\\", "*", "?", "\"", "<", ">", "|", "\n", "\r", "\t"]
            for ch in bad { out = out.replacingOccurrences(of: ch, with: "-") }
            out = out.replacingOccurrences(of: " ", with: "_")
            return out
        }
        let patient = slug(meta["Patient"] ?? "patient")
        let type = slug(meta["Visit Type"] ?? "visit").lowercased()
        let dateStr = meta["Visit Date"].flatMap { $0.isEmpty ? nil : $0 }
                     ?? ISO8601DateFormatter().string(from: Date())
        let date = slug(dateStr)
        return "\(patient)_\(type)_report_\(date)"
    }

    // New overload for file naming based on ReportMeta
    func makeFileStem(from meta: ReportMeta, fallbackType: String) -> String {
        func slug(_ s: String) -> String {
            var out = s
            let bad: [String] = [":", "/", "\\", "*", "?", "\"", "<", ">", "|", "\n", "\r", "\t"]
            for ch in bad { out = out.replacingOccurrences(of: ch, with: "-") }
            out = out.replacingOccurrences(of: " ", with: "_")
            return out
        }
        let patient = slug(meta.name.isEmpty ? meta.alias : meta.name)
        let type = slug((meta.visitTypeReadable ?? fallbackType).lowercased())
        let date = slug(meta.visitDateISO)
        return "\(patient)_\(type)_report_\(date)"
    }

    // Legacy helper that expects an extension; kept for internal callers
    func makeFileName(meta: [String:String], ext: String) -> String {
        return makeFileStem(meta: meta) + ".\(ext)"
    }
}

// MARK: - Rendering

private extension ReportBuilder {

    // Render an attributed string into paginated PDF data
    // Render an attributed string into paginated PDF data (supports image attachments)
    // Render an attributed string into paginated PDF data (multi-container pagination)
    func makePDF(from attributed: NSAttributedString,
                 pageSize: CGSize = REPORT_PAGE_SIZE,
                 inset: CGFloat = REPORT_INSET) throws -> Data {
        // Layout rects
        let contentRect = CGRect(
            x: inset,
            y: inset,
            width: pageSize.width - inset * 2,
            height: pageSize.height - inset * 2
        )

        // Prepare PDF context
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw NSError(domain: "ReportExport", code: 100,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create PDF consumer"])
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "ReportExport", code: 101,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create PDF context"])
        }

        // Ensure visible text color (avoid white-on-white on some systems)
        let base = NSMutableAttributedString(attributedString: attributed)
        base.addAttribute(.foregroundColor, value: NSColor.black,
                          range: NSRange(location: 0, length: base.length))

        // --- Respect manual page breaks (form feed U+000C) ---
        // Split the attributed string into segments separated by form-feed characters;
        // each segment will start on a new PDF page sequence.
        let fullNSString = base.string as NSString
        let fullLength = fullNSString.length
        var breakRanges: [NSRange] = []
        fullNSString.enumerateSubstrings(in: NSRange(location: 0, length: fullLength),
                                         options: [.byComposedCharacterSequences]) { (substr, subRange, _, _) in
            if substr == "\u{000C}" { breakRanges.append(subRange) }
        }

        var segments: [NSAttributedString] = []
        var cursor = 0
        for br in breakRanges {
            let segLen = br.location - cursor
            let segRange = NSRange(location: cursor, length: max(0, segLen))
            // Append content before the break; allow empty segment to yield a blank page on purpose
            segments.append(base.attributedSubstring(from: segRange))
            cursor = br.location + br.length
        }
        if cursor <= fullLength {
            let tailLen = fullLength - cursor
            let tailRange = NSRange(location: cursor, length: max(0, tailLen))
            segments.append(base.attributedSubstring(from: tailRange))
        }
        if segments.isEmpty { segments = [base] }

        // Paginate each segment independently; this guarantees that a form feed forces a new page.
        for segment in segments {
            let storage = NSTextStorage(attributedString: segment)
            let layoutManager = NSLayoutManager()
            layoutManager.usesFontLeading = true
            layoutManager.usesDefaultHyphenation = false
            layoutManager.allowsNonContiguousLayout = false
            storage.addLayoutManager(layoutManager)

            var glyphLocation = 0
            let totalGlyphs = layoutManager.numberOfGlyphs

            while glyphLocation < totalGlyphs {
                // New page container sized to the content area
                let container = NSTextContainer(size: contentRect.size)
                container.lineFragmentPadding = 0
                container.maximumNumberOfLines = 0
                layoutManager.addTextContainer(container)

                layoutManager.ensureLayout(for: container)
                let glyphRange = layoutManager.glyphRange(for: container)
                if glyphRange.length == 0 { break }

                // New page
                ctx.beginPDFPage(nil)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(mediaBox)

                // Draw using a flipped AppKit context (origin at top-left). No manual CG flips.
                NSGraphicsContext.saveGraphicsState()
                let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
                NSGraphicsContext.current = nsCtx

                // Ensure clean text state
                ctx.textMatrix = .identity

                // Mirror the entire content area across a horizontal axis (vertical flip of full page content)
                ctx.saveGState()
                ctx.translateBy(x: contentRect.minX, y: contentRect.minY + contentRect.height)
                ctx.scaleBy(x: 1.0, y: -1.0)
                layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)
                layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
                ctx.restoreGState()

                // Cleanup
                NSGraphicsContext.current = nil
                NSGraphicsContext.restoreGraphicsState()
                ctx.endPDFPage()

                glyphLocation = glyphRange.location + glyphRange.length
            }

            // If the segment is intentionally empty (e.g., two FF in a row), emit a blank page
            if totalGlyphs == 0 {
                ctx.beginPDFPage(nil)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(mediaBox)
                ctx.endPDFPage()
            }
        }

        ctx.closePDF()
        return data as Data
    }

    // (Kept in case you want RTF by path later)
    func renderRTF(meta: [String:String], sections: [Section]) throws -> Data {
        assembleAttributed(meta: meta, sections: sections)
            .rtf(from: NSRange(location: 0, length: assembleAttributed(meta: meta, sections: sections).length),
                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])!
    }

    /// If a patient bundle is open, save to its Docs/, else fallback to ~/Documents/DrsMainApp/Reports/
    func makeDestinationURL(meta: [String:String], ext: String) throws -> URL {
        let fm = FileManager.default
        let suggested = makeFileName(meta: meta, ext: ext)

        if let bundle = appState.currentBundleURL {
            let docs = bundle.appendingPathComponent("Docs", isDirectory: true)
            try fm.createDirectory(at: docs, withIntermediateDirectories: true)
            return docs.appendingPathComponent(suggested)
        } else {
            let docs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/DrsMainApp/Reports", isDirectory: true)
            try fm.createDirectory(at: docs, withIntermediateDirectories: true)
            return docs.appendingPathComponent(suggested)
        }
    }
}

// MARK: - Convenience overloads kept for callers

@MainActor
extension ReportBuilder {
    func exportPDF(for kind: VisitKind) throws -> URL {
        try exportReport(for: kind, format: .pdf)
    }
    func exportRTF(for kind: VisitKind) throws -> URL {
        try exportReport(for: kind, format: .rtf)
    }
}

    // Merge multiple PDF Data blobs into a single PDF
    func mergePDFs(_ parts: [Data]) throws -> Data {
        let out = PDFDocument()
        var pageCursor = 0
        for (partIndex, d) in parts.enumerated() {
            guard let doc = PDFDocument(data: d) else {
                throw NSError(domain: "ReportExport", code: 200 + partIndex,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to read intermediate PDF part #\(partIndex+1)"])
            }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) {
                    out.insert(page, at: pageCursor)
                    pageCursor += 1
                }
            }
        }
        guard let data = out.dataRepresentation() else {
            throw NSError(domain: "ReportExport", code: 299,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create merged PDF data"])
        }
        return data
    }

    // Draw charts directly into a PDF (one per page), bypassing text layout.
    private func makeChartsPDFForWell(_ series: ReportDataLoader.ReportGrowthSeries,
                                      pageSize: CGSize = REPORT_PAGE_SIZE,
                                      inset: CGFloat = REPORT_INSET) throws -> Data {
        // Page geometry
        let contentRect = CGRect(x: inset, y: inset,
                                 width: pageSize.width - 2*inset,
                                 height: pageSize.height - 2*inset)

        // Compute target logical render size (respect 18 cm cap)
        let max18cm: CGFloat = (18.0 / 2.54) * 72.0
        let renderW = min(contentRect.width, max18cm)
        // Keep the renderer's default aspect (matches 700x450)
        let aspect: CGFloat = 450.0 / 700.0
        let renderH = renderW * aspect
        let renderSize = CGSize(width: renderW, height: renderH)

        // Render images at 300 dpi via the renderer
        let images = ReportGrowthRenderer.renderAllCharts(series: series, size: renderSize, drawWHO: true)

        // Prepare PDF context
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw NSError(domain: "ReportExport", code: 310, userInfo: [NSLocalizedDescriptionKey: "ChartsPDF: consumer failed"])
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "ReportExport", code: 311, userInfo: [NSLocalizedDescriptionKey: "ChartsPDF: context failed"])
        }

        for (idx, img) in images.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(mediaBox)

            // Draw using a non-flipped context and explicit coordinates (origin = bottom-left).
            NSGraphicsContext.saveGraphicsState()
            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.current = nsCtx

            // Caption at the top of the content rect
            let caption = (idx == 0 ? "Weight‑for‑Age" : (idx == 1 ? "Length/Height‑for‑Age" : "Head Circumference‑for‑Age"))
            let p = NSMutableParagraphStyle(); p.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .paragraphStyle: p,
                .foregroundColor: NSColor.black
            ]
            let cap = NSAttributedString(string: caption, attributes: attrs)
            let capH: CGFloat = 18.0
            let capRect = CGRect(x: contentRect.minX,
                                 y: contentRect.maxY - capH,
                                 width: contentRect.width,
                                 height: capH)
            cap.draw(in: capRect)

            // Image rect: fit to content width and available height below caption (preserve aspect)
            let availableH = contentRect.height - capH - 8
            let imgW = min(renderW, contentRect.width)
            let imgH = min(renderH, availableH)
            let imgX = contentRect.midX - imgW / 2
            let imgY = capRect.minY - 8 - imgH
            let imgRect = CGRect(x: imgX, y: imgY, width: imgW, height: imgH)

            // Draw image without additional flipping; coordinates are bottom-left based
            img.draw(in: imgRect,
                     from: NSRect(origin: .zero, size: img.size),
                     operation: .sourceOver,
                     fraction: 1.0,
                     respectFlipped: false,
                     hints: nil)

            NSGraphicsContext.current = nil
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }

        ctx.closePDF()
        return data as Data
    }
