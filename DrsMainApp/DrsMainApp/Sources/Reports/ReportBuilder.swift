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
fileprivate let DEBUG_REPORT_EXPORT: Bool = true


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
                if DEBUG_REPORT_EXPORT {
                    let ffCount = bodyAttr.string.reduce(0) { $1 == "\u{000C}" ? $0 + 1 : $0 }
                    NSLog("[ReportDebug] bodyAttr FF count = %d", ffCount)
                }
                let bodyPDF0 = try makePDF(from: bodyAttr)
                let bodyPDF  = trimmedPDF(bodyPDF0, trimLeading: false, trimTrailing: true)
                if DEBUG_REPORT_EXPORT, let doc = PDFDocument(data: bodyPDF) {
                    NSLog("[ReportDebug] bodyPDF pages (after trim) = %d", doc.pageCount)
                }
                if DEBUG_REPORT_EXPORT {
                    if let doc = PDFDocument(data: bodyPDF) {
                        NSLog("[ReportDebug] bodyPDF pages = %d", doc.pageCount)
                    }
                    _ = debugDumpPDF(bodyPDF, name: "Body")
                }

                // Prefer direct-drawn charts PDF (avoids text-layout clipping of big attachments).
                var chartsPDFData: Data? = nil
                if case .well(let visitID) = kind, let gs = dataLoader.loadGrowthSeriesForWell(visitID: visitID) {
                    let charts0 = try makeChartsPDFForWell(gs)
                    chartsPDFData = trimmedPDF(charts0, trimLeading: true, trimTrailing: false)
                } else if let chartsAttr = chartsAttr {
                    let charts0 = try makePDF(from: chartsAttr)
                    chartsPDFData = trimmedPDF(charts0, trimLeading: true, trimTrailing: false)
                }
                if DEBUG_REPORT_EXPORT, let chartsPDF = chartsPDFData, let doc = PDFDocument(data: chartsPDF) {
                    NSLog("[ReportDebug] chartsPDF pages (after trim) = %d", doc.pageCount)
                }
                if DEBUG_REPORT_EXPORT, let chartsPDF = chartsPDFData {
                    if let doc = PDFDocument(data: chartsPDF) {
                        NSLog("[ReportDebug] chartsPDF pages = %d", doc.pageCount)
                    }
                    _ = debugDumpPDF(chartsPDF, name: "Charts")
                }

                let finalPDF: Data
                if let chartsPDF = chartsPDFData {
                    finalPDF = try mergePDFs([bodyPDF, chartsPDF])
                } else {
                    finalPDF = bodyPDF
                }
                if DEBUG_REPORT_EXPORT {
                    if let doc = PDFDocument(data: finalPDF) {
                        NSLog("[ReportDebug] mergedPDF pages = %d", doc.pageCount)
                    }
                    _ = debugDumpPDF(finalPDF, name: "Merged")
                }
                try finalPDF.write(to: dest, options: .atomic)
            case .rtf:
                do {
                    // Build a single‑file RTF that embeds charts inline as \pict\pngblip (no RTFD).
                    // We reuse the user‑chosen `dest` URL (already ".rtf" from the save panel).
                    
                    // Helper: strip everything from the "Growth Charts" header onward (body only).
                    func bodyWithoutCharts(_ full: NSAttributedString) -> NSAttributedString {
                        let ns = full.string as NSString
                        let r = ns.range(of: "Growth Charts")
                        if r.location != NSNotFound && r.location > 0 {
                            return full.attributedSubstring(from: NSRange(location: 0, length: r.location))
                        }
                        return full
                    }
                    
                    switch kind {
                    case .well(let visitID):
                        // Build the well report body without the charts section.
                        let wellData = try dataLoader.loadWell(visitID: visitID)
                        // Use the same header/body formatting as elsewhere, then trim charts out.
                        let fullBody = assembleAttributedWell(data: wellData,
                                                              fallbackSections: buildContent(for: kind).sections,
                                                              visitID: visitID)
                        let bodyOnly = bodyWithoutCharts(fullBody)
                        
                        // Render charts sized like in PDF (cap width at ~18 cm, keep renderer aspect 700:450).
                        let contentWidth = REPORT_PAGE_SIZE.width - (2 * REPORT_INSET)
                        let max18cm: CGFloat = (18.0 / 2.54) * 72.0
                        let renderWidth = min(contentWidth, max18cm)
                        let aspect: CGFloat = 450.0 / 700.0
                        let renderSize = CGSize(width: renderWidth, height: renderWidth * aspect)
                        
                        if let gs = dataLoader.loadGrowthSeriesForWell(visitID: visitID) {
                            let images = ReportGrowthRenderer.renderAllCharts(series: gs, size: renderSize, drawWHO: true)
                            let captions = ["Weight-for-Age", "Length/Height-for-Age", "Head Circumference-for-Age"]
                            let tuples: [(image: NSImage, goalSizePts: CGSize)] = images.map { (image: $0, goalSizePts: renderSize) }
                            // Assemble a single-file RTF by appending inline PNG/TIFF pictures to the body.
                            let rtfData = try makeSingleFileRTFInline(body: bodyOnly, charts: tuples, captions: captions)
                            try rtfData.write(to: dest, options: .atomic)
                        } else {
                            // No charts available — export body-only as plain RTF.
                            let range = NSRange(location: 0, length: bodyOnly.length)
                            guard let rtfData = bodyOnly.rtf(from: range,
                                                             documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else {
                                throw NSError(domain: "ReportExport", code: 3004,
                                              userInfo: [NSLocalizedDescriptionKey: "RTF body-only generation failed"])
                            }
                            try rtfData.write(to: dest, options: .atomic)
                        }
                        
                    case .sick:
                        // Sick reports have no charts; export the attributed body directly.
                        let range = NSRange(location: 0, length: attributed.length)
                        guard let rtfData = attributed.rtf(from: range,
                                                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else {
                            throw NSError(domain: "ReportExport", code: 3005,
                                          userInfo: [NSLocalizedDescriptionKey: "RTF generation failed (sick)"])
                        }
                        try rtfData.write(to: dest, options: .atomic)
                    }
                }
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
        if DEBUG_REPORT_EXPORT {
            for (idx, img) in images.enumerated() {
                debugLogImage(img, label: "chartsOnly[\(idx)]", targetSize: renderSize)
                _ = debugDumpImage(img, name: "chartsOnly_\(idx)")
            }
        }
        for (idx, img) in images.enumerated() {
            if idx > 0 { content.append(pageBreak()) }
            let caption = (idx == 0 ? "Weight‑for‑Age" : (idx == 1 ? "Length/Height‑for‑Age" : "Head Circumference‑for‑Age"))
            content.append(centeredTitle(caption))
            content.append(attachmentStringFittedToContent(from: img, reservedTopBottom: 72))
            content.append(NSAttributedString(string: "\n\n"))
        }
        return content
    }
    
    // Charts-only pages for Well report (RTF variant with PNG-embedded attachments)
    func assembleWellChartsRTF(data: WellReportData, visitID: Int) -> NSAttributedString? {
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
        content.append(NSAttributedString(string: "\n"))

        // Render charts sized to the page content width (capped at 18 cm).
        let contentWidth = REPORT_PAGE_SIZE.width - (2 * REPORT_INSET)
        let max18cm: CGFloat = (18.0 / 2.54) * 72.0
        let renderWidth = min(contentWidth, max18cm)
        let aspect: CGFloat = 450.0 / 700.0
        let renderSize = CGSize(width: renderWidth, height: renderWidth * aspect)
        let images = ReportGrowthRenderer.renderAllCharts(series: gs, size: renderSize, drawWHO: true)

        for (idx, img) in images.enumerated() {
            if idx > 0 { content.append(pageBreak()) }
            let caption = (idx == 0 ? "Weight-for-Age" : (idx == 1 ? "Length/Height-for-Age" : "Head Circumference-for-Age"))
            content.append(centeredTitle(caption))
            // Use RTF-specific attachment so PNG is embedded and layout reserves full height.
            content.append(attachmentStringRTFFittedToContent(from: img, pageSize: REPORT_PAGE_SIZE, inset: REPORT_INSET, reservedTopBottom: 72))
            content.append(NSAttributedString(string: "\n\n"))
        }
        return content
    }
}

// MARK: - Content assembly from AppState

extension ReportBuilder {

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
    
    // Build a TIFF payload from an NSImage (most compatible for single-file RTF embedding, \pict)
    private func bestTIFFData(from img: NSImage) -> Data? {
        // Prefer the highest-resolution bitmap rep if available
        if let rep = img.representations.compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            return rep.tiffRepresentation
        }
        // Fallback via NSImage.tiffRepresentation
        if let tiff = img.tiffRepresentation {
            return tiff
        }
        return nil
    }

    // Build a PNG file wrapper from an NSImage for clean RTF embedding.
    private func bestPNGData(from img: NSImage) -> Data? {
        // Prefer highest-resolution bitmap rep
        if let rep = img.representations.compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        // Fallback via TIFF -> NSBitmapImageRep -> PNG
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }

    // RTF-specific attachment that embeds an image as an image-based attachment (TIFF-backed), centered and scaled.
    private func attachmentStringRTF(from img: NSImage,
                                     maxWidth: CGFloat = 480) -> NSAttributedString {
        let srcSize = img.size
        let scale = min(1.0, maxWidth / max(srcSize.width, 1))
        let targetSize = NSSize(width: max(1, srcSize.width * scale),
                                height: max(1, srcSize.height * scale))

        // Use an AppKit-compatible attachment: NSTextAttachment + standard image cell.
        // This path serializes to single-file RTF by embedding TIFF (\pict), not requiring RTFD.
        let att = NSTextAttachment()
        att.attachmentCell = NSTextAttachmentCell(imageCell: img)
        att.bounds = CGRect(origin: .zero, size: targetSize)

        let para = NSMutableParagraphStyle()
        para.alignment = .center

        let s = NSMutableAttributedString(attachment: att)
        s.addAttributes([NSAttributedString.Key.paragraphStyle: para] as [NSAttributedString.Key : Any],
                        range: NSRange(location: 0, length: s.length))
        return s
    }

    // RTF attachment scaled to the printable content width of the page.
    private func attachmentStringRTFCappedToContentWidth(from img: NSImage,
                                                         pageSize: CGSize = CGSize(width: 8.5 * 72.0, height: 11 * 72.0),
                                                         inset: CGFloat = 36,
                                                         padding: CGFloat = 0) -> NSAttributedString {
        let contentWidth = max(1, pageSize.width - (2 * inset) - padding)
        return attachmentStringRTF(from: img, maxWidth: contentWidth)
    }

    // RTF attachment fitted to page content rect (respects caption spacing reservation).
    private func attachmentStringRTFFittedToContent(from img: NSImage,
                                                    pageSize: CGSize = CGSize(width: 8.5 * 72.0, height: 11 * 72.0),
                                                    inset: CGFloat = 36,
                                                    reservedTopBottom: CGFloat = 72) -> NSAttributedString {
        let contentWidth  = max(1, pageSize.width  - (2 * inset))
        let contentHeight = max(1, pageSize.height - (2 * inset) - max(0, reservedTopBottom))
        let widthIfHeightBounds = img.size.width * (contentHeight / max(1, img.size.height))
        let effectiveMaxWidth = min(contentWidth, widthIfHeightBounds)
        return attachmentStringRTF(from: img, maxWidth: effectiveMaxWidth)
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

extension ReportBuilder {

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

        }

        ctx.closePDF()
        return data as Data
    }
    
    // === Single‑file RTF (inline \pict) helpers – Step 1 (no behavior change yet) ===

    /// Convert points to twips for RTF (\picwgoal/\pichgoal expect twips).
    private func twips(_ points: CGFloat) -> Int {
        return Int((points * 20.0).rounded())
    }

    /// Produce PNG data and pixel dimensions from NSImage (prefers highest‑res bitmap rep).
    private func pngDataAndPixels(from img: NSImage) -> (data: Data, pxW: Int, pxH: Int)? {
        // Prefer largest bitmap rep
        if let rep = img.representations.compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, rep.pixelsWide, rep.pixelsHigh)
        }
        // Fallback via TIFF
        if let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, rep.pixelsWide, rep.pixelsHigh)
        }
        return nil
    }

    /// Produce JPEG data and pixel dimensions from NSImage (prefers highest‑res bitmap rep).
    private func jpegDataAndPixels(from img: NSImage, quality: CGFloat = 0.85) -> (data: Data, pxW: Int, pxH: Int)? {
        let props: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: quality]
        if let rep = img.representations.compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }),
           let jpg = rep.representation(using: .jpeg, properties: props) {
            return (jpg, rep.pixelsWide, rep.pixelsHigh)
        }
        if let tiff = img.tiffRepresentation,
           let rep  = NSBitmapImageRep(data: tiff),
           let jpg  = rep.representation(using: .jpeg, properties: props) {
            return (jpg, rep.pixelsWide, rep.pixelsHigh)
        }
        return nil
    }

    /// Produce a single‑page PDF from an NSImage at the requested logical size (points).
    /// Returns PDF data and logical "pixel" dimensions consistent with \blipupi72 (points = px).
    private func pdfDataFromImage(_ img: NSImage, sizePts: CGSize) -> (data: Data, pxW: Int, pxH: Int)? {
        let w = max(1.0, sizePts.width)
        let h = max(1.0, sizePts.height)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var box = CGRect(origin: .zero, size: CGSize(width: w, height: h))
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(box)

        // Draw the image to fill the page, preserving its aspect inside the target rect.
        let target = box
        ctx.saveGState()
        ctx.interpolationQuality = .high
        if let cg = bestCGImage(from: img) {
            // Fit preserving aspect
            let iw = CGFloat(cg.width)
            let ih = CGFloat(cg.height)
            let sx = target.width / max(iw, 1)
            let sy = target.height / max(ih, 1)
            let s = min(sx, sy)
            let dw = iw * s
            let dh = ih * s
            let dx = target.midX - dw / 2
            let dy = target.midY - dh / 2
            ctx.draw(cg, in: CGRect(x: dx, y: dy, width: dw, height: dh))
        } else {
            // Fallback via NSImage drawing in a non‑flipped context
            NSGraphicsContext.saveGraphicsState()
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.current = ns
            img.draw(in: target,
                     from: NSRect(origin: .zero, size: img.size),
                     operation: .sourceOver,
                     fraction: 1.0,
                     respectFlipped: false,
                     hints: nil)
            NSGraphicsContext.current = nil
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.restoreGState()
        ctx.endPDFPage()
        ctx.closePDF()
        return (data as Data, Int(w.rounded()), Int(h.rounded()))
    }
    
    /// Produce TIFF data and pixel dimensions from NSImage (prefers highest-res bitmap rep).
    private func tiffDataAndPixels(from img: NSImage) -> (data: Data, pxW: Int, pxH: Int)? {
        if let rep = img.representations.compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }),
           let tiff = rep.tiffRepresentation {
            return (tiff, rep.pixelsWide, rep.pixelsHigh)
        }
        if let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            return (tiff, rep.pixelsWide, rep.pixelsHigh)
        }
        return nil
    }
    
    // Escape to pure ASCII for safe RTF concatenation (avoid UTF-8 in RTF stream)
    private func rtfEscapeASCII(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 16)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\":
                out += "\\\\"
            case "{":
                out += "\\{"
            case "}":
                out += "\\}"
            case "\n":
                out += "\\par "
            default:
                let v = scalar.value
                if v < 0x80 {
                    out.append(String(scalar))
                } else {
                    // Map common punctuation to ASCII so we keep the whole file 7-bit
                    switch v {
                    case 0x2011, 0x2013, 0x2014: // non-breaking hyphen, en dash, em dash
                        out += "-"
                    case 0x2022: // bullet
                        out += "*"
                    case 0x00A0: // nbsp
                        out += " "
                    default:
                        out += "?" // safe fallback for other Unicode
                    }
                }
            }
        }
        return out
    }

    /// Hex‑encode data for RTF \pict blocks (group into short lines for readability).
    private func rtfHex(from data: Data, breakEvery: Int = 128) -> String {
        var s = ""
        s.reserveCapacity(data.count * 2 + data.count / (breakEvery / 2) + 8)
        var col = 0
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for b in bytes {
                s.append(String(format: "%02X", b))
                col += 2
                if col >= breakEvery {
                    s.append("\n")
                    col = 0
                }
            }
        }
        return s
    }

    /// Build a **single‑file RTF** by taking the body RTF from AppKit and appending inline PNG/TIFF pictures.
    private func makeSingleFileRTFInline(body: NSAttributedString,
                                         charts: [(image: NSImage, goalSizePts: CGSize)],
                                         captions: [String] = []) throws -> Data {
        // 1) Base RTF from AppKit (ASCII with RTF escapes)
        let full = NSRange(location: 0, length: body.length)
        guard let bodyRTF = body.rtf(from: full,
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else {
            throw NSError(domain: "ReportExport", code: 3001,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create base RTF for body"])
        }

        // Decode as ASCII only (avoid UTF-8 multibyte characters in RTF stream)
        guard var rtf = String(data: bodyRTF, encoding: .ascii) else {
            throw NSError(domain: "ReportExport", code: 3002,
                          userInfo: [NSLocalizedDescriptionKey: "Body RTF is not ASCII-serializable"])
        }

        // 2) Remove the final closing brace of the root group safely
        if let idx = rtf.lastIndex(of: Character("}")) {
            rtf.remove(at: idx)
        } else {
            // If not found, fall back to a minimal header
            rtf = "{\\rtf1\\ansi\\deff0\\uc1\n"
        }

        // 3) Append each chart page as ASCII-only RTF (caption + \\pict hex)
        for (i, chart) in charts.enumerated() {
            // page break before each chart
            rtf += "\\par\\page\n"

            // Centered caption (ASCII-escaped)
            if i < captions.count {
                let cap = rtfEscapeASCII(captions[i])
                rtf += "{\\pard\\qc \\fs24 "
                rtf += cap
                rtf += "\\par}\n"
            }

            // Prefer PDF (\pdfblip) for Cocoa RTF readers (TextEdit/Pages), then JPEG, then PNG.
            let wGoal = twips(chart.goalSizePts.width)
            let hGoal = twips(chart.goalSizePts.height)

            var embedded = false

            // --- PDF first ---
            if let (pdf, pxW, pxH) = pdfDataFromImage(chart.image, sizePts: chart.goalSizePts) {
                rtf += "{\\pard\\plain\\qc\n"
                rtf += "{\\pict\\pdfblip"
                rtf += "\\picw\(pxW)\\pich\(pxH)"
                rtf += "\\blipupi72"
                rtf += "\\picscalex100\\picscaley100"
                rtf += "\\picwgoal\(wGoal)\\pichgoal\(hGoal)\n"
                rtf += rtfHex(from: pdf)
                rtf += "}\n\\par}\n"
                embedded = true
                if DEBUG_REPORT_EXPORT {
                    NSLog("[ReportDebug] RTF inline chart#%d: pdfBytes=%d px=(%d×%d) goalPts=(%.1f×%.1f)",
                          i, pdf.count, pxW, pxH, chart.goalSizePts.width, chart.goalSizePts.height)
                    debugDumpMinimalRTFInlinePDF(pdfData: pdf,
                                                 pxW: pxW, pxH: pxH,
                                                 goalPts: chart.goalSizePts,
                                                 caption: (i < captions.count ? captions[i] : "Chart #\(i+1)"))
                }
            }

            // --- JPEG fallback ---
            if !embedded, let (jpgData, pxW, pxH) = jpegDataAndPixels(from: chart.image, quality: 0.85) {
                rtf += "{\\pard\\plain\\qc\n"
                rtf += "{\\pict\\jpegblip"
                rtf += "\\picw\(pxW)\\pich\(pxH)"
                rtf += "\\blipupi96"
                rtf += "\\picscalex100\\picscaley100"
                rtf += "\\picwgoal\(wGoal)\\pichgoal\(hGoal)\n"
                rtf += rtfHex(from: jpgData)
                rtf += "}\n\\par}\n"
                embedded = true
                if DEBUG_REPORT_EXPORT {
                    NSLog("[ReportDebug] RTF inline chart#%d: jpegBytes=%d px=(%d×%d) goalPts=(%.1f×%.1f)",
                          i, jpgData.count, pxW, pxH, chart.goalSizePts.width, chart.goalSizePts.height)
                    debugDumpMinimalRTFInlineJPEG(jpegData: jpgData,
                                                  pxW: pxW, pxH: pxH,
                                                  goalPts: chart.goalSizePts,
                                                  caption: (i < captions.count ? captions[i] : "Chart #\(i+1)"))
                }
            }

            // --- PNG fallback ---
            if !embedded, let (pngData, pxW, pxH) = pngDataAndPixels(from: chart.image) {
                rtf += "{\\pard\\plain\\qc\n"
                rtf += "{\\pict\\pngblip"
                rtf += "\\picw\(pxW)\\pich\(pxH)"
                rtf += "\\blipupi96"
                rtf += "\\picscalex100\\picscaley100"
                rtf += "\\picwgoal\(wGoal)\\pichgoal\(hGoal)\n"
                rtf += rtfHex(from: pngData)
                rtf += "}\n\\par}\n"
                embedded = true
                if DEBUG_REPORT_EXPORT {
                    NSLog("[ReportDebug] RTF inline chart#%d: pngBytes=%d px=(%d×%d) goalPts=(%.1f×%.1f)",
                          i, pngData.count, pxW, pxH, chart.goalSizePts.width, chart.goalSizePts.height)
                    debugDumpMinimalRTFInlinePNG(pngData: pngData,
                                                 pxW: pxW, pxH: pxH,
                                                 goalPts: chart.goalSizePts,
                                                 caption: (i < captions.count ? captions[i] : "Chart #\(i+1)"))
                }
            }

            if !embedded {
                NSLog("[ReportExport] All encodings (PDF/JPEG/PNG) failed for chart index \(i); skipping")
                continue
            }
        }

        // 4) Close root group and return ASCII data
        rtf += "}\n"
        guard let out = rtf.data(using: .ascii, allowLossyConversion: false) else {
            throw NSError(domain: "ReportExport", code: 3003,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to encode final RTF as ASCII"])
        }
        return out
    }

    // MARK: - Debug helpers

    /// Write a tiny, self‑contained RTF with one inline PDF \pict block to DebugExports.
    private func debugDumpMinimalRTFInlinePDF(pdfData: Data,
                                              pxW: Int, pxH: Int,
                                              goalPts: CGSize,
                                              caption: String) {
        let wGoal = twips(goalPts.width)
        let hGoal = twips(goalPts.height)
        var s = ""
        s += "{\\rtf1\\ansi\\ansicpg1252\\deff0\\deflang1033\\uc1\n"
        s += "{\\fonttbl{\\f0 Helvetica;}}\n"
        s += "{\\colortbl;\\red0\\green0\\blue0;}\n"
        s += "{\\pard\\qc\\f0\\fs24 "
        s += rtfEscapeASCII(caption)
        s += "\\par}\n"
        s += "{\\pard\\qc\n"
        s += "{\\pict\\pdfblip"
        s += "\\picw\(pxW)\\pich\(pxH)"
        s += "\\blipupi72"
        s += "\\picscalex100\\picscaley100"
        s += "\\picwgoal\(wGoal)\\pichgoal\(hGoal)\n"
        s += rtfHex(from: pdfData)
        s += "}\n\\par}\n"
        s += "}\n"
        if let data = s.data(using: .ascii) {
            let url = debugDir().appendingPathComponent("RTF-Minimal-PDF-\(debugTimestamp()).rtf")
            do {
                try data.write(to: url, options: .atomic)
                NSLog("[ReportDebug] wrote minimal PDF RTF probe %@", url.path)
            } catch {
                NSLog("[ReportDebug] write failed for minimal PDF RTF probe: %@", String(describing: error))
            }
        } else {
            NSLog("[ReportDebug] ASCII encoding failed for minimal PDF RTF probe")
        }
    }

    /// Write a tiny, self-contained RTF with just one inline PNG \pict block to DebugExports.
    /// This helps isolate whether the embedded block renders in viewers (TextEdit/Pages).
    private func debugDumpMinimalRTFInlinePNG(pngData: Data,
                                              pxW: Int, pxH: Int,
                                              goalPts: CGSize,
                                              caption: String) {
        let wGoal = twips(goalPts.width)
        let hGoal = twips(goalPts.height)
        var s = ""
        s += "{\\rtf1\\ansi\\ansicpg1252\\deff0\\deflang1033\\uc1\n"
        s += "{\\fonttbl{\\f0 Helvetica;}}\n"
        s += "{\\colortbl;\\red0\\green0\\blue0;}\n"
        s += "{\\pard\\qc\\f0\\fs24 "
        s += rtfEscapeASCII(caption)
        s += "\\par}\n"
        s += "{\\pard\\qc\n"
        s += "{\\pict\\pngblip"
        s += "\\picw\(pxW)\\pich\(pxH)"
        s += "\\blipupi96"
        s += "\\picscalex100\\picscaley100"
        s += "\\picwgoal\(wGoal)\\pichgoal\(hGoal)\n"
        s += rtfHex(from: pngData)
        s += "}\n\\par}\n"
        s += "}\n"
        if let data = s.data(using: .ascii) {
            let url = debugDir().appendingPathComponent("RTF-Minimal-\(debugTimestamp()).rtf")
            do {
                try data.write(to: url, options: .atomic)
                NSLog("[ReportDebug] wrote minimal RTF probe %@", url.path)
            } catch {
                NSLog("[ReportDebug] write failed for minimal RTF probe: %@", String(describing: error))
            }
        } else {
            NSLog("[ReportDebug] ASCII encoding failed for minimal RTF probe")
        }
    }

    /// Write a tiny, self-contained RTF with one inline JPEG \pict block to DebugExports.
    private func debugDumpMinimalRTFInlineJPEG(jpegData: Data,
                                               pxW: Int, pxH: Int,
                                               goalPts: CGSize,
                                               caption: String) {
        let wGoal = twips(goalPts.width)
        let hGoal = twips(goalPts.height)
        var s = ""
        s += "{\\rtf1\\ansi\\ansicpg1252\\deff0\\deflang1033\\uc1\n"
        s += "{\\fonttbl{\\f0 Helvetica;}}\n"
        s += "{\\colortbl;\\red0\\green0\\blue0;}\n"
        s += "{\\pard\\qc\\f0\\fs24 "
        s += rtfEscapeASCII(caption)
        s += "\\par}\n"
        s += "{\\pard\\qc\n"
        s += "{\\pict\\jpegblip"
        s += "\\picw\(pxW)\\pich\(pxH)"
        s += "\\blipupi96"
        s += "\\picscalex100\\picscaley100"
        s += "\\picwgoal\(wGoal)\\pichgoal\(hGoal)\n"
        s += rtfHex(from: jpegData)
        s += "}\n\\par}\n"
        s += "}\n"
        if let data = s.data(using: .ascii) {
            let url = debugDir().appendingPathComponent("RTF-Minimal-JPEG-\(debugTimestamp()).rtf")
            do {
                try data.write(to: url, options: .atomic)
                NSLog("[ReportDebug] wrote minimal JPEG RTF probe %@", url.path)
            } catch {
                NSLog("[ReportDebug] write failed for minimal JPEG RTF probe: %@", String(describing: error))
            }
        } else {
            NSLog("[ReportDebug] ASCII encoding failed for minimal JPEG RTF probe")
        }
    }
    private func debugTimestamp() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return df.string(from: Date())
    }

    private func debugDir() -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("Documents/DrsMainApp/DebugExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    /// Zip a directory into a single .zip file using /usr/bin/zip.
    /// Throws on failure so caller can surface the issue; directory remains usable.
    private func zipDirectory(at dir: URL, to zipFile: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: zipFile.path) {
            try? fm.removeItem(at: zipFile)
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.currentDirectoryURL = dir.deletingLastPathComponent()
        task.arguments = ["-r", "-y", zipFile.lastPathComponent, dir.lastPathComponent]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = pipe
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            NSLog("[ReportExport] zip failed (%d): %@", task.terminationStatus, out)
            throw NSError(domain: "ReportExport", code: 4001,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to zip RTFD at \(dir.path)"])
        }
    }

    // ==== DOCX (Office Open XML) helpers ====

    /// Escape text for XML.
    private func docxEscapeXML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 16)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// EMU (English Metric Unit) from points. 1 pt = 12700 EMU.
    private func emuFromPoints(_ pts: CGFloat) -> Int {
        return Int((pts * 12700.0).rounded())
    }

    /// Zip the **contents** of a directory so the files appear at the root of the zip (required for .docx).
    private func zipDocxPackage(at packageRoot: URL, to zipFile: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: zipFile.path) { try? fm.removeItem(at: zipFile) }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.currentDirectoryURL = packageRoot
        // Zip everything at root (not the folder itself)
        task.arguments = ["-r", "-y", zipFile.path, "."]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = pipe
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            NSLog("[ReportExport] docx zip failed (%d): %@", task.terminationStatus, out)
            throw NSError(domain: "ReportExport", code: 5001,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to zip DOCX at \(packageRoot.path)"])
        }
    }

    // Overload that supports styled paragraphs (Heading1, Heading2, etc.)
    private func writeDocxPackage(title: String,
                                  styledParagraphs: [(text: String, style: String?)],
                                  images: [(data: Data, filename: String, sizePts: CGSize)],
                                  destinationURL: URL) throws {
        let fm = FileManager.default

        // Create a temp build root
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DocxBuild-\(UUID().uuidString)", isDirectory: true)
        let relsDir = root.appendingPathComponent("_rels", isDirectory: true)
        let wordDir = root.appendingPathComponent("word", isDirectory: true)
        let wordRelsDir = wordDir.appendingPathComponent("_rels", isDirectory: true)
        let mediaDir = wordDir.appendingPathComponent("media", isDirectory: true)
        let propsDir = root.appendingPathComponent("docProps", isDirectory: true)
        try fm.createDirectory(at: relsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: wordRelsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: propsDir, withIntermediateDirectories: true)

        // Write images to word/media
        for (i, img) in images.enumerated() {
            let name = img.filename.isEmpty ? "image\(i+1).png" : img.filename
            try img.data.write(to: mediaDir.appendingPathComponent(name))
        }

        // === [Content_Types].xml ===
        let contentTypes =
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Default Extension="png" ContentType="image/png"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
          <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
          <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        </Types>
        """
        try contentTypes.data(using: .utf8)!.write(to: root.appendingPathComponent("[Content_Types].xml"))

        // === _rels/.rels ===
        let rootRels =
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """
        try rootRels.data(using: .utf8)!.write(to: relsDir.appendingPathComponent(".rels"))

        // === docProps/core.xml ===
        let now = ISO8601DateFormatter().string(from: Date())
        let coreXML =
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
          xmlns:dc="http://purl.org/dc/elements/1.1/"
          xmlns:dcterms="http://purl.org/dc/terms/"
          xmlns:dcmitype="http://purl.org/dc/dcmitype/"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <dc:title>\(docxEscapeXML(title))</dc:title>
          <dc:creator>DrsMainApp</dc:creator>
          <cp:lastModifiedBy>DrsMainApp</cp:lastModifiedBy>
          <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created>
          <dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified>
        </cp:coreProperties>
        """
        try coreXML.data(using: .utf8)!.write(to: propsDir.appendingPathComponent("core.xml"))

        // === docProps/app.xml ===
        let appXML =
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"
          xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
          <Application>DrsMainApp</Application>
        </Properties>
        """
        try appXML.data(using: .utf8)!.write(to: propsDir.appendingPathComponent("app.xml"))

        // === word/_rels/document.xml.rels ===
        var rels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        """
        for (i, img) in images.enumerated() {
            let name = img.filename.isEmpty ? "image\(i+1).png" : img.filename
            rels += """
              <Relationship Id="rId\(i+1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/\(name)"/>
            """
        }
        // Add Styles relationship after the images, using the next available rId
        let stylesRelId = images.count + 1
        rels += """
          <Relationship Id="rId\(stylesRelId)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        """
        rels += "\n</Relationships>\n"
        try rels.data(using: .utf8)!.write(to: wordRelsDir.appendingPathComponent("document.xml.rels"))

        // === word/styles.xml ===
        let stylesXML =
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
            <w:name w:val="Normal"/>
            <w:rPr>
              <w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica" w:cs="Helvetica"/>
              <w:sz w:val="22"/><w:szCs w:val="22"/>
            </w:rPr>
            <w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Title">
            <w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:qFormat/>
            <w:rPr><w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica" w:cs="Helvetica"/><w:b/><w:sz w:val="40"/><w:szCs w:val="40"/></w:rPr>
            <w:pPr><w:spacing w:after="180"/></w:pPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Heading1">
            <w:name w:val="Heading 1"/><w:basedOn w:val="Normal"/><w:qFormat/>
            <w:rPr><w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica" w:cs="Helvetica"/><w:b/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr>
            <w:pPr><w:spacing w:before="120" w:after="120"/></w:pPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Heading2">
            <w:name w:val="Heading 2"/><w:basedOn w:val="Normal"/><w:qFormat/>
            <w:rPr><w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica" w:cs="Helvetica"/><w:b/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr>
            <w:pPr><w:spacing w:before="80" w:after="80"/></w:pPr>
          </w:style>
        </w:styles>
        """
        try stylesXML.data(using: .utf8)!.write(to: wordDir.appendingPathComponent("styles.xml"))

        // === word/document.xml (apply styles per paragraph) ===
        var body = ""
        // Title paragraph (use Title style)
        body += """
        <w:p>
          <w:pPr><w:pStyle w:val="Title"/></w:pPr>
          <w:r><w:t>\(docxEscapeXML(title))</w:t></w:r>
        </w:p>
        """
        for (text, style) in styledParagraphs {
            let t = docxEscapeXML(text)
            if let st = style, !st.isEmpty {
                body += """
                <w:p>
                  <w:pPr><w:pStyle w:val="\(st)"/></w:pPr>
                  <w:r><w:t>\(t)</w:t></w:r>
                </w:p>
                """
            } else {
                body += "<w:p><w:r><w:t>\(t)</w:t></w:r></w:p>"
            }
        }
        for (i, img) in images.enumerated() {
            let cx = emuFromPoints(img.sizePts.width)
            let cy = emuFromPoints(img.sizePts.height)
            body +=
            """
            <w:p>
              <w:r>
                <w:drawing>
                  <wp:inline distT="0" distB="0" distL="0" distR="0"
                    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">
                    <wp:extent cx="\(cx)" cy="\(cy)"/>
                    <wp:docPr id="\(100 + i)" name="Chart \(i+1)"/>
                    <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
                      <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                        <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
                          <pic:nvPicPr>
                            <pic:cNvPr id="\(i+1)" name="chart\(i+1).png"/>
                            <pic:cNvPicPr/>
                          </pic:nvPicPr>
                          <pic:blipFill>
                            <a:blip r:embed="rId\(i+1)" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/>
                            <a:stretch><a:fillRect/></a:stretch>
                          </pic:blipFill>
                          <pic:spPr>
                            <a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>
                            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
                          </pic:spPr>
                        </pic:pic>
                      </a:graphicData>
                    </a:graphic>
                  </wp:inline>
                </w:drawing>
              </w:r>
            </w:p>
            """
        }
        let documentXML =
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <w:body>
            \(body)
            <w:sectPr/>
          </w:body>
        </w:document>
        """
        try documentXML.data(using: .utf8)!.write(to: wordDir.appendingPathComponent("document.xml"))

        // === Zip into .docx ===
        try zipDocxPackage(at: root, to: destinationURL)

        // Cleanup temp folder
        try? fm.removeItem(at: root)
    }
    /// Build a minimal DOCX package with paragraphs and inline PNG images.
    /// - Parameters:
    ///   - title: Document title for properties and first paragraph.
    ///   - paragraphs: Plain text paragraphs (no rich styling for v1).
    ///   - images: Array of (data (PNG), filename, logical size in points).
    ///   - destinationURL: Final `.docx` URL to write.
    private func writeDocxPackage(title: String,
                                  paragraphs: [String],
                                  images: [(data: Data, filename: String, sizePts: CGSize)],
                                  destinationURL: URL) throws {
        let fm = FileManager.default

        // Create a temp build root
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DocxBuild-\(UUID().uuidString)", isDirectory: true)
        let relsDir = root.appendingPathComponent("_rels", isDirectory: true)
        let wordDir = root.appendingPathComponent("word", isDirectory: true)
        let wordRelsDir = wordDir.appendingPathComponent("_rels", isDirectory: true)
        let mediaDir = wordDir.appendingPathComponent("media", isDirectory: true)
        let propsDir = root.appendingPathComponent("docProps", isDirectory: true)
        try fm.createDirectory(at: relsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: wordRelsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: propsDir, withIntermediateDirectories: true)

        // Write images to word/media
        for (i, img) in images.enumerated() {
            let name = img.filename.isEmpty ? "image\(i+1).png" : img.filename
            try img.data.write(to: mediaDir.appendingPathComponent(name))
        }

        // === [Content_Types].xml ===
        let contentTypes =
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Default Extension="png" ContentType="image/png"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
          <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
          <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        </Types>
        """
        try contentTypes.data(using: .utf8)!.write(to: root.appendingPathComponent("[Content_Types].xml"))

        // === _rels/.rels ===
        let rootRels =
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """
        try rootRels.data(using: .utf8)!.write(to: relsDir.appendingPathComponent(".rels"))

        // === docProps/core.xml ===
        let now = ISO8601DateFormatter().string(from: Date())
        let coreXML =
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
          xmlns:dc="http://purl.org/dc/elements/1.1/"
          xmlns:dcterms="http://purl.org/dc/terms/"
          xmlns:dcmitype="http://purl.org/dc/dcmitype/"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <dc:title>\(docxEscapeXML(title))</dc:title>
          <dc:creator>DrsMainApp</dc:creator>
          <cp:lastModifiedBy>DrsMainApp</cp:lastModifiedBy>
          <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created>
          <dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified>
        </cp:coreProperties>
        """
        try coreXML.data(using: .utf8)!.write(to: propsDir.appendingPathComponent("core.xml"))

        // === docProps/app.xml ===
        let appXML =
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"
          xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
          <Application>DrsMainApp</Application>
        </Properties>
        """
        try appXML.data(using: .utf8)!.write(to: propsDir.appendingPathComponent("app.xml"))

        // === word/_rels/document.xml.rels ===
        var rels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        """
        for (i, img) in images.enumerated() {
            let name = img.filename.isEmpty ? "image\(i+1).png" : img.filename
            rels += """
              <Relationship Id="rId\(i+1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/\(name)"/>
            """
        }
        // Add Styles relationship after the images, using the next available rId
        let stylesRelId = images.count + 1
        rels += """
          <Relationship Id="rId\(stylesRelId)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        """
        rels += "\n</Relationships>\n"
        try rels.data(using: .utf8)!.write(to: wordRelsDir.appendingPathComponent("document.xml.rels"))

        // === word/styles.xml ===
        let stylesXML =
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <!-- Default 'Normal' paragraph style: 11pt, 1.15 line spacing, 6pt after -->
          <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
            <w:name w:val="Normal"/>
            <w:rPr>
              <w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica" w:cs="Helvetica"/>
              <w:sz w:val="22"/>
              <w:szCs w:val="22"/>
            </w:rPr>
            <w:pPr>
              <w:spacing w:after="120" w:line="276" w:lineRule="auto"/>
            </w:pPr>
          </w:style>

          <!-- Title style: 20pt bold -->
          <w:style w:type="paragraph" w:styleId="Title">
            <w:name w:val="Title"/>
            <w:basedOn w:val="Normal"/>
            <w:qFormat/>
            <w:rPr>
              <w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica" w:cs="Helvetica"/>
              <w:b/>
              <w:sz w:val="40"/>
              <w:szCs w:val="40"/>
            </w:rPr>
            <w:pPr>
              <w:spacing w:after="180"/>
            </w:pPr>
          </w:style>

          <!-- Heading 1: 14pt semibold -->
          <w:style w:type="paragraph" w:styleId="Heading1">
            <w:name w:val="Heading 1"/>
            <w:basedOn w:val="Normal"/>
            <w:qFormat/>
            <w:rPr>
              <w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica" w:cs="Helvetica"/>
              <w:b/>
              <w:sz w:val="28"/>
              <w:szCs w:val="28"/>
            </w:rPr>
            <w:pPr>
              <w:spacing w:before="120" w:after="120"/>
            </w:pPr>
          </w:style>

          <!-- Heading 2: 12pt semibold -->
          <w:style w:type="paragraph" w:styleId="Heading2">
            <w:name w:val="Heading 2"/>
            <w:basedOn w:val="Normal"/>
            <w:qFormat/>
            <w:rPr>
              <w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica" w:cs="Helvetica"/>
              <w:b/>
              <w:sz w:val="24"/>
              <w:szCs w:val="24"/>
            </w:rPr>
            <w:pPr>
              <w:spacing w:before="80" w:after="80"/>
            </w:pPr>
          </w:style>
        </w:styles>
        """
        try stylesXML.data(using: .utf8)!.write(to: wordDir.appendingPathComponent("styles.xml"))

        // === word/document.xml (heading + paragraphs + images) ===
        var body = ""
        // Title paragraph (use Title style)
        body += """
        <w:p>
          <w:pPr><w:pStyle w:val="Title"/></w:pPr>
          <w:r><w:t>\(docxEscapeXML(title))</w:t></w:r>
        </w:p>
        """

        for p in paragraphs {
            let t = docxEscapeXML(p)
            body += "<w:p><w:r><w:t>\(t)</w:t></w:r></w:p>"
        }

        for (i, img) in images.enumerated() {
            let cx = emuFromPoints(img.sizePts.width)
            let cy = emuFromPoints(img.sizePts.height)
            body +=
            """
            <w:p>
              <w:r>
                <w:drawing>
                  <wp:inline distT="0" distB="0" distL="0" distR="0"
                    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">
                    <wp:extent cx="\(cx)" cy="\(cy)"/>
                    <wp:docPr id="\(100 + i)" name="Chart \(i+1)"/>
                    <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
                      <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                        <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
                          <pic:nvPicPr>
                            <pic:cNvPr id="\(i+1)" name="chart\(i+1).png"/>
                            <pic:cNvPicPr/>
                          </pic:nvPicPr>
                          <pic:blipFill>
                            <a:blip r:embed="rId\(i+1)" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/>
                            <a:stretch><a:fillRect/></a:stretch>
                          </pic:blipFill>
                          <pic:spPr>
                            <a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>
                            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
                          </pic:spPr>
                        </pic:pic>
                      </a:graphicData>
                    </a:graphic>
                  </wp:inline>
                </w:drawing>
              </w:r>
            </w:p>
            """
        }

        let documentXML =
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <w:body>
            \(body)
            <w:sectPr/>
          </w:body>
        </w:document>
        """
        try documentXML.data(using: .utf8)!.write(to: wordDir.appendingPathComponent("document.xml"))

        // === Zip into .docx ===
        try zipDocxPackage(at: root, to: destinationURL)

        // Cleanup temp folder
        try? fm.removeItem(at: root)
    }
    /// Export a minimal Word (.docx) report with Growth Charts embedded.
    /// v1 focuses on verifying image embedding works reliably in Word.
    func exportDOCX(for kind: VisitKind) throws -> URL {
        // Build text (title) and decide destination folder
        let (attr, stem) = try buildAttributedReport(for: kind)

        let fm = FileManager.default
        let baseDir: URL = {
            if let bundle = appState.currentBundleURL {
                return bundle.appendingPathComponent("Docs", isDirectory: true)
            } else {
                return fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/DrsMainApp/Reports", isDirectory: true)
            }
        }()
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let outURL = baseDir.appendingPathComponent("\(stem).docx")

        // Title as plain string
        let title = "Clinical Report"

        // Body paragraphs with Heading detection and previous-visit date line promotion
        let headingSet: Set<String> = [
            // Well visit sections (top of report)
            "Well Visit Summary",
            "Perinatal Summary",
            "Findings from Previous Well Visits",
            // Existing well visit sections
            "Previous Well Visits","Parents’ Concerns","Feeding","Supplementation","Sleep",
            "Developmental Evaluation","Age-specific Milestones","Measurements",
            "Physical Examination","Problem Listing","Conclusions","Anticipatory Guidance",
            "Clinician Comments","Next Visit Date","Growth Charts",
            // Sick visit sections
            "Main Complaint","History of Present Illness","Duration","Basics",
            "Past Medical History","Vaccination","Vitals Summary","Investigations",
            "Working Diagnosis","ICD-10","Plan & Anticipatory Guidance","Medications",
            "Follow-up / Next Visit","Sick Visit Report"
        ]
        func classifyStyle(_ s: String) -> String? {
            if s.hasPrefix("Current Visit —") { return "Heading1" }
            if headingSet.contains(s) { return "Heading1" }
            return nil
        }
        var styledParagraphs: [(text: String, style: String?)] = []

        // Detect date-looking lines (very tolerant: ISO, "Sep 15, 2025", "15 Sep 2025", etc.)
        func isDateLine(_ s: String) -> Bool {
            // Quick paths for ISO-like and Month-name patterns
            let iso = #"^(?:•\s*)?\d{4}-\d{2}-\d{2}\b"#
            let mdy = #"^(?:•\s*)?(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{1,2},\s*\d{4}\b"#
            let dmy = #"^(?:•\s*)?\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{4}\b"#
            return s.range(of: iso, options: .regularExpression) != nil
                || s.range(of: mdy, options: .regularExpression) != nil
                || s.range(of: dmy, options: .regularExpression) != nil
        }
        func stripLeadingBullet(_ s: String) -> String {
            if s.hasPrefix("• ") { return String(s.dropFirst(2)) }
            return s
        }

        // We only promote date lines that appear under these sections:
        let prevDatesSections: Set<String> = [
            "Previous Well Visits",
            "Findings from Previous Well Visits"
        ]
        var inPrevDatesSection = false

        for line in attr.string.components(separatedBy: .newlines) {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }

            // Heading1 detection first (also flips the in-section flag)
            if s.hasPrefix("Current Visit —") || headingSet.contains(s) {
                styledParagraphs.append((s, "Heading1"))
                inPrevDatesSection = prevDatesSections.contains(s)
                continue
            }

            // Under the previous-visits sections, promote clear date lines to Heading2
            if inPrevDatesSection, isDateLine(s) {
                styledParagraphs.append((stripLeadingBullet(s), "Heading2"))
                continue
            }

            // Keep other bullets/lines as body text
            if s.hasPrefix("• ") {
                styledParagraphs.append((s, nil))
            } else {
                styledParagraphs.append((s, nil))
            }
        }

        // Render growth charts (Well visit only). If not a Well visit, we still create a text-only docx.
        var images: [(data: Data, filename: String, sizePts: CGSize)] = []

        switch kind {
        case .well(let visitID):
            if let gs = dataLoader.loadGrowthSeriesForWell(visitID: visitID) {
                let contentWidth = REPORT_PAGE_SIZE.width - (2 * REPORT_INSET)
                let max18cm: CGFloat = (18.0 / 2.54) * 72.0
                let renderWidth = min(contentWidth, max18cm)
                let aspect: CGFloat = 450.0 / 700.0
                let renderSize = CGSize(width: renderWidth, height: renderWidth * aspect)
                let imgs = ReportGrowthRenderer.renderAllCharts(series: gs, size: renderSize, drawWHO: true)

                for (i, img) in imgs.enumerated() {
                    // Encode as PNG for docx
                    if let tiff = img.tiffRepresentation,
                       let rep  = NSBitmapImageRep(data: tiff),
                       let png  = rep.representation(using: .png, properties: [:]) {
                        images.append((data: png, filename: "image\(i+1).png", sizePts: renderSize))
                    }
                }
                NSLog("[ReportDebug] DOCX charts embedded count = %d  sizePts=(%.1f×%.1f)", images.count, renderSize.width, renderSize.height)
            }
        case .sick:
            break
        }

        try writeDocxPackage(title: title, styledParagraphs: styledParagraphs, images: images, destinationURL: outURL)
        NSLog("[ReportExport] wrote DOCX %@", outURL.path)
        return outURL
    }

    /// Ensure a given NSTextAttachment has a real FileWrapper (so it serializes into RTFD).
    /// If the attachment only has an attachmentCell/image, we create a PNG file wrapper for it.
    private func normalizeAttachmentToFileWrapper(_ att: NSTextAttachment, nameHint: String = "image.png") {
        // If there is already a file wrapper, we're good.
        if att.fileWrapper != nil { return }

        // Try to extract an NSImage from the attachment.
        var image: NSImage?
        if let cell = att.attachmentCell as? NSTextAttachmentCell {
            image = cell.image
        }
        // Some AppKit versions expose 'image' on NSTextAttachment directly.
        if image == nil {
            #if compiler(>=5.7)
            image = att.image
            #endif
        }

        // Build a PNG file wrapper if we can.
        if let img = image {
            if let png = bestPNGData(from: img) {
                let wrapper = FileWrapper(regularFileWithContents: png)
                wrapper.preferredFilename = nameHint
                att.fileWrapper = wrapper
                // Preserve intended on-page size if bounds were set; otherwise use the image's logical size.
                if att.bounds.size == .zero {
                    att.bounds = CGRect(origin: .zero, size: img.size)
                }
            } else if let tiff = img.tiffRepresentation {
                let wrapper = FileWrapper(regularFileWithContents: tiff)
                wrapper.preferredFilename = nameHint.replacingOccurrences(of: ".png", with: ".tiff")
                att.fileWrapper = wrapper
                if att.bounds.size == .zero {
                    att.bounds = CGRect(origin: .zero, size: img.size)
                }
            }
        }
    }

    /// Walk all attachments in an attributed string and make sure they have FileWrappers for RTFD export.
    private func ensureRTFDAttachments(in content: NSMutableAttributedString) {
        var idx = 0
        content.enumerateAttribute(.attachment,
                                   in: NSRange(location: 0, length: content.length)) { value, _, _ in
            if let att = value as? NSTextAttachment {
                normalizeAttachmentToFileWrapper(att, nameHint: String(format: "img_%03d.png", idx))
                idx += 1
            }
        }
    }

    private func debugLogImage(_ img: NSImage, label: String, targetSize: CGSize) {
        var pxW = 0, pxH = 0
        if let rep = img.representations.compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            pxW = rep.pixelsWide; pxH = rep.pixelsHigh
        } else if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            pxW = rep.pixelsWide; pxH = rep.pixelsHigh
        }
        NSLog("[ReportDebug] img %@ points=(%.1f×%.1f) targetPoints=(%.1f×%.1f) pixels=(%dx%d)",
              label, img.size.width, img.size.height, targetSize.width, targetSize.height, pxW, pxH)
    }

    @discardableResult
    private func debugDumpImage(_ img: NSImage, name: String) -> URL? {
        let url = debugDir().appendingPathComponent("\(name)-\(debugTimestamp()).png")
        if let tiff = img.tiffRepresentation,
           let rep  = NSBitmapImageRep(data: tiff),
           let png  = rep.representation(using: .png, properties: [:]) {
            do { try png.write(to: url)
                NSLog("[ReportDebug] wrote %@", url.path)
                return url
            } catch {
                NSLog("[ReportDebug] write failed %@: %@", url.path, String(describing: error))
                return nil
            }
        } else {
            // Fallback: rasterize at 1× point size
            let w = max(1, Int(img.size.width))
            let h = max(1, Int(img.size.height))
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = img.size
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                img.draw(in: NSRect(x: 0, y: 0, width: img.size.width, height: img.size.height))
                NSGraphicsContext.current = nil
            }
            NSGraphicsContext.restoreGraphicsState()
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
                NSLog("[ReportDebug] wrote (fallback) %@", url.path)
                return url
            }
            return nil
        }
    }

    @discardableResult
    private func debugDumpPDF(_ data: Data, name: String) -> URL? {
        let url = debugDir().appendingPathComponent("\(name)-\(debugTimestamp()).pdf")
        do {
            try data.write(to: url, options: .atomic)
            if let doc = PDFDocument(data: data) {
                NSLog("[ReportDebug] wrote %@ (pages=%d)", url.path, doc.pageCount)
            } else {
                NSLog("[ReportDebug] wrote %@ (unreadable by PDFDocument)", url.path)
            }
            return url
        } catch {
            NSLog("[ReportDebug] write failed %@: %@", url.path, String(describing: error))
            return nil
        }
    }
    
    // Count image attachments inside an attributed string (for RTF/RTFD verification)
    private func debugCountAttachments(in s: NSAttributedString) -> Int {
        var count = 0
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { val, _, _ in
            if (val as? NSTextAttachment) != nil { count += 1 }
        }
        return count
    }

    // Dump both RTF (single file) and RTFD (package) to DebugExports to see which preserves images
    private func debugDumpRTFVariants(_ s: NSAttributedString, stem: String) {
        let range = NSRange(location: 0, length: s.length)

        // 1) Plain RTF
        if let rtf = s.rtf(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            let url = debugDir().appendingPathComponent("\(stem)-\(debugTimestamp()).rtf")
            do { try rtf.write(to: url); NSLog("[ReportDebug] wrote %@", url.path) } catch {
                NSLog("[ReportDebug] write failed %@: %@", url.path, String(describing: error))
            }
        } else {
            NSLog("[ReportDebug] RTF serialization returned nil")
        }

        // 2) RTFD package
        if let wrapper = try? s.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) {
            let dir = debugDir().appendingPathComponent("\(stem)-\(debugTimestamp()).rtfd", isDirectory: true)
            do {
                try wrapper.write(to: dir, options: .atomic, originalContentsURL: nil)
                NSLog("[ReportDebug] wrote %@", dir.path)
            } catch {
                NSLog("[ReportDebug] RTFD write failed %@: %@", dir.path, String(describing: error))
            }
        } else {
            NSLog("[ReportDebug] RTFD fileWrapper creation failed")
        }
    }

    private func debugLogChartLayout(pageSize: CGSize,
                                     contentRect: CGRect,
                                     capRect: CGRect,
                                     imgRect: CGRect,
                                     image: NSImage) {
        var pxW = 0, pxH = 0
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            pxW = rep.pixelsWide; pxH = rep.pixelsHigh
        }
        NSLog("[ReportDebug] page=(%.1f×%.1f) content=(%.1f×%.1f @ %.1f,%.1f) cap=(%.1f×%.1f @ %.1f,%.1f) imgRect=(%.1f×%.1f @ %.1f,%.1f) imgPoints=(%.1f×%.1f) imgPixels=(%dx%d)",
              pageSize.width, pageSize.height,
              contentRect.width, contentRect.height, contentRect.origin.x, contentRect.origin.y,
              capRect.width, capRect.height, capRect.origin.x, capRect.origin.y,
              imgRect.width, imgRect.height, imgRect.origin.x, imgRect.origin.y,
              image.size.width, image.size.height,
              pxW, pxH)
    }

    // Extract highest-resolution CGImage from NSImage (avoids NSImage multi-rep quirks)
    private func bestCGImage(from img: NSImage) -> CGImage? {
        if let rep = img.representations.compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            return rep.cgImage
        }
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            return rep.cgImage
        }
        return nil
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
        return try exportReport(for: kind, format: .pdf)
    }
    func exportRTF(for kind: VisitKind) throws -> URL {
        // TEMPORARY: route "RTF" requests to the new DOCX path so existing UI
        // produces a Word file while we debug RTF/RTFD on macOS.
        // This keeps all call sites unchanged.
        let url = try exportDOCX(for: kind)
        NSLog("[ReportExport] (RTF shim) returned DOCX instead: %@", url.path)
        return url
    }
    
    
}



// MARK: - Rendering

private extension ReportBuilder {

    // ...existing functions...



    // Merge multiple PDF Data blobs into a single PDF
    private func mergePDFs(_ parts: [Data]) throws -> Data {
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
    
    // Heuristic: page is "blank" if it has no extracted text and no annotations.
    // (Good enough for our case; our extra page is entirely empty.)
    private func isVisuallyBlank(_ page: PDFPage) -> Bool {
        let hasText = !(page.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if hasText { return false }
        if !page.annotations.isEmpty { return false }
        return true
    }

    // Return PDF data with blank pages trimmed from start/end as requested.
    private func trimmedPDF(_ data: Data, trimLeading: Bool, trimTrailing: Bool) -> Data {
        guard let doc = PDFDocument(data: data) else { return data }
        var toRemove = IndexSet()

        if trimLeading {
            var i = 0
            while i < doc.pageCount, let p = doc.page(at: i), isVisuallyBlank(p) {
                toRemove.insert(i); i += 1
            }
        }
        if trimTrailing {
            var i = doc.pageCount - 1
            while i >= 0, let p = doc.page(at: i), isVisuallyBlank(p) {
                toRemove.insert(i); i -= 1
            }
        }
        for i in toRemove.sorted(by: >) { doc.removePage(at: i) }
        return doc.dataRepresentation() ?? data
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
        if DEBUG_REPORT_EXPORT {
            for (idx, img) in images.enumerated() {
                debugLogImage(img, label: "pdfCharts[\(idx)]", targetSize: renderSize)
                _ = debugDumpImage(img, name: "pdfCharts_\(idx)")
            }
        }

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

            // Caption at the top of the content rect (drawn with AppKit text)
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

            // Draw caption using an AppKit graphics context (no flips)
            do {
                NSGraphicsContext.saveGraphicsState()
                let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSGraphicsContext.current = nsCtx
                cap.draw(in: capRect)
                NSGraphicsContext.current = nil
                NSGraphicsContext.restoreGraphicsState()
            }

            // Image rect: fit to content width and available height below caption (preserve aspect)
            let availableH = contentRect.height - capH - 8
            let imgW = min(renderW, contentRect.width)
            let imgH = min(renderH, availableH)
            let imgX = contentRect.midX - imgW / 2
            let imgY = capRect.minY - 8 - imgH
            let imgRect = CGRect(x: imgX, y: imgY, width: imgW, height: imgH)

            if DEBUG_REPORT_EXPORT {
                debugLogChartLayout(pageSize: pageSize,
                                    contentRect: contentRect,
                                    capRect: capRect,
                                    imgRect: imgRect,
                                    image: img)
            }

            // Draw image via CoreGraphics to avoid NSImage multi-representation cropping
            ctx.saveGState()
            ctx.interpolationQuality = .high
            if let cg = bestCGImage(from: img) {
                ctx.draw(cg, in: imgRect)
            } else {
                // Fallback: use AppKit draw (non-flipped) if we cannot extract CGImage
                NSGraphicsContext.saveGraphicsState()
                let nsCtx2 = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSGraphicsContext.current = nsCtx2
                img.draw(in: imgRect,
                         from: NSRect(origin: .zero, size: img.size),
                         operation: .sourceOver,
                         fraction: 1.0,
                         respectFlipped: false,
                         hints: nil)
                NSGraphicsContext.current = nil
                NSGraphicsContext.restoreGraphicsState()
            }
            ctx.restoreGState()

            ctx.endPDFPage()
        }

        ctx.closePDF()
        return data as Data
    }
}
