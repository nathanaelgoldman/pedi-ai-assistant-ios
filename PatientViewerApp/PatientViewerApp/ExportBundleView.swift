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
    @State private var exportInProgress = false
    @State private var exportSuccess = false
    @State private var exportedFileURL: URL? = nil
    @State private var exportError: String? = nil

    // Share sheet routing (lets user Save to Files or share to another app)
    @State private var shareItem: ExportShareItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("patient_viewer.export_bundle.title", comment: "Screen title"))
                        .font(.title2.weight(.semibold))

                    Text(L("patient_viewer.export_bundle.subtitle", comment: "Screen subtitle/description"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Primary action
                Button {
                    Task { await exportBundle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 18, weight: .semibold))
                        Text(L("patient_viewer.export_bundle.action.export", comment: "Primary button"))
                            .font(.headline)
                        Spacer()
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                            .fill(AppTheme.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                            .stroke(AppTheme.cardStroke, lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
                .disabled(exportInProgress)
                .opacity(exportInProgress ? 0.65 : 1.0)

                // Status
                if exportInProgress {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(L("patient_viewer.export_bundle.progress.exporting", comment: "Progress label"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                            .fill(AppTheme.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                            .stroke(AppTheme.cardStroke, lineWidth: 0.8)
                    )
                }

                if let error = exportError {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("common.error", comment: "Common error"))
                            .font(.headline)
                        Text(LF("patient_viewer.export_bundle.error.format", error))
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                            .fill(AppTheme.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                            .stroke(AppTheme.cardStroke, lineWidth: 0.8)
                    )
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
        .appBackground()
        .navigationTitle(L("patient_viewer.export_bundle.nav_title", comment: "Navigation title"))
        .navigationBarTitleDisplayMode(.inline)
        .appNavBarBackground()
        .sheet(item: $shareItem, onDismiss: {
            // Reset so the next export reliably re-opens the sheet
            shareItem = nil
        }) { item in
            ShareSheet(items: [item.url])
        }
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

            // Present the system share sheet so the user can Save to Files or share to another app.
            // (This replaces the older onShare -> fileExporter flow.)
            await MainActor.run {
                self.exportedFileURL = exportURL
                self.shareItem = ExportShareItem(url: exportURL)
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

// MARK: - Share sheet helper


// MARK: - Share sheet helper

private struct ExportShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPad safety: present as popover anchored to the controller view.
        if let pop = vc.popoverPresentationController {
            pop.sourceView = vc.view
            pop.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // no-op
    }
}
