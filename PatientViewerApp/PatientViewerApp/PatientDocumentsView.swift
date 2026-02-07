//
//  PatientDocumentsView.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/14/25.
//

import SwiftUI
import UniformTypeIdentifiers
import QuickLook
import PDFKit
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
    // Stored list to avoid SwiftUI type-checker blowups from complex computed expressions.
    static let supported: [UTType] = {
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
    }()
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

    // Keep as a stored property to reduce SwiftUI type inference work.
    private let allowedContentTypes: [UTType] = AllowedDocTypes.supported

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
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.accentColor)
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
                    SupportLog.shared.info("DOCS upload tap")
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
                    allowedContentTypes: allowedContentTypes,
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
                            .fill(AppTheme.card)
                    )
                } else {
                    VStack(spacing: 12) {
                        ForEach(records) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Image(systemName: "doc.text")
                                        .foregroundColor(.accentColor)

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
                                        SupportLog.shared.info("DOCS delete tap | fileTok=\(AppLog.token(record.filename))")
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
                                    .fill(AppTheme.card)
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
            SupportLog.shared.info("UI open patient documents")
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
            documentsLog.debug("Preview dismissed.")
            SupportLog.shared.info("DOCS preview dismissed")
            isPreviewing = false
            wrappedPreviewURL = nil
        }) { (identifiableURL: IdentifiableURL) in
            // Avoid QuickLook for PDFs and images: QL can expose extra share entry points.
            let ext = identifiableURL.url.pathExtension.lowercased()
            if ext == "pdf" {
                PDFPreview(url: identifiableURL.url)
            } else if ["png", "jpg", "jpeg", "heic", "gif", "tif", "tiff", "bmp", "webp"].contains(ext) {
                ImagePreview(url: identifiableURL.url)
            } else {
                QuickLookPreview(url: identifiableURL.url)
            }
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
                SupportLog.shared.info("DOCS delete confirm | fileTok=\(AppLog.token(record.filename))")
                deleteRecord(record)
            }
            Button(L("common.cancel"), role: .cancel) {
                SupportLog.shared.info("DOCS delete cancel | fileTok=\(AppLog.token(record.filename))")
            }
        } message: { record in
            Text(record.originalName)
        }
        .appBackground()
    }

    // MARK: - File Handling

    private func openFile(record: DocumentRecord) {
        let docsFolder = dbURL.appendingPathComponent("docs")
        let fileURL = docsFolder.appendingPathComponent(record.filename)
        documentsLog.debug("Attempting to open file | file=DOC#\(AppLog.token(fileURL.lastPathComponent), privacy: .public)")
        SupportLog.shared.info("DOCS preview tap | fileTok=\(AppLog.token(record.filename))")

        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard !isPreviewing else {
                documentsLog.debug("Ignoring preview tap while another preview is active.")
                return
            }
            documentsLog.info("Presenting QuickLook | file=DOC#\(AppLog.token(fileURL.lastPathComponent), privacy: .public)")
            SupportLog.shared.info("DOCS preview present | fileTok=\(AppLog.token(record.filename))")
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
        let fileTok = AppLog.token(record.filename)

        documentsLog.info("Deleting document | nameTok=\(nameTok, privacy: .public) ext=\(ext, privacy: .public)")

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
                documentsLog.debug("Removed file | file=DOC#\(AppLog.token(fileURL.lastPathComponent), privacy: .public)")
                SupportLog.shared.info("DOCS delete file ok | fileTok=\(fileTok)")
            } else {
                documentsLog.warning("File to delete not found | file=DOC#\(AppLog.token(fileURL.lastPathComponent), privacy: .public)")
                SupportLog.shared.info("DOCS delete missing | fileTok=\(fileTok)")
            }

            // If currently previewing this file, dismiss the preview.
            if let current = wrappedPreviewURL, current.url == fileURL {
                wrappedPreviewURL = nil
                isPreviewing = false
            }

            // Remove from in-memory list and persist to legacy docs manifest.
            records.removeAll { $0.id == record.id || $0.filename == record.filename }
            saveManifest()

            // Always log the list update (even if file was already missing).
            SupportLog.shared.info("DOCS delete record removed | fileTok=\(fileTok)")
        } catch {
            documentsLog.error("Failed to delete file: \(String(describing: error), privacy: .private)")
            SupportLog.shared.info("DOCS delete failed | fileTok=\(fileTok) err=\(error.localizedDescription)")
            alertMessage = LF("patientDocs.error.deleteFailed_fmt", error.localizedDescription)
            showAlert = true
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let sourceURL = try result.get().first else {
                documentsLog.warning("FileImporter returned empty selection.")
                SupportLog.shared.info("DOCS import empty selection")
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
            SupportLog.shared.info("DOCS import ok | srcTok=\(srcTok) ext=\(ext) storedTok=\(AppLog.token(filename))")
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
            SupportLog.shared.info("DOCS import failed | err=\(error.localizedDescription)")
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
            documentsLog.debug("Attempting to read manifest from ROOT | file=\(url.lastPathComponent, privacy: .public)")
            do {
                let data = try Data(contentsOf: url)
                // Expect object with "files" map: { "files": { "filename": { ...meta... } } }
                if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Support both schemas:
                    //  1) { "files": { ... } }
                    //  2) { "docs": { "files": { ... } } }
                    let filesMap: [String: Any]?
                    if let m = root["files"] as? [String: Any] {
                        filesMap = m
                    } else if let docs = root["docs"] as? [String: Any],
                              let m = docs["files"] as? [String: Any] {
                        filesMap = m
                    } else {
                        filesMap = nil
                    }

                    if let filesMap {
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

                            loaded.append(DocumentRecord(
                                id: id,
                                filename: filename,
                                originalName: originalName,
                                uploadedAt: uploadedAt
                            ))
                        }

                        // Sort newest first if timestamps look present
                        records = loaded.sorted { $0.uploadedAt > $1.uploadedAt }
                        documentsLog.info("Loaded \(records.count, privacy: .public) record(s) from root manifest.")
                        return true
                    }
                }
            } catch {
                documentsLog.error("Failed to read root manifest: \(String(describing: error), privacy: .private)")
            }
            return false
        }

        func loadFromLegacyManifest(url: URL) -> Bool {
            documentsLog.debug("Attempting to read manifest from LEGACY docs/ | file=\(url.lastPathComponent, privacy: .public)")
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
        // Prefer the authoritative ROOT manifest when present (exporter writes hashes/metadata there).
        if fm.fileExists(atPath: rootManifest.path) {
            didLoad = loadFromRootManifest(url: rootManifest)
        }
        // Fallback to legacy docs/manifest.json for in-app uploads or older bundles.
        if !didLoad, fm.fileExists(atPath: legacyManifest.path) {
            didLoad = loadFromLegacyManifest(url: legacyManifest)
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
            SupportLog.shared.info("DOCS manifest save ok | count=\(records.count)")
        } catch {
            documentsLog.error("Failed to save legacy manifest: \(String(describing: error), privacy: .public)")
            SupportLog.shared.info("DOCS manifest save failed | err=\(error.localizedDescription)")
            alertMessage = LF("patientDocs.error.saveManifestFailed_fmt", error.localizedDescription)
            showAlert = true
        }
    }

    private func formattedNow() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}


// MARK: - Image Preview (UIKit)

struct ImagePreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = ImagePreviewViewController(url: url)
        let nav = UINavigationController(rootViewController: vc)
        vc.navController = nav
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        // no-op
    }
}

final class ImagePreviewViewController: UIViewController {
    let url: URL
    weak var navController: UINavigationController?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 6.0
        scrollView.delegate = self

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true

        view.addSubview(scrollView)
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),

            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        // Load the image
        if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
            imageView.image = img
        }

        navigationItem.largeTitleDisplayMode = .never

        let shareItem = UIBarButtonItem(
            barButtonSystemItem: .action,
            target: self,
            action: #selector(shareTapped)
        )
        shareItem.accessibilityIdentifier = "image.share"

        let doneItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(doneTapped)
        )
        doneItem.accessibilityIdentifier = "image.done"

        navigationItem.rightBarButtonItem = shareItem
        navigationItem.leftBarButtonItem = doneItem

        SupportLog.shared.info("DOCS image preview present | fileTok=\(AppLog.token(url.lastPathComponent))")
    }

    @objc private func doneTapped() {
        SupportLog.shared.info("DOCS image preview dismissed")
        navController?.dismiss(animated: true)
    }

    @objc private func shareTapped() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let proc = ProcessInfo.processInfo.processName
        SupportLog.shared.info("SupportLog target | pid=\(pid) proc=\(proc)")

        SupportLog.shared.info("DOCS share tap | fileTok=\(AppLog.token(url.lastPathComponent))")

        // Stage a stable share copy in Documents/ShareCopies
        let fm = FileManager.default
        let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let shareDir = docsURL.appendingPathComponent("ShareCopies", isDirectory: true)
        if !fm.fileExists(atPath: shareDir.path) {
            try? fm.createDirectory(at: shareDir, withIntermediateDirectories: true)
        }

        let safeName = sanitizeFilenameComponent(url.lastPathComponent)
        let dest = shareDir.appendingPathComponent(safeName)

        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: url, to: dest)
        } catch {
            // If copy fails, we will share the original URL.
        }

        let shareURL = fm.fileExists(atPath: dest.path) ? dest : url
        SupportLog.shared.info("DOCS share url | fileTok=\(AppLog.token(shareURL.lastPathComponent)) useCopy=\(shareURL == dest)")

        let activityVC = UIActivityViewController(
            activityItems: [DocumentShareItemSource(fileURL: shareURL)],
            applicationActivities: nil
        )
        activityVC.completionWithItemsHandler = { activityType, completed, returnedItems, error in
            let fileTok = AppLog.token(shareURL.lastPathComponent)
            let act = activityType?.rawValue ?? "(nil)"
            let itemsCount = returnedItems?.count ?? 0

            if let error = error {
                SupportLog.shared.info("DOCS share failed | fileTok=\(fileTok) act=\(act) items=\(itemsCount) err=\(error.localizedDescription)")
            } else {
                SupportLog.shared.info("DOCS share finished | fileTok=\(fileTok) completed=\(completed) act=\(act) items=\(itemsCount)")
            }
        }

        activityVC.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        SupportLog.shared.info("DOCS share sheet present | fileTok=\(AppLog.token(shareURL.lastPathComponent))")
        present(activityVC, animated: true)
    }
}

extension ImagePreviewViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }
}

// MARK: - PDF Preview (PDFKit)

struct PDFPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = PDFPreviewViewController(url: url)
        let nav = UINavigationController(rootViewController: vc)
        vc.navController = nav
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        // no-op
    }
}

final class PDFPreviewViewController: UIViewController {
    let url: URL
    weak var navController: UINavigationController?

    private let pdfView = PDFView()

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.usePageViewController(true, withViewOptions: nil)

        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        if let doc = PDFDocument(url: url) {
            pdfView.document = doc
        }

        navigationItem.largeTitleDisplayMode = .never

        let shareItem = UIBarButtonItem(
            barButtonSystemItem: .action,
            target: self,
            action: #selector(shareTapped)
        )
        shareItem.accessibilityIdentifier = "pdf.share"

        let doneItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(doneTapped)
        )
        doneItem.accessibilityIdentifier = "pdf.done"

        navigationItem.rightBarButtonItem = shareItem
        navigationItem.leftBarButtonItem = doneItem

        SupportLog.shared.info("DOCS pdf preview present | fileTok=\(AppLog.token(url.lastPathComponent))")
    }

    @objc private func doneTapped() {
        SupportLog.shared.info("DOCS pdf preview dismissed")
        navController?.dismiss(animated: true)
    }

    @objc private func shareTapped() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let proc = ProcessInfo.processInfo.processName
        SupportLog.shared.info("SupportLog target | pid=\(pid) proc=\(proc)")

        SupportLog.shared.info("DOCS share tap | fileTok=\(AppLog.token(url.lastPathComponent))")

        // Stage a stable share copy in Documents/ShareCopies (same strategy as QuickLookPreview)
        let fm = FileManager.default
        let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let shareDir = docsURL.appendingPathComponent("ShareCopies", isDirectory: true)
        if !fm.fileExists(atPath: shareDir.path) {
            try? fm.createDirectory(at: shareDir, withIntermediateDirectories: true)
        }

        let safeName = sanitizeFilenameComponent(url.lastPathComponent)
        let dest = shareDir.appendingPathComponent(safeName)

        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: url, to: dest)
        } catch {
            // If copy fails, we will share the original URL.
        }

        let shareURL = fm.fileExists(atPath: dest.path) ? dest : url
        SupportLog.shared.info("DOCS share url | fileTok=\(AppLog.token(shareURL.lastPathComponent)) useCopy=\(shareURL == dest)")

        let activityVC = UIActivityViewController(
            activityItems: [DocumentShareItemSource(fileURL: shareURL)],
            applicationActivities: nil
        )
        activityVC.completionWithItemsHandler = { activityType, completed, returnedItems, error in
            let fileTok = AppLog.token(shareURL.lastPathComponent)
            let act = activityType?.rawValue ?? "(nil)"
            let itemsCount = returnedItems?.count ?? 0

            if let error = error {
                SupportLog.shared.info("DOCS share failed | fileTok=\(fileTok) act=\(act) items=\(itemsCount) err=\(error.localizedDescription)")
            } else {
                SupportLog.shared.info("DOCS share finished | fileTok=\(fileTok) completed=\(completed) act=\(act) items=\(itemsCount)")
            }
        }

        activityVC.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        SupportLog.shared.info("DOCS share sheet present | fileTok=\(AppLog.token(shareURL.lastPathComponent))")
        present(activityVC, animated: true)
    }
}

// MARK: - QuickLook Preview

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

        // Hide QuickLook's bottom toolbar (it can show extra actions/buttons).
        // We keep only our explicit nav bar buttons (Share + Done).
        nav.setToolbarHidden(true, animated: false)
        preview.toolbarItems = []

        // Install bar buttons immediately so we can reliably log taps.
        // Some OS versions/layouts show a temporary width==0 during first layout; we re-apply once on next runloop as a fallback.
        let fileTok = AppLog.token(self.url.lastPathComponent)

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
        SupportLog.shared.info("DOCS ql buttons installed | fileTok=\(fileTok)")

        DispatchQueue.main.async {
            preview.navigationItem.rightBarButtonItem = shareItem
            preview.navigationItem.leftBarButtonItem = doneItem
            SupportLog.shared.info("DOCS ql buttons reinstalled | fileTok=\(fileTok)")
        }

        Self.log.debug("Prepared QLPreview | file=DOC#\(AppLog.token(self.url.lastPathComponent), privacy: .public)")
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
            let pid = ProcessInfo.processInfo.processIdentifier
            let proc = ProcessInfo.processInfo.processName

            QuickLookPreview.log.info("SupportLog target | pid=\(pid, privacy: .public) proc=\(proc, privacy: .public)")
            SupportLog.shared.info("SupportLog target | pid=\(pid) proc=\(proc)")

            QuickLookPreview.log.info("Share tapped | file=DOC#\(AppLog.token(self.url.lastPathComponent), privacy: .public)")
            SupportLog.shared.info("DOCS share tap | fileTok=\(AppLog.token(self.url.lastPathComponent))")

            // Share extensions (especially on Catalyst) are happier with a stable, user-accessible file.
            // Stage a named copy in Documents/ShareCopies and share the URL via an item source.
            let fm = FileManager.default

            let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            let shareDir = docsURL.appendingPathComponent("ShareCopies", isDirectory: true)
            if !fm.fileExists(atPath: shareDir.path) {
                try? fm.createDirectory(at: shareDir, withIntermediateDirectories: true)
            }

            // Keep original name, but sanitize for maximum compatibility.
            let safeName = sanitizeFilenameComponent(self.url.lastPathComponent)
            let dest = shareDir.appendingPathComponent(safeName)

            do {
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: self.url, to: dest)
                QuickLookPreview.log.debug("Prepared share copy | file=DOC#\(AppLog.token(dest.lastPathComponent), privacy: .public)")
            } catch {
                QuickLookPreview.log.error("Failed to create share copy (using original): \(String(describing: error), privacy: .public)")
            }

            let shareURL = fm.fileExists(atPath: dest.path) ? dest : self.url
            SupportLog.shared.info("DOCS share url | fileTok=\(AppLog.token(shareURL.lastPathComponent)) useCopy=\(shareURL == dest)")

            // Use UIActivityItemSource so the share sheet receives a filename early.
            let activityVC = UIActivityViewController(activityItems: [DocumentShareItemSource(fileURL: shareURL)], applicationActivities: nil)
            activityVC.completionWithItemsHandler = { activityType, completed, returnedItems, error in
                let fileTok = AppLog.token(shareURL.lastPathComponent)
                let act = activityType?.rawValue ?? "(nil)"
                let itemsCount = returnedItems?.count ?? 0

                if let error = error {
                    QuickLookPreview.log.error("Share failed: \(String(describing: error), privacy: .public)")
                    SupportLog.shared.info("DOCS share failed | fileTok=\(fileTok) act=\(act) items=\(itemsCount) err=\(error.localizedDescription)")
                } else {
                    QuickLookPreview.log.info("Share finished. completed=\(completed, privacy: .public) act=\(act, privacy: .public) items=\(itemsCount, privacy: .public)")
                    SupportLog.shared.info("DOCS share finished | fileTok=\(fileTok) completed=\(completed) act=\(act) items=\(itemsCount)")
                }
            }

            // iPad/iPhone support: anchor to the Share bar button if available
            if let barButton = navController?.topViewController?.navigationItem.rightBarButtonItem {
                activityVC.popoverPresentationController?.barButtonItem = barButton
            } else {
                activityVC.popoverPresentationController?.sourceView = navController?.view
                activityVC.popoverPresentationController?.sourceRect = CGRect(
                    x: navController?.view.bounds.midX ?? 0,
                    y: navController?.view.bounds.midY ?? 0,
                    width: 1,
                    height: 1
                )
                activityVC.popoverPresentationController?.permittedArrowDirections = []
            }

            SupportLog.shared.info("DOCS share sheet present | fileTok=\(AppLog.token(shareURL.lastPathComponent))")
            navController?.present(activityVC, animated: true)
        }

        @objc func doneTapped() {
            QuickLookPreview.log.debug("Done tapped, dismissing preview.")
            navController?.dismiss(animated: true)
        }
    }
}

// MARK: - Share helpers (documents)

/// Activity item source that preserves the filename and provides a stable file URL.
final class DocumentShareItemSource: NSObject, UIActivityItemSource {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        // Returning a URL gives ShareKit a filename early.
        return fileURL
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        return fileURL
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        if #available(iOS 14.0, *) {
            // Best-effort: derive type from extension, otherwise generic "public.data".
            if let t = UTType(filenameExtension: fileURL.pathExtension) {
                return t.identifier
            }
            return UTType.data.identifier
        } else {
            return "public.data"
        }
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        return fileURL.deletingPathExtension().lastPathComponent
    }
}

/// Conservative filename sanitizer for share compatibility across iOS/Mac Catalyst.
private func sanitizeFilenameComponent(_ s: String) -> String {
    let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
    let parts = s.components(separatedBy: forbidden)
    let joined = parts.joined(separator: "-")

    let ws = CharacterSet.whitespacesAndNewlines
    let spaced = joined.components(separatedBy: ws).filter { !$0.isEmpty }.joined(separator: "_")

    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
    let asciiSafe = String(spaced.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })

    let collapsed = asciiSafe
        .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
        .replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-_ ."))

    return collapsed.isEmpty ? "document" : collapsed
}
