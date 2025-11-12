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
        panel.canChooseDirectories = false          // ZIP-only
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.title = "Choose Patient Bundles (.zip only)"
        panel.prompt = "Add ZIPs"
        panel.allowedContentTypes = [.zip]

        panel.begin { resp in
            guard resp == .OK else { completion([]); return }
            // Extra safety: filter to .zip by path extension just in case
            let zips = panel.urls.filter { $0.pathExtension.lowercased() == "zip" }
            completion(zips)
        }
#else
        completion([])
#endif
    }

    /// Returns the app's Application Support staging directory for imports: ~/Library/Application Support/DrsMainApp/Imports
#if os(macOS)
    private static func stagingDirectory() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let bundleID = Bundle.main.bundleIdentifier ?? "DrsMainApp"
        let dir = appSupport.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent("Imports", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        return dir
    }

    /// Copy the given ZIPs into the staging directory. Returns the destination URLs.
    /// If a file with the same name exists, a timestamp suffix is appended to keep both.
    static func copyZipsToStaging(_ urls: [URL]) throws -> [URL] {
        let fm = FileManager.default
        let staging = try stagingDirectory()
        var results: [URL] = []
        for src in urls where src.pathExtension.lowercased() == "zip" {
            let baseName = src.deletingPathExtension().lastPathComponent
            var dest = staging.appendingPathComponent(src.lastPathComponent, isDirectory: false)
            if fm.fileExists(atPath: dest.path) {
                let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                dest = staging.appendingPathComponent("\(baseName)_\(ts).zip", isDirectory: false)
            }
            // Use replaceItem to support cross-volume moves; fallback to copy
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            do {
                _ = try fm.replaceItemAt(dest, withItemAt: src)
            } catch {
                try fm.copyItem(at: src, to: dest)
            }
            results.append(dest)
        }
        return results
    }

    /// Convenience: open panel for ZIPs, copy them into staging, and return the new locations.
    static func selectZipBundlesToStaging(completion: @escaping ([URL]) -> Void) {
        selectBundles { urls in
            do {
                let staged = try copyZipsToStaging(urls)
                completion(staged)
            } catch {
                NSLog("FilePicker.copyZipsToStaging error: \(error.localizedDescription)")
                completion([])
            }
        }
    }
#endif

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
