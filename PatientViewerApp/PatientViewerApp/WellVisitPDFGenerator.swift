//
//  WellVisitPdfGenerator.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/11/25.
//

import Foundation
import SQLite
import PDFKit
import UIKit
import OSLog
import CoreText



struct WellVisitPDFGenerator {
    private static let log = Logger(subsystem: "com.patientviewer.app", category: "pdf.well")
    // Simple localization helper for non-SwiftUI code (PDF rendering).
    // Uses the key if available in Localizable.strings, otherwise falls back to the provided English.
    private static func L(_ key: String, _ fallback: String) -> String {
        NSLocalizedString(key, value: fallback, comment: "")
    }
    
    // MARK: - Addenda (SQLite.swift style)

    private struct ReportAddendumLite {
        let createdAtISO: String?
        let updatedAtISO: String?
        let authorName: String?
        let text: String
    }

    private static func clean(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private static func tableExists(_ db: Connection, name: String) -> Bool {
        do {
            let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='\(name)'"
            if let n = try db.scalar(sql) as? Int64 { return n > 0 }
        } catch { }
        return false
    }

    private static func fetchAddendaForWellVisit(db: Connection, wellVisitID: Int64) -> [ReportAddendumLite] {
        // Addenda are stored in `visit_addenda` in exported bundles (same as sick visits).
        guard tableExists(db, name: "visit_addenda") else { return [] }

        func columns(in table: String) -> [String] {
            do {
                var out: [String] = []
                let stmt = try db.prepare("PRAGMA table_info(\(table));")
                for row in stmt {
                    // PRAGMA table_info returns columns: cid(0), name(1), type(2), notnull(3), dflt_value(4), pk(5)
                    if row.count > 1, let name = row[1] as? String {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { out.append(trimmed) }
                    }
                }
                return out
            } catch {
                return []
            }
        }

        let cols = Set(columns(in: "visit_addenda"))

        // FK column varies across schema versions
        let fkCandidates = ["visit_id", "visitID", "well_visit_id", "wellVisitID", "well_visitID"]
        guard let fkCol = fkCandidates.first(where: { cols.contains($0) }) else { return [] }

        // Text column varies too
        let textCandidates = ["text", "content", "note", "addendum_text"]
        guard let textCol = textCandidates.first(where: { cols.contains($0) }) else { return [] }

        // Optional metadata columns
        let createdCol = ["created_at", "createdAt", "created_iso"].first(where: { cols.contains($0) })
        let updatedCol = ["updated_at", "updatedAt", "updated_iso"].first(where: { cols.contains($0) })
        let authorCol  = ["author_name", "clinician_name", "provider_name", "user_name"].first(where: { cols.contains($0) })

        let createdSel = createdCol ?? "NULL"
        let updatedSel = updatedCol ?? "NULL"
        let authorSel  = authorCol  ?? "NULL"

        let orderExpr: String = {
            if let c = createdCol { return "datetime(\(c))" }
            return "rowid"
        }()

        let sql = """
        SELECT \(textCol), \(createdSel), \(updatedSel), \(authorSel)
        FROM visit_addenda
        WHERE \(fkCol) = ?
        ORDER BY \(orderExpr) ASC, rowid ASC;
        """

        do {
            let stmt = try db.prepare(sql, wellVisitID)
            var out: [ReportAddendumLite] = []

            for row in stmt {
                let text = (row[0] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                let created = clean(row[1] as? String)
                let updated = clean(row[2] as? String)
                let author  = clean(row[3] as? String)

                out.append(.init(createdAtISO: created, updatedAtISO: updated, authorName: author, text: text))
            }
            return out
        } catch {
            return []
        }
    }

    private static func buildAddendaBody(_ addenda: [ReportAddendumLite]) -> String {
        guard !addenda.isEmpty else { return "" }

        var lines: [String] = []

        for a in addenda {
            let created = clean(a.createdAtISO)
            let updated = clean(a.updatedAtISO)
            let author  = clean(a.authorName)

            var header = ""
            if let c = created, let u = updated, c != u {
                header = "\(c) (updated \(u))"
            } else if let c = created {
                header = c
            } else if let u = updated {
                header = u
            }

            if let author = author {
                header = header.isEmpty ? author : "\(header) — \(author)"
            }

            if !header.isEmpty { lines.append(header) }

            let parts = a.text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if parts.isEmpty {
                lines.append("• ")
            } else {
                for p in parts { lines.append("• \(p)") }
            }

            lines.append("") // spacer
        }

        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }

        return lines.joined(separator: "\n")
    }
    
    static func generate(for visit: VisitSummary, dbURL: URL) async throws -> URL? {
        WellVisitPDFGenerator.log.info("Generating WellVisit PDF for id=\(visit.id, privacy: .public) base=\(dbURL.path, privacy: .public)")
        let pdfMetaData = [
            kCGPDFContextCreator: WellVisitPDFGenerator.L("well_report.pdf.meta.creator", "Patient Viewer"),
            kCGPDFContextAuthor:  WellVisitPDFGenerator.L("well_report.pdf.meta.author",  "Patient App"),
            kCGPDFContextTitle:   WellVisitPDFGenerator.L("well_report.pdf.meta.title",   "Well Visit Report")
        ]
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = pdfMetaData as [String: Any]

        let pageWidth = 595.2
        let pageHeight = 841.8
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)

        let margin: CGFloat = 40
        let contentWidth = pageWidth - 2 * margin

        // Visit type mapping for readable names (localized)
        let visitMap: [String: String] = [
            // Newborn / post-maternity first visit
            "newborn_first": WellVisitPDFGenerator.L(
                "well_report.visit_type.first_visit_after_maternity",
                "First visit after maternity"
            ),

            // Standard milestone visits
            "one_month": WellVisitPDFGenerator.L("well_report.visit_type.one_month", "1-month visit"),
            "two_month": WellVisitPDFGenerator.L("well_report.visit_type.two_month", "2-month visit"),
            "four_month": WellVisitPDFGenerator.L("well_report.visit_type.four_month", "4-month visit"),
            "six_month": WellVisitPDFGenerator.L("well_report.visit_type.six_month", "6-month visit"),
            "nine_month": WellVisitPDFGenerator.L("well_report.visit_type.nine_month", "9-month visit"),
            "twelve_month": WellVisitPDFGenerator.L("well_report.visit_type.twelve_month", "12-month visit"),
            "fifteen_month": WellVisitPDFGenerator.L("well_report.visit_type.fifteen_month", "15-month visit"),
            "eighteen_month": WellVisitPDFGenerator.L("well_report.visit_type.eighteen_month", "18-month visit"),
            "twentyfour_month": WellVisitPDFGenerator.L("well_report.visit_type.twentyfour_month", "24-month visit"),
            "thirty_month": WellVisitPDFGenerator.L("well_report.visit_type.thirty_month", "30-month visit"),
            "thirtysix_month": WellVisitPDFGenerator.L("well_report.visit_type.thirtysix_month", "36-month visit"),

            // Preschool / school-age milestone visits
            "four_year": WellVisitPDFGenerator.L("well_report.visit_type.four_year", "4-year visit"),
            "five_year": WellVisitPDFGenerator.L("well_report.visit_type.five_year", "5-year visit")
        ]

        let defaultWellVisitTitle = WellVisitPDFGenerator.L("well_report.visit_type.well_visit", "Well Visit")

        // Helper to compute age in months, with fallback to DOB + visit date if age_days is missing
        func computeAgeMonths(dobString: String, visitDateString: String, ageDays: Int?) -> Double? {
            // Prefer explicit age_days when it is available and positive
            if let ageDays = ageDays, ageDays > 0 {
                return Double(ageDays) / 30.0
            }

            let dobFormatter = DateFormatter()
            dobFormatter.dateFormat = "yyyy-MM-dd"
            dobFormatter.locale = Locale(identifier: "en_US_POSIX")

            guard let dobDate = dobFormatter.date(from: dobString) else {
                WellVisitPDFGenerator.log.warning("computeAgeMonths: unable to parse DOB='\(dobString)'")
                return nil
            }

            // Try to parse visitDateString using ISO8601 (handles 'Z' and fractional seconds)
            var visitDate: Date? = nil
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            visitDate = isoFormatter.date(from: visitDateString)

            if visitDate == nil {
                isoFormatter.formatOptions = [.withInternetDateTime]
                visitDate = isoFormatter.date(from: visitDateString)
            }

            // Fallback to a legacy formatter with full datetime and fractional seconds
            if visitDate == nil {
                let legacyFormatter = DateFormatter()
                legacyFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
                legacyFormatter.locale = Locale(identifier: "en_US_POSIX")
                visitDate = legacyFormatter.date(from: visitDateString)
            }

            // Final fallback: plain date-only format (e.g. "2027-10-24")
            if visitDate == nil {
                let dateOnlyFormatter = DateFormatter()
                dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
                dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
                visitDate = dateOnlyFormatter.date(from: visitDateString)
            }

            guard let finalVisitDate = visitDate else {
                WellVisitPDFGenerator.log.warning("computeAgeMonths: unable to parse visitDate='\(visitDateString)' with ISO8601, legacy, or date-only formatter")
                return nil
            }

            let interval = finalVisitDate.timeIntervalSince(dobDate)
            let days = interval / (60.0 * 60.0 * 24.0)
            if days < 0 {
                WellVisitPDFGenerator.log.warning("computeAgeMonths: negative age (days=\(days)) for DOB='\(dobString)' visitDate='\(visitDateString)'")
            }
            // Clamp at 0 months so misconfigured dates don't hide age-gated content
            return max(0.0, days / 30.0)
        }
        
        // Helper to compute a human-readable age string for the header
        func formatAgeString(dobString: String, visitDateString: String, ageDays: Int?) -> String? {
            // Parse DOB
            let dobFormatter = DateFormatter()
            dobFormatter.dateFormat = "yyyy-MM-dd"
            dobFormatter.locale = Locale(identifier: "en_US_POSIX")

            guard let dobDate = dobFormatter.date(from: dobString) else {
                WellVisitPDFGenerator.log.warning("formatAgeString: unable to parse DOB='\(dobString)'")
                return nil
            }

            // Parse visit date using same strategy as computeAgeMonths
            var visitDate: Date? = nil
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            visitDate = isoFormatter.date(from: visitDateString)

            if visitDate == nil {
                isoFormatter.formatOptions = [.withInternetDateTime]
                visitDate = isoFormatter.date(from: visitDateString)
            }

            if visitDate == nil {
                let legacyFormatter = DateFormatter()
                legacyFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
                legacyFormatter.locale = Locale(identifier: "en_US_POSIX")
                visitDate = legacyFormatter.date(from: visitDateString)
            }

            if visitDate == nil {
                let dateOnlyFormatter = DateFormatter()
                dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
                dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
                visitDate = dateOnlyFormatter.date(from: visitDateString)
            }

            guard let finalVisitDate = visitDate else {
                WellVisitPDFGenerator.log.warning("formatAgeString: unable to parse visitDate='\(visitDateString)'")
                return nil
            }

            // Localized unit formats
            let fmtDaySing  = WellVisitPDFGenerator.L("well_report.age.day_singular", "%d day")
            let fmtDayPlur  = WellVisitPDFGenerator.L("well_report.age.day_plural", "%d days")
            let fmtMonthSing = WellVisitPDFGenerator.L("well_report.age.month_singular", "%d month")
            let fmtMonthPlur = WellVisitPDFGenerator.L("well_report.age.month_plural", "%d months")
            let fmtYearSing  = WellVisitPDFGenerator.L("well_report.age.year_singular", "%d year")
            let fmtYearPlur  = WellVisitPDFGenerator.L("well_report.age.year_plural", "%d years")

            let fmtMonthDay = WellVisitPDFGenerator.L("well_report.age.format.month_day", "%@ %@")
            let fmtYearMonth = WellVisitPDFGenerator.L("well_report.age.format.year_month", "%@ %@")

            func unit(_ n: Int, singular: String, plural: String) -> String {
                String(format: (n == 1 ? singular : plural), n)
            }

            // If misconfigured and visit is before DOB, clamp to 0 days
            if finalVisitDate < dobDate {
                return String(format: fmtDayPlur, 0)
            }

            let calendar = Calendar(identifier: .gregorian)
            let components = calendar.dateComponents([.year, .month, .day], from: dobDate, to: finalVisitDate)

            let years = max(0, components.year ?? 0)
            let months = max(0, components.month ?? 0)
            let days = max(0, components.day ?? 0)

            // Before 1 month: show days
            if years == 0 && months == 0 {
                return unit(days, singular: fmtDaySing, plural: fmtDayPlur)
            }

            // From 1 month to 12 months: month + optional days
            if years == 0 && months >= 1 {
                let monthPart = unit(months, singular: fmtMonthSing, plural: fmtMonthPlur)
                if days > 0 {
                    let dayPart = unit(days, singular: fmtDaySing, plural: fmtDayPlur)
                    return String(format: fmtMonthDay, monthPart, dayPart)
                } else {
                    return monthPart
                }
            }

            // From 12 months onward: years + optional months
            let yearPart = unit(years, singular: fmtYearSing, plural: fmtYearPlur)
            if months > 0 {
                let monthPart = unit(months, singular: fmtMonthSing, plural: fmtMonthPlur)
                return String(format: fmtYearMonth, yearPart, monthPart)
            } else {
                return yearPart
            }
        }

        // Helper to draw wrapped text for long lines (e.g., summary sections)
        func drawWrappedText(_ text: String, font: UIFont, in rect: CGRect, at y: inout CGFloat, using rendererContext: UIGraphicsPDFRendererContext) {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraphStyle
            ]

            let attributedText = NSAttributedString(string: text, attributes: attributes)
            let framesetter = CTFramesetterCreateWithAttributedString(attributedText as CFAttributedString)

            var currentRange = CFRange(location: 0, length: 0)

            repeat {
                var availableHeight = rect.height - y - margin
                if availableHeight < font.lineHeight * 2 {
                    rendererContext.beginPage()
                    y = margin
                    availableHeight = rect.height - y - margin
                }

                let path = CGMutablePath()
                path.addRect(CGRect(
                    x: rect.minX + margin,
                    y: rect.height - y - availableHeight,
                    width: rect.width - 2 * margin,
                    height: availableHeight
                ))

                let frame = CTFramesetterCreateFrame(framesetter, currentRange, path, nil)
                let visibleRange = CTFrameGetVisibleStringRange(frame)

                let cgContext = rendererContext.cgContext
                cgContext.saveGState()
                cgContext.textMatrix = .identity
                cgContext.translateBy(x: 0, y: rect.height)
                cgContext.scaleBy(x: 1.0, y: -1.0)
                CTFrameDraw(frame, cgContext)
                cgContext.restoreGState()

                let suggestedSize = CTFramesetterSuggestFrameSizeWithConstraints(
                    framesetter,
                    currentRange,
                    nil,
                    CGSize(width: rect.width - 2 * margin, height: .greatestFiniteMagnitude),
                    nil
                )
                y += suggestedSize.height + 6

                currentRange.location += visibleRange.length
                currentRange.length = 0

                if currentRange.location < attributedText.length {
                    rendererContext.beginPage()
                    y = margin
                }

            } while currentRange.location < attributedText.length
        }

        // Preload chart images before entering PDF rendering
        var chartImagesToRender: [(String, UIImage)] = []
        
        // We'll need sexText and dbPath before rendering
        var sexTextForCharts: String = ""
        let dbPath: String = dbURL.appendingPathComponent("db.sqlite").path
        WellVisitPDFGenerator.log.debug("Opening SQLite at path=\(dbPath, privacy: .public)")
        var pid: Int64 = 0
        // Approximate age in months at this visit for growth-chart gating (patient points only)
        var ageMonthsForCharts: Double? = nil

        do {
            let db = try Connection(dbPath)
            let wellVisits = Table("well_visits")
            let visitID = Expression<Int64>("id")
            let patientID = Expression<Int64>("patient_id")
            let visitDateCol = Expression<String>("visit_date")
            let ageDaysCol = Expression<Int?>("age_days")
            let sex = Expression<String>("sex")
            guard let visitRow = try db.pluck(wellVisits.filter(visitID == visit.id)) else {
                // If visit not found, skip chart images
                return nil
            }

            let visitDateString = visitRow[visitDateCol]
            let ageDaysDBForCharts = visitRow[ageDaysCol]

            let patients = Table("patients")
            let id = Expression<Int64>("id")
            let dob = Expression<String>("dob")

            pid = visitRow[patientID]
            if let patientRow = try db.pluck(patients.filter(id == pid)) {
                sexTextForCharts = patientRow[sex]
                let dobTextForCharts = patientRow[dob]

                // Compute approximate age in months at this visit for chart gating
                ageMonthsForCharts = computeAgeMonths(
                    dobString: dobTextForCharts,
                    visitDateString: visitDateString,
                    ageDays: ageDaysDBForCharts
                )

                if let months = ageMonthsForCharts {
                    WellVisitPDFGenerator.log.debug("Preloading growth charts for patient \(pid, privacy: .public) sex=\(sexTextForCharts, privacy: .public) ageMonthsForCharts=\(months, privacy: .public)")
                } else {
                    WellVisitPDFGenerator.log.debug("Preloading growth charts for patient \(pid, privacy: .public) sex=\(sexTextForCharts, privacy: .public); ageMonthsForCharts=nil (no cutoff will be applied)")
                }
            }
        } catch {
            WellVisitPDFGenerator.log.error("Failed to read patient/sex for charts: \(error.localizedDescription, privacy: .public)")
            sexTextForCharts = ""
        }
        if sexTextForCharts == "M" || sexTextForCharts == "F" {
            let chartTypes: [(String, String, String)] = [
                (
                    "weight",
                    WellVisitPDFGenerator.L(
                        "well_report.growth_chart.title.weight_for_age",
                        "Weight-for-Age (0–60m)"
                    ),
                    "wfa_0_24m_\(sexTextForCharts)"
                ),
                (
                    "height",
                    WellVisitPDFGenerator.L(
                        "well_report.growth_chart.title.length_for_age",
                        "Length-for-Age (0–60m)"
                    ),
                    "lhfa_0_24m_\(sexTextForCharts)"
                ),
                (
                    "head_circ",
                    WellVisitPDFGenerator.L(
                        "well_report.growth_chart.title.head_circumference_for_age",
                        "Head Circumference-for-Age (0–60m)"
                    ),
                    "hcfa_0_24m_\(sexTextForCharts)"
                ),
                (
                    "bmi",
                    WellVisitPDFGenerator.L(
                        "well_report.growth_chart.title.bmi_for_age",
                        "BMI-for-Age (0–60m)"
                    ),
                    "bmi_0_24m_\(sexTextForCharts)"
                )
            ]
            for (measurement, title, filename) in chartTypes {
                if let cutoff = ageMonthsForCharts {
                    WellVisitPDFGenerator.log.debug(
                        "Calling GrowthChartRenderer for \(measurement, privacy: .public) with ageMonthsForCharts=\(cutoff, privacy: .public) (visit id=\(visit.id, privacy: .public))"
                    )
                } else {
                    WellVisitPDFGenerator.log.debug(
                        "Calling GrowthChartRenderer for \(measurement, privacy: .public) with no age cutoff (ageMonthsForCharts=nil) (visit id=\(visit.id, privacy: .public))"
                    )
                }

                if let chartImage = await GrowthChartRenderer.generateChartImage(
                    dbPath: dbPath,
                    patientID: pid,
                    measurement: measurement,
                    sex: sexTextForCharts,
                    filename: filename,
                    maxAgeMonths: ageMonthsForCharts
                ) {
                    chartImagesToRender.append((title, chartImage))
                    WellVisitPDFGenerator.log.debug("Chart '\(title, privacy: .public)' generated (w=\(chartImage.size.width, privacy: .public), h=\(chartImage.size.height, privacy: .public))")
                } else {
                    WellVisitPDFGenerator.log.warning("Chart '\(title, privacy: .public)' was not generated (nil image)")
                }
            }
        }

        let data = renderer.pdfData { context in
            context.beginPage()
            var y: CGFloat = margin
            WellVisitPDFGenerator.log.debug("PDF rendering started; first page begun")
            func ensureSpace(for height: CGFloat) {
                if y + height > pageRect.maxY - margin {
                    WellVisitPDFGenerator.log.debug("Page break (remaining=\(pageRect.maxY - margin - y, privacy: .public), needed=\(height, privacy: .public))")
                    context.beginPage()
                    y = margin
                }
            }

            func drawText(_ text: String, font: UIFont, offset: CGFloat = margin) {
                let attributes: [NSAttributedString.Key: Any] = [.font: font]
                let attrString = NSAttributedString(string: text, attributes: attributes)

                let textRect = CGRect(x: offset, y: y, width: contentWidth, height: .greatestFiniteMagnitude)
                let boundingBox = attrString.boundingRect(with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                                                           options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                           context: nil)

                attrString.draw(in: textRect)
                y += ceil(boundingBox.height) + 6
            }
            
            // Section header drawing with a pale background (for visual separation)
            let sectionHeaderBgColor = UIColor.systemBlue.withAlphaComponent(0.12)

            func drawSectionTitle(_ text: String, font: UIFont) {
                let padX: CGFloat = 8
                let padY: CGFloat = 4

                let blockHeight = ceil(font.lineHeight + 2 * padY)
                ensureSpace(for: blockHeight + 6)

                // Background
                let bgRect = CGRect(x: margin, y: y, width: contentWidth, height: blockHeight)
                let cornerRadius: CGFloat = 6

                context.cgContext.saveGState()
                context.cgContext.setFillColor(sectionHeaderBgColor.cgColor)

                let path = UIBezierPath(roundedRect: bgRect, cornerRadius: cornerRadius)
                context.cgContext.addPath(path.cgPath)
                context.cgContext.fillPath()

                context.cgContext.restoreGState()

                // Text
                let attributes: [NSAttributedString.Key: Any] = [.font: font]
                let attrString = NSAttributedString(string: text, attributes: attributes)
                let textRect = CGRect(
                    x: margin + padX,
                    y: y + padY,
                    width: contentWidth - 2 * padX,
                    height: blockHeight - 2 * padY
                )
                attrString.draw(in: textRect)

                y += blockHeight + 6
            }

            // Report title banner (slightly darker blue than section headers)
            let reportTitleBgColor = UIColor.systemBlue.withAlphaComponent(0.45)

            func drawReportTitle(_ text: String, font: UIFont) {
                let padX: CGFloat = 12
                let padY: CGFloat = 10

                let blockHeight = ceil(font.lineHeight + 2 * padY)
                ensureSpace(for: blockHeight + 8)

                let bgRect = CGRect(x: margin, y: y, width: contentWidth, height: blockHeight)
                let cornerRadius: CGFloat = 10

                context.cgContext.saveGState()
                context.cgContext.setFillColor(reportTitleBgColor.cgColor)
                let path = UIBezierPath(roundedRect: bgRect, cornerRadius: cornerRadius)
                context.cgContext.addPath(path.cgPath)
                context.cgContext.fillPath()
                context.cgContext.restoreGState()

                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: UIColor.label
                ]
                let attrString = NSAttributedString(string: text, attributes: attributes)
                let textRect = CGRect(
                    x: margin + padX,
                    y: y + padY,
                    width: contentWidth - 2 * padX,
                    height: blockHeight - 2 * padY
                )
                attrString.draw(in: textRect)

                y += blockHeight + 8
            }

            let titleFont = UIFont.boldSystemFont(ofSize: 20)
            let subFont = UIFont.systemFont(ofSize: 14)

            drawReportTitle(WellVisitPDFGenerator.L("pdf.well.title", "Well Visit Report"), font: titleFont)
            let fmtGenerated = WellVisitPDFGenerator.L("pdf.well.generated.fmt", "Report Generated: %@")
            drawText(String(format: fmtGenerated, WellVisitPDFGenerator.formatDate(Date())), font: subFont)

            let dbPath = dbURL.appendingPathComponent("db.sqlite").path
            WellVisitPDFGenerator.log.debug("Opening SQLite at path=\(dbPath, privacy: .public)")
            do {
                let db = try Connection(dbPath)

                // Lookup visit
                let wellVisits = Table("well_visits")
                let visitID = Expression<Int64>("id")
                guard let visitRow = try db.pluck(wellVisits.filter(visitID == visit.id)) else {
                    WellVisitPDFGenerator.log.error("Visit id \(visit.id, privacy: .public) not found in DB")
                    drawText(
                        WellVisitPDFGenerator.L("well_report.error.visit_not_found", "❌ Error: Visit not found"),
                        font: subFont
                    )
                    return
                }

                let patients = Table("patients")
                let id = Expression<Int64>("id")
                let patientID = Expression<Int64>("patient_id")
                let firstName = Expression<String>("first_name")
                let lastName = Expression<String>("last_name")
                let dob = Expression<String>("dob")
                let sex = Expression<String>("sex")
                let mrn = Expression<String>("mrn")
                let alias = Expression<String?>("alias_label")

                let pid = visitRow[patientID]
                guard let patientRow = try db.pluck(patients.filter(id == pid)) else {
                    WellVisitPDFGenerator.log.error("Patient for visit id \(visit.id, privacy: .public) not found in DB")
                    drawText(
                        WellVisitPDFGenerator.L("well_report.error.patient_not_found", "❌ Error: Patient not found"),
                        font: subFont
                    )
                    return
                }

                let name = "\(patientRow[firstName]) \(patientRow[lastName])"

                // Localized placeholder
                let placeholderDash = WellVisitPDFGenerator.L("well_report.placeholder.dash", "—")

                // Localize stored enum tokens safely (graceful fallback for unsafe tokens like poop_status=xyz)
                func localizeEnumToken(prefix: String, token: String, unknownFallback: String? = nil) -> String {
                    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return trimmed }

                    // Only allow keys made of letters/numbers/underscore to avoid bad NSLocalizedString keys
                    let isKeySafe = trimmed.allSatisfy { ch in
                        ch.isLetter || ch.isNumber || ch == "_"
                    }

                    // If the stored value is not a safe enum token (e.g. contains '='), do NOT print it in the PDF.
                    guard isKeySafe else {
                        return unknownFallback ?? placeholderDash
                    }

                    // If localized string is missing, fall back to the raw safe token by default.
                    let localized = WellVisitPDFGenerator.L("\(prefix).\(trimmed)", "")
                    if localized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return unknownFallback ?? trimmed
                    }
                    return localized
                }

                let aliasText = patientRow[alias] ?? placeholderDash
                let dobText = patientRow[dob]
                let sexText = patientRow[sex]
                let mrnText = patientRow[mrn]
                WellVisitPDFGenerator.log.debug("Patient alias=\(aliasText, privacy: .public) name=\(name, privacy: .public) dob=\(dobText, privacy: .public) sex=\(sexText, privacy: .public)")

                let visitDate = visitRow[Expression<String>("visit_date")]
                let visitType = visitRow[Expression<String>("visit_type")]
                let ageDaysDB = visitRow[Expression<Int?>("age_days")]

                // Localized patient/visit header labels
                let hdrAlias = WellVisitPDFGenerator.L("pdf.well.patient.alias", "Alias")
                let hdrName = WellVisitPDFGenerator.L("pdf.well.patient.name", "Name")
                let hdrDOB = WellVisitPDFGenerator.L("pdf.well.patient.dob", "DOB")
                let hdrSex = WellVisitPDFGenerator.L("pdf.well.patient.sex", "Sex")
                let hdrMRN = WellVisitPDFGenerator.L("pdf.well.patient.mrn", "MRN")
                let hdrAgeAtVisit = WellVisitPDFGenerator.L("pdf.well.patient.ageAtVisit", "Age at Visit")
                let hdrVisitDate = WellVisitPDFGenerator.L("pdf.well.patient.visitDate", "Visit Date")
                let hdrVisitType = WellVisitPDFGenerator.L("pdf.well.patient.visitType", "Visit Type")
                let unitDays = WellVisitPDFGenerator.L("well_report.unit.days", "days")

                drawText("\(hdrAlias): \(aliasText)", font: subFont)
                drawText("\(hdrName): \(name)", font: subFont)
                drawText("\(hdrDOB): \(dobText)", font: subFont)
                let sexPretty = localizeEnumToken(prefix: "well_report.enum.sex", token: sexText, unknownFallback: placeholderDash)
                drawText("\(hdrSex): \(sexPretty)", font: subFont)
                drawText("\(hdrMRN): \(mrnText)", font: subFont)

                if let ageString = formatAgeString(dobString: dobText, visitDateString: visitDate, ageDays: ageDaysDB) {
                    drawText("\(hdrAgeAtVisit): \(ageString)", font: subFont)
                } else if let ageDays = ageDaysDB, ageDays > 0 {
                    // Fallback: if age_days is somehow populated, at least show it
                    drawText("\(hdrAgeAtVisit): \(ageDays) \(unitDays)", font: subFont)
                } else {
                    drawText("\(hdrAgeAtVisit): \(placeholderDash)", font: subFont)
                }

                drawText("\(hdrVisitDate): \(WellVisitPDFGenerator.formatDate(visitDate))", font: subFont)
                let visitTypeTrimmed = visitType.trimmingCharacters(in: .whitespacesAndNewlines)
                let visitTypeReadable = visitTypeTrimmed.isEmpty
                    ? defaultWellVisitTitle
                    : (visitMap[visitTypeTrimmed] ?? visitTypeTrimmed)
                drawText("\(hdrVisitType): \(visitTypeReadable)", font: subFont)
                // Localized section titles
                let secPerinatalSummary = WellVisitPDFGenerator.L("well_report.section.perinatal_summary", "Perinatal Summary")
                let secPreviousWellVisits = WellVisitPDFGenerator.L("well_report.section.previous_well_visits", "Findings from Previous Well Visits")
                let secCurrentVisit = WellVisitPDFGenerator.L("well_report.section.current_visit", "Current Visit")
                let secParentsConcerns = WellVisitPDFGenerator.L("well_report.section.parents_concerns", "Parents' Concerns")
                let secFeeding = WellVisitPDFGenerator.L("well_report.section.feeding", "Feeding")
                let secSupplementation = WellVisitPDFGenerator.L("well_report.section.supplementation", "Supplementation")
                let secStools = WellVisitPDFGenerator.L("well_report.section.stools", "Stools")
                let secSleep = WellVisitPDFGenerator.L("well_report.section.sleep", "Sleep")
                let secDevelopmentMilestones = WellVisitPDFGenerator.L("well_report.section.development_milestones", "Development & Milestones")
                let secMeasurements = WellVisitPDFGenerator.L("well_report.section.measurements", "Measurements")
                let secPhysicalExamination = WellVisitPDFGenerator.L("well_report.section.physical_examination", "Physical Examination")
                let secProblemListing = WellVisitPDFGenerator.L("well_report.section.problem_listing", "Problem Listing")
                let secConclusions = WellVisitPDFGenerator.L("well_report.section.conclusions", "Conclusions")
                let secAnticipatoryGuidance = WellVisitPDFGenerator.L("well_report.section.anticipatory_guidance", "Anticipatory Guidance")
                let secAddenda = WellVisitPDFGenerator.L("well_report.section.addenda", "Addenda")

                let users = Table("users")
                let userID = Expression<Int64?>("user_id")
                let firstNameUser = Expression<String>("first_name")
                let lastNameUser = Expression<String>("last_name")

                // user_id may be NULL in the DB; handle that safely
                if let userIdVal = visitRow[userID] {
                    if let userRow = try? db.pluck(users.filter(Expression<Int64>("id") == userIdVal)) {
                        let clinicianName = "\(userRow[firstNameUser]) \(userRow[lastNameUser])"
                        let hdrClinician = WellVisitPDFGenerator.L("pdf.well.patient.clinician", "Clinician")
                        drawText("\(hdrClinician): \(clinicianName)", font: subFont)
                    }
                } else {
                    // Optionally, you could show something here:
                    // let hdrClinician = WellVisitPDFGenerator.L("pdf.well.patient.clinician", "Clinician")
                    // drawText("\(hdrClinician): —", font: subFont)
                }
                
                // MARK: - Perinatal Summary
                y += 12
                drawSectionTitle(secPerinatalSummary, font: UIFont.boldSystemFont(ofSize: 16))

                let perinatal = Table("perinatal_history")
                let pregnancyRisk = Expression<String?>("pregnancy_risk")
                let birthMode = Expression<String?>("birth_mode")
                let term = Expression<Int?>("birth_term_weeks")
                let resuscitation = Expression<String?>("resuscitation")
                let infectionRisk = Expression<String?>("infection_risk")
                let birthWeight = Expression<Int?>("birth_weight_g")
                let birthLength = Expression<Double?>("birth_length_cm")
                let headCirc = Expression<Double?>("birth_head_circumference_cm")
                let dischargeWeight = Expression<Int?>("discharge_weight_g")
                let feeding = Expression<String?>("feeding_in_maternity")
                let vaccinations = Expression<String?>("maternity_vaccinations")
                let events = Expression<String?>("maternity_stay_events")
                let hearing = Expression<String?>("hearing_screening")
                let heart = Expression<String?>("heart_screening")
                let metabolic = Expression<String?>("metabolic_screening")
                let afterBirth = Expression<String?>("illnesses_after_birth")
                let motherVacc = Expression<String?>("mother_vaccinations")
                let vitK = Expression<Int?>("vit_k")
                let passedMeconium24h = Expression<Int?>("passed_meconium_24h")
                let urination24h = Expression<Int?>("urination_24h")
                let nicuStay = Expression<Int?>("nicu_stay")
                let maternityDischargeDate = Expression<String?>("maternity_discharge_date")
                let familyVacc = Expression<String?>("family_vaccinations")

                // Localized content labels (Perinatal Summary)
                let periLblPregnancy = WellVisitPDFGenerator.L("well_report.perinatal.label.pregnancy", "Pregnancy")
                let periLblBirthMode = WellVisitPDFGenerator.L("well_report.perinatal.label.birth_mode", "Birth Mode")
                let periLblResuscitation = WellVisitPDFGenerator.L("well_report.perinatal.label.resuscitation", "Resuscitation")
                let periLblInfectionRisk = WellVisitPDFGenerator.L("well_report.perinatal.label.infection_risk", "Infection Risk")
                let periLblFeedingInMaternity = WellVisitPDFGenerator.L("well_report.perinatal.label.feeding_in_maternity", "Feeding")
                let periLblMaternityVaccinations = WellVisitPDFGenerator.L("well_report.perinatal.label.maternity_vaccinations", "Vaccinations")
                let periLblMaternityStayEvents = WellVisitPDFGenerator.L("well_report.perinatal.label.maternity_stay_events", "Events")
                let periLblHearingScreening = WellVisitPDFGenerator.L("well_report.perinatal.label.hearing_screening", "Hearing")
                let periLblHeartScreening = WellVisitPDFGenerator.L("well_report.perinatal.label.heart_screening", "Heart")
                let periLblMetabolicScreening = WellVisitPDFGenerator.L("well_report.perinatal.label.metabolic_screening", "Metabolic")
                let periLblIllnessesAfterBirth = WellVisitPDFGenerator.L("well_report.perinatal.label.illnesses_after_birth", "After birth")
                let periLblMotherVaccinations = WellVisitPDFGenerator.L("well_report.perinatal.label.mother_vaccinations", "Mother Vacc")

                let valYes = WellVisitPDFGenerator.L("well_report.value.yes", "Yes")
                let valNo  = WellVisitPDFGenerator.L("well_report.value.no", "No")

                let periFmtVitaminK = WellVisitPDFGenerator.L("well_report.perinatal.fmt.vitamin_k", "Vitamin K: %@")
                let periFmtMeconium24h = WellVisitPDFGenerator.L("well_report.perinatal.fmt.meconium_24h", "Meconium 24h: %@")
                let periFmtUrination24h = WellVisitPDFGenerator.L("well_report.perinatal.fmt.urination_24h", "Urination 24h: %@")
                let periFmtNICUStay = WellVisitPDFGenerator.L("well_report.perinatal.fmt.nicu_stay", "NICU stay: %@")
                let periFmtMaternityDischargeDate = WellVisitPDFGenerator.L("well_report.perinatal.fmt.maternity_discharge_date", "Discharge date: %@")
                let periFmtFamilyVaccinations = WellVisitPDFGenerator.L("well_report.perinatal.fmt.family_vaccinations", "Family vaccinations: %@")

                // Localized formatted fields (Perinatal Summary)
                let periFmtGAWeeks = WellVisitPDFGenerator.L("well_report.perinatal.fmt.ga_weeks", "GA: %d w")
                let periFmtBirthWeightG = WellVisitPDFGenerator.L("well_report.perinatal.fmt.birth_weight_g", "BW: %d g")
                let periFmtBirthLengthCM = WellVisitPDFGenerator.L("well_report.perinatal.fmt.birth_length_cm", "BL: %.1f cm")
                let periFmtBirthHeadCircCM = WellVisitPDFGenerator.L("well_report.perinatal.fmt.birth_head_circumference_cm", "HC: %.1f cm")
                let periFmtDischargeWeightG = WellVisitPDFGenerator.L("well_report.perinatal.fmt.discharge_weight_g", "Discharge Wt: %d g")

                if let peri = try? db.pluck(perinatal.filter(Expression<Int64>("patient_id") == pid)) {
                    var parts: [String] = []

                    func localizeVaccinationTokenList(_ raw: String) -> String {
                        let tokens = raw
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                            .filter { !$0.isEmpty }

                        guard !tokens.isEmpty else { return "" }

                        // If there are specific vaccines listed, drop "none".
                        let hasReal = tokens.contains { $0 != "none" }
                        let normalized = hasReal ? tokens.filter { $0 != "none" } : tokens

                        func loc(_ t: String) -> String {
                            let token = t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                            guard !token.isEmpty else { return "" }

                            let key = "well_report.enum.vaccination.\(token)"

                            // If the key is missing, NSLocalizedString typically returns the key itself.
                            // So we pass the key as the fallback and compare.
                            let localized = WellVisitPDFGenerator.L(key, key)
                            if localized == key {
                                return token
                            }
                            return localized
                        }

                        return normalized.map(loc).joined(separator: ", ")
                    }

                    if let v = try? peri.get(pregnancyRisk) {
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { parts.append("\(periLblPregnancy): \(t)") }
                    }

                    if let v = try? peri.get(birthMode) {
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { parts.append("\(periLblBirthMode): \(t)") }
                    }

                    if let ga = ((try? peri.get(term)) ?? nil) {
                        parts.append(String(format: periFmtGAWeeks, ga))
                    }

                    if let v = try? peri.get(resuscitation) {
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { parts.append("\(periLblResuscitation): \(t)") }
                    }

                    if let v = try? peri.get(infectionRisk) {
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { parts.append("\(periLblInfectionRisk): \(t)") }
                    }

                    if let bw = ((try? peri.get(birthWeight)) ?? nil) {
                        parts.append(String(format: periFmtBirthWeightG, bw))
                    }

                    if let bl = ((try? peri.get(birthLength)) ?? nil) {
                        parts.append(String(format: periFmtBirthLengthCM, bl))
                    }

                    if let hc = ((try? peri.get(headCirc)) ?? nil) {
                        parts.append(String(format: periFmtBirthHeadCircCM, hc))
                    }

                    if let dw = ((try? peri.get(dischargeWeight)) ?? nil) {
                        parts.append(String(format: periFmtDischargeWeightG, dw))
                    }
                    if let v = try? peri.get(maternityDischargeDate) {
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { parts.append(String(format: periFmtMaternityDischargeDate, WellVisitPDFGenerator.formatDate(t))) }
                    }

                    if let v = try? peri.get(feeding) {
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { parts.append("\(periLblFeedingInMaternity): \(t)") }
                    }
                    if let v = ((try? peri.get(vitK)) ?? nil) {
                        let text = (v == 1) ? valYes : valNo
                        parts.append(String(format: periFmtVitaminK, text))
                    }

                    if let v = ((try? peri.get(passedMeconium24h)) ?? nil) {
                        let text = (v == 1) ? valYes : valNo
                        parts.append(String(format: periFmtMeconium24h, text))
                    }

                    if let v = ((try? peri.get(urination24h)) ?? nil) {
                        let text = (v == 1) ? valYes : valNo
                        parts.append(String(format: periFmtUrination24h, text))
                    }

                    if let v = ((try? peri.get(nicuStay)) ?? nil) {
                        let text = (v == 1) ? valYes : valNo
                        parts.append(String(format: periFmtNICUStay, text))
                    }

                    if let v = try? peri.get(vaccinations) {
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { parts.append("\(periLblMaternityVaccinations): \(t)") }
                    }

                    if let v = try? peri.get(events) {
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { parts.append("\(periLblMaternityStayEvents): \(t)") }
                    }

                    if let v = try? peri.get(hearing) {
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { parts.append("\(periLblHearingScreening): \(t)") }
                    }

                    if let v = try? peri.get(heart) {
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { parts.append("\(periLblHeartScreening): \(t)") }
                    }

                    if let v = try? peri.get(metabolic) {
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { parts.append("\(periLblMetabolicScreening): \(t)") }
                    }

                    if let v = try? peri.get(afterBirth) {
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { parts.append("\(periLblIllnessesAfterBirth): \(t)") }
                    }

                    if let v = try? peri.get(motherVacc) {
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        let pretty = t.isEmpty ? "" : localizeVaccinationTokenList(t)
                        if !pretty.isEmpty { parts.append("\(periLblMotherVaccinations): \(pretty)") }
                    }
                    if let v = try? peri.get(familyVacc) {
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        let pretty = t.isEmpty ? "" : localizeVaccinationTokenList(t)
                        if !pretty.isEmpty { parts.append(String(format: periFmtFamilyVaccinations, pretty)) }
                    }

                    if !parts.isEmpty {
                        let summary = parts.joined(separator: "; ")
                        drawWrappedText(summary, font: subFont, in: pageRect, at: &y, using: context)
                    } else {
                        drawText(placeholderDash, font: subFont)
                    }
                } else {
                    drawText(placeholderDash, font: subFont)
                }

                // MARK: - Findings from Previous Well Visits
                y += 12
                drawSectionTitle(secPreviousWellVisits, font: UIFont.boldSystemFont(ofSize: 16))

                let allVisits = Table("well_visits")
                let problemListing = Expression<String?>("problem_listing")
                let visitDateCol = Expression<String>("visit_date")
                let visitTypeCol = Expression<String>("visit_type")
                let visitCreatedAt = Expression<String>("created_at")


                let previousVisits = try db.prepare(
                    allVisits
                        .filter(patientID == pid && visitID != visit.id && visitDateCol < visitDate)
                        .order(visitDateCol.asc)
                )

                let prevVisitHeaderFont = UIFont.boldSystemFont(ofSize: 14)

                for v in previousVisits {
                    let vTypeRaw = v[visitTypeCol]
                    let vType = vTypeRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    let vTitle = vType.isEmpty ? defaultWellVisitTitle : (visitMap[vType] ?? defaultWellVisitTitle)

                    if vType.isEmpty || visitMap[vType] == nil {
                        WellVisitPDFGenerator.log.warning("Previous well visit has unmapped/empty visit_type='\(vTypeRaw, privacy: .public)'")
                    }
                    let vDate = v[visitDateCol]
                    let createdAt = v[visitCreatedAt]
                    let displayDate = vDate.isEmpty ? createdAt : vDate
                    let formattedDate = WellVisitPDFGenerator.formatDate(displayDate)
                    let findings = v[problemListing]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    drawText("\(vTitle) — \(formattedDate)", font: prevVisitHeaderFont)

                    func stripLeadingListMarker(_ raw: String) -> String {
                        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Normalize common list prefixes so we don't end up with "• - ..." or "- - ..."
                        let prefixes = ["• -", "•-", "- ", "– ", "— ", "• ", "· "]
                        for p in prefixes {
                            if s.hasPrefix(p) {
                                s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                                break
                            }
                        }
                        if s.hasPrefix("•") {
                            s = String(s.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        return s
                    }

                    if !findings.isEmpty {
                        let lines = findings
                            .components(separatedBy: .newlines)
                            .map { stripLeadingListMarker($0) }
                            .filter { !$0.isEmpty }

                        if lines.count <= 1 {
                            // Single line: keep as-is (no forced semicolons)
                            drawWrappedText(lines.first ?? findings, font: subFont, in: pageRect, at: &y, using: context)
                        } else {
                            // Multi-line: render as a clean bullet list (no extra dashes)
                            for line in lines {
                                ensureSpace(for: 16)
                                drawWrappedText("• \(line)", font: subFont, in: pageRect, at: &y, using: context)
                                y += 2
                            }
                        }
                    } else {
                        drawText(placeholderDash, font: subFont)
                    }

                    y += 6
                }

                // MARK: - Current Visit Section
                y += 12
                ensureSpace(for: 20)
                drawSectionTitle(secCurrentVisit, font: UIFont.boldSystemFont(ofSize: 16))

                let visitTypeRaw = visitRow[Expression<String>("visit_type")]
                let visitTypeKeyCurrent = visitTypeRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                let visitTypeReadableCurrent = visitTypeKeyCurrent.isEmpty
                    ? defaultWellVisitTitle
                    : (visitMap[visitTypeKeyCurrent] ?? defaultWellVisitTitle)
                ensureSpace(for: 16)
                drawText(visitTypeReadableCurrent, font: UIFont.italicSystemFont(ofSize: 14))

                // Parents' Concerns
                y += 12
                ensureSpace(for: 18)
                drawText(secParentsConcerns, font: UIFont.boldSystemFont(ofSize: 15))
                let parentsConcerns = visitRow[Expression<String?>("parent_concerns")] ?? ""
                if !parentsConcerns.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    drawWrappedText(parentsConcerns, font: subFont, in: pageRect, at: &y, using: context)
                } else {
                    drawText(placeholderDash, font: subFont)
                }

                // MARK: - Feeding Section
                y += 12
                ensureSpace(for: 18)
                drawText(secFeeding, font: UIFont.boldSystemFont(ofSize: 15))

                var feedingLines: [String] = []

                // Reuse valYes/valNo localized above

                let lblMilk = WellVisitPDFGenerator.L("well_report.feeding.label.milk", "Milk")
                let lblRegurgitation = WellVisitPDFGenerator.L("well_report.feeding.label.regurgitation", "Regurgitation")
                let lblFeedingIssue = WellVisitPDFGenerator.L("well_report.feeding.label.feeding_issue", "Feeding issue")
                let lblSolidFoodsStarted = WellVisitPDFGenerator.L("well_report.feeding.label.solid_foods_started", "Solid foods started")
                let lblSolidFoodsSince = WellVisitPDFGenerator.L("well_report.feeding.label.solid_foods_since", "Solid foods since")
                let lblSolidFoodQuality = WellVisitPDFGenerator.L("well_report.feeding.label.solid_food_quality", "Solid food quality")
                let lblSolidFoodComment = WellVisitPDFGenerator.L("well_report.feeding.label.solid_food_comment", "Solid food comment")
                let lblFoodVarietyQuantity = WellVisitPDFGenerator.L("well_report.feeding.label.food_variety_quantity", "Food variety / quantity")
                let lblDairyIntakeDaily = WellVisitPDFGenerator.L("well_report.feeding.label.dairy_intake_daily", "Dairy intake daily")
                let lblComment = WellVisitPDFGenerator.L("well_report.label.comment", "Comment")


                let fmtTypicalFeedVolume = WellVisitPDFGenerator.L("well_report.feeding.fmt.typical_feed_volume_ml", "Typical feed volume: %.0f ml")
                let fmtFeedsPer24h = WellVisitPDFGenerator.L("well_report.feeding.fmt.feeds_per_24h", "Feeds per 24h: %d times")
                let fmtEstimatedTotalIntake = WellVisitPDFGenerator.L("well_report.feeding.fmt.estimated_total_intake_ml_per_24h", "Estimated total intake: %.0f ml/24h")
                let fmtEstimatedIntakePerKg = WellVisitPDFGenerator.L("well_report.feeding.fmt.estimated_intake_ml_per_kg_24h", "Estimated intake: %.0f ml/kg/24h")
                let fmtDairyCupsOrBottles = WellVisitPDFGenerator.L("well_report.feeding.fmt.dairy_cups_or_bottles", "Dairy intake daily: %@ cup(s) or bottle(s)")


                // milk_types TEXT (stored enum(s): e.g. "breast", "formula" or "breast,formula")
                if let milkTypesRaw = visitRow[Expression<String?>("milk_types")] {
                    let raw = milkTypesRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !raw.isEmpty {
                        let tokens = raw
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }

                        func locMilkType(_ token: String) -> String {
                            // If unknown / legacy value, fall back to the raw token
                            WellVisitPDFGenerator.L("well_report.enum.milk_types.\(token)", token)
                        }

                        let pretty = tokens.isEmpty ? raw : tokens.map(locMilkType).joined(separator: ", ")
                        feedingLines.append("\(lblMilk): \(pretty)")
                    }
                }

                // feed_volume_ml REAL
                if let volume = visitRow[Expression<Double?>("feed_volume_ml")] {
                    feedingLines.append(String(format: fmtTypicalFeedVolume, volume))
                }

                // feed_freq_per_24h INTEGER
                if let freq = visitRow[Expression<Int?>("feed_freq_per_24h")] {
                    feedingLines.append(String(format: fmtFeedsPer24h, freq))
                }

                // est_total_ml REAL
                if let total = visitRow[Expression<Double?>("est_total_ml")] {
                    feedingLines.append(String(format: fmtEstimatedTotalIntake, total))
                }

                // est_ml_per_kg_24h REAL
                if let perKg = visitRow[Expression<Double?>("est_ml_per_kg_24h")] {
                    feedingLines.append(String(format: fmtEstimatedIntakePerKg, perKg))
                }

                // regurgitation INTEGER (boolean)
                if let reg = visitRow[Expression<Int?>("regurgitation")] {
                    // Only meaningful to report regurgitation in early infancy.
                    let ageDaysValue = visitRow[Expression<Int?>("age_days")]
                    if let ageMonths = computeAgeMonths(dobString: dobText,
                                                        visitDateString: visitDate,
                                                        ageDays: ageDaysValue),
                       ageMonths <= 4.0 {
                        let text = (reg == 1) ? valYes : valNo
                        feedingLines.append("\(lblRegurgitation): \(text)")
                    }
                }

                // feeding_issue TEXT
                if let issueRaw = visitRow[Expression<String?>("feeding_issue")] {
                    let issue = issueRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !issue.isEmpty {
                        feedingLines.append("\(lblFeedingIssue): \(issue)")
                    }
                }

                // solid_food_started INTEGER DEFAULT 0 (boolean)
                if let solidStarted = visitRow[Expression<Int?>("solid_food_started")] {
                    // Only meaningful to show this between about 4 and 9 months.
                    let ageDaysValue = visitRow[Expression<Int?>("age_days")]
                    if let ageMonths = computeAgeMonths(dobString: dobText,
                                                        visitDateString: visitDate,
                                                        ageDays: ageDaysValue),
                       ageMonths >= 4.0 && ageMonths <= 9.0 {
                        let text = (solidStarted == 1) ? valYes : valNo
                        feedingLines.append("\(lblSolidFoodsStarted): \(text)")
                    }
                }

                // solid_food_start_date TEXT
                if let solidDateRaw = visitRow[Expression<String?>("solid_food_start_date")] {
                    let solidDate = solidDateRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !solidDate.isEmpty {
                        feedingLines.append("\(lblSolidFoodsSince): \(WellVisitPDFGenerator.formatDate(solidDate))")
                    }
                }

                // solid_food_quality TEXT
                if let solidQualityRaw = visitRow[Expression<String?>("solid_food_quality")] {
                    let solidQuality = solidQualityRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !solidQuality.isEmpty {
                        let prettyQuality = localizeEnumToken(prefix: "well_report.enum.solid_food_quality", token: solidQuality)
                        feedingLines.append("\(lblSolidFoodQuality): \(prettyQuality)")
                    }
                }

                // solid_food_comment TEXT
                if let solidCommentRaw = visitRow[Expression<String?>("solid_food_comment")] {
                    let solidComment = solidCommentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !solidComment.isEmpty {
                        feedingLines.append("\(lblSolidFoodComment): \(solidComment)")
                    }
                }

                // food_variety_quality TEXT
                if let varietyRaw = visitRow[Expression<String?>("food_variety_quality")] {
                    let variety = varietyRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !variety.isEmpty {
                        let prettyVariety = localizeEnumToken(prefix: "well_report.enum.food_variety_quality", token: variety)
                        feedingLines.append("\(lblFoodVarietyQuantity): \(prettyVariety)")
                    }
                }

                // dairy_amount_text TEXT
                if let dairyRaw = visitRow[Expression<String?>("dairy_amount_text")] {
                    let dairy = dairyRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !dairy.isEmpty {
                        feedingLines.append(String(format: fmtDairyCupsOrBottles, dairy))
                    }
                }

                // feeding_comment TEXT
                if let commentRaw = visitRow[Expression<String?>("feeding_comment")] {
                    let comment = commentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !comment.isEmpty {
                        feedingLines.append("\(lblComment): \(comment)")
                    }
                }

                if feedingLines.isEmpty {
                    drawText(placeholderDash, font: UIFont.italicSystemFont(ofSize: 14))
                } else {
                    for line in feedingLines {
                        ensureSpace(for: 16)
                        drawWrappedText(line, font: subFont, in: pageRect, at: &y, using: context)
                        y += 2
                    }
                }

                // Supplementation Section
                y += 12
                ensureSpace(for: 18)
                drawText(secSupplementation, font: UIFont.boldSystemFont(ofSize: 15))

                let fmtVitaminDGiven = WellVisitPDFGenerator.L(
                    "well_report.supplementation.vitamin_d_given_fmt",
                    "Vitamin D given: %@"
                )

                let vitaminDGiven = visitRow[Expression<Int?>("vitamin_d_given")]
                if let val = vitaminDGiven {
                    if val == 1 {
                        drawText(String(format: fmtVitaminDGiven, valYes), font: UIFont.italicSystemFont(ofSize: 14))
                    } else if val == 0 {
                        drawText(String(format: fmtVitaminDGiven, valNo), font: UIFont.italicSystemFont(ofSize: 14))
                    }
                    // If other values are stored, we silently ignore them for now.
                } else {
                    // No supplementation info recorded for this visit; omit the line.
                }

                // MARK: - Stools
                y += 12
                ensureSpace(for: 18)
                drawText(secStools, font: UIFont.boldSystemFont(ofSize: 15))

                let poopStatusExp = Expression<String?>("poop_status")
                let poopCommentExp = Expression<String?>("poop_comment")

                let fmtStoolPattern = WellVisitPDFGenerator.L("well_report.stools.pattern_fmt", "Stool pattern: %@")
                let fmtStoolComment = WellVisitPDFGenerator.L("well_report.stools.comment_fmt", "Comment: %@")

                var stoolLines: [String] = []

                if let statusRaw = visitRow[poopStatusExp] {
                    let status = statusRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !status.isEmpty {
                        let prettyStatus = localizeEnumToken(prefix: "well_report.enum.poop_status", token: status)
                        stoolLines.append(String(format: fmtStoolPattern, prettyStatus))
                    }
                }

                if let commentRaw = visitRow[poopCommentExp] {
                    let comment = commentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !comment.isEmpty {
                        stoolLines.append(String(format: fmtStoolComment, comment))
                    }
                }

                if stoolLines.isEmpty {
                    drawText(placeholderDash, font: UIFont.italicSystemFont(ofSize: 14))
                } else {
                    for line in stoolLines {
                        ensureSpace(for: 16)
                        drawWrappedText(line, font: subFont, in: pageRect, at: &y, using: context)
                        y += 2
                    }
                }

                // Helper to prettify sleep duration string (e.g. "10_15" -> "10 to 15 hours", "<_10" -> "less than 10 hours")
                func prettySleepDuration(_ raw: String) -> String {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return trimmed }

                    // 1) Special tokens like "<_10" or ">_15"
                    // DB uses values like "<_10" for "less than 10 hours".
                    if trimmed.hasPrefix("<_") || trimmed.hasPrefix(">_") {
                        let isLess = trimmed.hasPrefix("<_")
                        let numberPart = trimmed.dropFirst(2) // remove "<_" or ">_"
                        if let hours = Int(numberPart) {
                            if isLess {
                                let fmtLessThanHours = WellVisitPDFGenerator.L(
                                    "well_report.sleep.fmt.less_than_hours",
                                    "less than %d hours"
                                )
                                return String(format: fmtLessThanHours, hours)
                            } else {
                                let fmtMoreThanHours = WellVisitPDFGenerator.L(
                                    "well_report.sleep.fmt.more_than_hours",
                                    "more than %d hours"
                                )
                                return String(format: fmtMoreThanHours, hours)
                            }
                        }
                        // If parsing fails, fall back to raw token.
                        return trimmed
                    }

                    // 2) Range tokens like "10_15" -> "10 to 15 hours"
                    let parts = trimmed.split(separator: "_", omittingEmptySubsequences: true)
                    if parts.count == 2 {
                        let first = parts[0]
                        let second = parts[1]
                        if !first.isEmpty && !second.isEmpty {
                            let fmtRangeHours = WellVisitPDFGenerator.L(
                                "well_report.sleep.fmt.range_hours",
                                "%@ to %@ hours"
                            )
                            return String(format: fmtRangeHours, String(first), String(second))
                        }
                    }

                    // 3) Unknown token; return as-is
                    return trimmed
                }

                // MARK: - Sleep Section
                y += 12
                ensureSpace(for: 18)
                drawText(secSleep, font: UIFont.boldSystemFont(ofSize: 15))

                var sleepLines: [String] = []

                let fmtSleepDuration = WellVisitPDFGenerator.L("well_report.sleep.duration_fmt", "Sleep duration: %@")
                let fmtSleepRegularity = WellVisitPDFGenerator.L("well_report.sleep.regularity_fmt", "Sleep regularity: %@")
                let fmtSleepSnoring = WellVisitPDFGenerator.L("well_report.sleep.snoring_fmt", "Snoring: %@")

                let sleepIssueYes = WellVisitPDFGenerator.L("well_report.sleep.issue_reported_yes", "Sleep issue reported: Yes")
                let sleepIssueNo = WellVisitPDFGenerator.L("well_report.sleep.issue_reported_no", "Sleep issue reported: No")
                let fmtSleepIssueYesDetail = WellVisitPDFGenerator.L("well_report.sleep.issue_reported_yes_detail_fmt", "Sleep issue reported: Yes – %@")

                // 1. Sleep duration (pretty-printed, e.g. "10_15" -> "10 to 15 hours")
                if let durationRaw = visitRow[Expression<String?>("sleep_hours_text")] {
                    let durationTrimmed = durationRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !durationTrimmed.isEmpty {
                        let pretty = prettySleepDuration(durationTrimmed)
                        sleepLines.append(String(format: fmtSleepDuration, pretty))
                    }
                }

                // 2. Sleep regularity (stored enum token)
                if let regularRaw = visitRow[Expression<String?>("sleep_regular")] {
                    let regular = regularRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !regular.isEmpty {
                        let pretty = localizeEnumToken(prefix: "well_report.enum.sleep_regular", token: regular)
                        sleepLines.append(String(format: fmtSleepRegularity, pretty))
                    }
                }

                // 3. Snoring (boolean, only meaningful from ~12 months onward)
                do {
                    let ageDaysValue = try visitRow.get(Expression<Int?>("age_days"))
                    if let ageMonths = computeAgeMonths(dobString: dobText,
                                                        visitDateString: visitDate,
                                                        ageDays: ageDaysValue),
                       ageMonths >= 12.0,
                       let snoreVal = visitRow[Expression<Int?>("sleep_snoring")] {
                        let text = (snoreVal == 1) ? valYes : valNo
                        sleepLines.append(String(format: fmtSleepSnoring, text))
                    }
                } catch {
                    // If age_days is missing for some reason, we silently skip the Snoring line.
                    WellVisitPDFGenerator.log.warning("Sleep section: unable to read age_days for snoring gating: \(error.localizedDescription, privacy: .public)")
                }

                // 4. Sleep issue reported (explicit Yes/No, plus text if Yes)
                let issueReportedVal = visitRow[Expression<Int?>("sleep_issue_reported")] ?? 0
                let issueTextRaw = visitRow[Expression<String?>("sleep_issue_text")] ?? ""
                let issueText = issueTextRaw.trimmingCharacters(in: .whitespacesAndNewlines)

                func prettySleepIssueText(_ raw: String) -> String {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return trimmed }

                    // Known structured token: wakes_per_night=<int>
                    // Some bundles store extra free text after the number, e.g. "wakes_per_night=1\nse reveille.".
                    // Parse only the leading integer and keep any remaining text.
                    if trimmed.hasPrefix("wakes_per_night=") {
                        let tail = trimmed.replacingOccurrences(of: "wakes_per_night=", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        // Extract leading digits only (stop at first non-digit).
                        var digits = ""
                        var remainderStartIdx = tail.startIndex
                        for ch in tail {
                            if ch.isNumber {
                                digits.append(ch)
                                remainderStartIdx = tail.index(after: remainderStartIdx)
                            } else {
                                break
                            }
                        }

                        if let n = Int(digits) {
                            let fmtWakesPerNight = WellVisitPDFGenerator.L(
                                "well_report.sleep.issue.wakes_per_night_fmt",
                                "Wakes per night: %d"
                            )

                            var out = String(format: fmtWakesPerNight, n)

                            let remainder = String(tail.replacingOccurrences(of: digits, with: "", options: [.anchored], range: tail.startIndex..<tail.endIndex))
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !remainder.isEmpty {
                                out += " — \(remainder)"
                            }

                            return out
                        }

                        // If parsing fails, fall back to raw token.
                        return trimmed
                    }

                    // For any other safe enum-like token, try localized enum mapping; fail-open to raw.
                    return localizeEnumToken(prefix: "well_report.enum.sleep_issue_text", token: trimmed)
                }

                if issueReportedVal == 1 {
                    if issueText.isEmpty {
                        sleepLines.append(sleepIssueYes)
                    } else {
                        let prettyIssue = prettySleepIssueText(issueText)
                        sleepLines.append(String(format: fmtSleepIssueYesDetail, prettyIssue))
                    }
                } else {
                    // Explicitly document absence of reported issues
                    sleepLines.append(sleepIssueNo)
                }

                if sleepLines.isEmpty {
                    drawText(placeholderDash, font: UIFont.italicSystemFont(ofSize: 14))
                } else {
                    for line in sleepLines {
                        ensureSpace(for: 16)
                        drawWrappedText(line, font: subFont, in: pageRect, at: &y, using: context)
                        y += 2
                    }
                }

                // MARK: - Development & Milestones
                y += 12
                ensureSpace(for: 18)
                drawText(secDevelopmentMilestones, font: UIFont.boldSystemFont(ofSize: 15))

                // Age in months for gating dev test and M-CHAT
                let ageDaysValueForDev = visitRow[Expression<Int?>("age_days")]
                let ageMonthsForDev = computeAgeMonths(
                    dobString: dobText,
                    visitDateString: visitDate,
                    ageDays: ageDaysValueForDev
                )

                // Developmental test strings
                let fmtDevResultScore = WellVisitPDFGenerator.L("well_report.development.devtest.result_score_fmt", "Developmental test: %@ (score %d)")
                let fmtDevScoreOnly = WellVisitPDFGenerator.L("well_report.development.devtest.score_only_fmt", "Developmental test score: %d")
                let fmtDevResultOnly = WellVisitPDFGenerator.L("well_report.development.devtest.result_only_fmt", "Developmental test: %@")

                // Developmental test (devtest_*), shown from 9 to 36 months
                let devTestScore = visitRow[Expression<Int?>("devtest_score")]
                let devResultRaw = visitRow[Expression<String?>("devtest_result")] ?? ""
                let devResultToken = devResultRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                let devResultPretty = devResultToken.isEmpty
                    ? ""
                    : localizeEnumToken(prefix: "well_report.enum.devtest_result", token: devResultToken)

                if let ageMonths = ageMonthsForDev,
                   ageMonths >= 9.0, ageMonths <= 36.0 {
                    if let score = devTestScore {
                        var devString: String
                        if !devResultPretty.isEmpty {
                            devString = String(format: fmtDevResultScore, devResultPretty, score)
                        } else {
                            devString = String(format: fmtDevScoreOnly, score)
                        }
                        ensureSpace(for: 16)
                        drawWrappedText(devString, font: subFont, in: pageRect, at: &y, using: context)
                    } else {
                        if !devResultPretty.isEmpty {
                            ensureSpace(for: 16)
                            drawWrappedText(String(format: fmtDevResultOnly, devResultPretty), font: subFont, in: pageRect, at: &y, using: context)
                        }
                    }
                }

                // M-CHAT strings
                let fmtMchatResultScore = WellVisitPDFGenerator.L("well_report.development.mchat.result_score_fmt", "M-CHAT: %@ (score %d)")
                let fmtMchatScoreOnly = WellVisitPDFGenerator.L("well_report.development.mchat.score_only_fmt", "M-CHAT score: %d")
                let fmtMchatResultOnly = WellVisitPDFGenerator.L("well_report.development.mchat.result_only_fmt", "M-CHAT: %@")

                // M-CHAT (mchat_*), shown from 18 to 30 months
                let mchatScore = visitRow[Expression<Int?>("mchat_score")]
                let mchatResultRaw = visitRow[Expression<String?>("mchat_result")] ?? ""
                let mchatResultToken = mchatResultRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                let mchatResultPretty = mchatResultToken.isEmpty
                    ? ""
                    : localizeEnumToken(prefix: "well_report.enum.mchat_result", token: mchatResultToken)

                if let ageMonths = ageMonthsForDev,
                   ageMonths >= 18.0, ageMonths <= 30.0 {
                    if let score = mchatScore {
                        var mchatLine: String
                        if !mchatResultPretty.isEmpty {
                            mchatLine = String(format: fmtMchatResultScore, mchatResultPretty, score)
                        } else {
                            mchatLine = String(format: fmtMchatScoreOnly, score)
                        }
                        ensureSpace(for: 16)
                        drawWrappedText(mchatLine, font: subFont, in: pageRect, at: &y, using: context)
                    } else {
                        if !mchatResultPretty.isEmpty {
                            ensureSpace(for: 16)
                            drawWrappedText(String(format: fmtMchatResultOnly, mchatResultPretty), font: subFont, in: pageRect, at: &y, using: context)
                        }
                    }
                }

                // Milestones summary (from well_visit_milestones)
                y += 12
                ensureSpace(for: 18)

                let fmtAchieved = WellVisitPDFGenerator.L("well_report.milestones.achieved_fmt", "Achieved: %d/%d")
                let achievedNone = WellVisitPDFGenerator.L("well_report.milestones.achieved_none", "Achieved: —")
                let flagsTitle = WellVisitPDFGenerator.L("well_report.milestones.flags_title", "Flags:")
                let fmtFlags = WellVisitPDFGenerator.L("well_report.milestones.flags_fmt", "Flags: %@")

                let statUncertain = WellVisitPDFGenerator.L("well_report.milestones.status.uncertain", "uncertain")
                let statNotYet = WellVisitPDFGenerator.L("well_report.milestones.status.not_yet", "not yet")

                let milestonesTable = Table("well_visit_milestones")
                _ = Expression<String>("code")
                let label = Expression<String>("label")
                let status = Expression<String?>("status")

                let milestoneRows = try? db.prepare(milestonesTable.filter(Expression<Int64>("visit_id") == visit.id))

                var achievedCount = 0
                var totalCount = 0
                var flags: [String] = []

                if let rows = milestoneRows {
                    // Normalize statuses aggressively so we don't silently miss flags due to
                    // whitespace / NBSP / legacy variants.
                    func normalizeStatus(_ raw: String) -> String {
                        // Replace NBSP with regular space, trim, collapse whitespace, lowercase.
                        let nbFixed = raw.replacingOccurrences(of: "\u{00A0}", with: " ")
                        let trimmed = nbFixed.trimmingCharacters(in: .whitespacesAndNewlines)
                        let collapsed = trimmed
                            .split(whereSeparator: { $0.isWhitespace })
                            .joined(separator: " ")
                        return collapsed.lowercased()
                    }

                    for row in rows {
                        let statRaw = row[status] ?? ""
                        let statNorm = normalizeStatus(statRaw)

                        totalCount += 1

                        // Anything not explicitly achieved is considered a flag.
                        if statNorm == "achieved" {
                            achievedCount += 1
                            continue
                        }

                        let itemLabel = row[label]
                        let statDisplay: String

                        switch statNorm {
                        case "uncertain":
                            statDisplay = statUncertain
                        case "not yet", "not_yet":
                            statDisplay = statNotYet
                        default:
                            // Fail-open: show the raw status if present; otherwise a dash.
                            let rawTrimmed = statRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                            statDisplay = rawTrimmed.isEmpty ? placeholderDash : rawTrimmed
                        }

                        flags.append("\(itemLabel): \(statDisplay)")
                    }
                }

                if totalCount > 0 {
                    drawText(String(format: fmtAchieved, achievedCount, totalCount), font: subFont)
                } else {
                    drawText(achievedNone, font: subFont)
                }

                if !flags.isEmpty {
                    drawText(flagsTitle, font: subFont)

                    func stripLeadingListMarker(_ raw: String) -> String {
                        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        let prefixes = ["• -", "•-", "- ", "– ", "— ", "• ", "· "]
                        for p in prefixes {
                            if s.hasPrefix(p) {
                                s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                                break
                            }
                        }
                        if s.hasPrefix("•") {
                            s = String(s.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        return s
                    }

                    for item in flags {
                        let cleaned = stripLeadingListMarker(item)
                        drawWrappedText("• \(cleaned)", font: subFont, in: pageRect, at: &y, using: context)
                    }
                } else {
                    drawText(String(format: fmtFlags, placeholderDash), font: subFont)
                }
                
                // MARK: - Measurements
                y += 12
                ensureSpace(for: 18)
                drawText(secMeasurements, font: UIFont.boldSystemFont(ofSize: 15))

                // Collect measurement lines; prefer manual_growth, fall back to legacy visit fields.
                var measurementLines: [String] = []
                // Localized measurement line formats
                let fmtWeightMeasuredOn = WellVisitPDFGenerator.L(
                    "well_report.measurements.line.weight_measured_on_fmt",
                    "Weight: %.2f kg (measured on %@)"
                )
                let fmtLengthMeasuredOn = WellVisitPDFGenerator.L(
                    "well_report.measurements.line.length_height_measured_on_fmt",
                    "Length/Height: %.1f cm (measured on %@)"
                )
                let fmtHeadCircMeasuredOn = WellVisitPDFGenerator.L(
                    "well_report.measurements.line.head_circ_measured_on_fmt",
                    "Head circumference: %.1f cm (measured on %@)"
                )
                let fmtTodayWeight = WellVisitPDFGenerator.L(
                    "well_report.measurements.line.weight_today_fmt",
                    "Today's weight: %.2f kg"
                )
                let fmtTodayLength = WellVisitPDFGenerator.L(
                    "well_report.measurements.line.length_today_fmt",
                    "Today's length: %.1f cm"
                )
                let fmtTodayHeadCirc = WellVisitPDFGenerator.L(
                    "well_report.measurements.line.head_circ_today_fmt",
                    "Today's head circumference: %.1f cm"
                )
                
                let fmtWeightGainSinceReference = WellVisitPDFGenerator.L(
                    "well_report.measurements.line.weight_gain_since_reference_fmt",
                    "Weight gain since reference: %.1f g/day (Δ %@%d g over %d days)"
                )
                let noReferenceWeightFound = WellVisitPDFGenerator.L(
                    "well_report.measurements.no_reference_weight_found",
                    "No reference weight found."
                )

                // 1. Try manual_growth (prefer measurements up to 24h after visit date)
                let manualGrowth = Table("manual_growth")
                let mgPatientID = Expression<Int64>("patient_id")
                let mgRecordedAt = Expression<String>("recorded_at")
                let mgWeight = Expression<Double?>("weight_kg")
                let mgHeight = Expression<Double?>("height_cm")
                let mgHeadCirc = Expression<Double?>("head_circumference_cm")

                // We prefer measurements recorded up to 24h after the visit date.
                var selectedMGRow: Row? = nil

                // Try to parse the visit date string into a Date
                var visitDateParsed: Date? = nil
                do {
                    let visitDateString = visitDate

                    let isoFormatter = ISO8601DateFormatter()
                    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    visitDateParsed = isoFormatter.date(from: visitDateString)

                    if visitDateParsed == nil {
                        isoFormatter.formatOptions = [.withInternetDateTime]
                        visitDateParsed = isoFormatter.date(from: visitDateString)
                    }

                    if visitDateParsed == nil {
                        let legacyFormatter = DateFormatter()
                        legacyFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
                        legacyFormatter.locale = Locale(identifier: "en_US_POSIX")
                        visitDateParsed = legacyFormatter.date(from: visitDateString)
                    }

                    if visitDateParsed == nil {
                        let dateOnlyFormatter = DateFormatter()
                        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
                        dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
                        visitDateParsed = dateOnlyFormatter.date(from: visitDateString)
                    }
                }

                // If we have a parsed visit date, filter manual_growth rows to those up to visitDate+24h
                if let visitDateDate = visitDateParsed {
                    let cutoffDate = visitDateDate.addingTimeInterval(24 * 60 * 60) // +24h
                    let rows = try? db.prepare(manualGrowth.filter(mgPatientID == pid))

                    if let rows = rows {
                        let isoFormatter = ISO8601DateFormatter()
                        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                        var latestDate: Date? = nil

                        for row in rows {
                            let recordedAtRaw = row[mgRecordedAt]

                            // Try ISO8601 with and without fractional seconds, then plain date-only format
                            var recDate: Date? = isoFormatter.date(from: recordedAtRaw)
                            if recDate == nil {
                                isoFormatter.formatOptions = [.withInternetDateTime]
                                recDate = isoFormatter.date(from: recordedAtRaw)
                            }
                            if recDate == nil {
                                let dateOnlyFormatter = DateFormatter()
                                dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
                                dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
                                recDate = dateOnlyFormatter.date(from: recordedAtRaw)
                            }

                            guard let recDateFinal = recDate else { continue }

                            if recDateFinal <= cutoffDate {
                                if let currentLatest = latestDate {
                                    if recDateFinal > currentLatest {
                                        latestDate = recDateFinal
                                        selectedMGRow = row
                                    }
                                } else {
                                    latestDate = recDateFinal
                                    selectedMGRow = row
                                }
                            }
                        }
                    }
                }

                if let mgRow = selectedMGRow {
                    let recordedAtRaw = mgRow[mgRecordedAt]
                    var recordedAtPretty = recordedAtRaw

                    // Try to pretty-print the recorded_at date if it is ISO8601 or plain date; otherwise keep raw string.
                    let isoFormatter = ISO8601DateFormatter()
                    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let date = isoFormatter.date(from: recordedAtRaw) {
                        let outFormatter = DateFormatter()
                        outFormatter.dateStyle = .medium
                        outFormatter.timeStyle = .none
                        recordedAtPretty = outFormatter.string(from: date)
                    } else {
                        isoFormatter.formatOptions = [.withInternetDateTime]
                        if let date = isoFormatter.date(from: recordedAtRaw) {
                            let outFormatter = DateFormatter()
                            outFormatter.dateStyle = .medium
                            outFormatter.timeStyle = .none
                            recordedAtPretty = outFormatter.string(from: date)
                        } else {
                            let dateOnlyFormatter = DateFormatter()
                            dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
                            dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
                            if let date = dateOnlyFormatter.date(from: recordedAtRaw) {
                                let outFormatter = DateFormatter()
                                outFormatter.dateStyle = .medium
                                outFormatter.timeStyle = .none
                                recordedAtPretty = outFormatter.string(from: date)
                            }
                        }
                    }

                    if let wt = mgRow[mgWeight] {
                        measurementLines.append(String(format: fmtWeightMeasuredOn, wt, recordedAtPretty))
                    }
                    if let ht = mgRow[mgHeight] {
                        measurementLines.append(String(format: fmtLengthMeasuredOn, ht, recordedAtPretty))
                    }
                    if let hc = mgRow[mgHeadCirc] {
                        measurementLines.append(String(format: fmtHeadCircMeasuredOn, hc, recordedAtPretty))
                    }

                    // Optional: weight gain (delta) for young infants (up to ~2 months)
                    if let ageMonthsForDelta = computeAgeMonths(
                        dobString: dobText,
                        visitDateString: visitDate,
                        ageDays: ageDaysDB
                    ),
                       ageMonthsForDelta <= 2.0,
                       let currentWeightKg = mgRow[mgWeight] {

                        // Parse current measurement date into currentDateFinal
                        let recordedAtRawForDelta = mgRow[mgRecordedAt]
                        var currentDateFinal: Date? = nil

                        let isoFormatterForCurrent = ISO8601DateFormatter()
                        isoFormatterForCurrent.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        if let d = isoFormatterForCurrent.date(from: recordedAtRawForDelta) {
                            currentDateFinal = d
                        } else {
                            isoFormatterForCurrent.formatOptions = [.withInternetDateTime]
                            if let d2 = isoFormatterForCurrent.date(from: recordedAtRawForDelta) {
                                currentDateFinal = d2
                            } else {
                                let dateOnlyFormatter = DateFormatter()
                                dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
                                dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
                                currentDateFinal = dateOnlyFormatter.date(from: recordedAtRawForDelta)
                            }
                        }

                        // If we can't parse the date, skip the delta line but keep the measurements

                        deltaWeightCalc: do {
                            guard let currentDateParsed = currentDateFinal else {
                                WellVisitPDFGenerator.log.warning("Measurements: couldn't parse current date from recorded_at='\(recordedAtRawForDelta, privacy: .public)' — skipping delta weight")
                                break deltaWeightCalc
                            }

                            var baselineWeightGrams: Double? = nil
                            var baselineDate: Date? = nil

                            // For ages > ~30 days (1 month), try to use the most recent prior manual_growth as reference
                            if ageMonthsForDelta > 1.0 {
                                if let rows = try? db.prepare(manualGrowth.filter(mgPatientID == pid)) {
                                    var latestPrevDate: Date? = nil

                                    for row in rows {
                                        let raw = row[mgRecordedAt]

                                        var prevDate: Date? = nil
                                        let isoPrev = ISO8601DateFormatter()
                                        isoPrev.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                                        if let d = isoPrev.date(from: raw) {
                                            prevDate = d
                                        } else {
                                            isoPrev.formatOptions = [.withInternetDateTime]
                                            if let d2 = isoPrev.date(from: raw) {
                                                prevDate = d2
                                            } else {
                                                let dateOnlyPrev = DateFormatter()
                                                dateOnlyPrev.dateFormat = "yyyy-MM-dd"
                                                dateOnlyPrev.locale = Locale(identifier: "en_US_POSIX")
                                                prevDate = dateOnlyPrev.date(from: raw)
                                            }
                                        }

                                        guard let prevDateFinal = prevDate, prevDateFinal < currentDateParsed else {
                                            continue
                                        }

                                        if let existing = latestPrevDate {
                                            if prevDateFinal > existing {
                                                latestPrevDate = prevDateFinal
                                                if let wPrev = row[mgWeight] {
                                                    baselineWeightGrams = wPrev * 1000.0
                                                    baselineDate = prevDateFinal
                                                }
                                            }
                                        } else {
                                            latestPrevDate = prevDateFinal
                                            if let wPrev = row[mgWeight] {
                                                baselineWeightGrams = wPrev * 1000.0
                                                baselineDate = prevDateFinal
                                            }
                                        }
                                    }
                                }
                            }

                            // If no prior manual_growth reference, fall back to perinatal discharge, then birth weight
                            if baselineWeightGrams == nil || baselineDate == nil {
                                let perinatalTable = Table("perinatal_history")
                                let perinatalPatientID = Expression<Int64>("patient_id")
                                let dischargeWeightCol = Expression<Int?>("discharge_weight_g")
                                let dischargeDateCol = Expression<String?>("maternity_discharge_date")
                                let birthWeightCol = Expression<Int?>("birth_weight_g")

                                if let peri = try? db.pluck(perinatalTable.filter(perinatalPatientID == pid)) {
                                    // 1) Try discharge weight + discharge date
                                    let dwOpt: Int?? = try? peri.get(dischargeWeightCol)
                                    let dischargeDateOpt: String?? = try? peri.get(dischargeDateCol)

                                    if let dwUnwrapped = dwOpt,
                                       let dw = dwUnwrapped,
                                       let dischargeDateUnwrapped = dischargeDateOpt,
                                       let dischargeDateStr = dischargeDateUnwrapped {

                                        let dateOnlyFormatter = DateFormatter()
                                        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
                                        dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
                                        if let dischargeDateFinal = dateOnlyFormatter.date(from: dischargeDateStr) {
                                            baselineWeightGrams = Double(dw)
                                            baselineDate = dischargeDateFinal
                                        }
                                    }

                                    // 2) If still no baseline, try birth weight + DOB
                                    if (baselineWeightGrams == nil || baselineDate == nil) {
                                        let bwOpt: Int?? = try? peri.get(birthWeightCol)
                                        if let bwUnwrapped = bwOpt,
                                           let bw = bwUnwrapped {

                                            let dobFormatter = DateFormatter()
                                            dobFormatter.dateFormat = "yyyy-MM-dd"
                                            dobFormatter.locale = Locale(identifier: "en_US_POSIX")
                                            if let dobDate = dobFormatter.date(from: dobText) {
                                                baselineWeightGrams = Double(bw)
                                                baselineDate = dobDate
                                            }
                                        }
                                    }
                                }
                            }

                            if let baselineWeight = baselineWeightGrams,
                               let baselineDateFinal = baselineDate {
                                let currentWeightGrams = currentWeightKg * 1000.0
                                let deltaGrams = currentWeightGrams - baselineWeight
                                let seconds = currentDateParsed.timeIntervalSince(baselineDateFinal)
                                let daysDouble = seconds / (60.0 * 60.0 * 24.0)
                                let days = Int(round(daysDouble))

                                if days > 0 {
                                    let dailyGain = deltaGrams / Double(days)
                                    let deltaSign = deltaGrams >= 0 ? "+" : "-"
                                    let deltaAbs = abs(Int(round(deltaGrams)))
                                    let line = String(format: fmtWeightGainSinceReference,
                                                      dailyGain,
                                                      deltaSign,
                                                      deltaAbs,
                                                      days)
                                    measurementLines.append(line)
                                }
                            } else {
                                measurementLines.append(noReferenceWeightFound)
                            }
                        }
                    }
                }

                // 2. If nothing from manual_growth, fall back to legacy per-visit fields
                if measurementLines.isEmpty {
                    if let wt = visitRow[Expression<Double?>("weight_today_kg")] {
                        measurementLines.append(String(format: fmtTodayWeight, wt))
                    }
                    if let length = visitRow[Expression<Double?>("length_today_cm")] {
                        measurementLines.append(String(format: fmtTodayLength, length))
                    }
                    if let hc = visitRow[Expression<Double?>("head_circ_today_cm")] {
                        measurementLines.append(String(format: fmtTodayHeadCirc, hc))
                    }
                }

                // 3. Render measurements or a placeholder if none
                if measurementLines.isEmpty {
                    drawText(placeholderDash, font: UIFont.italicSystemFont(ofSize: 14))
                } else {
                    for line in measurementLines {
                        ensureSpace(for: 16)
                        drawWrappedText(line, font: subFont, in: pageRect, at: &y, using: context)
                        y += 2
                    }
                }
                
                // MARK: - Physical Examination
                y += 12
                ensureSpace(for: 18)
                drawText(secPhysicalExamination, font: UIFont.boldSystemFont(ofSize: 15))

                // Localized common values
                // (valYes / valNo are already defined earlier and reused here)
                let valNormal = WellVisitPDFGenerator.L("well_report.value.normal", "Normal")
                let valAbnormal = WellVisitPDFGenerator.L("well_report.value.abnormal", "Abnormal")

                // Age in months for PE-specific gating (hips, fontanelle, teeth, etc.)
                let ageMonthsForPE = computeAgeMonths(
                    dobString: dobText,
                    visitDateString: visitDate,
                    ageDays: ageDaysDB
                )

                // PE localization helpers (keep internal keys stable; localize only at render time)
                func peGroupTitle(_ key: String) -> String {
                    switch key {
                    case "general":
                        return WellVisitPDFGenerator.L("well_report.pe.group.general", "General")
                    case "cardiorespiratory":
                        return WellVisitPDFGenerator.L("well_report.pe.group.cardiorespiratory", "Cardiorespiratory")
                    case "eyes_head":
                        return WellVisitPDFGenerator.L("well_report.pe.group.eyes_head", "Eyes & Head")
                    case "abdomen_genitalia":
                        return WellVisitPDFGenerator.L("well_report.pe.group.abdomen_genitalia", "Abdomen & Genitalia")
                    case "skin":
                        return WellVisitPDFGenerator.L("well_report.pe.group.skin", "Skin")
                    case "msk":
                        return WellVisitPDFGenerator.L("well_report.pe.group.msk", "MSK")
                    default:
                        return key
                    }
                }

                func peFieldLabel(_ key: String) -> String {
                    switch key {
                    case "trophic":
                        return WellVisitPDFGenerator.L("well_report.pe.field.trophic", "Trophic")
                    case "hydration":
                        return WellVisitPDFGenerator.L("well_report.pe.field.hydration", "Hydration")
                    case "color":
                        return WellVisitPDFGenerator.L("well_report.pe.field.color", "Color")
                    case "tone":
                        return WellVisitPDFGenerator.L("well_report.pe.field.tone", "Tone")
                    case "wakefulness":
                        return WellVisitPDFGenerator.L("well_report.pe.field.wakefulness", "Wakefulness")
                    case "breathing":
                        return WellVisitPDFGenerator.L("well_report.pe.field.breathing", "Breathing")
                    case "heart_sounds":
                        return WellVisitPDFGenerator.L("well_report.pe.field.heart_sounds", "Heart sounds")
                    case "femoral_pulses":
                        return WellVisitPDFGenerator.L("well_report.pe.field.femoral_pulses", "Femoral pulses")
                    case "fontanelle":
                        return WellVisitPDFGenerator.L("well_report.pe.field.fontanelle", "Fontanelle")
                    case "pupils_rr":
                        return WellVisitPDFGenerator.L("well_report.pe.field.pupils_rr", "Pupils RR")
                    case "ocular_motility":
                        return WellVisitPDFGenerator.L("well_report.pe.field.ocular_motility", "Ocular motility")
                    case "teeth_present":
                        return WellVisitPDFGenerator.L("well_report.pe.field.teeth_present", "Teeth present")
                    case "teeth_count":
                        return WellVisitPDFGenerator.L("well_report.pe.field.teeth_count", "Teeth count")
                    case "liver_spleen":
                        return WellVisitPDFGenerator.L("well_report.pe.field.liver_spleen", "Liver/Spleen")
                    case "abdominal_mass":
                        return WellVisitPDFGenerator.L("well_report.pe.field.abdominal_mass", "Abdominal mass")
                    case "genitalia":
                        return WellVisitPDFGenerator.L("well_report.pe.field.genitalia", "Genitalia")
                    case "umbilic":
                        return WellVisitPDFGenerator.L("well_report.pe.field.umbilic", "Umbilic")
                    case "testicles_descended":
                        return WellVisitPDFGenerator.L("well_report.pe.field.testicles_descended", "Testicles descended")
                    case "skin_marks":
                        return WellVisitPDFGenerator.L("well_report.pe.field.skin_marks", "Marks")
                    case "skin_integrity":
                        return WellVisitPDFGenerator.L("well_report.pe.field.skin_integrity", "Integrity")
                    case "skin_rash":
                        return WellVisitPDFGenerator.L("well_report.pe.field.skin_rash", "Rash")
                    case "spine":
                        return WellVisitPDFGenerator.L("well_report.pe.field.spine", "Spine")
                    case "hips":
                        return WellVisitPDFGenerator.L("well_report.pe.field.hips", "Hips")
                    default:
                        return key
                    }
                }

                func normalAbnormal(_ value: Int?) -> String? {
                    guard let v = value else { return nil }
                    if v == 1 { return valNormal }
                    if v == 0 { return valAbnormal }
                    return nil
                }

                func yesNoValue(_ value: Int?) -> String? {
                    guard let v = value else { return nil }
                    if v == 1 { return valYes }
                    if v == 0 { return valNo }
                    return nil
                }

                // Grouped PE fields like in Python app
                let peGroups: [(groupKey: String, fields: [(fieldKey: String, rawValue: Any?, comment: Any?)])] = [
                    ("general", [
                        ("trophic", visitRow[Expression<Int?>("pe_trophic_normal")], visitRow[Expression<String?>("pe_trophic_comment")]),
                        ("hydration", visitRow[Expression<Int?>("pe_hydration_normal")], visitRow[Expression<String?>("pe_hydration_comment")]),
                        ("color", visitRow[Expression<String?>("pe_color")], visitRow[Expression<String?>("pe_color_comment")]),
                        ("tone", visitRow[Expression<Int?>("pe_tone_normal")], visitRow[Expression<String?>("pe_tone_comment")]),
                        ("wakefulness", visitRow[Expression<Int?>("pe_wakefulness_normal")], visitRow[Expression<String?>("pe_wakefulness_comment")])
                    ]),
                    ("cardiorespiratory", [
                        ("breathing", visitRow[Expression<Int?>("pe_breathing_normal")], visitRow[Expression<String?>("pe_breathing_comment")]),
                        ("heart_sounds", visitRow[Expression<Int?>("pe_heart_sounds_normal")], visitRow[Expression<String?>("pe_heart_sounds_comment")]),
                        ("femoral_pulses", visitRow[Expression<Int?>("pe_femoral_pulses_normal")], visitRow[Expression<String?>("pe_femoral_pulses_comment")])
                    ]),
                    ("eyes_head", [
                        ("fontanelle", visitRow[Expression<Int?>("pe_fontanelle_normal")], visitRow[Expression<String?>("pe_fontanelle_comment")]),
                        ("pupils_rr", visitRow[Expression<Int?>("pe_pupils_rr_normal")], visitRow[Expression<String?>("pe_pupils_rr_comment")]),
                        ("ocular_motility", visitRow[Expression<Int?>("pe_ocular_motility_normal")], visitRow[Expression<String?>("pe_ocular_motility_comment")]),
                        // Teeth belong to Eyes & Head group, with age gating and dependency on presence flag
                        ("teeth_present", visitRow[Expression<Int?>("pe_teeth_present")], visitRow[Expression<String?>("pe_teeth_comment")]),
                        ("teeth_count", visitRow[Expression<Int?>("pe_teeth_count")], nil)
                    ]),
                    ("abdomen_genitalia", [
                        ("liver_spleen", visitRow[Expression<Int?>("pe_liver_spleen_normal")], visitRow[Expression<String?>("pe_liver_spleen_comment")]),
                        ("abdominal_mass", visitRow[Expression<Int?>("pe_abd_mass")], nil),
                        ("genitalia", visitRow[Expression<String?>("pe_genitalia")], nil),
                        ("umbilic", visitRow[Expression<Int?>("pe_umbilic_normal")], visitRow[Expression<String?>("pe_umbilic_comment")]),
                        ("testicles_descended", visitRow[Expression<Int?>("pe_testicles_descended")], nil)
                    ]),
                    ("skin", [
                        ("skin_marks", visitRow[Expression<Int?>("pe_skin_marks_normal")], visitRow[Expression<String?>("pe_skin_marks_comment")]),
                        ("skin_integrity", visitRow[Expression<Int?>("pe_skin_integrity_normal")], visitRow[Expression<String?>("pe_skin_integrity_comment")]),
                        ("skin_rash", visitRow[Expression<Int?>("pe_skin_rash_normal")], visitRow[Expression<String?>("pe_skin_rash_comment")])
                    ]),
                    ("msk", [
                        ("spine", visitRow[Expression<Int?>("pe_spine_normal")], visitRow[Expression<String?>("pe_spine_comment")]),
                        ("hips", visitRow[Expression<Int?>("pe_hips_normal")], visitRow[Expression<String?>("pe_hips_comment")])
                    ])
                ]

                var foundPE = false

                for (groupKey, fields) in peGroups {
                    var groupParts: [String] = []

                    for (fieldKey, rawValue, commentRaw) in fields {
                        // Sex gating: never show testicles for girls
                        if fieldKey == "testicles_descended", sexText != "M" {
                            continue
                        }

                        // Age gating rules – fail open if ageMonthsForPE is nil
                        if let ageMonths = ageMonthsForPE {
                            switch fieldKey {
                            case "hips":
                                // Hips visible only up to 6 months
                                if ageMonths > 6.0 { continue }
                            case "fontanelle":
                                // Fontanelle visible only up to 24 months
                                if ageMonths > 24.0 { continue }
                            case "teeth_present", "teeth_count":
                                // Teeth visible from 4 months onward
                                if ageMonths < 4.0 { continue }
                            default:
                                break
                            }
                        }

                        var displayValue: String?

                        func localizedPEEnumValue(fieldKey: String, raw: String) -> String {
                            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return trimmed }

                            // Only localize known picker/enumerated values; fail-open to raw for anything unexpected.
                            switch fieldKey {
                            case "color":
                                switch trimmed {
                                case "normal", "jaundice", "pale":
                                    return WellVisitPDFGenerator.L("well_report.enum.pe_color.\(trimmed)", trimmed)
                                default:
                                    return trimmed
                                }
                            default:
                                return trimmed
                            }
                        }

                        func valueForInt(_ v: Int) -> String? {
                            switch fieldKey {
                            case "abdominal_mass":
                                return (v == 1) ? valYes : (v == 0) ? valNo : nil
                            case "teeth_present":
                                return (v == 1) ? valYes : (v == 0) ? valNo : nil
                            case "testicles_descended":
                                return (v == 1) ? valYes : (v == 0) ? valNo : nil
                            case "teeth_count":
                                // Only show count if we know teeth are present
                                let presentVal = visitRow[Expression<Int?>("pe_teeth_present")] ?? 0
                                return (presentVal == 1) ? "\(v)" : nil
                            default:
                                return normalAbnormal(v)
                            }
                        }

                        switch rawValue {
                        case let b as Int:
                            displayValue = valueForInt(b)

                        case let s as String:
                            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                displayValue = localizedPEEnumValue(fieldKey: fieldKey, raw: trimmed)
                            }

                        case let optStr as Optional<String>:
                            if let s = optStr {
                                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    displayValue = localizedPEEnumValue(fieldKey: fieldKey, raw: trimmed)
                                }
                            }

                        case let optInt as Optional<Int>:
                            if let v = optInt {
                                displayValue = valueForInt(v)
                            }

                        default:
                            break
                        }

                        if let result = displayValue {
                            let label = peFieldLabel(fieldKey)
                            var line = "\(label): \(result)"

                            // Unwrap commentRaw safely (handles both String and String?)
                            var commentString: String?
                            if let s = commentRaw as? String {
                                commentString = s
                            } else if let sOpt = commentRaw as? Optional<String>, let s = sOpt {
                                commentString = s
                            }

                            if let c = commentString,
                               !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                // Field-specific rules for when to append comments
                                if fieldKey == "teeth_present" {
                                    // Only attach comment if teeth are present
                                    let presentVal = visitRow[Expression<Int?>("pe_teeth_present")] ?? 0
                                    if presentVal == 1 {
                                        line += " (\(c))"
                                    }
                                } else if fieldKey == "hips" {
                                    // Only attach comment if hips are abnormal
                                    let hipsNormalVal = visitRow[Expression<Int?>("pe_hips_normal")] ?? 1
                                    if hipsNormalVal == 0 {
                                        line += " (\(c))"
                                    }
                                } else if fieldKey == "fontanelle" {
                                    // Only attach comment if fontanelle is abnormal
                                    let fontanelleVal = visitRow[Expression<Int?>("pe_fontanelle_normal")] ?? 1
                                    if fontanelleVal == 0 {
                                        line += " (\(c))"
                                    }
                                } else {
                                    // Default behavior: always append tidy comment
                                    line += " (\(c))"
                                }
                            }

                            groupParts.append(line)
                        }
                    }

                    if !groupParts.isEmpty {
                        foundPE = true
                        let groupTitle = peGroupTitle(groupKey)
                        drawWrappedText(
                            "\(groupTitle): " + groupParts.joined(separator: "; "),
                            font: subFont,
                            in: pageRect,
                            at: &y,
                            using: context
                        )
                    }
                }

                if !foundPE {
                    drawText(WellVisitPDFGenerator.L("well_report.default.no_physical_exam_findings",
                                                     "No physical exam findings recorded."),
                             font: subFont)
                }
                
                // MARK: - Problem Listing
                y += 12
                ensureSpace(for: 18)
                drawText(secProblemListing, font: UIFont.boldSystemFont(ofSize: 15))

                let rawProblems = visitRow[Expression<String?>("problem_listing")] ?? ""
                let trimmedProblems = rawProblems.trimmingCharacters(in: .whitespacesAndNewlines)

                if trimmedProblems.isEmpty {
                    // No problem listing documented
                    drawText(placeholderDash, font: subFont)
                } else {
                    // Split into logical lines and render each as a bullet
                    let lines = trimmedProblems
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }

                    if lines.isEmpty {
                        drawText(placeholderDash, font: subFont)
                    } else {
                        for line in lines {
                            ensureSpace(for: 16)
                            drawWrappedText(line, font: subFont, in: pageRect, at: &y, using: context)
                            y += 2
                        }
                    }
                }
                
                // MARK: - Conclusions
                y += 12
                ensureSpace(for: 18)
                drawText(secConclusions, font: UIFont.boldSystemFont(ofSize: 15))
                let conclusions = visitRow[Expression<String?>("conclusions")] ?? ""
                let trimmedConclusions = conclusions.trimmingCharacters(in: .whitespacesAndNewlines)

                if !trimmedConclusions.isEmpty {
                    drawWrappedText(trimmedConclusions, font: subFont, in: pageRect, at: &y, using: context)
                } else {
                    // Default conclusion when nothing specific is documented
                    let fmtHealthyWithAge = WellVisitPDFGenerator.L(
                        "well_report.conclusions.default.healthy_with_age_fmt",
                        "Healthy %@"
                    )
                    let healthyOnly = WellVisitPDFGenerator.L(
                        "well_report.conclusions.default.healthy",
                        "Healthy"
                    )

                    if let ageStr = formatAgeString(dobString: dobText,
                                                   visitDateString: visitDate,
                                                   ageDays: ageDaysDB) {
                        drawWrappedText(String(format: fmtHealthyWithAge, ageStr),
                                       font: subFont,
                                       in: pageRect,
                                       at: &y,
                                       using: context)
                    } else {
                        drawWrappedText(healthyOnly,
                                       font: subFont,
                                       in: pageRect,
                                       at: &y,
                                       using: context)
                    }
                }

                // MARK: - Anticipatory Guidance
                y += 12
                ensureSpace(for: 18)
                drawText(secAnticipatoryGuidance, font: UIFont.boldSystemFont(ofSize: 15))
                let guidance = visitRow[Expression<String?>("anticipatory_guidance")] ?? ""
                if !guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    drawWrappedText(guidance, font: subFont, in: pageRect, at: &y, using: context)
                } else {
                    drawText(WellVisitPDFGenerator.L("well_report.default.anticipatory_guidance",
                                                     "Age appropriate anticipatory guidance"),
                             font: subFont)                }

               

                // MARK: - Clinician Comments
                y += 12
                ensureSpace(for: 18)
                drawText(WellVisitPDFGenerator.L("well_report.section.clinician_comments",
                                                 "Clinician Comments"),
                         font: UIFont.boldSystemFont(ofSize: 15))
                let comments = visitRow[Expression<String?>("comments")] ?? ""
                if !comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    drawWrappedText(comments, font: subFont, in: pageRect, at: &y, using: context)
                } else {
                    drawText(WellVisitPDFGenerator.L("well_report.default.no_clinician_comments",
                                                     "No clinician comments recorded."),
                             font: subFont)
                }

                // MARK: - Next Visit Date (optional)
                y += 12
                ensureSpace(for: 18)
                let nextVisit = visitRow[Expression<String?>("next_visit_date")] ?? ""
                if !nextVisit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let lblNextVisitDate = WellVisitPDFGenerator.L(
                        "well_report.label.next_visit_date",
                        "Next Visit Date"
                    )
                    drawText("\(lblNextVisitDate): \(WellVisitPDFGenerator.formatDate(nextVisit))", font: subFont)
                }

                // MARK: - AI Assistant Input
                y += 12
                ensureSpace(for: 18)
                drawText(WellVisitPDFGenerator.L("well_report.section.ai_assistant_input",
                                                 "AI Assistant Input"),
                         font: UIFont.boldSystemFont(ofSize: 15))

                let aiTable = Table("well_ai_inputs")
                let aiVisitID = Expression<Int64>("well_visit_id")
                let aiResponse = Expression<String?>("response")
                let aiCreatedAt = Expression<String?>("created_at")

                // Fetch only the latest AI record for this visit, ordered by created_at descending
                let latestAIQuery = aiTable
                    .filter(aiVisitID == visit.id)
                    .order(aiCreatedAt.desc)
                    .limit(1)

                if let aiRow = try? db.pluck(latestAIQuery),
                   let responseRaw = aiRow[aiResponse] {
                    let response = responseRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !response.isEmpty {
                        drawWrappedText(response, font: subFont, in: pageRect, at: &y, using: context)
                    } else {
                        drawText(WellVisitPDFGenerator.L("well_report.default.no_ai_input",
                                                         "No AI input recorded"),
                                 font: subFont)                    }
                } else {
                    drawText(WellVisitPDFGenerator.L("well_report.default.no_ai_input",
                                                     "No AI input recorded"),
                             font: subFont)
                }
                
                // MARK: - Addenda (appended at end)
                let addenda = WellVisitPDFGenerator.fetchAddendaForWellVisit(db: db, wellVisitID: visit.id)
                if !addenda.isEmpty {
                    y += 12
                    drawSectionTitle(secAddenda, font: UIFont.boldSystemFont(ofSize: 16))

                    let body = WellVisitPDFGenerator.buildAddendaBody(addenda)
                    if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        drawText(placeholderDash, font: subFont)
                    } else {
                        drawWrappedText(body, font: subFont, in: pageRect, at: &y, using: context)
                    }
                }
                
                // MARK: - Growth Charts
                y += 12
                ensureSpace(for: 18)

                for (title, chartImage) in chartImagesToRender {
                    // Each chart gets its own fresh page
                    context.beginPage()
                    y = margin

                    // Draw chart title at top of page
                    drawSectionTitle(title, font: UIFont.boldSystemFont(ofSize: 16))

                    // Validate image size to avoid NaN aspect ratios
                    guard chartImage.size.width > 0, chartImage.size.height > 0 else {
                        WellVisitPDFGenerator.log.warning(
                            "Skipping chart '\(title, privacy: .public)' due to invalid size w=\(chartImage.size.width, privacy: .public) h=\(chartImage.size.height, privacy: .public)"
                        )
                        continue
                    }

                    // Available drawing space *below* the title
                    let maxWidth = pageWidth - 2 * margin
                    let availableHeight = pageHeight - y - margin - 8   // 8pt spacing below title

                    let aspectRatio = chartImage.size.width / chartImage.size.height
                    var targetWidth = maxWidth
                    var targetHeight = targetWidth / aspectRatio

                    // If height exceeds available space, scale down to fit
                    if targetHeight > availableHeight {
                        targetHeight = availableHeight
                        targetWidth = targetHeight * aspectRatio
                    }

                    // Center image horizontally, place it just under the title
                    let imageX = (pageWidth - targetWidth) / 2
                    let imageY = y + 8   // small gap under title

                    let imageRect = CGRect(x: imageX, y: imageY, width: targetWidth, height: targetHeight)
                    chartImage.draw(in: imageRect)

                    // Update y in case you ever add anything below the chart later
                    y = imageY + targetHeight + 8
                }

            } catch {
                WellVisitPDFGenerator.log.error("DB error during PDF render: \(error.localizedDescription, privacy: .public)")
                let fmtDBError = WellVisitPDFGenerator.L("well_report.error.db_error_fmt", "❌ DB Error: %@")
                drawText(String(format: fmtDBError, error.localizedDescription), font: subFont)
            }
        }

        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = docsURL.appendingPathComponent("WellVisitReport_\(visit.id).pdf")
        try data.write(to: fileURL)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? NSNumber {
            WellVisitPDFGenerator.log.info("WellVisit PDF saved at \(fileURL.path, privacy: .public) (size=\(size.intValue, privacy: .public) bytes)")
        } else {
            WellVisitPDFGenerator.log.info("WellVisit PDF saved at \(fileURL.path, privacy: .public)")
        }
        return fileURL
    }

    private static func formatDate(_ raw: Any, includeTime: Bool = false) -> String {
        func formatOut(_ date: Date) -> String {
            let out = DateFormatter()
            out.locale = Locale.autoupdatingCurrent
            out.timeZone = TimeZone.autoupdatingCurrent
            out.dateStyle = .medium
            out.timeStyle = includeTime ? .short : .none
            return out.string(from: date)
        }

        if let date = raw as? Date {
            return formatOut(date)
        }

        if let dateString = raw as? String {
            let trimmed = dateString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }

            // 1) ISO8601 with fractional seconds (e.g. 2025-12-29T18:05:30.123Z)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: trimmed) { return formatOut(d) }

            // 2) ISO8601 without fractional seconds (e.g. 2025-12-29T18:05:30Z)
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: trimmed) { return formatOut(d) }

            // 3) Legacy microseconds format (e.g. 2025-12-29T18:05:30.123456)
            let legacy = DateFormatter()
            legacy.locale = Locale(identifier: "en_US_POSIX")
            legacy.timeZone = TimeZone(secondsFromGMT: 0)

            legacy.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
            if let d = legacy.date(from: trimmed) { return formatOut(d) }

            // 4) Legacy without fractional seconds (e.g. 2025-12-29T18:05:30)
            legacy.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            if let d = legacy.date(from: trimmed) { return formatOut(d) }

            // 5) Date-only (e.g. 2025-12-29)
            legacy.dateFormat = "yyyy-MM-dd"
            if let d = legacy.date(from: trimmed) { return formatOut(d) }

            // Fail-open: if we can't parse, keep the original string
            return trimmed
        }

        return "\(raw)"
    }
}

