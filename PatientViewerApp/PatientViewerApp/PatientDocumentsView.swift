//
//  PatientDocumentsView.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/14/25.
//

import SwiftUI
import UniformTypeIdentifiers
import QuickLook


struct DocumentRecord: Identifiable, Codable {
    let id: UUID
    let filename: String
    let originalName: String
    let uploadedAt: String

    init(id: UUID = UUID(), filename: String, originalName: String, uploadedAt: String) {
        self.id = id
        self.filename = filename
        self.originalName = originalName
        self.uploadedAt = uploadedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.filename = try container.decode(String.self, forKey: .filename)
        self.originalName = (try? container.decode(String.self, forKey: .originalName)) ?? self.filename
        self.uploadedAt = (try? container.decode(String.self, forKey: .uploadedAt)) ?? "Unknown"
    }
}


struct PatientDocumentsView: View {
    let dbURL: URL

    @State private var records: [DocumentRecord] = []
    @State private var selectedFileURL: URL?
    @State private var showImporter = false
    @State private var alertMessage: String?
    @State private var showAlert = false
    @State private var previewedFileURL: URL?
    @State private var wrappedPreviewURL: IdentifiableURL?

    private struct IdentifiableURL: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("📁 Patient Documents")
                .font(.title2)
                .bold()

            Button("📤 Upload Document") {
                showImporter = true
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.pdf, .image],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }

            Divider()

            if records.isEmpty {
                Text("No documents uploaded yet.")
                    .foregroundStyle(.gray)
            } else {
                ForEach(records) { record in
                    VStack(alignment: .leading) {
                        Text("📄 \(record.originalName)")
                            .font(.headline)
                        Text("Uploaded: \(record.uploadedAt)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("🧾 Preview") {
                                openFile(record: record)
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                        }
                    }
                    Divider()
                }
            }
        }
        .padding()
        .onAppear {
            loadManifest()
        }
        .alert("Error", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            if let msg = alertMessage {
                Text(msg)
            }
        }
        .sheet(item: $wrappedPreviewURL) { (identifiableURL: IdentifiableURL) in
            QuickLookWrapperView(url: identifiableURL.url)
        }
    }

    // MARK: - File Handling

    private func openFile(record: DocumentRecord) {
        let docsFolder = dbURL.appendingPathComponent("docs")
        let fileURL = docsFolder.appendingPathComponent(record.filename)
        print("[DEBUG] Attempting to open file: \(fileURL.path)")

        if FileManager.default.fileExists(atPath: fileURL.path) {
            print("[DEBUG] File exists, presenting QuickLook: \(fileURL.lastPathComponent)")
            // Set wrappedPreviewURL directly
            wrappedPreviewURL = IdentifiableURL(url: fileURL)
        } else {
            print("[ERROR] File not found at path: \(fileURL.path)")
            alertMessage = "File not found: \(record.originalName)"
            showAlert = true
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            let selected = try result.get().first
            guard let sourceURL = selected else { return }

            let filename = UUID().uuidString + "." + sourceURL.pathExtension
            let docsFolder = dbURL.appendingPathComponent("docs")
            let destinationURL = docsFolder.appendingPathComponent(filename)

            try FileManager.default.createDirectory(at: docsFolder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            let newRecord = DocumentRecord(
                id: UUID(),
                filename: filename,
                originalName: sourceURL.lastPathComponent,
                uploadedAt: formattedNow()
            )

            records.insert(newRecord, at: 0)
            saveManifest()
        } catch {
            alertMessage = "Import failed: \(error.localizedDescription)"
            showAlert = true
        }
    }

    private func loadManifest() {
        let manifestURL = dbURL.appendingPathComponent("docs/manifest.json")
        print("[DEBUG] Attempting to read manifest from: \(manifestURL.path)")
        do {
            let data = try Data(contentsOf: manifestURL)
            let decoded = try JSONDecoder().decode([DocumentRecord].self, from: data)
            records = decoded
        } catch {
            print("[ERROR] Failed to read manifest: \(error)")
            records = []  // fallback to empty
        }
    }

    private func saveManifest() {
        let manifestURL = dbURL.appendingPathComponent("docs/manifest.json")
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: manifestURL)
        } catch {
            alertMessage = "Failed to save manifest."
            showAlert = true
        }
    }

    private func formattedNow() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            return url as NSURL
        }
    }
}

struct QuickLookWrapperView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            QuickLookPreview(url: url)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
    }
}
