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


@inline(__always)
private func L(_ key: String, comment: String = "") -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: comment)
}

 #if os(macOS)
private func presentPemrShareChooser(fileURL: URL) {
    let pemrType = UTType("com.yunastic.pedia.pemr") ?? .zip

    // Use an item provider so services treat the file as an archive with the correct UTType.
    guard let provider = NSItemProvider(contentsOf: fileURL) else {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        return
    }
    provider.suggestedName = fileURL.lastPathComponent
    provider.registerFileRepresentation(
        forTypeIdentifier: pemrType.identifier,
        fileOptions: [],
        visibility: .all
    ) { completion in
        completion(fileURL, true, nil)
        return nil
    }

    let alert = NSAlert()
    alert.messageText = L("exporter.mac.sharechooser.title", comment: "Title for share chooser alert")
    alert.informativeText = fileURL.lastPathComponent

    // Buttons order matters: first is default.
    alert.addButton(withTitle: L("exporter.mac.sharechooser.airdrop", comment: "Share via AirDrop"))
    alert.addButton(withTitle: L("exporter.mac.sharechooser.mail", comment: "Share via Mail"))
    alert.addButton(withTitle: L("exporter.mac.sharechooser.messages", comment: "Share via Messages"))
    alert.addButton(withTitle: L("common.cancel", comment: "Cancel"))

    let resp = alert.runModal()

    let svc: NSSharingService?
    switch resp {
    case .alertFirstButtonReturn:
        svc = NSSharingService(named: .sendViaAirDrop)
    case .alertSecondButtonReturn:
        svc = NSSharingService(named: .composeEmail)
    case .alertThirdButtonReturn:
        svc = NSSharingService(named: .composeMessage)
    default:
        svc = nil
    }

    guard let svc else { return }
    svc.perform(withItems: [provider])
}
#endif

// MARK: - macOS front-end wrapper
@MainActor
struct MacBundleExporter {

    enum MacBundleExporterError: Error, LocalizedError {
        case noActiveBundle
        var errorDescription: String? {
            switch self {
            case .noActiveBundle:
                return L("exporter.mac.error.no_active_bundle", comment: "Shown when export is requested but no patient bundle is currently open")
            }
        }
    }

    /// Asks BundleExporter to pack the active bundle folder and lets the user save the `.pemr` file.
    static func run(appState: AppState) async throws -> URL {
        do {
            // 1) Source folder: the bundle currently open in DrsMainApp
            guard let src = appState.currentBundleURL else {
                throw MacBundleExporterError.noActiveBundle
            }

            // 2) Re-pack to a temporary container (ZIP internally; extension may vary)
            let tempBundleURL = try await BundleExporter.exportBundle(from: src)

            // 3) Ask the user where to save it
            let panel = NSSavePanel()
            panel.title = L("exporter.mac.savepanel.title", comment: "Title for the macOS save panel when exporting a peMR bundle")
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

                // Post-export action dialog
                let alert = NSAlert()
                alert.messageText = L("exporter.mac.success.title", comment: "Title for successful bundle export alert")
                alert.informativeText = dest.lastPathComponent

                alert.addButton(withTitle: L("exporter.mac.success.reveal", comment: "Reveal exported bundle in Finder"))
                alert.addButton(withTitle: L("exporter.mac.success.share", comment: "Share exported bundle"))
                alert.addButton(withTitle: L("common.ok", comment: "Generic OK button"))

                let response = alert.runModal()

                if response == .alertFirstButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                } else if response == .alertSecondButtonReturn {
                    presentPemrShareChooser(fileURL: dest)
                }

                return dest
            } else {
                throw CocoaError(.userCancelled)
            }
        } catch {
                throw error
            }
        }
    }

