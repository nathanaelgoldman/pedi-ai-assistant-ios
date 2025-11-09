//
//  BundleExported.swift
//  DrsMainApp
//
//  Created by yunastic on 11/9/25.
//

//
//  BundleExporter.swift
//  DrsMainApp
//
//  Pure-Foundation exporter used by MacBundleExporter.run(appState:)
//  Zips a peMR bundle folder into a temporary .peMR.zip
//

import Foundation
import CryptoKit

// MARK: - Errors

enum BundleZipError: Error, LocalizedError {
    case sourceNotDirectory(URL)
    case zipFailed(code: Int, output: String)

    var errorDescription: String? {
        switch self {
        case .sourceNotDirectory(let url):
            return "Source is not a directory: \(url.path)"
        case .zipFailed(let code, let output):
            return "Failed to create zip (code \(code)). Output:\n\(output)"
        }
    }
}

// MARK: - Exporter

struct BundleExporter {

    /// Create a `.peMR.zip` from the given bundle folder.
    /// Returns the temporary file URL of the created archive.
    static func exportBundle(from src: URL) async throws -> URL {
        // Run on a background thread to avoid blocking the main actor.
        return try await Task.detached(priority: .userInitiated) {
            try makeZip(from: src)
        }.value
    }

    // MARK: - Internal

    private static func makeZip(from src: URL) throws -> URL {
        let fm = FileManager.default

        // 1) Validate source
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else {
            throw BundleZipError.sourceNotDirectory(src)
        }

        // 2) Create a staging dir
        let stageRoot = fm.temporaryDirectory.appendingPathComponent("peMR-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stageRoot, withIntermediateDirectories: true)

        // 3) Copy filtered contents: db.sqlite + docs/**
        //    (skip db.sqlite-wal, db.sqlite-shm, .DS_Store, __MACOSX)
        let dbSrc  = src.appendingPathComponent("db.sqlite", isDirectory: false)
        let docsSrc = src.appendingPathComponent("docs", isDirectory: true)
        if fm.fileExists(atPath: dbSrc.path) {
            try fm.copyItem(at: dbSrc, to: stageRoot.appendingPathComponent("db.sqlite"))
        }
        if fm.fileExists(atPath: docsSrc.path) {
            try copyTreeFiltered(from: docsSrc, to: stageRoot.appendingPathComponent("docs"))
        }

        // 4) Build manifest.json with SHA-256 per file
        try writeManifest(at: stageRoot)

        // 5) Zip the staged root (flat)
        let stamp = timestamp()
        let name  = "\(src.lastPathComponent)-\(stamp).peMR.zip"
        let out   = fm.temporaryDirectory.appendingPathComponent(name, isDirectory: false)

        if fm.fileExists(atPath: out.path) { try? fm.removeItem(at: out) }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.currentDirectoryURL = stageRoot
        task.arguments = ["-r", "-y", out.path, ".", "-x", "__MACOSX/*", ".DS_Store", "*/.DS_Store", "*/._*"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = pipe
        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard task.terminationStatus == 0 else {
            // Cleanup staging before throwing
            try? fm.removeItem(at: stageRoot)
            throw BundleZipError.zipFailed(code: Int(task.terminationStatus), output: output)
        }

        // 6) Cleanup staging
        try? fm.removeItem(at: stageRoot)

        return out
    }

    /// Copy a directory tree while filtering out transient/macOS junk.
    private static func copyTreeFiltered(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        let contents = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        for item in contents {
            let name = item.lastPathComponent
            // skip junk
            if name == ".DS_Store" || name == "__MACOSX" || name.hasPrefix("._") { continue }
            // skip sqlite temps just in case
            if name.hasSuffix("-wal") || name.hasSuffix("-shm") { continue }

            let dstItem = dst.appendingPathComponent(name, isDirectory: false)
            let vals = try item.resourceValues(forKeys: [.isDirectoryKey])
            if vals.isDirectory == true {
                try copyTreeFiltered(from: item, to: dstItem)
            } else {
                try fm.copyItem(at: item, to: dstItem)
            }
        }
    }

    /// Write manifest.json with sha256, size, mtime for each file in the staged root.
    private static func writeManifest(at stageRoot: URL) throws {
        let fm = FileManager.default
        var files: [[String: Any]] = []

        // Walk stage root (db.sqlite and docs/**)
        let enumerator = fm.enumerator(at: stageRoot, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])!
        for case let url as URL in enumerator {
            if url == stageRoot { continue }
            let name = url.lastPathComponent
            if name == ".DS_Store" || name == "manifest.json" || name.hasPrefix("._") { continue }

            let vals = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            if vals.isDirectory == true { continue }

            let relPath = url.path.replacingOccurrences(of: stageRoot.path + "/", with: "")
            let data = try Data(contentsOf: url)
            let sha = sha256Hex(data)
            files.append([
                "path": relPath,
                "size": vals.fileSize ?? data.count,
                "modified": ISO8601DateFormatter().string(from: vals.contentModificationDate ?? Date()),
                "sha256": sha
            ])
        }

        let manifest: [String: Any] = [
            "version": 1,
            "created": ISO8601DateFormatter().string(from: Date()),
            "files": files
        ]
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
        try json.write(to: stageRoot.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func timestamp() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return df.string(from: Date())
    }
}
