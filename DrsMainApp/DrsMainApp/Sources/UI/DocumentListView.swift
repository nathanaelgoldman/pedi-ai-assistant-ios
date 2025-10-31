//
//  DocumentListView.swift
//  DrsMainApp
//
//  Created by yunastic on 10/31/25.
//
import SwiftUI
import PDFKit
import AppKit

struct DocumentListView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selection: URL?

    var body: some View {
        VStack(spacing: 0) {
            // Header actions
            HStack {
                Text("Documents").font(.title3.bold())
                Spacer()
                Button {
                    pickFiles()
                } label: { Label("Add", systemImage: "plus") }
                .help("Add files to docs/inbox")

                Button {
                    shareSelected()
                } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .disabled(selection == nil)

                Button(role: .destructive) {
                    if let sel = selection { appState.deleteDocument(sel) }
                } label: { Label("Delete", systemImage: "trash") }
                .disabled(!isDeletable(selection))
            }
            .padding(.horizontal).padding(.top, 10).padding(.bottom, 6)

            Divider()

            HStack(spacing: 0) {
                // Left list
                List(selection: $selection) {
                    ForEach(appState.documents, id: \.self) { url in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable().frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent)
                                if url.deletingLastPathComponent().lastPathComponent == "inbox" {
                                    Text("inbox/").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if isDeletable(url) {
                                Image(systemName: "trash").foregroundStyle(.secondary)
                            }
                        }
                        .tag(url as URL?)
                    }
                }
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 320)

                Divider()

                // Right preview
                Group {
                    if let sel = selection {
                        FilePreview(url: sel).id(sel)
                    } else {
                        VStack {
                            Image(systemName: "doc.on.doc").font(.system(size: 32))
                            Text("Select a document to preview").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { appState.reloadDocuments() }
    }

    private func isDeletable(_ url: URL?) -> Bool {
        guard let url, let docs = appState.currentDocsURL else { return false }
        let inbox = docs.appendingPathComponent("inbox", isDirectory: true).standardizedFileURL
        return url.standardizedFileURL.path.hasPrefix(inbox.path)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .png, .jpeg, .plainText]
        if panel.runModal() == .OK {
            appState.importDocuments(from: panel.urls)
        }
    }

    private func shareSelected() {
        guard let sel = selection else { return }
        let picker = NSSharingServicePicker(items: [sel])
        if let win = NSApplication.shared.keyWindow, let v = win.contentView {
            picker.show(relativeTo: .zero, of: v, preferredEdge: .minY)
        }
    }
}

// MARK: - Preview widgetry

private struct FilePreview: View {
    let url: URL
    var body: some View {
        switch url.pathExtension.lowercased() {
        case "pdf":
            PDFKitView(url: url).frame(maxWidth: .infinity, maxHeight: .infinity)
        case "png", "jpg", "jpeg":
            if let img = NSImage(contentsOf: url) {
                ScrollView([.vertical, .horizontal]) {
                    Image(nsImage: img)
                        .resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else { UnsupportedView(url: url) }
        case "txt":
            if let s = try? String(contentsOf: url) {
                ScrollView { Text(s).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            } else { UnsupportedView(url: url) }
        default:
            UnsupportedView(url: url)
        }
    }
}

private struct UnsupportedView: View {
    let url: URL
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 34))
            Text("Preview not available for “\(url.lastPathComponent)”.")
            Button("Open in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PDFKitView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.backgroundColor = .clear
        v.document = PDFDocument(url: url)
        return v
    }
    func updateNSView(_ nsView: PDFView, context: Context) {
        nsView.document = PDFDocument(url: url)
    }
}
