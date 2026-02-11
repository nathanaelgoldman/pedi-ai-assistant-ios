//
//  SupportLogExporter.swift
//  DrsMainApp
//
//  Created by Nathanael on 2/11/26.
//
import Foundation
import OSLog

enum SupportLogExporter {

    /// Export recent unified logs *for this process* to a text file.
    /// - Parameters:
    ///   - sinceSeconds: How far back to pull (e.g. last 1800 seconds = 30 min)
    ///   - maxEntries: Safety cap
    /// - Returns: URL of the written .txt file
    static func exportCurrentProcessLogs(
        sinceSeconds: TimeInterval = 1800,
        maxEntries: Int = 4000,
        context: [String: String] = [:]
    ) throws -> URL {

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let since = store.position(date: Date().addingTimeInterval(-sinceSeconds))

        // Pull everything from this process since `since`.
        let entries = try store.getEntries(at: since, matching: nil)

        var lines: [String] = []
        lines.reserveCapacity(min(maxEntries, 1024))

        let appSubsystem = Bundle.main.bundleIdentifier ?? ""

        func levelLabel(_ level: OSLogEntryLog.Level) -> String {
            switch level {
            case .debug:  return "DEBUG"
            case .info:   return "INFO"
            case .notice: return "NOTICE"
            case .error:  return "ERROR"
            case .fault:  return "FAULT"
            default:      return "LOG"
            }
        }

        var count = 0
        for case let e as OSLogEntryLog in entries {
            // Filter to app-only logs (keeps the file much cleaner for support).
            // Note: This still includes logs emitted by your app code via AppLog.
            if !appSubsystem.isEmpty, e.subsystem != appSubsystem {
                continue
            }

            let ts = ISO8601DateFormatter().string(from: e.date)
            let lvl = levelLabel(e.level)
            let msg = e.composedMessage

            lines.append("\(ts) | \(lvl) | \(e.category) | \(msg)")

            count += 1
            if count >= maxEntries { break }
        }

        // Include a little header block with environment + hashed context info
        let header = buildSupportLogHeader(context: context)
        let outText = header + "\n\n" + lines.joined(separator: "\n") + "\n"

        let filename = "\(appSlug())-SupportLog-v\(appVersionString())-\(timestamp()).txt"
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        try outText.write(to: outURL, atomically: true, encoding: .utf8)
        return outURL
    }
    
    private static func buildSupportLogHeader(context: [String: String]) -> String {
        var parts: [String] = []
        parts.append("DrsMainApp Support Log")
        parts.append("Created: \(ISO8601DateFormatter().string(from: Date()))")

        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            parts.append("Version: \(v)")
        }
        if let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            parts.append("Build: \(b)")
        }

        if !context.isEmpty {
            let sorted = context.keys.sorted()
            let ctxLine = sorted.map { "\($0)=\(context[$0] ?? "")" }.joined(separator: " ")
            parts.append("Context: \(ctxLine)")
        }

        return parts.joined(separator: "\n")
    }


    private static func appVersionString() -> String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        // Example: 1.2.0(45)
        return "\(version)(\(build))"
    }

    private static func appSlug() -> String {
        let info = Bundle.main.infoDictionary
        let raw = (info?["CFBundleName"] as? String)
            ?? (Bundle.main.bundleIdentifier ?? "App")

        // Keep only ASCII alphanumerics + dash/underscore; replace others with '-'
        let decomposed = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let mapped = decomposed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        var slug = String(mapped)
        slug = slug.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        return slug.isEmpty ? "App" : slug
    }

    private static func timestamp() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return df.string(from: Date())
    }
}
