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
                let ageDays = visitRow[Expression<Int?>("age_days")] ?? 0

                drawText("Alias: \(aliasText)", font: subFont)
                drawText("Name: \(name)", font: subFont)
                drawText("DOB: \(dobText)", font: subFont)
                drawText("Sex: \(sexText)", font: subFont)
                drawText("MRN: \(mrnText)", font: subFont)
                drawText("Age at Visit: \(ageDays) days", font: subFont)
                drawText("Visit Date: \(WellVisitPDFGenerator.formatDate(visitDate))", font: subFont)
                let visitTypeReadable = visitMap[visitType] ?? visitType
                drawText("Visit Type: \(visitTypeReadable)", font: subFont)

                let users = Table("users")
                let userID = Expression<Int64>("user_id")
                let userIdVal = visitRow[userID]
                let firstNameUser = Expression<String>("first_name")
                let lastNameUser = Expression<String>("last_name")

                if let userRow = try? db.pluck(users.filter(Expression<Int64>("id") == userIdVal)) {
                    let clinicianName = "\(userRow[firstNameUser]) \(userRow[lastNameUser])"
                    drawText("Clinician: \(clinicianName)", font: subFont)
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

                let feedingFields: [(String, Any?)] = [
                    ("Feeding Comment", visitRow[Expression<String?>("feeding_comment")]),
                    ("Milk Types", visitRow[Expression<String?>("milk_types")]),
                    ("Feeds / 24h", visitRow[Expression<Int?>("feed_freq_per_24h")]),
                    ("Regurgitation", visitRow[Expression<Int?>("regurgitation")]),
                    ("Wakes for Feeds", visitRow[Expression<Int?>("wakes_for_feeds")]),
                    ("Food Variety / Quantity", visitRow[Expression<String?>("food_variety_quality")]),
                    ("Dairy Amount", visitRow[Expression<String?>("dairy_amount_text")])
                ]

                for (label, rawValue) in feedingFields {
                    ensureSpace(for: 16)
                    var display: String? = nil

                    if let s = rawValue as? String {
                        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { display = trimmed }
                    } else if let i = rawValue as? Int {
                        // interpret booleans and numeric counts
                        let booleanFields = Set(["Regurgitation", "Wakes for Feeds"])
                        if booleanFields.contains(label) {
                            display = (i == 1) ? "Yes" : "No"
                        } else {
                            display = "\(i)"
                        }
                    } else if let d = rawValue as? Double {
                        display = String(format: "%g", d)
                    }

                    if let v = display, !v.isEmpty {
                        drawWrappedText("\(label): \(v)", font: subFont, in: pageRect, at: &y, using: context)
                    } else {
                        drawText("\(label): —", font: UIFont.italicSystemFont(ofSize: 14))
                    }
                    y += 2
                }

                // Supplementation Section
                y += 12
                ensureSpace(for: 18)
                drawText("Supplementation", font: UIFont.boldSystemFont(ofSize: 15))

                let vitaminDGiven = visitRow[Expression<Int?>("vitamin_d_given")] ?? -1
                if vitaminDGiven == 1 {
                    drawText("Vitamin D Given: Yes", font: UIFont.italicSystemFont(ofSize: 14))
                } else if vitaminDGiven == 0 {
                    drawText("Vitamin D Given: No", font: UIFont.italicSystemFont(ofSize: 14))
                } else {
                    drawText("Vitamin D Given: —", font: UIFont.italicSystemFont(ofSize: 14))
                }

                // MARK: - Sleep Section
                y += 12
                ensureSpace(for: 18)
                drawText("Sleep", font: UIFont.boldSystemFont(ofSize: 15))

                let sleepFields: [(String, Any?)] = [
                    ("Sleep Duration", visitRow[Expression<String?>("sleep_hours_text")]),
                    ("Sleep Regularity", visitRow[Expression<String?>("sleep_regular")]),
                    ("Snoring", visitRow[Expression<Int?>("sleep_snoring")]),
                    ("Sleep Issue Reported", visitRow[Expression<Int?>("sleep_issue_reported")])
                ]

                for (label, rawValue) in sleepFields {
                    ensureSpace(for: 16)
                    var display: String? = nil

                    if let s = rawValue as? String {
                        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { display = trimmed }
                    } else if let i = rawValue as? Int {
                        let booleanFields = Set(["Snoring", "Sleep Issue Reported"])
                        if booleanFields.contains(label) {
                            display = (i == 1) ? "Yes" : "No"
                        } else {
                            display = "\(i)"
                        }
                    } else if let d = rawValue as? Double {
                        display = String(format: "%g", d)
                    }

                    if let v = display, !v.isEmpty {
                        drawWrappedText("\(label): \(v)", font: subFont, in: pageRect, at: &y, using: context)
                    } else {
                        drawText("\(label): —", font: UIFont.italicSystemFont(ofSize: 14))
                    }
                    y += 2
                }

                // Developmental Evaluation
                y += 12
                ensureSpace(for: 18)
                drawText("Developmental Evaluation", font: UIFont.boldSystemFont(ofSize: 15))

                let devTestScore = visitRow[Expression<Int?>("devtest_score")]
                let devResult = visitRow[Expression<String?>("devtest_result")] ?? ""

                if let score = devTestScore {
                    var devString: String
                    if !devResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        devString = "Developmental test: \(devResult) (score \(score))"
                    } else {
                        devString = "Developmental test score: \(score)"
                    }
                    drawWrappedText(devString, font: subFont, in: pageRect, at: &y, using: context)
                } else if !devResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    drawWrappedText("Developmental test: \(devResult)", font: subFont, in: pageRect, at: &y, using: context)
                } else {
                    drawText("—", font: subFont)
                }
                // MARK: - M-CHAT Screening
                let mchatScore = visitRow[Expression<Int?>("mchat_score")]
                let mchatResult = visitRow[Expression<String?>("mchat_result")] ?? ""

                if let score = mchatScore {
                    var mchatLine: String
                    if !mchatResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        mchatLine = "M-CHAT: \(mchatResult) (score \(score))"
                    } else {
                        mchatLine = "M-CHAT score: \(score)"
                    }
                    drawWrappedText(mchatLine, font: subFont, in: pageRect, at: &y, using: context)
                } else if !mchatResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    drawWrappedText("M-CHAT: \(mchatResult)", font: subFont, in: pageRect, at: &y, using: context)
                }

                // MARK: - Age-specific Milestones
                y += 12
                ensureSpace(for: 18)
                drawText("Age-specific Milestones", font: UIFont.boldSystemFont(ofSize: 15))

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

                // 1. Today's weight (kg)
                if let wt = visitRow[Expression<Double?>("weight_today_kg")] {
                    drawText("Today's weight (kg): \(String(format: "%.2f", wt))", font: subFont)
                }

                // 2. Weight gain since discharge
                let deltaWeight = visitRow[Expression<Int?>("delta_weight_g")]
                let deltaDays = visitRow[Expression<Int?>("delta_days_since_discharge")]
                if let dw = deltaWeight, let dd = deltaDays, dd > 0 {
                    let dailyGain = Double(dw) / Double(dd)
                    let line = String(format: "Weight gain since discharge: %.1f g/day (Δ +%d g over %d days)", dailyGain, dw, dd)
                    drawWrappedText(line, font: subFont, in: pageRect, at: &y, using: context)
                }

                // 3. Length and Head Circumference
                if let length = visitRow[Expression<Double?>("length_today_cm")] {
                    drawText("Today's length (cm): \(String(format: "%.1f", length))", font: subFont)
                }
                if let hc = visitRow[Expression<Double?>("head_circ_today_cm")] {
                    drawText("Today's head circumference (cm): \(String(format: "%.1f", hc))", font: subFont)
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

