//
//  SupportLog.swift
//  PatientViewerApp
//
//  Created by Nathanael on 2/5/26.
//
//
//  SupportLog.swift
//  PatientViewerApp
//
//  Offline, user-shareable support log (NOT OSLog export).
//  - OFF by default
//  - Redaction-friendly: you should only log tokens / AppLog.*Ref outputs (no raw identifiers)
//  - Stores a small in-memory ring buffer + optional cache file for sharing
//

import Foundation
import SwiftUI

@MainActor
final class SupportLog: ObservableObject {
    static let shared = SupportLog()

    // MARK: - Config

    /// OFF by default (your requirement).
    @Published private(set) var isEnabled: Bool = false

    /// Keep it small and safe.
    private let maxLines: Int = 400

    /// UserDefaults key
    private let enabledKey = "support_log.enabled"

    /// In-memory ring buffer
    @Published private(set) var lines: [String] = []

    private let ioQueue = DispatchQueue(label: "SupportLog.io.queue", qos: .utility)

    private init() {
        let saved = UserDefaults.standard.bool(forKey: enabledKey)
        self.isEnabled = saved
        if saved {
            // If enabled, attempt to reload previous cached file for continuity.
            self.reloadFromDiskBestEffort()
        } else {
            // If disabled, ensure nothing persists.
            self.clear()
        }
    }

    // MARK: - Public API

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: enabledKey)

        if enabled {
            // Start fresh when enabled (less confusing, less risk).
            clear()
            add("SupportLog enabled.")
        } else {
            add("SupportLog disabled.")
            clear()
        }
    }

    /// Add a single log line. Keep content non-identifying.
    func add(_ message: String,
             level: Level = .info,
             file: String = #fileID,
             function: String = #function,
             line: Int = #line)
    {
        guard isEnabled else { return }

        let ts = Self.timestamp()
        let fileShort = (file as NSString).lastPathComponent
        let prefix = "\(ts) [\(level.rawValue)] \(fileShort):\(line) \(function) — "

        // IMPORTANT: assume caller already used AppLog.token / AppLog.*Ref.
        // As a safety net, we still strip obvious full paths.
        let safeMessage = Self.scrubLikelyPaths(message)

        let composed = prefix + safeMessage

        // In-memory ring buffer
        lines.append(composed)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }

        // Persist to cache (so Share works even if view disappears)
        writeToDiskBestEffort()
    }

    func clear() {
        lines.removeAll(keepingCapacity: false)
        deleteDiskFileBestEffort()
    }

    /// Creates/returns a URL to a shareable text file in Caches.
    /// Always returns a file URL (even if empty).
    func exportURL() async throws -> URL {
        // Snapshot quickly on the MainActor to avoid concurrent mutation while exporting.
        let enabled = self.isEnabled
        let snapshot = self.lines

        let header = """
        CareView Kids — Support Log
        Generated: \(Self.timestampHuman())
        Enabled: \(enabled ? "YES" : "NO")
        Lines: \(snapshot.count)

        """

        let body = (snapshot.joined(separator: "\n")) + "\n"
        let out = header + body

        // Write on the IO queue so we don't block the UI / share sheet presentation.
        return try await withCheckedThrowingContinuation { cont in
            ioQueue.async {
                do {
                    let url = Self.exportFileURL()
                    // Ensure caches exists (should, but keep it defensive)
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    guard let data = out.data(using: .utf8) else {
                        throw NSError(domain: "SupportLog", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "Unable to encode support log as UTF-8."
                        ])
                    }
                    try data.write(to: url, options: [.atomic])
                    cont.resume(returning: url)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Level

    enum Level: String {
        case debug = "DEBUG"
        case info  = "INFO"
        case warn  = "WARN"
        case error = "ERROR"
    }

    // MARK: - Disk IO (Caches)

    nonisolated private static func logFileURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("careviewkids-support-log.txt")
    }

    nonisolated private static func exportFileURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return caches.appendingPathComponent("careviewkids-support-log-\(stamp).txt")
    }

    private func writeToDiskBestEffort() {
        let snapshot = self.lines // capture on MainActor
        ioQueue.async {
            let url = Self.logFileURL()
            let text = snapshot.joined(separator: "\n") + "\n"
            do {
                try text.data(using: .utf8)?.write(to: url, options: [.atomic])
            } catch {
                // Intentionally ignore; support log must never crash the app.
            }
        }
    }

    private func reloadFromDiskBestEffort() {
        ioQueue.async {
            let url = Self.logFileURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                let data = try Data(contentsOf: url)
                let text = String(decoding: data, as: UTF8.self)
                let loaded = text
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map(String.init)

                DispatchQueue.main.async {
                    self.lines = Array(loaded.suffix(self.maxLines))
                }
            } catch {
                // ignore
            }
        }
    }

    private func deleteDiskFileBestEffort() {
        ioQueue.async {
            let url = Self.logFileURL()
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    private static func timestamp() -> String {
        // ISO-ish, stable, logs-friendly
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private static func timestampHuman() -> String {
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateStyle = .medium
        df.timeStyle = .medium
        return df.string(from: Date())
    }

    /// Safety net: remove strings that look like absolute paths.
    /// (You should still avoid logging raw paths in the first place.)
    private static func scrubLikelyPaths(_ s: String) -> String {
        // Very lightweight heuristic: replace any "/.../.../" run with "[path]".
        // Avoid heavy regex.
        var out = s
        if out.contains("/") {
            // Replace common iOS container markers
            out = out.replacingOccurrences(of: "/var/mobile/", with: "[path]/")
            out = out.replacingOccurrences(of: "/private/var/", with: "[path]/")
            out = out.replacingOccurrences(of: "/Users/", with: "[path]/")
        }
        return out
    }
}

// SupportLog.swift
extension SupportLog {
    func info(_ message: String)  { add(message, level: .info) }
    func warn(_ message: String)  { add(message, level: .warn) }
    func error(_ message: String) { add(message, level: .error) }
}
