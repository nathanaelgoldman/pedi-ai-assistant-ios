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

struct VisitSummary: Identifiable {
    let id: Int64
    let date: String
    let type: String
    let category: String
}

struct PDFGenerator {
    static func generateVisitPDF(visit: VisitSummary) -> URL? {
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

        do {
            let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fileURL = docsURL.appendingPathComponent("VisitReport_\(visit.id).pdf")
            try data.write(to: fileURL)
            return fileURL
        } catch {
            print("❌ Failed to save PDF: \(error)")
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
                        if visit.category == "sick" {
                            if let fileURL = SickVisitPDFGenerator.generate(for: visit, dbURL: dbURL) {
                                DispatchQueue.main.async {
                                    self.generatedPDFURL = IdentifiableURL(url: fileURL)
                                    self.showingPDFPreview = true
                                }
                            } else {
                                print("❌ SickVisitPDFGenerator returned nil")
                            }
                        } else {
                            if visit.category == "well" {
                                Task {
                                    do {
                                        if let fileURL = try await WellVisitPDFGenerator.generate(for: visit, dbURL: dbURL) {
                                            DispatchQueue.main.async {
                                                self.generatedPDFURL = IdentifiableURL(url: fileURL)
                                                self.showingPDFPreview = true
                                            }
                                        } else {
                                            print("❌ WellVisitPDFGenerator returned nil")
                                        }
                                    } catch {
                                        print("❌ Error generating Well Visit PDF: \(error)")
                                    }
                                }
                            } else {
                                if let fileURL = PDFGenerator.generateVisitPDF(visit: visit) {
                                    DispatchQueue.main.async {
                                        self.generatedPDFURL = IdentifiableURL(url: fileURL)
                                        self.showingPDFPreview = true
                                    }
                                } else {
                                    print("❌ PDFGenerator returned nil")
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
        .navigationTitle("Visit Details")
        .sheet(item: $generatedPDFURL) { identifiableURL in
            PDFPreviewContainer(fileURL: identifiableURL.url)
        }
        .padding()
        .navigationTitle("Visit Details")
        .alert(isPresented: $showExportAlert) {
            Alert(title: Text("✅ PDF Generated"), message: Text("Report saved to Files app."), dismissButton: .default(Text("OK")))
        }
        .sheet(item: $generatedPDFURL) { identifiableURL in
            PDFPreviewContainer(fileURL: identifiableURL.url)
        }
    }
}

struct PDFPreviewContainer: SwiftUI.View {
    let fileURL: URL
    @Environment(\.dismiss) private var dismiss

    var body: some SwiftUI.View {
        NavigationView {
            if let document = PDFDocument(url: fileURL) {
                PDFKitView(document: document)
                    .navigationTitle("PDF Preview")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                dismiss()
                            }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            ShareButton(fileURL: fileURL)
                        }
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
            .padding()

            List(filteredVisits) { visit in
                NavigationLink(destination: VisitDetailView(visit: visit, dbURL: dbURL)) {
                    VStack(alignment: .leading) {
                        Text("📅 \(formatDate(visit.date))")
                        Text("🩺 \(visit.type)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Visit Summaries")
        .onAppear {
            loadVisits()
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
        
        let dbPath = dbURL.appendingPathComponent("db.sqlite").path
        do {
            let db = try Connection(dbPath)

            // 🩵 Load Well Visits
            let wellVisitsTable = Table("well_visits")
            let id = Expression<Int64>("id")
            let recordedAt = Expression<String?>("recorded_at")
            let createdAt = Expression<String?>("created_at")
            let visitType = Expression<String?>("visit_type")

            var newVisits: [VisitSummary] = []

            for row in try db.prepare(wellVisitsTable) {
                let date = (try? row.get(recordedAt)) ?? (try? row.get(createdAt)) ?? "—"
                let type = (try? row.get(visitType)) ?? "Well Visit"
                newVisits.append(VisitSummary(id: row[id], date: date, type: type, category: "well"))
            }

            // 🩷 Load Sick Visits
            let episodesTable = Table("episodes")
            let diagnosis = Expression<String?>("diagnosis")
            let createdAtE = Expression<String?>("created_at")

            for row in try db.prepare(episodesTable) {
                let date = (try? row.get(createdAtE)) ?? "—"
                let type = (try? row.get(diagnosis)) ?? "Sick Visit"
                newVisits.append(VisitSummary(id: row[id], date: date, type: type, category: "sick"))
            }
            self.allVisits = newVisits
        } catch {
            print("❌ Failed to read visits: \(error)")
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

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ShareButton: SwiftUI.View {
    let fileURL: URL
    @State private var showShareSheet = false

    var body: some SwiftUI.View {
        Button(action: {
            showShareSheet = true
        }) {
            Image(systemName: "square.and.arrow.up")
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityView(activityItems: [fileURL])
        }
    }
}
