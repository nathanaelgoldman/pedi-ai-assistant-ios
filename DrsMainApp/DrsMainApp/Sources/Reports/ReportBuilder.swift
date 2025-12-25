//
//  ReportBuilder.swift
//  DrsMainApp
//
//  Created by yunastic on 11/2/25.
//

// REPORT CONTRACT (Well visits)
// - Age gating lives in WellVisitReportRules + ReportDataLoader ONLY.
// - Age gating controls ONLY which fields appear INSIDE the current visit sections.
// - Growth charts, perinatal summary, and previous well visits are NEVER age-gated.
// - ReportBuilder is a dumb renderer: it prints whatever WellReportData gives it.
//- We don't make RTF (that is legacy from previous failed attempts)
//- we don't touch GrowthCharts
//- we work with PDF and Docx.
//- the contract is to filter the age appropriate current visit field to include in the report. Everything else is left unchanged.

import Foundation
import AppKit
import PDFKit
import UniformTypeIdentifiers
import CoreText
import ZIPFoundation



// MARK: - Report geometry (single source of truth)
fileprivate let REPORT_PAGE_SIZE = CGSize(width: 595.0, height: 842.0) // US Letter; switch here if you use A4
fileprivate let REPORT_INSET: CGFloat = 36.0

fileprivate let DEBUG_REPORT_EXPORT: Bool = true

// MARK: - Localization helper
fileprivate func L(_ key: String, comment: String) -> String {
    NSLocalizedString(key, comment: comment)
}


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
            throw NSError(
                domain: "ReportExport",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L("report.export.cancelled_or_no_url",
                                                       comment: "User cancelled the save panel or the destination URL was missing")]
            )
        }

        // 3) Write
        do {
            // DOCX EXPORT LOGIC (find the DOCX export block, e.g. "[ReportDebug] DOCX charts embedded count = %d")
            // (We only need to change the WELL-visit logic for the main body.)
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
                    switch kind {
                    case .well(let visitID):
                        // Use the same age‑gated body as the PDF path.
                        let (bodyOnly, _) = try buildAttributedReportParts(for: kind)

                        // Render charts sized like in PDF (cap width at ~18 cm, keep renderer aspect 700:450).
                        let contentWidth = REPORT_PAGE_SIZE.width - (2 * REPORT_INSET)
                        let max18cm: CGFloat = (18.0 / 2.54) * 72.0
                        let renderWidth = min(contentWidth, max18cm)
                        let aspect: CGFloat = 450.0 / 700.0
                        let renderSize = CGSize(width: renderWidth, height: renderWidth * aspect)

                        if let gs = dataLoader.loadGrowthSeriesForWell(visitID: visitID) {
                            let images = ReportGrowthRenderer.renderAllCharts(series: gs,
                                                                              size: renderSize,
                                                                              drawWHO: true)
                            let captions = ["Weight-for-Age",
                                            "Length/Height-for-Age",
                                            "Head Circumference-for-Age"]
                            let tuples: [(image: NSImage, goalSizePts: CGSize)] =
                                images.map { (image: $0, goalSizePts: renderSize) }

                            // Assemble a single-file RTF by appending inline PNG/TIFF pictures to the body.
                            let rtfData = try makeSingleFileRTFInline(body: bodyOnly,
                                                                      charts: tuples,
                                                                      captions: captions)
                            try rtfData.write(to: dest, options: .atomic)
                        } else {
                            // No charts available — export body-only as plain RTF.
                            let range = NSRange(location: 0, length: bodyOnly.length)
                            guard let rtfData = bodyOnly.rtf(from: range,
                                                             documentAttributes: [
                                                                .documentType: NSAttributedString.DocumentType.rtf
                                                             ]) else {
                                throw NSError(
                                    domain: "ReportExport",
                                    code: 3004,
                                    userInfo: [NSLocalizedDescriptionKey: L("report.export.rtf.body_only_failed",
                                                                           comment: "RTF export failed when generating a body-only document")]
                                )
                            }
                            try rtfData.write(to: dest, options: .atomic)
                        }

                    case .sick:
                        // Sick reports have no charts; export the attributed body directly.
                        let range = NSRange(location: 0, length: attributed.length)
                        guard let rtfData = attributed.rtf(from: range,
                                                           documentAttributes: [
                                                            .documentType: NSAttributedString.DocumentType.rtf
                                                           ]) else {
                            throw NSError(
                                domain: "ReportExport",
                                code: 3005,
                                userInfo: [NSLocalizedDescriptionKey: L("report.export.rtf.sick_failed",
                                                                       comment: "RTF export failed for a sick visit report")]
                            )
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

            // Age-gating hook: compute numeric age at visit (in months).
            // This will be used by later steps to decide which sections/charts to show per age band.
            // Reuse body-only layout (Steps 1–12: header, perinatal, feeding, sleep, etc.)
            let body = assembleAttributedWell_BodyOnly(data: data, visitID: visitID)
            let charts = assembleWellChartsOnly(data: data, visitID: visitID)
            return (body, charts)

        case .sick(let episodeID):
            let data = try dataLoader.loadSick(episodeID: episodeID)
            // We now rely entirely on SickReportData-driven layout; no need for buildContent fallback.
            let body = assembleAttributedSick(data: data, fallbackSections: [], episodeID: episodeID)
            return (body, nil)
        }
    }
    // Body-only variant of Well report (steps 1–12), excluding Step 13 charts
    fileprivate func assembleAttributedWell_BodyOnly(data: WellReportData, visitID: Int) -> NSAttributedString {
        let content = NSMutableAttributedString()

        func para(_ text: String, font: NSFont, color: NSColor = .labelColor) {
            content.append(NSAttributedString(string: text + "\n",
                                              attributes: [.font: font, .foregroundColor: color]))
        }

        // Localized display labels for stored dictionary keys (keep storage keys stable).
        func feedingLabel(_ storageKey: String) -> String {
            switch storageKey {
            case "Breastfeeding":
                return L("report.well.feeding.breastfeeding", comment: "Feeding label: breastfeeding")
            case "Formula":
                return L("report.well.feeding.formula", comment: "Feeding label: formula")
            case "Solids":
                return L("report.well.feeding.solids", comment: "Feeding label: solids")
            case "Notes":
                return L("report.common.notes", comment: "Generic label: notes")
            default:
                return storageKey
            }
        }

        func supplementationLabel(_ storageKey: String) -> String {
            switch storageKey {
            case "Vitamin D":
                return L("report.well.supplementation.vitamin_d", comment: "Supplementation label: Vitamin D")
            case "Iron":
                return L("report.well.supplementation.iron", comment: "Supplementation label: iron")
            case "Other":
                return L("report.common.other", comment: "Generic label: other")
            case "Notes":
                return L("report.common.notes", comment: "Generic label: notes")
            default:
                return storageKey
            }
        }

        func stoolLabel(_ storageKey: String) -> String {
            switch storageKey {
            case "Stool pattern":
                return L("report.well.stool.pattern", comment: "Stool label: pattern")
            case "Stool comment":
                return L("report.well.stool.comment", comment: "Stool label: comment")
            default:
                return storageKey
            }
        }

        func sleepLabel(_ storageKey: String) -> String {
            switch storageKey {
            case "Total hours":
                return L("report.well.sleep.total_hours", comment: "Sleep label: total hours")
            case "Naps":
                return L("report.well.sleep.naps", comment: "Sleep label: naps")
            case "Night wakings":
                return L("report.well.sleep.night_wakings", comment: "Sleep label: night wakings")
            case "Quality":
                return L("report.well.sleep.quality", comment: "Sleep label: quality")
            case "Notes":
                return L("report.common.notes", comment: "Generic label: notes")
            default:
                return storageKey
            }
        }

        func developmentalLabel(_ storageKey: String) -> String {
            switch storageKey {
            case "Parent Concerns":
                return L("report.well.development.parent_concerns", comment: "Development label: parent concerns")
            case "M-CHAT":
                return L("report.well.development.mchat", comment: "Development label: M-CHAT")
            case "Developmental Test":
                return L("report.well.development.developmental_test", comment: "Development label: developmental test")
            default:
                return storageKey
            }
        }

        func localizedMchatInlineValue(_ raw: String) -> String {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return raw }

            // Try to localize the trailing M-CHAT result code while preserving the left part.
            let seps = [" – ", " — ", " - "]
            for sep in seps {
                if t.contains(sep) {
                    let parts = t.components(separatedBy: sep)
                    if parts.count >= 2 {
                        let left = parts.dropLast().joined(separator: sep).trimmingCharacters(in: .whitespacesAndNewlines)
                        let right = (parts.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let localizedRight = self.localizedMchatResultLabel(right)
                        return left.isEmpty ? localizedRight : (left + sep + localizedRight)
                    }
                }
            }

            // If it's just a code, localize it directly.
            return self.localizedMchatResultLabel(t)
        }

        func developmentalValue(_ key: String, _ value: String) -> String {
            return (key == "M-CHAT") ? localizedMchatInlineValue(value) : value
        }

        func measurementLabel(_ storageKey: String) -> String {
            switch storageKey {
            case "Weight":
                return L("report.well.measurements.weight", comment: "Measurement label: weight")
            case "Length":
                return L("report.well.measurements.length", comment: "Measurement label: length")
            case "Head Circumference":
                return L("report.well.measurements.head_circumference", comment: "Measurement label: head circumference")
            case "Weight gain since discharge":
                return L("report.well.measurements.weight_gain_since_discharge", comment: "Measurement label: weight gain since discharge")
            default:
                return storageKey
            }
        }

        // Age-gated section visibility is precomputed in WellVisitReportRules + ReportDataLoader.
        // ReportBuilder only reads these flags and renders sections accordingly.
        let visibility = data.visibility

        // Debug: log which sections are enabled and how much data we have for each.
        if DEBUG_REPORT_EXPORT {
            func flag(_ b: Bool?) -> String { b == nil ? "nil" : (b! ? "Y" : "N") }
            let parentsFlag = flag(visibility?.showParentsConcerns)
            let feedFlag = flag(visibility?.showFeeding)
            let suppFlag = flag(visibility?.showSupplementation)
            let sleepFlag = flag(visibility?.showSleep)
            let devFlag = flag(visibility?.showDevelopment)
            let milestonesFlag = flag(visibility?.showMilestones)
            let measFlag = flag(visibility?.showMeasurements)
            let peFlag = flag(visibility?.showPhysicalExam)
            let problemsFlag = flag(visibility?.showProblemListing)
            let conclFlag = flag(visibility?.showConclusions)
            let agFlag = flag(visibility?.showAnticipatoryGuidance)
            let commentsFlag = flag(visibility?.showClinicianComments)
            let nextFlag = flag(visibility?.showNextVisit)

            NSLog("[ReportBuilder] well flags: parents=%@ feed=%@ supp=%@ sleep=%@ dev=%@ milestones=%@ meas=%@ pe=%@ problems=%@ concl=%@ ag=%@ comments=%@ next=%@",
                  parentsFlag, feedFlag, suppFlag, sleepFlag, devFlag, milestonesFlag,
                  measFlag, peFlag, problemsFlag, conclFlag, agFlag, commentsFlag, nextFlag)

            let parentsCount = (data.parentsConcerns?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? 1 : 0
            let feedCount = data.feeding.count
            let suppCount = data.supplementation.count
            let sleepCount = data.sleep.count
            let devCount = data.developmental.count
            let measCount = data.measurements.count
            let peGroups = data.physicalExamGroups.count
            let milestoneFlags = data.milestoneFlags.count

            NSLog("[ReportBuilder] well data: parents=%d feed=%d supp=%d sleep=%d dev=%d meas=%d peGroups=%d milestoneFlags=%d",
                  parentsCount, feedCount, suppCount, sleepCount, devCount, measCount, peGroups, milestoneFlags)
        }

        // Header block (Well)
        para(L("report.well.title", comment: "Well visit report main title"),
             font: .systemFont(ofSize: 20, weight: .semibold))
        let triadFormat = L("report.header.triad_format",
                            comment: "Header line with created/edited/generated timestamps")
        let triad = String(format: triadFormat,
                           humanDateTime(data.meta.createdAtISO) ?? "—",
                           humanDateTime(data.meta.updatedAtISO) ?? "—",
                           humanDateTime(data.meta.generatedAtISO) ?? "—")
        para(triad, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        content.append(NSAttributedString(string: "\n"))

        let aliasMrnFormat = L("report.header.alias_mrn_format", comment: "Header line: Alias and MRN")
        para(String(format: aliasMrnFormat, data.meta.alias, data.meta.mrn), font: .systemFont(ofSize: 12))
        let nameFormat = L("report.header.name_format", comment: "Header line: patient name")
        para(String(format: nameFormat, data.meta.name), font: .systemFont(ofSize: 12))
        let dobShortWell = humanDateOnly(data.meta.dobISO) ?? "—"
        let ageShortWell = {
            let pre = data.meta.ageAtVisit.trimmingCharacters(in: .whitespacesAndNewlines)
            if pre.isEmpty || pre == "—" {
                return computeAgeShort(dobISO: data.meta.dobISO, refISO: data.meta.visitDateISO)
            }
            return pre
        }()
        let dobSexAgeFormat = L("report.header.dob_sex_age_format", comment: "Header line: DOB, sex, age at visit")
        para(String(format: dobSexAgeFormat, dobShortWell, data.meta.sex, ageShortWell),
             font: .systemFont(ofSize: 12))
        let visitTypeFallback = L("visit.type.well", comment: "Fallback visit type label for a well visit")
        let visitDateTypeFormat = L("report.header.visit_date_type_format", comment: "Header line: visit date and visit type")
        para(String(format: visitDateTypeFormat,
                    humanDateOnly(data.meta.visitDateISO) ?? "—",
                    data.meta.visitTypeReadable ?? visitTypeFallback),
             font: .systemFont(ofSize: 12))
        let clinicianFormat = L("report.header.clinician_format", comment: "Header line: clinician")
        para(String(format: clinicianFormat, data.meta.clinicianName), font: .systemFont(ofSize: 12))
        content.append(NSAttributedString(string: "\n"))

        // Steps 1–12 (copy of assembleAttributedWell up to just before Step 13)
        let headerFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 12)

        // Perinatal Summary must always be present (never age‑gated or suppressed)
        para(L("report.well.section.perinatal_summary", comment: "Section title: perinatal summary"), font: headerFont)
        let periText = (data.perinatalSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? data.perinatalSummary!
            : "—"
        para(periText, font: bodyFont)
        content.append(NSAttributedString(string: "\n"))

        if !data.previousVisitFindings.isEmpty {
            para(L("report.well.section.previous_findings", comment: "Section title: findings from previous well visits"), font: headerFont)
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
                        let ageLabel = L("report.label.age", comment: "Age label")
                        if let r = sub.range(of: "Age —") {
                            sub.replaceSubrange(r, with: "\(ageLabel) \(computed)")
                        } else if !sub.contains("\(ageLabel) ") && !sub.contains("Age ") {
                            let ageAppendFormat = L("report.previous.age_append_format", comment: "Suffix appended to previous visit title to show computed age")
                            sub.append(String(format: ageAppendFormat, computed))
                        }
                    }
                }

                content.append(NSAttributedString(
                    string: sub + "\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                 .foregroundColor: NSColor.labelColor]
                ))

                if let f = item.findings, !f.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let parts = splitPreviousVisitFindingLines(f)

                    // Rebuild as one-bullet-per-line, then normalize milestone formatting so PDF matches
                    // the token pipeline:
                    // - inserts one Milestones header before the first milestone item
                    // - removes the extra dash so we don't render "• - ..."
                    let bulleted = parts.map { "• \($0)" }.joined(separator: "\n")
                    let normalized = normalizePreviousWellVisitSummary(bulleted)

                    for raw in normalized.components(separatedBy: .newlines) {
                        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { continue }

                        if t.hasPrefix("•") {
                            para(t, font: bodyFont)
                        } else {
                            para("• \(t)", font: bodyFont)
                        }
                    }
                } else {
                    para("—", font: bodyFont)
                }
                content.append(NSAttributedString(string: "\n"))
            }
        }

        let _currentTitle = data.currentVisitTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !_currentTitle.isEmpty {
            let currentVisitFormat = L("report.well.current_visit_title_format", comment: "Title for current visit section, with visit type appended")
            para(String(format: currentVisitFormat, _currentTitle), font: headerFont)
            content.append(NSAttributedString(string: "\n"))
        }

        if visibility?.showParentsConcerns ?? true {
            para(L("report.well.section.parents_concerns", comment: "Section title: parents' concerns"), font: headerFont)
            let parentsText = (data.parentsConcerns?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? data.parentsConcerns!
                : "—"
            para(parentsText, font: bodyFont)
            content.append(NSAttributedString(string: "\n"))
        }

        if visibility?.showFeeding ?? true {
            para(L("report.well.section.feeding", comment: "Section title: feeding"), font: headerFont)
            if DEBUG_REPORT_EXPORT {
                let keys = data.feeding.keys.sorted()
                if let profile = visibility?.profile {
                    let f = profile.flags
                    NSLog("[ReportBuilder] feeding keys visitID=%d: %@ | earlyMilk=%d solids=%d olderFeeding=%d",
                          visitID,
                          keys.joined(separator: ", "),
                          f.isEarlyMilkOnlyVisit ? 1 : 0,
                          f.isSolidsVisit ? 1 : 0,
                          f.isOlderFeedingVisit ? 1 : 0)
                } else {
                    NSLog("[ReportBuilder] feeding keys visitID=%d: %@ | flags=nil",
                          visitID,
                          keys.joined(separator: ", "))
                }
            }
            if data.feeding.isEmpty {
                para("—", font: bodyFont)
            } else {
                let feedOrder = ["Breastfeeding","Formula","Solids","Notes"]
                for key in feedOrder {
                    if let v = data.feeding[key], !v.isEmpty {
                        para("\(feedingLabel(key)): \(v)", font: bodyFont)
                    }
                }
                let extra = data.feeding.keys
                    .filter { !["Breastfeeding","Formula","Solids","Notes"].contains($0) }
                    .sorted()
                for key in extra {
                    if let v = data.feeding[key], !v.isEmpty {
                        para("\(feedingLabel(key)): \(v)", font: bodyFont)
                    }
                }
            }
            content.append(NSAttributedString(string: "\n"))
        }

        if visibility?.showSupplementation ?? true {
            para(L("report.well.section.supplementation", comment: "Section title: supplementation"), font: headerFont)
            if data.supplementation.isEmpty {
                para("—", font: bodyFont)
            } else {
                let order = ["Vitamin D","Iron","Other","Notes"]
                for key in order {
                    if let v = data.supplementation[key], !v.isEmpty {
                        para("\(supplementationLabel(key)): \(v)", font: bodyFont)
                    }
                }
                let extra = data.supplementation.keys
                    .filter { !["Vitamin D","Iron","Other","Notes"].contains($0) }
                    .sorted()
                for key in extra {
                    if let v = data.supplementation[key], !v.isEmpty {
                        para("\(supplementationLabel(key)): \(v)", font: bodyFont)
                    }
                }
            }
            content.append(NSAttributedString(string: "\n"))
        }
        
        // Stool (always shown; uses dictionary from WellReportData)
        para(L("report.well.section.stool", comment: "Section title: stool"), font: headerFont)
        if data.stool.isEmpty {
            para("—", font: bodyFont)
        } else {
            let order = ["Stool pattern", "Stool comment"]
            for key in order {
                if let raw = data.stool[key] {
                    let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        para("\(stoolLabel(key)): \(trimmed)", font: bodyFont)
                    }
                }
            }
            let extra = data.stool.keys
                .filter { !order.contains($0) }
                .sorted()
            for key in extra {
                if let raw = data.stool[key] {
                    let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        para("\(stoolLabel(key)): \(trimmed)", font: bodyFont)
                    }
                }
            }
        }
        content.append(NSAttributedString(string: "\n"))

        if visibility?.showSleep ?? true {
            para(L("report.well.section.sleep", comment: "Section title: sleep"), font: headerFont)
            if data.sleep.isEmpty {
                para("—", font: bodyFont)
            } else {
                let order = ["Total hours","Naps","Night wakings","Quality","Notes"]
                for key in order {
                    if let v = data.sleep[key], !v.isEmpty {
                        para("\(sleepLabel(key)): \(v)", font: bodyFont)
                    }
                }
                let extra = data.sleep.keys
                    .filter { !["Total hours","Naps","Night wakings","Quality","Notes"].contains($0) }
                    .sorted()
                for key in extra {
                    if let v = data.sleep[key], !v.isEmpty {
                        para("\(sleepLabel(key)): \(v)", font: bodyFont)
                    }
                }
            }
            content.append(NSAttributedString(string: "\n"))
        }

        if visibility?.showDevelopment ?? true {
            para(L("report.well.section.development", comment: "Section title: developmental evaluation"), font: headerFont)
            if data.developmental.isEmpty {
                para("—", font: bodyFont)
            } else {
                let devOrder = ["Parent Concerns", "M-CHAT", "Developmental Test"]
                for key in devOrder {
                    guard let v = data.developmental[key],
                          !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let rendered = developmentalValue(key, v)
                    para("\(developmentalLabel(key)): \(rendered)", font: bodyFont)
                }
                let extra = data.developmental.keys
                    .filter { !["Parent Concerns","M-CHAT","Developmental Test"].contains($0) }
                    .sorted()
                for key in extra {
                    if let v = data.developmental[key],
                       !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let rendered = developmentalValue(key, v)
                        para("\(developmentalLabel(key)): \(rendered)", font: bodyFont)
                    }
                }
            }
            content.append(NSAttributedString(string: "\n"))
        }

        if visibility?.showMilestones ?? true {
            para(NSLocalizedString("well_visit_form.problem_listing.milestones.header", comment: "Section title: age-specific milestones"), font: headerFont)
            let achieved = data.milestonesAchieved.0
            let total = data.milestonesAchieved.1
            let achievedFormat = L("report.well.milestones.achieved_format", comment: "Milestones achieved count line")
            para(String(format: achievedFormat, achieved, total), font: bodyFont)
            if data.milestoneFlags.isEmpty {
                para(L("report.well.milestones.no_flags", comment: "Text shown when there are no milestone flags"), font: bodyFont)
            } else {
                for line in data.milestoneFlags {
                    para("• \(line)", font: bodyFont)
                }
            }
            content.append(NSAttributedString(string: "\n"))
        }

        if visibility?.showMeasurements ?? true {
            para(L("report.well.section.measurements", comment: "Section title: measurements"), font: headerFont)
            if data.measurements.isEmpty {
                para("—", font: bodyFont)
            } else {
                let measOrder = ["Weight","Length","Head Circumference","Weight gain since discharge"]
                for key in measOrder {
                    if let v = data.measurements[key], !v.isEmpty {
                        para("\(measurementLabel(key)): \(v)", font: bodyFont)
                    }
                }
                let extra = data.measurements.keys
                    .filter { !["Weight","Length","Head Circumference","Weight gain since discharge"].contains($0) }
                    .sorted()
                for key in extra {
                    if let v = data.measurements[key], !v.isEmpty {
                        para("\(measurementLabel(key)): \(v)", font: bodyFont)
                    }
                }
            }
            content.append(NSAttributedString(string: "\n"))
        }

        if visibility?.showPhysicalExam ?? true {
            para(L("report.well.section.physical_exam", comment: "Section title: physical examination"), font: headerFont)
            if data.physicalExamGroups.isEmpty {
                para("—", font: bodyFont)
            } else {
                for (groupTitle, lines) in data.physicalExamGroups {
                    content.append(NSAttributedString(
                        string: groupTitle + "\n",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                            .foregroundColor: NSColor.labelColor
                        ]
                    ))
                    for line in lines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        para("• \(line)", font: bodyFont)
                    }
                }
            }
            content.append(NSAttributedString(string: "\n"))
        }

        if visibility?.showProblemListing ?? true {
            para(L("report.well.section.problem_listing", comment: "Section title: problem listing"), font: headerFont)

            let rendered = renderProblemListing(tokens: data.problemListingTokens,
                                                fallback: data.problemListing)
            let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
            para(trimmed.isEmpty ? "—" : trimmed, font: bodyFont)

            content.append(NSAttributedString(string: "\n"))
        }

        if visibility?.showConclusions ?? true {
            para(L("report.well.section.conclusions", comment: "Section title: conclusions"), font: headerFont)
            let _conclusions = data.conclusions?.trimmingCharacters(in: .whitespacesAndNewlines)
            para((_conclusions?.isEmpty == false ? _conclusions! : "—"), font: bodyFont)
            content.append(NSAttributedString(string: "\n"))
        }

        if visibility?.showAnticipatoryGuidance ?? true {
            para(L("report.well.section.anticipatory_guidance", comment: "Section title: anticipatory guidance"), font: headerFont)
            let _ag = data.anticipatoryGuidance?.trimmingCharacters(in: .whitespacesAndNewlines)
            para((_ag?.isEmpty == false ? _ag! : "—"), font: bodyFont)
            content.append(NSAttributedString(string: "\n"))
        }

        if visibility?.showClinicianComments ?? true {
            para(L("report.well.section.clinician_comments", comment: "Section title: clinician comments"), font: headerFont)
            let _cc = data.clinicianComments?.trimmingCharacters(in: .whitespacesAndNewlines)
            para((_cc?.isEmpty == false ? _cc! : "—"), font: bodyFont)
            content.append(NSAttributedString(string: "\n"))
        }

        if visibility?.showNextVisit ?? true {
            para(L("report.well.section.next_visit_date", comment: "Section title: next visit date"), font: headerFont)
            if let rawNext = data.nextVisitDate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawNext.isEmpty {
                para(humanDateOnly(rawNext) ?? rawNext, font: bodyFont)
            } else {
                para("—", font: bodyFont)
            }
            content.append(NSAttributedString(string: "\n"))
        }

        // AI Assistant – latest model response for this WELL visit (if any)
        if let ai = dataLoader.loadLatestAIInputForWell(visitID) {
            para(L("report.ai_assistant.title", comment: "Section title: AI Assistant"),
                 font: headerFont)

            let modelLine = String(format: L("report.ai_assistant.model_format",
                                            comment: "AI assistant meta line: model name"),
                                   ai.model)
            var metaLine = modelLine

            let ts = ai.createdAt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ts.isEmpty {
                let pretty = humanDateTime(ts) ?? ts
                let timeSuffix = String(format: L("report.ai_assistant.time_suffix_format",
                                                 comment: "AI assistant meta line suffix with timestamp"),
                                        pretty)
                metaLine += timeSuffix
            }

            para(metaLine, font: bodyFont)
            content.append(NSAttributedString(string: "\n"))

            let resp = ai.response.trimmingCharacters(in: .whitespacesAndNewlines)
            if resp.isEmpty {
                para("—", font: bodyFont)
            } else {
                para(resp, font: bodyFont)
            }
            content.append(NSAttributedString(string: "\n"))
        }

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
        para(L("report.well.charts.title", comment: "Section title: growth charts"), font: headerFont)
        let dobPretty = humanDateOnly(gs.dobISO) ?? gs.dobISO
        let cutPretty = humanDateOnly(gs.visitDateISO) ?? gs.visitDateISO
        let sexText = (gs.sex == .female)
            ? L("report.sex.female", comment: "Sex label: female")
            : L("report.sex.male", comment: "Sex label: male")
        let sexDobCutoffFormat = L("report.charts.sex_dob_cutoff_format",
                                  comment: "Charts meta line with sex, DOB and cutoff")
        para(String(format: sexDobCutoffFormat, sexText, dobPretty, cutPretty), font: bodyFont)

        func range(_ pts: [ReportGrowth.Point]) -> String {
            guard let minA = pts.map({ $0.ageMonths }).min(),
                  let maxA = pts.map({ $0.ageMonths }).max() else {
                return L("report.charts.range.zero", comment: "Charts range label when there are no points")
            }
            let nf = NumberFormatter(); nf.maximumFractionDigits = 1
            let lo = nf.string(from: NSNumber(value: minA)) ?? String(format: "%.1f", minA)
            let hi = nf.string(from: NSNumber(value: maxA)) ?? String(format: "%.1f", maxA)

            if pts.count == 1 {
                let oneFmt = L("report.charts.range.single_format", comment: "Charts range label for exactly one point")
                return String(format: oneFmt, pts.count, lo, hi)
            } else {
                let manyFmt = L("report.charts.range.multi_format", comment: "Charts range label for multiple points")
                return String(format: manyFmt, pts.count, lo, hi)
            }
        }

        let wfaLine = String(format: L("report.charts.wfa_line_format", comment: "Charts summary line: weight-for-age"), range(gs.wfa))
        let lhfaLine = String(format: L("report.charts.lhfa_line_format", comment: "Charts summary line: length/height-for-age"), range(gs.lhfa))
        let hcfaLine = String(format: L("report.charts.hcfa_line_format", comment: "Charts summary line: head circumference-for-age"), range(gs.hcfa))
        para(wfaLine, font: bodyFont)
        para(lhfaLine, font: bodyFont)
        para(hcfaLine, font: bodyFont)
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
            let caption = (idx == 0
                           ? L("report.charts.caption.wfa", comment: "Charts caption: weight-for-age")
                           : (idx == 1
                              ? L("report.charts.caption.lhfa", comment: "Charts caption: length/height-for-age")
                              : L("report.charts.caption.hcfa", comment: "Charts caption: head circumference-for-age")))
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
        para(L("report.well.charts.title", comment: "Section title: growth charts"), font: headerFont)
        let dobPretty = humanDateOnly(gs.dobISO) ?? gs.dobISO
        let cutPretty = humanDateOnly(gs.visitDateISO) ?? gs.visitDateISO
        let sexText = (gs.sex == .female)
            ? L("report.sex.female", comment: "Sex label: female")
            : L("report.sex.male", comment: "Sex label: male")
        let sexDobCutoffFormat = L("report.charts.sex_dob_cutoff_format",
                                  comment: "Charts meta line with sex, DOB and cutoff")
        para(String(format: sexDobCutoffFormat, sexText, dobPretty, cutPretty), font: bodyFont)
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
            let caption = (idx == 0
                           ? L("report.charts.caption.wfa", comment: "Charts caption: weight-for-age")
                           : (idx == 1
                              ? L("report.charts.caption.lhfa", comment: "Charts caption: length/height-for-age")
                              : L("report.charts.caption.hcfa", comment: "Charts caption: head circumference-for-age")))
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
    /// Localizes an inline M-CHAT result code in a legacy/plain-text line.
    /// Example: "• M-CHAT: score 5 – medium_risk" -> "• M-CHAT: score 5 – <localized label>"
    private func localizedMchatInlineValueInLegacyLine(_ rawLine: String) -> String {
        let original = rawLine
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return original }

        // Keep a leading bullet prefix if present.
        let hasBullet = line.hasPrefix("•")
        if hasBullet {
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Only attempt this on lines that contain M-CHAT.
        if !line.lowercased().contains("m-chat") {
            return original
        }

        // Try to localize the trailing code while preserving the left part.
        let seps = [" – ", " — ", " - "]
        for sep in seps {
            if line.contains(sep) {
                let parts = line.components(separatedBy: sep)
                if parts.count >= 2 {
                    let left = parts.dropLast().joined(separator: sep).trimmingCharacters(in: .whitespacesAndNewlines)
                    let right = (parts.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let localizedRight = localizedMchatResultLabel(right)
                    let rebuilt = left.isEmpty ? localizedRight : (left + sep + localizedRight)
                    return hasBullet ? ("• " + rebuilt) : rebuilt
                }
            }
        }

        // If it's just a code, localize it directly.
        let rebuilt = localizedMchatResultLabel(line)
        return hasBullet ? ("• " + rebuilt) : rebuilt
    }
    
    // MARK: - Well Visit problem listing (token-rendered)

    private func renderProblemListing(tokens: [ProblemToken], fallback: String?) -> String {
        // Prefer token-driven rendering (keeps ordering consistent with the form).
        
        
        
        if !tokens.isEmpty {
            var out: [String] = []
            var insertedMilestonesHeader = false

            for token in tokens {
                let k = token.key.trimmingCharacters(in: .whitespacesAndNewlines)

                // 0) If the token itself is the milestones header, dedupe it here.
                if k == "well_visit_form.problem_listing.milestones.header" {
                    if insertedMilestonesHeader { continue }
                    insertedMilestonesHeader = true
                }

                // 1) Insert a header line once, immediately before the first milestone-related line
                //    ONLY if we haven't already seen/printed the header token.
                let isMilestoneLine =
                    (k == "well_visit_form.problem_listing.milestones.line_format") ||
                    (k == "well_visit_form.problem_listing.token.milestone_item_v1")

                if isMilestoneLine, !insertedMilestonesHeader {
                    let headerKey = "well_visit_form.problem_listing.milestones.header"
                    let header = NSLocalizedString(headerKey, comment: "Problem listing subheader: milestones")
                    let headerText = (header == headerKey) ? "Milestones:" : header
                    out.append("• " + headerText)
                    insertedMilestonesHeader = true
                }

                if let line = renderProblemTokenLine(token) {
                    out.append(line)
                }
            }

            let rendered = out.joined(separator: "\n")
            if !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return rendered
            }
        }

        return (fallback ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits stored previous-visit findings into clean per-line items.
    ///
    /// Supports:
    /// - legacy single-line blobs separated by " • "
    /// - multi-line text (each item on its own line)
    /// - already-bulleted lines ("• ...")
    ///
    /// Returned items are bulletless (caller may add bullets), trimmed, and non-empty.
    private func splitPreviousVisitFindingLines(_ raw: String) -> [String] {
        let s = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let parts: [String]
        if s.contains(" • ") {
            parts = s.components(separatedBy: " • ")
        } else {
            parts = s.components(separatedBy: .newlines)
        }

        return parts.compactMap { p in
            var t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }

            // Avoid double bullets if the stored text already contains bullets
            if t.hasPrefix("•") {
                t.removeFirst()
                t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            return t.isEmpty ? nil : t
        }
    }

    /// Normalizes legacy / plain-text previous-visit summaries so they match the token-rendered pipeline:
    /// - inserts a single "Milestones" header bullet before the first milestone-like line
    /// - removes the extra dash so we don't render "• - ..."
    private func normalizePreviousWellVisitSummary(_ text: String) -> String {
        let headerKey = "well_visit_form.problem_listing.milestones.header"
        let headerLocalized = NSLocalizedString(headerKey, comment: "Problem listing subheader: milestones")
        let headerText = (headerLocalized == headerKey) ? "Milestones:" : headerLocalized

        var out: [String] = []
        out.reserveCapacity(16)

        var insertedHeader = false

        // Split while preserving simple line structure
        let lines = text.components(separatedBy: .newlines)
        for rawLine in lines {
            var line = localizedMchatInlineValueInLegacyLine(rawLine)

            // Detect and normalize the legacy "• - ..." milestone lines.
            // We treat any bullet line that starts with "• -", "• –", or "• —" as a milestone item.
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let isMilestoneLegacyBullet: Bool =
                trimmed.hasPrefix("• -") ||
                trimmed.hasPrefix("• –") ||
                trimmed.hasPrefix("• —")

            if isMilestoneLegacyBullet {
                if !insertedHeader {
                    out.append("• " + headerText)
                    insertedHeader = true
                }

                // Strip the extra dash variants after the bullet.
                // Examples:
                // "• - Throws a ball" -> "• Throws a ball"
                // "• – Throws a ball" -> "• Throws a ball"
                // "• — Throws a ball" -> "• Throws a ball"
                line = trimmed
                if line.hasPrefix("•") {
                    // Remove the initial bullet
                    line.removeFirst()
                    line = line.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                // Remove leading dash variants (and surrounding spaces)
                while line.hasPrefix("-") || line.hasPrefix("–") || line.hasPrefix("—") {
                    line.removeFirst()
                    line = line.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                out.append("• " + line)
                continue
            }

            out.append(line)
        }

        return dedupePreviousWellVisitSummaryLines(out.joined(separator: "\n"))
    }

    /// Dedupe previous-visit bullet lines in a stable, pipeline-driven way.
    /// This prevents the same clinical fact from appearing twice due to legacy text sources.
    private func dedupePreviousWellVisitSummaryLines(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)

        var out: [String] = []
        out.reserveCapacity(lines.count)

        var seen = Set<String>()

        func collapseSpaces(_ s: String) -> String {
            var t = s
            while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
            return t
        }

        func canonicalKey(for line: String) -> String {
            var t = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Remove leading bullet for comparison
            if t.hasPrefix("•") {
                t.removeFirst()
                t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            t = collapseSpaces(t)

            // Generic normalization for duplicates like "(18)" vs "(18 dents)".
            // If the parenthetical contains a number + a word that already appears earlier in the line,
            // treat it as redundant for dedupe purposes.
            if let re = try? NSRegularExpression(pattern: "\\((\\d+)\\s+([A-Za-zÀ-ÿ]+)\\)", options: []) {
                let nsRange = NSRange(t.startIndex..<t.endIndex, in: t)
                if let m = re.firstMatch(in: t, options: [], range: nsRange), m.numberOfRanges == 3,
                   let rWord = Range(m.range(at: 2), in: t),
                   let rParen = Range(m.range(at: 0), in: t) {
                    let word = String(t[rWord])
                    let prefix = t[..<rParen.lowerBound].lowercased()
                    if prefix.contains(word.lowercased()) {
                        // Replace "(N word)" with "(N)" for canonical comparison
                        t = re.stringByReplacingMatches(in: t, options: [], range: nsRange, withTemplate: "($1)")
                        t = collapseSpaces(t)
                    }
                }
            }

            return t.lowercased()
        }

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let key = canonicalKey(for: trimmed)
            guard seen.insert(key).inserted else { continue }

            out.append(raw)
        }

        return out.joined(separator: "\n")
    }

    private func renderProblemTokenLine(_ token: ProblemToken) -> String? {
        let key = token.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }

        let fmt = NSLocalizedString(key, comment: "")
        let rawArgs = problemTokenStringArray(token, names: ["tokenArgs", "args", "arguments", "tokens"])
        let args: [CVarArg] = rawArgs.map { localizeProblemTokenArg($0, tokenKey: key) }

        // New milestone token pipeline (v1): token args are [code, statusCode, optionalNote]
        // Render it using the same localized strings as the live form.
        if key == "well_visit_form.problem_listing.token.milestone_item_v1" {
            guard rawArgs.count >= 2 else { return nil }

            let code = rawArgs[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let statusCode = rawArgs[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let note = (rawArgs.count >= 3)
                ? rawArgs[2].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""

            let label = localizedLabel(for: code, prefixes: [
                "well_visit_form.milestone",
                "well_visit_form.milestones.item",
                "well_visit_form.shared"
            ])

            let statusLabel = localizedLabel(for: statusCode, prefixes: [
                "well_visit_form.milestones.status",
                "well_visit_form.shared"
            ])

            let lineKey = "well_visit_form.problem_listing.milestones.line_format"
            let lineFmt = NSLocalizedString(lineKey, comment: "")
            var line: String
            if lineFmt == lineKey {
                // Safe fallback if the format key is missing
                line = "\(label) – \(statusLabel)"
            } else {
                line = String(format: lineFmt, label, statusLabel)
            }

            if !note.isEmpty {
                let withNoteKey = "well_visit_form.problem_listing.milestones.line_with_note_format"
                let withNoteFmt = NSLocalizedString(withNoteKey, comment: "")
                if withNoteFmt == withNoteKey {
                    line = "\(line) (\(note))"
                } else {
                    line = String(format: withNoteFmt, line, note)
                }
            }

            let prefixKey = "well_visit_form.problem_listing.milestones.item_prefix_format"
            let prefixFmt = NSLocalizedString(prefixKey, comment: "")
            if prefixFmt != prefixKey {
                line = String(format: prefixFmt, line)
            }

            var t = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // If the localized string already contains a bullet, keep it as-is.
            if t.hasPrefix("•") { return t }

            // Strip leading dash variants so we only have one bullet.
            while t.hasPrefix("-") || t.hasPrefix("–") || t.hasPrefix("—") {
                t.removeFirst()
                t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            return "• " + t
        }

        let raw: String
        if args.isEmpty {
            raw = (fmt == key) ? key : fmt
        } else {
            raw = String(format: fmt, arguments: args)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Milestone problem-list lines sometimes come pre-prefixed with a dash in localized strings
        // (e.g. "- Throws a ball"), which would otherwise render as "• - ...".
        if key == "well_visit_form.problem_listing.milestones.line_format" {
            var t = trimmed

            // If the localized string already contains a bullet, keep it as-is.
            if t.hasPrefix("•") { return t }

            // Strip leading dash variants so we only have one bullet.
            while t.hasPrefix("-") || t.hasPrefix("–") || t.hasPrefix("—") {
                t.removeFirst()
                t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return "• " + t
        }

        if trimmed.hasPrefix("•") { return trimmed }
        return "• " + trimmed
    }

    private func problemTokenStringArray(_ token: ProblemToken, names: [String]) -> [String] {
        let m = Mirror(reflecting: token)
        for child in m.children {
            guard let label = child.label, names.contains(label) else { continue }
            if let arr = child.value as? [String] { return arr }
            if let arr = child.value as? [Substring] { return arr.map(String.init) }
        }
        return []
    }

    private func localizeProblemTokenArg(_ raw: String, tokenKey: String) -> CVarArg {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" as NSString }

        switch tokenKey {
        case "well_visit_form.problem_listing.sleep.regularity":
            return localizedLabel(for: t, prefixes: [
                "well_visit_form.sleep.regularity.option",
                "well_visit_form.shared"
            ]) as NSString

        case "well_visit_form.problem_listing.mchat.line_format":
            return localizedMchatResultLabel(t) as NSString

        case "well_visit_form.problem_listing.dev_test.line_format":
            return localizedLabel(for: t, prefixes: [
                "well_visit_form.dev_test.result",
                "well_visit_form.shared"
            ]) as NSString

        case "well_visit_form.problem_listing.milestones.line_format":
            return localizedLabel(for: t, prefixes: [
                "well_visit_form.milestone",
                "well_visit_form.milestones.item",
                "well_visit_form.shared"
            ]) as NSString

        default:
            // Heuristic: if a token arg *looks like* a localization key, localize it.
            // This is common for PE tokens where the value is a key (valueIsKey=true).
            if (t.hasPrefix("well_visit_form.") || t.hasPrefix("report.") || t.hasPrefix("visit.")) && t.contains(".") {
                let s = NSLocalizedString(t, comment: "")
                if s != t { return s as NSString }
            }
            return t as NSString
        }
    }

    private func localizedLabel(for code: String, prefixes: [String]) -> String {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return "" }

        for p in prefixes {
            let k = "\(p).\(c)"
            let s = NSLocalizedString(k, comment: "")
            if s != k { return s }
        }
        return c
    }

    // M-CHAT result codes are stored as stable codes (e.g. low_risk/medium_risk/high_risk),
    // but older data (or some normalizers) may store variants (e.g. low/medium/high).
    // This helper tries a few safe fallbacks before giving up and returning the raw code.
    private func localizedMchatResultLabel(_ code: String) -> String {
        let c0 = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c0.isEmpty else { return "" }

        // 1) Prefer exact match using the same prefixes as the live form.
        let exact = localizedLabel(for: c0, prefixes: [
            "well_visit_form.mchat.result",
            "well_visit_form.shared"
        ])
        if exact != c0 { return exact }

        // 2) Try common legacy/variant shapes.
        var candidates: [String] = []

        // Convert snake_case to dotted form if any legacy keys used dots.
        if c0.contains("_") {
            candidates.append(c0.replacingOccurrences(of: "_", with: "."))
        }

        // If the code is like "medium_risk", also try "medium".
        if c0.hasSuffix("_risk") {
            let base = String(c0.dropLast("_risk".count))
            if !base.isEmpty {
                candidates.append(base)
                if base.contains("_") {
                    candidates.append(base.replacingOccurrences(of: "_", with: "."))
                }
            }
        }

        // If the code is like "medium", also try "medium_risk".
        if c0 == "low" || c0 == "medium" || c0 == "high" {
            candidates.append("\(c0)_risk")
        }

        // De-dup while preserving order.
        var seen = Set<String>()
        let uniq = candidates.filter { seen.insert($0).inserted }

        for cand in uniq {
            let s = localizedLabel(for: cand, prefixes: [
                "well_visit_form.mchat.result",
                "well_visit_form.shared"
            ])
            if s != cand { return s }
        }

        // 3) Give up: return the raw stable code.
        return c0
    }
    
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
                sections.append(.init(title: L("report.section.problem_listing", comment: "Generic section title: problem listing"), body: p))
            }
            if let d = s.diagnosis, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append(.init(title: L("report.section.diagnosis", comment: "Generic section title: diagnosis"), body: d))
            }
            if let c = s.conclusions, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append(.init(title: L("report.section.conclusions_plan", comment: "Generic section title: conclusions/plan"), body: c))
            }
        }

        // Perinatal / PMH snapshot
        if let prof = appState.currentPatientProfile {
            if let peri = prof.perinatalHistory, !peri.isEmpty {
                sections.append(.init(title: L("report.section.perinatal", comment: "Generic section title: perinatal"), body: peri))
            }
            if let pmh = prof.pmh, !pmh.isEmpty {
                sections.append(.init(title: L("report.section.past_medical_history", comment: "Generic section title: past medical history"), body: pmh))
            }
            if let vacc = prof.vaccinationStatus, !vacc.isEmpty {
                sections.append(.init(title: L("report.section.vaccination", comment: "Generic section title: vaccination"), body: vacc))
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
        switch kind {
        case .well(let visitID):
            let data = try dataLoader.loadWell(visitID: visitID)

            // Use the new body-only, age-gated layout (same logic as PDF path)
            let body = assembleAttributedWell_BodyOnly(data: data, visitID: visitID)

            let stem = makeFileStem(from: data.meta, fallbackType: "well")
            return (body, stem)

        case .sick(let episodeID):
            let data = try dataLoader.loadSick(episodeID: episodeID)
            let (_, fallbackSections) = buildContent(for: kind)
            let attributed = assembleAttributedSick(data: data,
                                                    fallbackSections: fallbackSections,
                                                    episodeID: episodeID)
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

        para(L("report.title.clinical_report", comment: "Report title: clinical report"), font: .systemFont(ofSize: 20, weight: .semibold))
        func metaLabel(_ key: String) -> String {
            switch key {
            case "Patient":   return L("report.meta.patient", comment: "Report meta label: patient")
            case "DOB":       return L("report.meta.dob", comment: "Report meta label: DOB")
            case "Sex":       return L("report.meta.sex", comment: "Report meta label: sex")
            case "MRN":       return L("report.meta.mrn", comment: "Report meta label: MRN")
            case "Visit Type":return L("report.meta.visit_type", comment: "Report meta label: visit type")
            case "Visit Date":return L("report.meta.visit_date", comment: "Report meta label: visit date")
            case "Clinician": return L("report.meta.clinician", comment: "Report meta label: clinician")
            default:           return key
            }
        }

        let pretty = Dictionary(uniqueKeysWithValues: meta.map { (k, v) in
            // Localize the *value* for visit type while keeping internal keys stable.
            if k == "Visit Type" {
                if v == "Sick Visit" {
                    return (k, L("report.visit_type.sick", comment: "Visit type label: sick"))
                }
                if v == "Well Visit" {
                    return (k, L("report.visit_type.well", comment: "Visit type label: well"))
                }
            }
            return (k, humanizeIfDate(v))
        })

        let metaLine = pretty.sorted(by: { $0.key < $1.key })
            .map { "\(metaLabel($0.key)): \($0.value)" }
            .joined(separator: "   •   ")
        para(metaLine, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        content.append(NSAttributedString(string: "\n"))

        for s in sections {
            para(s.title, font: .systemFont(ofSize: 14, weight: .semibold))
            // If this is the previous well visit summary section, normalize it.
            let isPrevWellVisitSection =
                s.title == L("report.section.problem_listing", comment: "Generic section title: problem listing") ||
                s.title.lowercased().contains("visites de suivi précédentes") ||
                s.title.lowercased().contains("previous well visit")
            if isPrevWellVisitSection {
                let normalized = normalizePreviousWellVisitSummary(s.body)
                para(normalized, font: .systemFont(ofSize: 12))
            } else {
                para(s.body, font: .systemFont(ofSize: 12))
            }
            content.append(NSAttributedString(string: "\n"))
        }

        return content
    }

    func assembleAttributedWell(data: WellReportData, fallbackSections: [Section], visitID: Int) -> NSAttributedString {
        let content = NSMutableAttributedString()

        // Compute age band for gating; reuse same logic as PDF/body-only path
        _ = assembleAttributedWell_BodyOnly(data: data,
                                            visitID: visitID)

        // --- Step 13: Growth Charts (summary up to visit date) ---
        func para(_ text: String, font: NSFont, color: NSColor = .labelColor) {
            content.append(
                NSAttributedString(
                    string: text + "\n",
                    attributes: [
                        .font: font,
                        .foregroundColor: color
                    ]
                )
            )
        }
        let headerFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 12)

        para(L("report.well.charts.title", comment: "Section title: growth charts"), font: headerFont)
        if let gs = dataLoader.loadGrowthSeriesForWell(visitID: visitID) {
            let dobPretty = humanDateOnly(gs.dobISO) ?? gs.dobISO
            let cutPretty = humanDateOnly(gs.visitDateISO) ?? gs.visitDateISO
            let sexText = (gs.sex == .female)
                ? L("report.sex.female", comment: "Sex label: female")
                : L("report.sex.male", comment: "Sex label: male")
            let sexDobCutoffFormat = L("report.charts.sex_dob_cutoff_format",
                                      comment: "Charts meta line with sex, DOB and cutoff")
            para(String(format: sexDobCutoffFormat, sexText, dobPretty, cutPretty), font: bodyFont)

            func range(_ pts: [ReportGrowth.Point]) -> String {
                guard let minA = pts.map({ $0.ageMonths }).min(),
                      let maxA = pts.map({ $0.ageMonths }).max() else {
                    return L("report.charts.range.zero", comment: "Charts range label when there are no points")
                }
                let nf = NumberFormatter(); nf.maximumFractionDigits = 1
                let lo = nf.string(from: NSNumber(value: minA)) ?? String(format: "%.1f", minA)
                let hi = nf.string(from: NSNumber(value: maxA)) ?? String(format: "%.1f", maxA)

                if pts.count == 1 {
                    let oneFmt = L("report.charts.range.single_format", comment: "Charts range label for exactly one point")
                    return String(format: oneFmt, pts.count, lo, hi)
                } else {
                    let manyFmt = L("report.charts.range.multi_format", comment: "Charts range label for multiple points")
                    return String(format: manyFmt, pts.count, lo, hi)
                }
            }

            para(String(format: L("report.charts.wfa_line_format", comment: "Charts summary line: weight-for-age"), range(gs.wfa)), font: bodyFont)
            para(String(format: L("report.charts.lhfa_line_format", comment: "Charts summary line: length/height-for-age"), range(gs.lhfa)), font: bodyFont)
            para(String(format: L("report.charts.hcfa_line_format", comment: "Charts summary line: head circumference-for-age"), range(gs.hcfa)), font: bodyFont)
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
                let caption: String
                switch idx {
                case 0:
                    caption = L("report.charts.caption.wfa", comment: "Charts caption: weight-for-age")
                case 1:
                    caption = L("report.charts.caption.lhfa", comment: "Charts caption: length/height-for-age")
                default:
                    caption = L("report.charts.caption.hcfa", comment: "Charts caption: head circumference-for-age")
                }
                content.append(centeredTitle(caption))
                content.append(attachmentStringFittedToContent(from: img, reservedTopBottom: 72))
                content.append(NSAttributedString(string: "\n\n"))
            }
        }

        return content
    }

    // Assemble Sick Visit header parity; append current fallback sections.
    func assembleAttributedSick(data: SickReportData, fallbackSections: [Section], episodeID: Int) -> NSAttributedString {
        let content = NSMutableAttributedString()

        func para(_ text: String, font: NSFont, color: NSColor = .labelColor) {
            content.append(NSAttributedString(string: text + "\n",
                                              attributes: [.font: font, .foregroundColor: color]))
        }
        

        // Header block (Sick)
        para(L("report.sick.title", comment: "Sick report title"), font: .systemFont(ofSize: 20, weight: .semibold))
        let triadFmt = L("report.sick.meta.triad_format", comment: "Sick report header triad")
        let triad = String(format: triadFmt,
                           humanDateTime(data.meta.createdAtISO) ?? "—",
                           humanDateTime(data.meta.updatedAtISO) ?? "—",
                           humanDateTime(data.meta.generatedAtISO) ?? "—")
        para(triad, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        content.append(NSAttributedString(string: "\n"))

        let aliasMrnFmt = L("report.sick.meta.alias_mrn_format", comment: "Sick report header: alias and MRN")
        para(String(format: aliasMrnFmt, data.meta.alias, data.meta.mrn), font: .systemFont(ofSize: 12))
        let nameFmt = L("report.sick.meta.name_format", comment: "Sick report header: name")
        para(String(format: nameFmt, data.meta.name), font: .systemFont(ofSize: 12))
        let dobShortSick = humanDateOnly(data.meta.dobISO) ?? "—"
        let ageShortSick = {
            let pre = data.meta.ageAtVisit.trimmingCharacters(in: .whitespacesAndNewlines)
            if pre.isEmpty || pre == "—" { // treat em-dash placeholder as missing
                return computeAgeShort(dobISO: data.meta.dobISO, refISO: data.meta.visitDateISO)
            }
            return pre
        }()
        let dobSexAgeFmt = L("report.sick.meta.dob_sex_age_format", comment: "Sick report header: DOB/sex/age")
        para(String(format: dobSexAgeFmt, dobShortSick, data.meta.sex, ageShortSick), font: .systemFont(ofSize: 12))
        let visitDateFmt = L("report.sick.meta.visit_date_format", comment: "Sick report header: visit date")
        para(String(format: visitDateFmt, humanDateOnly(data.meta.visitDateISO) ?? "—"), font: .systemFont(ofSize: 12))
        let clinicianFmt = L("report.sick.meta.clinician_format", comment: "Sick report header: clinician")
        para(String(format: clinicianFmt, data.meta.clinicianName), font: .systemFont(ofSize: 12))
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
        section(L("report.sick.section.main_complaint", comment: "Sick section title: main complaint"), data.mainComplaint)
        // 9) History of Present Illness
        section(L("report.sick.section.hpi", comment: "Sick section title: HPI"), data.hpi)
        // 10) Duration
        section(L("report.sick.section.duration", comment: "Sick section title: duration"), data.duration)
        // 11) Basics (Feeding · Urination · Breathing · Pain · Context)
        if !data.basics.isEmpty {
            para(L("report.sick.section.basics", comment: "Sick section title: basics"), font: headerFont)
            let order = ["Feeding","Urination","Breathing","Pain","Context"]
            func basicsLabel(_ key: String) -> String {
                switch key {
                case "Feeding":   return L("report.sick.basics.feeding", comment: "Basics label: feeding")
                case "Urination": return L("report.sick.basics.urination", comment: "Basics label: urination")
                case "Breathing": return L("report.sick.basics.breathing", comment: "Basics label: breathing")
                case "Pain":      return L("report.sick.basics.pain", comment: "Basics label: pain")
                case "Context":   return L("report.sick.basics.context", comment: "Basics label: context")
                default:           return key
                }
            }
            for key in order {
                if let val = data.basics[key], !val.isEmpty {
                    para("\(basicsLabel(key)): \(val)", font: bodyFont)
                }
            }
            content.append(NSAttributedString(string: "\n"))
        }
        // 12) Past Medical History
        if data.perinatalSummary != nil {
            // When we have (or had) a perinatal summary for this age band:
            // render PMH as two subsections and use "—" for whichever is empty.
            para(L("report.sick.section.pmh", comment: "Sick section title: past medical history"), font: headerFont)

            let peri = data.perinatalSummary?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let pmh  = data.pmh?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // Perinatal history
            para(L("report.sick.section.perinatal_history", comment: "Sick PMH subsection title: perinatal history"), font: NSFont.systemFont(ofSize: 13, weight: .semibold))
            if !peri.isEmpty {
                para(peri, font: bodyFont)
            } else {
                para("—", font: bodyFont)
            }

            // Other PMH
            para(L("report.sick.section.other_pmh", comment: "Sick PMH subsection title: other PMH"), font: NSFont.systemFont(ofSize: 13, weight: .semibold))
            if !pmh.isEmpty {
                para(pmh, font: bodyFont)
            } else {
                para("—", font: bodyFont)
            }

            content.append(NSAttributedString(string: "\n"))
        } else {
            // Fallback: pre-existing simple behavior when no perinatal summary
            section(L("report.sick.section.pmh", comment: "Sick section title: past medical history"), data.pmh)
        }

        // 13) Vaccination
        section(L("report.sick.section.vaccination", comment: "Sick section title: vaccination"), data.vaccination)

        // 14) Vitals (full block from vitalsSummary)
        para(L("report.sick.section.vitals", comment: "Sick section title: vitals"), font: headerFont)
        if data.vitalsSummary.isEmpty {
            para("—", font: bodyFont)
        } else {
            for rawLine in data.vitalsSummary {
                var line = rawLine

                // If the line contains a "Measured: ..." segment, pretty-print the date/time part.
                let token = "Measured: "
                if let range = line.range(of: token) {
                    let prefix = String(line[..<range.lowerBound])          // everything before "Measured: "
                    let rawDatePart = line[range.upperBound...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)    // the ISO timestamp
                    let pretty = humanizeIfDate(rawDatePart)                // reuse existing helper
                    line = prefix + token + pretty
                }

                para("• \(line)", font: bodyFont)
            }
        }
        content.append(NSAttributedString(string: "\n"))

        // 15) Physical Examination (grouped)
        // Localize PE value strings when they come from choice-based pickers.
        // The DB often stores the base (English) choice text; for reports we want to render
        // the localized display string when a matching Localizable.strings key exists.
        func slugifyChoice(_ s: String) -> String {
            let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var out = ""
            out.reserveCapacity(lower.count)
            var lastWasUnderscore = false
            for ch in lower {
                if ch.isLetter || ch.isNumber {
                    out.append(ch)
                    lastWasUnderscore = false
                } else {
                    if !lastWasUnderscore {
                        out.append("_")
                        lastWasUnderscore = true
                    }
                }
            }
            // trim leading/trailing underscores
            while out.hasPrefix("_") { out.removeFirst() }
            while out.hasSuffix("_") { out.removeLast() }
            return out
        }

        func localizeChoiceIfPossible(_ raw: String) -> String {
            let slug = slugifyChoice(raw)
            if slug.isEmpty { return raw }

            // Try known choice namespaces. Return the first that resolves to a non-key string.
            let prefixes: [String] = [
                "sick_episode_form.choice.",
                "well_visit_form.choice.",
                "well_visit.choice.",
                "report.choice."
            ]
            for p in prefixes {
                let k = p + slug
                let v = NSLocalizedString(k, comment: "")
                if v != k { return v }
            }
            return raw
        }

        func localizePELine(_ line: String) -> String {
            // Expect "Label: Value". Only localize the Value part.
            guard let r = line.range(of: ":") else { return line }
            let label = String(line[..<r.lowerBound])
            let value = String(line[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return line }
            let localizedValue = localizeChoiceIfPossible(value)
            return "\(label): \(localizedValue)"
        }
        para(L("report.sick.section.physical_exam", comment: "Sick section title: physical examination"), font: headerFont)
        if data.physicalExamGroups.isEmpty {
            para("—", font: bodyFont)
        } else {
            for group in data.physicalExamGroups {
                para(group.group, font: NSFont.systemFont(ofSize: 13, weight: .semibold))
                for line in group.lines {
                    para("• \(localizePELine(line))", font: bodyFont)
                }
            }
        }
        content.append(NSAttributedString(string: "\n"))

        // 16) Problem Listing
        section(L("report.sick.section.problem_listing", comment: "Sick section title: problem listing"), data.problemListing)

        // 17) Investigations
        para(L("report.sick.section.investigations", comment: "Sick section title: investigations"), font: headerFont)
        if data.investigations.isEmpty {
            para("—", font: bodyFont)
        } else {
            for item in data.investigations {
                para("• \(item)", font: bodyFont)
            }
        }
        content.append(NSAttributedString(string: "\n"))

        // 18) Working Diagnosis
        section(L("report.sick.section.working_diagnosis", comment: "Sick section title: working diagnosis"), data.workingDiagnosis)

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
        section(L("report.sick.section.icd10", comment: "Sick section title: ICD-10"), icdStr)

        // 20) Plan & Anticipatory Guidance
        section(L("report.sick.section.plan_guidance", comment: "Sick section title: plan and anticipatory guidance"), data.planGuidance)

        // 21) Medications
        para(L("report.sick.section.medications", comment: "Sick section title: medications"), font: headerFont)
        if data.medications.isEmpty {
            para("—", font: bodyFont)
        } else {
            for m in data.medications {
                para("• \(m)", font: bodyFont)
            }
        }
        content.append(NSAttributedString(string: "\n"))

        // 22) Clinician Comments
        section(L("report.sick.section.clinician_comments", comment: "Sick section title: clinician comments"), data.clinicianComments)

        // 23) Follow-up / Next Visit
        section(L("report.sick.section.follow_up", comment: "Sick section title: follow-up / next visit"), data.nextVisitDate)
        
        // 24) AI Assistant – latest model response (if any)
        if let ai = dataLoader.loadLatestAIInputForEpisode(episodeID) {
            para("AI Assistant", font: headerFont)
            
            var metaLine = "Model: \(ai.model)"
            let ts = ai.createdAt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ts.isEmpty {
                let pretty = humanDateTime(ts) ?? ts
                metaLine += "   •   Time: \(pretty)"
            }
            para(metaLine, font: bodyFont)
            content.append(NSAttributedString(string: "\n"))
            
            let resp = ai.response.trimmingCharacters(in: .whitespacesAndNewlines)
            if resp.isEmpty {
                para("—", font: bodyFont)
            } else {
                para(resp, font: bodyFont)
            }
            content.append(NSAttributedString(string: "\n"))
        }

        
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
                          userInfo: [NSLocalizedDescriptionKey: L("report.error.pdf_consumer", comment: "PDF export error: failed to create PDF consumer")])
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "ReportExport", code: 101,
                          userInfo: [NSLocalizedDescriptionKey: L("report.error.pdf_context", comment: "PDF export error: failed to create PDF context")])
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
                          userInfo: [NSLocalizedDescriptionKey: L(
                            "report.error.rtf_create_base_body",
                            comment: "RTF export error: failed to create base RTF for body"
                          )])
        }

        // Decode as ASCII only (avoid UTF-8 multibyte characters in RTF stream)
        guard var rtf = String(data: bodyRTF, encoding: .ascii) else {
            throw NSError(domain: "ReportExport", code: 3002,
                          userInfo: [NSLocalizedDescriptionKey: L(
                            "report.error.rtf_body_not_ascii",
                            comment: "RTF export error: body RTF is not ASCII-serializable"
                          )])
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
                          userInfo: [NSLocalizedDescriptionKey: L(
                            "report.error.rtf_encode_final_ascii",
                            comment: "RTF export error: failed to encode final RTF as ASCII"
                          )])
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
                          userInfo: [NSLocalizedDescriptionKey: String(format: L("report.error.zip_rtfd_format", comment: "Zip export error with path"), dir.path)])
        }
    }

    // ==== DOCX (Office Open XML) helpers ====

    /// Derive a DOCX title from body text (prefers patient name and visit type).
    private func makeDocxTitle(from rawText: String) -> String {
        var patientName: String?
        var visitType: String?

        // NOTE: These prefixes must match the labels used in the rendered report text.
        // They are localized so DOCX titles remain correct in non-English locales.
        let patientPrefix = L(
            "report.docx.parse.patient_prefix",
            comment: "DOCX title parser: prefix for patient line (must match rendered report label, e.g., 'Patient:')"
        )
        let currentVisitPrefix = L(
            "report.docx.parse.current_visit_prefix",
            comment: "DOCX title parser: prefix for current visit line (must match rendered report label, e.g., 'Current Visit')"
        )

        for line in rawText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            // Extract patient name from "Patient: Pablo Picasso (Alias ...)" line
            if trimmed.hasPrefix(patientPrefix) {
                let rest = trimmed.dropFirst(patientPrefix.count).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty {
                    if let parenIndex = rest.firstIndex(of: "(") {
                        let namePart = rest[..<parenIndex]
                        patientName = namePart.trimmingCharacters(in: .whitespaces)
                    } else {
                        patientName = rest
                    }
                }
            }

            // Extract visit type from "Current Visit — 1-month visit" line
            if trimmed.hasPrefix(currentVisitPrefix) {
                // Look for an em dash or regular dash as separator
                if let dashRange = trimmed.range(of: "—") ?? trimmed.range(of: "-") {
                    let after = trimmed[dashRange.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !after.isEmpty {
                        visitType = after
                    }
                }
            }

            if patientName != nil && visitType != nil {
                break
            }
        }

        let name = patientName ?? L(
            "report.docx.title.fallback",
            comment: "DOCX title fallback when patient name cannot be parsed"
        )
        let sep = L(
            "report.docx.title.separator",
            comment: "DOCX title separator between patient name and visit type (includes surrounding spaces if desired)"
        )
        if let vt = visitType, !vt.isEmpty {
            return "\(name)\(sep)\(vt)"
        } else {
            return name
        }
    }

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
    /// Uses Foundation's Archive API instead of /usr/bin/zip to avoid sandbox issues when writing
    /// to user‑selected locations (e.g. Downloads) from a sandboxed app.
    private func zipDocxPackage(at packageRoot: URL, to zipFile: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: zipFile.path) {
            try fm.removeItem(at: zipFile)
        }

        // Use in‑process ZIP via Foundation.Archive (10.13+).
        if #available(macOS 10.13, *) {
            guard let archive = Archive(url: zipFile, accessMode: .create) else {
                throw NSError(
                    domain: "ReportExport",
                    code: 5002,
                    userInfo: [NSLocalizedDescriptionKey: String(format: L(
                        "report.error.docx_archive_create_format",
                        comment: "DOCX export error: failed to create archive (format expects 1 path)"
                    ), zipFile.path)]
                )
            }

            // Enumerate all files under packageRoot and add them with paths relative to packageRoot.
            guard let enumerator = fm.enumerator(at: packageRoot,
                                                 includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [],
                                                 errorHandler: { url, error in
                                                     NSLog("[ReportExport] docx enumerator error for %@: %@", url.path, String(describing: error))
                                                     return true
                                                 }) else {
                throw NSError(
                    domain: "ReportExport",
                    code: 5003,
                    userInfo: [NSLocalizedDescriptionKey: String(format: L(
                        "report.error.docx_package_enumerate_format",
                        comment: "DOCX export error: failed to enumerate package directory (format expects 1 path)"
                    ), packageRoot.path)]
                )
            }

            for case let fileURL as URL in enumerator {
                let rv = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
                if rv.isDirectory == true {
                    // Directories do not need explicit entries in the zip; they are implied by file paths.
                    continue
                }

                // Compute path inside the zip as a relative path from packageRoot.
                let fullPath = fileURL.path
                let basePath = packageRoot.path
                var relPath: String
                if fullPath.hasPrefix(basePath) {
                    let start = fullPath.index(fullPath.startIndex, offsetBy: basePath.count)
                    relPath = String(fullPath[start...])
                    if relPath.hasPrefix("/") {
                        relPath.removeFirst()
                    }
                } else {
                    // Fallback: just use the last path component.
                    relPath = fileURL.lastPathComponent
                }

                // Add the entry using the convenience relativeTo: API.
                do {
                    try archive.addEntry(with: relPath,
                                         relativeTo: packageRoot,
                                         compressionMethod: .deflate)
                } catch {
                    NSLog("[ReportExport] failed to add %@ to DOCX archive: %@", relPath, String(describing: error))
                    throw NSError(
                        domain: "ReportExport",
                        code: 5004,
                        userInfo: [NSLocalizedDescriptionKey: String(format: L(
                            "report.error.docx_add_entry_format",
                            comment: "DOCX export error: failed to add an entry (format expects entry path, then docx path)"
                        ), relPath, zipFile.path)]
                    )
                }
            }
        } else {
            // Very old macOS fallback: this path may still hit sandbox limits when targeting user folders.
            // Kept only for completeness; modern targets should always go through the Archive path above.
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            task.currentDirectoryURL = packageRoot
            task.arguments = ["-r", "-y", zipFile.path, "."]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError  = pipe
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                NSLog("[ReportExport] docx zip failed (%d): %@", task.terminationStatus, out)
                throw NSError(
                    domain: "ReportExport",
                    code: 5001,
                    userInfo: [NSLocalizedDescriptionKey: String(format: L(
                        "report.error.docx_zip_failed_format",
                        comment: "DOCX export error: failed to zip package (format expects 1 path)"
                    ), packageRoot.path)]
                )
            }
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
    /// Export a minimal Word (.docx) report with Growth Charts embedded.
    /// v1 focuses on verifying image embedding works reliably in Word.
    func exportDOCX(for kind: VisitKind) throws -> URL {
        // Build text (title) and decide destination folder
        let (attr, stem) = try buildAttributedReport(for: kind)

        // DOCX now uses the already age-gated body from WellReportData / ReportDataLoader.
        // No extra text-level gating here; ReportBuilder is a dumb renderer.
        let bodyTextForDocx = attr.string

        let fm = FileManager.default
        let baseDir: URL = {
            // Always export DOCX outside the bundle so it does NOT appear in the in-bundle Document Viewer.
            // Use a fixed per-user export folder.
            let docsRoot = fm.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
            return docsRoot.appendingPathComponent("DrsMainApp/Exports", isDirectory: true)
        }()
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let outURL = baseDir.appendingPathComponent("\(stem).docx")

        // Title derived from body text (patient + visit type when available)
        let title = makeDocxTitle(from: bodyTextForDocx)

        // Prefix used by the rendered report line: "Current Visit — …".
        // Localized so Heading1 mapping works in non-English locales.
        let currentVisitLinePrefix = L(
            "report.docx.heading.current_visit_line_prefix",
            comment: "DOCX heading detection: prefix for the 'Current Visit — …' line (must match rendered report)"
        )

        // === Heading mapping for Word navigation / anchors ===
        // Only true section titles + current visit title become Heading1.
        // Localized so we can correctly detect headings in the localized body text.
        let headingSet: Set<String> = [
            // Well visit sections (top of report)
            L("report.docx.heading.well_visit_summary", comment: "DOCX heading detection: Well Visit Summary"),
            L("report.docx.heading.perinatal_summary", comment: "DOCX heading detection: Perinatal Summary"),
            L("report.docx.heading.findings_previous_well_visits", comment: "DOCX heading detection: Findings from Previous Well Visits"),

            // Existing well visit sections
            L("report.docx.heading.parents_concerns", comment: "DOCX heading detection: Parents’ Concerns"),
            L("report.docx.heading.feeding", comment: "DOCX heading detection: Feeding"),
            L("report.docx.heading.supplementation", comment: "DOCX heading detection: Supplementation"),
            L("report.docx.heading.sleep", comment: "DOCX heading detection: Sleep"),
            L("report.docx.heading.developmental_evaluation", comment: "DOCX heading detection: Developmental Evaluation"),
            L("report.docx.heading.age_specific_milestones", comment: "DOCX heading detection: Age-specific Milestones"),
            L("report.docx.heading.measurements", comment: "DOCX heading detection: Measurements"),
            L("report.docx.heading.physical_examination", comment: "DOCX heading detection: Physical Examination"),
            L("report.docx.heading.problem_listing", comment: "DOCX heading detection: Problem Listing"),
            L("report.docx.heading.conclusions", comment: "DOCX heading detection: Conclusions"),
            L("report.docx.heading.anticipatory_guidance", comment: "DOCX heading detection: Anticipatory Guidance"),
            L("report.docx.heading.clinician_comments", comment: "DOCX heading detection: Clinician Comments"),
            L("report.docx.heading.next_visit_date", comment: "DOCX heading detection: Next Visit Date"),
            L("report.docx.heading.growth_charts", comment: "DOCX heading detection: Growth Charts"),

            // Sick visit sections
            L("report.docx.heading.sick_visit_report", comment: "DOCX heading detection: Sick Visit Report"),
            L("report.docx.heading.main_complaint", comment: "DOCX heading detection: Main Complaint"),
            L("report.docx.heading.hpi", comment: "DOCX heading detection: History of Present Illness"),
            L("report.docx.heading.duration", comment: "DOCX heading detection: Duration"),
            L("report.docx.heading.basics", comment: "DOCX heading detection: Basics"),
            L("report.docx.heading.past_medical_history", comment: "DOCX heading detection: Past Medical History"),
            L("report.docx.heading.vaccination", comment: "DOCX heading detection: Vaccination"),
            L("report.docx.heading.vitals", comment: "DOCX heading detection: Vitals"),
            L("report.docx.heading.investigations", comment: "DOCX heading detection: Investigations"),
            L("report.docx.heading.working_diagnosis", comment: "DOCX heading detection: Working Diagnosis"),
            L("report.docx.heading.icd10", comment: "DOCX heading detection: ICD-10"),
            L("report.docx.heading.plan_anticipatory", comment: "DOCX heading detection: Plan & Anticipatory Guidance"),
            L("report.docx.heading.medications", comment: "DOCX heading detection: Medications"),
            L("report.docx.heading.followup_next_visit", comment: "DOCX heading detection: Follow-up / Next Visit")
        ]

        // Problem Listing milestone formatting (shared text pipeline step)
        let problemListingHeading = L(
            "report.docx.heading.problem_listing",
            comment: "DOCX heading detection: Problem Listing"
        )
        let milestonesHeader = L(
            "well_visit_form.problem_listing.milestones.header",
            comment: "Problem listing subheader shown before milestone bullet lines"
        )

        var styledParagraphs: [(text: String, style: String?)] = []

        // Each non-empty line becomes a paragraph; only section headings / current visit line are Heading1.
        for line in bodyTextForDocx.components(separatedBy: .newlines) {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }

            if s.hasPrefix(currentVisitLinePrefix) || headingSet.contains(s) {
                styledParagraphs.append((s, "Heading1"))
            } else {
                styledParagraphs.append((s, nil))
            }
        }

        // Normalize milestone bullet formatting (shared rule):
        // - Converts "• - ..." to "• ..." (removes the extra dash)
        // - Inserts a single "• <Milestones header>" line before the first milestone item in each bullet block
        // - Resets per block when a non-bullet paragraph appears (e.g., each previous-visit header line)
        styledParagraphs = normalizeMilestoneBullets(in: styledParagraphs,
                                                     milestonesHeader: milestonesHeader)

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
                    if let tiff = img.tiffRepresentation,
                       let rep  = NSBitmapImageRep(data: tiff),
                       let png  = rep.representation(using: .png, properties: [:]) {
                        images.append((data: png, filename: "image\(i+1).png", sizePts: renderSize))
                    }
                }
                NSLog("[ReportDebug] %@",
                      String(format: L(
                        "report.debug.docx_charts_embedded_count_format",
                        comment: "Debug log: DOCX embedded charts count and size in points (format: count, width, height)"
                      ),
                      images.count,
                      images.first?.sizePts.width ?? 0,
                      images.first?.sizePts.height ?? 0))
            }
        case .sick:
            break
        }

        try writeDocxPackage(
            title: title,
            styledParagraphs: styledParagraphs,
            images: images,
            destinationURL: outURL
        )
        NSLog("[ReportExport] %@",
              String(format: L(
                "report.export.wrote_docx_format",
                comment: "Export log: wrote DOCX file (format expects 1 path)"
              ), outURL.path))
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
        let attributed = assembleAttributed(meta: meta, sections: sections)
        let range = NSRange(location: 0, length: attributed.length)
        guard let data = attributed.rtf(from: range,
                                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else {
            throw NSError(domain: "ReportExport", code: 6001,
                          userInfo: [NSLocalizedDescriptionKey: L("report.error.generate_rtf_data", comment: "RTF export error: failed to generate RTF data")])
        }
        return data
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
        NSLog("[ReportExport] %@",
              String(format: L(
                "report.export.rtf_shim_returned_docx_format",
                comment: "Export log: RTF shim returned DOCX instead (format expects 1 path)"
              ), url.path))
        return url
    }
    
    
}


// MARK: - Rendering

private extension ReportBuilder {



    // Merge multiple PDF Data blobs into a single PDF
    private func mergePDFs(_ parts: [Data]) throws -> Data {
        let out = PDFDocument()
        var pageCursor = 0
        for (partIndex, d) in parts.enumerated() {
            guard let doc = PDFDocument(data: d) else {
                throw NSError(
                    domain: "ReportExport",
                    code: 200 + partIndex,
                    userInfo: [NSLocalizedDescriptionKey: String(format: L(
                        "report.error.read_intermediate_pdf_part_format",
                        comment: "PDF export error: failed to read intermediate PDF part (format expects 1-based part index)"
                    ), partIndex + 1)]
                )
            }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) {
                    out.insert(page, at: pageCursor)
                    pageCursor += 1
                }
            }
        }
        guard let data = out.dataRepresentation() else {
            throw NSError(
                domain: "ReportExport",
                code: 299,
                userInfo: [NSLocalizedDescriptionKey: L(
                    "report.error.create_merged_pdf_data",
                    comment: "PDF export error: failed to create merged PDF data"
                )]
            )
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
            throw NSError(domain: "ReportExport", code: 310, userInfo: [NSLocalizedDescriptionKey: L(
                "report.error.charts_pdf_consumer_failed",
                comment: "PDF export error: ChartsPDF consumer creation failed"
            )])
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "ReportExport", code: 311, userInfo: [NSLocalizedDescriptionKey: L(
                "report.error.charts_pdf_context_failed",
                comment: "PDF export error: ChartsPDF context creation failed"
            )])
        }

        for (idx, img) in images.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(mediaBox)

            // Draw using a non-flipped context and explicit coordinates (origin = bottom-left).

            // Caption at the top of the content rect (drawn with AppKit text)
            let caption: String
            switch idx {
            case 0:
                caption = L("report.chart.caption.weight_for_age", comment: "Chart caption: Weight-for-Age")
            case 1:
                caption = L("report.chart.caption.length_for_age", comment: "Chart caption: Length/Height-for-Age")
            default:
                caption = L("report.chart.caption.head_circumference_for_age", comment: "Chart caption: Head Circumference-for-Age")
            }
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

    /// Shared milestone bullet normalization used by report renderers.
    ///
    /// Why:
    /// - Some upstream sources produce milestone lines as "• - …" (a bullet that contains a dash-bullet),
    ///   which renders as a double bullet.
    /// - We also want a single localized "Milestones" subheader inserted once per bullet block,
    ///   including inside each previous-visit block.
    private func normalizeMilestoneBullets(
        in paragraphs: [(text: String, style: String?)],
        milestonesHeader: String
    ) -> [(text: String, style: String?)] {
        guard !paragraphs.isEmpty else { return paragraphs }

        var out: [(text: String, style: String?)] = []
        out.reserveCapacity(paragraphs.count + 4)

        // Insert header once per bullet block (resets on headings and non-bullet paragraphs).
        var insertedHeaderInBlock = false

        func startsWithDash(_ s: Substring) -> Bool {
            guard let first = s.first else { return false }
            return first == "-" || first == "–" || first == "—"
        }
        

        func stripLeadingDashesAndSpace(_ s: Substring) -> Substring {
            var t = s
            while let first = t.first, (first == "-" || first == "–" || first == "—") {
                t = t.dropFirst()
                // trim only leading whitespace after each dash removal
                while let ws = t.first, ws == " " || ws == "\t" { t = t.dropFirst() }
            }
            return t
        }

        for (rawText, rawStyle) in paragraphs {
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // Keep empty lines, but do not reset state.
                out.append((rawText, rawStyle))
                continue
            }

            // Any Heading1 acts as a block boundary.
            if rawStyle == "Heading1" {
                insertedHeaderInBlock = false
                out.append((rawText, rawStyle))
                continue
            }

            // Non-bullet paragraph starts a new block (this is what resets per previous-visit header line).
            if !trimmed.hasPrefix("•") {
                insertedHeaderInBlock = false
                out.append((rawText, rawStyle))
                continue
            }

            // Bullet paragraph
            var content = trimmed.dropFirst()
            // trim spaces after the bullet
            while let first = content.first, first == " " || first == "\t" { content = content.dropFirst() }

            let contentStr = String(content).trimmingCharacters(in: .whitespacesAndNewlines)

            // If the upstream already wrote the milestones header as a bullet, keep only one per block.
            if contentStr == milestonesHeader {
                if insertedHeaderInBlock {
                    // Skip duplicates
                    continue
                } else {
                    insertedHeaderInBlock = true
                    out.append(("• \(milestonesHeader)", nil))
                    continue
                }
            }

            // Milestone items are encoded as "• - ..." (or en/em dash variants).
            if startsWithDash(content) {
                if !insertedHeaderInBlock {
                    out.append(("• \(milestonesHeader)", nil))
                    insertedHeaderInBlock = true
                }
                let cleaned = stripLeadingDashesAndSpace(content)
                let cleanedLine = "• \(cleaned)"
                out.append((cleanedLine, nil))
                continue
            }

            // Other bullets unchanged.
            out.append((rawText, rawStyle))
        }

        return out
    }

/// Shared milestone bullet normalization for **attributed** report bodies (PDF/RTF/RTFD).
///
/// - Converts "• - …" (or en/em dash variants) into "• …".
/// - Inserts one localized milestones header bullet ("• <Milestones header>") before the
///   first milestone item in each bullet block.
/// - Resets per block when encountering any non-bullet paragraph.
private func normalizeMilestoneBullets(
    in attributed: NSAttributedString,
    milestonesHeader: String
) -> NSAttributedString {
    guard attributed.length > 0 else { return attributed }

    let out = NSMutableAttributedString(attributedString: attributed)
    var insertedHeaderInBlock = false

    func isDash(_ ch: Character) -> Bool {
        ch == "-" || ch == "–" || ch == "—"
    }

    func leadingContentAfterBullet(_ trimmed: String) -> Substring {
        var s = trimmed.dropFirst() // drop the bullet
        while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
        return s
    }

    var loc = 0
    while loc < out.length {
        // Recompute NSString each loop because we mutate `out`
        let ns = out.string as NSString
        let paraRange = ns.paragraphRange(for: NSRange(location: loc, length: 0))

        let paraText = ns.substring(with: paraRange)
        let trimmed = paraText.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            loc = NSMaxRange(paraRange)
            continue
        }

        // Non-bullet paragraph starts a new block (resets per previous-visit header line).
        if !trimmed.hasPrefix("•") {
            insertedHeaderInBlock = false
            loc = NSMaxRange(paraRange)
            continue
        }

        // Bullet paragraph
        let content = leadingContentAfterBullet(trimmed)
        let contentStr = String(content).trimmingCharacters(in: .whitespacesAndNewlines)

        // If upstream already wrote the milestones header as a bullet, keep only one per block.
        if contentStr == milestonesHeader {
            if insertedHeaderInBlock {
                out.replaceCharacters(in: paraRange, with: "")
                continue
            } else {
                insertedHeaderInBlock = true
                loc = NSMaxRange(paraRange)
                continue
            }
        }

        // Milestone items are encoded as "• - ..." (or en/em dash variants).
        if let first = content.first, isDash(first) {
            // Insert header once per bullet block.
            if !insertedHeaderInBlock {
                let attrs = out.attributes(at: paraRange.location, effectiveRange: nil)
                let headerLine = "• \(milestonesHeader)\n"
                out.insert(NSAttributedString(string: headerLine, attributes: attrs),
                           at: paraRange.location)
                insertedHeaderInBlock = true
                // Move `loc` to the original paragraph (now shifted down by header line)
                loc = paraRange.location + (headerLine as NSString).length
                continue
            }

            // Strip leading dash(es) + spaces
            var cleaned = content
            while let f = cleaned.first, isDash(f) {
                cleaned = cleaned.dropFirst()
                while let ws = cleaned.first, ws == " " || ws == "\t" { cleaned = cleaned.dropFirst() }
            }

            let attrs = out.attributes(at: paraRange.location, effectiveRange: nil)
            let cleanedLine = "• \(cleaned)\n"
            out.replaceCharacters(in: paraRange,
                                  with: NSAttributedString(string: cleanedLine, attributes: attrs))

            loc = paraRange.location + (cleanedLine as NSString).length
            continue
        }

        // Other bullets unchanged.
        loc = NSMaxRange(paraRange)
    }

    return out
}
/// Split the stored `previousVisitFindings` blob into clean per-line items.
///
/// Supports:
/// 1) Single-line blob with " • " separators (legacy)
/// 2) Multi-line text with each item on its own line (preferred)
/// 3) Already-bulleted lines ("• …")
///
/// Returned items are *bulletless* (caller adds the leading "• "),
/// and we preserve leading dash items ("- / – / —") so `normalizeMilestoneBullets(...)`
/// can insert the milestones header + strip the extra dash.
private func splitPreviousVisitFindingLines(_ raw: String) -> [String] {
    let s = raw
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")

    let parts: [String]
    if s.contains(" • ") {
        parts = s.components(separatedBy: " • ")
    } else {
        parts = s.components(separatedBy: .newlines)
    }

    return parts.compactMap { p in
        var t = p.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        // Avoid "• • ..." when the stored text already contains bullets
        if t.hasPrefix("•") {
            t.removeFirst()
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return t.isEmpty ? nil : t
    }
}
