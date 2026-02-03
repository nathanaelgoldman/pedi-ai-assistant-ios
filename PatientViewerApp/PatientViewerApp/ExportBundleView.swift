//
//  ExportBundleView.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/14/25.
//


import SwiftUI
import UniformTypeIdentifiers

// MARK: - Localization (file-local)
@inline(__always)
private func L(_ key: String, comment: String = "") -> String {
    NSLocalizedString(key, comment: comment)
}

@inline(__always)
private func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

struct ExportBundleView: View {
    private static let log = AppLog.feature("ExportUI")
    let dbURL: URL
    let onShare: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var didKickoffShare = false

    @State private var exportInProgress = false
    @State private var exportSuccess = false
    @State private var exportedFileURL: URL? = nil
    @State private var exportError: String? = nil

    var body: some View {
        VStack(spacing: 24) {
            Text(L("patient_viewer.export_bundle.title", comment: "Screen title"))
                .font(.title2)
                .bold()

            Text(L("patient_viewer.export_bundle.subtitle", comment: "Screen subtitle/description"))
                .font(.body)

            Button(action: {
                Task {
                    await exportBundle()
                }
            }) {
                HStack {
                    Image(systemName: "arrow.down.doc.fill")
                    Text(L("patient_viewer.export_bundle.action.export", comment: "Primary button"))
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .disabled(exportInProgress)

            if exportInProgress {
                ProgressView(L("patient_viewer.export_bundle.progress.exporting", comment: "Progress label"))
            }

            if let error = exportError {
                Text(LF("patient_viewer.export_bundle.error.format", error))
                    .foregroundColor(.red)
            }

            Spacer()
        }
        .padding()
    }

    private func exportBundle() async {
        let dbRef = AppLog.dbRef(self.dbURL)
        Self.log.info("Export started | db=\(dbRef, privacy: .public)")
        await MainActor.run {
            exportInProgress = true
            exportSuccess = false
            exportedFileURL = nil
            exportError = nil
        }

        do {
            let exportURL = try await BundleExporter.exportBundle(from: dbURL)
            let size = (try? Data(contentsOf: exportURL).count) ?? 0
            let humanSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            let fileTok = AppLog.token(exportURL.lastPathComponent)
            Self.log.debug("Export zip ready | fileTok=\(fileTok, privacy: .public)")
            Self.log.info("Export finished | fileTok=\(fileTok, privacy: .public) size=\(humanSize, privacy: .public)")

            await MainActor.run {
                exportedFileURL = exportURL
                exportSuccess = true
                Self.log.notice("Export succeeded")
            }

            if didKickoffShare {
                Self.log.debug("Share already kicked off, skipping.")
                return
            }
            didKickoffShare = true
            Self.log.debug("Dismissing export sheet and invoking onShare.")

            // 1) Dismiss this sheet first
            await MainActor.run { dismiss() }

            // 2) Route to the global share sheet via the router
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                onShare(exportURL)
            }
        } catch {
            Self.log.error("Export failed: \(error.localizedDescription, privacy: .private)")
            await MainActor.run {
                exportError = error.localizedDescription
            }
        }

        await MainActor.run {
            exportInProgress = false
        }
        Self.log.debug("Export flow ended.")
    }
}
