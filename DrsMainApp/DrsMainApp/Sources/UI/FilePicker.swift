//
//  FilePicker.swift
//  DrsMainApp
//
//  Created by yunastic on 10/27/25.
//
//  FilePicker.swift
//  DrsMainApp
//
//  Lightweight wrappers around NSOpenPanel and common file ops.
//
//
//  FilePicker.swift
//  DrsMainApp
//

// DrsMainApp/Sources/Util/FilePicker.swift
import Foundation
import SwiftUI

#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

enum FilePicker {
    static func selectBundles(completion: @escaping ([URL]) -> Void) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.title = "Choose Patient Bundles (folder or .zip)"
        panel.prompt = "Add Bundles"
        // Modern API (avoid deprecated allowedFileTypes):
        panel.allowedContentTypes = [.zip]

        panel.begin { resp in
            guard resp == .OK else { completion([]); return }
            completion(panel.urls)
        }
        #else
        completion([])
        #endif
    }

    static func revealInFinder(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    static func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
