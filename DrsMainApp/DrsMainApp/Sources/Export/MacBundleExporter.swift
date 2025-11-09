//
//  MacBundleExporter.swift
//  DrsMainApp
//
//  Minimal macOS exporter used by MacBundleExporter.run(appState:)
//  Zips the currently open bundle folder into a temporary .peMR.zip
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

    /// Asks BundleExporter to pack the active bundle folder and lets the user save the .peMR.zip
    static func run(appState: AppState) async {
        do {
            // 1) Source folder: the bundle currently open in DrsMainApp
            guard let src = appState.currentBundleURL else {
                throw MacBundleExporterError.noActiveBundle
            }

            // 2) Re-pack (temp zip)
            let tempZipURL = try await BundleExporter.exportBundle(from: src)

            // 3) Ask the user where to save it
            let panel = NSSavePanel()
            panel.title = "Export peMR Bundle"
            panel.allowedContentTypes = [UTType.zip]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = tempZipURL.lastPathComponent

            if panel.runModal() == .OK, let dest = panel.url {
                let fm = FileManager.default
                if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                try fm.copyItem(at: tempZipURL, to: dest)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
