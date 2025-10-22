import Foundation
import SQLite
import PDFKit
import UIKit

struct SickVisitPDFGenerator {
    static func generate(for visit: VisitSummary, dbURL: URL) -> URL? {
        let pdfMetaData = [
            kCGPDFContextCreator: "Patient Viewer",
            kCGPDFContextAuthor: "Patient App",
            kCGPDFContextTitle: "Sick Visit Report"
        ]
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = pdfMetaData as [String: Any]

        let pageWidth = 595.2
        let pageHeight = 841.8
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)

        let margin: CGFloat = 40
        let contentWidth = pageWidth - 2 * margin

        // Helper to ensure enough space on the current PDF page
        func ensureSpace(for height: CGFloat) {
            // This is a placeholder; the actual implementation is inside the renderer.pdfData closure.
            // The actual function will be shadowed/overwritten in the closure below,
            // but this declaration is needed for drawWrappedText's scope.
        }

        // Helper to draw wrapped text for long lines (e.g., PE section), supporting multi-page and clean margins
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
                // Always compute availableHeight based on y, but reset y before calculation if starting a new page
                var availableHeight = rect.height - y - margin
                if availableHeight < font.lineHeight * 2 {
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

                let textRect = CGRect(x: offset, y: y, width: contentWidth, height: .greatestFiniteMagnitude)
                let boundingBox = attrString.boundingRect(with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                                                           options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                           context: nil)
                
                ensureSpace(for: ceil(boundingBox.height))
                attrString.draw(in: textRect)
                y += ceil(boundingBox.height) + 6
            }

            let titleFont = UIFont.boldSystemFont(ofSize: 20)
            let subFont = UIFont.systemFont(ofSize: 14)

            // Title
            drawText("Sick Visit Report", font: titleFont)

            // Visit date
            let formattedVisitDate = formatDate(visit.date)
            drawText("Visit Date: \(formattedVisitDate)", font: subFont)
            drawText("Report Generated: \(formatDate(Date()))", font: subFont)

            // Fetch patient info
            let dbPath = dbURL.appendingPathComponent("db.sqlite").path
            do {
                let db = try Connection(dbPath)
                let episodes = Table("episodes")
                let episodeID = Expression<Int64>("id")
                let patientID = Expression<Int64>("patient_id")

                // 1. Get patient_id for this visit (episode)
                guard let episodeRow = try db.pluck(episodes.filter(episodeID == visit.id)) else {
                    drawText("❌ Error: Episode not found", font: subFont)
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

                guard let patientRow = try db.pluck(patients.filter(id == pid)) else {
                    drawText("❌ Error: Patient not found", font: subFont)
                    return
                }

                let aliasText = patientRow[alias] ?? "—"
                let name = "\(patientRow[firstName]) \(patientRow[lastName])"
                let dobText = patientRow[dob]
                let sexText = patientRow[sex]
                let mrnText = patientRow[mrn]

                // 3. Render
                y += 12
                drawText("Patient Info", font: UIFont.boldSystemFont(ofSize: 16))
                drawText("Alias: \(aliasText)", font: subFont)
                drawText("Name: \(name)", font: subFont)
                drawText("DOB: \(dobText)", font: subFont)
                drawText("Sex: \(sexText)", font: subFont)
                drawText("MRN: \(mrnText)", font: subFont)

                // Chief Complaint & History section
                y += 12
                drawText("Chief Complaint & History", font: UIFont.boldSystemFont(ofSize: 16))

                let mainComplaint = Expression<String?>("main_complaint")
                let hpi = Expression<String?>("hpi")
                let duration = Expression<String?>("duration")
                let feeding = Expression<String?>("feeding")
                let urination = Expression<String?>("urination")
                let breathing = Expression<String?>("breathing")
                let pain = Expression<String?>("pain")
                let context = Expression<String?>("context")

                if let episodeRow = try? db.pluck(episodes.filter(episodeID == visit.id)) {
                    func showField(_ label: String, _ value: String?) {
                        if let val = value, !val.isEmpty {
                            drawText("\(label): \(val)", font: subFont)
                        }
                    }

                    showField("Main Complaint", try? episodeRow.get(mainComplaint))
                    showField("History", try? episodeRow.get(hpi))
                    showField("Duration", try? episodeRow.get(duration))
                    showField("Feeding", try? episodeRow.get(feeding))
                    showField("Urination", try? episodeRow.get(urination))
                    showField("Breathing", try? episodeRow.get(breathing))
                    showField("Pain", try? episodeRow.get(pain))
                    showField("Context", try? episodeRow.get(context))
                    
                    // MARK: - Vaccination Status
                    let vaccinationStatus = Expression<String?>("vaccination_status")

                    let vaccStatus = patientRow[vaccinationStatus]
                    if let status = vaccStatus, !status.isEmpty {
                        y += 12
                        drawText("Vaccination Status", font: UIFont.boldSystemFont(ofSize: 16))
                        drawText(status, font: subFont)
                    }

                    // MARK: - Past Medical History
                    let pmh = Table("past_medical_history")
                    let asthma = Expression<Int?>("asthma")
                    let otitis = Expression<Int?>("otitis")
                    let uti = Expression<Int?>("uti")
                    let allergies = Expression<Int?>("allergies")
                    let other = Expression<String?>("other")

                    if let pmhRow = try? db.pluck(pmh.filter(Expression<Int64>("patient_id") == pid)) {
                        var items: [String] = []
                        if (try? pmhRow.get(asthma)) == 1 { items.append("Asthma") }
                        if (try? pmhRow.get(otitis)) == 1 { items.append("Otitis") }
                        if (try? pmhRow.get(uti)) == 1 { items.append("UTI") }
                        if (try? pmhRow.get(allergies)) == 1 { items.append("Allergies") }
                        if let otherVal = try? pmhRow.get(other), !otherVal.isEmpty {
                            items.append(otherVal)
                        }
                        if !items.isEmpty {
                            y += 12
                            drawText("Past Medical History", font: UIFont.boldSystemFont(ofSize: 16))
                            drawText(items.joined(separator: "; "), font: subFont)
                        }
                    }
                    
                // MARK: - Physical Examination
                y += 12
                drawText("Physical Examination", font: UIFont.boldSystemFont(ofSize: 16))

                func getPEField(_ key: String) -> String? {
                    return try? episodeRow.get(Expression<String?>(key))
                }

                let peGroups: [(label: String, keys: [String])] = [
                    ("General", ["general_appearance", "hydration", "color", "skin"]),
                    ("ENT", ["ent", "right_ear", "left_ear", "right_eye", "left_eye"]),
                    ("Cardiorespiratory", ["heart", "lungs"]),
                    ("Abdomen", ["abdomen", "peristalsis"]),
                    ("Genitalia", ["genitalia"]),
                    ("Neuro / MSK / Lymph", ["neurological", "musculoskeletal", "lymph_nodes"])
                ]

                for group in peGroups {
                    var values: [String] = []
                    for key in group.keys {
                        if let val = getPEField(key), !val.isEmpty {
                            // Capitalize only first letter of each part
                            let label = key.replacingOccurrences(of: "_", with: " ").capitalized
                            values.append("\(label): \(val)")
                        }
                    }
                    if !values.isEmpty {
                        drawWrappedText("\(group.label): " + values.joined(separator: "; "), font: subFont, in: pageRect, at: &y, using: rendererContext)
                    }
                }
                }

                // MARK: - Problem Listing
                let headerFont = UIFont.boldSystemFont(ofSize: 16)
                let headerHeight = headerFont.lineHeight + 6
                ensureSpace(for: headerHeight)
                
                y += 12
                drawText("Problem Listing", font: headerFont)

                let problemListing = Expression<String?>("problem_listing")
                if let summary = try? episodeRow.get(problemListing), !summary.isEmpty {
                    let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    drawWrappedText(cleanSummary.replacingOccurrences(of: "\n", with: "; "), font: subFont, in: pageRect, at: &y, using: rendererContext)
                } else {
                    drawText("—", font: subFont)
                }
                // MARK: - Additional Episode Fields
                let compInvestigations = Expression<String?>("complementary_investigations")
                let diagnosis = Expression<String?>("diagnosis")
                let icd10 = Expression<String?>("icd10")
                let medications = Expression<String?>("medications")
                let anticipatory = Expression<String?>("anticipatory_guidance")
                let comments = Expression<String?>("comments")
                let aiNotes = Expression<String?>("ai_notes")

                func renderSection(title: String, content: String?) {
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
                    drawText(title, font: headerFont)

                    if let text = content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        drawWrappedText(text.replacingOccurrences(of: "\n", with: "; "), font: bodyFont, in: pageRect, at: &y, using: rendererContext)
                    } else {
                        drawText("—", font: bodyFont)
                    }
                }

                renderSection(title: "Investigations", content: try? episodeRow.get(compInvestigations))
                renderSection(title: "Diagnosis", content: try? episodeRow.get(diagnosis))
                renderSection(title: "ICD10", content: try? episodeRow.get(icd10))
                renderSection(title: "Medications", content: try? episodeRow.get(medications))
                renderSection(title: "Anticipatory Guidance", content: try? episodeRow.get(anticipatory))
                renderSection(title: "Comments", content: try? episodeRow.get(comments))
                renderSection(title: "AI Notes", content: try? episodeRow.get(aiNotes))
            } catch {
                drawText("❌ DB Error: \(error.localizedDescription)", font: subFont)
            }
        }  // end of renderer.pdfData

        do {
            let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fileURL = docsURL.appendingPathComponent("VisitReport_\(visit.id).pdf")
            try data.write(to: fileURL)
            return fileURL
        } catch {
            print("❌ Failed to save sick visit PDF: \(error)")
            return nil
        }
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
