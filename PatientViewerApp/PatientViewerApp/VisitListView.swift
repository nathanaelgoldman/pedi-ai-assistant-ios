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
            kCGPDFContextCreator: "Patient Viewer",
            kCGPDFContextAuthor: "Patient App",
            kCGPDFContextTitle: "Visit Report"
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

            drawText("Visit Report", font: titleFont)
            drawText("Date: \(visit.date)", font: bodyFont)
            drawText("Diagnosis: \(visit.type)", font: bodyFont)
            drawText("Category: \(visit.category.capitalized)", font: bodyFont)
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
                GroupBox(label: Label("Visit Information", systemImage: "info.circle")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Date: \(formatDate(visit.date))", systemImage: "calendar")
                        Label("Diagnosis: \(visit.type)", systemImage: "stethoscope")
                        Label("Category: \(visit.category.capitalized)", systemImage: "folder")
                    }
                    .padding(.top, 4)
                }

                GroupBox(label: Label("Report", systemImage: "doc.text")) {
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
                        Label("Preview PDF Report", systemImage: "doc.richtext")
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
        .navigationTitle("Visit Details")
        .sheet(item: $generatedPDFURL) { identifiableURL in
            PDFPreviewContainer(fileURL: identifiableURL.url)
        }
        .padding()
        .alert(isPresented: $showExportAlert) {
            Alert(title: Text("✅ PDF Generated"), message: Text("Report saved to Files app."), dismissButton: .default(Text("OK")))
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
                        .navigationTitle("PDF Preview")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") {
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
                        Text("❌ Could not load PDF.")
                            .foregroundColor(.red)
                        Text("Path:")
                        Text(fileURL.path)
                            .font(.caption)
                            .foregroundColor(.gray)
                            .padding()
                        Button("Done") {
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
        VStack {
            Picker("Visit Type", selection: $selectedCategory) {
                Text("🧒 Well Visits").tag("well")
                Text("🤒 Sick Visits").tag("sick")
            }
            .pickerStyle(SegmentedPickerStyle())
            .onChange(of: selectedCategory) { oldValue, newValue in
                logVisits.info("VisitList filter changed from \(oldValue, privacy: .public) to \(newValue, privacy: .public)")
            }
            .padding()

            List(filteredVisits) { visit in
                NavigationLink(destination: VisitDetailView(visit: visit, dbURL: dbURL)) {
                    VStack(alignment: .leading) {
                        Text("📅 \(formatDate(visit.date))")
                        Text("🩺 \(visit.type)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
            }
        }
        .navigationTitle("Visit Summaries")
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
                let type = (try? row.get(visitType)) ?? "Well Visit"
                newVisits.append(VisitSummary(id: row[id], date: date, type: type, category: "well"))
                wellCount += 1
            }

            // 🩷 Load Sick Visits
            let episodesTable = Table("episodes")
            let diagnosis = Expression<String?>("diagnosis")
            let createdAtE = Expression<String?>("created_at")

            for row in try db.prepare(episodesTable) {
                let date = (try? row.get(createdAtE)) ?? "—"
                let type = (try? row.get(diagnosis)) ?? "Sick Visit"
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
