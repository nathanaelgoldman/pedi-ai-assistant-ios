//
//  DocumentListView.swift
//  DrsMainApp
//
//  Created by yunastic on 10/31/25.
//

import SwiftUI
import OSLog
import UniformTypeIdentifiers
import PDFKit

struct DocumentListView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedURL: URL? = nil
    @State private var files: [URL] = []
    @State private var errorMessage: String? = nil

    private let log = AppLog.feature("documents")
    private let allowedExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "docx", "txt"]

    private var docsFolder: URL? {
        guard let root = appState.currentBundleURL else { return nil }
        return root.appendingPathComponent("docs", isDirectory: true)
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                // LEFT: list
                VStack(spacing: 0) {
                    HStack {
                        Text(NSLocalizedString("docs.list.header.title",
                                               comment: "Header title for documents list in bundle documents window"))
                            .font(.headline)
                        Spacer()
                    }
                    .padding(8)

                    List(selection: $selectedURL) {
                        if files.isEmpty {
                            Text(NSLocalizedString("docs.list.empty",
                                                   comment: "Shown when there are no documents in the bundle docs folder"))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(files, id: \.self) { url in
                                HStack {
                                    Image(systemName: iconName(for: url))
                                    Text(url.lastPathComponent)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .tag(url as URL?)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedURL = url }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                }

                Divider()

                // RIGHT: preview
                Group {
                    if let url = selectedURL {
                        PreviewPane(url: url)
                    } else {
                        VStack {
                            Text(NSLocalizedString("docs.preview.placeholder",
                                                   comment: "Shown when no document is selected in the documents window"))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 420, idealWidth: 560, maxWidth: .infinity,
                       minHeight: 400, idealHeight: 520, maxHeight: .infinity)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
            )
            .padding(20)
            .task { loadFiles() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("generic.button.close",
                                             comment: "Generic Close button title")) {
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .automatic) {
                    if let url = selectedURL {
                        OpenInFinderButton(url: url)
                        ShareButton(url: url)
                        Button {
                            exportSelected(url)
                        } label: {
                            Label(
                                NSLocalizedString("docs.toolbar.save_copy",
                                                  comment: "Toolbar button to save a copy of the selected document to a user-chosen location"),
                                systemImage: "square.and.arrow.down"
                            )
                        }
                        Button(role: .destructive) {
                            deleteSelected(url)
                        } label: {
                            Label(NSLocalizedString("docs.toolbar.delete",
                                                    comment: "Toolbar button to delete the selected document"),
                                  systemImage: "trash")
                        }
                        .disabled(!canDelete(url))
                        Divider()
                    }
                    Button {
                        importFile()
                    } label: {
                        Label(NSLocalizedString("docs.toolbar.upload",
                                                comment: "Toolbar button to upload a document into the bundle docs folder"),
                              systemImage: "square.and.arrow.up")
                    }
                    .keyboardShortcut("i", modifiers: [.command])
                }
            }
            .navigationTitle(NSLocalizedString("docs.nav.title",
                                               comment: "Navigation title for the bundle documents window"))
            .alert(
                NSLocalizedString("generic.error.title",
                                  comment: "Generic error alert title"),
                isPresented: .constant(errorMessage != nil),
                actions: {
                    Button(NSLocalizedString("generic.button.ok",
                                             comment: "Generic OK button title")) {
                        errorMessage = nil
                    }
                },
                message: {
                    Text(errorMessage ?? "")
                }
            )
        }
        .frame(minWidth: 840, idealWidth: 960, maxWidth: .infinity,
               minHeight: 520, idealHeight: 640, maxHeight: .infinity)
    }

    // MARK: - File ops

    private func loadFiles() {
        guard let docs = docsFolder else {
            files = []
            return
        }
        let fm = FileManager.default
        do {
            let urls = try fm.contentsOfDirectory(
                at: docs,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey],
                options: [.skipsHiddenFiles]
            )
            files = urls.filter { url in
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return false }
                return allowedExtensions.contains(url.pathExtension.lowercased())
            }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            errorMessage = String(
                format: NSLocalizedString("docs.error.list-failed",
                                          comment: "Shown when listing documents in the bundle docs folder fails; %@ is the underlying error message"),
                error.localizedDescription
            )
            files = []
        }

        if let sel = selectedURL, !files.contains(sel) {
            selectedURL = nil
        }
    }
    private func exportSelected(_ url: URL) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = url.lastPathComponent

        // Best-effort content type hint
        if let t = UTType(filenameExtension: url.pathExtension.lowercased()) {
            panel.allowedContentTypes = [t]
        }

        if panel.runModal() == .OK, let dest = panel.url {
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: url, to: dest)
            } catch {
                errorMessage = String(
                    format: NSLocalizedString(
                        "docs.error.export-failed",
                        comment: "Shown when exporting/saving a copy of a document fails; %@ is the underlying error message"
                    ),
                    error.localizedDescription
                )
            }
        }
        #endif
    }

    private func importFile() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .pdf, .png, .jpeg, .plainText,
            UTType(filenameExtension: "docx")!
        ]
        if panel.runModal() == .OK, let picked = panel.url {
            savePickedFile(picked)
        }
        #endif
    }

    private func savePickedFile(_ picked: URL) {
        guard let docs = docsFolder else { return }
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: docs.path) {
                try fm.createDirectory(at: docs, withIntermediateDirectories: true)
            }
            var dest = docs.appendingPathComponent(picked.lastPathComponent)
            var count = 1
            while fm.fileExists(atPath: dest.path) {
                let base = dest.deletingPathExtension().lastPathComponent
                let ext = dest.pathExtension
                dest = docs.appendingPathComponent("\(base)-\(count).\(ext)")
                count += 1
            }
            try fm.copyItem(at: picked, to: dest)
            loadFiles()
            selectedURL = dest
        } catch {
            errorMessage = String(
                format: NSLocalizedString("docs.error.copy-failed",
                                          comment: "Shown when copying an imported document into the bundle docs folder fails; %@ is the underlying error message"),
                error.localizedDescription
            )
        }
    }

    private func canDelete(_ url: URL) -> Bool {
        guard let docs = docsFolder else { return false }
        return url.standardizedFileURL.path.hasPrefix(docs.standardizedFileURL.path)
    }

    private func deleteSelected(_ url: URL) {
        guard let docs = docsFolder else { return }
        let fm = FileManager.default
        // Only allow deletion if file resides under docs/
        guard url.standardizedFileURL.path.hasPrefix(docs.standardizedFileURL.path) else {
            errorMessage = NSLocalizedString("docs.error.delete-outside-docs",
                                             comment: "Shown when attempting to delete a file that is not inside the bundle docs folder")
            return
        }
        do {
            try fm.removeItem(at: url)
            loadFiles()
            selectedURL = nil
        } catch {
            errorMessage = String(
                format: NSLocalizedString("docs.error.delete-failed",
                                          comment: "Shown when deleting a document from the bundle docs folder fails; %@ is the underlying error message"),
                error.localizedDescription
            )
        }
    }

    private func iconName(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg": return "photo"
        case "txt": return "doc.plaintext"
        case "docx": return "doc"
        default: return "doc"
        }
    }
}

// MARK: - Preview Pane

fileprivate struct PreviewPane: View {
    let url: URL

    var body: some View {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg":
            ImagePreview(url: url)      // scaled to fit
        case "pdf":
            PDFPreview(url: url)        // PDFKit
        case "txt":
            TextPreview(url: url)       // plain text
        case "docx":
            VStack(spacing: 12) {
                Image(systemName: "doc")
                    .font(.system(size: 48))
                Text(NSLocalizedString("docs.preview.docx-unsupported",
                                       comment: "Shown when a DOCX document cannot be previewed in the app"))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    OpenInFinderButton(url: url)
                    ShareButton(url: url)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            VStack(spacing: 12) {
                Image(systemName: "questionmark.folder")
                    .font(.system(size: 48))
                Text(NSLocalizedString("docs.preview.unsupported-type",
                                       comment: "Shown when the document file type is not supported for preview"))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    OpenInFinderButton(url: url)
                    ShareButton(url: url)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// Images: scale to fit with scroll (prevents giant PNGs)
fileprivate struct ImagePreview: View {
    let url: URL
    @State private var image: NSImage? = nil

    var body: some View {
        GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: geo.size.width - 24,
                                   maxHeight: geo.size.height - 24)
                            .clipped()
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.2))
                            )
                            .padding(12)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if image == nil {
                image = NSImage(contentsOf: url)
            }
        }
    }
}

// PDF preview via PDFKit (auto-scales)
fileprivate struct PDFPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysAsBook = false
        v.backgroundColor = .clear
        return v
    }
    func updateNSView(_ nsView: PDFView, context: Context) {
        nsView.document = PDFDocument(url: url)
    }
}

// TXT preview
fileprivate struct TextPreview: View {
    let url: URL
    @State private var text: String = ""
    var body: some View {
        ScrollView {
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .task {
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                text = String(
                    format: NSLocalizedString("docs.error.text-load-failed",
                                              comment: "Shown when loading a plain text document fails; %@ is the underlying error message"),
                    error.localizedDescription
                )
            }
        }
    }
}

// MARK: - Buttons

fileprivate struct OpenInFinderButton: View {
    let url: URL
    var body: some View {
        #if os(macOS)
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Label(NSLocalizedString("docs.button.show-in-finder",
                                    comment: "Button to reveal the selected document in Finder"),
                  systemImage: "folder")
        }
        #else
        EmptyView()
        #endif
    }
}

fileprivate struct ShareButton: View {
    let url: URL
    var body: some View {
        #if os(macOS)
        Button {
            let picker = NSSharingServicePicker(items: [url])
            if let view = NSApp.keyWindow?.contentView {
                picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
            }
        } label: {
            Label(NSLocalizedString("docs.button.share",
                                    comment: "Button to share the selected document"),
                  systemImage: "square.and.arrow.up")
        }
        #else
        EmptyView()
        #endif
    }
}
