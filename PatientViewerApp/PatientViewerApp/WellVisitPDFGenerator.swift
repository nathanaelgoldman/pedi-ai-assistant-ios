import Foundation
import SQLite
import PDFKit
import UIKit
import OSLog
import CoreText

struct WellVisitPDFGenerator {
    private static let log = Logger(subsystem: "com.patientviewer.app", category: "pdf.well")
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

        // Visit type mapping for readable names
        let visitMap: [String: String] = [
            "one_month": "1-month visit",
            "two_month": "2-month visit",
            "four_month": "4-month visit",
            "six_month": "6-month visit",
            "nine_month": "9-month visit",
            "twelve_month": "12-month visit",
            "fifteen_month": "15-month visit",
            "eighteen_month": "18-month visit",
            "twentyfour_month": "24-month visit",
            "thirty_month": "30-month visit",
            "thirtysix_month": "36-month visit"
        ]

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

            // If misconfigured and visit is before DOB, clamp to 0 days
            if finalVisitDate < dobDate {
                return "0 days"
            }

            let calendar = Calendar(identifier: .gregorian)
            let components = calendar.dateComponents([.year, .month, .day], from: dobDate, to: finalVisitDate)

            let years = max(0, components.year ?? 0)
            let months = max(0, components.month ?? 0)
            let days = max(0, components.day ?? 0)

            // Before 1 month: show days
            if years == 0 && months == 0 {
                return "\(days) day" + (days == 1 ? "" : "s")
            }

            // From 1 month to 12 months: month + days
            if years == 0 && months >= 1 {
                let monthPart = months == 1 ? "1 month" : "\(months) months"
                if days > 0 {
                    let dayPart = days == 1 ? "1 day" : "\(days) days"
                    return "\(monthPart) \(dayPart)"
                } else {
                    return monthPart
                }
            }

            // From 12 months onward: years + months
            let yearPart = years == 1 ? "1 year" : "\(years) years"
            if months > 0 {
                let monthPart = months == 1 ? "1 month" : "\(months) months"
                return "\(yearPart) \(monthPart)"
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
        do {
            let db = try Connection(dbPath)
            let wellVisits = Table("well_visits")
            let visitID = Expression<Int64>("id")
            let patientID = Expression<Int64>("patient_id")
            let sex = Expression<String>("sex")
            guard let visitRow = try db.pluck(wellVisits.filter(visitID == visit.id)) else {
                // If visit not found, skip chart images
                return nil
            }
            let patients = Table("patients")
            let id = Expression<Int64>("id")
            pid = visitRow[patientID]
            if let patientRow = try db.pluck(patients.filter(id == pid)) {
                sexTextForCharts = patientRow[sex]
                WellVisitPDFGenerator.log.debug("Preloading growth charts for patient \(pid, privacy: .public) sex=\(sexTextForCharts, privacy: .public)")
            }
        } catch {
            WellVisitPDFGenerator.log.error("Failed to read patient/sex for charts: \(error.localizedDescription, privacy: .public)")
            sexTextForCharts = ""
        }
        if sexTextForCharts == "M" || sexTextForCharts == "F" {
            let chartTypes: [(String, String, String)] = [
                ("weight", "Weight-for-Age (0–24m)", "wfa_0_24m_\(sexTextForCharts)"),
                ("height", "Length-for-Age (0–24m)", "lhfa_0_24m_\(sexTextForCharts)"),
                ("head_circ", "Head Circumference-for-Age (0–24m)", "hcfa_0_24m_\(sexTextForCharts)")
            ]
            for (measurement, title, filename) in chartTypes {
                if let chartImage = await GrowthChartRenderer.generateChartImage(
                    dbPath: dbPath,
                    patientID: pid,
                    measurement: measurement,
                    sex: sexTextForCharts,
                    filename: filename
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

            drawText("Well Visit Report", font: titleFont)
            drawText("Report Generated: \(WellVisitPDFGenerator.formatDate(Date()))", font: subFont)

            let dbPath = dbURL.appendingPathComponent("db.sqlite").path
            WellVisitPDFGenerator.log.debug("Opening SQLite at path=\(dbPath, privacy: .public)")
            do {
                let db = try Connection(dbPath)

                // Lookup visit
                let wellVisits = Table("well_visits")
                let visitID = Expression<Int64>("id")
                guard let visitRow = try db.pluck(wellVisits.filter(visitID == visit.id)) else {
                    WellVisitPDFGenerator.log.error("Visit id \(visit.id, privacy: .public) not found in DB")
                    drawText("❌ Error: Visit not found", font: subFont)
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
                    drawText("❌ Error: Patient not found", font: subFont)
                    return
                }

                let name = "\(patientRow[firstName]) \(patientRow[lastName])"
                let aliasText = patientRow[alias] ?? "—"
                let dobText = patientRow[dob]
                let sexText = patientRow[sex]
                let mrnText = patientRow[mrn]
                WellVisitPDFGenerator.log.debug("Patient alias=\(aliasText, privacy: .public) name=\(name, privacy: .public) dob=\(dobText, privacy: .public) sex=\(sexText, privacy: .public)")

                let visitDate = visitRow[Expression<String>("visit_date")]
                let visitType = visitRow[Expression<String>("visit_type")]
                let ageDaysDB = visitRow[Expression<Int?>("age_days")]

                drawText("Alias: \(aliasText)", font: subFont)
                drawText("Name: \(name)", font: subFont)
                drawText("DOB: \(dobText)", font: subFont)
                drawText("Sex: \(sexText)", font: subFont)
                drawText("MRN: \(mrnText)", font: subFont)

                if let ageString = formatAgeString(dobString: dobText, visitDateString: visitDate, ageDays: ageDaysDB) {
                    drawText("Age at Visit: \(ageString)", font: subFont)
                } else if let ageDays = ageDaysDB, ageDays > 0 {
                    // Fallback: if age_days is somehow populated, at least show it
                    drawText("Age at Visit: \(ageDays) days", font: subFont)
                } else {
                    drawText("Age at Visit: —", font: subFont)
                }
                drawText("Visit Date: \(WellVisitPDFGenerator.formatDate(visitDate))", font: subFont)
                let visitTypeReadable = visitMap[visitType] ?? visitType
                drawText("Visit Type: \(visitTypeReadable)", font: subFont)

                let users = Table("users")
                let userID = Expression<Int64?>("user_id")
                let firstNameUser = Expression<String>("first_name")
                let lastNameUser = Expression<String>("last_name")

                // user_id may be NULL in the DB; handle that safely
                if let userIdVal = visitRow[userID] {
                    if let userRow = try? db.pluck(users.filter(Expression<Int64>("id") == userIdVal)) {
                        let clinicianName = "\(userRow[firstNameUser]) \(userRow[lastNameUser])"
                        drawText("Clinician: \(clinicianName)", font: subFont)
                    }
                } else {
                    // Optionally, you could show something here:
                    // drawText("Clinician: —", font: subFont)
                }
                
                // MARK: - Perinatal Summary
                y += 12
                drawText("Perinatal Summary", font: UIFont.boldSystemFont(ofSize: 16))

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

                if let peri = try? db.pluck(perinatal.filter(Expression<Int64>("patient_id") == pid)) {
                    var parts: [String] = []
                    if let v = try? peri.get(pregnancyRisk), !v.isEmpty { parts.append("Pregnancy: \(v)") }
                    if let v = try? peri.get(birthMode), !v.isEmpty { parts.append("Birth Mode: \(v)") }
                    if let v = try? peri.get(term) { parts.append("GA: \(v)") }
                    if let v = try? peri.get(resuscitation), !v.isEmpty { parts.append("Resuscitation: \(v)") }
                    if let v = try? peri.get(infectionRisk), !v.isEmpty { parts.append("Infection Risk: \(v)") }
                    if let v = try? peri.get(birthWeight) { parts.append("BW: \(v) g") }
                    if let v = try? peri.get(birthLength) { parts.append("BL: \(String(format: "%.1f", v)) cm") }
                    if let v = try? peri.get(headCirc) { parts.append("HC: \(String(format: "%.1f", v)) cm") }
                    if let v = try? peri.get(dischargeWeight) { parts.append("Discharge Wt: \(v) g") }
                    if let v = try? peri.get(feeding), !v.isEmpty { parts.append("Feeding: \(v)") }
                    if let v = try? peri.get(vaccinations), !v.isEmpty { parts.append("Vaccinations: \(v)") }
                    if let v = try? peri.get(events), !v.isEmpty { parts.append("Events: \(v)") }
                    if let v = try? peri.get(hearing), !v.isEmpty { parts.append("Hearing: \(v)") }
                    if let v = try? peri.get(heart), !v.isEmpty { parts.append("Heart: \(v)") }
                    if let v = try? peri.get(metabolic), !v.isEmpty { parts.append("Metabolic: \(v)") }
                    if let v = try? peri.get(afterBirth), !v.isEmpty { parts.append("After birth: \(v)") }
                    if let v = try? peri.get(motherVacc), !v.isEmpty { parts.append("Mother Vacc: \(v)") }

                    if !parts.isEmpty {
                        let summary = parts.joined(separator: "; ")
                        drawWrappedText(summary, font: subFont, in: pageRect, at: &y, using: context)
                    } else {
                        drawText("—", font: subFont)
                    }
                } else {
                    drawText("—", font: subFont)
                }

                // MARK: - Findings from Previous Well Visits
                y += 12
                drawText("Findings from Previous Well Visits", font: UIFont.boldSystemFont(ofSize: 16))

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
                    let vType = v[visitTypeCol]
                    let vTitle = visitMap[vType] ?? "Well Visit"
                    let vDate = v[visitDateCol]
                    let createdAt = v[visitCreatedAt]
                    let displayDate = vDate.isEmpty ? createdAt : vDate
                    let formattedDate = WellVisitPDFGenerator.formatDate(displayDate)
                    let findings = v[problemListing]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    drawText("\(vTitle) — \(formattedDate)", font: subFont)
                    if !findings.isEmpty {
                        drawWrappedText(findings.replacingOccurrences(of: "\n", with: "; "), font: subFont, in: pageRect, at: &y, using: context)
                    } else {
                        drawText("—", font: subFont)
                    }

                    y += 6
                }

                // MARK: - Current Visit Section
                y += 12
                ensureSpace(for: 20)
                drawText("Current Visit", font: UIFont.boldSystemFont(ofSize: 16))

                let visitTypeRaw = visitRow[Expression<String>("visit_type")]
                let visitTypeReadableCurrent = visitMap[visitTypeRaw] ?? "Well Visit"
                ensureSpace(for: 16)
                drawText(visitTypeReadableCurrent, font: UIFont.italicSystemFont(ofSize: 14))

                // Parents' Concerns
                y += 12
                ensureSpace(for: 18)
                drawText("Parents' Concerns", font: UIFont.boldSystemFont(ofSize: 15))
                let parentsConcerns = visitRow[Expression<String?>("parent_concerns")] ?? ""
                if !parentsConcerns.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    drawWrappedText(parentsConcerns, font: subFont, in: pageRect, at: &y, using: context)
                } else {
                    drawText("—", font: subFont)
                }

                // MARK: - Feeding Section
                y += 12
                ensureSpace(for: 18)
                drawText("Feeding", font: UIFont.boldSystemFont(ofSize: 15))

                var feedingLines: [String] = []

                // milk_types TEXT
                if let milkTypesRaw = visitRow[Expression<String?>("milk_types")] {
                    let milkTypes = milkTypesRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !milkTypes.isEmpty {
                        feedingLines.append("Milk: \(milkTypes)")
                    }
                }

                // feed_volume_ml REAL
                if let volume = visitRow[Expression<Double?>("feed_volume_ml")] {
                    feedingLines.append(String(format: "Typical feed volume: %.0f ml", volume))
                }

                // feed_freq_per_24h INTEGER
                if let freq = visitRow[Expression<Int?>("feed_freq_per_24h")] {
                    feedingLines.append("Feeds per 24h: \(freq) times")
                }

                // est_total_ml REAL
                if let total = visitRow[Expression<Double?>("est_total_ml")] {
                    feedingLines.append(String(format: "Estimated total intake: %.0f ml/24h", total))
                }

                // est_ml_per_kg_24h REAL
                if let perKg = visitRow[Expression<Double?>("est_ml_per_kg_24h")] {
                    feedingLines.append(String(format: "Estimated intake: %.0f ml/kg/24h", perKg))
                }

                // regurgitation INTEGER (boolean)
                if let reg = visitRow[Expression<Int?>("regurgitation")] {
                    // Only meaningful to report regurgitation in early infancy.
                    let ageDaysValue = visitRow[Expression<Int?>("age_days")]
                    if let ageMonths = computeAgeMonths(dobString: dobText,
                                                        visitDateString: visitDate,
                                                        ageDays: ageDaysValue),
                       ageMonths <= 4.0 {
                        let text = (reg == 1) ? "Yes" : "No"
                        feedingLines.append("Regurgitation: \(text)")
                    }
                }

                // feeding_issue TEXT
                if let issueRaw = visitRow[Expression<String?>("feeding_issue")] {
                    let issue = issueRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !issue.isEmpty {
                        feedingLines.append("Feeding issue: \(issue)")
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
                        let text = (solidStarted == 1) ? "Yes" : "No"
                        feedingLines.append("Solid foods started: \(text)")
                    }
                }

                // solid_food_start_date TEXT
                if let solidDateRaw = visitRow[Expression<String?>("solid_food_start_date")] {
                    let solidDate = solidDateRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !solidDate.isEmpty {
                        feedingLines.append("Solid foods since: \(solidDate)")
                    }
                }

                // solid_food_quality TEXT
                if let solidQualityRaw = visitRow[Expression<String?>("solid_food_quality")] {
                    let solidQuality = solidQualityRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !solidQuality.isEmpty {
                        let prettyQuality: String
                        switch solidQuality {
                        case "appears_good":
                            prettyQuality = "appears good"
                        case "probably_limited":
                            prettyQuality = "probably limited"
                        default:
                            prettyQuality = solidQuality
                        }
                        feedingLines.append("Solid food quality: \(prettyQuality)")
                    }
                }

                // solid_food_comment TEXT
                if let solidCommentRaw = visitRow[Expression<String?>("solid_food_comment")] {
                    let solidComment = solidCommentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !solidComment.isEmpty {
                        feedingLines.append("Solid food comment: \(solidComment)")
                    }
                }

                // food_variety_quality TEXT
                if let varietyRaw = visitRow[Expression<String?>("food_variety_quality")] {
                    let variety = varietyRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !variety.isEmpty {
                        let prettyVariety: String
                        if variety == "appears_good" {
                            prettyVariety = "appears good"
                        } else {
                            prettyVariety = variety
                        }
                        feedingLines.append("Food variety / quantity: \(prettyVariety)")
                    }
                }

                // dairy_amount_text TEXT
                if let dairyRaw = visitRow[Expression<String?>("dairy_amount_text")] {
                    let dairy = dairyRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !dairy.isEmpty {
                        feedingLines.append("Dairy intake daily: \(dairy) cup(s) or bottle(s)")
                    }
                }

                // feeding_comment TEXT
                if let commentRaw = visitRow[Expression<String?>("feeding_comment")] {
                    let comment = commentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !comment.isEmpty {
                        feedingLines.append("Comment: \(comment)")
                    }
                }

                if feedingLines.isEmpty {
                    drawText("—", font: UIFont.italicSystemFont(ofSize: 14))
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
                drawText("Supplementation", font: UIFont.boldSystemFont(ofSize: 15))

                let vitaminDGiven = visitRow[Expression<Int?>("vitamin_d_given")]
                if let val = vitaminDGiven {
                    if val == 1 {
                        drawText("Vitamin D Given: Yes", font: UIFont.italicSystemFont(ofSize: 14))
                    } else if val == 0 {
                        drawText("Vitamin D Given: No", font: UIFont.italicSystemFont(ofSize: 14))
                    }
                    // If other values are stored, we silently ignore them for now.
                } else {
                    // No supplementation info recorded for this visit; omit the line.
                }

                // MARK: - Stools
                y += 12
                ensureSpace(for: 18)
                drawText("Stools", font: UIFont.boldSystemFont(ofSize: 15))

                let poopStatusExp = Expression<String?>("poop_status")
                let poopCommentExp = Expression<String?>("poop_comment")

                var stoolLines: [String] = []

                if let statusRaw = visitRow[poopStatusExp] {
                    let status = statusRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !status.isEmpty {
                        stoolLines.append("Stool pattern: \(status)")
                    }
                }

                if let commentRaw = visitRow[poopCommentExp] {
                    let comment = commentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !comment.isEmpty {
                        stoolLines.append("Comment: \(comment)")
                    }
                }

                if stoolLines.isEmpty {
                    drawText("—", font: UIFont.italicSystemFont(ofSize: 14))
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
                            return "\(first) to \(second) hours"
                        }
                    }
                    return trimmed
                }

                // MARK: - Sleep Section
                y += 12
                ensureSpace(for: 18)
                drawText("Sleep", font: UIFont.boldSystemFont(ofSize: 15))

                var sleepLines: [String] = []

                // 1. Sleep duration (pretty-printed, e.g. "10_15" -> "10 to 15 hours")
                if let durationRaw = visitRow[Expression<String?>("sleep_hours_text")] {
                    let durationTrimmed = durationRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !durationTrimmed.isEmpty {
                        let pretty = prettySleepDuration(durationTrimmed)
                        sleepLines.append("Sleep duration: \(pretty)")
                    }
                }

                // 2. Sleep regularity (free text)
                if let regularRaw = visitRow[Expression<String?>("sleep_regular")] {
                    let regular = regularRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !regular.isEmpty {
                        sleepLines.append("Sleep regularity: \(regular)")
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
                        let text = (snoreVal == 1) ? "Yes" : "No"
                        sleepLines.append("Snoring: \(text)")
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
                        sleepLines.append("Sleep issue reported: Yes")
                    } else {
                        sleepLines.append("Sleep issue reported: Yes – \(issueText)")
                    }
                } else {
                    // Explicitly document absence of reported issues
                    sleepLines.append("Sleep issue reported: No")
                }

                if sleepLines.isEmpty {
                    drawText("—", font: UIFont.italicSystemFont(ofSize: 14))
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
                drawText("Development & Milestones", font: UIFont.boldSystemFont(ofSize: 15))

                // Age in months for gating dev test and M-CHAT
                let ageDaysValueForDev = visitRow[Expression<Int?>("age_days")]
                let ageMonthsForDev = computeAgeMonths(
                    dobString: dobText,
                    visitDateString: visitDate,
                    ageDays: ageDaysValueForDev
                )

                // Developmental test (devtest_*), shown from 9 to 36 months
                let devTestScore = visitRow[Expression<Int?>("devtest_score")]
                let devResult = visitRow[Expression<String?>("devtest_result")] ?? ""

                if let ageMonths = ageMonthsForDev,
                   ageMonths >= 9.0, ageMonths <= 36.0 {
                    if let score = devTestScore {
                        let trimmedResult = devResult.trimmingCharacters(in: .whitespacesAndNewlines)
                        var devString: String
                        if !trimmedResult.isEmpty {
                            devString = "Developmental test: \(trimmedResult) (score \(score))"
                        } else {
                            devString = "Developmental test score: \(score)"
                        }
                        ensureSpace(for: 16)
                        drawWrappedText(devString, font: subFont, in: pageRect, at: &y, using: context)
                    } else {
                        let trimmedResult = devResult.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedResult.isEmpty {
                            ensureSpace(for: 16)
                            drawWrappedText("Developmental test: \(trimmedResult)", font: subFont, in: pageRect, at: &y, using: context)
                        }
                    }
                }

                // M-CHAT (mchat_*), shown from 18 to 30 months
                let mchatScore = visitRow[Expression<Int?>("mchat_score")]
                let mchatResult = visitRow[Expression<String?>("mchat_result")] ?? ""

                if let ageMonths = ageMonthsForDev,
                   ageMonths >= 18.0, ageMonths <= 30.0 {
                    if let score = mchatScore {
                        let trimmed = mchatResult.trimmingCharacters(in: .whitespacesAndNewlines)
                        var mchatLine: String
                        if !trimmed.isEmpty {
                            mchatLine = "M-CHAT: \(trimmed) (score \(score))"
                        } else {
                            mchatLine = "M-CHAT score: \(score)"
                        }
                        ensureSpace(for: 16)
                        drawWrappedText(mchatLine, font: subFont, in: pageRect, at: &y, using: context)
                    } else {
                        let trimmed = mchatResult.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            ensureSpace(for: 16)
                            drawWrappedText("M-CHAT: \(trimmed)", font: subFont, in: pageRect, at: &y, using: context)
                        }
                    }
                }

                // Milestones summary (from well_visit_milestones)
                y += 12
                ensureSpace(for: 18)

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
                            flags.append("\(itemLabel): \(stat)")
                        }
                    }
                }

                if totalCount > 0 {
                    drawText("Achieved: \(achievedCount)/\(totalCount)", font: subFont)
                } else {
                    drawText("Achieved: —", font: subFont)
                }

                if !flags.isEmpty {
                    drawText("Flags:", font: subFont)
                    for item in flags {
                        drawWrappedText("- \(item)", font: subFont, in: pageRect, at: &y, using: context)
                    }
                } else {
                    drawText("Flags: —", font: subFont)
                }
                
                // MARK: - Measurements
                y += 12
                ensureSpace(for: 18)
                drawText("Measurements", font: UIFont.boldSystemFont(ofSize: 15))

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
                    drawText("—", font: UIFont.italicSystemFont(ofSize: 14))
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
                drawText("Physical Examination", font: UIFont.boldSystemFont(ofSize: 15))

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
                        ("Ocular motility", visitRow[Expression<Int?>("pe_ocular_motility_normal")], visitRow[Expression<String?>("pe_ocular_motility_comment")])
                    ]),
                    ("Abdomen & Genitalia", [
                        ("Liver/Spleen", visitRow[Expression<Int?>("pe_liver_spleen_normal")], visitRow[Expression<String?>("pe_liver_spleen_comment")]),
                        ("Abdominal mass", visitRow[Expression<Int?>("pe_abd_mass")], nil),
                        ("Genitalia", visitRow[Expression<String?>("pe_genitalia")], nil),
                        ("Umbilic", visitRow[Expression<Int?>("pe_umbilic_normal")], visitRow[Expression<String?>("pe_umbilic_comment")]),
                        ("Testicles descended", testicleStatus(visitRow[Expression<Int?>("pe_testicles_descended")]), nil)
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
                        var displayValue: String?

                        switch rawValue {
                        case let b as Int:
                            displayValue = yesNo(b)
                        case let s as String:
                            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                displayValue = s
                            }
                        case let s as Optional<String>:
                            if let s = s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                displayValue = s
                            }
                        case let s as Optional<Int>:
                            if label == "Testicles descended" {
                                displayValue = s.flatMap(testicleStatus)
                            } else {
                                displayValue = s != nil ? "\(s!)" : nil
                            }
                        default:
                            break
                        }

                        if let result = displayValue {
                            var line = "\(label): \(result)"
                            if let c = commentRaw as? String, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                line += " (\(c))"
                            }
                            groupParts.append(line)
                        }
                    }

                    if !groupParts.isEmpty {
                        foundPE = true
                        drawWrappedText("\(groupName): " + groupParts.joined(separator: "; "), font: subFont, in: pageRect, at: &y, using: context)
                    }
                }

                if !foundPE {
                    drawText("No physical exam findings recorded.", font: subFont)
                }
                
                // MARK: - Problem Listing
                y += 12
                ensureSpace(for: 18)
                drawText("Problem Listing", font: UIFont.boldSystemFont(ofSize: 15))

                let problems = visitRow[Expression<String?>("problem_listing")] ?? ""
                if !problems.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    drawWrappedText(problems, font: subFont, in: pageRect, at: &y, using: context)
                } else {
                    drawText("—", font: subFont)
                }
                
                // MARK: - Conclusions
                y += 12
                ensureSpace(for: 18)
                drawText("Conclusions", font: UIFont.boldSystemFont(ofSize: 15))
                let conclusions = visitRow[Expression<String?>("conclusions")] ?? ""
                if !conclusions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    drawWrappedText(conclusions, font: subFont, in: pageRect, at: &y, using: context)
                } else {
                    drawText("No conclusions documented.", font: subFont)
                }

                // MARK: - Anticipatory Guidance
                y += 12
                ensureSpace(for: 18)
                drawText("Anticipatory Guidance", font: UIFont.boldSystemFont(ofSize: 15))
                let guidance = visitRow[Expression<String?>("anticipatory_guidance")] ?? ""
                if !guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    drawWrappedText(guidance, font: subFont, in: pageRect, at: &y, using: context)
                } else {
                    drawText("No anticipatory guidance provided.", font: subFont)
                }

               

                // MARK: - Clinician Comments
                y += 12
                ensureSpace(for: 18)
                drawText("Clinician Comments", font: UIFont.boldSystemFont(ofSize: 15))
                let comments = visitRow[Expression<String?>("comments")] ?? ""
                if !comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    drawWrappedText(comments, font: subFont, in: pageRect, at: &y, using: context)
                } else {
                    drawText("No clinician comments recorded.", font: subFont)
                }

                // MARK: - Next Visit Date (optional)
                y += 12
                ensureSpace(for: 18)
                let nextVisit = visitRow[Expression<String?>("next_visit_date")] ?? ""
                if !nextVisit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    drawText("Next Visit Date: \(nextVisit)", font: subFont)
                }
                
                // MARK: - Growth Charts
                y += 12
                ensureSpace(for: 18)
                for (title, chartImage) in chartImagesToRender {
                    context.beginPage()

                    // Draw chart title
                    drawText(title, font: UIFont.boldSystemFont(ofSize: 16))

                    // Validate image size to avoid NaN aspect ratios
                    guard chartImage.size.width > 0, chartImage.size.height > 0 else {
                        WellVisitPDFGenerator.log.warning("Skipping chart '\(title, privacy: .public)' due to invalid size w=\(chartImage.size.width, privacy: .public) h=\(chartImage.size.height, privacy: .public)")
                        continue
                    }

                    // Set available drawing space to nearly full page
                    let maxWidth = pageWidth - 2 * margin
                    let maxHeight = pageHeight - 2 * margin

                    // Maintain aspect ratio
                    let aspectRatio = chartImage.size.width / chartImage.size.height
                    var targetWidth = maxWidth
                    var targetHeight = maxWidth / aspectRatio

                    // If height exceeds max, scale down to fit height
                    if targetHeight > maxHeight {
                        targetHeight = maxHeight
                        targetWidth = maxHeight * aspectRatio
                    }

                    // Center image on page
                    let imageX = (pageWidth - targetWidth) / 2
                    let imageY = (pageHeight - targetHeight) / 2  // Center vertically

                    let imageRect = CGRect(x: imageX, y: imageY, width: targetWidth, height: targetHeight)
                    chartImage.draw(in: imageRect)
                }

            } catch {
                WellVisitPDFGenerator.log.error("DB error during PDF render: \(error.localizedDescription, privacy: .public)")
                drawText("❌ DB Error: \(error.localizedDescription)", font: subFont)
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
}//
//  WellVisitPdfGenerator.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/11/25.
//

