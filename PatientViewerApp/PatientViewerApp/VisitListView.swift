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
    return formatter
}()

// Structured logger for Visit-related flows (lists, details, PDF generation)

private let logVisits = Logger(subsystem: "com.yunastic.PatientViewerApp", category: "visits")

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
            logVisits.info("Saved PDF to \(fileURL.path, privacy: .public) (\(dataSize) bytes)")
            return fileURL
        } catch {
            logVisits.error("Failed to save PDF: \(String(describing: error))")
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

                GroupBox(label: Label(L("patient_viewer.visit_detail.section.report", comment: "Section title"), systemImage: "doc.text")) {
                    Button(action: {
                        logVisits.info("Preview PDF tapped for visit id=\(visit.id, privacy: .public) category=\(visit.category, privacy: .public)")
                        if visit.category == "sick" {
                            logVisits.info("Generating SickVisit PDF for id=\(visit.id, privacy: .public)")
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
            }
            .padding()
        }
        .onAppear {
            logVisits.info("VisitDetailView appeared id=\(visit.id, privacy: .public) date=\(visit.date, privacy: .public) category=\(visit.category, privacy: .public)")
        }
        .navigationTitle(L("patient_viewer.visit_detail.nav_title", comment: "Navigation title"))
        .sheet(item: $generatedPDFURL) { identifiableURL in
            PDFPreviewContainer(fileURL: identifiableURL.url)
        }
        .padding()
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
    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet = false

    var body: some SwiftUI.View {
        NavigationView {
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
                                    showShareSheet = true
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
                        Text(fileURL.path)
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
        .sheet(isPresented: $showShareSheet) {
            ActivityView(activityItems: [PDFShareItemSource(fileURL: fileURL)])
        }
    }
}

private func formatDate(_ raw: String) -> String {
    if let date = inputDateFormatter.date(from: raw) {
        return outputDateFormatter.string(from: date)
    } else {
        return raw
    }
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
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

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
                .background(Color(.secondarySystemBackground))
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
        }
        .navigationTitle(L("patient_viewer.visits.list.nav_title", comment: "Navigation title"))
        .onAppear {
            let path = dbURL.appendingPathComponent("db.sqlite").path
            logVisits.info("VisitListView appeared with db=\(path, privacy: .public)")
            loadVisits()
        }
        .onDisappear {
            logVisits.info("VisitListView disappeared")
        }
    }

    func formatDate(_ raw: String) -> String {
        if let date = inputDateFormatter.date(from: raw) {
            return outputDateFormatter.string(from: date)
        } else {
            return raw
        }
    }

    func loadVisits() {
        let start = Date()
        
        let dbPath = dbURL.appendingPathComponent("db.sqlite").path
        logVisits.info("Loading visits from \(dbPath, privacy: .public)")
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
                .fill(Color(.systemBackground))
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
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

final class PDFShareItemSource: NSObject, UIActivityItemSource {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init()
    }

    // Placeholder required by UIActivityViewController
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return Data()
    }

    // Provide raw PDF data instead of a sandboxed file URL to avoid LSSharing/CKShare errors
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        if let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) {
            return data
        } else {
            // Fallback to the URL if data read fails
            return fileURL
        }
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

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}
