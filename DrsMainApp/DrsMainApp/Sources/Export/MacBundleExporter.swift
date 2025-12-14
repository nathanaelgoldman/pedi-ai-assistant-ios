//
//  MacBundleExporter.swift
//  DrsMainApp
//
//  Minimal macOS exporter used by MacBundleExporter.run(appState:)
//  Packs the currently open bundle folder into a temporary ZIP container
//  and lets the user save it as a `.pemr` file.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - macOS front-end wrapper
@MainActor
struct MacBundleExporter {

    enum MacBundleExporterError: Error, LocalizedError {
        case noActiveBundle
        var errorDescription: String? {
            switch self {
            case .noActiveBundle:
                return "No active patient bundle is open to export."
            }
        }
    }

    /// Asks BundleExporter to pack the active bundle folder and lets the user save the `.pemr` file.
    static func run(appState: AppState) async {
        do {
            // 1) Source folder: the bundle currently open in DrsMainApp
            guard let src = appState.currentBundleURL else {
                throw MacBundleExporterError.noActiveBundle
            }

            // 2) Re-pack to a temporary container (ZIP internally; extension may vary)
            let tempBundleURL = try await BundleExporter.exportBundle(from: src)

            // 3) Ask the user where to save it
            let panel = NSSavePanel()
            panel.title = "Export peMR Bundle"
            panel.canCreateDirectories = true

            // Suggest a clean `.pemr` name regardless of the temp file's extension
            let baseName = tempBundleURL.deletingPathExtension().lastPathComponent
            panel.nameFieldStringValue = baseName.hasSuffix(".pemr")
                ? baseName
                : baseName + ".pemr"

            // We *don't* restrict to UTType.zip here, because the user-facing
            // artifact is a `.pemr` file, even though the inner format is ZIP.
            // (UTType registration for `.pemr` can be added later.)

            if panel.runModal() == .OK, let chosenURL = panel.url {
                let fm = FileManager.default

                // Normalise the final saved file to have a `.pemr` extension,
                // regardless of what the user typed into the panel.
                var dest = chosenURL
                let ext = dest.pathExtension.lowercased()
                if ext != "pemr" {
                    dest.deletePathExtension()
                    dest.appendPathExtension("pemr")
                }

                if fm.fileExists(atPath: dest.path) {
                    try? fm.removeItem(at: dest)
                }
                try fm.copyItem(at: tempBundleURL, to: dest)

                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
