//
//  ExportBundleView.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/14/25.
//

import SwiftUI
import UniformTypeIdentifiers
import OSLog

struct ExportBundleView: View {
    private static let log = Logger(subsystem: "Yunastic.PatientViewerApp", category: "ExportUI")
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
            Text("📤 Export Patient Bundle")
                .font(.title2)
                .bold()

            Text("Export your current records and documents as a portable `.peMR.zip` file. This file can be shared, saved, or transferred to another device.")
                .font(.body)

            Button(action: {
                Task {
                    await exportBundle()
                }
            }) {
                HStack {
                    Image(systemName: "arrow.down.doc.fill")
                    Text("Export Bundle")
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .disabled(exportInProgress)

            if exportInProgress {
                ProgressView("Exporting...")
            }

            if let error = exportError {
                Text("❌ \(error)")
                    .foregroundColor(.red)
            }

            Spacer()
        }
        .padding()
    }

    private func exportBundle() async {
        Self.log.info("Export started from dbURL: \(self.dbURL.path, privacy: .public)")
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
            Self.log.debug("Export zip ready at: \(exportURL.absoluteString, privacy: .public)")
            Self.log.info("Export finished at: \(exportURL.path, privacy: .public) (\(humanSize, privacy: .public))")

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
            Self.log.error("Export failed: \(error.localizedDescription, privacy: .public)")
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
