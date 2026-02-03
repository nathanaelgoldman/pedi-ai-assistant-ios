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

// MARK: - Localization helpers
private func L(_ key: String) -> LocalizedStringKey { LocalizedStringKey(key) }
private func LF(_ formatKey: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(formatKey, comment: ""), arguments: args)
}

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
        self.uploadedAt = (try? container.decode(String.self, forKey: .uploadedAt))
            ?? NSLocalizedString("common.unknown", comment: "")
    }
}

private let documentsLog = AppLog.feature("Documents")

private enum AllowedDocTypes {
    static var supported: [UTType] {
        var types: [UTType] = [.pdf, .image]
        let extras: [UTType] = [
            UTType(filenameExtension: "doc"),
            UTType(filenameExtension: "docx"),
            UTType(filenameExtension: "pages"),
            UTType(filenameExtension: "rtf"),
            UTType(filenameExtension: "txt"),
            UTType(filenameExtension: "zip")
        ].compactMap { $0 }
        types.append(contentsOf: extras)
        return types
    }
}

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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color(.systemBlue).opacity(0.1))
                            .frame(width: 44, height: 44)
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(Color(.systemBlue))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("patientDocs.title"))
                            .font(.title2.weight(.semibold))
                        Text(L("patientDocs.subtitle"))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }

                // Upload button
                Button {
                    showImporter = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text(L("patientDocs.upload"))
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .fileImporter(
                    isPresented: $showImporter,
                    allowedContentTypes: AllowedDocTypes.supported,
                    allowsMultipleSelection: false
                ) { result in
                    handleImport(result)
                }

                // Divider between actions and list
                Divider()
                    .padding(.top, 4)

                // Document list / empty state
                if records.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 36, weight: .regular))
                            .foregroundColor(.secondary)

                        Text(L("patientDocs.empty.title"))
                            .font(.headline)

                        Text(L("patientDocs.empty.body"))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                } else {
                    VStack(spacing: 12) {
                        ForEach(records) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Image(systemName: "doc.text")
                                        .foregroundColor(Color(.systemBlue))

                                    Text(record.originalName)
                                        .font(.headline)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)

                                    Spacer()
                                }

                                Text(LF("patientDocs.uploaded_fmt", record.uploadedAt))
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                HStack(spacing: 12) {
                                    Button {
                                        openFile(record: record)
                                    } label: {
                                        Label(L("patientDocs.preview"), systemImage: "eye")
                                            .font(.subheadline)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(isPreviewing)

                                    Button(role: .destructive) {
                                        confirmDelete = record
                                    } label: {
                                        Label(L("patientDocs.delete"), systemImage: "trash")
                                            .font(.subheadline)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(.red)

                                    Spacer()
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
                            )
                        }
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
        .onAppear {
            guard !didLoadOnce else { return }
            let dbFileURL = dbURL.appendingPathComponent("db.sqlite")
            documentsLog.info("Documents view appeared | db=\(AppLog.dbRef(dbFileURL), privacy: .public)")
            loadManifest()
            didLoadOnce = true
        }
        .alert(L("common.error"), isPresented: $showAlert) {
            Button(L("common.ok"), role: .cancel) {}
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
            L("patientDocs.confirmDelete.title"),
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmDelete
        ) { record in
            Button(L("patientDocs.delete"), role: .destructive) {
                deleteRecord(record)
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { record in
            Text(record.originalName)
        }
    }

    // MARK: - File Handling

    private func openFile(record: DocumentRecord) {
        let docsFolder = dbURL.appendingPathComponent("docs")
        let fileURL = docsFolder.appendingPathComponent(record.filename)
        documentsLog.debug("Attempting to open file: \(fileURL.lastPathComponent, privacy: .public)")

        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard !isPreviewing else {
                documentsLog.debug("Ignoring preview tap while another preview is active.")
                return
            }
            documentsLog.info("Presenting QuickLook | file=DOC#\(AppLog.token(fileURL.lastPathComponent), privacy: .public)")
            isPreviewing = true
            wrappedPreviewURL = IdentifiableURL(url: fileURL)
        } else {
            documentsLog.error("File not found | file=DOC#\(AppLog.token(fileURL.lastPathComponent), privacy: .public)")
            alertMessage = LF("patientDocs.error.fileNotFound_fmt", record.originalName)
            showAlert = true
        }
    }

    private func deleteRecord(_ record: DocumentRecord) {
        let docsFolder = dbURL.appendingPathComponent("docs")
        let fileURL = docsFolder.appendingPathComponent(record.filename)
        let nameTok = AppLog.token(record.originalName)
        let ext = (record.originalName as NSString).pathExtension.lowercased()
        documentsLog.info("Deleting document | nameTok=\(nameTok, privacy: .public) ext=\(ext, privacy: .public)")

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
                documentsLog.debug("Removed file: \(fileURL.lastPathComponent, privacy: .public)")
            } else {
                documentsLog.warning("File to delete not found: \(fileURL.lastPathComponent, privacy: .public)")
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
            documentsLog.error("Failed to delete file: \(String(describing: error), privacy: .private)")
            alertMessage = LF("patientDocs.error.deleteFailed_fmt", error.localizedDescription)
            showAlert = true
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let sourceURL = try result.get().first else {
                documentsLog.warning("FileImporter returned empty selection.")
                return
            }

            // On iOS, FileImporter often returns a security-scoped URL (e.g. Files/iCloud Drive).
            // We must start accessing before reading/copying, otherwise we can get permission errors.
            let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let fm = FileManager.default
            let filename = UUID().uuidString + (sourceURL.pathExtension.isEmpty ? "" : ".\(sourceURL.pathExtension)")
            let docsFolder = dbURL.appendingPathComponent("docs")
            let destinationURL = docsFolder.appendingPathComponent(filename)

            try fm.createDirectory(at: docsFolder, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destinationURL.path) {
                try? fm.removeItem(at: destinationURL)
            }

            // Use NSFileCoordinator to safely read from provider-backed locations (iCloud Drive, etc.).
            var coordError: NSError?
            var copyError: Error?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordError) { coordinatedURL in
                do {
                    try fm.copyItem(at: coordinatedURL, to: destinationURL)
                } catch {
                    copyError = error
                }
            }

            if let coordError {
                throw coordError
            }
            if let copyError {
                throw copyError
            }

            let srcTok = AppLog.token(sourceURL.lastPathComponent)
            let ext = sourceURL.pathExtension.lowercased()
            documentsLog.info("Imported document | srcTok=\(srcTok, privacy: .public) ext=\(ext, privacy: .public) → stored=\(filename, privacy: .public)")

            let newRecord = DocumentRecord(
                id: UUID(),
                filename: filename,
                originalName: sourceURL.lastPathComponent,
                uploadedAt: formattedNow()
            )

            records.insert(newRecord, at: 0)
            saveManifest()
        } catch {
            documentsLog.error("Import failed: \(String(describing: error), privacy: .private)")
            alertMessage = LF("patientDocs.error.importFailed_fmt", error.localizedDescription)
            showAlert = true
        }
    }

    private func loadManifest() {
        let fm = FileManager.default
        let rootManifest = dbURL.appendingPathComponent("manifest.json")
        let legacyManifest = dbURL.appendingPathComponent("docs/manifest.json")

        func loadFromRootManifest(url: URL) -> Bool {
            documentsLog.debug("Attempting to read manifest from ROOT: \(url.lastPathComponent, privacy: .public)")
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
                        let uploadedAt = (meta["uploadedAt"] as? String)
                            ?? NSLocalizedString("common.unknown", comment: "")
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
                documentsLog.error("Failed to read root manifest: \(String(describing: error), privacy: .private)")
            }
            return false
        }

        func loadFromLegacyManifest(url: URL) -> Bool {
            documentsLog.debug("Attempting to read manifest from LEGACY docs/: \(url.lastPathComponent, privacy: .public)")
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
                        let uploadedAt = (meta["uploadedAt"] as? String)
                            ?? NSLocalizedString("common.unknown", comment: "")
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
                documentsLog.error("Failed to read legacy manifest: \(String(describing: error), privacy: .private)")
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
        // Finally, merge in any files that may already exist in docs/ but were missing from the manifest.
        reconcileDocsFolderWithManifest()
    }

    private func reconcileDocsFolderWithManifest() {
        let fm = FileManager.default
        let docsFolder = dbURL.appendingPathComponent("docs")
        guard let items = try? fm.contentsOfDirectory(at: docsFolder, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return
        }
        let knownFilenames = Set(records.map { $0.filename })
        var added = 0
        for url in items {
            // Skip manifest and hidden files/folders
            let name = url.lastPathComponent
            if name == "manifest.json" || name.hasPrefix(".") { continue }
            if let vals = try? url.resourceValues(forKeys: [.isDirectoryKey]), vals.isDirectory == true { continue }
            if knownFilenames.contains(name) { continue }

            // Add a minimal record for any orphan file we discover
            let rec = DocumentRecord(
                filename: name,
                originalName: name,
                uploadedAt: formattedNow()
            )
            records.insert(rec, at: 0)
            added += 1
        }
        if added > 0 {
            documentsLog.info("Reconciled \(added, privacy: .public) stray file(s) in docs/ into manifest.")
            saveManifest()
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
            documentsLog.info("Saved legacy docs manifest: \(manifestURL.lastPathComponent, privacy: .public)")
        } catch {
            alertMessage = NSLocalizedString("patientDocs.error.saveManifestFailed", comment: "")
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

    private static let log = AppLog.feature("QuickLook")

    // We wrap the QLPreviewController in a UINavigationController so we can add our own bar buttons.
    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        // Avoid large-title layouts to reduce spurious constraint logs on Simulator.
        preview.navigationItem.largeTitleDisplayMode = .never

        let nav = UINavigationController(rootViewController: preview)
        nav.navigationBar.prefersLargeTitles = false
        context.coordinator.navController = nav

        // Defer adding bar buttons until the next runloop so the nav bar has a real width.
        // This reduces "temporary width == 0" Auto Layout warnings on Simulator.
        DispatchQueue.main.async {
            let shareItem = UIBarButtonItem(
                barButtonSystemItem: .action,
                target: context.coordinator,
                action: #selector(Coordinator.shareTapped)
            )
            shareItem.accessibilityIdentifier = "ql.share"

            let doneItem = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: context.coordinator,
                action: #selector(Coordinator.doneTapped)
            )
            doneItem.accessibilityIdentifier = "ql.done"

            preview.navigationItem.rightBarButtonItem = shareItem
            preview.navigationItem.leftBarButtonItem = doneItem
        }

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
                QuickLookPreview.log.debug("Staged share copy: \(stagedURL.lastPathComponent, privacy: .public)")
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
