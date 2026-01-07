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

@inline(__always)
private func L(_ key: String, _ fallback: String) -> String {
    NSLocalizedString(key, comment: fallback)
}

struct WellVisitPDFGenerator {
    private static let log = Logger(subsystem: "com.patientviewer.app", category: "pdf.well")
    // Simple localization helper for non-SwiftUI code (PDF rendering).
    // Uses the key if available in Localizable.strings, otherwise falls back to the provided English.
    private static func L(_ key: String, _ fallback: String) -> String {
        NSLocalizedString(key, value: fallback, comment: "")
    }
    static func generate(for visit: VisitSummary, dbURL: URL) async throws -> URL? {
        WellVisitPDFGenerator.log.info("Generating WellVisit PDF for id=\(visit.id, privacy: .public) base=\(dbURL.path, privacy: .public)")
        let pdfMetaData = [
            kCGPDFContextCreator: "Patient Viewer",
            kCGPDFContextAuthor: "Patient App",
            kCGPDFContextTitle: "Well Visit Report"
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
                "well_report.visit_type.newborn_first",
                "First visit after maternity"
            ),
            // Common aliases (in case older DB rows used different keys)
            "post_maternity_first": WellVisitPDFGenerator.L(
                "well_report.visit_type.first_visit_after_maternity",
                "First visit after maternity"
            ),
            "first_after_maternity": WellVisitPDFGenerator.L(
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
            "thirtysix_month": WellVisitPDFGenerator.L("well_report.visit_type.thirtysix_month", "36-month visit")
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

            let titleFont = UIFont.boldSystemFont(ofSize: 20)
            let subFont = UIFont.systemFont(ofSize: 14)

            drawText(WellVisitPDFGenerator.L("well_report.title", "Well Visit Report"), font: titleFont)
            drawText("\(WellVisitPDFGenerator.L("well_report.generated", "Report Generated")): \(WellVisitPDFGenerator.formatDate(Date()))", font: subFont)

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

                let aliasText = patientRow[alias] ?? placeholderDash
                let dobText = patientRow[dob]
                let sexText = patientRow[sex]
                let mrnText = patientRow[mrn]
                WellVisitPDFGenerator.log.debug("Patient alias=\(aliasText, privacy: .public) name=\(name, privacy: .public) dob=\(dobText, privacy: .public) sex=\(sexText, privacy: .public)")

                let visitDate = visitRow[Expression<String>("visit_date")]
                let visitType = visitRow[Expression<String>("visit_type")]
                let ageDaysDB = visitRow[Expression<Int?>("age_days")]

                // Localized patient/visit header labels
                let hdrAlias = WellVisitPDFGenerator.L("well_report.header.alias", "Alias")
                let hdrName = WellVisitPDFGenerator.L("well_report.header.name", "Name")
                let hdrDOB = WellVisitPDFGenerator.L("well_report.header.dob", "DOB")
                let hdrSex = WellVisitPDFGenerator.L("well_report.header.sex", "Sex")
                let hdrMRN = WellVisitPDFGenerator.L("well_report.header.mrn", "MRN")
                let hdrAgeAtVisit = WellVisitPDFGenerator.L("well_report.header.age_at_visit", "Age at Visit")
                let hdrVisitDate = WellVisitPDFGenerator.L("well_report.header.visit_date", "Visit Date")
                let hdrVisitType = WellVisitPDFGenerator.L("well_report.header.visit_type", "Visit Type")
                let unitDays = WellVisitPDFGenerator.L("well_report.unit.days", "days")

                drawText("\(hdrAlias): \(aliasText)", font: subFont)
                drawText("\(hdrName): \(name)", font: subFont)
                drawText("\(hdrDOB): \(dobText)", font: subFont)
                drawText("\(hdrSex): \(sexText)", font: subFont)
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

                let users = Table("users")
                let userID = Expression<Int64?>("user_id")
                let firstNameUser = Expression<String>("first_name")
                let lastNameUser = Expression<String>("last_name")

                // user_id may be NULL in the DB; handle that safely
                if let userIdVal = visitRow[userID] {
                    if let userRow = try? db.pluck(users.filter(Expression<Int64>("id") == userIdVal)) {
                        let clinicianName = "\(userRow[firstNameUser]) \(userRow[lastNameUser])"
                        let hdrClinician = WellVisitPDFGenerator.L("well_report.header.clinician", "Clinician")
                        drawText("\(hdrClinician): \(clinicianName)", font: subFont)
                    }
                } else {
                    // Optionally, you could show something here:
                    // let hdrClinician = WellVisitPDFGenerator.L("well_report.header.clinician", "Clinician")
                    // drawText("\(hdrClinician): —", font: subFont)
                }
                
                // MARK: - Perinatal Summary
                y += 12
                drawText(secPerinatalSummary, font: UIFont.boldSystemFont(ofSize: 16))

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

                // Localized formatted fields (Perinatal Summary)
                let periFmtGAWeeks = WellVisitPDFGenerator.L("well_report.perinatal.fmt.ga_weeks", "GA: %d w")
                let periFmtBirthWeightG = WellVisitPDFGenerator.L("well_report.perinatal.fmt.birth_weight_g", "BW: %d g")
                let periFmtBirthLengthCM = WellVisitPDFGenerator.L("well_report.perinatal.fmt.birth_length_cm", "BL: %.1f cm")
                let periFmtBirthHeadCircCM = WellVisitPDFGenerator.L("well_report.perinatal.fmt.birth_head_circumference_cm", "HC: %.1f cm")
                let periFmtDischargeWeightG = WellVisitPDFGenerator.L("well_report.perinatal.fmt.discharge_weight_g", "Discharge Wt: %d g")

                if let peri = try? db.pluck(perinatal.filter(Expression<Int64>("patient_id") == pid)) {
                    var parts: [String] = []

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

                    if let v = try? peri.get(feeding) {
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { parts.append("\(periLblFeedingInMaternity): \(t)") }
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
                        if !t.isEmpty { parts.append("\(periLblMotherVaccinations): \(t)") }
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
                drawText(secPreviousWellVisits, font: UIFont.boldSystemFont(ofSize: 16))

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

                    drawText("\(vTitle) — \(formattedDate)", font: subFont)

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
                drawText(secCurrentVisit, font: UIFont.boldSystemFont(ofSize: 16))

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

                // Localized content labels (Feeding)
                let valYes = WellVisitPDFGenerator.L("well_report.value.yes", "Yes")
                let valNo  = WellVisitPDFGenerator.L("well_report.value.no", "No")

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

                let valAppearsGood = WellVisitPDFGenerator.L("well_report.value.appears_good", "appears good")
                let valProbablyLimited = WellVisitPDFGenerator.L("well_report.value.probably_limited", "probably limited")

                let fmtTypicalFeedVolume = WellVisitPDFGenerator.L("well_report.feeding.fmt.typical_feed_volume_ml", "Typical feed volume: %.0f ml")
                let fmtFeedsPer24h = WellVisitPDFGenerator.L("well_report.feeding.fmt.feeds_per_24h", "Feeds per 24h: %d times")
                let fmtEstimatedTotalIntake = WellVisitPDFGenerator.L("well_report.feeding.fmt.estimated_total_intake_ml_per_24h", "Estimated total intake: %.0f ml/24h")
                let fmtEstimatedIntakePerKg = WellVisitPDFGenerator.L("well_report.feeding.fmt.estimated_intake_ml_per_kg_24h", "Estimated intake: %.0f ml/kg/24h")
                let fmtDairyCupsOrBottles = WellVisitPDFGenerator.L("well_report.feeding.fmt.dairy_cups_or_bottles", "Dairy intake daily: %@ cup(s) or bottle(s)")

                // milk_types TEXT
                if let milkTypesRaw = visitRow[Expression<String?>("milk_types")] {
                    let milkTypes = milkTypesRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !milkTypes.isEmpty {
                        feedingLines.append("\(lblMilk): \(milkTypes)")
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
                        feedingLines.append("\(lblSolidFoodsSince): \(solidDate)")
                    }
                }

                // solid_food_quality TEXT
                if let solidQualityRaw = visitRow[Expression<String?>("solid_food_quality")] {
                    let solidQuality = solidQualityRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !solidQuality.isEmpty {
                        let prettyQuality: String
                        switch solidQuality {
                        case "appears_good":
                            prettyQuality = valAppearsGood
                        case "probably_limited":
                            prettyQuality = valProbablyLimited
                        default:
                            prettyQuality = solidQuality
                        }
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
                        let prettyVariety: String
                        if variety == "appears_good" {
                            prettyVariety = valAppearsGood
                        } else {
                            prettyVariety = variety
                        }
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
                        stoolLines.append(String(format: fmtStoolPattern, status))
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

                // Helper to prettify sleep duration string (e.g. "10_15" -> "10 to 15 hours")
                func prettySleepDuration(_ raw: String) -> String {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Expecting values like "10_15" -> "10 to 15 hours"
                    let parts = trimmed.split(separator: "_", omittingEmptySubsequences: true)
                    if parts.count == 2 {
                        let first = parts[0]
                        let second = parts[1]
                        if !first.isEmpty && !second.isEmpty {
                            let fmtRangeHours = WellVisitPDFGenerator.L("well_report.sleep.fmt.range_hours", "%@ to %@ hours")
                            return String(format: fmtRangeHours, String(first), String(second))
                        }
                    }
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

                // 2. Sleep regularity (free text)
                if let regularRaw = visitRow[Expression<String?>("sleep_regular")] {
                    let regular = regularRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !regular.isEmpty {
                        sleepLines.append(String(format: fmtSleepRegularity, regular))
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

                if issueReportedVal == 1 {
                    if issueText.isEmpty {
                        sleepLines.append(sleepIssueYes)
                    } else {
                        sleepLines.append(String(format: fmtSleepIssueYesDetail, issueText))
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
                let devResult = visitRow[Expression<String?>("devtest_result")] ?? ""

                if let ageMonths = ageMonthsForDev,
                   ageMonths >= 9.0, ageMonths <= 36.0 {
                    if let score = devTestScore {
                        let trimmedResult = devResult.trimmingCharacters(in: .whitespacesAndNewlines)
                        var devString: String
                        if !trimmedResult.isEmpty {
                            devString = String(format: fmtDevResultScore, trimmedResult, score)
                        } else {
                            devString = String(format: fmtDevScoreOnly, score)
                        }
                        ensureSpace(for: 16)
                        drawWrappedText(devString, font: subFont, in: pageRect, at: &y, using: context)
                    } else {
                        let trimmedResult = devResult.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedResult.isEmpty {
                            ensureSpace(for: 16)
                            drawWrappedText(String(format: fmtDevResultOnly, trimmedResult), font: subFont, in: pageRect, at: &y, using: context)
                        }
                    }
                }

                // M-CHAT strings
                let fmtMchatResultScore = WellVisitPDFGenerator.L("well_report.development.mchat.result_score_fmt", "M-CHAT: %@ (score %d)")
                let fmtMchatScoreOnly = WellVisitPDFGenerator.L("well_report.development.mchat.score_only_fmt", "M-CHAT score: %d")
                let fmtMchatResultOnly = WellVisitPDFGenerator.L("well_report.development.mchat.result_only_fmt", "M-CHAT: %@")

                // M-CHAT (mchat_*), shown from 18 to 30 months
                let mchatScore = visitRow[Expression<Int?>("mchat_score")]
                let mchatResult = visitRow[Expression<String?>("mchat_result")] ?? ""

                if let ageMonths = ageMonthsForDev,
                   ageMonths >= 18.0, ageMonths <= 30.0 {
                    if let score = mchatScore {
                        let trimmed = mchatResult.trimmingCharacters(in: .whitespacesAndNewlines)
                        var mchatLine: String
                        if !trimmed.isEmpty {
                            mchatLine = String(format: fmtMchatResultScore, trimmed, score)
                        } else {
                            mchatLine = String(format: fmtMchatScoreOnly, score)
                        }
                        ensureSpace(for: 16)
                        drawWrappedText(mchatLine, font: subFont, in: pageRect, at: &y, using: context)
                    } else {
                        let trimmed = mchatResult.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            ensureSpace(for: 16)
                            drawWrappedText(String(format: fmtMchatResultOnly, trimmed), font: subFont, in: pageRect, at: &y, using: context)
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
                let status = Expression<String>("status")

                let milestoneRows = try? db.prepare(milestonesTable.filter(Expression<Int64>("visit_id") == visit.id))

                var achievedCount = 0
                var totalCount = 0
                var flags: [String] = []

                if let rows = milestoneRows {
                    for row in rows {
                        let stat = row[status]
                        totalCount += 1
                        if stat == "achieved" {
                            achievedCount += 1
                        } else if stat == "uncertain" || stat == "not yet" {
                            let itemLabel = row[label]
                            let statDisplay: String
                            switch stat {
                            case "uncertain":
                                statDisplay = statUncertain
                            case "not yet":
                                statDisplay = statNotYet
                            default:
                                statDisplay = stat
                            }
                            flags.append("\(itemLabel): \(statDisplay)")
                        }
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
                        measurementLines.append(String(format: "Weight: %.2f kg (measured on %@)", wt, recordedAtPretty))
                    }
                    if let ht = mgRow[mgHeight] {
                        measurementLines.append(String(format: "Length/Height: %.1f cm (measured on %@)", ht, recordedAtPretty))
                    }
                    if let hc = mgRow[mgHeadCirc] {
                        measurementLines.append(String(format: "Head circumference: %.1f cm (measured on %@)", hc, recordedAtPretty))
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

                        // If we still can't parse the date, skip the delta line but keep the measurements
                        guard let currentDateParsed = currentDateFinal else {
                            WellVisitPDFGenerator.log.warning("Measurements: unable to parse manual_growth recorded_at='\(recordedAtRawForDelta)' for delta weight")
                            // Skip delta, do not append any additional line.
                            // The raw measurements above have already been rendered.
                            return
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
                                let line = String(
                                    format: "Weight gain since reference: %.1f g/day (Δ %@%d g over %d days)",
                                    dailyGain,
                                    deltaSign,
                                    deltaAbs,
                                    days
                                )
                                measurementLines.append(line)
                            }
                        } else {
                            measurementLines.append("No reference weight found.")
                        }
                    }
                }

                // 2. If nothing from manual_growth, fall back to legacy per-visit fields
                if measurementLines.isEmpty {
                    if let wt = visitRow[Expression<Double?>("weight_today_kg")] {
                        measurementLines.append(String(format: "Today's weight: %.2f kg", wt))
                    }
                    if let length = visitRow[Expression<Double?>("length_today_cm")] {
                        measurementLines.append(String(format: "Today's length: %.1f cm", length))
                    }
                    if let hc = visitRow[Expression<Double?>("head_circ_today_cm")] {
                        measurementLines.append(String(format: "Today's head circumference: %.1f cm", hc))
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

                // Age in months for PE-specific gating (hips, fontanelle, teeth, etc.)
                let ageMonthsForPE = computeAgeMonths(
                    dobString: dobText,
                    visitDateString: visitDate,
                    ageDays: ageDaysDB
                )

                func yesNo(_ value: Int?) -> String? {
                    if value == 1 { return "normal" }
                    if value == 0 { return "abnormal" }
                    return nil
                }
                func testicleStatus(_ value: Int?) -> String? {
                    if value == 1 { return "descended" }
                    if value == 0 { return "undescended" }
                    return nil
                }

                // Grouped PE fields like in Python app
                let peGroups: [(String, [(String, Any?, Any?)])] = [
                    ("General", [
                        ("Trophic", visitRow[Expression<Int?>("pe_trophic_normal")], visitRow[Expression<String?>("pe_trophic_comment")]),
                        ("Hydration", visitRow[Expression<Int?>("pe_hydration_normal")], visitRow[Expression<String?>("pe_hydration_comment")]),
                        ("Color", visitRow[Expression<String?>("pe_color")], visitRow[Expression<String?>("pe_color_comment")]),
                        ("Tone", visitRow[Expression<Int?>("pe_tone_normal")], visitRow[Expression<String?>("pe_tone_comment")]),
                        ("Wakefulness", visitRow[Expression<Int?>("pe_wakefulness_normal")], visitRow[Expression<String?>("pe_wakefulness_comment")])
                    ]),
                    ("Cardiorespiratory", [
                        ("Breathing", visitRow[Expression<Int?>("pe_breathing_normal")], visitRow[Expression<String?>("pe_breathing_comment")]),
                        ("Heart sounds", visitRow[Expression<Int?>("pe_heart_sounds_normal")], visitRow[Expression<String?>("pe_heart_sounds_comment")]),
                        ("Femoral pulses", visitRow[Expression<Int?>("pe_femoral_pulses_normal")], visitRow[Expression<String?>("pe_femoral_pulses_comment")])
                    ]),
                    ("Eyes & Head", [
                        ("Fontanelle", visitRow[Expression<Int?>("pe_fontanelle_normal")], visitRow[Expression<String?>("pe_fontanelle_comment")]),
                        ("Pupils RR", visitRow[Expression<Int?>("pe_pupils_rr_normal")], visitRow[Expression<String?>("pe_pupils_rr_comment")]),
                        ("Ocular motility", visitRow[Expression<Int?>("pe_ocular_motility_normal")], visitRow[Expression<String?>("pe_ocular_motility_comment")]),
                        // Teeth belong to Eyes & Head group, with age gating and dependency on presence flag
                        ("Teeth present", visitRow[Expression<Int?>("pe_teeth_present")], visitRow[Expression<String?>("pe_teeth_comment")]),
                        ("Teeth count", visitRow[Expression<Int?>("pe_teeth_count")], nil)
                    ]),
                    ("Abdomen & Genitalia", [
                        ("Liver/Spleen", visitRow[Expression<Int?>("pe_liver_spleen_normal")], visitRow[Expression<String?>("pe_liver_spleen_comment")]),
                        ("Abdominal mass", visitRow[Expression<Int?>("pe_abd_mass")], nil),
                        ("Genitalia", visitRow[Expression<String?>("pe_genitalia")], nil),
                        ("Umbilic", visitRow[Expression<Int?>("pe_umbilic_normal")], visitRow[Expression<String?>("pe_umbilic_comment")]),
                        ("Testicles descended", visitRow[Expression<Int?>("pe_testicles_descended")], nil)
                    ]),
                    ("Skin", [
                        ("Marks", visitRow[Expression<Int?>("pe_skin_marks_normal")], visitRow[Expression<String?>("pe_skin_marks_comment")]),
                        ("Integrity", visitRow[Expression<Int?>("pe_skin_integrity_normal")], visitRow[Expression<String?>("pe_skin_integrity_comment")]),
                        ("Rash", visitRow[Expression<Int?>("pe_skin_rash_normal")], visitRow[Expression<String?>("pe_skin_rash_comment")])
                    ]),
                    ("MSK", [
                        ("Spine", visitRow[Expression<Int?>("pe_spine_normal")], visitRow[Expression<String?>("pe_spine_comment")]),
                        ("Hips", visitRow[Expression<Int?>("pe_hips_normal")], visitRow[Expression<String?>("pe_hips_comment")])
                    ])
                ]

                var foundPE = false

                for (groupName, fields) in peGroups {
                    var groupParts: [String] = []

                    for (label, rawValue, commentRaw) in fields {
                        // Sex gating: never show testicles for girls
                        if label == "Testicles descended", sexText != "M" {
                            continue
                        }

                        // Age gating rules – fail open if ageMonthsForPE is nil
                        if let ageMonths = ageMonthsForPE {
                            switch label {
                            case "Hips":
                                // Hips visible only up to 6 months
                                if ageMonths > 6.0 { continue }
                            case "Fontanelle":
                                // Fontanelle visible only up to 24 months
                                if ageMonths > 24.0 { continue }
                            case "Teeth present", "Teeth count":
                                // Teeth visible from 4 months onward
                                if ageMonths < 4.0 { continue }
                            default:
                                break
                            }
                        }

                        var displayValue: String?

                        switch rawValue {
                        case let b as Int:
                            if label == "Abdominal mass" {
                                // 0 == no mass, 1 == mass present
                                if b == 1 { displayValue = "yes" }
                                else if b == 0 { displayValue = "no" }
                            } else if label == "Teeth present" {
                                // Teeth present as yes/no
                                displayValue = (b == 1 ? "yes" : "no")
                            } else if label == "Testicles descended" {
                                // Testicles descended as yes/no
                                displayValue = (b == 1 ? "yes" : "no")
                            } else {
                                displayValue = yesNo(b)
                            }

                        case let s as String:
                            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                displayValue = s
                            }

                        case let optStr as Optional<String>:
                            if let s = optStr,
                               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                displayValue = s
                            }

                        case let optInt as Optional<Int>:
                            if let v = optInt {
                                if label == "Testicles descended" {
                                    // yes/no semantics for testicles descended
                                    displayValue = (v == 1 ? "yes" : "no")
                                } else if label == "Teeth present" {
                                    // yes/no semantics for teeth present
                                    displayValue = (v == 1 ? "yes" : "no")
                                } else if label == "Teeth count" {
                                    // Only show count if we know teeth are present
                                    let presentVal = visitRow[Expression<Int?>("pe_teeth_present")] ?? 0
                                    if presentVal == 1 {
                                        displayValue = "\(v)"
                                    }
                                } else if label == "Abdominal mass" {
                                    // yes/no semantics for abdominal mass
                                    displayValue = (v == 1 ? "yes" : "no")
                                } else {
                                    displayValue = "\(v)"
                                }
                            }

                        default:
                            break
                        }

                        if let result = displayValue {
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
                                if label == "Teeth present" {
                                    // Only attach comment if teeth are present
                                    let presentVal = visitRow[Expression<Int?>("pe_teeth_present")] ?? 0
                                    if presentVal == 1 {
                                        line += " (\(c))"
                                    }
                                } else if label == "Hips" {
                                    // Only attach comment if hips are abnormal
                                    let hipsNormalVal = visitRow[Expression<Int?>("pe_hips_normal")] ?? 1
                                    if hipsNormalVal == 0 {
                                        line += " (\(c))"
                                    }
                                } else if label == "Fontanelle" {
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
                        drawWrappedText(
                            "\(groupName): " + groupParts.joined(separator: "; "),
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
                    if let ageStr = formatAgeString(dobString: dobText,
                                                   visitDateString: visitDate,
                                                   ageDays: ageDaysDB) {
                        drawWrappedText("Healthy \(ageStr)", font: subFont, in: pageRect, at: &y, using: context)
                    } else {
                        drawWrappedText("Healthy", font: subFont, in: pageRect, at: &y, using: context)
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
                    drawText("\(lblNextVisitDate): \(nextVisit)", font: subFont)
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
                
                // MARK: - Growth Charts
                y += 12
                ensureSpace(for: 18)

                for (title, chartImage) in chartImagesToRender {
                    // Each chart gets its own fresh page
                    context.beginPage()
                    y = margin

                    // Draw chart title at top of page
                    drawText(title, font: UIFont.boldSystemFont(ofSize: 16))

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

    private static func formatDate(_ raw: Any) -> String {
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        inputFormatter.locale = Locale(identifier: "en_US_POSIX")

        let outputFormatter = DateFormatter()
        outputFormatter.dateStyle = .medium
        outputFormatter.timeStyle = .short

        if let dateString = raw as? String, let parsed = inputFormatter.date(from: dateString) {
            return outputFormatter.string(from: parsed)
        } else if let date = raw as? Date {
            return outputFormatter.string(from: date)
        } else {
            return "\(raw)"
        }
    }
}

