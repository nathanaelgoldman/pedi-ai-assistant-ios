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
                let pdfData = try makePDF(from: attributed)
                try pdfData.write(to: dest, options: Data.WritingOptions.atomic)
            case .rtf:
                guard let rtfData = attributed.rtf(
                    from: NSRange(location: 0, length: attributed.length),
                    documentAttributes: [:]
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
}

// MARK: - Content assembly from AppState

private extension ReportBuilder {

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
            let attributed = assembleAttributedWell(data: data, fallbackSections: fallbackSections)
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
    func assembleAttributedWell(data: WellReportData, fallbackSections: [Section]) -> NSAttributedString {
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
        para("DOB: \(humanDateOnly(data.meta.dobISO) ?? "—")   •   Sex: \(data.meta.sex)   •   Age at Visit: \(data.meta.ageAtVisit)", font: .systemFont(ofSize: 12))
        para("Visit Date: \(humanDateOnly(data.meta.visitDateISO) ?? "—")   •   Visit Type: \(data.meta.visitTypeReadable ?? "Well Visit")", font: .systemFont(ofSize: 12))
        para("Clinician: \(data.meta.clinicianName)", font: .systemFont(ofSize: 12))
        content.append(NSAttributedString(string: "\n"))

        
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
        para("DOB: \(humanDateOnly(data.meta.dobISO) ?? "—")   •   Sex: \(data.meta.sex)   •   Age at Visit: \(data.meta.ageAtVisit)", font: .systemFont(ofSize: 12))
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
    func makePDF(from attributed: NSAttributedString,
                 pageSize: CGSize = CGSize(width: 8.5 * 72.0, height: 11 * 72.0),
                 inset: CGFloat = 36) throws -> Data {
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
        let mutable = NSMutableAttributedString(attributedString: attributed)
        mutable.addAttribute(.foregroundColor, value: NSColor.black,
                             range: NSRange(location: 0, length: mutable.length))

        // CoreText typesetter for pagination
        let framesetter = CTFramesetterCreateWithAttributedString(mutable as CFAttributedString)
        let path = CGMutablePath()
        path.addRect(contentRect)

        var currentIndex = 0
        while currentIndex < mutable.length {
            // Start page
            ctx.beginPDFPage(nil)

            // White background
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(mediaBox)

            // Bridge to NSGraphicsContext for correct metrics each page
            NSGraphicsContext.saveGraphicsState()
            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.current = nsCtx

            // Create and draw frame for the remaining text
            let frame = CTFramesetterCreateFrame(framesetter,
                                                 CFRange(location: currentIndex, length: 0),
                                                 path,
                                                 nil)
            CTFrameDraw(frame, ctx)

            // Restore and end page
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()

            // Advance by visible range; stop if no progress (safety)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }
            currentIndex += visible.length
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
