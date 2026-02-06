//
//  VisitListView.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/9/25.
//

import SwiftUI
import SQLite
import PDFKit
import UIKit
import Foundation
import os
import UniformTypeIdentifiers

let inputDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

let outputDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

// Structured logger for Visit-related flows (lists, details, PDF generation)

private let logVisits = AppLog.feature("visits")


// MARK: - Localization (file-local)
@inline(__always)
private func L(_ key: String, comment: String = "") -> String {
    NSLocalizedString(key, comment: comment)
}

@inline(__always)
private func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

// Well-visit milestone code -> localized display title
@inline(__always)
private func wellVisitTitle(_ code: String) -> String {
    switch code {
    case "one_month": return L("patient_viewer.well_visit.title.one_month", comment: "Well visit title")
    case "two_month": return L("patient_viewer.well_visit.title.two_month", comment: "Well visit title")
    case "four_month": return L("patient_viewer.well_visit.title.four_month", comment: "Well visit title")
    case "six_month": return L("patient_viewer.well_visit.title.six_month", comment: "Well visit title")
    case "nine_month": return L("patient_viewer.well_visit.title.nine_month", comment: "Well visit title")
    case "twelve_month": return L("patient_viewer.well_visit.title.twelve_month", comment: "Well visit title")
    case "fifteen_month": return L("patient_viewer.well_visit.title.fifteen_month", comment: "Well visit title")
    case "eighteen_month": return L("patient_viewer.well_visit.title.eighteen_month", comment: "Well visit title")
    case "twentyfour_month": return L("patient_viewer.well_visit.title.twentyfour_month", comment: "Well visit title")
    case "thirty_month": return L("patient_viewer.well_visit.title.thirty_month", comment: "Well visit title")
    case "thirtysix_month": return L("patient_viewer.well_visit.title.thirtysix_month", comment: "Well visit title")
    case "newborn_first": return L("patient_viewer.well_visit.title.newborn_first", comment: "Well visit title")
    case "four_year": return L("patient_viewer.well_visit.title.four_year", comment: "Well visit title")
    case "five_year": return L("patient_viewer.well_visit.title.five_year", comment: "Well visit title")
    default:
        return code
    }
}

struct VisitSummary: Identifiable {
    let id: Int64
    let date: String
    let type: String
    let category: String
}

struct PDFGenerator {
    static func generateVisitPDF(visit: VisitSummary) -> URL? {
        logVisits.info("Generating simple PDF for visit id=\(visit.id, privacy: .public) category=\(visit.category, privacy: .public) date=\(visit.date, privacy: .public)")
        let pdfMetaData = [
            kCGPDFContextCreator: L("patient_viewer.pdf.meta.creator", comment: "PDF metadata"),
            kCGPDFContextAuthor: L("patient_viewer.pdf.meta.author", comment: "PDF metadata"),
            kCGPDFContextTitle: L("patient_viewer.pdf.meta.title", comment: "PDF metadata")
        ]
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = pdfMetaData as [String: Any]

        let pageWidth = 595.2
        let pageHeight = 841.8
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)

        let data = renderer.pdfData { context in
            context.beginPage()
            let titleFont = UIFont.boldSystemFont(ofSize: 20)
            let bodyFont = UIFont.systemFont(ofSize: 14)

            var y: CGFloat = 40
            func drawText(_ text: String, font: UIFont) {
                let attributes: [NSAttributedString.Key: Any] = [.font: font]
                let attrString = NSAttributedString(string: text, attributes: attributes)
                attrString.draw(at: CGPoint(x: 40, y: y))
                y += font.lineHeight + 10
            }

            drawText(L("patient_viewer.pdf.fallback.title", comment: "Fallback visit PDF title"), font: titleFont)
            drawText(LF("patient_viewer.pdf.fallback.date", visit.date), font: bodyFont)
            drawText(LF("patient_viewer.pdf.fallback.diagnosis", visit.type), font: bodyFont)
            drawText(LF("patient_viewer.pdf.fallback.category", visit.category.capitalized), font: bodyFont)
        }
        let dataSize = data.count

        do {
            let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fileURL = docsURL.appendingPathComponent("VisitReport_\(visit.id).pdf")
            try data.write(to: fileURL)
            logVisits.info("Saved PDF \(fileURL.lastPathComponent, privacy: .public) (\(dataSize, privacy: .public) bytes)")
            return fileURL
        } catch {
            let ns = error as NSError
            logVisits.error("Failed to save PDF (domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public))")
            return nil
        }
    }
}

struct VisitDetailView: SwiftUI.View {
    let visit: VisitSummary
    let dbURL: URL
    @State private var showExportAlert = false
    @State private var generatedPDFURL: IdentifiableURL?
    @State private var showingPDFPreview = false

    var body: some SwiftUI.View {
        ZStack {
            AppTheme.background
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    GroupBox(label: Label(L("patient_viewer.visit_detail.section.info", comment: "Section title"), systemImage: "info.circle")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(LF("patient_viewer.visit_detail.field.date", formatDate(visit.date)), systemImage: "calendar")
                            Label(LF("patient_viewer.visit_detail.field.diagnosis", visit.type), systemImage: "stethoscope")
                            Label(LF("patient_viewer.visit_detail.field.category", visit.category.capitalized), systemImage: "folder")
                        }
                        .padding(.top, 4)
                    }
                    .padding(12)
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color(.quaternaryLabel), lineWidth: 0.8)
                    )

                    GroupBox(label: Label(L("patient_viewer.visit_detail.section.report", comment: "Section title"), systemImage: "doc.text")) {
                        Button(action: {
                            logVisits.info("Preview PDF tapped for visit id=\(visit.id, privacy: .public) category=\(visit.category, privacy: .public)")
                            if visit.category == "sick" {
                                let dbFileURL = dbURL.appendingPathComponent("db.sqlite")
                                logVisits.info("Generating SickVisit PDF | id=\(visit.id, privacy: .public) db=\(AppLog.dbRef(dbFileURL), privacy: .public)")
                                if let fileURL = SickVisitPDFGenerator.generate(for: visit, dbURL: dbURL) {
                                    logVisits.info("SickVisit PDF prepared at \(fileURL.lastPathComponent, privacy: .public)")
                                    DispatchQueue.main.async {
                                        self.generatedPDFURL = IdentifiableURL(url: fileURL)
                                        self.showingPDFPreview = true
                                    }
                                } else {
                                    logVisits.error("SickVisitPDFGenerator returned nil")
                                }
                            } else {
                                if visit.category == "well" {
                                    Task {
                                        logVisits.info("Generating WellVisit PDF for id=\(visit.id, privacy: .public)")
                                        do {
                                            if let fileURL = try await WellVisitPDFGenerator.generate(for: visit, dbURL: dbURL) {
                                                logVisits.info("WellVisit PDF prepared at \(fileURL.lastPathComponent, privacy: .public)")
                                                DispatchQueue.main.async {
                                                    self.generatedPDFURL = IdentifiableURL(url: fileURL)
                                                    self.showingPDFPreview = true
                                                }
                                            } else {
                                                logVisits.error("WellVisitPDFGenerator returned nil")
                                            }
                                        } catch {
                                            logVisits.error("Error generating Well Visit PDF: \(String(describing: error))")
                                        }
                                    }
                                } else {
                                    logVisits.info("Generating fallback simple PDF for id=\(visit.id, privacy: .public)")
                                    if let fileURL = PDFGenerator.generateVisitPDF(visit: visit) {
                                        logVisits.info("Fallback PDF prepared at \(fileURL.lastPathComponent, privacy: .public)")
                                        DispatchQueue.main.async {
                                            self.generatedPDFURL = IdentifiableURL(url: fileURL)
                                            self.showingPDFPreview = true
                                        }
                                    } else {
                                        logVisits.error("PDFGenerator returned nil")
                                    }
                                }
                            }
                        }) {
                            Label(L("patient_viewer.visit_detail.action.preview_pdf", comment: "Button"), systemImage: "doc.richtext")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                    }
                    .padding(12)
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color(.quaternaryLabel), lineWidth: 0.8)
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
        .onAppear {
            logVisits.info("VisitDetailView appeared id=\(visit.id, privacy: .public) date=\(visit.date, privacy: .public) category=\(visit.category, privacy: .public)")
        }
        .navigationTitle(L("patient_viewer.visit_detail.nav_title", comment: "Navigation title"))
        .sheet(item: $generatedPDFURL) { identifiableURL in
            PDFPreviewContainer(fileURL: identifiableURL.url, visit: visit, dbURL: dbURL)
        }
        .alert(isPresented: $showExportAlert) {
            Alert(
                title: Text(L("patient_viewer.visit_detail.alert.pdf_generated.title", comment: "Alert title")),
                message: Text(L("patient_viewer.visit_detail.alert.pdf_generated.message", comment: "Alert message")),
                dismissButton: .default(Text(L("patient_viewer.common.ok", comment: "Common")))
            )
        }
    }
}

struct PDFPreviewContainer: SwiftUI.View {
    let fileURL: URL
    let visit: VisitSummary
    let dbURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: IdentifiableURL?

    var body: some SwiftUI.View {
        NavigationView {
            ZStack {
                AppTheme.background
                    .ignoresSafeArea()

                Group {
                    if let document = PDFDocument(url: fileURL) {
                        PDFKitView(document: document)
                            .navigationTitle(L("patient_viewer.pdf_preview.nav_title", comment: "Navigation title"))
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button(L("patient_viewer.common.done", comment: "Common")) {
                                        logVisits.info("PDFPreview Done tapped for \(fileURL.lastPathComponent, privacy: .public)")
                                        dismiss()
                                    }
                                }
                                ToolbarItem(placement: .primaryAction) {
                                    Button {
                                        logVisits.info("PDFPreview Share tapped for \(fileURL.lastPathComponent, privacy: .public)")

                                        // Build the named copy first, then present using a non-nil Identifiable URL.
                                        // Using `.sheet(item:)` avoids the “No items to share” first-tap race.
                                        let shareCopyURL = makeNamedShareCopy(originalURL: fileURL, visit: visit, bundleRoot: dbURL)

                                        // Support log breadcrumb (matches SupportLog export/sick patterns)
                                        let shareTok = AppLog.token(shareCopyURL.lastPathComponent)
                                        SupportLog.shared.info("UI share sheet present | visitTok=\(AppLog.token(String(visit.id))) fileTok=\(shareTok) cat=\(visit.category)")

                                        DispatchQueue.main.async {
                                            self.shareURL = IdentifiableURL(url: shareCopyURL)
                                        }
                                    } label: {
                                        Image(systemName: "square.and.arrow.up")
                                    }
                                }
                            }
                            .onAppear {
                                logVisits.info("PDFPreview presented: \(fileURL.lastPathComponent, privacy: .public)")
                            }
                    } else {
                        VStack {
                            Text(L("patient_viewer.pdf_preview.error.could_not_load", comment: "Error"))
                                .foregroundColor(.red)
                            Text(L("patient_viewer.pdf_preview.label.path", comment: "Label"))
                            Text(fileURL.lastPathComponent)
                                .font(.caption)
                                .foregroundColor(.gray)
                                .padding()
                            Button(L("patient_viewer.common.done", comment: "Common")) {
                                dismiss()
                            }
                            .padding()
                        }
                    }
                }
            }
        }
        .sheet(item: $shareURL, onDismiss: {
            SupportLog.shared.info("UI share sheet dismissed")
            // Reset between runs so the next share always starts clean.
            self.shareURL = nil
        }) { identifiable in
            ActivityView(activityItems: [PDFShareItemSource(fileURL: identifiable.url)])
        }
    }
}

private func formatDate(_ raw: String) -> String {
    if let d = parseVisitDate(raw) {
        return outputDateFormatter.string(from: d)
    }
    return raw
}

struct VisitListView: SwiftUI.View {
    let dbURL: URL
    @State private var allVisits: [VisitSummary] = []
    @State private var selectedCategory: String = "well"

    var filteredVisits: [VisitSummary] {
        allVisits
            .filter { $0.category == selectedCategory }
            .sorted { $0.date > $1.date }
    }

    var body: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text(L("patient_viewer.visits.list.title", comment: "Screen title"))
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(L("patient_viewer.visits.list.subtitle", comment: "Screen subtitle"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 4)

            // Segmented picker in a subtle card
            VStack {
                Picker(L("patient_viewer.visits.list.picker.label", comment: "Picker label"), selection: $selectedCategory) {
                    Text(L("patient_viewer.visits.list.segment.well", comment: "Segment")).tag("well")
                    Text(L("patient_viewer.visits.list.segment.sick", comment: "Segment")).tag("sick")
                }
                .pickerStyle(.segmented)
            }
            .padding(8)
            .background(AppTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onChange(of: selectedCategory) { oldValue, newValue in
                logVisits.info("VisitList filter changed from \(oldValue, privacy: .public) to \(newValue, privacy: .public)")
            }

            // Visits list as cards
            if filteredVisits.isEmpty {
                Spacer()

                VStack(spacing: 8) {
                    Image(systemName: selectedCategory == "well" ? "figure.child" : "bandage")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundColor(.secondary)

                    Text(selectedCategory == "well"
                        ? L("patient_viewer.visits.list.empty.well", comment: "Empty state")
                        : L("patient_viewer.visits.list.empty.sick", comment: "Empty state")
                    )
                        .font(.headline)
                        .foregroundColor(.secondary)

                    Text(L("patient_viewer.visits.list.empty.hint", comment: "Empty state hint"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredVisits) { visit in
                            NavigationLink {
                                VisitDetailView(visit: visit, dbURL: dbURL)
                            } label: {
                                VisitCard(visit: visit)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .navigationTitle(L("patient_viewer.visits.list.nav_title", comment: "Navigation title"))
        .appBackground()
        .appNavBarBackground()
        .onAppear {
            let dbFileURL = dbURL.appendingPathComponent("db.sqlite")
            logVisits.info("VisitListView appeared | db=\(AppLog.dbRef(dbFileURL), privacy: .public)")
            loadVisits()
        }
        .onDisappear {
            logVisits.info("VisitListView disappeared")
        }
    }

    func formatDate(_ raw: String) -> String {
        if let d = parseVisitDate(raw) {
            return outputDateFormatter.string(from: d)
        }
        return raw
    }

    func loadVisits() {
        let start = Date()
        
        let dbPath = dbURL.appendingPathComponent("db.sqlite").path
        let dbFileURL = dbURL.appendingPathComponent("db.sqlite")
        logVisits.info("Loading visits | db=\(AppLog.dbRef(dbFileURL), privacy: .public)")
        do {
            let db = try Connection(dbPath)

            // 🩵 Load Well Visits
            let wellVisitsTable = Table("well_visits")
            let id = Expression<Int64>("id")
            let recordedAt = Expression<String?>("recorded_at")
            let createdAt = Expression<String?>("created_at")
            let visitType = Expression<String?>("visit_type")

            var newVisits: [VisitSummary] = []
            var wellCount = 0
            var sickCount = 0

            for row in try db.prepare(wellVisitsTable) {
                let date = (try? row.get(recordedAt)) ?? (try? row.get(createdAt)) ?? "—"
                let rawType = (try? row.get(visitType)) ?? ""
                let type = rawType.isEmpty
                    ? L("patient_viewer.well_visit.title.default", comment: "Default well visit title")
                    : wellVisitTitle(rawType)
                newVisits.append(VisitSummary(id: row[id], date: date, type: type, category: "well"))
                wellCount += 1
            }

            // 🩷 Load Sick Visits
            let episodesTable = Table("episodes")
            let diagnosis = Expression<String?>("diagnosis")
            let createdAtE = Expression<String?>("created_at")

            for row in try db.prepare(episodesTable) {
                let date = (try? row.get(createdAtE)) ?? "—"
                let type = (try? row.get(diagnosis)) ?? L("patient_viewer.sick_visit.title.default", comment: "Default sick visit title")
                newVisits.append(VisitSummary(id: row[id], date: date, type: type, category: "sick"))
                sickCount += 1
            }
            self.allVisits = newVisits
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            logVisits.info("Loaded \(newVisits.count) visits (well: \(wellCount), sick: \(sickCount)) in \(ms) ms")
        } catch {
            logVisits.error("Failed to read visits: \(String(describing: error))")
        }
    }
}

struct VisitCard: SwiftUI.View {
    let visit: VisitSummary

    private var iconName: String {
        switch visit.category {
        case "well":
            return "heart.text.square"
        case "sick":
            return "bandage"
        default:
            return "doc.text.magnifyingglass"
        }
    }

    private var categoryLabel: String {
        switch visit.category {
        case "well":
            return L("patient_viewer.visits.card.category.well", comment: "Category label")
        case "sick":
            return L("patient_viewer.visits.card.category.sick", comment: "Category label")
        default:
            return visit.category.capitalized
        }
    }

    var body: some SwiftUI.View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.systemBlue).opacity(0.08))

                Image(systemName: iconName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Color(.systemBlue))
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(formatDate(visit.date))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                Text(visit.type.isEmpty ? L("patient_viewer.visits.card.no_title", comment: "Fallback") : visit.type)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text(categoryLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(.tertiaryLabel))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(.quaternaryLabel), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
    }
}

struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)

        // IMPORTANT: On iPad and Mac Catalyst, UIActivityViewController presents as a popover.
        // If no sourceView/sourceRect is set, it can crash at presentation time.
        if let pop = controller.popoverPresentationController {
            pop.sourceView = controller.view
            pop.sourceRect = CGRect(x: controller.view.bounds.midX,
                                    y: controller.view.bounds.midY,
                                    width: 1, height: 1)
            pop.permittedArrowDirections = []
        }

        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // no-op
    }
}

final class PDFShareItemSource: NSObject, UIActivityItemSource {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init()
    }

    // Placeholder required by UIActivityViewController
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        // IMPORTANT: On Mac Catalyst, ShareKit needs a filename early.
        // Returning a URL guarantees a name.
        return fileURL
    }

    // Provide item
    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        // Always provide a file URL, for ALL activity types.
        // This preserves the filename and avoids ShareKit / FileProvider “can’t fetch item” issues.
        return fileURL
    }

    // Declare the UTI / content type for the data we return
    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        if #available(iOS 14.0, *) {
            return UTType.pdf.identifier
        } else {
            return "com.adobe.pdf"
        }
    }

    // Nice-to-have subject for Mail
    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        return fileURL.deletingPathExtension().lastPathComponent
    }
}

// MARK: - Share filename helpers
private func makeNamedShareCopy(originalURL: URL, visit: VisitSummary, bundleRoot: URL) -> URL {
    let fm = FileManager.default

    let (aliasFromDB, _) = fetchPatientAliasAndDOB(bundleRoot: bundleRoot)
    let aliasPartRaw = (aliasFromDB?.isEmpty == false) ? aliasFromDB! : bundleRoot.lastPathComponent
    let aliasPart = sanitizeFilenameComponent(aliasPartRaw)

    let visitDate = parseVisitDate(visit.date)
    let visitDatePart = (visitDate != nil) ? formatDateForFilename(visitDate!) : "unknownDate"

    let visitTypePart = computeVisitTypePart(visit: visit, bundleRoot: bundleRoot)

    let savedPart = formatNowForFilename(Date())

    let appNameRaw = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? "PatientViewerApp"
    let appPart = sanitizeFilenameComponent(appNameRaw)

    // Example: Amber_Unicorn_🦋_36_month_visit_20251210_saved-20260107-123045_PatientViewerApp.pdf
    let fileName = "\(aliasPart)_\(visitTypePart)_\(visitDatePart)_saved-\(savedPart)_\(appPart).pdf"

    // NOTE: Share / FileProvider on macOS/Catalyst can be picky about transient locations.
    // Use Documents/ShareCopies so the file is in a stable, user-accessible sandbox.
    let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
    let shareDir = docsURL.appendingPathComponent("ShareCopies", isDirectory: true)
    if !fm.fileExists(atPath: shareDir.path) {
        try? fm.createDirectory(at: shareDir, withIntermediateDirectories: true)
    }

    let dest = shareDir.appendingPathComponent(fileName)

    do {
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: originalURL, to: dest)
        let tok = AppLog.token(dest.lastPathComponent)
        logVisits.info("Prepared share copy | nameTok=\(tok, privacy: .public)")
        return dest
    } catch {
        logVisits.error("Failed to create share copy (using original): \(String(describing: error))")
        return originalURL
    }
}

private func fetchPatientAliasAndDOB(bundleRoot: URL) -> (alias: String?, dob: Date?) {
    let dbPath = bundleRoot.appendingPathComponent("db.sqlite").path

    do {
        let db = try Connection(dbPath)

        // Try the most common schema: patients(id, alias, dob)
        do {
            let patients = Table("patients")
            let id = Expression<Int64>("id")
            let alias = Expression<String?>("alias")
            let dob = Expression<String?>("dob")

            if let row = try db.pluck(patients.filter(id == 1)) ?? db.pluck(patients.limit(1)) {
                let aliasStr = (try? row.get(alias)) ?? nil
                let dobStr = (try? row.get(dob)) ?? nil
                return (aliasStr, parseDOB(dobStr))
            }
        } catch {
            // Fall through to other attempts
        }

        // Some exports may store demographics elsewhere; best-effort fallback.
        return (nil, nil)
    } catch {
        logVisits.error("Could not open DB for patient info: \(String(describing: error))")
        return (nil, nil)
    }
}

private func parseDOB(_ raw: String?) -> Date? {
    guard let raw = raw, !raw.isEmpty else { return nil }
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    df.dateFormat = "yyyy-MM-dd"
    return df.date(from: raw)
}

private func parseVisitDate(_ raw: String) -> Date? {
    let rawTrim = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if rawTrim.isEmpty || rawTrim == "—" { return nil }

    // 1) First try real ISO8601 parsing (handles trailing Z and timezone offsets).
    //    Try fractional seconds first, then non-fractional.
    let isoFrac = ISO8601DateFormatter()
    isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = isoFrac.date(from: rawTrim) { return d }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: rawTrim) { return d }

    // 2) Fallback to explicit DateFormatter patterns (legacy/variant exports)
    let formats = [
        // Common ISO-ish exports
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
        "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd",

        // ISO-ish exports with timezone suffix (e.g. ...Z)
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'",

        // Compact ISO-ish exports (no dashes/colons)
        "yyyyMMdd'T'HHmmss.SSSSSS",
        "yyyyMMdd'T'HHmmss.SSS",
        "yyyyMMdd'T'HHmmss",
        "yyyyMMdd"
    ]

    for f in formats {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = f
        if let d = df.date(from: rawTrim) { return d }
    }

    return nil
}

private func computeVisitTypePart(visit: VisitSummary, bundleRoot: URL) -> String {
    switch visit.category {
    case "well":
        if let code = fetchWellVisitTypeCode(visitID: visit.id, bundleRoot: bundleRoot) {
            return mapWellVisitTypeCodeToFilename(code)
        }
        let fallback = sanitizeFilenameComponent(visit.type)
        return fallback.isEmpty ? "well_visit" : fallback

    case "sick":
        let fallback = sanitizeFilenameComponent(visit.type)
        return fallback.isEmpty ? "sick_visit" : fallback

    default:
        let fallback = sanitizeFilenameComponent(visit.category)
        return fallback.isEmpty ? "visit" : fallback
    }
}

private func fetchWellVisitTypeCode(visitID: Int64, bundleRoot: URL) -> String? {
    let dbPath = bundleRoot.appendingPathComponent("db.sqlite").path

    do {
        let db = try Connection(dbPath)
        let wellVisits = Table("well_visits")
        let id = Expression<Int64>("id")
        let visitType = Expression<String?>("visit_type")

        if let row = try db.pluck(wellVisits.filter(id == visitID)) {
            let raw = (try? row.get(visitType)) ?? nil
            return (raw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? raw : nil
        }
        return nil
    } catch {
        logVisits.error("Could not fetch well visit type code: \(String(describing: error))")
        return nil
    }
}

private func mapWellVisitTypeCodeToFilename(_ codeRaw: String) -> String {
    let code = codeRaw.trimmingCharacters(in: .whitespacesAndNewlines)

    switch code {
    case "one_month": return "1_month_visit"
    case "two_month": return "2_month_visit"
    case "four_month": return "4_month_visit"
    case "six_month": return "6_month_visit"
    case "nine_month": return "9_month_visit"
    case "twelve_month": return "12_month_visit"
    case "fifteen_month": return "15_month_visit"
    case "eighteen_month": return "18_month_visit"
    case "twentyfour_month": return "24_month_visit"
    case "thirty_month": return "30_month_visit"
    case "thirtysix_month": return "36_month_visit"
    case "newborn_first": return "newborn_first_visit"
    case "four_year": return "4_year_visit"
    case "five_year": return "5_year_visit"
    default:
        let cleaned = sanitizeFilenameComponent(code)
        return cleaned.isEmpty ? "well_visit" : "\(cleaned)_visit"
    }
}

private func computeAgePart(dob: Date?, visitDate: Date?) -> String {
    guard let dob = dob, let visitDate = visitDate else { return "age-NA" }

    let cal = Calendar(identifier: .gregorian)
    let comps = cal.dateComponents([.year, .month], from: dob, to: visitDate)
    let y = max(0, comps.year ?? 0)
    let m = max(0, comps.month ?? 0)

    if y > 0 {
        return "\(y)y\(m)m"
    } else {
        return "\(m)m"
    }
}

private func formatNowForFilename(_ d: Date) -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    df.dateFormat = "yyyyMMdd-HHmmss"
    return df.string(from: d)
}

private func formatDateForFilename(_ d: Date) -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    df.dateFormat = "yyyyMMdd"
    return df.string(from: d)
}

private func sanitizeFilenameComponent(_ s: String) -> String {
    // Goal: produce a conservative, share-safe filename component.
    // Many share extensions behave poorly with emoji / some Unicode.

    // 1) Remove obvious forbidden filesystem characters.
    let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
    let parts = s.components(separatedBy: forbidden)
    let joined = parts.joined(separator: "-")

    // 2) Normalize whitespace to single underscores.
    let ws = CharacterSet.whitespacesAndNewlines
    let spaced = joined.components(separatedBy: ws).filter { !$0.isEmpty }.joined(separator: "_")

    // 3) Keep only a conservative ASCII set for maximum compatibility across iOS share targets.
    // Allowed: A-Z a-z 0-9 underscore dash dot
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
    let asciiSafe = String(spaced.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })

    // 4) Collapse repeated separators and trim.
    let collapsed = asciiSafe
        .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
        .replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-_ ."))

    return collapsed.isEmpty ? "unknown" : collapsed
}

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}
