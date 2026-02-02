
import Foundation
import SQLite
import PDFKit
import UIKit
import OSLog
import CoreText

// MARK: - Localization helpers (PDF uses String, not LocalizedStringKey)
private func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

private func LF(_ formatKey: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(formatKey, comment: ""), arguments: args)
}

struct SickVisitPDFGenerator {
    private static let log = AppLog.feature("pdf.sick")
    static func generate(for visit: VisitSummary, dbURL: URL) -> URL? {
        Self.log.log("Generating SickVisit PDF for id=\(visit.id, privacy: .public) db=\(dbURL.path, privacy: .private)")
        let pdfMetaData = [
            kCGPDFContextCreator: L("pdf.meta.creator"),
            kCGPDFContextAuthor: L("pdf.meta.author"),
            kCGPDFContextTitle: L("pdf.sick.title")
        ]
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = pdfMetaData as [String: Any]

        let pageWidth = 595.2
        let pageHeight = 841.8
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        Self.log.debug("PDF renderer created with pageRect=\(String(describing: pageRect))")

        let margin: CGFloat = 40
        let contentWidth = pageWidth - 2 * margin

        // Helper to ensure enough space on the current PDF page
        func ensureSpace(for height: CGFloat) {
            // This is a placeholder; the actual implementation is inside the renderer.pdfData closure.
            // The actual function will be shadowed/overwritten in the closure below,
            // but this declaration is needed for drawWrappedText's scope.
        }

        // Helper to format age string, mirroring WellVisitPDFGenerator logic (without ageDays param)
        func formatAgeString(dobString: String, visitDateString: String) -> String? {
            let dobFormatter = DateFormatter()
            dobFormatter.dateFormat = "yyyy-MM-dd"
            dobFormatter.locale = Locale(identifier: "en_US_POSIX")
            guard let dobDate = dobFormatter.date(from: dobString) else {
                SickVisitPDFGenerator.log.warning("formatAgeString: unable to parse DOB='\(dobString)'")
                return nil
            }
            var visitDate: Date? = nil
            // Try ISO8601 with fractional seconds
            let iso1 = ISO8601DateFormatter()
            iso1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            visitDate = iso1.date(from: visitDateString)
            if visitDate == nil {
                // Try ISO8601 without fractional seconds
                let iso2 = ISO8601DateFormatter()
                iso2.formatOptions = [.withInternetDateTime]
                visitDate = iso2.date(from: visitDateString)
            }
            if visitDate == nil {
                // Try "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
                let df1 = DateFormatter()
                df1.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
                df1.locale = Locale(identifier: "en_US_POSIX")
                visitDate = df1.date(from: visitDateString)
            }
            if visitDate == nil {
                // Try "yyyy-MM-dd"
                let df2 = DateFormatter()
                df2.dateFormat = "yyyy-MM-dd"
                df2.locale = Locale(identifier: "en_US_POSIX")
                visitDate = df2.date(from: visitDateString)
            }
            guard let visit = visitDate else {
                SickVisitPDFGenerator.log.warning("formatAgeString: unable to parse visitDate='\(visitDateString)'")
                return nil
            }
            let calendar = Calendar(identifier: .gregorian)
            let components = calendar.dateComponents([.year, .month, .day], from: dobDate, to: visit)
            let years = max(0, components.year ?? 0)
            let months = max(0, components.month ?? 0)
            let days = max(0, components.day ?? 0)
            if years == 0 && months == 0 {
                return days == 1 ? L("age.day.one") : LF("age.days.fmt", days)
            } else if years == 0 && months >= 1 {
                let monthPart = months == 1 ? L("age.month.one") : LF("age.months.fmt", months)
                if days > 0 {
                    let dayPart = days == 1 ? L("age.day.one") : LF("age.days.fmt", days)
                    return LF("age.compound.fmt", monthPart, dayPart)
                } else {
                    return monthPart
                }
            } else if years >= 1 {
                let yearPart = years == 1 ? L("age.year.one") : LF("age.years.fmt", years)
                if months > 0 {
                    let monthPart = months == 1 ? L("age.month.one") : LF("age.months.fmt", months)
                    return LF("age.compound.fmt", yearPart, monthPart)
                } else {
                    return yearPart
                }
            }
            return nil
        }

        // Helper to compute age in months from DOB and visit date
        func computeAgeMonths(dobString: String, visitDateString: String) -> Double? {
            let dobFormatter = DateFormatter()
            dobFormatter.dateFormat = "yyyy-MM-dd"
            dobFormatter.locale = Locale(identifier: "en_US_POSIX")

            guard let dobDate = dobFormatter.date(from: dobString) else {
                SickVisitPDFGenerator.log.warning("computeAgeMonths: unable to parse DOB (token=\(AppLog.token(dobString), privacy: .public))")
                return nil
            }

            var visitDate: Date? = nil

            // Try ISO8601 with fractional seconds
            let iso1 = ISO8601DateFormatter()
            iso1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            visitDate = iso1.date(from: visitDateString)

            if visitDate == nil {
                // Try ISO8601 without fractional seconds
                let iso2 = ISO8601DateFormatter()
                iso2.formatOptions = [.withInternetDateTime]
                visitDate = iso2.date(from: visitDateString)
            }

            if visitDate == nil {
                // Try "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
                let df1 = DateFormatter()
                df1.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
                df1.locale = Locale(identifier: "en_US_POSIX")
                visitDate = df1.date(from: visitDateString)
            }

            if visitDate == nil {
                // Try plain date-only format
                let df2 = DateFormatter()
                df2.dateFormat = "yyyy-MM-dd"
                df2.locale = Locale(identifier: "en_US_POSIX")
                visitDate = df2.date(from: visitDateString)
            }

            guard let finalVisitDate = visitDate else {
                SickVisitPDFGenerator.log.warning("computeAgeMonths: unable to parse visitDate (token=\(AppLog.token(visitDateString), privacy: .public))")
                return nil
            }

            let interval = finalVisitDate.timeIntervalSince(dobDate)
            let days = interval / 86_400.0
            if days < 0 {
                SickVisitPDFGenerator.log.warning(
                    "computeAgeMonths: negative age days=\(days) for DOB(token=\(AppLog.token(dobString), privacy: .public)) visit(token=\(AppLog.token(visitDateString), privacy: .public))"
                )
            }
            return max(0.0, days / 30.0)
        }

        // Helper to draw wrapped attributed text (multi-page, clean margins)
        func drawWrappedAttributedText(_ attributedText: NSAttributedString, in rect: CGRect, at y: inout CGFloat, using rendererContext: UIGraphicsPDFRendererContext) {
            let framesetter = CTFramesetterCreateWithAttributedString(attributedText as CFAttributedString)
            var currentRange = CFRange(location: 0, length: 0)

            repeat {
                // Always compute availableHeight based on y, but reset y before calculation if starting a new page
                var availableHeight = rect.height - y - margin
                if availableHeight < 24 { // small safety floor
                    rendererContext.beginPage()
                    y = margin
                    availableHeight = rect.height - y - margin
                }

                // UIKit coordinates: y origin is at bottom, so use rect.height - y - availableHeight
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

                // Advance y by the height of the drawn portion
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

        // Helper to draw wrapped text for long lines (e.g., PE section), supporting multi-page and clean margins
        func drawWrappedText(_ text: String, font: UIFont, in rect: CGRect, at y: inout CGFloat, using rendererContext: UIGraphicsPDFRendererContext) {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraphStyle
            ]

            let attributed = NSAttributedString(string: text, attributes: attributes)
            drawWrappedAttributedText(attributed, in: rect, at: &y, using: rendererContext)
        }

        // Helper to draw wrapped text while preserving paragraph breaks (better for AI output)
        func drawWrappedTextRich(_ text: String, font: UIFont, in rect: CGRect, at y: inout CGFloat, using rendererContext: UIGraphicsPDFRendererContext) {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping
            paragraphStyle.lineSpacing = 2
            paragraphStyle.paragraphSpacing = 6

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraphStyle
            ]

            let attributed = NSAttributedString(string: text, attributes: attributes)
            drawWrappedAttributedText(attributed, in: rect, at: &y, using: rendererContext)
        }

        let data = renderer.pdfData { (rendererContext) in
            rendererContext.beginPage()
            var y: CGFloat = margin

            func ensureSpace(for height: CGFloat) {
                if y + height > pageRect.maxY - margin {
                    rendererContext.beginPage()
                    y = margin
                }
            }

            func drawText(_ text: String, font: UIFont, offset: CGFloat = margin) {
                let attributes: [NSAttributedString.Key: Any] = [.font: font]
                let attrString = NSAttributedString(string: text, attributes: attributes)

                let boundingBox = attrString.boundingRect(
                    with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
                let needed = ceil(boundingBox.height)
                ensureSpace(for: needed)
                let textRect = CGRect(x: offset, y: y, width: contentWidth, height: needed)
                attrString.draw(in: textRect)
                y += needed + 6
            }

            let titleFont = UIFont.boldSystemFont(ofSize: 20)
            let subFont = UIFont.systemFont(ofSize: 14)

            // --- Styling colors (match WellVisitPDFGenerator look) ---
            let titleBG   = UIColor(red: 0.18, green: 0.45, blue: 0.80, alpha: 1.0) // darker blue
            let sectionBG = UIColor(red: 0.88, green: 0.94, blue: 1.00, alpha: 1.0) // pale blue

            func drawHeaderBox(
                _ text: String,
                font: UIFont,
                background: UIColor,
                textColor: UIColor,
                cornerRadius: CGFloat = 8,
                paddingX: CGFloat = 10,
                paddingY: CGFloat = 6
            ) {
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.lineBreakMode = .byWordWrapping

                let attr = NSAttributedString(
                    string: text,
                    attributes: [
                        .font: font,
                        .foregroundColor: textColor,
                        .paragraphStyle: paragraphStyle
                    ]
                )

                let maxTextWidth = contentWidth - 2 * paddingX
                let bb = attr.boundingRect(
                    with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )

                let boxHeight = ceil(bb.height) + 2 * paddingY
                ensureSpace(for: boxHeight)

                let boxRect = CGRect(x: margin, y: y, width: contentWidth, height: boxHeight)
                let path = UIBezierPath(roundedRect: boxRect, cornerRadius: cornerRadius)
                rendererContext.cgContext.saveGState()
                rendererContext.cgContext.setFillColor(background.cgColor)
                rendererContext.cgContext.addPath(path.cgPath)
                rendererContext.cgContext.fillPath()
                rendererContext.cgContext.restoreGState()

                let textRect = CGRect(
                    x: boxRect.minX + paddingX,
                    y: boxRect.minY + paddingY,
                    width: contentWidth - 2 * paddingX,
                    height: ceil(bb.height)
                )
                attr.draw(in: textRect)

                y += boxHeight + 10
            }

            func drawSectionHeader(_ key: String) {
                drawHeaderBox(L(key), font: UIFont.boldSystemFont(ofSize: 16), background: sectionBG, textColor: .black)
            }

            // Title
            drawHeaderBox(L("pdf.sick.title"), font: titleFont, background: titleBG, textColor: .white, cornerRadius: 10, paddingX: 12, paddingY: 8)

            // Visit date
            let formattedVisitDate = formatDate(visit.date)
            drawText(LF("pdf.sick.visitDate.fmt", formattedVisitDate), font: subFont)
            drawText(LF("pdf.sick.generated.fmt", formatDate(Date())), font: subFont)

            // Fetch patient info
            let dbPath = dbURL.appendingPathComponent("db.sqlite").path
            do {
                let dbFileURL = dbURL.appendingPathComponent("db.sqlite")
                Self.log.debug("Opening SQLite | db=\(AppLog.dbRef(dbFileURL), privacy: .public)")

                let db = try Connection(dbFileURL.path)

                let episodes = Table("episodes")
                let episodeID = Expression<Int64>("id")
                let patientID = Expression<Int64>("patient_id")
                let episodeUserID = Expression<Int64?>("user_id")

                // 1. Get patient_id for this visit (episode)
                guard let episodeRow = try db.pluck(episodes.filter(episodeID == visit.id)) else {
                    Self.log.error("Episode \(visit.id, privacy: .public) not found in 'episodes' table.")
                    drawText(L("pdf.sick.error.episodeNotFound"), font: subFont)
                    return
                }

                let pid = episodeRow[patientID]

                // 2. Get patient details
                let patients = Table("patients")
                let id = Expression<Int64>("id")
                let firstName = Expression<String>("first_name")
                let lastName = Expression<String>("last_name")
                let dob = Expression<String>("dob")
                let sex = Expression<String>("sex")
                let mrn = Expression<String>("mrn")
                let alias = Expression<String?>("alias_label")
                
                let users = Table("users")
                let userPK = Expression<Int64>("id")
                let firstNameUser = Expression<String>("first_name")
                let lastNameUser = Expression<String>("last_name")

                guard let patientRow = try db.pluck(patients.filter(id == pid)) else {
                    Self.log.error("Patient id=\(pid, privacy: .public) not found in 'patients' table.")
                    drawText(L("pdf.sick.error.patientNotFound"), font: subFont)
                    return
                }

                let aliasText = patientRow[alias] ?? L("common.placeholder")
                let name = "\(patientRow[firstName]) \(patientRow[lastName])"
                let dobText = patientRow[dob]
                let sexText = patientRow[sex]
                let mrnText = patientRow[mrn]

                let ageMonthsForVisit = computeAgeMonths(dobString: dobText, visitDateString: visit.date)
                let aliasRef = (aliasText == L("common.placeholder")) ? "ALIAS#nil" : AppLog.aliasRef(aliasText)
                Self.log.debug("Patient loaded | pid=\(pid, privacy: .private) alias=\(aliasRef, privacy: .public)")

                // 3. Render
                y += 12
                drawSectionHeader("pdf.sick.section.patientInfo")
                drawText(LF("pdf.sick.labelValue.fmt", L("pdf.sick.patient.alias"), aliasText), font: subFont)
                drawText(LF("pdf.sick.labelValue.fmt", L("pdf.sick.patient.name"), name), font: subFont)
                drawText(LF("pdf.sick.labelValue.fmt", L("pdf.sick.patient.dob"), dobText), font: subFont)
                if let ageText = formatAgeString(dobString: dobText, visitDateString: visit.date) {
                    drawText(LF("pdf.sick.labelValue.fmt", L("pdf.sick.patient.ageAtVisit"), ageText), font: subFont)
                }
                drawText(LF("pdf.sick.labelValue.fmt", L("pdf.sick.patient.sex"), sexText), font: subFont)
                drawText(LF("pdf.sick.labelValue.fmt", L("pdf.sick.patient.mrn"), mrnText), font: subFont)
                // Clinician Name (if available)
                if let clinicianID = episodeRow[episodeUserID],
                   let userRow = try? db.pluck(users.filter(userPK == clinicianID)) {
                    let clinicianName = "\(userRow[firstNameUser]) \(userRow[lastNameUser])".trimmingCharacters(in: .whitespaces)
                    if !clinicianName.isEmpty {
                        drawText(LF("pdf.sick.labelValue.fmt", L("pdf.sick.patient.clinician"), clinicianName), font: subFont)
                    }
                }

                // Chief Complaint & History section
                y += 12
                drawSectionHeader("pdf.sick.section.chiefComplaintHistory")

                let mainComplaint = Expression<String?>("main_complaint")
                let hpi = Expression<String?>("hpi")
                let duration = Expression<String?>("duration")
                let feeding = Expression<String?>("feeding")
                let urination = Expression<String?>("urination")
                let breathing = Expression<String?>("breathing")
                let pain = Expression<String?>("pain")
                let context = Expression<String?>("context")

                if let episodeRow = try? db.pluck(episodes.filter(episodeID == visit.id)) {
                    func showField(key: String, _ value: String?) {
                        if let val = value, !val.isEmpty {
                            drawText(LF("pdf.sick.labelValue.fmt", L(key), val), font: subFont)
                        }
                    }

                    showField(key: "pdf.sick.hx.mainComplaint", try? episodeRow.get(mainComplaint))
                    showField(key: "pdf.sick.hx.history", try? episodeRow.get(hpi))
                    showField(key: "pdf.sick.hx.duration", try? episodeRow.get(duration))
                    showField(key: "pdf.sick.hx.feeding", try? episodeRow.get(feeding))
                    showField(key: "pdf.sick.hx.urination", try? episodeRow.get(urination))
                    showField(key: "pdf.sick.hx.breathing", try? episodeRow.get(breathing))
                    showField(key: "pdf.sick.hx.pain", try? episodeRow.get(pain))
                    showField(key: "pdf.sick.hx.context", try? episodeRow.get(context))
                    
                    // MARK: - Vaccination Status
                    let vaccinationStatus = Expression<String?>("vaccination_status")

                    let vaccStatus = patientRow[vaccinationStatus]
                    if let status = vaccStatus, !status.isEmpty {
                        y += 12
                        drawSectionHeader("pdf.sick.section.vaccinationStatus")
                        drawText(status, font: subFont)
                    }

                    // MARK: - Past Medical History
                    let pmh = Table("past_medical_history")
                    let pmhPID = Expression<Int64>("patient_id")
                    let asthma = Expression<Int?>("asthma")
                    let otitis = Expression<Int?>("otitis")
                    let uti = Expression<Int?>("uti")
                    let allergies = Expression<Int?>("allergies")
                    let other = Expression<String?>("other")
                    let allergyDetails = Expression<String?>("allergy_details")

                    // Default lines (shown even when nothing is recorded)
                    var perinatalLine = LF("pdf.sick.perinatal.line.fmt", L("common.placeholder"))
                    var pmhLine = LF("pdf.sick.pmh.line.fmt", L("common.placeholder"))

                    // Age-gated perinatal summary (only if < 3 months)
                    if let ageM = ageMonthsForVisit, ageM < 3.0 {
                        let perinatal = Table("perinatal_history")
                        let perinatalPID = Expression<Int64>("patient_id")
                        let pregnancyRisk = Expression<String?>("pregnancy_risk")
                        let birthMode = Expression<String?>("birth_mode")
                        let term = Expression<Int?>("birth_term_weeks")
                        let resuscitation = Expression<String?>("resuscitation")
                        let infectionRisk = Expression<String?>("infection_risk")
                        let birthWeight = Expression<Int?>("birth_weight_g")
                        let birthLength = Expression<Double?>("birth_length_cm")
                        let headCirc = Expression<Double?>("birth_head_circumference_cm")
                        let dischargeWeight = Expression<Int?>("discharge_weight_g")
                        let feedingMaternity = Expression<String?>("feeding_in_maternity")
                        let vaccinations = Expression<String?>("maternity_vaccinations")
                        let events = Expression<String?>("maternity_stay_events")
                        let hearing = Expression<String?>("hearing_screening")
                        let heart = Expression<String?>("heart_screening")
                        let metabolic = Expression<String?>("metabolic_screening")
                        let afterBirth = Expression<String?>("illnesses_after_birth")
                        let motherVacc = Expression<String?>("mother_vaccinations")

                        if let peri = try? db.pluck(perinatal.filter(perinatalPID == pid)) {
                            var parts: [String] = []
                            if let v = try? peri.get(pregnancyRisk), !v.isEmpty { parts.append(LF("pdf.sick.perinatal.pregnancy.fmt", v)) }
                            if let v = try? peri.get(birthMode), !v.isEmpty { parts.append(LF("pdf.sick.perinatal.birthMode.fmt", v)) }
                            if let v = try? peri.get(term) { parts.append(LF("pdf.sick.perinatal.gaWeeks.fmt", v)) }
                            if let v = try? peri.get(resuscitation), !v.isEmpty { parts.append(LF("pdf.sick.perinatal.resuscitation.fmt", v)) }
                            if let v = try? peri.get(infectionRisk), !v.isEmpty { parts.append(LF("pdf.sick.perinatal.infectionRisk.fmt", v)) }
                            if let v = try? peri.get(birthWeight) { parts.append(LF("pdf.sick.perinatal.birthWeightG.fmt", v)) }
                            if let v = try? peri.get(birthLength) { parts.append(LF("pdf.sick.perinatal.birthLengthCm.fmt", String(format: "%.1f", v))) }
                            if let v = try? peri.get(headCirc) { parts.append(LF("pdf.sick.perinatal.birthHcCm.fmt", String(format: "%.1f", v))) }
                            if let v = try? peri.get(dischargeWeight) { parts.append(LF("pdf.sick.perinatal.dischargeWeightG.fmt", v)) }
                            if let v = try? peri.get(feedingMaternity), !v.isEmpty { parts.append(LF("pdf.sick.perinatal.feeding.fmt", v)) }
                            if let v = try? peri.get(vaccinations), !v.isEmpty { parts.append(LF("pdf.sick.perinatal.vaccinations.fmt", v)) }
                            if let v = try? peri.get(events), !v.isEmpty { parts.append(LF("pdf.sick.perinatal.events.fmt", v)) }
                            if let v = try? peri.get(hearing), !v.isEmpty { parts.append(LF("pdf.sick.perinatal.hearing.fmt", v)) }
                            if let v = try? peri.get(heart), !v.isEmpty { parts.append(LF("pdf.sick.perinatal.heart.fmt", v)) }
                            if let v = try? peri.get(metabolic), !v.isEmpty { parts.append(LF("pdf.sick.perinatal.metabolic.fmt", v)) }
                            if let v = try? peri.get(afterBirth), !v.isEmpty { parts.append(LF("pdf.sick.perinatal.afterBirth.fmt", v)) }
                            if let v = try? peri.get(motherVacc), !v.isEmpty { parts.append(LF("pdf.sick.perinatal.motherVacc.fmt", v)) }

                            if !parts.isEmpty {
                                perinatalLine = LF("pdf.sick.perinatal.lineWithValue.fmt", parts.joined(separator: "; "))
                            }
                        }
                    }

                    // Non-perinatal past medical history
                    if let pmhRow = try? db.pluck(pmh.filter(pmhPID == pid)) {
                        var items: [String] = []
                        if (try? pmhRow.get(asthma)) == 1 { items.append(L("pdf.sick.pmh.asthma")) }
                        if (try? pmhRow.get(otitis)) == 1 { items.append(L("pdf.sick.pmh.otitis")) }
                        if (try? pmhRow.get(uti)) == 1 { items.append(L("pdf.sick.pmh.uti")) }
                        if (try? pmhRow.get(allergies)) == 1 { items.append(L("pdf.sick.pmh.allergies")) }
                        if let otherVal = try? pmhRow.get(other), !otherVal.isEmpty {
                            items.append(otherVal)
                        }
                        if let details = try? pmhRow.get(allergyDetails), !details.isEmpty {
                            items.append(LF("pdf.sick.pmh.allergyDetails.fmt", details))
                        }

                        if !items.isEmpty {
                            pmhLine = LF("pdf.sick.pmh.lineWithValue.fmt", items.joined(separator: "; "))
                        }
                    }

                    // Always render Past Medical History section with explicit placeholders
                    y += 12
                    drawSectionHeader("pdf.sick.section.pastMedicalHistory")
                    drawWrappedText(perinatalLine, font: subFont, in: pageRect, at: &y, using: rendererContext)
                    drawWrappedText(pmhLine, font: subFont, in: pageRect, at: &y, using: rendererContext)

                    // MARK: - Vitals
                    y += 12
                    drawSectionHeader("pdf.sick.section.vitals")

                    let vitals = Table("vitals")
                    let vEpisodeID = Expression<Int64>("episode_id")
                    let vRecordedAt = Expression<String>("recorded_at")

                    let vWeight = Expression<Double?>("weight_kg")
                    let vHeight = Expression<Double?>("height_cm")
                    let vHeadCirc = Expression<Double?>("head_circumference_cm")
                    let vTemp = Expression<Double?>("temperature_c")
                    let vHR = Expression<Int?>("heart_rate")
                    let vRR = Expression<Int?>("respiratory_rate")
                    let vSpO2 = Expression<Int?>("spo2")
                    let vSys = Expression<Int?>("bp_systolic")
                    let vDia = Expression<Int?>("bp_diastolic")

                    if let vitalsRow = try? db.pluck(
                        vitals
                            .filter(vEpisodeID == visit.id)
                            .order(vRecordedAt.desc)
                            .limit(1)
                    ) {
                        var vitalsLines: [String] = []

                        if let w = vitalsRow[vWeight], w > 0 {
                            vitalsLines.append(LF("pdf.sick.vitals.weightKg.fmt", w))
                        }
                        if let h = vitalsRow[vHeight], h > 0 {
                            vitalsLines.append(LF("pdf.sick.vitals.heightCm.fmt", h))
                        }
                        if let hc = vitalsRow[vHeadCirc], hc > 0 {
                            vitalsLines.append(LF("pdf.sick.vitals.headCircCm.fmt", hc))
                        }
                        if let t = vitalsRow[vTemp], t > 0 {
                            vitalsLines.append(LF("pdf.sick.vitals.tempC.fmt", t))
                        }
                        if let hr = vitalsRow[vHR], hr > 0 {
                            vitalsLines.append(LF("pdf.sick.vitals.hrBpm.fmt", hr))
                        }
                        if let rr = vitalsRow[vRR], rr > 0 {
                            vitalsLines.append(LF("pdf.sick.vitals.rrPerMin.fmt", rr))
                        }
                        if let spo = vitalsRow[vSpO2], spo > 0 {
                            vitalsLines.append(LF("pdf.sick.vitals.spo2Pct.fmt", spo))
                        }
                        if let sys = vitalsRow[vSys], let dia = vitalsRow[vDia], sys > 0, dia > 0 {
                            vitalsLines.append(LF("pdf.sick.vitals.bpMmhg.fmt", sys, dia))
                        }

                        if vitalsLines.isEmpty {
                            drawText(L("common.placeholder"), font: subFont)
                        } else {
                            for line in vitalsLines {
                                drawText(line, font: subFont)
                            }
                        }
                    } else {
                        // No vitals recorded for this episode
                        drawText(L("common.placeholder"), font: subFont)
                    }

                // MARK: - Physical Examination
                y += 12
                drawSectionHeader("pdf.sick.section.physicalExam")

                func getPEField(_ key: String) -> String? {
                    try? episodeRow.get(Expression<String?>(key))
                }

                func peFieldLabel(_ dbKey: String) -> String {
                    // Preferred localization: "pdf.sick.pe.field.<dbKey>"
                    let locKey = "pdf.sick.pe.field.\(dbKey)"
                    let localized = L(locKey)
                    if localized != locKey {
                        return localized
                    }

                    // Fallback: readable label from the DB key
                    return dbKey
                        .replacingOccurrences(of: "_", with: " ")
                        .capitalized
                }

                let peGroups: [(label: String, keys: [String])] = [
                    (L("pdf.sick.pe.group.general"), ["general_appearance", "hydration", "color", "skin"]),
                    (L("pdf.sick.pe.group.ent"), ["ent", "right_ear", "left_ear", "right_eye", "left_eye"]),
                    (L("pdf.sick.pe.group.cardioresp"), ["heart", "lungs"]),
                    (L("pdf.sick.pe.group.abdomen"), ["abdomen", "peristalsis"]),
                    (L("pdf.sick.pe.group.genitalia"), ["genitalia"]),
                    (L("pdf.sick.pe.group.neuroMskLymph"), ["neurological", "musculoskeletal", "lymph_nodes"])
                ]

                for group in peGroups {
                    var values: [String] = []
                    for key in group.keys {
                        if let val = getPEField(key), !val.isEmpty {
                            let label = peFieldLabel(key)
                            values.append(LF("pdf.sick.labelValue.fmt", label, val))
                        }
                    }
                    if !values.isEmpty {
                        // Group label + all field label/value items on one wrapped line, with group label bold
                        let boldFont = UIFont.boldSystemFont(ofSize: subFont.pointSize)
                        let paragraphStyle = NSMutableParagraphStyle()
                        paragraphStyle.lineBreakMode = .byWordWrapping

                        let head = NSAttributedString(
                            string: group.label + ": ",
                            attributes: [
                                .font: boldFont,
                                .paragraphStyle: paragraphStyle
                            ]
                        )

                        let body = NSAttributedString(
                            string: values.joined(separator: "; "),
                            attributes: [
                                .font: subFont,
                                .paragraphStyle: paragraphStyle
                            ]
                        )

                        let combined = NSMutableAttributedString()
                        combined.append(head)
                        combined.append(body)

                        drawWrappedAttributedText(
                            combined,
                            in: pageRect,
                            at: &y,
                            using: rendererContext
                        )
                    }
                }
                    
                    // --- Additional physical examination information (free text) ---
                    y += 6
                    drawText(L("pdf.sick.pe.additional_info.title"),
                             font: UIFont.boldSystemFont(ofSize: subFont.pointSize))

                    let extraPE = (try? episodeRow.get(Expression<String?>("comments"))) ?? ""
                    
                    let extraPETrimmed = extraPE.trimmingCharacters(in: .whitespacesAndNewlines)

                    if extraPETrimmed.isEmpty {
                        drawText(L("common.placeholder"), font: subFont)
                    } else {
                        drawWrappedText("• \(extraPETrimmed)", font: subFont, in: pageRect, at: &y, using: rendererContext)
                    }
                }

                // MARK: - Problem Listing
                let headerFont = UIFont.boldSystemFont(ofSize: 16)
                let headerHeight = headerFont.lineHeight + 6
                ensureSpace(for: headerHeight)
                
                y += 12
                drawSectionHeader("pdf.sick.section.problemListing")

                let problemListing = Expression<String?>("problem_listing")
                if let summary = try? episodeRow.get(problemListing), !summary.isEmpty {
                    let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    drawWrappedText(cleanSummary.replacingOccurrences(of: "\n", with: "; "), font: subFont, in: pageRect, at: &y, using: rendererContext)
                } else {
                    drawText(L("common.placeholder"), font: subFont)
                }
                // MARK: - Additional Episode Fields
                let compInvestigations = Expression<String?>("complementary_investigations")
                let diagnosis = Expression<String?>("diagnosis")
                let icd10 = Expression<String?>("icd10")
                let medications = Expression<String?>("medications")
                let anticipatory = Expression<String?>("anticipatory_guidance")
                let aiNotes = Expression<String?>("ai_notes")

                let aiInputs = Table("ai_inputs")
                let aiEpisodeID = Expression<Int64>("episode_id")
                let aiResponse = Expression<String?>("response")
                let aiCreatedAt = Expression<String?>("created_at")

                // Resolve AI content: prefer latest ai_inputs.response, fallback to legacy episodes.ai_notes
                var aiSectionContent: String? = nil

                // 1) Try latest ai_inputs row for this episode
                let latestAIQuery = aiInputs
                    .filter(aiEpisodeID == visit.id)
                    .order(aiCreatedAt.desc)
                    .limit(1)

                if let aiRow = try? db.pluck(latestAIQuery),
                   var raw = aiRow[aiResponse] {
                    raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !raw.isEmpty {
                        // If stored with literal "\\n" sequences (common when JSON-escaping), restore real newlines.
                        if !raw.contains("\n") && raw.contains("\\n") {
                            raw = raw.replacingOccurrences(of: "\\n", with: "\n")
                        }
                        aiSectionContent = raw
                    }
                } else if let legacy = try? episodeRow.get(aiNotes) {
                    // 2) Fallback to legacy ai_notes column on episodes
                    var trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        if !trimmed.contains("\n") && trimmed.contains("\\n") {
                            trimmed = trimmed.replacingOccurrences(of: "\\n", with: "\n")
                        }
                        aiSectionContent = trimmed
                    }
                }

                func renderSection(title: String, content: String?, preserveNewlines: Bool = false) {
                    let headerFont = UIFont.boldSystemFont(ofSize: 16)
                    let bodyFont = subFont
                    let spacing: CGFloat = 6

                    // Estimate height of header + body
                    let headerHeight = headerFont.lineHeight + spacing
                    var bodyHeight: CGFloat = 0
                    if let text = content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        let paragraphStyle = NSMutableParagraphStyle()
                        paragraphStyle.lineBreakMode = .byWordWrapping
                        let attributes: [NSAttributedString.Key: Any] = [
                            .font: bodyFont,
                            .paragraphStyle: paragraphStyle
                        ]
                        let boundingBox = NSString(string: text).boundingRect(
                            with: CGSize(width: pageRect.width - 2 * margin, height: .greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                            attributes: attributes,
                            context: nil
                        )
                        bodyHeight = ceil(boundingBox.height) + spacing
                    } else {
                        bodyHeight = bodyFont.lineHeight + spacing
                    }

                    ensureSpace(for: headerHeight + bodyHeight)

                    y += 12
                    drawHeaderBox(title, font: headerFont, background: sectionBG, textColor: .black)

                    if let text = content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        if preserveNewlines {
                            drawWrappedTextRich(text, font: bodyFont, in: pageRect, at: &y, using: rendererContext)
                        } else {
                            drawWrappedText(text.replacingOccurrences(of: "\n", with: "; "), font: bodyFont, in: pageRect, at: &y, using: rendererContext)
                        }
                    } else {
                        drawText(L("common.placeholder"), font: bodyFont)
                    }
                }

                renderSection(title: L("pdf.sick.section.investigations"), content: try? episodeRow.get(compInvestigations))
                renderSection(title: L("pdf.sick.section.diagnosis"), content: try? episodeRow.get(diagnosis))
                renderSection(title: L("pdf.sick.section.icd10"), content: try? episodeRow.get(icd10))
                renderSection(title: L("pdf.sick.section.medications"), content: try? episodeRow.get(medications))
                renderSection(title: L("pdf.sick.section.anticipatoryGuidance"), content: try? episodeRow.get(anticipatory))
                renderSection(title: L("pdf.sick.section.aiAssistantInput"), content: aiSectionContent, preserveNewlines: true)

                // MARK: - Addenda (visit_addenda)
                let addenda = Self.loadReportAddendaForEpisode(db: db, episodeID: visit.id)
                if !addenda.isEmpty {
                    y += 12
                    drawHeaderBox(L("pdf.section.addenda"),
                                  font: UIFont.boldSystemFont(ofSize: 16),
                                  background: sectionBG,
                                  textColor: .black)

                    for a in addenda {
                        let created = Self.cleanLine(a.createdAtISO)
                        let updated = Self.cleanLine(a.updatedAtISO)
                        let author  = Self.cleanLine(a.authorName)

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

                        let parts = a.text
                            .replacingOccurrences(of: "\r\n", with: "\n")
                            .replacingOccurrences(of: "\r", with: "\n")
                            .components(separatedBy: "\n")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }

                        let paragraphStyle = NSMutableParagraphStyle()
                        paragraphStyle.lineBreakMode = .byWordWrapping
                        paragraphStyle.lineSpacing = 2
                        paragraphStyle.paragraphSpacing = 6

                        let block = NSMutableAttributedString()
                        if !header.isEmpty {
                            block.append(NSAttributedString(
                                string: header + "\n",
                                attributes: [
                                    .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                                    .foregroundColor: UIColor.secondaryLabel,
                                    .paragraphStyle: paragraphStyle
                                ]
                            ))
                        }

                        if parts.isEmpty {
                            block.append(NSAttributedString(
                                string: "•\n",
                                attributes: [
                                    .font: subFont,
                                    .paragraphStyle: paragraphStyle
                                ]
                            ))
                        } else {
                            for p in parts {
                                block.append(NSAttributedString(
                                    string: "• \(p)\n",
                                    attributes: [
                                        .font: subFont,
                                        .paragraphStyle: paragraphStyle
                                    ]
                                ))
                            }
                        }

                        // Trim final newline (looks cleaner)
                        if block.string.hasSuffix("\n") {
                            block.deleteCharacters(in: NSRange(location: block.length - 1, length: 1))
                        }

                        drawWrappedAttributedText(block, in: pageRect, at: &y, using: rendererContext)
                        y += 4
                    }
                }
            } catch {
                Self.log.error("DB error while generating sick visit PDF: \(error.localizedDescription, privacy: .public)")
                drawText(LF("pdf.sick.error.dbError.fmt", error.localizedDescription), font: subFont)
            }
        }  // end of renderer.pdfData

        do {
            let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fileURL = docsURL.appendingPathComponent("VisitReport_\(visit.id).pdf")
            try data.write(to: fileURL)
            Self.log.log("SickVisit PDF saved at \(fileURL.path, privacy: .private) (size=\(data.count, privacy: .public) bytes)")
            return fileURL
        } catch {
            Self.log.error("Failed to save sick visit PDF: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Addenda (visit_addenda)

    private struct ReportAddendum: Identifiable {
        let id: Int64
        let createdAtISO: String?
        let updatedAtISO: String?
        let authorName: String?
        let text: String
    }

    private static func tableExists(_ db: Connection, name: String) -> Bool {
        do {
            let q = "SELECT name FROM sqlite_master WHERE type='table' AND name = ? LIMIT 1;"
            if let _ = try db.scalar(q, name) as? String {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    private static func columns(in db: Connection, table: String) -> Set<String> {
        do {
            var out = Set<String>()
            for row in try db.prepare("PRAGMA table_info(\(table));") {
                if let n = row[1] as? String {
                    out.insert(n)
                }
            }
            return out
        } catch {
            return []
        }
    }

    /// Fetch addenda for a SICK episode from `visit_addenda`.
    /// This is best-effort and tolerant to small schema differences.
    private static func loadReportAddendaForEpisode(db: Connection, episodeID: Int64) -> [ReportAddendum] {
        guard tableExists(db, name: "visit_addenda") else { return [] }

        let cols = columns(in: db, table: "visit_addenda")
        guard !cols.isEmpty else { return [] }

        let fkCandidates = ["episode_id", "episodeId", "episodeID", "visit_id", "visitID"]
        guard let fk = fkCandidates.first(where: { cols.contains($0) }) else { return [] }

        let idCol = cols.contains("id") ? "id" : "rowid"

        guard let textCol = ["text", "content", "note", "addendum_text"].first(where: { cols.contains($0) }) else {
            return []
        }

        let createdCol = ["created_at", "createdAt", "created_iso"].first(where: { cols.contains($0) })
        let updatedCol = ["updated_at", "updatedAt", "updated_iso"].first(where: { cols.contains($0) })

        let authorDirectCol = ["author_name", "clinician_name", "provider_name", "user_name"].first(where: { cols.contains($0) })
        let authorUserFK = ["author_user_id", "clinician_user_id", "user_id", "provider_id", "doctor_user_id"].first(where: { cols.contains($0) })

        let usersTableExists = tableExists(db, name: "users")

        let idSel = "a.\(idCol)"
        let textSel = "a.\(textCol)"
        let createdSel = createdCol != nil ? "a.\(createdCol!)" : "NULL"
        let updatedSel = updatedCol != nil ? "a.\(updatedCol!)" : "NULL"

        let (authorSel, joinUsers): (String, String) = {
            if let c = authorDirectCol {
                return ("a.\(c)", "")
            }
            if usersTableExists, let fkCol = authorUserFK {
                let sel = "trim(coalesce(u.first_name,'') || ' ' || coalesce(u.last_name,''))"
                let join = "LEFT JOIN users u ON u.id = a.\(fkCol)"
                return (sel, join)
            }
            return ("NULL", "")
        }()

        let orderExpr: String = {
            if let c = createdCol { return "datetime(a.\(c))" }
            return idSel
        }()

        let sql = """
        SELECT \(idSel), \(textSel), \(createdSel), \(updatedSel), \(authorSel)
        FROM visit_addenda a
        \(joinUsers)
        WHERE a.\(fk) = ?
        ORDER BY \(orderExpr) ASC, \(idSel) ASC;
        """

        func asInt64(_ v: Any?) -> Int64 {
            if let x = v as? Int64 { return x }
            if let x = v as? Int { return Int64(x) }
            if let x = v as? Int32 { return Int64(x) }
            if let x = v as? Int16 { return Int64(x) }
            if let x = v as? Int8 { return Int64(x) }
            return 0
        }

        func asString(_ v: Any?) -> String? {
            if let s = v as? String { return s }
            if v == nil { return nil }
            return String(describing: v!)
        }

        do {
            var out: [ReportAddendum] = []
            for row in try db.prepare(sql, episodeID) {
                let id = asInt64(row[0])
                let text = (asString(row[1]) ?? "")
                let created = asString(row[2])
                let updated = asString(row[3])
                let author = asString(row[4])

                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(ReportAddendum(
                        id: id,
                        createdAtISO: created,
                        updatedAtISO: updated,
                        authorName: author,
                        text: text
                    ))
                }
            }
            return out
        } catch {
            return []
        }
    }

    private static func cleanLine(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
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
