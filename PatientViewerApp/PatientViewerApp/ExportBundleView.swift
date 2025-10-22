//
//  ExportBundleView.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/14/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct ExportBundleView: View {
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
        await MainActor.run {
            exportInProgress = true
            exportSuccess = false
            exportedFileURL = nil
            exportError = nil
        }

        do {
            let exportURL = try await BundleExporter.exportBundle(from: dbURL)
            let size = (try? Data(contentsOf: exportURL).count) ?? 0
            print("[DEBUG] Export zip ready at: \(exportURL)")
            print("[DEBUG] Export finished at: \(exportURL.path) (\(size) bytes)")

            await MainActor.run {
                exportedFileURL = exportURL
                exportSuccess = true
            }

            guard !didKickoffShare else { return }
            didKickoffShare = true

            // 1) Dismiss this sheet first
            await MainActor.run { dismiss() }

            // 2) Route to the global share sheet via the router
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                onShare(exportURL)
            }
        } catch {
            await MainActor.run {
                exportError = error.localizedDescription
            }
        }

        await MainActor.run {
            exportInProgress = false
        }
    }
}
