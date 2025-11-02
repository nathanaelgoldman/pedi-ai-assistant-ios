//
//  ReportBuilder.swift
//  DrsMainApp
//
//  Created by yunastic on 11/2/25.
//

import Foundation
import PDFKit
import AppKit
import OSLog
import SQLite3

struct ReportSection {
    let title: String
    let body: String
}

enum VisitKind {
    case sick(episodeID: Int)
    case well(visitID: Int)
}

enum ReportFormat {
    case pdf
    case rtf // (easy export now; we can add .docx later)
}

@MainActor
final class ReportBuilder {
    private let log = Logger(subsystem: "DrsMainApp", category: "ReportBuilder")
    private let appState: AppState
    private let clinicianStore: ClinicianStore

    init(appState: AppState, clinicianStore: ClinicianStore) {
        self.appState = appState
        self.clinicianStore = clinicianStore
    }

    // Public entry — returns the saved file URL
    func exportReport(for kind: VisitKind, format: ReportFormat) throws -> URL {
        let (patient, sections, meta) = try fetchContent(kind: kind)
        switch format {
        case .pdf:
            return try renderPDF(patient: patient, sections: sections, meta: meta)
        case .rtf:
            return try renderRTF(patient: patient, sections: sections, meta: meta)
        }
    }

    // MARK: - Data fetch
    private func fetchContent(kind: VisitKind) throws -> (patient: PatientRow, sections: [ReportSection], meta: [String:String]) {
        guard let dbURL = appState.currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else {
            throw NSError(domain: "Report", code: 1, userInfo: [NSLocalizedDescriptionKey: "No DB for current bundle"])
        }
        guard let patient = appState.selectedPatient else {
            throw NSError(domain: "Report", code: 2, userInfo: [NSLocalizedDescriptionKey: "No selected patient"])
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw NSError(domain: "Report", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to open DB"])
        }
        defer { sqlite3_close(db) }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]

        var sections: [ReportSection] = []
        var visitDate = ""
        var visitType = ""
        var clinicianName = ""

        // Active clinician (signature)
        if let uid = appState.activeUserID, let c = clinicianStore.users.first(where: { $0.id == uid }) {
            let n = (c.firstName + " " + c.lastName).trimmingCharacters(in: .whitespaces)
            clinicianName = n.isEmpty ? "Clinician #\(c.id)" : n
        }

        switch kind {
        case .sick(let episodeID):
            visitType = "Sick Visit"
            // date
            visitDate = fetchScalar(db, "SELECT COALESCE(visit_date, created_at, updated_at, '') FROM episodes WHERE id=? LIMIT 1;", bind: episodeID) ?? ""

            let mainComplaint = fetchScalar(db, "SELECT main_complaint FROM episodes WHERE id=? LIMIT 1;", bind: episodeID)
            let problems      = fetchScalar(db, "SELECT problem_listing FROM episodes WHERE id=? LIMIT 1;", bind: episodeID)
            let dx            = fetchScalar(db, "SELECT diagnosis FROM episodes WHERE id=? LIMIT 1;", bind: episodeID)
            let icd10         = fetchScalar(db, "SELECT icd10 FROM episodes WHERE id=? LIMIT 1;", bind: episodeID)

            if let v = mainComplaint, !v.isEmpty { sections.append(.init(title: "Main Complaint", body: v)) }
            if let v = problems, !v.isEmpty { sections.append(.init(title: "Problem Listing", body: v)) }
            if let v = dx, !v.isEmpty {
                let dxLine = icd10.map { "\(v) (ICD-10: \($0))" } ?? v
                sections.append(.init(title: "Diagnosis", body: dxLine))
            }

        case .well(let visitID):
            visitType = "Well Visit"
            visitDate = fetchScalar(db, "SELECT COALESCE(visit_date, created_at, updated_at, '') FROM well_visits WHERE id=? LIMIT 1;", bind: visitID) ?? ""

            let problems   = fetchScalar(db, "SELECT problem_listing FROM well_visits WHERE id=? LIMIT 1;", bind: visitID)
            let conclusions = fetchScalar(db, "SELECT conclusions FROM well_visits WHERE id=? LIMIT 1;", bind: visitID)

            if let v = problems, !v.isEmpty { sections.append(.init(title: "Problem Listing", body: v)) }
            if let v = conclusions, !v.isEmpty { sections.append(.init(title: "Conclusions / Plan", body: v)) }
        }

        let headerName = patient.fullName.isEmpty ? (patient.alias.isEmpty ? "Patient #\(patient.id)" : patient.alias) : patient.fullName
        var meta: [String:String] = [
            "Patient": headerName,
            "DOB": patient.dobISO,
            "Sex": patient.sex,
            "Visit Type": visitType,
            "Visit Date": visitDate,
        ]
        if !clinicianName.isEmpty {
            meta["Clinician"] = clinicianName
        }
        return (patient, sections, meta)
    }

    private func fetchScalar(_ db: OpaquePointer?, _ sql: String, bind: Int) -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(bind))
        if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
            let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        return nil
    }

    // MARK: - Renderers
    private func renderPDF(patient: PatientRow, sections: [ReportSection], meta: [String:String]) throws -> URL {
        let doc = PDFDocument()
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter, points
        let margin: CGFloat = 54

        let page = PDFPage()
        let view = NSView(frame: pageRect.insetBy(dx: 0, dy: 0))

        // Build an attributed string
        let content = NSMutableAttributedString()

        func add(_ text: String, font: NSFont, color: NSColor = .labelColor, spacingAfter: CGFloat = 6) {
            let att = NSMutableAttributedString(string: text + "\n", attributes: [
                .font: font,
                .foregroundColor: color
            ])
            content.append(att)
            content.append(NSAttributedString(string: String(repeating: " ", count: Int(spacingAfter))))
        }

        // Header
        add("Clinical Report", font: .systemFont(ofSize: 20, weight: .semibold))
        var metaLines: [String] = []
        for (k,v) in meta {
            metaLines.append("\(k): \(v)")
        }
        add(metaLines.sorted().joined(separator: "   •   "), font: .systemFont(ofSize: 11), color: .secondaryLabelColor, spacingAfter: 12)

        // Sections
        for s in sections {
            add(s.title, font: .systemFont(ofSize: 14, weight: .semibold))
            add(s.body, font: .systemFont(ofSize: 12))
            content.append(NSAttributedString(string: "\n"))
        }

        // Layout with NSTextView for pagination (simple single-page for now)
        let textView = NSTextView(frame: pageRect.insetBy(dx: margin, dy: margin))
        textView.isEditable = false
        textView.textStorage?.setAttributedString(content)
        view.addSubview(textView)

        // Render to PDF
        let data = view.dataWithPDF(inside: view.bounds)
        guard let pdf = PDFDocument(data: data) else {
            throw NSError(domain: "Report", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create PDF"])
        }

        // Save
        let out = try makeExportURL(suggested: makeFileName(meta: meta, ext: "pdf"))
        pdf.write(to: out)
        return out
    }

    private func renderRTF(patient: PatientRow, sections: [ReportSection], meta: [String:String]) throws -> URL {
        let doc = NSMutableAttributedString()
        func add(_ text: String, font: NSFont, color: NSColor = .labelColor) {
            doc.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        add("Clinical Report", font: .systemFont(ofSize: 20, weight: .semibold))
        let metaLine = meta.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "   •   ")
        add(metaLine, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        doc.append(NSAttributedString(string: "\n"))

        for s in sections {
            add(s.title, font: .systemFont(ofSize: 14, weight: .semibold))
            add(s.body, font: .systemFont(ofSize: 12))
            doc.append(NSAttributedString(string: "\n"))
        }

        let rtf = try doc.data(from: NSRange(location: 0, length: doc.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let out = try makeExportURL(suggested: makeFileName(meta: meta, ext: "rtf"))
        try rtf.write(to: out, options: .atomic)
        return out
    }

    private func makeFileName(meta: [String:String], ext: String) -> String {
        let patient = meta["Patient"]?.replacingOccurrences(of: " ", with: "_") ?? "patient"
        let date = meta["Visit Date"]?.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: " ", with: "_") ?? ISO8601DateFormatter().string(from: Date())
        let type = (meta["Visit Type"] ?? "visit").replacingOccurrences(of: " ", with: "_").lowercased()
        return "\(patient)_\(type)_report_\(date).\(ext)"
    }

    private func makeExportURL(suggested: String) throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return dir.appendingPathComponent(suggested, isDirectory: false)
    }
}
