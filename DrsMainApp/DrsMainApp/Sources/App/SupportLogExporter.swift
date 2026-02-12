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
    ///   - context: hashed, non-identifying context fields to include in the header
    /// - Returns: URL of the written .txt file
    static func exportCurrentProcessLogs(
        sinceSeconds: TimeInterval = 1800,
        maxEntries: Int = 4000,
        context: [String: String] = [:]
    ) throws -> URL {

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let since = store.position(date: Date().addingTimeInterval(-sinceSeconds))

        // Pull everything from this process since `since`.
        // IMPORTANT: `OSLogStore.getEntries(...)` returns a single-pass sequence.
        // We do two scans (baseline + optional escalation), so we must materialize it.
        let entriesSequence = try store.getEntries(at: since, matching: nil)
        let entries = Array(entriesSequence)

        let appSubsystem = Bundle.main.bundleIdentifier ?? ""
        let iso = ISO8601DateFormatter()

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

        // MARK: - Two-pass export with escalation mode
        // Pass 1: baseline policy (Debug build = debug+, Release/TestFlight = info+)
        // Pass 2 (optional): if we detect actionable problems, run again with a more verbose policy.
        // IMPORTANT: We ALWAYS keep the baseline log. Escalation appends extra context; it never replaces baseline.

        struct ScanResult {
            var lines: [String]
            var scanned: Int
            var written: Int

            var debugCount: Int
            var infoCount: Int
            var noticeCount: Int
            var errorCount: Int
            var faultCount: Int

            var droppedOtherSubsystem: Int
            var droppedByLevelPolicy: Int
            var droppedNonLogEntry: Int
            var truncatedByMaxEntries: Bool
        }

        func shouldIncludeBaseline(_ rawLevel: Int) -> Bool {
            AppLog.includeInSupportLog(osLogLevelRaw: rawLevel)
        }

        // Escalated policy: include *all* app logs (debug+) even in Release/TestFlight.
        // We still keep the subsystem filter to avoid unrelated OS noise.
        func shouldIncludeEscalated(_ rawLevel: Int) -> Bool {
            return rawLevel >= OSLogEntryLog.Level.debug.rawValue
        }

        func runScan(includeLevel: (Int) -> Bool) -> ScanResult {
            var out: [String] = []
            out.reserveCapacity(min(maxEntries, 1024))

            var scanned = 0
            var written = 0

            var debugCount = 0
            var infoCount = 0
            var noticeCount = 0
            var errorCount = 0
            var faultCount = 0

            var droppedOtherSubsystem = 0
            var droppedByLevelPolicy = 0
            var droppedNonLogEntry = 0
            var truncatedByMaxEntries = false

            for entry in entries {
                scanned += 1

                guard let e = entry as? OSLogEntryLog else {
                    droppedNonLogEntry += 1
                    continue
                }

                // Filter to app-only logs (keeps the file much cleaner for support).
                if !appSubsystem.isEmpty, e.subsystem != appSubsystem {
                    droppedOtherSubsystem += 1
                    continue
                }

                // Filter by the supplied level policy.
                if !includeLevel(e.level.rawValue) {
                    droppedByLevelPolicy += 1
                    continue
                }

                let ts = iso.string(from: e.date)
                let lvl = levelLabel(e.level)

                switch e.level {
                case .debug:  debugCount += 1
                case .info:   infoCount += 1
                case .notice: noticeCount += 1
                case .error:  errorCount += 1
                case .fault:  faultCount += 1
                default:      break
                }

                let msg = e.composedMessage
                out.append("\(ts) | \(lvl) | \(e.category) | \(msg)")

                written += 1
                if written >= maxEntries {
                    truncatedByMaxEntries = true
                    break
                }
            }

            return ScanResult(
                lines: out,
                scanned: scanned,
                written: written,
                debugCount: debugCount,
                infoCount: infoCount,
                noticeCount: noticeCount,
                errorCount: errorCount,
                faultCount: faultCount,
                droppedOtherSubsystem: droppedOtherSubsystem,
                droppedByLevelPolicy: droppedByLevelPolicy,
                droppedNonLogEntry: droppedNonLogEntry,
                truncatedByMaxEntries: truncatedByMaxEntries
            )
        }

        // Pass 1 (baseline)
        let baseline = runScan(includeLevel: shouldIncludeBaseline)

        // Decide whether to escalate.
        let userErrorHint = (context["user_error"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasUserError = !userErrorHint.isEmpty && userErrorHint.lowercased() != "none"
        let hasErrorLogs = (baseline.errorCount + baseline.faultCount) > 0

        // If the baseline policy already includes debug+ (typical in Debug builds),
        // escalation is usually redundant unless the baseline was truncated.
        let baselineAlreadyIncludesDebug = shouldIncludeBaseline(OSLogEntryLog.Level.debug.rawValue)

        // Escalation can add value in two situations:
        // 1) Baseline didn't include debug+ (Release/TestFlight), or baseline was truncated.
        // 2) Even if baseline includes debug+, we may still want nearby NON-app ERROR/FAULT logs (framework/SQLite/etc.).
        let canGainSignalFromEscalation = baseline.truncatedByMaxEntries || !baselineAlreadyIncludesDebug || hasErrorLogs

        let baselinePolicyLabel = baselineAlreadyIncludesDebug ? "debug+" : "info+"

        // Escalation window: include only nearby context (around an anchor event) and avoid duplicating baseline lines.
        let escalationPreSeconds: TimeInterval = 30
        let escalationPostSeconds: TimeInterval = 120
        let escalationMaxEntries: Int = min(600, maxEntries)

        var escalated = false
        var escalationReason: String? = nil

        if canGainSignalFromEscalation {
            if hasErrorLogs {
                escalated = true
                escalationReason = "error_or_fault_logs_present"
            } else if hasUserError {
                escalated = true
                escalationReason = "user_error_hint_\(userErrorHint)"
            }
        } else {
            // Baseline already captured debug+ and was not truncated, so escalation would be a duplicate.
            escalated = false
            escalationReason = nil
        }

        // Helper to find escalation anchor date
        func findEscalationAnchorDate() -> Date? {
            // Prefer the first ERROR/FAULT app log in the captured time range.
            if escalated {
                for entry in entries {
                    guard let e = entry as? OSLogEntryLog else { continue }
                    if !appSubsystem.isEmpty, e.subsystem != appSubsystem { continue }
                    if e.level == .error || e.level == .fault {
                        return e.date
                    }
                }
            }

            // Fallback: if escalation is triggered only by user_error hint, try to anchor on the UI alert emission.
            if hasUserError {
                for entry in entries {
                    guard let e = entry as? OSLogEntryLog else { continue }
                    if !appSubsystem.isEmpty, e.subsystem != appSubsystem { continue }
                    if e.composedMessage.contains("Presenting error alert") { return e.date }
                    if e.category == "ui.alert" { return e.date }
                }
            }

            return nil
        }

        // Escalation scan: capture ONLY a time window around the anchor.
        // Goal: add *new* signal without duplicating baseline.
        // - Always: app subsystem debug+ (deduped against baseline)
        // - Additionally: non-app ERROR/FAULT logs in the same window (to catch framework/SQLite/system errors)
        func runEscalationWindowScan(anchorDate: Date) -> ScanResult {
            let start = anchorDate.addingTimeInterval(-escalationPreSeconds)
            let end = anchorDate.addingTimeInterval(escalationPostSeconds)

            var out: [String] = []
            out.reserveCapacity(min(escalationMaxEntries, 256))

            var scanned = 0
            var written = 0

            var debugCount = 0
            var infoCount = 0
            var noticeCount = 0
            var errorCount = 0
            var faultCount = 0

            var droppedOtherSubsystem = 0
            var droppedByLevelPolicy = 0
            var droppedNonLogEntry = 0
            var truncatedByMaxEntries = false

            // Build a fast lookup to avoid duplicating baseline lines in the escalation block.
            let baselineSet = Set(baseline.lines)

            for entry in entries {
                guard let e = entry as? OSLogEntryLog else {
                    // Not counted as scanned; keep bookkeeping simple for the window.
                    droppedNonLogEntry += 1
                    continue
                }

                // Only entries inside the time window.
                if e.date < start || e.date > end {
                    continue
                }

                let isAppSubsystem = appSubsystem.isEmpty ? true : (e.subsystem == appSubsystem)

                // Escalation policy:
                // - For app logs: include debug+
                // - For non-app logs: include only ERROR/FAULT (keeps noise low but captures useful framework/system errors)
                let includeThis: Bool
                if isAppSubsystem {
                    includeThis = shouldIncludeEscalated(e.level.rawValue)
                } else {
                    includeThis = (e.level == .error || e.level == .fault)
                    if !includeThis { droppedOtherSubsystem += 1 }
                }

                if !includeThis {
                    if isAppSubsystem { droppedByLevelPolicy += 1 }
                    continue
                }

                // "scanned" reflects the number of eligible entries in the window under the escalation policy.
                scanned += 1

                let ts = iso.string(from: e.date)
                let lvl = levelLabel(e.level)
                let msg = e.composedMessage
                let line = "\(ts) | \(lvl) | \(e.category) | \(msg)"

                // Avoid duplicating baseline lines.
                if baselineSet.contains(line) {
                    continue
                }

                switch e.level {
                case .debug:  debugCount += 1
                case .info:   infoCount += 1
                case .notice: noticeCount += 1
                case .error:  errorCount += 1
                case .fault:  faultCount += 1
                default:      break
                }

                out.append(line)
                written += 1

                if written >= escalationMaxEntries {
                    truncatedByMaxEntries = true
                    break
                }
            }

            return ScanResult(
                lines: out,
                scanned: scanned,
                written: written,
                debugCount: debugCount,
                infoCount: infoCount,
                noticeCount: noticeCount,
                errorCount: errorCount,
                faultCount: faultCount,
                droppedOtherSubsystem: droppedOtherSubsystem,
                droppedByLevelPolicy: droppedByLevelPolicy,
                droppedNonLogEntry: droppedNonLogEntry,
                truncatedByMaxEntries: truncatedByMaxEntries
            )
        }

        // MARK: - Escalation noise annotation
        // Returns a short hint for well-known benign system log lines.
        func escalationNoiseHint(for line: String) -> String? {
            // Keep matching simple and stable: substring checks on the rendered line.
            let s = line

            if s.contains("Unable to obtain a task name port right") {
                return "macOS entitlement/inspection noise (often harmless)"
            }

            if s.contains("ViewBridge to RemoteViewService Terminated") || s.contains("NSViewBridgeErrorCanceled") {
                return "SwiftUI/remote view service disconnect; usually benign"
            }

            if s.contains("CursorUI") && s.contains("ViewBridge") {
                return "Cursor/UI remote view noise; usually benign"
            }

            // Add more patterns here if you see recurring benign lines.
            return nil
        }

        // Pass 2 (escalation window) — optional; never replaces baseline.
        let escalationAnchorDate: Date? = escalated ? findEscalationAnchorDate() : nil
        let escalatedResult: ScanResult? = {
            guard escalated, let anchor = escalationAnchorDate else { return nil }
            return runEscalationWindowScan(anchorDate: anchor)
        }()

        let baselineKeptPct: String = {
            guard baseline.scanned > 0 else { return "0%" }
            let pct = (Double(baseline.written) / Double(baseline.scanned)) * 100.0
            return String(format: "%.2f%%", pct)
        }()

        let escalatedKeptPct: String? = {
            guard let r = escalatedResult, r.scanned > 0 else { return nil }
            let pct = (Double(r.written) / Double(r.scanned)) * 100.0
            return String(format: "%.2f%%", pct)
        }()

        // Header uses baseline as the primary log, with optional escalation meta.
        let header = buildSupportLogHeader(
            context: context,
            entriesScanned: baseline.scanned,
            entriesWritten: baseline.written,
            keptPct: baselineKeptPct,
            baselinePolicyLabel: baselinePolicyLabel,
            debugCount: baseline.debugCount,
            infoCount: baseline.infoCount,
            noticeCount: baseline.noticeCount,
            errorCount: baseline.errorCount,
            faultCount: baseline.faultCount,
            droppedOtherSubsystem: baseline.droppedOtherSubsystem,
            droppedByLevelPolicy: baseline.droppedByLevelPolicy,
            droppedNonLogEntry: baseline.droppedNonLogEntry,
            truncatedByMaxEntries: baseline.truncatedByMaxEntries,
            escalated: escalated,
            escalationReason: escalationReason,
            escalationEntriesScanned: escalatedResult?.scanned,
            escalationEntriesWritten: escalatedResult?.written,
            escalationKeptPct: escalatedKeptPct,
            escalationTruncated: escalatedResult?.truncatedByMaxEntries
        )

        var bodyText = baseline.lines.joined(separator: "\n")

        if let r = escalatedResult {
            bodyText += "\n\n---\nESCALATION CONTEXT (windowed, debug+)\n"
            bodyText += "Reason: \(escalationReason ?? "unknown")\n"
            if let anchor = escalationAnchorDate {
                bodyText += "Anchor: \(iso.string(from: anchor))\n"
                bodyText += "Window: -\(Int(escalationPreSeconds))s / +\(Int(escalationPostSeconds))s\n"
                bodyText += "Policy: app subsystem includes debug+ (deduped vs baseline); non-app logs include ERROR/FAULT only\n"
                bodyText += "Excluded: non-app DEBUG/INFO/NOTICE (common OS/UI noise), and any entries already present in baseline\n"
            } else {
                bodyText += "Policy: app subsystem includes debug+ (deduped vs baseline); non-app logs include ERROR/FAULT only\n"
                bodyText += "Excluded: non-app DEBUG/INFO/NOTICE (common OS/UI noise), and any entries already present in baseline\n"
            }
            bodyText += "Entries: \(r.written)/\(r.scanned)\(r.truncatedByMaxEntries ? " (truncated)" : "")\n"
            bodyText += "---\n"

            if r.lines.isEmpty {
                bodyText += "(No additional entries were captured beyond the baseline — either the baseline already contained everything in the window, or there were no non-app ERROR/FAULT logs near the anchor.)\n"
            } else {
                // If escalation contains only known-benign system noise, add a single high-level hint.
                let hintedCount = r.lines.reduce(0) { acc, line in
                    acc + ((escalationNoiseHint(for: line) != nil) ? 1 : 0)
                }
                if !r.lines.isEmpty, hintedCount == r.lines.count {
                    bodyText += "NoiseHint: escalation captured only common benign OS/UI noise; baseline contains the app error details.\n"
                }

                // Append per-line noise hints for common OS errors.
                let annotated = r.lines.map { line -> String in
                    if let hint = escalationNoiseHint(for: line) {
                        return "\(line)  [NoiseHint: \(hint)]"
                    }
                    return line
                }
                bodyText += annotated.joined(separator: "\n")
                bodyText += "\n"
            }
        }

        let outText = header + "\n\n" + bodyText + "\n"

        let filename = "\(appSlug())-SupportLog-v\(appVersionString())-\(timestamp()).txt"
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        try outText.write(to: outURL, atomically: true, encoding: .utf8)
        return outURL
    }

    private static func buildSupportLogHeader(
        context: [String: String],
        entriesScanned: Int,
        entriesWritten: Int,
        keptPct: String,
        baselinePolicyLabel: String,
        debugCount: Int,
        infoCount: Int,
        noticeCount: Int,
        errorCount: Int,
        faultCount: Int,
        droppedOtherSubsystem: Int,
        droppedByLevelPolicy: Int,
        droppedNonLogEntry: Int,
        truncatedByMaxEntries: Bool,
        escalated: Bool,
        escalationReason: String?,
        escalationEntriesScanned: Int?,
        escalationEntriesWritten: Int?,
        escalationKeptPct: String?,
        escalationTruncated: Bool?
    ) -> String {
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

        // Escalation header
        if escalated {
            var line = "Escalation: triggered=yes reason=\(escalationReason ?? "unknown")"
            if let s = escalationEntriesScanned, let w = escalationEntriesWritten {
                let trunc = (escalationTruncated ?? false) ? " truncated=yes" : " truncated=no"
                if let pct = escalationKeptPct {
                    line += " entries=\(w)/\(s) kept=\(pct)\(trunc)"
                } else {
                    line += " entries=\(w)/\(s)\(trunc)"
                }
            }
            parts.append(line)
        } else {
            parts.append("Escalation: triggered=no")
        }

        parts.append(
            "Summary: entries=\(entriesWritten)/\(entriesScanned) kept=\(keptPct) baseline_policy=\(baselinePolicyLabel) levels(debug=\(debugCount) info=\(infoCount) notice=\(noticeCount) error=\(errorCount) fault=\(faultCount))"
        )

        // Dropped counters are tracked explicitly so the header can't drift if filtering changes.
        let droppedTotal = droppedOtherSubsystem + droppedByLevelPolicy + droppedNonLogEntry
        let droppedComputed = max(0, entriesScanned - entriesWritten)
        let truncatedLabel = truncatedByMaxEntries ? "yes" : "no"

        parts.append(
            "Dropped: total=\(droppedTotal) other_subsystem=\(droppedOtherSubsystem) below_level_policy=\(droppedByLevelPolicy) non_log_entry=\(droppedNonLogEntry) truncated=\(truncatedLabel)"
        )

        // If these ever diverge, it signals a future code change forgot to increment a counter.
        if droppedTotal != droppedComputed {
            parts.append("DroppedWarning: counters_mismatch tracked=\(droppedTotal) computed=\(droppedComputed)")
        }

        // Optional: caller can pass a user-facing error status hint (e.g. user_error=none / present)
        if let userError = context["user_error"], !userError.isEmpty {
            parts.append("UserError: \(userError)")
        } else {
            parts.append("UserError: unknown")
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
