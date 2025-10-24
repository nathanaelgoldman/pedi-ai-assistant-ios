//
//  PatientDocumentsView.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/14/25.
//

import SwiftUI
import UniformTypeIdentifiers
import QuickLook
import UIKit
import OSLog


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

private let documentsLog = Logger(subsystem: "Yunastic.PatientViewerApp", category: "Documents")

struct PatientDocumentsView: View {
    let dbURL: URL

    @State private var records: [DocumentRecord] = []
    @State private var showImporter = false
    @State private var alertMessage: String?
    @State private var showAlert = false
    @State private var wrappedPreviewURL: IdentifiableURL?
    @State private var didLoadOnce = false
    @State private var isPreviewing = false
    @State private var confirmDelete: DocumentRecord?

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
                            .disabled(isPreviewing)
                            Button(role: .destructive) {
                                confirmDelete = record
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            Spacer()
                        }
                    }
                    Divider()
                }
            }
        }
        .padding()
        .onAppear {
            guard !didLoadOnce else { return }
            documentsLog.info("Documents view appeared. Base=\(dbURL.path, privacy: .public)")
            loadManifest()
            didLoadOnce = true
        }
        .alert("Error", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            if let msg = alertMessage {
                Text(msg)
            }
        }
        .sheet(item: $wrappedPreviewURL, onDismiss: {
            documentsLog.debug("QuickLook dismissed.")
            isPreviewing = false
            wrappedPreviewURL = nil
        }) { (identifiableURL: IdentifiableURL) in
            QuickLookPreview(url: identifiableURL.url)
        }
        .confirmationDialog(
            "Delete this document?",
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmDelete
        ) { record in
            Button("Delete", role: .destructive) {
                deleteRecord(record)
            }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text(record.originalName)
        }
    }

    // MARK: - File Handling

    private func openFile(record: DocumentRecord) {
        let docsFolder = dbURL.appendingPathComponent("docs")
        let fileURL = docsFolder.appendingPathComponent(record.filename)
        documentsLog.debug("Attempting to open file: \(fileURL.path, privacy: .public)")

        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard !isPreviewing else {
                documentsLog.debug("Ignoring preview tap while another preview is active.")
                return
            }
            documentsLog.info("Presenting QuickLook for: \(fileURL.lastPathComponent, privacy: .public)")
            isPreviewing = true
            wrappedPreviewURL = IdentifiableURL(url: fileURL)
        } else {
            documentsLog.error("File not found at path: \(fileURL.path, privacy: .public)")
            alertMessage = "File not found: \(record.originalName)"
            showAlert = true
        }
    }

    private func deleteRecord(_ record: DocumentRecord) {
        let docsFolder = dbURL.appendingPathComponent("docs")
        let fileURL = docsFolder.appendingPathComponent(record.filename)
        documentsLog.info("Deleting document '\(record.originalName, privacy: .public)' (\(record.filename, privacy: .public))")

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
                documentsLog.debug("Removed file at path: \(fileURL.path, privacy: .public)")
            } else {
                documentsLog.warning("File to delete not found at path: \(fileURL.path, privacy: .public)")
            }

            // If currently previewing this file, dismiss the preview.
            if let current = wrappedPreviewURL, current.url == fileURL {
                wrappedPreviewURL = nil
                isPreviewing = false
            }

            // Remove from in-memory list and persist to legacy docs manifest.
            records.removeAll { $0.id == record.id || $0.filename == record.filename }
            saveManifest()
        } catch {
            documentsLog.error("Failed to delete file: \(String(describing: error), privacy: .public)")
            alertMessage = "Delete failed: \(error.localizedDescription)"
            showAlert = true
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let sourceURL = try result.get().first else {
                documentsLog.warning("FileImporter returned empty selection.")
                return
            }

            let filename = UUID().uuidString + (sourceURL.pathExtension.isEmpty ? "" : ".\(sourceURL.pathExtension)")
            let docsFolder = dbURL.appendingPathComponent("docs")
            let destinationURL = docsFolder.appendingPathComponent(filename)

            try FileManager.default.createDirectory(at: docsFolder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            documentsLog.info("Imported document '\(sourceURL.lastPathComponent, privacy: .public)' → \(filename, privacy: .public)")

            let newRecord = DocumentRecord(
                id: UUID(),
                filename: filename,
                originalName: sourceURL.lastPathComponent,
                uploadedAt: formattedNow()
            )

            records.insert(newRecord, at: 0)
            saveManifest()
        } catch {
            documentsLog.error("Import failed: \(String(describing: error), privacy: .public)")
            alertMessage = "Import failed: \(error.localizedDescription)"
            showAlert = true
        }
    }

    private func loadManifest() {
        let fm = FileManager.default
        let rootManifest = dbURL.appendingPathComponent("manifest.json")
        let legacyManifest = dbURL.appendingPathComponent("docs/manifest.json")

        func loadFromRootManifest(url: URL) -> Bool {
            documentsLog.debug("Attempting to read manifest from ROOT: \(url.path, privacy: .public)")
            do {
                let data = try Data(contentsOf: url)
                // Expect object with "files" map: { "files": { "filename": { ...meta... } } }
                if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let filesMap = root["files"] as? [String: Any] {
                    var loaded: [DocumentRecord] = []
                    for (filename, metaAny) in filesMap {
                        let meta = metaAny as? [String: Any] ?? [:]
                        // Accept either "originalName" or "title"
                        let originalName = (meta["originalName"] as? String)
                                          ?? (meta["title"] as? String)
                                          ?? filename
                        let uploadedAt = (meta["uploadedAt"] as? String) ?? "Unknown"
                        // Use stable UUID if present (optional), else new one
                        let idString = meta["id"] as? String
                        let id = UUID(uuidString: idString ?? "") ?? UUID()
                        loaded.append(DocumentRecord(id: id,
                                                     filename: filename,
                                                     originalName: originalName,
                                                     uploadedAt: uploadedAt))
                    }
                    // Sort newest first if timestamps look present
                    records = loaded.sorted { $0.uploadedAt > $1.uploadedAt }
                    documentsLog.info("Loaded \(records.count, privacy: .public) record(s) from root manifest.")
                    return true
                }
            } catch {
                documentsLog.error("Failed to read root manifest: \(String(describing: error), privacy: .public)")
            }
            return false
        }

        func loadFromLegacyManifest(url: URL) -> Bool {
            documentsLog.debug("Attempting to read manifest from LEGACY docs/: \(url.path, privacy: .public)")
            do {
                let data = try Data(contentsOf: url)
                // Try legacy array schema first
                if let decoded = try? JSONDecoder().decode([DocumentRecord].self, from: data) {
                    records = decoded
                    documentsLog.info("Loaded \(decoded.count, privacy: .public) record(s) from legacy docs manifest (array).")
                    return true
                }
                // Fallback: legacy object with "files" map
                if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let filesMap = root["files"] as? [String: Any] {
                    var loaded: [DocumentRecord] = []
                    for (filename, metaAny) in filesMap {
                        let meta = metaAny as? [String: Any] ?? [:]
                        let originalName = (meta["originalName"] as? String)
                                          ?? (meta["title"] as? String)
                                          ?? filename
                        let uploadedAt = (meta["uploadedAt"] as? String) ?? "Unknown"
                        let idString = meta["id"] as? String
                        let id = UUID(uuidString: idString ?? "") ?? UUID()
                        loaded.append(DocumentRecord(id: id,
                                                     filename: filename,
                                                     originalName: originalName,
                                                     uploadedAt: uploadedAt))
                    }
                    records = loaded.sorted { $0.uploadedAt > $1.uploadedAt }
                    documentsLog.info("Loaded \(records.count, privacy: .public) record(s) from legacy docs manifest (map).")
                    return true
                }
            } catch {
                documentsLog.error("Failed to read legacy manifest: \(String(describing: error), privacy: .public)")
            }
            return false
        }

        var didLoad = false
        if fm.fileExists(atPath: legacyManifest.path) {
            didLoad = loadFromLegacyManifest(url: legacyManifest)
        }
        if !didLoad, fm.fileExists(atPath: rootManifest.path) {
            didLoad = loadFromRootManifest(url: rootManifest)
        }
        if !didLoad {
            documentsLog.warning("No manifest.json found at root or docs/. Showing empty list.")
            records = []
        }
    }

    private func saveManifest() {
        // We intentionally write the legacy docs/manifest.json for in-app uploads.
        // The exporter builds the authoritative root manifest with hashes at export time.
        let manifestURL = dbURL.appendingPathComponent("docs/manifest.json")
        do {
            try FileManager.default.createDirectory(
                at: manifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(records)
            try data.write(to: manifestURL, options: [.atomic])
            documentsLog.info("Saved legacy docs manifest at: \(manifestURL.path, privacy: .public)")
        } catch {
            alertMessage = "Failed to save manifest."
            showAlert = true
            documentsLog.error("Failed to save legacy manifest: \(String(describing: error), privacy: .public)")
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

    private static let log = Logger(subsystem: "Yunastic.PatientViewerApp", category: "QuickLook")

    // We wrap the QLPreviewController in a UINavigationController so we can add our own bar buttons.
    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator

        // Add explicit Done and Share buttons.
        let shareItem = UIBarButtonItem(barButtonSystemItem: .action, target: context.coordinator, action: #selector(Coordinator.shareTapped))
        let doneItem = UIBarButtonItem(barButtonSystemItem: .done, target: context.coordinator, action: #selector(Coordinator.doneTapped))
        preview.navigationItem.rightBarButtonItem = shareItem
        preview.navigationItem.leftBarButtonItem = doneItem

        let nav = UINavigationController(rootViewController: preview)
        context.coordinator.navController = nav

        Self.log.debug("Prepared QLPreview for \(self.url.lastPathComponent, privacy: .public)")
        return nav
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        // no-op
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        weak var navController: UINavigationController?

        init(url: URL) {
            self.url = url
        }

        // MARK: - QLPreviewControllerDataSource

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            return url as NSURL
        }

        // MARK: - Actions

        @objc func shareTapped() {
            QuickLookPreview.log.info("Share tapped for \(self.url.lastPathComponent, privacy: .public)")
            
            // Stage a copy in a temp location so any extension can read it safely.
            let tmpDir = FileManager.default.temporaryDirectory
            let stagedURL = tmpDir.appendingPathComponent(self.url.lastPathComponent)
            var provider: NSItemProvider?
            
            do {
                if FileManager.default.fileExists(atPath: stagedURL.path) {
                    try FileManager.default.removeItem(at: stagedURL)
                }
                try FileManager.default.copyItem(at: self.url, to: stagedURL)
                provider = NSItemProvider(contentsOf: stagedURL)
                QuickLookPreview.log.debug("Staged share copy at \(stagedURL.path, privacy: .public)")
            } catch {
                QuickLookPreview.log.error("Failed to stage share copy: \(String(describing: error), privacy: .public). Falling back to direct provider.")
                provider = NSItemProvider(contentsOf: self.url)
            }
            
            guard let itemProvider = provider else {
                QuickLookPreview.log.error("Failed to create NSItemProvider for share.")
                return
            }
            // Preserve the original filename in the share sheet when possible.
            itemProvider.suggestedName = self.url.lastPathComponent
            
            let activityVC = UIActivityViewController(activityItems: [itemProvider], applicationActivities: nil)
            activityVC.completionWithItemsHandler = { _, completed, _, error in
                if let error = error {
                    QuickLookPreview.log.error("Share failed: \(String(describing: error), privacy: .public)")
                } else {
                    QuickLookPreview.log.info("Share finished. completed=\(completed, privacy: .public)")
                }
                // Best-effort cleanup for the staged file.
                try? FileManager.default.removeItem(at: stagedURL)
            }
            
            // iPad/iPhone support: anchor to the Share bar button if available
            if let barButton = navController?.topViewController?.navigationItem.rightBarButtonItem {
                activityVC.popoverPresentationController?.barButtonItem = barButton
            } else {
                activityVC.popoverPresentationController?.sourceView = navController?.view
            }
            navController?.present(activityVC, animated: true)
        }

        @objc func doneTapped() {
            QuickLookPreview.log.debug("Done tapped, dismissing preview.")
            navController?.dismiss(animated: true)
        }
    }
}
